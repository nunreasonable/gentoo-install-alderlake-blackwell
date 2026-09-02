#!/usr/bin/env bash
# 03-chroot-setup.sh — configuracao base do sistema DENTRO do chroot.
#
# Implementa os seguintes passos do Handbook AMD64:
#   - "Installing the Gentoo ebuild repository snapshot from the web"
#     (emerge-webrsync) + "Updating the Gentoo ebuild repository" (emerge --sync)
#   - "Choosing the right profile" (eselect profile set, POR NOME EXATO)
#   - "Timezone" (symlink /etc/localtime)
#   - "Configure locales" (locale.gen + locale-gen + eselect locale set)
#   - recarga de ambiente (env-update && source /etc/profile)
#   - "Configuring the system > Filesystem information" (/etc/fstab por UUID)
#   - opcional: "Updating the @world set" (atras de UPDATE_WORLD=yes)
#
# Fase: chroot (rodado pelo install.sh --chroot, ou standalone para debug).
# Idempotente: cada sub-etapa passa por run_step com probe funcional.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/vars.sh"
source "$SCRIPT_DIR/lib.sh"
init_logging 03-chroot-setup
require_phase chroot
validate_vars

# Devices das particoes (visiveis no chroot gracas ao rbind de /dev).
# Necessario para o fstab por UUID.
compute_partitions

# ---------------------------------------------------------------------------
# Constantes e derivacoes locais
# ---------------------------------------------------------------------------

# Localizacao padrao do repositorio ::gentoo no perfil 23.0.
GENTOO_REPO="/var/db/repos/gentoo"

# Perfil eselect derivado de INIT_SYSTEM — SEMPRE por nome exato, nunca por
# numero (a numeracao do `eselect profile list` muda entre snapshots do repo).
TARGET_PROFILE="default/linux/amd64/23.0"
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    TARGET_PROFILE="$TARGET_PROFILE/systemd"
fi

# Charmap do locale principal para a linha do locale.gen
# (pt_BR.UTF-8 -> "pt_BR.UTF-8 UTF-8"; locale sem sufixo assume UTF-8).
if [[ "$LOCALE" == *.* ]]; then
    LOCALE_CHARMAP="${LOCALE#*.}"
else
    LOCALE_CHARMAP="UTF-8"
fi
LOCALE_GEN_LINE="$LOCALE $LOCALE_CHARMAP"

# en_US.UTF-8 e SEMPRE gerado junto, como fallback (convencao do plano).
FALLBACK_LOCALE_LINE="en_US.UTF-8 UTF-8"

# ---------------------------------------------------------------------------
# Helpers locais (somente leitura — usados pelos probes)
# ---------------------------------------------------------------------------

# current_profile / eselect_profile_show vivem no lib.sh (sao sourceaveis, e por
# isso testaveis sem chroot). Ver a secao "Perfil do Portage" la.

# normalize_locale <nome>: normaliza para comparacao — o glibc registra
# "pt_BR.UTF-8" como "pt_BR.utf8" em `locale -a` (minusculas, sem hifen).
normalize_locale() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '-'
}

# locale_generated <nome>: retorna 0 se o locale ja foi gerado (visivel em
# `locale -a`, comparacao normalizada).
locale_generated() {
    local want
    want="$(normalize_locale "$1")"
    locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-' \
        | grep -qx "$want"
}

# eselect_current_locale: imprime o LANG corrente segundo o eselect
# (linha 2 do `eselect locale show`, sem espacos ao redor).
#
# DIVIDA CONSCIENTE: isto parseia a UI do eselect, do mesmo jeito que o probe de
# perfil fazia antes de migrar para o symlink canonico. Nao foi migrado junto
# porque a fonte canonica de locale DEPENDE DO INIT (/etc/env.d/02locale no
# OpenRC, /etc/locale.conf no systemd) e o caminho OpenRC ja esta validado em
# QEMU — trocar aqui arriscaria uma regressao sem bug concreto que a justifique.
# Mitigacao: este e o ULTIMO dos quatro testes de probe_locale; os tres
# anteriores (duas linhas em locale.gen + locale_generated dos dois locales) sao
# funcionais e nao dependem de formato de saida.
eselect_current_locale() {
    eselect locale show 2>/dev/null \
        | awk 'NR==2 {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}'
}

