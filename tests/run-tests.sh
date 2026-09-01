#!/usr/bin/env bash
#
# run-tests.sh — roda a suite de testes do host.
#
# Nenhum teste aqui executa o instalador, particiona, monta ou baixa nada.
# Sao verificacoes estaticas e chamadas a funcoes read-only (validate_vars).
#
#     ./tests/run-tests.sh
#
# O smoke-test de verdade (QEMU/OVMF, boot, build de kernel) NAO faz parte
# desta suite: ele exige uma VM e leva horas. Ver README, secao QEMU, e
# tests/run-in-qemu-guest.sh.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"

total_fail=0

# --- bash -n em tudo -------------------------------------------------------
printf '\n== bash -n ==\n'
n_ok=0 n_bad=0
for f in "$REPO_DIR"/*.sh "$SCRIPT_DIR"/*.sh "$REPO_DIR"/desktop/*.sh; do
    [[ -e "$f" ]] || continue
    if bash -n "$f" 2>/dev/null; then
        n_ok=$((n_ok + 1))
    else
        printf '  FAIL  %s\n' "${f#"$REPO_DIR"/}"
        bash -n "$f" 2>&1 | sed 's/^/        /'
        n_bad=$((n_bad + 1))
    fi
done
printf '  -> %d pass, %d fail\n' "$n_ok" "$n_bad"
(( n_bad > 0 )) && total_fail=$((total_fail + 1))

# --- ShellCheck (opcional: binario local, senao container) -----------------
printf '\n== ShellCheck ==\n'
if command -v shellcheck > /dev/null 2>&1; then
    if (cd "$REPO_DIR" && shellcheck -s bash ./*.sh tests/*.sh desktop/*.sh); then
        printf '  -> limpo\n'
    else
        printf '  -> ShellCheck reportou achados (revise; nem todo achado e bug)\n'
    fi
elif command -v podman > /dev/null 2>&1; then
    # Repo montado READ-ONLY: o container nao pode alterar o projeto.
    if podman run --rm -v "$REPO_DIR:/mnt:ro,Z" -w /mnt \
         docker.io/koalaman/shellcheck:stable -s bash ./*.sh tests/*.sh desktop/*.sh; then
        printf '  -> limpo\n'
    else
        printf '  -> ShellCheck reportou achados (revise; nem todo achado e bug)\n'
    fi
else
    printf '  SKIP  shellcheck e podman ausentes — NAO EXECUTADO\n'
fi

# --- Testes unitarios ------------------------------------------------------
for t in "$SCRIPT_DIR"/test-*.sh; do
    [[ -x "$t" ]] || continue
    "$t" || total_fail=$((total_fail + 1))
done

printf '\n'
if (( total_fail > 0 )); then
    printf 'RESULTADO: %d grupo(s) de teste com falha\n\n' "$total_fail"
    exit 1
fi
printf 'RESULTADO: todos os testes do host passaram\n'
printf '(o smoke-test QEMU nao esta incluso — ver README)\n\n'
