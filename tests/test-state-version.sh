#!/usr/bin/env bash
#
# test-state-version.sh — o state carrega a identidade do installer que o
# produziu (schema + commit), e o resume reage de forma diferenciada:
# mesmo commit -> silencio; commit diferente -> aviso; schema diferente ->
# aborta; state corrompido/ilegivel -> aborta (fail-closed).
#
# Nenhum caso pode ser DESTRUTIVO: state_identity_check nunca apaga state.

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

printf '\n== test-state-version ==\n'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Roda state_identity_check com TARGET_ROOT apontando para uma arvore
# temporaria (fase live: state_dir = $TARGET_ROOT/var/lib/gentoo-install/state).
# Ecoa saida; devolve o exit code em EXIT= na ultima linha.
run_check() {
    local root="$1"
    TARGET_ROOT="$root" lib_eval '
        state_identity_check
        printf "EXIT=%s\n" "$?"
    '
}

state_file() { printf '%s/var/lib/gentoo-install/state/.installer\n' "$1"; }
exit_of()    { sed -n 's/^EXIT=//p' <<< "$1" | tail -n1; }

# --- 1. state ausente: cria a identidade e segue ---------------------------
r1="$TMP/novo"; mkdir -p "$r1"
out="$(run_check "$r1")"
assert_eq "0" "$(exit_of "$out")" "state ausente: nao falha (primeira execucao)"
if [[ -f "$(state_file "$r1")" ]]; then
    ok "state ausente: grava .installer com a identidade"
    assert_contains "$(cat "$(state_file "$r1")")" "schema=" "identidade gravada declara schema"
    assert_contains "$(cat "$(state_file "$r1")")" "commit=" "identidade gravada declara commit"
else
    no "state ausente: nao gravou .installer"
fi

# --- 2. mesmo commit: silencioso -------------------------------------------
out="$(run_check "$r1")"
assert_eq "0" "$(exit_of "$out")" "mesmo commit: resume continua"
assert_not_contains "$out" "installer atual" "mesmo commit: nao emite aviso de divergencia"

# --- 3. commit diferente, mesmo schema: aviso, mas continua ----------------
r3="$TMP/outro-commit"; mkdir -p "$r3/var/lib/gentoo-install/state"
printf 'schema=1\ncommit=deadbeefcafe\n' > "$(state_file "$r3")"
out="$(run_check "$r3")"
assert_eq "0" "$(exit_of "$out")" "commit diferente + schema compativel: resume CONTINUA"
assert_contains "$out" "deadbeefcafe" "commit diferente: mensagem cita o commit que criou o state"
assert_contains "$out" "installer atual" "commit diferente: mensagem cita o installer atual"

# --- 4. schema incompativel: aborta ----------------------------------------
r4="$TMP/schema-futuro"; mkdir -p "$r4/var/lib/gentoo-install/state"
printf 'schema=99\ncommit=abc123\n' > "$(state_file "$r4")"
out="$(run_check "$r4")"
if [[ "$(exit_of "$out")" == "0" ]]; then
    no "schema incompativel deveria abortar" "$out"
else
    ok "schema incompativel: aborta"
fi
assert_contains "$out" "INCOMPATIVEL" "schema incompativel: mensagem e explicita"

# --- 5. state corrompido (schema nao numerico): aborta ---------------------
r5="$TMP/corrompido"; mkdir -p "$r5/var/lib/gentoo-install/state"
printf 'schema=abacaxi\ncommit=x\n' > "$(state_file "$r5")"
out="$(run_check "$r5")"
if [[ "$(exit_of "$out")" == "0" ]]; then
    no "state corrompido deveria abortar" "$out"
else
    ok "state corrompido (schema nao numerico): aborta fail-closed"
fi

# --- 6. arquivo sem schema nenhum: aborta ----------------------------------
r6="$TMP/vazio"; mkdir -p "$r6/var/lib/gentoo-install/state"
printf 'lixo\n' > "$(state_file "$r6")"
out="$(run_check "$r6")"
if [[ "$(exit_of "$out")" == "0" ]]; then
    no "state sem schema deveria abortar" "$out"
else
    ok "state sem campo schema: aborta fail-closed"
fi

# --- 7. NENHUM caso pode ter apagado state --------------------------------
missing=""
for r in "$r3" "$r4" "$r5" "$r6"; do
    [[ -f "$(state_file "$r")" ]] || missing="$missing $r"
done
if [[ -z "$missing" ]]; then
    ok "nenhum caminho de erro apagou o state (nao-destrutivo)"
else
    no "state removido por um caminho de erro:$missing"
fi

# --- 8. fora de um checkout git nao se inventa SHA ------------------------
out="$(cd "$TMP" && lib_eval 'SCRIPT_DIR="'"$TMP"'"; installer_commit')"
assert_contains "$out" "nao-versionado" "fora de checkout git: reporta 'nao-versionado', nao inventa SHA"

finish
