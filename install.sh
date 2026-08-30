#!/usr/bin/env bash
# install.sh — orquestrador da instalacao automatizada do Gentoo.
#
# Fase live (sem --chroot, no minimal install ISO):
#   valida vars -> roda 00-02 -> prepara os mounts do chroot -> copia este
#   diretorio para $TARGET_ROOT/root/gentoo-install/ -> grava a sentinela de
#   fase -> chroot, onde ESTE MESMO script re-executa com --chroot.
#   Ao voltar com sucesso remove a sentinela e imprime as instrucoes finais
#   de umount + reboot. NUNCA reboota sozinho.
#
# Fase chroot (--chroot, invocado pelo proprio install.sh dentro do alvo):
#   roda 03-06.
#
# O vars.sh copiado para o alvo e reescrito com os valores EFETIVOS (incluindo
# overrides de ambiente tipo `TARGET_DISK=/dev/vda ./install.sh`) e e o UNICO
# canal de configuracao entre as fases: o chroot e invocado com `env -i`,
# nenhuma variavel de ambiente atravessa.
#
# Todas as etapas sao idempotentes (marker + probe funcional, probe e a
# autoridade): re-executar ./install.sh apos uma falha retoma da sub-etapa
# que falhou. Veja --help para as flags.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/vars.sh"   # SEMPRE vars.sh ANTES de lib.sh
source "$SCRIPT_DIR/lib.sh"

# Diretorio para onde os scripts sao copiados no alvo (visto da fase live).
# Dentro do chroot o mesmo diretorio e /root/gentoo-install (== SCRIPT_DIR).
TARGET_SCRIPTS_DIR_REL="/root/gentoo-install"

# Lista COMPLETA das variaveis de vars.sh — usada para gerar o vars.sh
# "assado" (com valores efetivos) que atravessa para o chroot.
ALL_VARS=(
    TARGET_DISK EFI_SIZE SWAP_SIZE ROOT_SIZE ROOT_FS TARGET_ROOT
    TARGET_HOSTNAME TIMEZONE KEYMAP LOCALE INIT_SYSTEM
    MAKEOPTS CFLAGS_ARCH
    MIRROR RELENG_KEY_FPR
    NVIDIA_MIN_VER NVIDIA_MODE
    USERNAME USER_GROUPS ROOT_PASSWORD_HASH USER_PASSWORD_HASH
    ENABLE_SSHD ENABLE_DHCP GRUB_REMOVABLE AUTO_CONFIRM UPDATE_WORLD
    ALLOW_INSTALLED_HOST
)

# ---------------------------------------------------------------------------
# Ajuda
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Uso: ./install.sh [OPCOES]

Sem opcoes (no live ISO): valida vars.sh, roda as etapas 00-02 (fase live),
entra no chroot do sistema alvo e roda as etapas 03-06 (fase chroot). Ao
final imprime as instrucoes de desmontagem e reboot — NUNCA reboota sozinho.
Re-executar apos uma falha retoma da sub-etapa que falhou (idempotente).

Opcoes:
  --chroot          (uso interno) fase chroot: roda as etapas 03-06. E o
                    proprio install.sh que se re-invoca assim dentro do chroot;
                    tambem funciona standalone para debug dentro do chroot.
  --from N          comeca na etapa N e segue ate a 06 (N = 0..6; vale nas
                    duas fases). Na fase live com N>=3, pula direto para o
                    chroot (as etapas 00-02 ja precisam ter sido executadas).
  --only N          roda somente a etapa N (N = 0..6; vale nas duas fases).
                    Na fase live com N>=3, entra no chroot so para essa etapa.
  --reset           apaga o diretorio de state (markers) no filesystem alvo e
                    segue com a instalacao. Como o probe funcional e a
                    autoridade, o que o estado REAL do sistema mostra como
                    feito continua sendo pulado — o reset descarta apenas os
                    markers (inclusive os com valor: flavor do stage3, hash do
                    kernel, versao/skip do nvidia).
  --repartition     SOMENTE junto com --reset: invalida o layout atual do
                    disco (renomeia o PARTLABEL da particao raiz — operacao de
                    metadados, nao destroi dados) para forcar o 00 a tratar o
                    layout como nao-feito. A destruicao real continua
                    centralizada no 00, que re-exige digitar 'ERASE <disco>'
                    (bypass so com AUTO_CONFIRM=yes).
  -h, --help        mostra esta ajuda e sai (nao valida nem toca em nada).

