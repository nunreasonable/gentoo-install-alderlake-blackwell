#!/usr/bin/env bash
# 05-bootloader.sh — GRUB UEFI + grub.cfg (fase chroot).
#
# Implementa o capitulo "Configuring the bootloader" do Handbook AMD64:
#   - emerge sys-boot/grub (GRUB_PLATFORMS="efi-64" ja definido pelo 02 no make.conf)
#   - /etc/default/grub com os parametros de kernel necessarios
#   - grub-install --target=x86_64-efi --efi-directory=/efi
#   - grub-mkconfig -o /boot/grub/grub.cfg
#
# Particularidade desta instalacao: NAO ha initramfs (kernel do 04 tem tudo
# built-in). Sem initramfs o kernel NAO entende root=UUID= (UUID de filesystem
# e resolvido por userspace/initramfs); ja root=PARTUUID= e resolvido pelo
# proprio kernel via GPT. Por isso forcamos GRUB_DISABLE_LINUX_UUID=true e
# passamos root=PARTUUID=<partuuid real da raiz> explicitamente na cmdline.
#
# Sub-etapas (run_step): 05-efi-mount, 05-grub-emerge, 05-default-grub,
# 05-grub-install, 05-grub-cfg. Probes funcionais: o probe do 05-grub-cfg
# exige que o grub.cfg mencione a versao ATUAL do kernel — assim um rebuild
# de kernel no 04 invalida a sub-etapa e o grub.cfg e regenerado.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/vars.sh"   # SEMPRE vars.sh ANTES de lib.sh
source "$SCRIPT_DIR/lib.sh"
init_logging 05-bootloader
require_phase chroot
validate_vars

# Globais preenchidas por main() antes dos run_step (os probes dependem delas).
ROOT_PARTUUID=""
KERNEL_RELEASE=""

# current_kernel_release: imprime a release do kernel corrente (ex.:
# 6.12.21-gentoo). Fonte primaria: kernel.release da arvore selecionada por
# `eselect kernel set` no 04 (existe apos o build). Fallback: o vmlinuz mais
# novo em /boot (ordenacao por versao), IGNORANDO os backups vmlinuz-*.old
# que o `make install` cria num rebuild de mesma versao — sort -V ordenaria
# '<rel>.old' DEPOIS de '<rel>' e o backup seria eleito como kernel corrente.
# Retorna 1 se nada for encontrado.
current_kernel_release() {
    if [[ -r /usr/src/linux/include/config/kernel.release ]]; then
        cat /usr/src/linux/include/config/kernel.release
        return 0
    fi
    # Glob + loop em vez de `ls | grep` (SC2010): o shell ja entrega os nomes
    # um a um, sem passar por parsing de saida de ls.
    local f rel newest
    shopt -s nullglob
    local candidates=()
    for f in /boot/vmlinuz-*; do
        [[ -f "$f" ]] || continue
        rel="${f##*/vmlinuz-}"
        # ignora os backups vmlinuz-*.old do `make install` (ver comentario
        # acima): sort -V ordenaria '<rel>.old' DEPOIS de '<rel>'
        [[ "$rel" == *.old ]] && continue
        candidates+=("$rel")
    done
    shopt -u nullglob
    [[ "${#candidates[@]}" -gt 0 ]] || return 1
    newest="$(printf '%s\n' "${candidates[@]}" | sort -V | tail -n1)"
    [[ -n "$newest" ]] || return 1
    printf '%s\n' "$newest"
}

# ---------------------------------------------------------------------------
# 05-efi-mount — garante a ESP montada em /efi
# Handbook: "Installing the boot loader" pressupoe a ESP montada (o Handbook
# atual monta a ESP em /efi; os kernels ficam em /boot, na raiz).
# Apos um reboot do live ISO + re-entrada no chroot, os mounts do live cobrem
# isso; esta sub-etapa e a rede de seguranca para execucao standalone.
# ---------------------------------------------------------------------------

