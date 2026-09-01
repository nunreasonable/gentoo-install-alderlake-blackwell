#!/usr/bin/env bash
#
# test-secrets.sh — hashes de senha nao podem ficar persistidos no artefato que
# sobra em /root/gentoo-install/ do sistema instalado.
#
# Exercita write_effective_vars/cleanup_secrets de verdade (num alvo falso em
# /tmp), em vez de so grepar o codigo: o teste monta o vars.sh efetivo e depois
# procura os hashes nele.

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

printf '\n== test-secrets ==\n'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hashes distintos e improvaveis, para o grep nao dar falso positivo.
RHASH='$6$TESTEROOT$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaSENTINELAROOT'
UHASH='$6$TESTEUSER$bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbSENTINELAUSER'

TROOT="$TMP/alvo"
SCRIPTS="$TROOT/root/gentoo-install"
mkdir -p "$SCRIPTS"

# install.sh nao pode ser sourced inteiro (ele executa no fim), entao montamos
# um prelude com as definicoes reais que os testes precisam. Extracao por nome,
# nao por range solto — um range ate "^}" atravessa varias definicoes.
INSTALL_SH="$REPO_DIR/install.sh"
PRELUDE="$TMP/prelude.sh"
{
    extract_assign "$INSTALL_SH" TARGET_SCRIPTS_DIR_REL
    extract_assign "$INSTALL_SH" ALL_VARS
    extract_assign "$INSTALL_SH" SECRET_VARS
    extract_assign "$INSTALL_SH" SECRETS_FILE_REL
    extract_fn     "$INSTALL_SH" secrets_path
    extract_fn     "$INSTALL_SH" write_effective_vars
    extract_fn     "$INSTALL_SH" cleanup_secrets
} > "$PRELUDE"
bash -n "$PRELUDE" || no "prelude extraido do install.sh nao e bash valido"

# gi_eval <codigo> [rhash] [uhash]: roda <codigo> com vars.sh + lib.sh + prelude.
gi_eval() {
    local code="$1" rh="${2-}" uh="${3-}"
    bash -c '
        set -uo pipefail
        SCRIPT_DIR="$1"
        source "$1/vars.sh"
        source "$1/lib.sh"
        source "$2"
        ROOT_PASSWORD_HASH="$4"; USER_PASSWORD_HASH="$5"; TARGET_ROOT="$6"
        eval "$3"
    ' _ "$REPO_DIR" "$PRELUDE" "$code" "$rh" "$uh" "$TROOT"
}

run_write() {
    gi_eval 'write_effective_vars > /dev/null; printf "SECRETS=%s\n" "$(secrets_path)"' \
            "$RHASH" "$UHASH"
}

out="$(run_write)"
rc=$?
if (( rc != 0 )); then
    no "write_effective_vars falhou" "$out"
    finish
    exit 1
fi
SECRETS="$(sed -n 's/^SECRETS=//p' <<< "$out" | tail -n1)"
VARS="$SCRIPTS/vars.sh"

# --- 1. o vars.sh persistente NAO contem os hashes ------------------------
if [[ -f "$VARS" ]]; then
    ok "vars.sh efetivo foi gerado"
    if grep -qF 'SENTINELAROOT' "$VARS" || grep -qF 'SENTINELAUSER' "$VARS"; then
        no "hash de senha PERSISTIDO no vars.sh" "$(grep -nF SENTINELA "$VARS")"
    else
        ok "nenhum hash de senha no vars.sh efetivo"
    fi
    if grep -qE '^(ROOT|USER)_PASSWORD_HASH=' "$VARS"; then
        no "vars.sh atribui *_PASSWORD_HASH com valor literal" "$(grep -nE '^(ROOT|USER)_PASSWORD_HASH=' "$VARS")"
    else
        ok "vars.sh nao atribui os hashes diretamente"
    fi
else
    no "vars.sh efetivo nao foi gerado"
fi

