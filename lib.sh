#!/usr/bin/env bash
# lib.sh — funcoes compartilhadas da instalacao automatizada do Gentoo.
#
# Este arquivo e APENAS sourced pelos scripts 00-06 e pelo install.sh,
# SEMPRE DEPOIS de vars.sh:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/vars.sh"
#   source "$SCRIPT_DIR/lib.sh"
#
# Convencoes:
# - cada script chama: init_logging <nome-do-script> ; require_phase live|chroot ;
#   validate_vars ; e depois run_step para cada sub-etapa.
# - o PROBE e a autoridade da idempotencia; o marker e so cache/registro.
#   Nenhuma acao destrutiva pode confiar apenas no marker.

# ---------------------------------------------------------------------------
# Constantes internas (NAO editaveis — as editaveis ficam em vars.sh)
# ---------------------------------------------------------------------------

# Sentinela que marca "estamos dentro do chroot do sistema alvo".
# install.sh grava em $TARGET_ROOT/etc/gentoo-install/.inside-chroot antes do
# chroot e remove ao voltar com sucesso.
CHROOT_SENTINEL="/etc/gentoo-install/.inside-chroot"

# Partlabels GPT exatos usados por 00-partition.sh e pelos probes.
EFI_PARTLABEL="gentoo-esp"
SWAP_PARTLABEL="gentoo-swap"
ROOT_PARTLABEL="gentoo-root"

# Sub-etapa corrente (mantida por run_step; usada pelo trap ERR).
CURRENT_STEP=""

# Logfile corrente (definido por init_logging).
LOGFILE="${LOGFILE:-}"

# PID do `tee` que init_logging deixou em background. detach_logging_to_tmp
# precisa dele para ENCERRAR o tee antigo de forma deterministica (ele segura um
# fd aberto que pode estar dentro do alvo e impedir o umount -R).
LOGGING_TEE_PID=""

# ---------------------------------------------------------------------------
# Fase (live vs chroot)
# ---------------------------------------------------------------------------

# current_phase: imprime "chroot" se a sentinela existe, senao "live".
current_phase() {
    if [[ -e "$CHROOT_SENTINEL" ]]; then
        echo "chroot"
    else
        echo "live"
    fi
}