probe_efi_mount() {
    mountpoint -q /efi || return 1
    # Confere que o que esta montado em /efi e MESMO a nossa ESP (particao 1)
    local src
    src="$(findmnt -no SOURCE /efi 2>/dev/null)" || return 1
    [[ -n "$src" && -b "$src" ]] || return 1
    [[ "$(realpath "$src")" == "$(realpath "$EFI_PART")" ]]
}

do_efi_mount() {
    # Se ha OUTRA coisa montada em /efi, nao desmontamos por conta propria:
    # melhor morrer com diagnostico do que mexer em mount alheio.
    if mountpoint -q /efi; then
        die "/efi esta montado mas nao e $EFI_PART (veja findmnt /efi) — desmonte manualmente e re-execute"
    fi
    mkdir -p /efi
    mount "$EFI_PART" /efi
    log_info "ESP $EFI_PART montada em /efi"
}

# ---------------------------------------------------------------------------
# 05-grub-emerge — instala o GRUB
# Handbook: "Emerge" (Default: GRUB) — `emerge --ask sys-boot/grub`.
# GRUB_PLATFORMS="efi-64" ja foi gravado no make.conf pelo 02, entao o build
# traz o suporte UEFI de 64 bits (/usr/lib/grub/x86_64-efi).
# ---------------------------------------------------------------------------

probe_grub_emerge() {
    # Probe funcional: binarios presentes E imagens do target x86_64-efi
    # instaladas (grub compilado sem efi-64 seria inutil aqui).
    command -v grub-install > /dev/null 2>&1 || return 1
    command -v grub-mkconfig > /dev/null 2>&1 || return 1
    [[ -d /usr/lib/grub/x86_64-efi ]]
}

do_grub_emerge() {
    emerge sys-boot/grub
}

# ---------------------------------------------------------------------------
# 05-default-grub — escreve /etc/default/grub
# Handbook: "Optional: Setting kernel boot options" — parametros de kernel
# vao em GRUB_CMDLINE_LINUX no /etc/default/grub.
# O root= NAO vai no GRUB_CMDLINE_LINUX: com GRUB_DISABLE_LINUX_UUID=true e
# GRUB_DISABLE_LINUX_PARTUUID=false o proprio 10_linux upstream emite
# root=PARTUUID=<partuuid da raiz> em cada menuentry, lendo o valor do disco
# real. Colocar um segundo root= aqui produzia DOIS root= por menuentry (o
# kernel obedece ao ultimo, entao funcionava por acidente) e transformava o
# /etc/default/grub numa segunda fonte de verdade que podia divergir do disco
# apos um reparticionamento — exatamente o que o invariante 1 proibe.
# intel_iommu=on liga a IOMMU (o kernel do 04 tem INTEL_IOMMU=y mas
# INTEL_IOMMU_DEFAULT_ON desligado — a decisao fica na cmdline).
# ---------------------------------------------------------------------------

probe_default_grub() {
    [[ -f /etc/default/grub ]] || return 1
    grep -qx 'GRUB_DISABLE_LINUX_UUID=true' /etc/default/grub || return 1
    grep -qx 'GRUB_DISABLE_LINUX_PARTUUID=false' /etc/default/grub || return 1
    # Nenhum root= ATIVO: quem emite o root= e o 10_linux, a partir do estado
    # real do disco. Um root= aqui seria uma segunda fonte de verdade.
    #
    # Linhas de comentario ficam de fora do teste. Sem isso o probe reprovava o
    # proprio arquivo que o do_default_grub acabara de escrever: o comentario
    # que EXPLICA por que nao ha root= contem a string "root=" tres vezes.
    # Sintoma: "do_fn terminou mas o probe ainda reporta nao-feito".
    # Pego no primeiro smoke-test em QEMU que chegou na etapa 05.
    if grep -vE '^[[:space:]]*#' /etc/default/grub | grep -q 'root='; then
        return 1
    fi
    grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX=.*intel_iommu=on' /etc/default/grub
}