# find_locale_target: imprime o nome EXATO do locale como o sistema o registra
# em `locale -a` (ex.: pt_BR.utf8) para passar ao eselect por nome — o eselect
# so aceita alvos que existem na lista. Retorna 1 se o locale nao foi gerado.
find_locale_target() {
    local want cand
    want="$(normalize_locale "$LOCALE")"
    while IFS= read -r cand; do
        if [[ "$(normalize_locale "$cand")" == "$want" ]]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done < <(locale -a 2>/dev/null)
    return 1
}

# ---------------------------------------------------------------------------
# 03-sync — snapshot do repositorio + sync
# Handbook: "Installing a Gentoo ebuild repository snapshot from the web"
#           + "Optional: Updating the Gentoo ebuild repository"
# ---------------------------------------------------------------------------

# Sentinela de sync EM ANDAMENTO: criada antes do emerge-webrsync e removida
# so apos o `emerge --sync` concluir. Mesmo padrao do EXTRACT_STARTED no 01, e
# pela mesma razao: os dois arquivos que o probe checa aparecem CEDO na
# extracao do snapshot, entao Ctrl-C/queda/disco cheio no meio deixa uma
# arvore truncada que satisfaria o probe para sempre — e a falha so apareceria
# muito depois, em 04/05/06, como "no ebuilds to satisfy".
# Vive fora do state dir de proposito: sobrevive a ./install.sh --reset, entao
# a evidencia de sync interrompido nao se perde junto com os markers.
SYNC_STARTED="/var/tmp/gentoo-install/sync-started"

# Categorias que as etapas seguintes consomem. Se qualquer uma faltar, a
# arvore esta truncada, por mais que repo_name/timestamp.chk existam.
SYNC_REQUIRED_PKGS=(
    "sys-kernel/gentoo-sources"      # 04-kernel
    "sys-boot/grub"                  # 05-bootloader
    "x11-drivers/nvidia-drivers"     # 04-nvidia
)

# Probe: o repositorio ::gentoo esta populado E completo. Uma vez populado,
# re-sincronizar a cada re-execucao seria lento e desnecessario — quem quiser
# forcar usa `emerge --sync` na mao.
probe_sync() {
    local pkg
    # Evidencia de sync INTERROMPIDO -> refaz (webrsync+sync sao incrementais
    # e nao-destrutivos; o pior caso de refazer e tempo, nunca perda de arvore).
    [[ -e "$SYNC_STARTED" ]] && return 1
    [[ -f "$GENTOO_REPO/profiles/repo_name" \
       && -f "$GENTOO_REPO/metadata/timestamp.chk" ]] || return 1
    # Arvore truncada satisfaz os dois arquivos acima mas nao tem as categorias
    # de que 04/05/06 dependem — exige um ebuild real em cada uma delas.
    for pkg in "${SYNC_REQUIRED_PKGS[@]}"; do
        compgen -G "$GENTOO_REPO/$pkg/*.ebuild" >/dev/null || return 1
    done
    return 0
}

do_sync() {
    local stamp
    mkdir -p "$(dirname "$SYNC_STARTED")"
    # Sentinela ANTES do webrsync: se o sync for interrompido, o proximo run a
    # encontra e refaz em vez de aceitar a arvore parcial.
    : > "$SYNC_STARTED"
    # webrsync baixa o snapshot diario assinado (nao depende de rsync liberado
    # na rede); o --sync em seguida traz o delta ate o estado corrente.
    emerge-webrsync
    emerge --sync --quiet
    rm -f "$SYNC_STARTED"
    # Marker com valor: registra o timestamp.chk do snapshot sincronizado, para
    # o log identificar QUAL arvore esta instalada (diagnostico de 04/05/06).
    stamp="$(cat "$GENTOO_REPO/metadata/timestamp.chk" 2>/dev/null || true)"
    mark_done 03-sync "${stamp:-done}"
}

run_step 03-sync probe_sync do_sync

# ---------------------------------------------------------------------------
# News items — Handbook: "Reading news items" (logo apos o sync)
# News frequentemente trazem instrucoes de migracao obrigatorias (perfil 23.0,
# merged-usr) que afetam as etapas seguintes. Roda SEMPRE, fora de run_step:
# e barato e naturalmente idempotente (depois de lidos, 'count new' volta 0).
# ---------------------------------------------------------------------------