# require_phase <live|chroot>: mata o script com mensagem clara se ele foi
# invocado na fase errada. Todos os scripts rodam standalone para debug, entao
# esta guarda e a unica coisa que impede rodar 03-06 fora do chroot.
require_phase() {
    local want="$1" actual
    actual="$(current_phase)"
    if [[ "$want" != "$actual" ]]; then
        if [[ "$want" == "chroot" ]]; then
            die "este script deve rodar DENTRO do chroot do sistema alvo (fase '$want'), mas estamos na fase '$actual'. Use ./install.sh, que entra no chroot sozinho, ou entre manualmente e rode de la."
        else
            die "este script deve rodar no live ISO (fase '$want'), mas estamos na fase '$actual' (sentinela $CHROOT_SENTINEL presente)."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# init_logging <nome-do-script>: define LOGFILE e passa a duplicar TODO o
# stdout/stderr do script para ele via tee.
# Escolha do destino:
#   - fase chroot................ /var/log/gentoo-install/<nome>.log
#   - fase live, alvo montado.... $TARGET_ROOT/var/log/gentoo-install/<nome>.log
#   - fase live, alvo NAO montado (00 pre-mount): /tmp/gentoo-install/<nome>.log
#     -> depois de montar, chame attach_log_to_target para anexar ao alvo.
init_logging() {
    local script_name="$1" logdir
    if [[ "$(current_phase)" == "chroot" ]]; then
        logdir="/var/log/gentoo-install"
    elif mountpoint -q "$TARGET_ROOT" 2>/dev/null; then
        logdir="$TARGET_ROOT/var/log/gentoo-install"
    else
        logdir="/tmp/gentoo-install"
    fi
    mkdir -p "$logdir"
    LOGFILE="$logdir/${script_name}.log"
    # fd 9 guarda o stdout ORIGINAL (console), antes de qualquer tee.
    # detach_logging_to_tmp restaura por ele para fechar a ponta de escrita do
    # pipe: sem um stdout valido de volta, o tee novo nasceria com "Bad file
    # descriptor". Aberto so uma vez, mesmo se init_logging for re-chamada.
    if ! { true >&9; } 2>/dev/null; then
        exec 9>&1
    fi
    # tee -a: re-execucoes do mesmo script acumulam no mesmo log
    exec > >(tee -a "$LOGFILE") 2>&1
    LOGGING_TEE_PID=$!
    log_info "==== $script_name iniciado (fase $(current_phase)) — log: $LOGFILE ===="
}

# attach_log_to_target: anexa o log pre-mount (que comecou em /tmp) ao alvo.
# Chame depois que $TARGET_ROOT estiver montado (fim da sub-etapa de mount do 00)
# e de novo no final do script, se quiser o log completo no alvo. Idempotente:
# copia o conteudo integral por cima da copia anterior, nunca duplica.
attach_log_to_target() {
    local target_dir="$TARGET_ROOT/var/log/gentoo-install"
    [[ -n "$LOGFILE" ]] || return 0
    case "$LOGFILE" in
        /tmp/*)
            mountpoint -q "$TARGET_ROOT" || {
                log_warn "attach_log_to_target: $TARGET_ROOT nao esta montado; log continua so em $LOGFILE"
                return 0
            }
            mkdir -p "$target_dir"
            cp -f "$LOGFILE" "$target_dir/$(basename "$LOGFILE")"
            log_info "log copiado para $target_dir/$(basename "$LOGFILE")"
            ;;
    esac
}

# detach_logging_to_tmp: re-aponta o logging do script corrente para /tmp.
# Necessario antes de desmontar o alvo (install.sh --repartition e o do_gpt
# standalone do 00): o tee de init_logging segura um fd aberto dentro de
# $TARGET_ROOT, o que faria o umount -R falhar com EBUSY.
# No-op se o log ja esta fora do alvo. Depois do re-mount,
# attach_log_to_target anexa a copia integral ao alvo.
#
# O tee antigo e ENCERRADO E COLHIDO aqui, e nao deixado para morrer sozinho:
# antes, a funcao apenas criava um segundo tee e o primeiro continuava vivo
# segurando o fd por um tempo indeterminado — e dai vinham os loops de retry de
# 5x com sleep 1 em volta do umount (00-partition.sh e install.sh). Com o fd
# solto de forma deterministica, o umount seguinte pode ser feito de uma vez.
detach_logging_to_tmp() {
    case "$LOGFILE" in
        "$TARGET_ROOT"/*)
            local newdir="/tmp/gentoo-install" newlog
            mkdir -p "$newdir"
            newlog="$newdir/$(basename "$LOGFILE")"
            # preserva no novo log o que ja foi logado nesta execucao
            cat "$LOGFILE" >> "$newlog" 2>/dev/null || true

            # 1) devolve stdout/stderr ao console original (fd 9). Isto fecha a
            #    ponta de ESCRITA do pipe, que e o que faz o tee ver EOF.
            #    Se o fd 9 nao existir (init_logging nao rodou por este
            #    caminho), segue sem o encerramento deterministico em vez de
            #    quebrar o script — o comportamento degrada para o antigo.
            if { true >&9; } 2>/dev/null; then
                exec 1>&9 2>&9
                # 2) espera o tee terminar de escrever e sair — so entao o fd
                #    dentro do alvo esta realmente liberado para o umount.
                if [[ -n "$LOGGING_TEE_PID" ]]; then
                    wait "$LOGGING_TEE_PID" 2>/dev/null || true
                fi
            fi

            # 3) so agora abre o tee novo, ja apontando para fora do alvo
            exec > >(tee -a "$newlog") 2>&1
            LOGGING_TEE_PID=$!
            LOGFILE="$newlog"
            log_info "logging re-apontado para $LOGFILE (o alvo sera desmontado; tee antigo encerrado)"
            ;;
    esac
}

log_info() {
    printf '[%s] [INFO ] %s\n' "$(_timestamp)" "$*"
}

log_warn() {
    printf '[%s] [AVISO] %s\n' "$(_timestamp)" "$*" >&2
}

log_error() {
    printf '[%s] [ERRO ] %s\n' "$(_timestamp)" "$*" >&2
}

# die <mensagem>: loga o erro e encerra o script com status 1.
die() {
    log_error "$*"
    exit 1
}

# Trap ERR global: nomeia a sub-etapa corrente, arquivo, linha e logfile.
# `set -o errtrace` garante que o trap e herdado por funcoes e subshells de
# comando — os scripts usam `set -euo pipefail`, entao qualquer comando que
# falhe fora de um contexto testado cai aqui antes do shell morrer.
_on_error() {
    local exit_code="$1" line="$2" src="$3"
    local step="${CURRENT_STEP:-"(fora de run_step)"}"
    log_error "falha (exit $exit_code) na sub-etapa '$step' — $src linha $line. Log completo: ${LOGFILE:-"(logging nao inicializado)"}"
}
set -o errtrace
trap '_on_error "$?" "$LINENO" "${BASH_SOURCE[0]}"' ERR

# ---------------------------------------------------------------------------
# Validacao de variaveis (fatal antes de qualquer acao)
# ---------------------------------------------------------------------------

# _live_root_disks: imprime a cadeia de devices (incluindo discos inteiros) que
# sustenta o / do sistema em execucao. Em live ISO tipico o / e overlay/tmpfs
# (nao e block device) e a saida e vazia — nada a comparar.
# Retorna !=0 se o SOURCE do / parece um device mas nao conseguimos resolver a
# cadeia com seguranca — o chamador DEVE tratar isso como fatal, nunca como
# "sem discos" (senao a guarda anti-host vira no-op silencioso).
_live_root_disks() {
    local src
    # -v (--nofsroot): suprime o sufixo de fsroot que o btrfs adiciona ao
    # SOURCE (ex.: /dev/nvme1n1p3[/root] em Fedora) — sem isso o teste -b
    # falharia num root btrfs e a guarda morreria calada
    src="$(findmnt -v -rno SOURCE / 2>/dev/null || true)"
    # cinto e suspensorio: strip manual do [/subvol] para findmnt antigos
    # que nao suportem -v
    src="${src%%\[*}"
    # / sem SOURCE: nada a comparar (ex.: ambientes exoticos sem findmnt)
    [[ -n "$src" ]] || return 0
    if [[ ! -b "$src" ]]; then
        # SOURCE nao-vazio que nao e block device: overlay/tmpfs/airootfs de
        # live ISO sao legitimos (nao vivem em /dev), mas qualquer caminho em
        # /dev que nao resolvemos e SUSPEITO — falha em vez de retornar vazio
        if [[ "$src" == /dev/* ]]; then
            return 1
        fi
        return 0
    fi
    # -s: arvore inversa — lista o device e todos os ancestrais (dm/luks/raid
    # inclusos), terminando nos discos inteiros. Falha do lsblk aqui tambem e
    # suspeita: temos um block device real e nao conseguimos a cadeia dele.
    lsblk -srno NAME "$src" 2>/dev/null || return 1
}

# _host_is_installed_system: retorna 0 se o / do sistema em execucao vive numa
# cadeia de devices que termina num disco real (lsblk TYPE=disk) — evidencia
# POSITIVA de sistema instalado. A fase "live" e definida por mera ausencia da
# sentinela de chroot, entao sem esta checagem qualquer host instalado passa
# como "live". Live ISOs legitimos tem / em overlay/tmpfs (SOURCE nao e block
# device) ou, no maximo, em loop/rom (squashfs, CD) — nunca em TYPE=disk.
_host_is_installed_system() {
    local src
    # -v + strip manual: mesmo tratamento de fsroot btrfs de _live_root_disks
    src="$(findmnt -v -rno SOURCE / 2>/dev/null || true)"
    src="${src%%\[*}"
    [[ -n "$src" && -b "$src" ]] || return 1
    lsblk -srno TYPE "$src" 2>/dev/null | grep -qx "disk"
}

# ---------------------------------------------------------------------------
# Enumeracao de particoes e mounts (FONTE DE VERDADE das guardas destrutivas)
# ---------------------------------------------------------------------------
#
# A coluna MOUNTPOINT (singular) do lsblk e uma armadilha: quando um device tem
# varios mountpoints ela mostra UM arbitrariamente e omite os outros. Guardas
# que dependiam dela eram cegas para o mount que mais importa. Todas as guardas
# passam por estes helpers, que usam findmnt (enumera tudo) e sao fail-closed.

# _target_disk_parts: imprime, uma por linha, as particoes (TYPE=part) do
# TARGET_DISK, ja como nome de kernel absoluto. Nao inclui o disco em si.
# Fail-closed: se o lsblk falhar, retorna !=0 e o chamador DEVE morrer — uma
# lista vazia por erro faria as guardas de mount virarem no-op silencioso.
_target_disk_parts() {
    local name type
    lsblk -nrpo NAME,TYPE "$TARGET_DISK" 2>/dev/null | while read -r name type; do
        [[ "$type" == "part" ]] || continue
        printf '%s\n' "$name"
    done
    # PIPESTATUS[0] e o exit do lsblk (o while nunca falha)
    return "${PIPESTATUS[0]}"
}

# _mountpoints_of <particao>: imprime TODOS os mountpoints da particao, um por
# linha (vazio se nao esta montada). --source e obrigatorio: sem ele o findmnt
# adivinha se o argumento e device ou mountpoint.
# findmnt sai !=0 quando simplesmente nao ha match — isso NAO e erro, entao a
# funcao normaliza para 0 e o "nao montado" e representado por saida vazia.
_mountpoints_of() {
    findmnt -rno TARGET --source "$1" 2>/dev/null || true
}

# _swap_is_active <particao>: 0 se a particao esta ativa como swap.
# realpath tratado explicitamente: um valor vazio viraria o padrao degenerado
# "^ " e a guarda casaria com qualquer linha (ou com nenhuma), em silencio.
_swap_is_active() {
    local dev="$1" rp
    rp="$(realpath "$dev" 2>/dev/null)" \
        || die "nao foi possivel resolver '$dev' para checar swap ativa — abortando por precaucao"
    [[ -n "$rp" ]] \
        || die "realpath de '$dev' retornou vazio ao checar swap ativa — abortando por precaucao"
    grep -q "^${rp} " /proc/swaps
}

# _part_is_our_swap <particao>: 0 somente com EVIDENCIA DE IDENTIDADE de que a
# particao e a swap do NOSSO layout — PARTLABEL == $SWAP_PARTLABEL. Posicao no
# disco nao e evidencia: quase todo layout tem swap na particao 2.
# Fail-closed: PARTLABEL ausente/ilegivel => nao e nossa.
_part_is_our_swap() {
    local label
    label="$(lsblk -nro PARTLABEL "$1" 2>/dev/null)" || return 1
    [[ "$label" == "$SWAP_PARTLABEL" ]]
}

# validate_vars: validacoes fatais de TODAS as variaveis de vars.sh.
# Chamar em todo script, logo depois de init_logging/require_phase.
validate_vars() {
    local size_re='^[0-9]+(MiB|GiB)$'

    # --- alvo (canonicalizado ANTES de tudo) ---
    # TARGET_ROOT tem de ser canonicalizado logo no inicio, e nao no bloco de
    # validacao la embaixo, porque as guardas de mount deste mesmo bloco
    # comparam mountpoints (que o kernel reporta ja canonicos) contra ele.
    # Sem isso: '//' e '///' passavam pelo teste "!= /" e faziam o script tratar
    # a raiz do live ISO como alvo; e '/mnt/gentoo/' fazia o teste de prefixo
    # falhar contra os proprios mounts legitimos (falso positivo).
    # -m (e nao -e): o diretorio pode legitimamente ainda nao existir.
    [[ -n "${TARGET_ROOT:-}" && "$TARGET_ROOT" == /* ]] \
        || die "TARGET_ROOT='${TARGET_ROOT:-}' invalido (esperado caminho absoluto)"
    # guarda a grafia original: a mensagem de erro tem de mostrar o que o
    # usuario escreveu ('//'), nao so o resultado canonico ('/')
    local root_given="$TARGET_ROOT" root_real
    root_real="$(realpath -m "$TARGET_ROOT" 2>/dev/null)" \
        || die "TARGET_ROOT='$root_given' nao pode ser canonicalizado"
    [[ -n "$root_real" ]] \
        || die "TARGET_ROOT='$root_given' canonicalizou para vazio — abortando"
    TARGET_ROOT="$root_real"
    # Profundidade minima de 1 componente: apos a canonicalizacao a raiz em
    # qualquer grafia ('/', '//', '/.', '/mnt/..') vira exatamente '/'.
    [[ "$TARGET_ROOT" != "/" ]] \
        || die "TARGET_ROOT='$root_given' resolve para a raiz '/' do sistema em execucao — use um ponto de montagem dedicado (ex.: /mnt/gentoo)"
    [[ "$TARGET_ROOT" == "$root_given" ]] \
        || log_info "TARGET_ROOT canonicalizado: '$root_given' -> '$TARGET_ROOT'"

    # --- disco alvo ---
    # Canonicaliza ANTES de qualquer outra checagem: symlinks estaveis
    # (/dev/disk/by-id, by-path) sao bem-vindos na entrada, mas as particoes
    # deles seguem a convencao "-part1" e quebrariam part_dev — sem isso o
    # do_gpt zaparia o disco e SO ENTAO morreria esperando um node inexistente.
    # Daqui em diante TARGET_DISK e sempre o nome de kernel (ex.: /dev/nvme0n1).
    local disk_real
    disk_real="$(realpath -e "$TARGET_DISK" 2>/dev/null)" \
        || die "TARGET_DISK='$TARGET_DISK' nao existe ou nao pode ser resolvido"
    TARGET_DISK="$disk_real"
    [[ -b "$TARGET_DISK" ]] \
        || die "TARGET_DISK='$TARGET_DISK' nao e um block device"
    [[ "$(lsblk -ndo TYPE "$TARGET_DISK")" == "disk" ]] \
        || die "TARGET_DISK='$TARGET_DISK' nao e um disco inteiro (lsblk TYPE != disk) — passe o disco, nao uma particao"

    # Na fase live: o disco alvo NAO pode sustentar o / do sistema em execucao
    # (protege contra apagar o proprio host por engano). No chroot esta checagem
    # nao faz sentido (o / DELIBERADAMENTE esta no disco alvo).
    if [[ "$(current_phase)" == "live" ]]; then
        # Evidencia positiva de live ISO: se o / atual vive num disco real,
        # isto e um sistema INSTALADO sendo tratado como fase live (a fase e
        # so a ausencia da sentinela de chroot). Morre por default; o override
        # ALLOW_INSTALLED_HOST=yes e explicito e nao-default, para quem
        # DELIBERADAMENTE instala num segundo disco a partir da distro atual.
        if _host_is_installed_system && [[ "${ALLOW_INSTALLED_HOST:-no}" != "yes" ]]; then
            die "o / do sistema em execucao vive num disco real — isto parece um sistema INSTALADO, nao um live ISO. Se voce REALMENTE quer instalar a partir daqui (ex.: num segundo disco), rode com ALLOW_INSTALLED_HOST=yes."
        fi
        local tdisk_name live_disks
        tdisk_name="$(basename "$TARGET_DISK")"
        # captura em variavel (nao em pipe) para que a falha da funcao seja
        # fatal — SOURCE suspeito nunca pode passar como "sem discos"
        live_disks="$(_live_root_disks)" \
            || die "nao foi possivel determinar com seguranca a cadeia de devices que sustenta o / (SOURCE do findmnt suspeito) — abortando por precaucao em vez de arriscar apagar o disco do host"
        if grep -qx "$tdisk_name" <<<"$live_disks"; then
            die "TARGET_DISK='$TARGET_DISK' sustenta o / do sistema em execucao — voce NAO esta num live ISO ou apontou para o disco errado. Abortando."
        fi
        # Rede de seguranca extra: nenhuma particao do disco alvo pode estar
        # montada fora de $TARGET_ROOT. Swap ativa so e tolerada quando e a
        # SWAP_PART do NOSSO layout — e "nosso" exige EVIDENCIA DE IDENTIDADE
        # (PARTLABEL), nunca a mera posicao 2 no disco: ESP/swap/root e o
        # layout mais comum que existe, entao aceitar pela posicao descartava o
        # sinal de "disco errado" justamente no caso mais provavel de disco
        # errado. Qualquer outra swap bloqueia igual a um mount estranho.
        #
        # FONTE DE VERDADE = findmnt, nao lsblk: a coluna MOUNTPOINT do lsblk e
        # SINGULAR por design — com varios mountpoints no mesmo device ela
        # escolhe um arbitrariamente e OMITE os demais (provado neste hardware:
        # lsblk mostrava so /home enquanto o device tambem sustentava /).
        # 'findmnt -rno TARGET --source <part>' enumera TODAS as linhas.
        # Mesmo padrao ja correto de _assert_not_mounted_elsewhere (00:55-63).
        local part mnt target_parts
        # captura em variavel (nao em process substitution) pelo mesmo motivo
        # de live_disks acima: em <(...) o exit code se perde e uma lista vazia
        # por erro do lsblk transformaria as guardas abaixo em no-op silencioso
        target_parts="$(_target_disk_parts)" \
            || die "nao foi possivel enumerar as particoes de '$TARGET_DISK' (lsblk falhou) — abortando por precaucao em vez de seguir com guardas de mount cegas"
        while read -r part; do
            [[ -n "$part" ]] || continue
            # swap nao aparece no findmnt — /proc/swaps e a fonte para ela
            if _swap_is_active "$part"; then
                _part_is_our_swap "$part" \
                    || die "particao $part de TARGET_DISK esta ativa como swap e NAO e a swap do nosso layout (PARTLABEL != '$SWAP_PARTLABEL') — se este e mesmo o disco certo, rode 'swapoff $part' antes de continuar"
            fi
            # enumera TODOS os mountpoints desta particao, um por linha
            while read -r mnt; do
                [[ -n "$mnt" ]] || continue
                [[ "$mnt" == "$TARGET_ROOT" || "$mnt" == "$TARGET_ROOT"/* ]] \
                    || die "particao $part de TARGET_DISK esta montada em '$mnt' (fora de $TARGET_ROOT) — desmonte antes de continuar"
            done < <(_mountpoints_of "$part")
        done <<< "$target_parts"
    fi

    # --- tamanhos ---
    [[ "$EFI_SIZE" =~ $size_re ]] \
        || die "EFI_SIZE='$EFI_SIZE' invalido (esperado <numero>MiB ou <numero>GiB)"
    [[ "$SWAP_SIZE" =~ $size_re ]] \
        || die "SWAP_SIZE='$SWAP_SIZE' invalido (esperado <numero>MiB ou <numero>GiB)"
    [[ -z "$ROOT_SIZE" || "$ROOT_SIZE" =~ $size_re ]] \
        || die "ROOT_SIZE='$ROOT_SIZE' invalido (vazio = resto do disco, ou <numero>MiB/GiB)"

    # --- enums ---
    [[ "$ROOT_FS" == "ext4" || "$ROOT_FS" == "xfs" || "$ROOT_FS" == "btrfs" ]] \
        || die "ROOT_FS='$ROOT_FS' invalido (ext4|xfs|btrfs)"
    [[ "$INIT_SYSTEM" == "openrc" || "$INIT_SYSTEM" == "systemd" ]] \
        || die "INIT_SYSTEM='$INIT_SYSTEM' invalido (openrc|systemd)"
    [[ "$NVIDIA_MODE" == "auto" || "$NVIDIA_MODE" == "force" || "$NVIDIA_MODE" == "skip" ]] \
        || die "NVIDIA_MODE='$NVIDIA_MODE' invalido (auto|force|skip)"
    local var
    for var in ENABLE_SSHD ENABLE_DHCP ENABLE_WIFI ENABLE_SUDO GRUB_REMOVABLE AUTO_CONFIRM UPDATE_WORLD ALLOW_INSTALLED_HOST \
               READ_NEWS SKIP_HW_PREFLIGHT HW_PREFLIGHT_STRICT; do
        [[ "${!var}" == "yes" || "${!var}" == "no" ]] \
            || die "$var='${!var}' invalido (yes|no)"
    done

    # --- identidade ---
    [[ "$TARGET_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
        || die "TARGET_HOSTNAME='$TARGET_HOSTNAME' invalido (RFC 1123)"
    [[ "$TIMEZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] \
        || die "TIMEZONE='$TIMEZONE' invalido (esperado ex.: America/Sao_Paulo)"
    [[ "$KEYMAP" =~ ^[a-zA-Z0-9._-]+$ ]] \
        || die "KEYMAP='$KEYMAP' invalido"
    [[ "$LOCALE" =~ ^[a-z]{2,3}_[A-Z]{2}(\.[A-Za-z0-9-]+)?$ ]] \
        || die "LOCALE='$LOCALE' invalido (esperado ex.: pt_BR.UTF-8)"

    # --- compilacao ---
    [[ "$MAKEOPTS" =~ ^-j[0-9]+([[:space:]]+-[a-z][A-Za-z0-9=]*)*$ ]] \
        || die "MAKEOPTS='$MAKEOPTS' invalido (esperado ex.: -j17 ou '-j17 -l16')"
    [[ "$CFLAGS_ARCH" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
        || die "CFLAGS_ARCH='$CFLAGS_ARCH' invalido (esperado ex.: native, alderlake)"

    # --- download / verificacao ---
    [[ "$MIRROR" =~ ^https?:// ]] \
        || die "MIRROR='$MIRROR' invalido (esperado URL http(s)://)"
    [[ "$RELENG_KEY_FPR" =~ ^[0-9A-Fa-f]{40}$ ]] \
        || die "RELENG_KEY_FPR='$RELENG_KEY_FPR' invalido (esperados 40 digitos hex)"

    # --- nvidia ---
    [[ "$NVIDIA_MIN_VER" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
        || die "NVIDIA_MIN_VER='$NVIDIA_MIN_VER' invalido (esperado ex.: 580.173.02)"

    # --- usuario ---
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || die "USERNAME='$USERNAME' invalido"
    [[ "$USER_GROUPS" =~ ^[a-z_][a-z0-9_-]*(,[a-z_][a-z0-9_-]*)*$ ]] \
        || die "USER_GROUPS='$USER_GROUPS' invalido (lista separada por virgula)"
    [[ -z "$ROOT_PASSWORD_HASH" || "$ROOT_PASSWORD_HASH" == \$* ]] \
        || die "ROOT_PASSWORD_HASH nao parece um hash crypt (deve comecar com \$) — use ex.: openssl passwd -6"
    [[ -z "$USER_PASSWORD_HASH" || "$USER_PASSWORD_HASH" == \$* ]] \
        || die "USER_PASSWORD_HASH nao parece um hash crypt (deve comecar com \$) — use ex.: openssl passwd -6"

    # --- alvo ---
    # (TARGET_ROOT ja foi canonicalizado e validado no inicio desta funcao —
    # tinha de ser antes das guardas de mount, que comparam contra ele.)
}

# ---------------------------------------------------------------------------
# API de state (marker + probe; o PROBE e a autoridade)
# ---------------------------------------------------------------------------

# state_dir: imprime o diretorio de markers, que vive NO FILESYSTEM ALVO
# (sobrevive as duas fases e a reboot do live ISO):
#   fase live  -> $TARGET_ROOT/var/lib/gentoo-install/state
#   fase chroot-> /var/lib/gentoo-install/state
state_dir() {
    if [[ "$(current_phase)" == "chroot" ]]; then
        echo "/var/lib/gentoo-install/state"
    else
        echo "$TARGET_ROOT/var/lib/gentoo-install/state"
    fi
}

# mark_done <nome> [valor]: grava o marker (default "done"). Sub-etapas que
# precisam registrar um valor (flavor do stage3, hash do fragmento, versao do
# nvidia...) passam o valor como 2o argumento.
mark_done() {
    local name="$1" value="${2:-done}" dir
    dir="$(state_dir)"
    mkdir -p "$dir"
    printf '%s\n' "$value" > "$dir/$name"
}

# step_done <nome>: retorna 0 se o marker existe, 1 caso contrario.
step_done() {
    [[ -e "$(state_dir)/$1" ]]
}

# step_value <nome>: imprime o conteudo do marker (vazio se nao existe).
# Nunca falha — sempre retorna 0.
step_value() {
    cat "$(state_dir)/$1" 2>/dev/null || true
}

# clear_marker <nome>: remove o marker (inofensivo se nao existe).
clear_marker() {
    rm -f "$(state_dir)/$1"
}

# ---------------------------------------------------------------------------
# Identidade do state (schema + commit do installer que o produziu)
# ---------------------------------------------------------------------------
#
# Motivacao: o state sobrevive a reboots e a `--reset`, e nada o amarrava a
# versao do installer que o gerou. Um state produzido pela versao A podia ser
# consumido pela versao B sem nenhum aviso.
#
# STATE_SCHEMA muda SO quando o FORMATO do state muda de um jeito que a versao
# anterior nao entende (nome/semantica de marker, layout do diretorio). Trocar
# de commit NAO e motivo para incrementar.
STATE_SCHEMA=1

# installer_commit: identidade da arvore de codigo em execucao.
# Retorna o commit curto quando o diretorio do script E um checkout git, com
# sufixo -dirty se ha modificacoes nao commitadas. Fora de um checkout (o caso
# normal DENTRO do chroot, onde so os scripts foram copiados) devolve
# "nao-versionado" — nunca inventa um SHA.
installer_commit() {
    local dir="${SCRIPT_DIR:-.}" c
    if ! c="$(git -C "$dir" rev-parse --short=12 HEAD 2>/dev/null)" || [[ -z "$c" ]]; then
        printf 'nao-versionado\n'
        return 0
    fi
    if ! git -C "$dir" diff --quiet HEAD 2>/dev/null; then
        c="$c-dirty"
    fi
    printf '%s\n' "$c"
}

# state_identity_check: confronta o state existente com o installer atual.
#
#   state ausente          -> grava a identidade e segue (primeira execucao)
#   mesmo schema, mesmo commit  -> silencioso
#   mesmo schema, commit difere -> AVISO, resume continua
#   schema diferente       -> die (o formato mudou; resume seria adivinhacao)
#   arquivo ilegivel/sem schema numerico -> die (fail-closed)
#
# Deliberadamente NAO destrutivo: nunca apaga state, nunca reformata. Na duvida
# aborta e deixa a decisao com o operador.
#
# So faz sentido chamar depois que o alvo esta montado (o state vive no
# filesystem alvo); os call sites estao no install.sh.
state_identity_check() {
    local dir f schema commit cur
    dir="$(state_dir)"
    f="$dir/.installer"
    cur="$(installer_commit)"

    if [[ ! -e "$f" ]]; then
        mkdir -p "$dir"
        printf 'schema=%s\ncommit=%s\n' "$STATE_SCHEMA" "$cur" > "$f"
        return 0
    fi

    [[ -r "$f" ]] || die "state ilegivel: $f existe mas nao pode ser lido — corrija as permissoes ou remova o diretorio de state ($dir) para comecar limpo"

    schema="$(sed -n 's/^schema=//p' "$f" | head -n1)"
    commit="$(sed -n 's/^commit=//p' "$f" | head -n1)"

    [[ "$schema" =~ ^[0-9]+$ ]] \
        || die "state corrompido: $f nao declara um schema numerico (leu '${schema:-vazio}'). Remova $dir para comecar limpo — nenhuma etapa destrutiva sera repetida, porque os probes reexaminam o estado real do disco."

    if (( schema != STATE_SCHEMA )); then
        die "state INCOMPATIVEL: foi criado com schema $schema e este installer usa schema $STATE_SCHEMA. O formato do state mudou entre as duas versoes e retomar seria adivinhacao. Opcoes: (a) use a versao do installer que criou este state, ou (b) remova $dir e re-execute — os probes reexaminam o disco, entao nada ja feito e refeito."
    fi

    if [[ "$commit" != "$cur" ]]; then
        log_warn "State foi criado pelo installer commit ${commit:-desconhecido}; o installer atual e $cur."
        log_warn "Schema $schema e o mesmo, entao o resume CONTINUA normalmente — mas se o comportamento das etapas mudou entre as duas versoes, o estado ja gravado reflete a versao antiga."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Filesystem real da raiz (autoridade sobre a variavel ROOT_FS)
# ---------------------------------------------------------------------------
#
# ROOT_FS e a EXPECTATIVA declarada em vars.sh; o que esta gravado na particao
# e o FATO. Os dois divergem sempre que alguem edita vars.sh depois do mkfs,
# ou retoma uma instalacao antiga com outro valor.
#
# Quem decide com base em filesystem (fstab no 03, xfsprogs no 06) tem que usar
# ESTA funcao, para as duas etapas concordarem. Imprime o tipo e retorna 0;
# retorna 1 (sem imprimir) quando nao da para determinar — cabe ao chamador
# decidir, e a regra do projeto e fail-closed: probe reporta nao-feito, do_fn
# morre.
root_fs_actual() {
    local t
    t="$(blkid -s TYPE -o value "$ROOT_PART" 2>/dev/null)" || t=""
    [[ -n "$t" ]] || return 1
    printf '%s\n' "$t"
}

# warn_root_fs_mismatch: aviso unico e uniforme quando a expectativa diverge do
# fato. Nao decide nada — so relata. Silencioso quando batem.
warn_root_fs_mismatch() {
    local actual="$1"
    [[ "$actual" == "$ROOT_FS" ]] && return 0
    log_warn "ROOT_FS='$ROOT_FS' em vars.sh, mas $ROOT_PART esta formatada como '$actual' — o tipo REAL manda; nada sera reformatado"
    return 0
}

# ---------------------------------------------------------------------------
# Perfil do Portage (usado pelo 03; vive aqui para ser sourceavel e testavel)
# ---------------------------------------------------------------------------

# current_profile [caminho-do-make.profile]: perfil corrente pela fonte
# CANONICA — o alvo real do symlink /etc/portage/make.profile, que e o que o
# portage de fato le.
#
# NAO parseamos `eselect profile show`: a saida dele e apresentacao (cabecalho,
# indentacao, marcador do selecionado) e depender da POSICAO das linhas
# transforma texto decorativo em API. O symlink e a estrutura de verdade.
#
# Imprime o perfil no formato do eselect (ex.: default/linux/amd64/23.0), que e
# o trecho apos ".../profiles/". Retorna 1 sem imprimir quando o symlink nao
# existe ou nao resolve — fail-closed: o probe reporta nao-feito.
#
# O argumento opcional existe so para os testes apontarem para uma arvore
# temporaria; em producao ninguem passa nada.
current_profile() {
    local link="${1:-/etc/portage/make.profile}" target
    target="$(readlink -f "$link" 2>/dev/null)" || return 1
    [[ -n "$target" && -d "$target" ]] || return 1
    if [[ "$target" == */profiles/* ]]; then
        printf '%s\n' "${target#*/profiles/}"
    else
        # Perfil fora de um repo com layout padrao: devolve o caminho absoluto,
        # que nao vai casar com TARGET_PROFILE — e reprovar aqui e o certo.
        printf '%s\n' "$target"
    fi
}