do_default_grub() {
    cat > /etc/default/grub <<EOF
# /etc/default/grub — gerado por 05-bootloader.sh (instalacao automatizada).

GRUB_DISTRIBUTOR="Gentoo"
GRUB_TIMEOUT=5

# Sem initramfs o kernel nao resolve root=UUID= (UUID de filesystem e coisa de
# userspace); root=PARTUUID= e resolvido pelo proprio kernel via GPT. Com estes
# dois valores o 10_linux emite root=PARTUUID= sozinho, lendo o PARTUUID do
# disco real — por isso NAO repetimos root= no GRUB_CMDLINE_LINUX abaixo.
GRUB_DISABLE_LINUX_UUID=true
GRUB_DISABLE_LINUX_PARTUUID=false

# intel_iommu : liga a IOMMU (VT-d) — o kernel foi buildado com
#               INTEL_IOMMU_DEFAULT_ON desligado de proposito
GRUB_CMDLINE_LINUX="intel_iommu=on"
EOF
    log_info "/etc/default/grub escrito (root=PARTUUID emitido pelo 10_linux)"
}

# ---------------------------------------------------------------------------
# 05-grub-install — instala o GRUB na ESP
# Handbook: "Install" (Default: GRUB, sistemas UEFI) —
#   `grub-install --target=x86_64-efi --efi-directory=/efi`
# GRUB_REMOVABLE=yes adiciona --removable: grava em EFI/BOOT/BOOTX64.EFI (o
# caminho de fallback UEFI) e NAO toca na NVRAM — util em VM/firmware que
# ignora ou perde entradas de boot.
# Sem --removable, o probe exige grubx64.efi na ESP E a entrada na NVRAM
# (efibootmgr): so o arquivo nao basta, pois o grub-install pode falhar
# depois da copia mas antes de registrar a entrada de boot.
# ---------------------------------------------------------------------------

# _efi_fallback_present: verdadeiro se existe EFI/BOOT/BOOTX64.EFI na ESP
# (FAT e case-insensitive, mas o -ipath cobre variacoes de caixa por garantia).
_efi_fallback_present() {
    find /efi/EFI -maxdepth 2 -type f -ipath '*/boot/bootx64.efi' 2>/dev/null | grep -q .
}

probe_grub_install() {
    if [[ "$GRUB_REMOVABLE" == "yes" ]]; then
        # --removable instala SO no caminho de fallback e nao toca na NVRAM
        _efi_fallback_present
    else
        # Instalacao padrao: EFI/<bootloader-id>/grubx64.efi na ESP...
        find /efi/EFI -maxdepth 2 -type f -iname 'grubx64.efi' 2>/dev/null | grep -q . || return 1
        # ...E a copia de fallback EFI/BOOT/BOOTX64.EFI que do_grub_install
        # grava incondicionalmente na segunda invocacao. Sem esta checagem a
        # rede de seguranca do firmware ASUS (que tem historico de perder ou
        # reordenar entradas de NVRAM) ficava sem probe nenhum: se a segunda
        # invocacao falhasse, o probe passava e a maquina ficava dependente
        # exclusivamente da entrada NVRAM.
        _efi_fallback_present || return 1
        # ...E a entrada de boot na NVRAM. O grub-install copia o grubx64.efi
        # ANTES de registrar a entrada via efivarfs; se ele falhar no meio
        # (ex.: live ISO bootado em CSM/legacy, efivarfs inacessivel no
        # chroot), o arquivo sozinho nao prova que a etapa terminou — e sem a
        # entrada a maquina nao boota. Se o efibootmgr nao conseguir ler as
        # variaveis, reportamos nao-feito: o do_grub_install re-roda e morre
        # com a mensagem de erro real do grub-install.
        efibootmgr -v 2>/dev/null | grep -qi 'grubx64\.efi'
    fi
}

