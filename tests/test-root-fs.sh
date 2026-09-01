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

# --- coerencia do conjunto de filesystems suportados ----------------------
# ROOT_FS so vale se as QUATRO pontas concordarem: o enum aceita, o 00 sabe
# formatar, o kernel embute o driver e o 06 instala as ferramentas. Uma ponta
# faltando produz falha em momentos diferentes — e a do kernel produz a pior
# delas: sistema que nao boota, sem shell de recuperacao.
enum_line="$(grep -n 'ROOT_FS.*invalido' "$REPO_DIR/lib.sh" | head -n1)"
mkfs_block="$(sed -n '/case "\$ROOT_FS" in/,/esac/p' "$REPO_DIR/00-partition.sh")"
frag="$REPO_DIR/kernel-fragment.config"
required="$(sed -n '/local -a required=(/,/^    )/p' "$REPO_DIR/04-kernel.sh")"
fs_tools="$(extract_fn "$REPO_DIR/06-users-services.sh" do_fs_tools)"

for fs in ext4 xfs btrfs; do
    # 1. o enum aceita
    if grep -q "\"$fs\"" <<< "$(grep -A1 'ROOT_FS.*==' "$REPO_DIR/lib.sh" | head -4)"; then
        ok "ROOT_FS=$fs e aceito por validate_vars"
    else
        no "ROOT_FS=$fs nao esta no enum de validate_vars"
    fi
    # 2. o 00 sabe formatar
    if grep -qE "^\s+$fs\)" <<< "$mkfs_block"; then
        ok "00-partition sabe formatar $fs"
    else
        no "00-partition nao tem caso de mkfs para $fs" "validate_vars aceitaria e o mkfs morreria depois do ERASE"
    fi
done

# 3. o kernel embute os TRES. Sem initramfs, =m no driver da raiz = nao boota.
for sym in EXT4_FS XFS_FS BTRFS_FS; do
    if grep -qx "CONFIG_$sym=y" "$frag"; then
        ok "kernel-fragment tem CONFIG_$sym=y (built-in, exigido sem initramfs)"
    elif grep -qx "CONFIG_$sym=m" "$frag"; then
        no "CONFIG_$sym esta como MODULO no fragmento" \
           "sem initramfs o driver da raiz precisa ser =y — o modulo vive dentro da raiz que ainda nao foi montada"
    else
        no "CONFIG_$sym ausente do kernel-fragment"
    fi
    # 4. e o gate duro cobra
    if grep -qE "^\s+$sym\b" <<< "$required"; then
        ok "verify_kconfig exige $sym"
    else
        no "verify_kconfig nao exige $sym" "um fragmento editado poderia rebaixa-lo sem ninguem ver"
    fi
done

# 5. o 06 instala a ferramenta de cada fs que precisa de uma
for pair in "xfs:xfsprogs" "btrfs:btrfs-progs"; do
    fs="${pair%%:*}"; pkg="${pair##*:}"
    if grep -q "$pkg" <<< "$fs_tools"; then
        ok "06-fs-tools instala $pkg quando a raiz e $fs"
    else
        no "06-fs-tools nao instala $pkg para raiz $fs" "o fsck do primeiro boot nao acharia a ferramenta"
    fi
done

finish
