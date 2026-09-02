#!/usr/bin/env bash
#
# test-safety.sh — invariantes destrutivos. Complementa (nao substitui)
# tests/test-target-disk-required.sh, que cobre o disco alvo ausente/invalido.
#
# Nenhum teste aqui particiona, formata ou monta. Os casos comportamentais
# chamam validate_vars (read-only); os demais sao asercoes estruturais sobre a
# ORDEM das operacoes, que e onde mora o risco: uma guarda depois do sgdisk nao
# e uma guarda.

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

printf '\n== test-safety ==\n'

INSTALL_SH="$REPO_DIR/install.sh"
LIB_SH="$REPO_DIR/lib.sh"
PART_SH="$REPO_DIR/00-partition.sh"

# --- 1. TARGET_ROOT: canonicalizacao e recusa da raiz ---------------------
# "/" escrito de outra forma nao pode passar: com TARGET_ROOT=// o script
# trataria a raiz do live ISO como alvo (umount -R, rm -rf, mount por cima).
check_root() {
    local value="$1" desc="$2" out
    out="$(TARGET_ROOT="$value" TARGET_DISK=/dev/nao-existe-para-teste \
           lib_eval 'validate_vars; printf "EXIT=%s\n" "$?"')"
    if [[ "$(sed -n 's/^EXIT=//p' <<< "$out" | tail -n1)" == "0" ]]; then
        no "$desc" "validate_vars ACEITOU TARGET_ROOT='$value'"
    else
        ok "$desc"
    fi
}
check_root "/"    "TARGET_ROOT=/ e recusado"
check_root "//"   "TARGET_ROOT=// e recusado (canonicaliza para /)"
check_root "///"  "TARGET_ROOT=/// e recusado"
check_root "/mnt/gentoo/../.." "TARGET_ROOT que sobe ate / e recusado"
check_root "mnt/gentoo" "TARGET_ROOT relativo e recusado"
check_root ""     "TARGET_ROOT vazio e recusado"

# Caminho legitimo com barra final NAO pode ser recusado (regressao conhecida:
# antes da canonicalizacao, '/mnt/gentoo/' quebrava o teste de prefixo).
out="$(TARGET_ROOT="/mnt/gentoo/" TARGET_DISK=/dev/nao-existe-para-teste \
       lib_eval 'validate_vars; printf "EXIT=%s\n" "$?"')"
if grep -qF 'TARGET_ROOT' <<< "$out" && ! grep -qF 'nao existe' <<< "$out"; then
    no "TARGET_ROOT com barra final foi recusado por si mesmo" "$out"
else
    ok "TARGET_ROOT com barra final nao e recusado pela propria validacao"
fi

# --- 2. AUTO_CONFIRM nao pode bypassar o REFORMAT ------------------------
# confirm_destruction honra AUTO_CONFIRM (automacao em VM). _confirm_reformat
# NAO pode: ele existe justamente para o caso em que o layout ja bate e o mkfs
# vai destruir um filesystem existente sem passar pelo prompt de particionar.
reformat="$(extract_fn "$PART_SH" _confirm_reformat)"
if [[ -z "$reformat" ]]; then
    no "_confirm_reformat nao encontrada em 00-partition.sh"
else
    ok "_confirm_reformat existe"
    if grep -q 'confirm_destruction' <<< "$reformat"; then
        no "_confirm_reformat delega a confirm_destruction (que honra AUTO_CONFIRM)" \
           "$(grep -n 'confirm_destruction' <<< "$reformat")"
    else
        ok "_confirm_reformat nao delega a confirm_destruction"
    fi
    if grep -qE 'AUTO_CONFIRM.*==.*yes.*\)|== "yes" \]\].*return 0' <<< "$reformat"; then
        no "_confirm_reformat parece retornar cedo por AUTO_CONFIRM" "$reformat"
    else
        ok "_confirm_reformat nao tem saida antecipada por AUTO_CONFIRM"
    fi
    if grep -q '/dev/tty' <<< "$reformat"; then
        ok "_confirm_reformat le do /dev/tty (exige operador presente)"
    else
        no "_confirm_reformat nao le do /dev/tty"
    fi
    if grep -q 'REFORMAT' <<< "$reformat"; then
        ok "_confirm_reformat exige a palavra REFORMAT digitada"
    else
        no "_confirm_reformat nao exige a palavra REFORMAT"
    fi
fi

# --- 3. nada destrutivo antes do preflight de hardware -------------------
# Ordem em main_live: preflight_hardware TEM de vir antes de do_reset,
# repartition_prep e da primeira run_script.
main_live="$(extract_fn "$INSTALL_SH" main_live)"
# So CHAMADAS contam: linhas de comentario mencionam as mesmas funcoes ao
# explicar a ordem, e casariam antes das invocacoes reais.
line_of() {
    grep -vE '^[[:space:]]*#' <<< "$main_live" \
        | grep -nE "^[[:space:]]*(if[[:space:]].*)?$1\b" | head -n1 | cut -d: -f1
}
pf="$(line_of 'preflight_hardware')"
if [[ -z "$pf" ]]; then
    no "main_live nao chama preflight_hardware"