report_news_items() {
    local count rc
    # Tres estados DISTINTOS, nunca colapsados: (a) consultei e ha N>0,
    # (b) consultei e ha zero, (c) NAO consegui consultar. Sem 2>/dev/null: o
    # motivo da falha precisa ir para o log. Sem `|| count=0`: tratar falha de
    # consulta como "zero news" imprimiria uma afirmacao positiva e FALSA.
    count="$(eselect news count new 2>&1)" && rc=0 || rc=$?
    if (( rc != 0 )); then
        log_warn "nao foi possivel consultar os news items do Portage (eselect news count new saiu com $rc): ${count:-sem saida}"
        log_warn "leia manualmente com 'eselect news list' — news podem trazer migracoes obrigatorias que afetam 04/05/06"
        return 0
    fi
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        log_warn "eselect news count new devolveu saida inesperada ('$count') — nao da para afirmar que nao ha news; leia manualmente com 'eselect news list'"
        return 0
    fi
    if (( count > 0 )); then
        log_warn "$count news item(s) do Portage nao lidos — conteudo registrado no log abaixo"
        eselect news list || true

        # 'read --quiet new' EXIBE o conteudo sem marcar como lido: o pager e
        # desabilitado, mas o estado de leitura NAO e alterado. E a unica forma
        # de logar o texto integral preservando o aviso do Portage nos emerges
        # seguintes, que e o que garante que o operador humano tome ciencia.
        eselect news read --quiet new || true

        # Marcar como lido e uma decisao do OPERADOR, nunca do instalador.
        # News do Gentoo carregam migracoes obrigatorias (perfil 23.0, merged-usr)
        # que quebram 04/05/06 horas depois; engolir o aviso silenciosamente
        # transforma uma instrucao de migracao em falha misteriosa de build.
        # Por isso o default e READ_NEWS=no.
        if [[ "$READ_NEWS" == "yes" ]]; then
            log_warn "READ_NEWS=yes — marcando os $count news item(s) como lidos a pedido do usuario"
            eselect news read new > /dev/null || true
        else
            log_warn "os news items acima permanecem NAO LIDOS (READ_NEWS=no, default seguro)"
            log_warn "leia-os antes de usar o sistema: 'eselect news read new' — e marque como lidos so depois de aplicar o que for necessario"
        fi
    else
        log_info "nenhum news item novo do Portage"
    fi
}

report_news_items

# ---------------------------------------------------------------------------
# 03-profile — perfil do Portage
# Handbook: "Choosing the right profile"
# ---------------------------------------------------------------------------

# Probe: o symlink /etc/portage/make.profile resolve para o perfil desejado.
# Autoridade = o symlink (fonte canonica), nao a saida do eselect.
probe_profile() {
    local cur
    cur="$(current_profile)" || return 1
    [[ "$cur" == "$TARGET_PROFILE" ]]
}

do_profile() {
    # Por NOME exato — nunca por numero (numeracao instavel entre snapshots).
    eselect profile set "$TARGET_PROFILE"
    # Verificar DEPOIS de aplicar (invariante 6), pela fonte canonica: o
    # eselect pode sair 0 e ainda assim deixar o symlink em outro lugar.
    local cur
    cur="$(current_profile)" \
        || die "apos 'eselect profile set $TARGET_PROFILE', /etc/portage/make.profile nao existe ou nao resolve. eselect diz: $(eselect_profile_show)"
    [[ "$cur" == "$TARGET_PROFILE" ]] \
        || die "perfil errado apos o set: /etc/portage/make.profile resolve para '$cur', esperado '$TARGET_PROFILE'. eselect diz: $(eselect_profile_show)"
}

run_step 03-profile probe_profile do_profile

# ---------------------------------------------------------------------------
# 03-timezone — fuso horario
# Handbook: "Configuring the system > Timezone"
# ---------------------------------------------------------------------------

# Probe: symlink relativo correto + /etc/timezone consistente.
probe_timezone() {
    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || return 1
    [[ "$(readlink /etc/localtime 2>/dev/null)" == "../usr/share/zoneinfo/$TIMEZONE" ]] || return 1
    [[ "$(cat /etc/timezone 2>/dev/null)" == "$TIMEZONE" ]]
}