Etapas:
  00 particionamento+mkfs+mount   01 stage3          02 config do Portage
  03 sync/perfil/tz/locale/fstab  04 kernel+nvidia   05 GRUB (UEFI)
  06 hostname/usuarios/servicos

Combinacoes invalidas (erro com mensagem clara):
  --from com --only; --repartition sem --reset; --reset com --from/--only;
  --reset/--repartition na fase chroot; --from/--only N<3 na fase chroot.
EOF
}

# --help sai ANTES de logging/validacao — pode rodar em qualquer maquina,
# sem exigir live ISO nem disco alvo presente.
for _arg in "$@"; do
    case "$_arg" in
        -h|--help)
            usage
            exit 0
            ;;
    esac
done

# Pre-scan de --chroot apenas para nomear o log: o log do pai (live) e o do
# filho (chroot) apontariam para o MESMO arquivo fisico no alvo
# (var/log/gentoo-install/install.log) com dois tee simultaneos — nomes
# distintos evitam a colisao.
_log_name="install"
for _arg in "$@"; do
    if [[ "$_arg" == "--chroot" ]]; then
        _log_name="install-chroot"
    fi
done
init_logging "$_log_name"

# ---------------------------------------------------------------------------
# Parse de argumentos
# ---------------------------------------------------------------------------

CHROOT_MODE="no"
FROM_STEP=""
ONLY_STEP=""
DO_RESET="no"
DO_REPARTITION="no"

# _set_step <nome-da-var> <valor-cru>: valida e normaliza o numero da etapa
# (aceita "4" e "04") e grava na variavel indicada.
_set_step() {
    local var="$1" raw="${2:-}"
    if [[ ! "$raw" =~ ^0?[0-6]$ ]]; then
        die "valor de etapa invalido: '$raw' (esperado numero 0-6, ex.: --from 4). Veja --help"
    fi
    printf -v "$var" '%s' "$((10#$raw))"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --chroot)
                CHROOT_MODE="yes"
                ;;
            --from)
                if [[ $# -lt 2 ]]; then
                    die "--from exige o numero da etapa (0-6)"
                fi
                _set_step FROM_STEP "$2"
                shift
                ;;
            --from=*)
                _set_step FROM_STEP "${1#--from=}"
                ;;
            --only)
                if [[ $# -lt 2 ]]; then
                    die "--only exige o numero da etapa (0-6)"
                fi
                _set_step ONLY_STEP "$2"
                shift
                ;;
            --only=*)
                _set_step ONLY_STEP "${1#--only=}"
                ;;
            --reset)
                DO_RESET="yes"
                ;;
            --repartition)
                DO_REPARTITION="yes"
                ;;
            *)
                die "argumento desconhecido: '$1' — veja ./install.sh --help"
                ;;
        esac
        shift
    done

    # --- combinacoes invalidas ---
    if [[ -n "$FROM_STEP" && -n "$ONLY_STEP" ]]; then
        die "--from e --only sao mutuamente exclusivos"
    fi
    if [[ "$DO_REPARTITION" == "yes" && "$DO_RESET" == "no" ]]; then
        die "--repartition so vale junto com --reset (uso: ./install.sh --reset --repartition)"
    fi
    if [[ "$DO_RESET" == "yes" && ( -n "$FROM_STEP" || -n "$ONLY_STEP" ) ]]; then
        die "--reset nao combina com --from/--only (o reset recomeca a instalacao inteira)"
    fi
    if [[ "$CHROOT_MODE" == "yes" ]]; then
        if [[ "$DO_RESET" == "yes" || "$DO_REPARTITION" == "yes" ]]; then
            die "--reset/--repartition so valem na fase live (fora do chroot)"
        fi
        local s
        for s in "$FROM_STEP" "$ONLY_STEP"; do
            if [[ -n "$s" && "$s" -lt 3 ]]; then
                die "etapa $s e da fase live (00-02) — dentro do chroot so valem as etapas 3-6"
            fi
        done
    fi
}

parse_args "$@"

# Guarda de fase: --chroot exige a sentinela presente; sem --chroot exige live.
if [[ "$CHROOT_MODE" == "yes" ]]; then
    require_phase chroot
else
    require_phase live
fi
validate_vars

# ---------------------------------------------------------------------------
# Mapeamento etapa -> script
# ---------------------------------------------------------------------------

