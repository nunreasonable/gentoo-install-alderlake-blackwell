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
    # tee -a: re-execucoes do mesmo script acumulam no mesmo log
    exec > >(tee -a "$LOGFILE") 2>&1
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
# standalone do 00): o tee de init_logging pode estar segurando um fd aberto
# dentro de $TARGET_ROOT, o que faria o umount -R falhar com EBUSY.
# No-op se o log ja esta fora do alvo. Depois do re-mount,
# attach_log_to_target anexa a copia integral ao alvo.
detach_logging_to_tmp() {
    case "$LOGFILE" in
        "$TARGET_ROOT"/*)
            local newdir="/tmp/gentoo-install" newlog
            mkdir -p "$newdir"
            newlog="$newdir/$(basename "$LOGFILE")"
            # preserva no novo log o que ja foi logado nesta execucao
            cat "$LOGFILE" >> "$newlog" 2>/dev/null || true
            exec > >(tee -a "$newlog") 2>&1
            LOGFILE="$newlog"
            log_info "logging re-apontado para $LOGFILE (o alvo sera desmontado)"
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

# validate_vars: validacoes fatais de TODAS as variaveis de vars.sh.
# Chamar em todo script, logo depois de init_logging/require_phase.
validate_vars() {
    local size_re='^[0-9]+(MiB|GiB)$'

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
        # SWAP_PART do NOSSO layout (particao 2, ativada pelo 00-mount) —
        # qualquer outra swap no disco alvo e forte indicio de maquina/disco
        # errado e bloqueia igual a um mount estranho.
        local dev mnt our_swap
        our_swap="$(realpath -m "$(part_dev 2)")"
        while read -r dev mnt; do
            [[ -n "$mnt" ]] || continue
            if [[ "$mnt" == "[SWAP]" ]]; then
                [[ "$(realpath -m "$dev")" == "$our_swap" ]] \
                    || die "particao $dev de TARGET_DISK esta ativa como swap e NAO e a swap do nosso layout ($(part_dev 2)) — rode 'swapoff $dev' antes de continuar"
                continue
            fi
            [[ "$mnt" == "$TARGET_ROOT" || "$mnt" == "$TARGET_ROOT"/* ]] \
                || die "particao $dev de TARGET_DISK esta montada em '$mnt' (fora de $TARGET_ROOT) — desmonte antes de continuar"
        done < <(lsblk -nrpo NAME,MOUNTPOINT "$TARGET_DISK")
    fi

    # --- tamanhos ---
    [[ "$EFI_SIZE" =~ $size_re ]] \
        || die "EFI_SIZE='$EFI_SIZE' invalido (esperado <numero>MiB ou <numero>GiB)"
    [[ "$SWAP_SIZE" =~ $size_re ]] \
        || die "SWAP_SIZE='$SWAP_SIZE' invalido (esperado <numero>MiB ou <numero>GiB)"
    [[ -z "$ROOT_SIZE" || "$ROOT_SIZE" =~ $size_re ]] \
        || die "ROOT_SIZE='$ROOT_SIZE' invalido (vazio = resto do disco, ou <numero>MiB/GiB)"

    # --- enums ---
    [[ "$ROOT_FS" == "ext4" || "$ROOT_FS" == "xfs" ]] \
        || die "ROOT_FS='$ROOT_FS' invalido (ext4|xfs)"
    [[ "$INIT_SYSTEM" == "openrc" || "$INIT_SYSTEM" == "systemd" ]] \
        || die "INIT_SYSTEM='$INIT_SYSTEM' invalido (openrc|systemd)"
    [[ "$NVIDIA_MODE" == "auto" || "$NVIDIA_MODE" == "force" || "$NVIDIA_MODE" == "skip" ]] \
        || die "NVIDIA_MODE='$NVIDIA_MODE' invalido (auto|force|skip)"
    local var
    for var in ENABLE_SSHD ENABLE_DHCP GRUB_REMOVABLE AUTO_CONFIRM UPDATE_WORLD ALLOW_INSTALLED_HOST; do
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
    [[ "$TARGET_ROOT" == /* && "$TARGET_ROOT" != "/" ]] \
        || die "TARGET_ROOT='$TARGET_ROOT' invalido (caminho absoluto != /)"
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
    log_warn "=================================================================="
    log_warn "ATENCAO: TODO o conteudo de $TARGET_DISK sera DESTRUIDO."
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

    # swapon guardado por /proc/swaps (mountpoint nao cobre swap)
    if ! grep -q "^$(realpath "$SWAP_PART") " /proc/swaps; then
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

    # DNS dentro do chroot (cp -L resolve symlink do resolv.conf de live ISOs)
    cp -L /etc/resolv.conf "$TARGET_ROOT/etc/resolv.conf"
}