do_timezone() {
    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] \
        || die "timezone '$TIMEZONE' nao existe em /usr/share/zoneinfo — confira a variavel TIMEZONE em vars.sh"
    # Symlink relativo, como no Handbook; -n evita seguir symlink pre-existente.
    ln -sfn "../usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    # /etc/timezone mantem o nome legivel do fuso (usado pelo OpenRC/timezone-data;
    # inofensivo no systemd).
    printf '%s\n' "$TIMEZONE" > /etc/timezone
}

run_step 03-timezone probe_timezone do_timezone

# ---------------------------------------------------------------------------
# 03-locale — geracao e selecao de locale
# Handbook: "Configuring the system > Configure locales"
# ---------------------------------------------------------------------------

# Probe: linhas presentes no locale.gen, locales efetivamente gerados
# (locale -a) e LANG corrente do eselect apontando para $LOCALE.
probe_locale() {
    grep -qxF "$LOCALE_GEN_LINE" /etc/locale.gen 2>/dev/null || return 1
    grep -qxF "$FALLBACK_LOCALE_LINE" /etc/locale.gen 2>/dev/null || return 1
    locale_generated "$LOCALE" || return 1
    locale_generated "en_US.UTF-8" || return 1
    [[ "$(normalize_locale "$(eselect_current_locale)")" == "$(normalize_locale "$LOCALE")" ]]
}

do_locale() {
    local line target
    # Acrescenta as linhas que faltam sem duplicar as existentes.
    for line in "$LOCALE_GEN_LINE" "$FALLBACK_LOCALE_LINE"; do
        if ! grep -qxF "$line" /etc/locale.gen 2>/dev/null; then
            printf '%s\n' "$line" >> /etc/locale.gen
        fi
    done
    locale-gen
    # eselect por nome exato como registrado pelo glibc (ex.: pt_BR.utf8).
    target="$(find_locale_target)" \
        || die "locale '$LOCALE' nao apareceu em 'locale -a' apos locale-gen — confira a variavel LOCALE em vars.sh"
    eselect locale set "$target"
}

run_step 03-locale probe_locale do_locale

# ---------------------------------------------------------------------------
# Recarga de ambiente — Handbook: "env-update && source /etc/profile"
# Roda SEMPRE (barato e idempotente): garante que este proprio shell enxerga
# perfil/locale recem-definidos antes das proximas etapas.
# ---------------------------------------------------------------------------

refresh_environment() {
    log_info "recarregando ambiente (env-update + source /etc/profile)"
    env-update
    # /etc/profile nao foi escrito para rodar sob set -e/-u; relaxa as opcoes
    # so durante o source e restaura em seguida (pipefail fica intocado).
    set +eu
    # shellcheck disable=SC1091
    source /etc/profile
    set -eu
}

refresh_environment

# ---------------------------------------------------------------------------
# 03-fstab — /etc/fstab por UUID
# Handbook: "Configuring the system > Creating the fstab file"
# Layout fixo: ESP em /efi (vfat), swap, raiz em / — tudo por UUID real
# lido via blkid (estado do sistema, nunca marker).
# ---------------------------------------------------------------------------

# Probe: as tres linhas com os UUIDs REAIS das particoes existem no fstab.
probe_fstab() {
    local efi_uuid swap_uuid root_uuid
    efi_uuid="$(blkid -s UUID -o value "$EFI_PART" 2>/dev/null)" || return 1
    swap_uuid="$(blkid -s UUID -o value "$SWAP_PART" 2>/dev/null)" || return 1
    root_uuid="$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null)" || return 1
    [[ -n "$efi_uuid" && -n "$swap_uuid" && -n "$root_uuid" ]] || return 1
    grep -Eq "^UUID=${root_uuid}[[:blank:]]+/[[:blank:]]" /etc/fstab 2>/dev/null || return 1
    grep -Eq "^UUID=${efi_uuid}[[:blank:]]+/efi[[:blank:]]" /etc/fstab 2>/dev/null || return 1
    grep -Eq "^UUID=${swap_uuid}[[:blank:]]+none[[:blank:]]+swap[[:blank:]]" /etc/fstab 2>/dev/null
}