# step_script <N>: imprime o nome do script da etapa N.
step_script() {
    case "$1" in
        0) echo "00-partition.sh" ;;
        1) echo "01-stage3.sh" ;;
        2) echo "02-portage-config.sh" ;;
        3) echo "03-chroot-setup.sh" ;;
        4) echo "04-kernel.sh" ;;
        5) echo "05-bootloader.sh" ;;
        6) echo "06-users-services.sh" ;;
        *) die "etapa inexistente: '$1'" ;;
    esac
}

# run_script <arquivo>: executa um script de etapa como processo filho.
# Cada script tem seu proprio preludio (logging/fase/validacao) e run_steps
# idempotentes; se falhar, morremos com instrucao de retomada.
run_script() {
    local script="$1"
    CURRENT_STEP="$script"
    log_info ">>> executando $script"
    if ! "$SCRIPT_DIR/$script"; then
        die "etapa $script falhou — corrija o problema e re-execute ./install.sh (a instalacao retoma da sub-etapa que falhou; logs em \$TARGET_ROOT/var/log/gentoo-install/)"
    fi
    log_info "<<< $script concluido"
    CURRENT_STEP=""
}

# ---------------------------------------------------------------------------
# --reset / --repartition (fase live)
# ---------------------------------------------------------------------------

# do_reset: apaga o diretorio de state (markers) no filesystem alvo.
# Precisa enxergar o alvo montado; se as particoes nem existem, nao ha
# state dir nenhum e o reset e um no-op.
do_reset() {
    if ! mountpoint -q "$TARGET_ROOT"; then
        if [[ -b "$ROOT_PART" && -n "$(blkid -s TYPE -o value "$ROOT_PART" 2>/dev/null || true)" ]]; then
            ensure_target_mounts
        else
            log_info "--reset: particao raiz inexistente ou sem filesystem — nao ha state dir para apagar"
            return 0
        fi
    fi
    local dir
    dir="$(state_dir)"
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        log_info "--reset: state dir apagado ($dir)"
    else
        log_info "--reset: state dir inexistente ($dir) — nada a apagar"
    fi
}

# repartition_prep: forca o 00 a tratar o layout atual como nao-feito.
# Estrategia NAO destrutiva: renomeia o PARTLABEL da particao 3 (operacao
# somente de metadados GPT — nenhum dado e tocado). O probe 00-gpt exige o
# PARTLABEL exato, entao passa a reportar nao-feito e o do_gpt do 00 re-exige
# a confirmacao 'ERASE <disco>' ANTES de zapear/recriar — a destruicao real
# continua centralizada no 00. Se o usuario abortar la, nada foi perdido
# (PARTLABEL nao afeta o boot: o fstab usa UUID e o GRUB usa PARTUUID).
repartition_prep() {
    log_warn "--repartition: o layout atual de $TARGET_DISK sera tratado como invalido; o 00 vai re-exigir a confirmacao ERASE antes de destruir qualquer coisa"

    # o log pode estar dentro do alvo — solta o fd antes de desmontar
    detach_logging_to_tmp

    # desativa qualquer swap residual do disco alvo
    local dev mnt
    while read -r dev mnt; do
        if [[ "$mnt" == "[SWAP]" ]]; then
            swapoff "$dev"
            log_info "--repartition: swap desativado em $dev"
        fi
    done < <(lsblk -nrpo NAME,MOUNTPOINT "$TARGET_DISK")

    # desmonta o alvo inteiro (retry: o tee antigo pode levar um instante para
    # soltar o fd depois do detach_logging_to_tmp)
    if mountpoint -q "$TARGET_ROOT"; then
        local i ok="no"
        for i in 1 2 3 4 5; do
            if umount -R "$TARGET_ROOT" 2>/dev/null; then
                ok="yes"
                break
            fi
            sleep 1
        done
        if [[ "$ok" == "no" ]]; then
            die "nao foi possivel desmontar $TARGET_ROOT — feche o que estiver usando o alvo e tente de novo"
        fi
        log_info "--repartition: $TARGET_ROOT desmontado"
    fi

    # invalida o layout renomeando o PARTLABEL da particao raiz
    if sgdisk -i 3 "$TARGET_DISK" 2>/dev/null | grep -q "^Partition name: '${ROOT_PARTLABEL}'"; then
        sgdisk -c "3:${ROOT_PARTLABEL}-invalid" "$TARGET_DISK"
        log_info "--repartition: PARTLABEL da particao 3 renomeado para '${ROOT_PARTLABEL}-invalid' — o probe do 00 vai reportar layout nao-feito"
    else
        log_info "--repartition: o layout atual ja nao bate com o esperado — nada a invalidar, o 00 vai reparticionar de qualquer jeito"
    fi
}

