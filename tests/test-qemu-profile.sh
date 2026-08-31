#!/usr/bin/env bash
#
# test-qemu-profile.sh — prova que o perfil QEMU usa /dev/vda EXPLICITAMENTE,
# que o default de producao continua NVMe, e que nao existe autodeteccao nem
# fallback de disco em lugar nenhum.
#
# Roda no host, sem VM, sem root. Nao executa o instalador.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
PROFILE="$SCRIPT_DIR/qemu-profile.env"
RUNNER="$SCRIPT_DIR/run-in-qemu-guest.sh"

pass=0 fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$((fail + 1)); }

printf '\n== test-qemu-profile ==\n'

# --- 1. O perfil QEMU declara /dev/vda -------------------------------------
if [[ -r "$PROFILE" ]]; then
    ok "tests/qemu-profile.env existe"
    # O subshell e PROPOSITAL: zeramos TARGET_DISK e lemos o perfil isolados,
    # para o valor lido ser o do arquivo e nao vazar para o resto do teste.
    # SC2030 avisa exatamente sobre esse isolamento, que aqui e o objetivo.
    # shellcheck source=tests/qemu-profile.env disable=SC2030
    disk="$(TARGET_DISK=""; set -a; source "$PROFILE"; set +a; printf '%s' "${TARGET_DISK:-}")"
    if [[ "$disk" == "/dev/vda" ]]; then
        ok "perfil QEMU define TARGET_DISK=/dev/vda"
    else
        no "perfil QEMU deveria definir TARGET_DISK=/dev/vda" "encontrado: '${disk:-vazio}'"
    fi
else
    no "tests/qemu-profile.env nao existe"
fi

# --- 2. O default de producao NAO foi trocado para acomodar a VM -----------
prod_disk="$(set -a; source "$REPO_DIR/vars.sh"; set +a; printf '%s' "$TARGET_DISK")"
if [[ "$prod_disk" == "/dev/nvme0n1" ]]; then
    ok "vars.sh mantem o default de producao /dev/nvme0n1 (NVMe da maquina de referencia)"
else
    no "default de producao em vars.sh mudou" "esperado /dev/nvme0n1, encontrado '$prod_disk'"
fi

# --- 3. O runner da VM consome o perfil (fonte unica) ----------------------
if [[ -x "$RUNNER" ]]; then
    ok "tests/run-in-qemu-guest.sh existe e e executavel"
    if grep -q 'qemu-profile.env' "$RUNNER"; then
        ok "runner da VM le o TARGET_DISK do perfil, nao de uma copia hardcoded"
    else
        no "runner da VM nao faz source de qemu-profile.env"
    fi
    if grep -qE 'systemd-detect-virt|hypervisor' "$RUNNER"; then
        ok "runner da VM exige deteccao de virtualizacao antes de rodar (carrega AUTO_CONFIRM=yes)"
    else
        no "runner da VM nao tem guarda de virtualizacao, mas carrega AUTO_CONFIRM=yes"
    fi
else
    no "tests/run-in-qemu-guest.sh ausente ou nao executavel"
fi

# --- 4. Nenhuma autodeteccao de disco no instalador ------------------------
# O instalador NUNCA pode escolher disco sozinho. Procuramos atribuicao de
# TARGET_DISK a partir da saida de ferramentas de enumeracao de bloco.
auto="$(grep -nE 'TARGET_DISK=.*\$\((lsblk|blkid|find|ls)\b' \
         "$REPO_DIR"/*.sh 2>/dev/null || true)"
if [[ -z "$auto" ]]; then
    ok "nenhum TARGET_DISK derivado de lsblk/blkid/find/ls nos scripts"
else
    no "possivel autodeteccao de disco" "$auto"
fi

# --- 5. Nenhum fallback nvme -> vda ---------------------------------------
# Um fallback "se nvme0n1 nao existir, usa vda" e perigoso no hardware real:
# transforma um abort seguro em escolha silenciosa de outro disco.
# Comentarios sao ignorados: a doc legitimamente cita os dois discos lado a
# lado ("bare metal NVMe: /dev/nvme0n1 — VM: /dev/vda"). O que nao pode existir
# e CODIGO relacionando os dois.
fb="$(grep -nE '(vda.*nvme|nvme.*vda)' "$REPO_DIR"/*.sh 2>/dev/null \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [[ -z "$fb" ]]; then
    ok "nenhum fallback entre nvme0n1 e vda nos scripts de producao"
else
    no "possivel fallback de disco nos scripts" "$fb"
fi

# --- 6. A doc do smoke-test passa o disco explicitamente -------------------
if grep -q 'TARGET_DISK=/dev/vda' "$REPO_DIR/README.md"; then
    ok "README documenta TARGET_DISK=/dev/vda para o ambiente QEMU"
else
    no "README nao documenta TARGET_DISK=/dev/vda"
fi

printf '  -> %d pass, %d fail\n' "$pass" "$fail"
exit $(( fail > 0 ? 1 : 0 ))