do_fstab() {
    local efi_uuid swap_uuid root_uuid root_type
    [[ -b "$ROOT_PART" && -b "$EFI_PART" && -b "$SWAP_PART" ]] \
        || die "particoes de $TARGET_DISK nao visiveis no chroot — os mounts de /dev (rbind) estao ok?"
    efi_uuid="$(blkid -s UUID -o value "$EFI_PART")"
    swap_uuid="$(blkid -s UUID -o value "$SWAP_PART")"
    root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
    [[ -n "$efi_uuid" && -n "$swap_uuid" && -n "$root_uuid" ]] \
        || die "blkid nao retornou UUID para alguma particao — rode 00-partition.sh (mkfs) antes"
    # O tipo REAL do filesystem da raiz e a autoridade (nao a variavel).
    # root_fs_actual (lib.sh) e a MESMA funcao que o 06 usa para decidir sobre
    # xfsprogs — as duas etapas precisam concordar sobre o que a raiz e.
    root_type="$(root_fs_actual)" \
        || die "blkid nao retornou TYPE para $ROOT_PART — a raiz foi formatada?"
    warn_root_fs_mismatch "$root_type"
    # Reescreve o fstab inteiro (o do stage3 so tem exemplos comentados);
    # regenerar por completo e o que garante a idempotencia.
    {
        printf '# /etc/fstab — gerado por 03-chroot-setup.sh (instalacao automatizada)\n'
        printf '# Layout: 1=ESP (/efi), 2=swap, 3=raiz — UUIDs reais lidos via blkid.\n'
        printf '# <fs>\t\t\t\t\t\t<mountpoint>\t<type>\t<opts>\t\t<dump> <pass>\n'
        # passno da raiz depende do TIPO: ext4/xfs usam fsck no boot (passno 1);
        # btrfs NAO usa — o fsck.btrfs e um stub que sai 0 de proposito, e a
        # verificacao real e o `btrfs scrub`, feito com o sistema no ar.
        # Com passno 1 num btrfs o boot fica dependendo de o btrfs-progs estar
        # instalado so para rodar um stub. Convencao (e o que o proprio
        # btrfs-progs documenta): passno 0.
        printf 'UUID=%s\t/\t%s\tdefaults,noatime\t0 %s\n' \
            "$root_uuid" "$root_type" "$([[ "$root_type" == "btrfs" ]] && echo 0 || echo 1)"
        printf 'UUID=%s\t/efi\tvfat\tumask=0077\t0 2\n' "$efi_uuid"
        printf 'UUID=%s\tnone\tswap\tsw\t0 0\n' "$swap_uuid"
    } > /etc/fstab
}

run_step 03-fstab probe_fstab do_fstab

# ---------------------------------------------------------------------------
# 03-world-update — opcional, atras de UPDATE_WORLD=yes
# Handbook: "Updating the @world set" (opcional na primeira instalacao)
# ---------------------------------------------------------------------------

# Probe: nada pendente segundo o proprio emerge (--pretend e somente leitura).
# O status do emerge e checado SEPARADO da contagem: falha do --pretend
# (conflito, pacote mascarado) NAO pode virar "ja feito" — probe falha,
# do_world_update roda e o errexit expoe o erro real no log.
probe_world_update() {
    local out count
    # stderr NAO entra em $out: avisos do Portage no stderr poluiriam a
    # contagem. O exit code continua sendo checado separado da contagem.
    out="$(emerge --pretend --quiet --update --deep --newuse @world 2>/dev/null)" \
        || return 1
    # SEM ancora '^': a etiqueta vem indentada em varios formatos de saida do
    # Portage, e uma unica coluna de deslocamento derrubava a contagem de 1
    # para 0 — o probe dizia "ja atualizado" e o emerge nunca rodava.
    count="$(grep -cE '\[(ebuild|binary|nomerge|blocks|uninstall)' <<<"$out" || true)"
    (( count == 0 )) || return 1
    # Fail-safe: contagem zero mas a saida menciona ebuild = formato que este
    # probe nao entende. Trata como NAO-feito (roda o emerge, que e idempotente)
    # em vez de arriscar pular a atualizacao pedida por UPDATE_WORLD=yes.
    grep -qi 'ebuild' <<<"$out" && return 1
    return 0
}

do_world_update() {
    emerge --verbose --update --deep --newuse @world
}

if [[ "$UPDATE_WORLD" == "yes" ]]; then
    run_step 03-world-update probe_world_update do_world_update
else
    log_info "UPDATE_WORLD=no — pulando 'emerge -uDN @world' (habilite em vars.sh se quiser)"
fi

log_info "==== 03-chroot-setup concluido: sync, perfil '$TARGET_PROFILE', timezone '$TIMEZONE', locale '$LOCALE', fstab ===="