# eselect_profile_show: SOMENTE para mensagem de diagnostico. Nao e autoridade
# e nenhum probe decide com base nisto.
eselect_profile_show() {
    eselect profile show 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//'
}

# run_step <nome> <probe_fn> <do_fn>: executor idempotente de sub-etapa.
#
# SEMANTICA CRITICA — o probe e a autoridade:
#   - probe retorna 0 ("ja feito")  -> pula; grava o marker se faltava.
#   - probe retorna !=0 ("nao feito") -> executa do_fn MESMO que exista marker;
#     o marker obsoleto e apagado ANTES de executar.
#   - depois de do_fn, o probe e re-executado: se ainda reportar nao-feito,
#     e fatal (do_fn nao cumpriu o contrato).
#   - do_fn pode chamar `mark_done <nome> <valor>` para registrar um valor;
#     run_step so grava o marker generico "done" se do_fn nao gravou nada.
#
# probe_fn NAO pode ter efeitos colaterais nem acoes destrutivas; do_fn nunca
# deve decidir destruicao com base em marker — so no estado real do sistema.
run_step() {
    local name="$1" probe_fn="$2" do_fn="$3"
    CURRENT_STEP="$name"
    if "$probe_fn"; then
        # probe diz feito: garante marker e pula
        if ! step_done "$name"; then
            mark_done "$name"
        fi
        log_info "[$name] probe OK — ja feito, pulando"
    else
        if step_done "$name"; then
            log_warn "[$name] marker existia mas o probe reporta nao-feito — marker obsoleto removido, re-executando"
            clear_marker "$name"
        fi
        log_info "[$name] executando..."
        "$do_fn"
        if "$probe_fn"; then
            if ! step_done "$name"; then
                mark_done "$name"
            fi
            log_info "[$name] concluido"
        else
            die "[$name] do_fn terminou mas o probe ainda reporta nao-feito — sub-etapa inconsistente, veja $LOGFILE"
        fi
    fi
    CURRENT_STEP=""
}

