#!/usr/bin/env bash
#
# test-target-disk-required.sh — prova que um TARGET_DISK ausente/invalido causa
# FALHA DURA, e nunca uma escolha silenciosa de outro disco.
#
# Este e o teste de regressao do comportamento que o smoke-test QEMU exercitou
# na pratica: com TARGET_DISK=/dev/nvme0n1 numa VM que so tem /dev/vda, o
# instalador abortou. Isso e um PASS de seguranca e precisa continuar valendo.
#
# Chama apenas validate_vars, que e read-only. NAO executa o instalador, nao
# particiona, nao monta nada. Roda no host, sem root.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"

pass=0 fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$((fail + 1)); }

# Roda validate_vars num shell isolado com TARGET_DISK=$1. Ecoa o exit code e a
# saida. O subshell impede que qualquer variavel vaze para este processo.
run_validate() {
    local disk="$1" out rc
    out="$(TARGET_DISK="$disk" bash -c '
        source "$1/vars.sh"
        source "$1/lib.sh"
        validate_vars
    ' _ "$REPO_DIR" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    return $rc
}

# Espera falha (exit != 0) e, opcionalmente, uma substring na mensagem.
expect_fail() {
    local desc="$1" disk="$2" needle="${3:-}" out rc
    out="$(run_validate "$disk")"; rc=$?
    if (( rc == 0 )); then
        no "$desc" "validate_vars ACEITOU '$disk' (exit 0) — deveria abortar"
        return
    fi
    if [[ -n "$needle" ]] && ! grep -qF "$needle" <<< "$out"; then
        no "$desc" "abortou (exit $rc), mas sem a mensagem esperada '$needle'. Saida: $(tail -1 <<< "$out")"
        return
    fi
    ok "$desc (exit $rc)"
}

printf '\n== test-target-disk-required ==\n'

# --- Disco inexistente: exatamente o caso do smoke-test QEMU ---------------
expect_fail "disco inexistente aborta" \
    "/dev/nao-existe-em-lugar-nenhum" "nao existe ou nao pode ser resolvido"

# Mesmo caso, com o nome real que falhou na VM (regressao literal).
expect_fail "TARGET_DISK=/dev/nvme0n1 aborta quando o disco nao existe (caso da VM)" \
    "/dev/nvme0n1-inexistente-para-teste" "nao existe"

# --- TARGET_DISK vazio -----------------------------------------------------
expect_fail "TARGET_DISK vazio aborta" ""

# --- Nao-block-devices -----------------------------------------------------
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT
expect_fail "arquivo comum nao e aceito como disco" "$tmpfile"

# /dev/null e char device, nao block device.
expect_fail "char device (/dev/null) nao e aceito como disco" "/dev/null"

# --- Diretorio -------------------------------------------------------------
expect_fail "diretorio nao e aceito como disco" "/tmp"

# --- E o inverso: a falha NAO pode virar escolha de outro disco ------------
# A propriedade que importa: diante de um disco invalido, o instalador aborta
# SEM eleger nenhum disco real da maquina como substituto. Verificamos que
# nenhum nome de disco existente neste host aparece na saida do erro.
#
# (Nao da para inspecionar $TARGET_DISK depois: validate_vars chama die, que
# encerra o shell. E a canonicalizacao de symlinks reescreve TARGET_DISK
# legitimamente, entao "o valor nao mudou" nem seria a asercao correta.)
out="$(run_validate "/dev/nao-existe-em-lugar-nenhum" 2>&1)"
host_disks="$(lsblk -ndo NAME --nodeps 2>/dev/null || true)"
leaked=""
for d in $host_disks; do
    grep -qF "/dev/$d" <<< "$out" && leaked="$leaked /dev/$d"
done
if [[ -z "$leaked" ]]; then
    ok "abort nao menciona nenhum disco real do host (${host_disks//$'\n'/ }) — nenhum substituto eleito"
else
    no "a saida do erro menciona disco(s) real(is) do host:$leaked" "$out"
fi

# A mensagem tem que nomear EXATAMENTE o que o operador pediu, para ele
# entender que a escolha continua sendo dele.
if grep -qF "/dev/nao-existe-em-lugar-nenhum" <<< "$out"; then
    ok "a mensagem de erro nomeia o disco informado pelo operador"
else
    no "a mensagem de erro nao cita o TARGET_DISK informado" "$out"
fi

printf '  -> %d pass, %d fail\n' "$pass" "$fail"
exit $(( fail > 0 ? 1 : 0 ))