# assert_boot_fs_readable_by_grub: o GRUB tem de conseguir LER o filesystem que
# guarda o /boot. Neste layout o /boot vive dentro da raiz, entao e a raiz.
#
# Existe porque uma instalacao btrfs completou com sucesso — grub.cfg gerado,
# kernel versionado no lugar, PARTUUID correto, todas as verificacoes do 05
# passando — e mesmo assim caiu em `grub rescue> unknown filesystem` no primeiro
# boot. As verificacoes olhavam o CONTEUDO dos arquivos; nenhuma perguntava se o
# GRUB conseguia abrir o filesystem em que eles estao.
#
# block-group-tree: feature que o mkfs.btrfs moderno liga por DEFAULT e que o
# driver btrfs do GRUB nao suporta (o btrfs.c dele nao tem uma referencia ao
# simbolo, nem checa compat_ro). O 00 cria com '-O ^block-group-tree'; este
# portao cobre o caso de a raiz ter vindo de outro lugar — mkfs a mao, disco
# reaproveitado, ou mudanca de default do btrfs-progs.
assert_boot_fs_readable_by_grub() {
    local fs
    fs="$(root_fs_actual)" || return 0   # indeterminado: o 03 ja morreu antes
    [[ "$fs" == "btrfs" ]] || return 0

    command -v btrfs > /dev/null 2>&1 || {
        log_warn "raiz e btrfs mas o comando 'btrfs' nao esta disponivel — nao da para conferir block-group-tree aqui; se o boot cair em 'grub rescue', e essa a causa provavel"
        return 0
    }

    local compat_ro
    compat_ro="$(btrfs inspect-internal dump-super "$ROOT_PART" 2>/dev/null \
                 | awk '/^compat_ro_flags/ { print $2; exit }')"
    [[ -n "$compat_ro" ]] || {
        log_warn "nao consegui ler compat_ro_flags de $ROOT_PART — seguindo sem a verificacao de block-group-tree"
        return 0
    }

    # bit 3 (0x8) = BTRFS_FEATURE_COMPAT_RO_BLOCK_GROUP_TREE
    # (include/uapi/linux/btrfs.h do kernel)
    if (( (compat_ro & 0x8) != 0 )); then
        die "a raiz $ROOT_PART e btrfs com a feature 'block-group-tree' LIGADA (compat_ro_flags=$compat_ro). O driver btrfs do GRUB NAO le esse formato: o boot cairia em 'grub rescue> unknown filesystem', com tudo o mais aparentemente correto. Recrie a raiz com 'mkfs.btrfs -f -O ^block-group-tree $ROOT_PART' (o 00-partition.sh ja faz isso) e re-execute, OU use ROOT_FS=ext4."
    fi
    log_info "raiz btrfs sem block-group-tree — legivel pelo GRUB"
}

do_grub_install() {
    assert_boot_fs_readable_by_grub
    local args=(--target=x86_64-efi --efi-directory=/efi)
    if [[ "$GRUB_REMOVABLE" == "yes" ]]; then
        args+=(--removable)
    fi
    # Nota: sem --removable o grub-install tambem grava a entrada de boot na
    # NVRAM via efivarfs (disponivel no chroot pelo rbind de /sys feito no
    # install.sh; o live ISO precisa ter sido bootado em modo UEFI).
    grub-install "${args[@]}"
    log_info "grub-install concluido (${args[*]})"
    if [[ "$GRUB_REMOVABLE" != "yes" ]]; then
        # Defensivo: alem da entrada na NVRAM, grava tambem uma copia no
        # caminho de fallback EFI/BOOT/BOOTX64.EFI — se o firmware perder ou
        # ignorar a entrada NVRAM, a maquina ainda boota pelo fallback.
        # Segunda invocacao com --removable (flag UPSTREAM): ela so copia os
        # arquivos para EFI/BOOT e NAO toca na NVRAM. NAO usar
        # --force-extra-removable: e patch exclusivo do Debian/Ubuntu e o
        # grub-install do Gentoo (vanilla) morre com "unrecognized option".
        grub-install "${args[@]}" --removable
        log_info "copia de fallback EFI/BOOT/BOOTX64.EFI gravada (grub-install --removable)"
    fi
}