# --- 2. os segredos existem durante a instalacao, com modo restritivo -----
if [[ -f "$SECRETS" ]]; then
    ok "secrets.env criado (a etapa 06 ainda precisa dos hashes)"
    mode="$(stat -c '%a' "$SECRETS")"
    assert_eq "600" "$mode" "secrets.env tem modo 0600"
    if grep -qF 'SENTINELAROOT' "$SECRETS" && grep -qF 'SENTINELAUSER' "$SECRETS"; then
        ok "secrets.env carrega os dois hashes (resume nao-interativo preservado)"
    else
        no "secrets.env nao contem os hashes esperados"
    fi
else
    no "secrets.env nao foi criado — a etapa 06 perderia os hashes"
fi

# --- 3. o vars.sh sourceado reconstitui os hashes ------------------------
got="$(bash -c 'set -u; source "$1"; printf "%s|%s\n" "$ROOT_PASSWORD_HASH" "$USER_PASSWORD_HASH"' _ "$VARS" 2>&1)"
assert_eq "$RHASH|$UHASH" "$got" "source do vars.sh reconstitui os hashes a partir do secrets.env"

# --- 4. sem secrets.env, o vars.sh continua sourceavel sob set -u ---------
rm -f "$SECRETS"
got="$(bash -c 'set -u; source "$1"; printf "[%s][%s]\n" "$ROOT_PASSWORD_HASH" "$USER_PASSWORD_HASH"' _ "$VARS" 2>&1)"
assert_eq "[][]" "$got" "sem secrets.env: vars.sh nao quebra sob set -u (cai no passwd interativo)"

# --- 5. cleanup_secrets remove o arquivo ---------------------------------
run_write > /dev/null
[[ -f "$SECRETS" ]] || no "pre-condicao: secrets.env deveria existir apos regravar"
cleanup_out="$(gi_eval 'cleanup_secrets > /dev/null')"
if [[ -e "$SECRETS" ]]; then
    no "cleanup_secrets nao removeu o arquivo" "$cleanup_out"
else
    ok "cleanup_secrets remove o secrets.env ao final"
fi

# --- 6. regravar limpa o secrets.env anterior ----------------------------
printf 'ROOT_PASSWORD_HASH=LIXO_ANTIGO\n' > "$SECRETS"
gi_eval 'write_effective_vars > /dev/null' "" "" > /dev/null 2>&1
if [[ -e "$SECRETS" ]]; then
    no "secrets.env obsoleto sobreviveu a uma execucao sem hashes" "$(cat "$SECRETS")"
else
    ok "execucao sem hashes remove o secrets.env obsoleto"
fi

# --- 7. os hashes nao sao ecoados por nenhum script ----------------------
leak="$(grep -nE '(echo|printf|log_(info|warn|error)).*(ROOT|USER)_PASSWORD_HASH' \
        "$REPO_DIR"/*.sh 2>/dev/null | grep -v 'printf .%s:%s' || true)"
if [[ -z "$leak" ]]; then
    ok "nenhum echo/printf/log imprime os hashes"
else
    no "possivel vazamento dos hashes em log/saida" "$leak"
fi

# A unica saida permitida e o pipe para chpasswd -e (nao vai para stdout).
if grep -qE "printf '%s:%s\\\\n'.*\\| *chpasswd -e" "$REPO_DIR/06-users-services.sh"; then
    ok "hashes so saem por pipe direto para 'chpasswd -e'"
else
    no "nao encontrei o pipe esperado para chpasswd -e"
fi

# --- 8. os hashes nao estao mais em ALL_VARS -----------------------------
allvars="$(sed -n '/^ALL_VARS=(/,/^)/p' "$REPO_DIR/install.sh")"
if grep -qE '(ROOT|USER)_PASSWORD_HASH' <<< "$allvars"; then
    no "ALL_VARS ainda inclui os hashes (voltariam ao vars.sh persistente)"
else
    ok "ALL_VARS nao inclui os hashes"
fi

finish
