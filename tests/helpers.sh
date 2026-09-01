#!/usr/bin/env bash
#
# helpers.sh — utilidades comuns aos testes do host.
#
# Nenhum teste deste diretorio executa o instalador, particiona, monta, baixa
# ou compila. Os testes ou (a) fazem source de lib.sh/vars.sh num subshell
# isolado e chamam funcoes puras, ou (b) fazem asercoes estaticas sobre o
# codigo. Onde e preciso simular um comando externo (blkid, lsblk), usamos um
# diretorio de stubs no inicio do PATH — nunca o comando real.

# shellcheck disable=SC2034  # usadas pelos scripts que fazem source deste
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname -- "$TESTS_DIR")"

_pass=0
_fail=0

ok() { printf '  PASS  %s\n' "$1"; _pass=$((_pass + 1)); }
no() {
    printf '  FAIL  %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '        %s\n' "$2"
    _fail=$((_fail + 1))
}

# finish <nome-do-grupo>: imprime o resumo e sai com 1 se houve falha.
finish() {
    printf '  -> %d pass, %d fail\n' "$_pass" "$_fail"
    [[ "$_fail" -eq 0 ]]
}

# assert_eq <esperado> <obtido> <descricao>
assert_eq() {
    if [[ "$1" == "$2" ]]; then
        ok "$3"
    else
        no "$3" "esperado '$1', obtido '$2'"
    fi
}

# assert_contains <texto> <agulha> <descricao>
assert_contains() {
    if grep -qF -- "$2" <<< "$1"; then
        ok "$3"
    else
        no "$3" "nao encontrei '$2' em: $(head -c 300 <<< "$1")"
    fi
}

# assert_not_contains <texto> <agulha> <descricao>
assert_not_contains() {
    if grep -qF -- "$2" <<< "$1"; then
        no "$3" "encontrei '$2' onde nao devia"
    else
        ok "$3"
    fi
}

# make_stub <dir> <nome> <corpo>: cria um executavel falso em <dir>.
make_stub() {
    local dir="$1" name="$2" body="$3"
    mkdir -p "$dir"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$dir/$name"
    chmod +x "$dir/$name"
}

# extract_fn <arquivo> <nome>: imprime a definicao da funcao <nome>, de
# "^nome() {" ate o primeiro "^}". Usado pelos testes para exercitar funcoes do
# install.sh, que nao pode ser sourced inteiro (ele executa no fim).
extract_fn() {
    sed -n "/^$2() {/,/^}/p" "$1"
}

# extract_assign <arquivo> <nome>: imprime a atribuicao de <nome>, seja de uma
# linha (VAR=... ou VAR=(a b)) ou de um array multi-linha terminado em "^)".
extract_assign() {
    local file="$1" name="$2" first
    first="$(grep -n "^$name=" "$file" | head -n1 | cut -d: -f1)"
    [[ -n "$first" ]] || return 1
    if sed -n "${first}p" "$file" | grep -q '=(' && ! sed -n "${first}p" "$file" | grep -q ')[[:space:]]*$'; then
        sed -n "${first},/^)/p" "$file"       # array multi-linha
    else
        sed -n "${first}p" "$file"            # linha unica
    fi
}

# lib_eval <codigo> [stub_dir]: roda <codigo> num bash isolado que fez source de
# vars.sh e lib.sh. Ecoa stdout+stderr; o exit code e o do <codigo>.
# Rodar em subshell separado garante que nada vaze para o processo de teste.
lib_eval() {
    local code="$1" stubs="${2:-}"
    local path="$PATH"
    [[ -n "$stubs" ]] && path="$stubs:$PATH"
    PATH="$path" bash -c '
        set -uo pipefail
        SCRIPT_DIR="$1"
        source "$1/vars.sh"
        source "$1/lib.sh"
        # O trap ERR global do lib.sh referencia ${BASH_SOURCE[0]}, que em
        # `bash -c` e um array VAZIO — sob set -u o proprio trap abortaria com
        # "unbound variable" sempre que a funcao sob teste retornasse != 0,
        # mascarando o valor de retorno que queremos medir. Em producao isso
        # nunca ocorre (todo script tem arquivo, logo BASH_SOURCE[0] existe).
        # `die` continua funcionando: e chamada explicita, nao depende do trap.
        trap - ERR
        eval "$2"
    ' _ "$REPO_DIR" "$code" 2>&1
}