# ---------------------------------------------------------------------------
# 05-grub-cfg — gera o grub.cfg
# Handbook: "Configure" (Default: GRUB) —
#   `grub-mkconfig -o /boot/grub/grub.cfg`
# O probe exige que o grub.cfg mencione o vmlinuz da versao ATUAL do kernel e
# o root=PARTUUID atual: rebuild de kernel (04) ou reparticionamento invalidam
# a sub-etapa e o grub.cfg e regenerado.
# ---------------------------------------------------------------------------

probe_grub_cfg() {
    [[ -s /boot/grub/grub.cfg ]] || return 1
    grep -qF "vmlinuz-$KERNEL_RELEASE" /boot/grub/grub.cfg || return 1
    # Sintaxe integra: um grub.cfg truncado (ENOSPC, queda no meio da escrita)
    # ainda contem a linha `linux ...` com as substrings acima, porque ela
    # aparece CEDO, antes do fechamento do menuentry — as checagens de conteudo
    # sozinhas nao distinguem arquivo completo de arquivo cortado. O
    # grub-script-check vem no mesmo pacote sys-boot/grub e recusa bloco nao
    # fechado. Se o binario nao existir, reportamos nao-feito (fail-closed).
    command -v grub-script-check > /dev/null 2>&1 || return 1
    grub-script-check /boot/grub/grub.cfg > /dev/null 2>&1 || return 1
    # Exatamente UM root= na linha do menuentry default (ver comentario do
    # probe_default_grub): duas ocorrencias significam que alguem reintroduziu
    # root= no GRUB_CMDLINE_LINUX e o 10_linux acrescentou o dele.
    grub_cfg_root_ok /boot/grub/grub.cfg
}

# grub_cfg_root_ok <arquivo>: valida as linhas `linux ...` do grub.cfg. Cada
# uma precisa ter EXATAMENTE uma ocorrencia de root= e ela precisa ser o
# PARTUUID real da raiz. Sem initramfs um root= errado (ou um segundo root=
# divergente vencendo por ser o ultimo) e maquina que nao boota, e o grep -qF
# de substring do probe antigo casava em qualquer posicao, inclusive num
# menuentry de outro sistema. Retorna 1 se nao houver nenhuma linha linux.
grub_cfg_root_ok() {
    local cfg="$1" line n found=0
    while IFS= read -r line; do
        found=1
        # conta as ocorrencias de root= nesta linha
        n="$(grep -o -- 'root=' <<< "$line" | grep -c .)" || n=0
        [[ "$n" -eq 1 ]] || return 1
        grep -qE -- "(^|[[:blank:]])root=PARTUUID=$ROOT_PARTUUID([[:blank:]]|\$)" <<< "$line" || return 1
    done < <(grep -E '^[[:blank:]]*linux[[:blank:]]' "$cfg")
    [[ "$found" -eq 1 ]]
}

# _grub_cfg_fail <tmp> <msg>: remove o temporario e morre. Existe porque o
# die() encerra o processo e um `trap ... RETURN` nao seria executado.
_grub_cfg_fail() {
    local tmp="$1"; shift
    rm -f "$tmp"
    die "$@"
}

