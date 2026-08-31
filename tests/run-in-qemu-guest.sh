#!/usr/bin/env bash
#
# run-in-qemu-guest.sh — roda o instalador DENTRO da VM QEMU/OVMF de teste.
#
# Motivo de existir: a receita do smoke-test vivia so em prosa no README, e o
# TARGET_DISK=/dev/vda dependia de o operador digitar certo. Esquecer fazia o
# instalador abortar com "TARGET_DISK=/dev/nvme0n1 nao existe" — que e a
# resposta CORRETA (ele nao adivinha disco), mas o teste nao rodava.
#
# Uso, ja dentro do live ISO da VM:
#     cd /root/gentoo-install
#     ./tests/run-in-qemu-guest.sh            # fluxo completo
#     ./tests/run-in-qemu-guest.sh --only 0   # repassa flags ao install.sh
#
# Este script NAO afrouxa nenhuma guarda: ele apenas fornece o perfil da VM ao
# install.sh, que continua rodando validate_vars, preflight_hardware e o
# confirm_destruction inteiro. Ele ADICIONA uma guarda propria (recusa rodar
# fora de VM), porque o perfil carrega AUTO_CONFIRM=yes.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
PROFILE="$SCRIPT_DIR/qemu-profile.env"

die() { printf '\n[run-in-qemu-guest] ERRO: %s\n\n' "$*" >&2; exit 1; }
info() { printf '[run-in-qemu-guest] %s\n' "$*"; }

[[ -r "$PROFILE" ]] || die "perfil nao encontrado: $PROFILE"
[[ -x "$REPO_DIR/install.sh" ]] || die "install.sh nao encontrado ou nao executavel em $REPO_DIR"

# ---------------------------------------------------------------------------
# Guarda 1: e VM mesmo?
#
# O perfil carrega AUTO_CONFIRM=yes, que pula o prompt ERASE. Rodar isso numa
# maquina real que por acaso tenha /dev/vda (host com virtio, container, blade)
# apagaria o disco sem perguntar. Deteccao positiva obrigatoria: na duvida,
# recusa. Nao uso o _detect_virt do lib.sh de proposito — esta guarda tem que
# valer ANTES de qualquer coisa do instalador ser carregada.
# ---------------------------------------------------------------------------
is_vm() {
    if command -v systemd-detect-virt > /dev/null 2>&1; then
        # sai 0 quando virtualizado, 1 em bare metal
        systemd-detect-virt --quiet && return 0
    fi
    local f
    for f in /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor; do
        [[ -r "$f" ]] || continue
        grep -qiE 'qemu|kvm|bochs|virtualbox|vmware|virtual machine' "$f" && return 0
    done
    grep -qw hypervisor /proc/cpuinfo 2>/dev/null && return 0
    return 1
}

if ! is_vm; then
    die "nenhuma virtualizacao detectada — este script SO roda dentro da VM de teste.
     Ele carrega AUTO_CONFIRM=yes (pula o prompt ERASE) e um disco alvo fixo.
     Em hardware real, rode ./install.sh direto, com TARGET_DISK explicito e
     sem AUTO_CONFIRM."
fi

# ---------------------------------------------------------------------------
# Perfil da VM
# ---------------------------------------------------------------------------
set -a
# shellcheck source=tests/qemu-profile.env
source "$PROFILE"
set +a

[[ -n "${TARGET_DISK:-}" ]] || die "qemu-profile.env nao definiu TARGET_DISK"

# MAKEOPTS derivado das vCPUs desta VM (o -j17 do bare metal derrubaria uma VM
# menor). Respeita override explicito do ambiente.
if [[ -z "${MAKEOPTS:-}" ]]; then
    MAKEOPTS="-j$(( $(nproc) + 1 ))"
    export MAKEOPTS
fi

# ---------------------------------------------------------------------------
# Guarda 2: o disco do perfil precisa existir e ser um disco INTEIRO.
#
# Redundante com validate_vars de proposito: erra aqui, com mensagem que explica
# a receita do QEMU, em vez de erra la com mensagem generica.
# ---------------------------------------------------------------------------
[[ -b "$TARGET_DISK" ]] || die "$TARGET_DISK nao existe ou nao e block device dentro desta VM.
     Confira que o QEMU foi iniciado com '-drive file=...,if=virtio,format=qcow2'.
     Com if=ide/sata o disco vira /dev/sda e o perfil precisa ser ajustado —
     edite tests/qemu-profile.env, NAO passe um disco na linha de comando."

if [[ "$(lsblk -ndo TYPE "$TARGET_DISK" 2>/dev/null)" != "disk" ]]; then
    die "$TARGET_DISK nao e um disco inteiro (lsblk TYPE != disk)"
fi

cat <<EOF

=========================================================
 Smoke-test QEMU — perfil da VM
=========================================================
 TARGET_DISK    $TARGET_DISK   (explicito, via qemu-profile.env)
 AUTO_CONFIRM   ${AUTO_CONFIRM:-no}
 NVIDIA_MODE    ${NVIDIA_MODE:-auto}   (build only: QEMU nao valida runtime)
 MAKEOPTS       $MAKEOPTS
 vCPUs          $(nproc)
=========================================================
 O DISCO $TARGET_DISK SERA APAGADO.
=========================================================

EOF

info "delegando para install.sh — todas as guardas do instalador continuam ativas"
exec "$REPO_DIR/install.sh" "$@"