else
    ok "main_live chama preflight_hardware"
    for after in 'do_reset' 'repartition_prep' 'run_script'; do
        n="$(line_of "$after")"
        if [[ -n "$n" ]] && (( n < pf )); then
            no "'$after' acontece ANTES do preflight_hardware (linha $n < $pf)"
        else
            ok "'$after' acontece depois do preflight_hardware"
        fi
    done
fi

# --- 4. guardas de mount/swap usam findmnt, nunca a coluna singular -------
# `lsblk -o MOUNTPOINT` (singular) reporta UM mountpoint por device: um segundo
# mount do disco alvo ficava invisivel e chegava intacto ao sgdisk.
if grep -rn 'NAME,MOUNTPOINT' "$REPO_DIR"/*.sh > /dev/null 2>&1; then
    no "voltou a existir 'lsblk -o NAME,MOUNTPOINT' (coluna singular esconde mounts)" \
       "$(grep -rn 'NAME,MOUNTPOINT' "$REPO_DIR"/*.sh)"
else
    ok "nenhum uso da coluna singular MOUNTPOINT do lsblk"
fi
if grep -q 'findmnt' "$LIB_SH"; then
    ok "lib.sh enumera mounts com findmnt"
else
    no "lib.sh nao usa findmnt para enumerar mounts"
fi

# --- 5. guardas obrigatorias continuam presentes em validate_vars ---------
vv="$(extract_fn "$LIB_SH" validate_vars)"
for guard in 'realpath' 'lsblk -ndo TYPE' '_host_is_installed_system' '_swap_is_active'; do
    if grep -qF -- "$guard" <<< "$vv"; then
        ok "validate_vars mantem a guarda: $guard"
    else
        no "validate_vars perdeu a guarda: $guard"
    fi
done

# --- 6. deteccao de holders (LVM/LUKS/RAID) antes do zap ------------------
gpt="$(extract_fn "$PART_SH" do_gpt)"
if grep -qE 'lvm|crypt|raid' <<< "$gpt"; then
    ok "do_gpt detecta holders (lvm/crypt/raid) antes de destruir"
else
    no "do_gpt nao detecta holders no disco alvo"
fi
if grep -qE 'blockdev|rereadpt|partprobe' <<< "$gpt"; then
    ok "do_gpt verifica a releitura da tabela de particoes pelo kernel"
else
    no "do_gpt nao verifica se o kernel releu a tabela"
fi

# --- 7. quem usa as globais de particao tem de chama-las antes ------------
# EFI_PART/SWAP_PART/ROOT_PART so existem depois de compute_partitions. Um
# script que as usa sem chamar morre com "unbound variable" sob set -u, no meio
# da instalacao. Pego assim ao ligar o 06 ao filesystem real da raiz.
for step in "$REPO_DIR"/0[0-6]-*.sh; do
    base="$(basename "$step")"
    body="$(grep -vE '^[[:space:]]*#' "$step")"
    if grep -qE '\$(EFI_PART|SWAP_PART|ROOT_PART)\b|\$\{(EFI_PART|SWAP_PART|ROOT_PART)\b' <<< "$body"; then
        if grep -qE '^[[:space:]]*compute_partitions' <<< "$body"; then
            ok "$base usa as globais de particao e chama compute_partitions"
        else
            no "$base usa \$ROOT_PART/\$EFI_PART/\$SWAP_PART sem chamar compute_partitions" \
               "morreria com 'unbound variable' sob set -u"
        fi
    fi
done

# root_fs_actual depende de ROOT_PART: quem a chama precisa das globais.
for step in "$REPO_DIR"/0[0-6]-*.sh; do
    base="$(basename "$step")"
    if grep -qE '^[^#]*root_fs_actual' "$step" \
       && ! grep -qE '^[[:space:]]*compute_partitions' "$step"; then
        no "$base chama root_fs_actual sem compute_partitions"
    fi
done

# --- 8. as invocacoes de lsblk/findmnt sao VALIDAS -----------------------
# Uma combinacao de flags invalida (ex.: `-r` junto de `--list`, que o
# util-linux recusa) faz o comando sair com erro e a substituicao de processo
# devolver VAZIO. Laco de umount/guarda de mount nao itera, e falha ABERTA: o
# script segue como se o disco estivesse livre. Foi exatamente isso que
# aconteceu em 00-partition.sh em 2026-09-01.
#
# Este teste EXECUTA cada combinacao contra um disco real do host. lsblk e
# findmnt sao read-only: nao escrevem nada, nao montam nada.
real_disk="$(lsblk -ndo NAME 2>/dev/null | head -n1)"
if [[ -z "$real_disk" ]]; then
    printf '  SKIP  nenhum disco visivel para validar as flags de lsblk\n'
else
    real_disk="/dev/$real_disk"
    bad=0
    while IFS= read -r flags; do
        [[ -n "$flags" ]] || continue
        # shellcheck disable=SC2086  # split proposital: sao flags separadas
        err="$(lsblk $flags "$real_disk" 2>&1 >/dev/null || true)"
        if grep -qiE 'cannot be combined|unrecognized|invalid option|unknown column' <<< "$err"; then
            no "lsblk com flags invalidas nos scripts: 'lsblk $flags'" "$err"
            bad=1
        fi
    done < <(grep -rhvE '^[[:space:]]*#' "$REPO_DIR"/*.sh \
             | grep -ohE 'lsblk (-[^"|)]*)' \
             | sed 's/^lsblk //; s/[[:space:]]*$//' | sort -u)
    (( bad == 0 )) && ok "todas as combinacoes de flags do lsblk nos scripts sao aceitas"

    bad=0
    while IFS= read -r flags; do
        [[ -n "$flags" ]] || continue
        # shellcheck disable=SC2086  # split proposital
        err="$(findmnt $flags / 2>&1 >/dev/null || true)"
        if grep -qiE 'cannot be combined|unrecognized|invalid option|unknown column' <<< "$err"; then
            no "findmnt com flags invalidas nos scripts: 'findmnt $flags'" "$err"
            bad=1
        fi
    done < <(grep -rhvE '^[[:space:]]*#' "$REPO_DIR"/*.sh \
             | grep -ohE 'findmnt (-[^"|)$]*)' \
             | sed 's/^findmnt //; s/--source//; s/[[:space:]]*$//' | sort -u)
    (( bad == 0 )) && ok "todas as combinacoes de flags do findmnt nos scripts sao aceitas"
fi

# Enumerar particoes do alvo tem UMA implementacao so (lib.sh). Uma copia
# divergente foi a causa raiz do bug acima.
# So conta quando a saida vira DADO (capturada em variavel ou alimentando um
# laco). lsblk usado para EXIBIR o disco ao operador nao e enumeracao.
inline="$(grep -rnE '(done[[:space:]]*<[[:space:]]*<\(lsblk|=[[:space:]]*"?\$\(lsblk)[^)]*NAME' \
          "$REPO_DIR"/0[0-6]-*.sh "$REPO_DIR"/install.sh 2>/dev/null \
          | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [[ -z "$inline" ]]; then
    ok "nenhuma enumeracao de particoes reimplementada fora do lib.sh"
else
    no "enumeracao de particoes duplicada fora do lib.sh (use _target_disk_parts)" "$inline"
fi

# --- 9. nenhuma autodeteccao de disco ------------------------------------
if grep -nE 'TARGET_DISK=.*\$\((lsblk|blkid|find|ls)\b' "$REPO_DIR"/*.sh > /dev/null 2>&1; then
    no "TARGET_DISK derivado de enumeracao de blocos (autodeteccao proibida)" \
       "$(grep -nE 'TARGET_DISK=.*\$\((lsblk|blkid|find|ls)\b' "$REPO_DIR"/*.sh)"
else
    ok "TARGET_DISK nunca e derivado de lsblk/blkid/find/ls"
fi

# --- o prompt de destruicao tem de mostrar o PLANO, nao so o estrago --------
# ROOT_FS foi esquecido tres vezes durante o desenvolvimento, uma delas no bare
# metal (instalou ext4 querendo btrfs). O prompt do ERASE e o unico momento em
# que o operador para e le; se o filesystem a criar nao aparece ali, o erro so
# se revela na primeira retomada — ou nunca.
printf '\n  -- plano visivel antes do ERASE --\n'

cd_fn="$(extract_fn "$REPO_DIR/lib.sh" confirm_destruction)"
if [[ -z "$cd_fn" ]]; then
    no "confirm_destruction nao existe"
else
    ln_fs="$(grep -n 'ROOT_FS' <<< "$cd_fn" | head -1 | cut -d: -f1)"
    ln_prompt="$(grep -n 'digite exatamente' <<< "$cd_fn" | head -1 | cut -d: -f1)"
    if [[ -n "$ln_fs" ]]; then
        ok "confirm_destruction nomeia o ROOT_FS que sera criado"
    else
        no "confirm_destruction nao mostra o filesystem a criar" \
           "o operador digita ERASE sem ver o que vai ser feito no lugar"
    fi
    if [[ -n "$ln_fs" && -n "$ln_prompt" ]] && (( ln_fs < ln_prompt )); then
        ok "o plano aparece ANTES do prompt de confirmacao"
    else
        no "o plano aparece depois do prompt (fs=$ln_fs prompt=$ln_prompt)"
    fi
    if grep -q 'USERNAME' <<< "$cd_fn"; then
        ok "confirm_destruction nomeia o usuario que sera criado"
    else
        no "confirm_destruction nao mostra o usuario a criar"
    fi
fi

finish