# ---------------------------------------------------------------------------
# Particionamento (nomes de device e layout)
# ---------------------------------------------------------------------------

# part_dev <numero>: imprime o device da particao N do TARGET_DISK.
# Disco cujo nome termina em digito (nvme0n1, mmcblk0, loop0) ganha sufixo "p":
#   /dev/nvme0n1 -> /dev/nvme0n1p2 ; /dev/vda -> /dev/vda2 ; /dev/sda -> /dev/sda2
part_dev() {
    local n="$1"
    if [[ "$TARGET_DISK" =~ [0-9]$ ]]; then
        echo "${TARGET_DISK}p${n}"
    else
        echo "${TARGET_DISK}${n}"
    fi
}

# compute_partitions: define as globais EFI_PART, SWAP_PART e ROOT_PART a
# partir do layout fixo (1=ESP, 2=swap, 3=root). Chamar antes de qualquer uso.
compute_partitions() {
    EFI_PART="$(part_dev 1)"
    SWAP_PART="$(part_dev 2)"
    ROOT_PART="$(part_dev 3)"
}

# ---------------------------------------------------------------------------
# Preflight de hardware (roda ANTES de qualquer escrita no disco)
# ---------------------------------------------------------------------------
#
# Este instalador e hardware-targeted de proposito (i5-12600K + RTX 5060 Ti +
# 32 GiB), e os defaults de vars.sh sao dimensionados para esse alvo. Ate aqui
# nada confrontava esses defaults com a maquina real: MAKEOPTS e CFLAGS_ARCH
# eram validados so pela sintaxe, e nada distinguia bare metal de VM. O disco
# era destruido antes de qualquer verificacao de hardware.
#
# Politica de veredicto, por linha da tabela:
#   PASS  — o item bate com o alvo (ou e irrelevante para a corretude).
#   AVISO — divergencia de DIMENSIONAMENTO ou deteccao NAO CONFIAVEL (modelo
#           exato de placa/GPU, VRAM, jobs, RAM). O instalador continua: ele
#           precisa seguir utilizavel em hardware parecido e dentro de VM.
#   FALHA — divergencia CONFIAVEL que produz um sistema comprovadamente
#           quebrado. Aborta AQUI, com o disco ainda intacto.
#
# So tres coisas sao FATAIS, porque so estas tres sao ao mesmo tempo
# confiaveis de detectar e fatais de verdade:
#   1. firmware sem UEFI  -> o 05 instala GRUB x86_64-efi; em BIOS legado o
#      sistema instalado simplesmente nao da boot.
#   2. CPU nao-Intel      -> CFLAGS/USE, o fragmento de kernel (INTEL_IDLE,
#      INTEL_PSTATE, i915/ME) e o perfil sao todos Intel-especificos.
#   3. TARGET_DISK ausente / nao e disco inteiro -> nao ha onde instalar.
# Falta de GPU NVIDIA NAO e fatal: a receita QEMU do README nao tem GPU
# passada, precisa continuar validando todo o resto, e o 04 ja decide sozinho
# (NVIDIA_MODE=auto pula com aviso).
#
# ESTE PREFLIGHT NAO SUBSTITUI A VALIDACAO DE DISCO DO 00. Ele roda cedo e
# olha o hardware; quem valida o ESTADO do disco alvo (particoes montadas,
# swap ativa, layout GPT, holders em /sys) imediatamente antes de particionar
# continua sendo validate_vars + 00-partition.sh, e essa validacao e
# deliberadamente re-executada la, ja que o estado do disco pode mudar entre
# o preflight e o sgdisk (alguem monta uma particao, o udev roda, etc.).
#
# Preenche as globais PREFLIGHT_* para os chamadores (e para o log).

