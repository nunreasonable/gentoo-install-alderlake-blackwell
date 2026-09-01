#!/usr/bin/env bash
#
# test-all-vars.sh — toda variavel de vars.sh precisa atravessar para o chroot.
#
# O vars.sh "assado" e o UNICO canal entre as fases (o chroot e invocado com
# env -i). Uma variavel declarada em vars.sh e esquecida em ALL_VARS/SECRET_VARS
# nao existe do outro lado — e como os scripts rodam sob `set -u`, o sintoma e a
# fase chroot morrendo com "unbound variable" no meio da instalacao. Ja
# aconteceu neste projeto com ALLOW_INSTALLED_HOST.
#
# Falsos positivos: contamos SOMENTE variaveis declaradas com o idioma de
# configuracao do vars.sh — `: "${NOME:=...}"`. Constantes internas e derivadas
# (definidas com NOME=valor) nao sao configuracao e nao entram na conta.

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

printf '\n== test-all-vars ==\n'

VARS_SH="$REPO_DIR/vars.sh"
INSTALL_SH="$REPO_DIR/install.sh"

# Variaveis de configuracao declaradas em vars.sh.
declared="$(grep -oE '^[[:space:]]*:[[:space:]]*"\$\{[A-Z_][A-Z0-9_]*:=' "$VARS_SH" \
            | grep -oE '\{[A-Z_][A-Z0-9_]*' | tr -d '{' | sort -u)"

# Variaveis propagadas: ALL_VARS (nao-sensiveis) + SECRET_VARS (sensiveis, que
# viajam pelo secrets.env). As duas juntas tem de cobrir vars.sh.
# tr limpa os separadores de sintaxe (=( ) ; espacos) para sobrar so nomes:
# SECRET_VARS e um array de UMA linha, entao "NOME=(" e ")" ficam colados.
# shellcheck disable=SC2020  # conjunto de CARACTERES e o que queremos aqui:
# cada separador de sintaxe (= ( ) ; , espaco tab) vira quebra de linha, para
# sobrarem apenas nomes de variavel. Nao e substituicao de palavras.
names_of() { tr '=();, \t' '\n\n\n\n\n\n\n' | grep -oE '^[A-Z_][A-Z0-9_]*$' | sort -u; }

propagated="$( { extract_assign "$INSTALL_SH" ALL_VARS
                 extract_assign "$INSTALL_SH" SECRET_VARS ; } \
               | names_of | grep -vE '^(ALL_VARS|SECRET_VARS)$' )"

if [[ -z "$declared" ]]; then
    no "nao consegui extrair as variaveis de vars.sh — o teste esta cego"
    finish; exit 1
fi
ok "vars.sh declara $(wc -l <<< "$declared") variaveis de configuracao"

# --- 1. nenhuma variavel de vars.sh fica de fora --------------------------
missing="$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$propagated"))"
if [[ -z "$missing" ]]; then
    ok "todas as variaveis de vars.sh sao propagadas (ALL_VARS + SECRET_VARS)"
else
    no "variaveis declaradas em vars.sh e NAO propagadas ao chroot" \
       "$(tr '\n' ' ' <<< "$missing") — a fase chroot morreria com 'unbound variable'"
fi

# --- 2. nada e propagado sem existir em vars.sh ---------------------------
extra="$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$propagated"))"
if [[ -z "$extra" ]]; then
    ok "nada em ALL_VARS/SECRET_VARS sem declaracao em vars.sh"
else
    no "propagadas mas ausentes de vars.sh" "$(tr '\n' ' ' <<< "$extra")"
fi

# --- 3. as duas listas sao disjuntas --------------------------------------
dup="$(comm -12 \
        <(extract_assign "$INSTALL_SH" ALL_VARS   | names_of | grep -vE '^ALL_VARS$') \
        <(extract_assign "$INSTALL_SH" SECRET_VARS | names_of | grep -vE '^SECRET_VARS$'))"
if [[ -z "$dup" ]]; then
    ok "ALL_VARS e SECRET_VARS sao disjuntas (segredo nao vaza para o vars.sh)"
else
    no "variavel em ALL_VARS *e* SECRET_VARS" "$(tr '\n' ' ' <<< "$dup")"
fi

# --- 4. toda variavel enum yes/no e validada -------------------------------
# validate_vars valida um conjunto de flags yes|no num laco. Uma flag nova
# esquecida ali passa qualquer lixo adiante.
# shellcheck disable=SC1003  # '\\' e mesmo uma barra invertida literal: o laco
# de validacao quebra linha com "\" e precisamos remove-la antes de tokenizar.
enum_loop="$(grep -A3 'for var in ENABLE_SSHD' "$REPO_DIR/lib.sh" | tr -d '\\' | names_of)"
yesno_defaults="$(grep -oE '^[[:space:]]*:[[:space:]]*"\$\{[A-Z_][A-Z0-9_]*:=(yes|no)\}"' "$VARS_SH" \
                  | grep -oE '\{[A-Z_][A-Z0-9_]*' | tr -d '{' | sort -u)"
missing_enum="$(comm -23 <(printf '%s\n' "$yesno_defaults") <(printf '%s\n' "$enum_loop"))"
if [[ -z "$missing_enum" ]]; then
    ok "toda variavel com default yes/no e validada como enum em validate_vars"
else
    no "flags yes/no sem validacao de enum" "$(tr '\n' ' ' <<< "$missing_enum")"
fi

finish
