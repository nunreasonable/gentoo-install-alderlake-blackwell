#!/usr/bin/env bash
#
# test-root-fs.sh — o filesystem REAL da raiz e a autoridade, nao a variavel
# ROOT_FS. Cobre a divergencia entre expectativa (vars.sh) e fato (blkid), que
# antes fazia o 03 montar o fstab com um tipo e o 06 escolher as ferramentas de
# filesystem com outro.

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

printf '\n== test-root-fs ==\n'

STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS"' EXIT

# blkid falso: devolve o TYPE que o teste mandar via BLKID_FAKE_TYPE.
# Vazio => simula "nao consegui determinar" (particao nao formatada).
make_stub "$STUBS" blkid '
for a in "$@"; do :; done
[[ -n "${BLKID_FAKE_TYPE:-}" ]] && printf "%s\n" "$BLKID_FAKE_TYPE"
exit 0
'

# check_case <ROOT_FS> <tipo real> <espera tipo> <espera warn: sim|nao>
check_case() {
    local declared="$1" actual="$2" want_type="$3" want_warn="$4" out got
    out="$(ROOT_FS="$declared" BLKID_FAKE_TYPE="$actual" \
        lib_eval '
            ROOT_PART=/dev/fake3
            if t="$(root_fs_actual)"; then
                printf "TYPE=%s\n" "$t"
                warn_root_fs_mismatch "$t"
            else
                printf "TYPE=INDETERMINADO\n"
            fi
        ' "$STUBS")"

    got="$(sed -n 's/^TYPE=//p' <<< "$out" | head -n1)"
    assert_eq "$want_type" "$got" "ROOT_FS=$declared / real=${actual:-vazio} -> tipo usado e '$want_type'"

    if [[ "$want_warn" == "sim" ]]; then
        assert_contains "$out" "o tipo REAL manda" \
            "ROOT_FS=$declared / real=$actual -> emite aviso de divergencia"
    else
        assert_not_contains "$out" "o tipo REAL manda" \
            "ROOT_FS=$declared / real=${actual:-vazio} -> nao emite aviso indevido"
    fi
}

# --- matriz pedida na auditoria ------------------------------------------
check_case ext4 ext4 ext4          nao
check_case xfs  xfs  xfs           nao
check_case ext4 xfs  xfs           sim
check_case xfs  ext4 ext4          sim
check_case ext4 ""   INDETERMINADO nao   # fail-closed: sem tipo, sem decisao

# --- o 06 tem de decidir pelo tipo real, nao pela variavel ----------------
# Asercao estatica complementar: o bloco de fs-tools nao pode voltar a comparar
# ROOT_FS diretamente para decidir sobre xfsprogs.
fs_block="$(sed -n '/^probe_fs_tools/,/^run_step 06-fs-tools/p' "$REPO_DIR/06-users-services.sh")"

if grep -q 'root_fs_actual' <<< "$fs_block"; then
    ok "06-fs-tools consulta root_fs_actual"
else
    no "06-fs-tools nao usa root_fs_actual"
fi

if grep -qE '\[\[[[:space:]]*"\$ROOT_FS"[[:space:]]*==' <<< "$fs_block"; then
    no "06-fs-tools ainda decide comparando \$ROOT_FS diretamente" \
       "$(grep -nE '\[\[[[:space:]]*"\$ROOT_FS"' <<< "$fs_block")"
else
    ok "06-fs-tools nao decide pela variavel ROOT_FS"
fi

# O 03 (fstab) tem de usar a MESMA funcao — as duas etapas nao podem discordar.
if grep -q 'root_fs_actual' "$REPO_DIR/03-chroot-setup.sh"; then
    ok "03-chroot-setup usa a mesma autoridade (root_fs_actual) para o fstab"
else
    no "03-chroot-setup nao usa root_fs_actual — 03 e 06 podem discordar"
fi

finish