PREFLIGHT_DONE="no"
PREFLIGHT_VIRT="unknown"   # "none" (bare metal) ou o nome do hypervisor
PREFLIGHT_NPROC=""
PREFLIGHT_MEM_GIB=""
PREFLIGHT_GPU_NVIDIA="unknown"  # yes|no|unknown — fonte unica para 02 e 04

# Contadores/coletores da tabela, preenchidos por _pf_row.
PREFLIGHT_WARNS=0
PREFLIGHT_FAILS=0
_PF_FAIL_MSGS=()

# _pf_row <veredicto> <rotulo> <valor> [detalhe-para-a-mensagem-de-falha]
# Emite UMA linha da tabela do preflight e contabiliza o veredicto.
# Nao aborta: a tabela e impressa INTEIRA antes de qualquer die, para que o
# operador veja todos os problemas de uma vez e nao um por execucao.
_pf_row() {
    local verdict="$1" label="$2" value="$3" detail="${4:-}"
    # rotulo com padding fixo para a tabela ficar alinhada sem depender de
    # `column`, que nao esta garantido no minimal ISO
    printf '  %-7s %-14s %s\n' "[$verdict]" "$label" "$value"
    case "$verdict" in
        AVISO) PREFLIGHT_WARNS=$(( PREFLIGHT_WARNS + 1 )) ;;
        FALHA)
            PREFLIGHT_FAILS=$(( PREFLIGHT_FAILS + 1 ))
            _PF_FAIL_MSGS+=("$label: ${detail:-$value}")
            ;;
    esac
}

# _pf_first_line: imprime so a primeira linha da entrada, ja sem espacos das
# pontas. lspci/dmi podem devolver varias linhas (duas GPUs, dois controladores
# NVMe) e a tabela e de uma linha por item.
_pf_first_line() {
    local s
    IFS= read -r s || true
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s\n' "$s"
}

# _dmi_field <nome>: le /sys/class/dmi/id/<nome>. Sempre retorna 0; campo
# ausente ou ilegivel (o DMI exige root para alguns campos) vira string vazia,
# tratada pelo chamador como "desconhecido" (AVISO, nunca FALHA).
_dmi_field() {
    local v
    v="$(cat "/sys/class/dmi/id/$1" 2>/dev/null || true)"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s\n' "$v"
}

# _detect_virt: imprime "none" em bare metal ou o identificador do hypervisor.
# systemd-detect-virt sai com 1 quando nao ha virtualizacao — isso e SUCESSO
# semantico, nao erro, por isso o exit code e ignorado de proposito.
# Sem a ferramenta, cai no DMI (que os live ISOs sempre tem).
_detect_virt() {
    local v
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v="$(systemd-detect-virt 2>/dev/null || true)"
        [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
    fi
    # Fallback por DMI: QEMU/KVM, VMware, VirtualBox e Hyper-V se anunciam aqui
    v="$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null || true)"
    case "$v" in
        *QEMU*|*Bochs*)         echo "qemu"      ; return 0 ;;
        *VMware*)               echo "vmware"    ; return 0 ;;
        *VirtualBox*|*innotek*) echo "oracle"    ; return 0 ;;
        *Microsoft*Virtual*)    echo "microsoft" ; return 0 ;;
    esac
    # Ultimo recurso, sem systemd e sem DMI legivel: a flag 'hypervisor' do
    # CPUID. Ela NAO diz qual hypervisor e (por isso "vm-generica"), mas o
    # kernel so a expoe quando roda sob um — e o unico sinal que sobrevive a
    # um ISO minimo com /sys/class/dmi ausente.
    if grep -qm1 '^flags.*[[:space:]]hypervisor\([[:space:]]\|$\)' /proc/cpuinfo 2>/dev/null; then
        echo "vm-generica"
        return 0
    fi
    # DMI vazio E sem flag de hypervisor: nao da para afirmar bare metal.
    # "unknown" e o estado honesto e faz o preflight AVISAR em vez de PASSAR.
    [[ -n "$v" ]] && echo "none" || echo "unknown"
    return 0
}

# _cpu_is_emulated: 0 se /proc/cpuinfo denuncia uma CPU emulada generica —
# QEMU sem `-cpu host` reporta literalmente "QEMU Virtual CPU". E o sinal que
# torna CFLAGS_ARCH=native ativamente PERIGOSO (ver preflight_hardware).
_cpu_is_emulated() {
    grep -qiE 'model name.*(QEMU Virtual CPU|Common KVM processor|Common 32-bit KVM)' /proc/cpuinfo 2>/dev/null
}

