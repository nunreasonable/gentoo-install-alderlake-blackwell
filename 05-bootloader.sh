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
    local newest
    newest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | grep -v '\.old$' | sed 's|.*/vmlinuz-||' | sort -V | tail -n1)"
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
# root=PARTUUID e obrigatorio aqui (sem initramfs, ver cabecalho do script);
# intel_iommu=on liga a IOMMU (o kernel do 04 tem INTEL_IOMMU=y mas
# INTEL_IOMMU_DEFAULT_ON desligado — a decisao fica na cmdline).
# ---------------------------------------------------------------------------

probe_default_grub() {
    [[ -f /etc/default/grub ]] || return 1
    grep -qx 'GRUB_DISABLE_LINUX_UUID=true' /etc/default/grub || return 1
    # O PARTUUID gravado precisa ser o PARTUUID REAL atual da raiz: um
    # reparticionamento (novo PARTUUID) invalida o arquivo e forca reescrita.
    grep -qF "root=PARTUUID=$ROOT_PARTUUID" /etc/default/grub || return 1
    grep -qF 'intel_iommu=on' /etc/default/grub
}

do_default_grub() {
    cat > /etc/default/grub <<EOF
# /etc/default/grub — gerado por 05-bootloader.sh (instalacao automatizada).
# Reescrito automaticamente se o root=PARTUUID divergir do estado real do disco.

GRUB_DISTRIBUTOR="Gentoo"
GRUB_TIMEOUT=5

# Sem initramfs o kernel nao resolve root=UUID= (UUID de filesystem e coisa de
# userspace); root=PARTUUID= e resolvido pelo proprio kernel via GPT.
GRUB_DISABLE_LINUX_UUID=true
GRUB_DISABLE_LINUX_PARTUUID=false

# root=       : raiz por PARTUUID (particao 3 de $TARGET_DISK)
# intel_iommu : liga a IOMMU (VT-d) — o kernel foi buildado com
#               INTEL_IOMMU_DEFAULT_ON desligado de proposito
GRUB_CMDLINE_LINUX="root=PARTUUID=$ROOT_PARTUUID intel_iommu=on"
EOF
    log_info "/etc/default/grub escrito (root=PARTUUID=$ROOT_PARTUUID)"
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

probe_grub_install() {
    if [[ "$GRUB_REMOVABLE" == "yes" ]]; then
        # --removable instala no caminho de fallback (FAT e case-insensitive,
        # mas o find -ipath cobre variacoes de caixa por garantia)
        find /efi/EFI -maxdepth 2 -type f -ipath '*/boot/bootx64.efi' 2>/dev/null | grep -q .
    else
        # Instalacao padrao: EFI/<bootloader-id>/grubx64.efi na ESP...
        find /efi/EFI -maxdepth 2 -type f -iname 'grubx64.efi' 2>/dev/null | grep -q . || return 1
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

do_grub_install() {
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
    grep -qF "root=PARTUUID=$ROOT_PARTUUID" /boot/grub/grub.cfg
}

do_grub_cfg() {
    mkdir -p /boot/grub
    grub-mkconfig -o /boot/grub/grub.cfg
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