# ---------------------------------------------------------------------------
# Preparacao e entrada no chroot (fase live)
# ---------------------------------------------------------------------------

# copy_scripts_to_target: copia este diretorio inteiro (scripts + lib + vars +
# kernel-fragment.config) para $TARGET_ROOT/root/gentoo-install/.
copy_scripts_to_target() {
    local dst="$TARGET_ROOT$TARGET_SCRIPTS_DIR_REL"
    if [[ "$SCRIPT_DIR" == "$dst" ]]; then
        # ja estamos rodando da copia dentro do alvo (re-execucao esquisita
        # mas valida) — nada a copiar por cima de si mesmo
        log_info "scripts ja estao em $dst (rodando da propria copia)"
    else
        mkdir -p "$dst"
        cp -a "$SCRIPT_DIR/." "$dst/"
        log_info "scripts copiados para $dst"
    fi
    chmod +x "$dst"/[0-9][0-9]-*.sh "$dst/install.sh"
}

# write_effective_vars: reescreve o vars.sh COPIADO com os valores efetivos
# das variaveis desta execucao (defaults + edicoes + overrides de ambiente).
# E este arquivo — e somente ele — que configura a fase chroot.
write_effective_vars() {
    local dst="$TARGET_ROOT$TARGET_SCRIPTS_DIR_REL/vars.sh" tmp v
    tmp="$dst.tmp"
    {
        echo '#!/usr/bin/env bash'
        echo '# vars.sh — GERADO pelo install.sh na fase live com os valores EFETIVOS'
        echo '# (defaults + edicoes + overrides de ambiente daquela execucao).'
        echo '# E o UNICO canal de configuracao entre as fases: o chroot e invocado'
        echo "# com env -i, nenhuma variavel de ambiente atravessa."
        echo "# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')"
        for v in "${ALL_VARS[@]}"; do
            printf '%s=%q\n' "$v" "${!v}"
        done
    } > "$tmp"
    mv "$tmp" "$dst"
    log_info "vars.sh efetivo gravado em $dst"
}

# enter_chroot [flags...]: prepara os mounts, copia scripts + vars efetivos,
# grava a sentinela de fase e entra no chroot re-invocando este script com
# --chroot (+ flags encaminhadas, ex.: --from 4 / --only 5). Ao voltar com
# sucesso remove a sentinela; em falha a sentinela FICA (re-execucao retoma).
enter_chroot() {
    local forward=("$@")

    # restaura/garante os mounts do alvo (idempotente; morre com instrucao
    # clara de rodar o 00 se as particoes nao existem)
    ensure_target_mounts

    # o chroot so faz sentido com o stage3 extraido
    if [[ ! -e "$TARGET_ROOT/etc/gentoo-release" ]]; then
        die "stage3 ausente em $TARGET_ROOT (etc/gentoo-release nao existe) — rode as etapas 00-02 antes (./install.sh sem --from/--only)"
    fi

    # pseudo-filesystems (proc/sys/dev/run) + resolv.conf — idempotente
    ensure_chroot_mounts

    copy_scripts_to_target
    write_effective_vars

    # sentinela de fase: dentro do chroot, current_phase passa a dizer "chroot"
    mkdir -p "$TARGET_ROOT$(dirname "$CHROOT_SENTINEL")"
    touch "$TARGET_ROOT$CHROOT_SENTINEL"

    log_info "entrando no chroot em $TARGET_ROOT (fase chroot: etapas ${forward[*]:-03-06})"
    # env -i: NENHUMA variavel de ambiente atravessa — a configuracao vem
    # exclusivamente do vars.sh efetivo copiado acima. HOME/TERM/PATH minimos
    # sao redefinidos (e o source /etc/profile reconfigura o resto).
    if ! chroot "$TARGET_ROOT" /usr/bin/env -i \
            HOME=/root \
            TERM="${TERM:-linux}" \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            /bin/bash -c 'source /etc/profile && exec /root/gentoo-install/install.sh --chroot "$@"' \
            install.sh "${forward[@]}"; then
        die "fase chroot falhou — veja os logs em $TARGET_ROOT/var/log/gentoo-install/ e re-execute ./install.sh (retoma da sub-etapa que falhou; a sentinela de fase foi mantida de proposito)"
    fi

    # sucesso: remove a sentinela (o alvo deixa de ser "fase chroot")
    rm -f "$TARGET_ROOT$CHROOT_SENTINEL"
    log_info "fase chroot concluida com sucesso; sentinela removida"
}