# preflight_hardware: classifica a maquina, confronta com os defaults e loga um
# resumo. Deve rodar ANTES de confirm_destruction e de QUALQUER escrita no
# disco, para que a divergencia apareca enquanto abortar ainda e gratuito.
# Idempotente: so faz o trabalho na primeira chamada.
preflight_hardware() {
    [[ "$PREFLIGHT_DONE" == "no" ]] || return 0

    # Escape hatch: SKIP_HW_PREFLIGHT=yes pula a tabela INTEIRA, inclusive os
    # tres gates fatais. Existe para hardware novo que o instalador ainda nao
    # conhece; quem usa assume o risco de descobrir a incompatibilidade depois
    # do disco apagado. Nunca e o default.
    if [[ "${SKIP_HW_PREFLIGHT:-no}" == "yes" ]]; then
        log_warn "SKIP_HW_PREFLIGHT=yes — preflight de hardware PULADO por completo, inclusive as verificacoes fatais (UEFI, CPU Intel, disco alvo). Voce assume o risco de o hardware ser incompativel."
        PREFLIGHT_DONE="yes"
        return 0
    fi

    PREFLIGHT_VIRT="$(_detect_virt)"
    PREFLIGHT_NPROC="$(nproc 2>/dev/null || echo 0)"
    local mem_kb
    mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || true)"
    [[ -n "$mem_kb" ]] || mem_kb=0
    PREFLIGHT_MEM_GIB=$(( mem_kb / 1048576 ))

    local cpu_model cpu_vendor gpu_lines
    cpu_model="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    cpu_vendor="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    gpu_lines="$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display controller' || true)"

    # is_vm: "nao e bare metal comprovado". 'unknown' conta como VM para efeito
    # de RELAXAR verificacoes (fail-safe na direcao de nao bloquear), nunca
    # para relaxar os tres gates fatais, que valem em qualquer plataforma.
    local is_vm="no"
    [[ "$PREFLIGHT_VIRT" != "none" ]] && is_vm="yes"

    log_info "=================== PREFLIGHT DE HARDWARE ==================="
    log_info "Alvo do projeto: ASUS TUF GAMING B760M-E D4 | i5-12600K (6P+4E, 16t)"
    log_info "                 RTX 5060 Ti 16GB (Blackwell) | 32 GiB DDR4 | NVMe | UEFI"
    log_info "-------------------------------------------------------------"

    # --- perfil / plataforma ---
    local profile
    case "$PREFLIGHT_VIRT" in
        none)    profile="BARE-METAL" ;;
        unknown) profile="DESCONHECIDO" ;;
        *)       profile="VM ($PREFLIGHT_VIRT)" ;;
    esac
    if [[ "$profile" == "DESCONHECIDO" ]]; then
        _pf_row AVISO "plataforma" "$profile (sem systemd-detect-virt, sem DMI e sem flag hypervisor)"
    else
        _pf_row PASS "plataforma" "$profile"
    fi

    # --- CPU: vendor (FATAL), modelo, hibrida, threads ---
    # Vendor e o unico atributo de CPU confiavel o bastante para ser fatal:
    # vem do CPUID, nao de string de marketing.
    if [[ -z "$cpu_vendor" ]]; then
        # /proc/cpuinfo ilegivel e anomalia grave, mas nao e prova de AMD:
        # AVISO, para nao inventar uma falha a partir de ausencia de dado.
        _pf_row AVISO "cpu.vendor" "indeterminado (/proc/cpuinfo sem vendor_id)"
    elif [[ "$cpu_vendor" == "GenuineIntel" ]]; then
        _pf_row PASS "cpu.vendor" "$cpu_vendor"
    else
        _pf_row FALHA "cpu.vendor" "$cpu_vendor (esperado GenuineIntel)" \
            "CPU '$cpu_vendor' nao e Intel. Este instalador e Intel-especifico: CFLAGS/USE, o perfil e o fragmento de kernel (INTEL_IDLE, INTEL_PSTATE, drivers Intel =y sem initramfs) assumem Intel. Num AMD/outro o sistema instalado tende a nao dar boot ou perder gerenciamento de energia."
    fi

    # Modelo exato e ADVISORY por politica: string de marketing muda entre
    # revisoes de microcodigo e nunca pode ser requisito.
    if [[ -z "$cpu_model" ]]; then
        _pf_row AVISO "cpu.modelo" "ilegivel"
    elif [[ "$cpu_model" == *i5-12600K* ]]; then
        _pf_row PASS "cpu.modelo" "$cpu_model"
    else
        _pf_row AVISO "cpu.modelo" "$cpu_model (alvo: i5-12600K — outro modelo Intel deve funcionar)"
    fi

    # Hibrida P+E: os dois PMUs so existem em Alder Lake e sucessores. E o
    # sinal que confirma a familia SEM depender da string de modelo.
    if [[ -d /sys/devices/cpu_core && -d /sys/devices/cpu_atom ]]; then
        local p_cpus e_cpus
        p_cpus="$(cat /sys/devices/cpu_core/cpus 2>/dev/null || true)"
        e_cpus="$(cat /sys/devices/cpu_atom/cpus 2>/dev/null || true)"
        _pf_row PASS "cpu.hibrida" "P-cores=${p_cpus:-?} E-cores=${e_cpus:-?} (Alder Lake ou sucessor)"
    elif [[ "$is_vm" == "yes" ]]; then
        # QEMU nao expoe os PMUs hibridos nem com -cpu host: esperado, nao e
        # divergencia. Sem esta excecao a receita do README daria AVISO sempre.
        _pf_row PASS "cpu.hibrida" "nao exposta (normal em VM)"
    else
        _pf_row AVISO "cpu.hibrida" "sem /sys/devices/cpu_{core,atom} — CPU nao-hibrida ou pre-Alder Lake"
    fi

    if [[ "$PREFLIGHT_NPROC" -eq 16 ]]; then
        _pf_row PASS "cpu.threads" "$PREFLIGHT_NPROC"
    else
        _pf_row AVISO "cpu.threads" "$PREFLIGHT_NPROC (alvo: 16 — veja MAKEOPTS abaixo)"
    fi

    # --- Boot: UEFI (FATAL) + efivars ---
    # /sys/firmware/efi so existe quando o kernel EM EXECUCAO bootou por UEFI.
    # Se o live ISO bootou em BIOS legado, o grub-install --target=x86_64-efi
    # do 05 nao produz um sistema bootavel: e o gate mais barato do projeto.
    if [[ -d /sys/firmware/efi ]]; then
        # efivars e requisito SEPARADO: sem ele o efibootmgr do 05 nao grava a
        # entrada de boot na NVRAM. AVISO e nao FALHA porque GRUB_REMOVABLE=yes
        # (EFI/BOOT/BOOTX64.EFI) e um caminho legitimo que dispensa NVRAM.
        if [[ -d /sys/firmware/efi/efivars ]] && findmnt -rno TARGET /sys/firmware/efi/efivars >/dev/null 2>&1; then
            _pf_row PASS "boot.uefi" "UEFI ativo, efivars montado"
        else
            _pf_row AVISO "boot.uefi" "UEFI ativo, mas efivars NAO montado — o efibootmgr do 05 falharia; use GRUB_REMOVABLE=yes ou monte efivarfs"
        fi
    else
        _pf_row FALHA "boot.uefi" "/sys/firmware/efi ausente (bootado em BIOS legado)" \
            "o sistema em execucao NAO bootou por UEFI (/sys/firmware/efi nao existe). O 05 instala GRUB em x86_64-efi e o layout tem ESP: em BIOS legado o sistema instalado NAO daria boot. Rebote o live ISO em modo UEFI (desative CSM/Legacy no firmware)."
    fi

    # --- Placa-mae (tudo ADVISORY: DMI e string livre do fabricante) ---
    local board_vendor board_name bios_ver
    board_vendor="$(_dmi_field board_vendor)"
    board_name="$(_dmi_field board_name)"
    bios_ver="$(_dmi_field bios_version)"
    if [[ -z "$board_vendor$board_name" ]]; then
        _pf_row AVISO "placa" "DMI ilegivel (normal em VM ou sem root)"
    elif [[ "$board_name" == *"B760M-E"* ]]; then
        _pf_row PASS "placa" "$board_vendor $board_name (BIOS ${bios_ver:-?})"
    else
        _pf_row AVISO "placa" "$board_vendor $board_name (BIOS ${bios_ver:-?}) — alvo: TUF GAMING B760M-E D4"
    fi

    # --- GPU NVIDIA (NUNCA fatal: a VM do README nao tem GPU passada) ---
    #
    # O `|| true` NAO e cosmetico: sem ele o grep sai com 1 quando nao casa
    # nada (= nenhuma GPU NVIDIA), o pipefail propaga esse 1 para a atribuicao
    # e o set -e mata o preflight inteiro — exatamente no caso que as linhas
    # abaixo tratam como AVISO. Bug real, visto num smoke-test em QEMU: a
    # tabela morria entre 'placa' e 'gpu'. Mesmo padrao ja usado em gpu_lines.
    local nv_line=""
    nv_line="$(lspci -nn -d 10de: 2>/dev/null | grep -iE 'vga|3d controller|display controller' | _pf_first_line || true)"
    if [[ -n "$nv_line" ]]; then
        PREFLIGHT_GPU_NVIDIA="yes"
        # 2d04 = GB206 (RTX 5060 Ti). Match por device id quando legivel; a
        # AUSENCIA do match nunca reprova, so informa (GPUs novas mudam de id).
        if [[ "$nv_line" == *"10de:2d04"* || "$nv_line" == *GB20* ]]; then
            _pf_row PASS "gpu" "$nv_line"
        else
            _pf_row AVISO "gpu" "$nv_line (NVIDIA, mas nao identificada como Blackwell/RTX 5060 Ti — confira NVIDIA_MIN_VER=$NVIDIA_MIN_VER)"
        fi
    elif [[ -d /sys/bus/pci/devices ]] && [[ -n "$(ls -A /sys/bus/pci/devices 2>/dev/null || true)" ]]; then
        PREFLIGHT_GPU_NVIDIA="no"
        if [[ "${NVIDIA_MODE:-auto}" == "skip" ]]; then
            _pf_row PASS "gpu" "nenhuma NVIDIA (NVIDIA_MODE=skip — deliberado)"
        else
            # gpu_lines pode ter varias linhas; so a primeira entra na tabela
            local other_gpu
            other_gpu="$(printf '%s\n' "$gpu_lines" | _pf_first_line)"
            _pf_row AVISO "gpu" "nenhuma NVIDIA no barramento (${other_gpu:-nenhuma GPU vista}) — NAO e fatal; o 04 decide sozinho com NVIDIA_MODE=$NVIDIA_MODE"
        fi
    else
        # Sem barramento PCI enumeravel nao da para afirmar "sem GPU".
        PREFLIGHT_GPU_NVIDIA="unknown"
        _pf_row AVISO "gpu" "barramento PCI nao enumeravel — deteccao de GPU indeterminada"
    fi

    # --- Storage: controlador NVMe + disco alvo (FATAL se o alvo nao serve) ---
    local nvme_ctrl
    # `|| true`: numa VM com disco virtio nao existe controlador NVMe, o grep
    # sai 1 e o pipefail derrubaria o preflight. Ausencia e tratada abaixo.
    nvme_ctrl="$(lspci 2>/dev/null | grep -i 'non-volatile memory controller' | _pf_first_line || true)"
    if [[ -n "$nvme_ctrl" ]]; then
        _pf_row PASS "storage.nvme" "$nvme_ctrl"
    elif [[ "$is_vm" == "yes" ]]; then
        _pf_row PASS "storage.nvme" "nenhum controlador NVMe (normal em VM com virtio)"
    else
        _pf_row AVISO "storage.nvme" "nenhum controlador NVMe visto pelo lspci — o alvo do projeto e NVMe"
    fi

    # O disco alvo em si e FATAL: sem ele nao ha instalacao possivel.
    # ATENCAO: isto NAO substitui a validacao do 00 — aqui so se confere que o
    # device EXISTE e e um disco INTEIRO. O estado do disco (particoes
    # montadas, swap ativa, holders) e revalidado pelo 00 imediatamente antes
    # do particionamento, porque pode mudar entre este ponto e o sgdisk.
    if [[ ! -b "$TARGET_DISK" ]]; then
        _pf_row FALHA "storage.alvo" "$TARGET_DISK nao e um block device" \
            "TARGET_DISK='$TARGET_DISK' nao existe ou nao e um block device — nao ha onde instalar."
    elif [[ "$(lsblk -ndo TYPE "$TARGET_DISK" 2>/dev/null || true)" != "disk" ]]; then
        _pf_row FALHA "storage.alvo" "$TARGET_DISK nao e um disco inteiro" \
            "TARGET_DISK='$TARGET_DISK' nao e um disco inteiro (lsblk TYPE != disk) — passe o disco, nao uma particao."
    else
        _pf_row PASS "storage.alvo" "$(_disk_identity)"
    fi

    # --- RAM (ADVISORY: pouca memoria e lento, nao impossivel) ---
    if (( PREFLIGHT_MEM_GIB >= 30 )); then
        _pf_row PASS "memoria" "${PREFLIGHT_MEM_GIB} GiB"
    elif (( PREFLIGHT_MEM_GIB >= 8 )); then
        _pf_row AVISO "memoria" "${PREFLIGHT_MEM_GIB} GiB (alvo: 32 GiB — compilacao mais lenta)"
    else
        _pf_row AVISO "memoria" "${PREFLIGHT_MEM_GIB} GiB — compilar gcc/rust/nvidia-drivers com pouca RAM e lento e propenso a OOM"
    fi

    # --- Extras informativos (nunca reprovam nada) ---
    local scaling_drv
    scaling_drv="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || true)"
    _pf_row PASS "cpu.freq" "${scaling_drv:-nenhum driver de escala ativo (normal em VM)}"

    local iommu_state="desativado ou nao exposto"
    if [[ -d /sys/class/iommu ]] && [[ -n "$(ls -A /sys/class/iommu 2>/dev/null || true)" ]]; then
        iommu_state="ativo ($(ls -A /sys/class/iommu 2>/dev/null | tr '\n' ' '))"
    fi
    _pf_row PASS "iommu" "$iommu_state"

    local net_ctrl audio_ctrl
    # `|| true` nos dois: grep sem match sai 1 e o pipefail derrubaria o
    # preflight. Ausencia de rede/audio e tratada logo abaixo como AVISO.
    net_ctrl="$(lspci 2>/dev/null | grep -iE 'ethernet controller|network controller' | _pf_first_line || true)"
    audio_ctrl="$(lspci 2>/dev/null | grep -i 'audio device' | _pf_first_line || true)"
    if [[ -n "$net_ctrl" ]]; then
        _pf_row PASS "rede" "$net_ctrl"
    else
        # Sem rede o 01 nao baixa stage3 e o 03 nao sincroniza. Nao e fatal
        # aqui (pode haver USB tethering / wifi que o lspci nao classifica
        # assim), mas o operador precisa ver isto ANTES de apagar o disco.
        _pf_row AVISO "rede" "nenhum controlador de rede visto pelo lspci — o 01 (download do stage3) e o 03 (sync) EXIGEM rede"
    fi
    _pf_row PASS "audio" "${audio_ctrl:-nenhum controlador de audio visto}"

    log_info "-------------------------------------------------------------"

    # --- CFLAGS_ARCH: native numa CPU emulada e FALHA ---
    # Compilar -march=native contra uma CPU falsa produz, EM SILENCIO, binarios
    # que nao rodam no bare metal (SIGILL no primeiro boot, depois de horas de
    # compilacao). Nao ha como isto ser o que o usuario quis.
    if [[ "$CFLAGS_ARCH" == "native" ]] && _cpu_is_emulated; then
        _pf_row FALHA "cflags.arch" "native numa CPU emulada generica" \
            "CFLAGS_ARCH=native numa CPU EMULADA generica ('${cpu_model:-?}'): -march=native compilaria para a CPU falsa e os binarios NAO rodariam no bare metal. Rode o QEMU com '-cpu host', ou defina CFLAGS_ARCH para uma arquitetura explicita (ex.: CFLAGS_ARCH=alderlake)."
    elif [[ "$CFLAGS_ARCH" == "native" && "$is_vm" == "yes" ]]; then
        _pf_row AVISO "cflags.arch" "native em VM ($PREFLIGHT_VIRT) — CPU parece repassada (-cpu host); o build so serve se o bare metal de destino tiver a MESMA CPU"
    else
        _pf_row PASS "cflags.arch" "$CFLAGS_ARCH"
    fi

    # --- AVISO: -jN vs threads reais ---
    # MAKEOPTS ja passou pela validacao sintatica em validate_vars.
    # expansao de parametro em vez de `tr -d '-j'`: o tr interpretaria o "-j"
    # do argumento como uma OPCAO dele e falharia
    local jobs=""
    if [[ "$MAKEOPTS" =~ (^|[[:space:]])-j([0-9]+) ]]; then
        jobs="${BASH_REMATCH[2]}"
    fi
    local mk_msg="$MAKEOPTS"
    local mk_verdict="PASS"
    if [[ -n "$jobs" && "$PREFLIGHT_NPROC" -gt 0 ]]; then
        if (( jobs > PREFLIGHT_NPROC + 1 )); then
            mk_verdict="AVISO"
            mk_msg="$MAKEOPTS excede as $PREFLIGHT_NPROC threads desta maquina (max recomendado -j$(( PREFLIGHT_NPROC + 1 ))) — o build competiria consigo mesmo"
        # Regra pratica do Handbook: ~1 GiB de RAM (+swap) por job paralelo.
        # Aviso e nao aborto: a swap de 16GiB do layout costuma cobrir o excesso.
        elif (( PREFLIGHT_MEM_GIB > 0 && jobs > PREFLIGHT_MEM_GIB )); then
            mk_verdict="AVISO"
            mk_msg="$MAKEOPTS = $jobs jobs para ${PREFLIGHT_MEM_GIB} GiB de RAM (< 1 GiB/job) — risco de OOM em gcc/rust/chromium; reduza MAKEOPTS ou confie na swap de $SWAP_SIZE"
        fi
    fi
    _pf_row "$mk_verdict" "makeopts" "$mk_msg"

    # --- Veredicto ---
    log_info "-------------------------------------------------------------"
    log_info "Perfil detectado: $profile | ${PREFLIGHT_NPROC} threads | ${PREFLIGHT_MEM_GIB} GiB | GPU NVIDIA: $PREFLIGHT_GPU_NVIDIA"
    log_info "Resultado: $PREFLIGHT_FAILS falha(s), $PREFLIGHT_WARNS aviso(s)"
    log_info "============================================================="

    # HW_PREFLIGHT_STRICT=yes promove os avisos a falhas. E o modo para quem
    # quer garantir que esta MESMO no hardware alvo (nenhuma divergencia
    # tolerada) — util em CI e antes de uma instalacao de producao.
    if [[ "${HW_PREFLIGHT_STRICT:-no}" == "yes" && "$PREFLIGHT_WARNS" -gt 0 ]]; then
        die "preflight: $PREFLIGHT_WARNS aviso(s) com HW_PREFLIGHT_STRICT=yes — em modo estrito qualquer divergencia do hardware alvo aborta. Veja a tabela acima; para prosseguir mesmo assim, rode com HW_PREFLIGHT_STRICT=no."
    fi

    if (( PREFLIGHT_FAILS > 0 )); then
        local m
        for m in "${_PF_FAIL_MSGS[@]}"; do
            log_error "preflight: $m"
        done
        # Aborta AQUI: o disco alvo ainda esta intacto. Este e o ponto inteiro
        # do preflight — descobrir a incompatibilidade enquanto abortar e
        # gratuito, e nao depois do sgdisk --zap-all.
        die "preflight de hardware REPROVOU ($PREFLIGHT_FAILS falha(s)) — NADA foi escrito no disco. Corrija os itens [FALHA] acima. Se voce sabe o que esta fazendo e quer pular o preflight inteiro (por sua conta e risco), rode com SKIP_HW_PREFLIGHT=yes."
    fi

    PREFLIGHT_DONE="yes"
}

