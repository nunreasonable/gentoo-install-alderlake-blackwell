#!/usr/bin/env bash
#
# test-profile-detection.sh — o perfil corrente vem do symlink canonico
# /etc/portage/make.profile, NAO da saida do `eselect profile show`.
#
# Testa a funcao de verdade (current_profile aceita um caminho para o teste
# apontar numa arvore temporaria) e, alem disso, prova que a deteccao nao
# depende da POSICAO das linhas do eselect: um eselect falso que imprime a
# resposta certa na linha errada — ou que nem existe — nao muda o resultado.

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

printf '\n== test-profile-detection ==\n'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Arvore falsa com o layout de um repo do portage.
PROFILES="$TMP/repo/profiles"
mkdir -p "$PROFILES/default/linux/amd64/23.0" \
         "$PROFILES/default/linux/amd64/23.0/systemd"
LINK="$TMP/make.profile"

# eselect falso e HOSTIL: imprime o perfil certo, mas na linha 1 e com outro
# formato. Se a deteccao dependesse de NR==2, quebraria aqui.
STUBS="$TMP/stubs"
make_stub "$STUBS" eselect '
printf "default/linux/amd64/23.0\n"
printf "  [1]   perfil-decorativo-que-nao-e-o-selecionado *\n"
printf "  [2]   outra-linha-qualquer\n"
'

probe() { lib_eval "current_profile '$LINK'" "$STUBS"; }

# --- 1. OpenRC: symlink resolve para o perfil 23.0 ------------------------
ln -sfn "$PROFILES/default/linux/amd64/23.0" "$LINK"
assert_eq "default/linux/amd64/23.0" "$(probe)" \
    "symlink -> 23.0 e detectado como 'default/linux/amd64/23.0'"

# --- 2. systemd: sub-perfil e detectado separadamente ---------------------
ln -sfn "$PROFILES/default/linux/amd64/23.0/systemd" "$LINK"
assert_eq "default/linux/amd64/23.0/systemd" "$(probe)" \
    "symlink -> 23.0/systemd e detectado como o perfil systemd"

# --- 3. independencia do eselect ------------------------------------------
# Sem eselect nenhum no PATH o resultado tem de ser o mesmo.
EMPTY="$TMP/vazio"; mkdir -p "$EMPTY"
ln -sfn "$PROFILES/default/linux/amd64/23.0" "$LINK"
out="$(PATH="$EMPTY:/usr/bin:/bin" lib_eval "current_profile '$LINK'")"
assert_eq "default/linux/amd64/23.0" "$out" \
    "deteccao funciona mesmo sem o binario eselect disponivel"

# O eselect hostil (resposta na linha 1, lixo na linha 2) nao altera nada.
assert_eq "default/linux/amd64/23.0" "$(probe)" \
    "eselect com saida em ordem diferente nao afeta a deteccao"

# --- 4. fail-closed --------------------------------------------------------
rm -f "$LINK"
out="$(probe)"; rc=$?
if (( rc != 0 )) && [[ -z "$out" ]]; then
    ok "symlink ausente: retorna erro sem imprimir (fail-closed)"
else
    no "symlink ausente deveria falhar silenciosamente" "rc=$rc out='$out'"
fi

ln -sfn "$TMP/nao-existe" "$LINK"
out="$(probe)"; rc=$?
if (( rc != 0 )); then
    ok "symlink quebrado: retorna erro (fail-closed)"
else
    no "symlink quebrado deveria falhar" "out='$out'"
fi

# Perfil fora de um repo com .../profiles/: nao pode casar com TARGET_PROFILE.
mkdir -p "$TMP/solto/algum-perfil"
ln -sfn "$TMP/solto/algum-perfil" "$LINK"
out="$(probe)"
if [[ "$out" == "default/linux/amd64/23.0" ]]; then
    no "perfil fora de .../profiles/ nao pode ser confundido com o alvo"
else
    ok "perfil fora do layout padrao nao casa com o alvo (retornou '$out')"
fi

# --- 5. o codigo do 03 nao voltou a parsear a UI para o perfil ------------
prof_block="$(sed -n '/^probe_profile/,/^run_step 03-profile/p' "$REPO_DIR/03-chroot-setup.sh")"
if grep -q 'NR==2' <<< "$prof_block"; then
    no "probe/do de perfil voltou a depender de NR==2"
else
    ok "probe/do de perfil nao usa NR==2"
fi
if grep -q 'current_profile' <<< "$prof_block"; then
    ok "probe/do de perfil usa a fonte canonica (current_profile)"
else
    no "probe/do de perfil nao usa current_profile"
fi
if grep -q 'readlink -f' <<< "$(extract_fn "$REPO_DIR/lib.sh" current_profile)"; then
    ok "current_profile resolve o symlink com readlink -f"
else
    no "current_profile nao usa readlink -f"
fi

finish