do_grub_cfg() {
    mkdir -p /boot/grub
    # Gera para um temporario NO MESMO filesystem (/boot/grub) e so publica
    # depois de validar: o `grub-mkconfig -o` escreve DIRETO no destino final,
    # entao um ENOSPC no meio deixaria o grub.cfg truncado no lugar do bom e o
    # GRUB cairia no rescue no proximo boot. Invariante 6: verificar ANTES de
    # publicar. mv no mesmo filesystem e rename(2) — atomico.
    # grub-script-check checado ANTES de gerar: se faltar, nao ha por que
    # gastar o grub-mkconfig — e nao publicamos cfg nao validado (fail-closed).
    command -v grub-script-check > /dev/null 2>&1 \
        || die "grub-script-check nao encontrado (deveria vir com sys-boot/grub) — recusando publicar grub.cfg nao validado"
    local tmp
    tmp="$(mktemp /boot/grub/grub.cfg.new.XXXXXX)" \
        || die "nao foi possivel criar temporario em /boot/grub (disco cheio?)"
    # Cada saida de erro limpa o temporario explicitamente. NAO usar
    # `trap ... RETURN`: o die() faz exit e o trap RETURN nao dispara nesse
    # caminho, deixando grub.cfg.new.* acumulando na /boot a cada tentativa.
    grub-mkconfig -o "$tmp" \
        || _grub_cfg_fail "$tmp" "grub-mkconfig falhou — grub.cfg anterior preservado intacto"
    [[ -s "$tmp" ]] \
        || _grub_cfg_fail "$tmp" "grub-mkconfig gerou arquivo vazio — grub.cfg anterior preservado intacto"
    grub-script-check "$tmp" \
        || _grub_cfg_fail "$tmp" "grub.cfg gerado tem sintaxe invalida (truncado por disco cheio?) — grub.cfg anterior preservado intacto"
    # mktemp cria 0600; o grub-mkconfig -o tambem gera 0600 no destino final,
    # entao nao ha modo a ajustar antes de publicar.
    mv -f "$tmp" /boot/grub/grub.cfg \
        || _grub_cfg_fail "$tmp" "falha ao publicar /boot/grub/grub.cfg"
    log_info "/boot/grub/grub.cfg gerado, validado com grub-script-check e publicado"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
    # Layout fixo (1=ESP, 2=swap, 3=root) — define EFI_PART/SWAP_PART/ROOT_PART
    compute_partitions

    [[ -b "$ROOT_PART" ]] \
        || die "particao raiz $ROOT_PART nao existe — rode 00-partition.sh (fase live) antes"
    [[ -b "$EFI_PART" ]] \
        || die "ESP $EFI_PART nao existe — rode 00-partition.sh (fase live) antes"

    # PARTUUID real da raiz, direto do estado do disco (nunca de marker/cache)
    ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$ROOT_PART")" \
        || die "blkid falhou em $ROOT_PART"
    [[ -n "$ROOT_PARTUUID" ]] \
        || die "nao foi possivel obter o PARTUUID de $ROOT_PART (tabela nao e GPT?)"

    # Versao do kernel instalado pelo 04 — necessaria para o probe do grub.cfg
    KERNEL_RELEASE="$(current_kernel_release)" \
        || die "nenhum kernel encontrado (nem /usr/src/linux buildado nem /boot/vmlinuz-*) — rode 04-kernel.sh antes"
    [[ -e "/boot/vmlinuz-$KERNEL_RELEASE" ]] \
        || die "/boot/vmlinuz-$KERNEL_RELEASE nao existe — rode 04-kernel.sh (make install) antes"
    log_info "kernel corrente: $KERNEL_RELEASE — raiz: $ROOT_PART (PARTUUID=$ROOT_PARTUUID)"

    run_step 05-efi-mount    probe_efi_mount    do_efi_mount
    run_step 05-grub-emerge  probe_grub_emerge  do_grub_emerge
    run_step 05-default-grub probe_default_grub do_default_grub
    run_step 05-grub-install probe_grub_install do_grub_install
    run_step 05-grub-cfg     probe_grub_cfg     do_grub_cfg

    log_info "==== 05-bootloader concluido — GRUB instalado na ESP e grub.cfg gerado ===="
}

main "$@"