# _disk_identity: imprime uma identificacao ESTAVEL do disco alvo (modelo,
# serial e tamanho), nao so o nome de kernel — que e volatil entre boots
# (nvme0n1 e nvme1n1 podem trocar de lugar na proxima inicializacao).
# Nunca falha: o valor e informativo e entra em mensagens ao operador.
_disk_identity() {
    local info
    info="$(lsblk -ndo MODEL,SERIAL,SIZE "$TARGET_DISK" 2>/dev/null | tr -s ' ' || true)"
    # remove espacos das pontas sem depender de xargs
    info="${info#"${info%%[![:space:]]*}"}"
    info="${info%"${info##*[![:space:]]}"}"
    if [[ -n "$info" ]]; then
        printf '%s (%s)\n' "$TARGET_DISK" "$info"
    else
        printf '%s (modelo/serial indisponiveis)\n' "$TARGET_DISK"
    fi
}

# ---------------------------------------------------------------------------
# Confirmacao destrutiva
# ---------------------------------------------------------------------------

# confirm_destruction: mostra o estado atual do disco (lsblk + sgdisk -p) e
# exige que o usuario digite LITERALMENTE `ERASE $TARGET_DISK` para prosseguir.
# Bypass SOMENTE com AUTO_CONFIRM=yes (automacao em VM QEMU) e SOMENTE se nao
# estamos num sistema instalado — um `export AUTO_CONFIRM=yes` esquecido no
# ambiente de um host real nunca pode zapar disco sem prompt.
# Chamar apenas quando o probe do 00 disser que o layout NAO bate — layout ja
# correto nao re-pergunta.
confirm_destruction() {
    # Preflight ANTES do prompt: divergencia grave de hardware tem de aparecer
    # (e abortar) enquanto o disco ainda esta intacto. Idempotente.
    preflight_hardware

    log_warn "=================================================================="
    log_warn "ATENCAO: TODO o conteudo de $TARGET_DISK sera DESTRUIDO."
    # Identidade ESTAVEL do disco: o nome de kernel sozinho e volatil entre
    # boots (nvme0n1/nvme1n1 podem trocar), entao o operador precisa conferir
    # modelo e serial — que nao mudam — antes de digitar o ERASE.
    log_warn "Disco alvo: $(_disk_identity)"
    log_warn "CONFIRA o modelo e o serial acima: o nome '$TARGET_DISK' pode"
    log_warn "apontar para outro disco depois de um reboot."
    log_warn "Estado atual do disco:"
    log_warn "=================================================================="
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT "$TARGET_DISK" || true
    sgdisk -p "$TARGET_DISK" || true
    if [[ "$AUTO_CONFIRM" == "yes" ]]; then
        if _host_is_installed_system; then
            # AUTO_CONFIRM vazado do ambiente num host real e o pior cenario:
            # sem esta recusa o caminho ate o sgdisk --zap-all seria 100%
            # silencioso. Em sistema instalado, ERASE continua obrigatorio.
            log_warn "AUTO_CONFIRM=yes IGNORADO: o / atual vive num disco real (sistema instalado, nao live ISO) — confirmacao interativa continua obrigatoria"
        else
            log_warn "AUTO_CONFIRM=yes — pulando confirmacao interativa (modo VM/automacao)"
            return 0
        fi
    fi
    local expected="ERASE $TARGET_DISK" reply
    printf '\nPara confirmar, digite exatamente: %s\n> ' "$expected"
    # le do tty diretamente (stdout/stderr estao passando pelo tee do logging)
    IFS= read -r reply < /dev/tty || die "nao foi possivel ler confirmacao do terminal"
    [[ "$reply" == "$expected" ]] \
        || die "confirmacao incorreta (recebido: '$reply') — abortando sem tocar no disco"
    log_info "destruicao de $TARGET_DISK confirmada pelo usuario"
}

# ---------------------------------------------------------------------------
# Servicos (OpenRC vs systemd, chroot-safe)
# ---------------------------------------------------------------------------

# svc_enable <servico> [runlevel]: habilita o servico no boot, idempotente.
#   OpenRC : rc-update add <servico> <runlevel> (default: "default")
#   systemd: systemctl enable <servico> (so cria symlinks — funciona no chroot)
# O argumento runlevel so se aplica ao OpenRC (ex.: keymaps vai no "boot").
svc_enable() {
    local svc="$1" runlevel="${2:-default}"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        if rc-update show "$runlevel" 2>/dev/null | awk '{print $1}' | grep -qx "$svc"; then
            log_info "servico '$svc' ja esta no runlevel '$runlevel'"
        else
            rc-update add "$svc" "$runlevel"
            log_info "servico '$svc' adicionado ao runlevel '$runlevel'"
        fi
    else
        systemctl enable "$svc"
        log_info "servico '$svc' habilitado via systemctl"
    fi
}

# ---------------------------------------------------------------------------
# Mounts idempotentes (guardados por mountpoint -q)
# ---------------------------------------------------------------------------

# ensure_target_mounts: (fase live) monta root em $TARGET_ROOT, ESP em
# $TARGET_ROOT/efi e ativa o swap — cada acao guardada, seguro re-executar.
# E o que restaura a visibilidade do state dir apos reboot do live ISO.
ensure_target_mounts() {
    require_phase live
    compute_partitions
    [[ -b "$ROOT_PART" ]] || die "particao raiz $ROOT_PART nao existe — rode 00-partition.sh primeiro"

    mkdir -p "$TARGET_ROOT"
    if ! mountpoint -q "$TARGET_ROOT"; then
        mount "$ROOT_PART" "$TARGET_ROOT"
        log_info "montado $ROOT_PART em $TARGET_ROOT"
    fi

    mkdir -p "$TARGET_ROOT/efi"
    if ! mountpoint -q "$TARGET_ROOT/efi"; then
        mount "$EFI_PART" "$TARGET_ROOT/efi"
        log_info "montado $EFI_PART em $TARGET_ROOT/efi"
    fi

    # swapon guardado por /proc/swaps (mountpoint nao cobre swap).
    # _swap_is_active trata o erro do realpath explicitamente: com o realpath
    # inline, uma falha (componente de diretorio ausente, symlink stale) gerava
    # o padrao degenerado "^ " e a guarda virava no-op silencioso — swapon
    # rodaria por cima de uma swap ja ativa.
    if ! _swap_is_active "$SWAP_PART"; then
        swapon "$SWAP_PART"
        log_info "swap ativado em $SWAP_PART"
    fi
}

# ensure_chroot_mounts: (fase live) monta os pseudo-filesystems dentro do alvo
# e copia o resolv.conf — tudo idempotente, seguro chamar quantas vezes quiser.
# NAO faz o chroot em si (isso e papel do install.sh).
ensure_chroot_mounts() {
    require_phase live
    mountpoint -q "$TARGET_ROOT" || die "$TARGET_ROOT nao esta montado — chame ensure_target_mounts antes"

    if ! mountpoint -q "$TARGET_ROOT/proc"; then
        mount --types proc /proc "$TARGET_ROOT/proc"
        log_info "montado proc em $TARGET_ROOT/proc"
    fi

    local d
    for d in sys dev run; do
        if ! mountpoint -q "$TARGET_ROOT/$d"; then
            mount --rbind "/$d" "$TARGET_ROOT/$d"
            mount --make-rslave "$TARGET_ROOT/$d"
            log_info "montado (rbind+rslave) /$d em $TARGET_ROOT/$d"
        fi
    done

    # DNS dentro do chroot (cp -L resolve symlink do resolv.conf de live ISOs).
    # Guardado e degradado para aviso: sem isso o cp era o ULTIMO comando da
    # funcao, entao o retorno dela era o do cp — um live ISO sem
    # /etc/resolv.conf (ou com symlink quebrado) fazia o set -e do install.sh
    # matar a fase live com o alvo TODO montado e mensagem inutil.
    # A falta de DNS nao e fatal aqui: quem precisa de rede (01/03) falha
    # depois com mensagem propria e acionavel.
    if [[ -e /etc/resolv.conf ]]; then
        if cp -L /etc/resolv.conf "$TARGET_ROOT/etc/resolv.conf"; then
            log_info "resolv.conf copiado para $TARGET_ROOT/etc/resolv.conf"
        else
            log_warn "nao foi possivel copiar /etc/resolv.conf para o alvo — o DNS dentro do chroot pode nao funcionar"
        fi
    else
        log_warn "/etc/resolv.conf nao existe no live ISO (ou o symlink esta quebrado) — o DNS dentro do chroot pode nao funcionar"
    fi

    # return explicito: o valor de saida da funcao nao pode depender do ultimo
    # comando executado acima (ver comentario do bloco de resolv.conf)
    return 0
}