# cleanup_stage3_workdir: Handbook "Removing tarballs" (Finalizing) — apos a
# fase chroot concluir COM SUCESSO, o workdir do stage3 (tarball ~300MB, .asc,
# .sha256, keyring GNUPGHOME e a sentinela extract-started) nao serve mais.
# So e chamado no caminho feliz do fluxo completo: a sentinela extract-started
# some junto, o que so e seguro porque aqui a extracao ja terminou (e todas as
# etapas posteriores tambem). O 01 tolera a remocao num resume: com a arvore
# extraida e integra, probe_extract curto-circuita download/verificacao e nada
# e re-baixado.
cleanup_stage3_workdir() {
    local workdir="$TARGET_ROOT/var/tmp/gentoo-install/stage3"
    if [[ -d "$workdir" ]]; then
        rm -rf "$workdir"
        log_info "workdir do stage3 removido ($workdir) — tarball, artefatos de verificacao e keyring nao sao mais necessarios"
    fi
}

# print_final_instructions: instrucoes manuais de finalizacao.
# Este script NUNCA desmonta o alvo nem reboota sozinho.
print_final_instructions() {
    log_info "=================================================================="
    log_info "Instalacao concluida!"
    log_info "=================================================================="
    log_info "Para finalizar, execute MANUALMENTE (este script NUNCA reboota sozinho):"
    log_info ""
    log_info "    cd /"
    log_info "    swapoff $SWAP_PART"
    log_info "    umount -R $TARGET_ROOT"
    log_info "    reboot"
    log_info ""
    log_info "Apos o reboot, remova a midia do live ISO. Logs completos da"
    log_info "instalacao ficam em /var/log/gentoo-install/ no sistema instalado."
}

# ---------------------------------------------------------------------------
# Fase live: 00-02 + entrada no chroot
# ---------------------------------------------------------------------------

main_live() {
    compute_partitions

    if [[ "$DO_RESET" == "yes" ]]; then
        do_reset
    fi
    if [[ "$DO_REPARTITION" == "yes" ]]; then
        repartition_prep
    fi

    # --only N: roda so a etapa pedida (entrando no chroot se N>=3) e para.
    if [[ -n "$ONLY_STEP" ]]; then
        if [[ "$ONLY_STEP" -le 2 ]]; then
            run_script "$(step_script "$ONLY_STEP")"
        else
            enter_chroot --only "$ONLY_STEP"
        fi
        attach_log_to_target
        log_info "--only $ONLY_STEP concluido. O alvo continua montado em $TARGET_ROOT; nada foi desmontado."
        return 0
    fi

    # execucao sequencial: etapas live de $start ate 02, depois chroot
    local start="${FROM_STEP:-0}" n
    for ((n = start; n <= 2; n++)); do
        run_script "$(step_script "$n")"
    done

    # encaminha --from para a fase chroot apenas quando a live foi pulada
    # inteira (--from N>=3); com N<=2 o chroot roda 03-06 completo
    local fwd=()
    if [[ "$start" -ge 3 ]]; then
        fwd=(--from "$start")
    fi
    enter_chroot "${fwd[@]}"

    # fase chroot concluida com sucesso — limpeza do Handbook "Removing tarballs"
    cleanup_stage3_workdir

    attach_log_to_target
    print_final_instructions
}

# ---------------------------------------------------------------------------
# Fase chroot: 03-06
# ---------------------------------------------------------------------------

main_chroot() {
    local steps=() n
    if [[ -n "$ONLY_STEP" ]]; then
        steps=("$ONLY_STEP")
    else
        local start=3
        if [[ -n "$FROM_STEP" ]]; then
            start="$FROM_STEP"
        fi
        for ((n = start; n <= 6; n++)); do
            steps+=("$n")
        done
    fi

    for n in "${steps[@]}"; do
        run_script "$(step_script "$n")"
    done
    log_info "fase chroot: todas as etapas pedidas concluidas"
}

# ---------------------------------------------------------------------------
# Execucao
# ---------------------------------------------------------------------------

if [[ "$CHROOT_MODE" == "yes" ]]; then
    main_chroot
else
    main_live
fi
