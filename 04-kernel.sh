#!/usr/bin/env bash
# 04-kernel.sh — compilacao do kernel + driver NVIDIA (fase chroot).
#
# Implementa o Handbook AMD64, capitulo "Configuring the Linux kernel":
#   - Installing firmware and/or microcode (linux-firmware + intel-microcode)
#   - Installing the kernel sources (gentoo-sources + eselect kernel)
#   - Manual configuration (defconfig + fragmento + olddefconfig)
#   - Compiling and installing (make && make modules_install && make install)
# e, fora do Handbook, o guia oficial do Gentoo Wiki "NVIDIA/nvidia-drivers"
# para a RTX 5060 Ti (Blackwell/GB206).
#
# SEM initramfs: os drivers de root/filesystem sao built-in no fragmento
# (BLK_DEV_NVME/VIRTIO_BLK/EXT4/XFS =y + DEVTMPFS_MOUNT) e o GRUB usa
# root=PARTUUID= (etapa 05).
#
# Sub-etapas (run_step):
#   04-sources      -> emerge sources+firmware+microcode, eselect kernel set 1
#   04-kernel-build -> pipeline de config + verify_kconfig (gate duro) + build
#                      (marker = sha256 do kernel-fragment.config; editar o
#                       fragmento invalida o marker e forca rebuild; o hash
#                       tambem e gravado em /boot junto do vmlinuz para que
#                       --reset NAO force rebuild de um kernel ja correto)
#   04-nvidia       -> nvidia-drivers, invalidado por rebuild de kernel
#                      (marker = "versao-instalada:hash-do-fragmento" ou
#                       "skipped-no-gpu"; upgrade de kernel muda a release e
#                       editar o fragmento muda o hash — ambos reinstalam)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/vars.sh"   # SEMPRE vars.sh ANTES de lib.sh
source "$SCRIPT_DIR/lib.sh"
init_logging 04-kernel
require_phase chroot
validate_vars

# Fragmento Kconfig aplicado sobre o defconfig (vive junto dos scripts).
FRAGMENT_FILE="$SCRIPT_DIR/kernel-fragment.config"

# ---------------------------------------------------------------------------
# Helpers locais (sem dependencias alem do stage3: bash, coreutils, portage)
# ---------------------------------------------------------------------------

# pkg_installed <categoria/nome>: checa o vardb do portage diretamente
# (nao depende de qlist/portage-utils, que pode nao estar no stage3).
pkg_installed() {
    compgen -G "/var/db/pkg/${1}-[0-9]*" > /dev/null
}

# kernel_release: imprime a release do kernel corrente (ex.: 6.18.48-gentoo).
# Fonte PRIMARIA: include/config/kernel.release, gerado pelo proprio build e
# exatamente o nome que o `make install` usa em /boot e /lib/modules — inclui
# CONFIG_LOCALVERSION e sufixo de arvore git, que o nome do diretorio NAO tem.
# Derivar do nome do diretorio como fonte primaria divergia do 05 (que sempre
# leu kernel.release): o probe procurava vmlinuz-<nome-errado>, recompilava
# ~1h a cada execucao e o probe_nvidia nunca reconhecia o driver.
# Fallback (so ANTES do primeiro build, quando kernel.release ainda nao
# existe): o nome do diretorio apontado pelo symlink /usr/src/linux, que basta
# para o probe_sources validar o `eselect kernel set`.
# Retorna 1 se nao ha arvore valida.
kernel_release() {
    local src
    src="$(readlink -f /usr/src/linux 2>/dev/null)" || return 1
    [[ -n "$src" && -f "$src/Makefile" ]] || return 1
    if [[ -r "$src/include/config/kernel.release" ]]; then
        # tr -d: o arquivo termina em newline; o $() ja a remove, mas um
        # kernel.release corrompido com CR/espacos quebraria os globs.
        local rel
        rel="$(tr -d '[:space:]' < "$src/include/config/kernel.release")"
        if [[ -n "$rel" ]]; then
            printf '%s\n' "$rel"
            return 0
        fi
    fi
    basename "$src" | sed 's/^linux-//'
}

# fragment_hash: sha256 do fragmento — gravado no marker 04-kernel-build.
fragment_hash() {
    sha256sum "$FRAGMENT_FILE" 2>/dev/null | awk '{print $1}'
}

# version_ge <a> <b>: verdadeiro se a >= b. Comparacao NUMERICA campo a campo
# via sort -V — nunca comparacao lexicografica de string (que diria que
# "99.1" > "100.1").
version_ge() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

# gpu_present: ha GPU NVIDIA (vendor 10de) no barramento PCI?
# lspci -d 10de: e o probe canonico; fallback via sysfs se lspci faltar.
# TRES estados — probe puro, SEM efeitos colaterais (nao chama die):
#   0 = GPU NVIDIA presente
#   1 = barramento legivel e sem GPU NVIDIA
#   2 = INDETERMINADO (sysfs ausente) — a POLITICA fica com o chamador.
# Antes esta funcao chamava die() direto, matando o script no meio da
# avaliacao do probe_nvidia (com CURRENT_STEP setado), o que viola o contrato
# "probe nao pode ter efeitos colaterais" (lib.sh:392-393).
gpu_present() {
    # Ambos os probes dependem do sysfs (lspci le /sys/bus/pci). Num chroot
    # entrado MANUALMENTE sem `mount --rbind /sys`, o barramento parece vazio
    # e NVIDIA_MODE=auto pularia o driver em silencio NO BARE METAL com GPU.
    # Em hardware real e em VM QEMU sempre ha dispositivos PCI, entao
    # barramento vazio == /sys ausente — nunca chutar "sem GPU".
    compgen -G '/sys/bus/pci/devices/*' > /dev/null || return 2
    if command -v lspci > /dev/null 2>&1; then
        lspci -d 10de: 2>/dev/null | grep -q .
    else
        grep -qi '^0x10de$' /sys/bus/pci/devices/*/vendor 2>/dev/null
    fi
}

# require_pci_bus: guarda de POLITICA, fail-closed, para os chamadores que
# precisam decidir sobre o nvidia. Separada do probe para que so o do_fn
# (efeito colateral permitido) mate o script.
require_pci_bus() {
    compgen -G '/sys/bus/pci/devices/*' > /dev/null \
        || die "/sys/bus/pci/devices vazio — /sys nao esta montado no chroot; monte-o (mount --rbind /sys <raiz>/sys) antes de decidir sobre o nvidia"
}

# resolve_nvidia_version: imprime a versao do melhor nvidia-drivers VISIVEL
# para o portage neste instante (vazio se nenhum) — selecao em runtime, nunca
# pinada em vars.
resolve_nvidia_version() {
    local best
    best="$(portageq best_visible / x11-drivers/nvidia-drivers 2>/dev/null || true)"
    [[ -n "$best" ]] || return 0
    echo "${best##*/nvidia-drivers-}"
}

# installed_nvidia_version: imprime a versao INSTALADA (vardb), vazio se nao ha.
installed_nvidia_version() {
    local d
    for d in /var/db/pkg/x11-drivers/nvidia-drivers-[0-9]*; do
        [[ -d "$d" ]] || return 0
        basename "$d" | sed 's/^nvidia-drivers-//'
        return 0
    done
    return 0
}

# ---------------------------------------------------------------------------
# Sub-etapa 04-sources — Handbook: "Installing firmware and/or microcode" +
# "Installing the kernel sources". Firmware e microcode vem ANTES do build
# porque o fragmento embute o ucode via EXTRA_FIRMWARE (early microcode sem
# initramfs) — o arquivo precisa existir em /lib/firmware na hora do make.
# ---------------------------------------------------------------------------

probe_sources() {
    pkg_installed sys-kernel/gentoo-sources || return 1
    pkg_installed sys-kernel/linux-firmware || return 1
    pkg_installed sys-firmware/intel-microcode || return 1
    pkg_installed sys-kernel/installkernel || return 1
    # O que importa nao e so o pacote, e o binario que o `make install` invoca.
    [[ -x /sbin/installkernel || -x /usr/sbin/installkernel ]] || return 1
    # /usr/src/linux precisa apontar para uma arvore valida (eselect kernel)
    kernel_release > /dev/null || return 1
    return 0
}

do_sources() {
    # Licencas dos blobs de firmware/microcode: ACCEPT_LICENSE="@FREE" (02) nao
    # as cobre; sem isto o emerge abaixo morre mascarado por licenca.
    # (Arquivo proprio para nao colidir com package.license/nvidia-drivers do 02.)
    mkdir -p /etc/portage/package.license
    cat > /etc/portage/package.license/kernel-firmware <<'EOF'
# Gerado por 04-kernel.sh — blobs redistribuiveis exigidos pelo hardware
sys-kernel/linux-firmware linux-fw-redistributable
sys-firmware/intel-microcode intel-ucode
EOF

    # sys-kernel/installkernel fornece /sbin/installkernel, que e QUEM o
    # `make install` do kernel chama para gravar vmlinuz-<versao>,
    # System.map-<versao> e config-<versao> em /boot.
    #
    # Sem esse pacote o `make install` NAO falha: o script de fallback do
    # proprio kernel (arch/x86/boot/install.sh) copia o bzImage para
    # /boot/vmlinuz — SEM VERSAO no nome — tenta rodar o LILO, imprime
    # "Cannot find LILO." e sai com 0. O resultado e um /boot que parece
    # populado mas nao tem o vmlinuz-<versao> que o 05 e os probes esperam.
    # Visto num smoke-test em QEMU; a verificacao pos-install abaixo pegou.
    #
    # USE PINADOS: os backends alternativos deste pacote geram INITRAMFS
    # (dracut, ugrd) ou Unified Kernel Image. Este projeto boota SEM initramfs
    # — todo driver de raiz e built-in — e um initramfs gerado aqui seria
    # referenciado pelo grub-mkconfig do 05, quebrando a premissa do design.
    # Forcamos o backend tradicional. Flags desconhecidas na arvore sao
    # ignoradas pelo portage; a garantia de verdade e a verificacao logo abaixo.
    mkdir -p /etc/portage/package.use
    cat > /etc/portage/package.use/installkernel <<'EOF'
# Gerado por 04-kernel.sh — backend tradicional, sem gerador de initramfs.
# Este projeto boota sem initramfs (drivers de raiz built-in): dracut/ugrd/uki
# aqui produziriam um initramfs que o grub-mkconfig do 05 passaria a usar.
sys-kernel/installkernel -dracut -ugrd -uki -ukify -systemd -efistub
EOF

    # Handbook: emerge das fontes + firmware + microcode (nao pinamos versao;
    # o portage resolve o estavel corrente).
    emerge sys-kernel/gentoo-sources sys-kernel/linux-firmware sys-firmware/intel-microcode \
           sys-kernel/installkernel

    # Verificar DEPOIS de instalar (invariante 6): o pacote pode estar merged e
    # ainda assim nao ter deixado o binario que o make install procura.
    [[ -x /sbin/installkernel || -x /usr/sbin/installkernel ]] \
        || die "sys-kernel/installkernel foi emergido mas nao ha /sbin/installkernel nem /usr/sbin/installkernel — o 'make install' cairia no fallback legado e gravaria /boot/vmlinuz sem versao"

    # Handbook: apontar /usr/src/linux para as fontes via eselect.
    #
    # NAO usamos "eselect kernel set 1": o indice 1 e a PRIMEIRA linha da lista,
    # nao "a arvore que acabamos de instalar". Numa instalacao nova com um unico
    # gentoo-sources os dois coincidem, mas basta uma segunda arvore existir
    # (retomada apos um `emerge` de outra versao, ou um --from 4 depois de
    # atualizar as fontes) para o indice 1 apontar para a arvore ERRADA — e o
    # kernel seria compilado a partir dela sem nenhum aviso.
    #
    # Em vez disso: perguntar ao portage QUAL versao ele instalou e selecionar
    # essa arvore por NOME exato, do mesmo jeito que o perfil e selecionado no 03.
    local src_ver src_dir
    src_ver="$(portageq best_version / sys-kernel/gentoo-sources)" \
        || die "nao consegui consultar a versao instalada de sys-kernel/gentoo-sources"
    [[ -n "$src_ver" ]] || die "sys-kernel/gentoo-sources nao aparece como instalado apos o emerge"
    # best_version devolve o atom completo (sys-kernel/gentoo-sources-6.18.48);
    # o diretorio correspondente e /usr/src/linux-<versao>-gentoo.
    src_dir="/usr/src/linux-${src_ver#sys-kernel/gentoo-sources-}-gentoo"
    [[ -d "$src_dir" ]] \
        || die "arvore de fontes esperada nao existe: $src_dir (portage reporta $src_ver) — verifique 'eselect kernel list'"

    # Seleciona por NOME (nao por indice). Evitamos deliberadamente parsear a
    # saida de 'eselect kernel list': o formato (indentacao, numeracao, o '*' do
    # selecionado) e apresentacao, nao API. Se o eselect nao aceitar o nome,
    # caimos no symlink direto — que e literalmente tudo que o eselect kernel
    # faz, e o 'list' passa a mostrar essa arvore como selecionada do mesmo jeito.
    if ! eselect kernel set "${src_dir#/usr/src/}" 2>/dev/null; then
        log_warn "'eselect kernel set ${src_dir#/usr/src/}' falhou — apontando /usr/src/linux diretamente"
        ln -sfn "$src_dir" /usr/src/linux
    fi

    # Verificacao apos instalar (invariante 6): o symlink tem que apontar para a
    # arvore que o portage instalou, nao para outra qualquer.
    local linked
    linked="$(readlink -f /usr/src/linux)" \
        || die "/usr/src/linux nao existe ou nao resolve apos o eselect kernel"
    [[ "$linked" == "$(readlink -f "$src_dir")" ]] \
        || die "/usr/src/linux aponta para '$linked', esperado '$src_dir' — recuse compilar a arvore errada"
    log_info "fontes do kernel selecionadas: $src_dir ($src_ver)"

    # Sanidade: o ucode do 12600K (family 6 model 151 stepping 2) que o
    # fragmento embute via EXTRA_FIRMWARE deve existir. Em VM a CPU e outra,
    # mas o pacote intel-microcode instala a colecao inteira — so avisa.
    if [[ ! -e /lib/firmware/intel-ucode/06-97-02 ]]; then
        log_warn "/lib/firmware/intel-ucode/06-97-02 nao encontrado — o build do kernel falhara no EXTRA_FIRMWARE se o fragmento o referenciar"
    fi
}

# ---------------------------------------------------------------------------
# Sub-etapa 04-kernel-build — Handbook: "Manual configuration" +
# "Compiling and installing". Pipeline: defconfig -> merge do fragmento ->
# olddefconfig -> verify_kconfig (gate DURO) -> make/modules_install/install.
# ---------------------------------------------------------------------------

# verify_kconfig <caminho-do-.config>: gate DURO das assercoes obrigatorias.
# merge_config.sh so AVISA quando um simbolo pedido nao vinga (dependencia
# faltando, simbolo renomeado entre versoes...) — aqui qualquer falta e FATAL,
# antes de gastar horas compilando um kernel que nao boota.
verify_kconfig() {
    local config="$1" sym
    local -a missing=()
    # Obrigatorios =y (lista minima do plano): boot NVMe/virtio sem initramfs,
    # EFI/GPT/ESP, console pre-driver, cpufreq hybrid-aware do Alder Lake.
    local -a required=(
        BLK_DEV_NVME        # root NVMe sem initramfs exige built-in
        EXT4_FS             # qualquer um dos dois pode ser root ($ROOT_FS)
        XFS_FS
        EFI_STUB
        EFI_PARTITION       # tabela GPT
        VFAT_FS             # ESP
        DEVTMPFS_MOUNT      # /dev automatico no boot sem initramfs
        VIRTIO_PCI          # mesmo kernel boota na VM QEMU
        VIRTIO_BLK
        USB_XHCI_HCD        # teclado USB antes de modulos
        HID                 # camada HID: sem ela nao ha teclado nenhum
        USB_HID             # tristate no Kconfig: pode virar =m e sumir do
        HID_GENERIC         #   boot (prompt de fsck/senha) sem initramfs
        EFI                 # suporte EFI (EFI_STUB sozinho nao basta)
        DEVTMPFS            # base do DEVTMPFS_MOUNT abaixo
        NLS_CODEPAGE_437    # sem os dois NLS, VFAT_FS=y monta a ESP so por
        NLS_ISO8859_1       #   sorte do NLS_DEFAULT
        FW_LOADER           # firmware GSP: OBRIGATORIO em Blackwell +
                            #   EXTRA_FIRMWARE (early ucode sem initramfs)
        MODULES             # nvidia e out-of-tree
        X86_INTEL_PSTATE    # unico cpufreq hybrid-aware (P+E cores)
        SCHED_MC_PRIO       # ITMT: P-cores preferidos sobre E-cores
        MTRR                # exigido pelo nvidia-drivers
        # Grupo de console pre-driver: sem ele o boot e TELA PRETA ate o
        # nvidia-drm assumir — e o fragmento (blocos 143-157) ja pede os
        # quatro, entao a ausencia aqui e furo do gate, nao escolha.
        DRM                 # base do DRM (SIMPLEDRM/FBDEV_EMULATION dependem)
        SYSFB_SIMPLEFB      # framebuffer que a UEFI/GOP deixou
        DRM_SIMPLEDRM       # console pre-nvidia + puxa DRM_KMS_HELPER
        DRM_FBDEV_EMULATION # fbdev sobre DRM
        FRAMEBUFFER_CONSOLE # fbcon: o console de texto propriamente dito
    )
    for sym in "${required[@]}"; do
        grep -qx "CONFIG_${sym}=y" "$config" || missing+=("CONFIG_${sym}=y (ausente ou nao built-in)")
    done
    # DRM_TTM_HELPER: cheque FATAL (sem '~') do CONFIG_CHECK do nvidia-drivers
    # em kernel >=6.11 com DRM_FBDEV_EMULATION. Simbolo sem prompt, garantido
    # no fragmento via DRM_QXL=m (que o seleciona) — por isso fica
    # legitimamente =m e NAO pode entrar no array required (que exige =y);
    # o linux_chkconfig_present do ebuild aceita y ou m.
    if ! grep -Eqx 'CONFIG_DRM_TTM_HELPER=(y|m)' "$config"; then
        missing+=("CONFIG_DRM_TTM_HELPER=y|m (ausente — DRM_QXL=m no fragmento deveria seleciona-lo; exigido pelo nvidia-drivers em kernel >=6.11)")
    fi
    # Proibidos: nouveau conflita com o driver proprietario; MODULE_SIG_FORCE
    # recusaria carregar o modulo nvidia nao assinado.
    if grep -q '^CONFIG_DRM_NOUVEAU=' "$config"; then
        missing+=("CONFIG_DRM_NOUVEAU deve ficar DESATIVADO (conflita com nvidia)")
    fi
    if grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$config"; then
        missing+=("CONFIG_MODULE_SIG_FORCE deve ficar DESATIVADO (modulo nvidia nao assinado)")
    fi
    if (( ${#missing[@]} > 0 )); then
        local m
        for m in "${missing[@]}"; do
            log_error "verify_kconfig: $m"
        done
        die "verify_kconfig: ${#missing[@]} assercao(oes) falharam no .config final — corrija o kernel-fragment.config (simbolo renomeado/dependencia faltando?) e re-execute"
    fi
    log_info "verify_kconfig: todas as assercoes obrigatorias presentes no .config"
}

probe_kernel_build() {
    local kver frag
    kver="$(kernel_release)" || return 1
    # vmlinuz instalado pelo `make install` para a versao corrente das fontes
    compgen -G "/boot/vmlinuz-${kver}*" > /dev/null || return 1
    # modulos instalados
    [[ -d "/lib/modules/${kver}" ]] || return 1
    # hash do fragmento: editar o fragmento muda o hash, invalida e forca o
    # rebuild. Duas fontes aceitas para o hash do BUILD:
    #   1. o marker (valor gravado por mark_done, nao "done" generico);
    #   2. /boot/kernel-fragment.sha256-<kver>, gravado por do_kernel_build
    #      junto do vmlinuz — sobrevive ao --reset (que apaga so o state dir),
    #      entao um kernel integro e atual NAO e recompilado por horas so
    #      porque os markers sumiram (probe funcional e a autoridade).
    # Nota: se o probe passar via fonte 2 sem marker, o run_step regrava um
    # marker generico "done" — inofensivo, a fonte 2 segue validando.
    [[ -f "$FRAGMENT_FILE" ]] || return 1
    frag="$(fragment_hash)"
    [[ -n "$frag" ]] || return 1
    [[ "$(step_value 04-kernel-build)" == "$frag" ]] && return 0
    # Fonte 2: a sentinela em /boot. Ela grava DOIS campos — o hash do
    # fragmento E o sha256 do vmlinuz que descreve — e os dois precisam bater.
    # So o hash do fragmento nao amarrava a sentinela ao kernel: um build
    # posterior que falhasse no meio deixava a sentinela antiga validando um
    # vmlinuz que ja nao correspondia a ela.
    local sent_frag sent_vm vmlinuz
    if [[ -r "/boot/kernel-fragment.sha256-${kver}" ]]; then
        read -r sent_frag sent_vm < "/boot/kernel-fragment.sha256-${kver}" || true
        if [[ "$sent_frag" == "$frag" && -n "$sent_vm" ]]; then
            vmlinuz="/boot/vmlinuz-${kver}"
            if [[ -f "$vmlinuz" ]] \
               && [[ "$(sha256sum "$vmlinuz" 2>/dev/null | awk '{print $1}')" == "$sent_vm" ]]; then
                return 0
            fi
        fi
    fi
    return 1
}

do_kernel_build() {
    [[ -f "$FRAGMENT_FILE" ]] \
        || die "fragmento $FRAGMENT_FILE nao encontrado — ele deve viver no mesmo diretorio dos scripts"
    local frag_hash
    frag_hash="$(fragment_hash)"

    # Sentinela invalidada ANTES do build (padrao do 01): a partir daqui o
    # kernel em /boot esta em transicao. Se o build ou o `make install`
    # falharem no meio, NAO fica sentinela antiga validando um vmlinuz que ja
    # nao corresponde a ela — o proximo probe falha e o build recomeca.
    local kver_old
    if kver_old="$(kernel_release)"; then
        rm -f "/boot/kernel-fragment.sha256-${kver_old}"
    fi

    # Subshell: o cd nao vaza para o resto do script; qualquer falha dentro
    # derruba o script via set -e + trap ERR.
    (
        cd /usr/src/linux

        # Handbook (manual configuration): partimos do defconfig da arquitetura
        # (base viva, nao um .config congelado que apodrece entre versoes)...
        make defconfig

        # ...aplicamos o fragmento por cima (-m = so mescla, sem rodar target)...
        ./scripts/kconfig/merge_config.sh -m .config "$FRAGMENT_FILE"

        # ...e resolvemos dependencias com defaults para o que o fragmento
        # nao fixou.
        make olddefconfig

        # Gate duro ANTES de compilar: merge_config.sh so avisa, nos morremos.
        verify_kconfig /usr/src/linux/.config

        # Handbook (compiling and installing). MAKEOPTS sem aspas de proposito:
        # precisa sofrer word splitting (ex.: "-j17 -l16").
        # shellcheck disable=SC2086
        make $MAKEOPTS
        make modules_install
        # make install copia vmlinuz + System.map + config para /boot
        # (que fica na raiz — a ESP montada em /efi guarda so o GRUB).
        make install
    )

    # Hash do fragmento TAMBEM em /boot, junto do vmlinuz: e um artefato do
    # proprio build (fora do state dir), entao sobrevive ao --reset e permite
    # ao probe reconhecer este kernel como feito sem depender do marker.
    # Promovida so AQUI, depois do make install: dois campos, "<hash-do-
    # fragmento> <sha256-do-vmlinuz>", para amarrar a sentinela ao kernel que
    # ela de fato descreve.
    local kver vm_hash
    kver="$(kernel_release)" \
        || die "build concluido mas /usr/src/linux nao aponta para uma arvore valida — nao da para derivar a release do kernel"
    [[ -f "/boot/vmlinuz-${kver}" ]] \
        || die "make install concluido mas /boot/vmlinuz-${kver} nao existe — a release derivada nao casa com o que foi instalado em /boot. Causa tipica: /sbin/installkernel ausente, e o fallback do kernel gravou /boot/vmlinuz SEM versao (procure por 'Cannot find LILO.' no log). Confira 'ls /boot' e que sys-kernel/installkernel esta instalado."

    # Nenhum initramfs pode ter sido gerado: este sistema boota sem initramfs
    # (drivers de raiz built-in, root=PARTUUID). Se um backend do installkernel
    # produziu um, o grub-mkconfig do 05 passaria a referencia-lo e a premissa
    # do design cairia em silencio. Falha aqui, alto e claro.
    local stray_initrd
    stray_initrd="$(find /boot -maxdepth 1 \( -name 'initramfs-*' -o -name 'initrd-*' -o -name 'initramfs.img*' \) -printf '%f ' 2>/dev/null || true)"
    [[ -z "$stray_initrd" ]] \
        || die "initramfs encontrado em /boot ($stray_initrd) — este projeto boota SEM initramfs. Um backend de sys-kernel/installkernel (dracut/ugrd/uki) foi ativado apesar do package.use; revise /etc/portage/package.use/installkernel e remova o(s) arquivo(s) antes de seguir."

    # Restos do fallback legado (uma execucao anterior sem /sbin/installkernel
    # grava /boot/vmlinuz e /boot/System.map SEM versao). Nao apagamos nada em
    # /boot automaticamente — so avisamos, porque decidir o que remover do
    # diretorio de boot e do operador.
    local f
    for f in /boot/vmlinuz /boot/System.map /boot/vmlinuz.old /boot/System.map.old; do
        [[ -f "$f" ]] && log_warn "resto de execucao anterior sem installkernel: $f (sem versao no nome). Inofensivo para o GRUB, que lista vmlinuz-*, mas pode ser removido a mao."
    done

    vm_hash="$(sha256sum "/boot/vmlinuz-${kver}" | awk '{print $1}')"
    printf '%s %s\n' "$frag_hash" "$vm_hash" > "/boot/kernel-fragment.sha256-${kver}"

    # Marker com valor: o hash do fragmento usado neste build.
    mark_done 04-kernel-build "$frag_hash"
}

# ---------------------------------------------------------------------------
# Sub-etapa 04-nvidia — Gentoo Wiki "NVIDIA/nvidia-drivers" (fora do Handbook).
# Roda por ULTIMO: o modulo compila contra o kernel recem-buildado, e um
# rebuild de kernel invalida esta sub-etapa (o probe exige o .ko na arvore
# de modulos da versao corrente E o marker casando com o hash atual do
# fragmento — cobre tambem rebuild de MESMA versao apos editar o fragmento).
# ---------------------------------------------------------------------------

probe_nvidia() {
    # skip: nunca instala — sempre considerado feito
    if [[ "$NVIDIA_MODE" == "skip" ]]; then
        return 0
    fi
    # probe funcional: pacote instalado no vardb...
    local marker inst kver gpu
    marker="$(step_value 04-nvidia)"
    inst="$(installed_nvidia_version)"

    # "Nada a fazer por falta de GPU" e derivado do ESTADO REAL (gpu_present +
    # NVIDIA_MODE + vardb), NUNCA do marker: este era o unico ramo do projeto
    # em que o marker alterava a SEMANTICA do probe. O marker "skipped-no-gpu"
    # vira registro de auditoria puro. Exigir vardb vazio garante que jamais
    # reportamos "pulado por falta de GPU" num sistema com o driver instalado
    # (esse caso cai no probe funcional abaixo, que e mais forte).
    gpu_present && gpu=0 || gpu=$?
    if [[ -z "$inst" && "$gpu" -eq 1 && "$NVIDIA_MODE" == "auto" ]]; then
        # sem GPU, sem driver e modo auto: do_nvidia so registraria o skip
        return 0
    fi
    # gpu=2 (sysfs ausente) NAO satisfaz o ramo acima: fail-closed, cai no
    # probe funcional e, se ele falhar, do_nvidia morre em require_pci_bus.

    [[ -n "$inst" ]] || return 1
    # ...E modulo presente na arvore do kernel CORRENTE (upgrade de kernel
    # muda a versao e derruba este teste => reinstala o driver)
    kver="$(kernel_release)" || return 1
    compgen -G "/lib/modules/${kver}/video/nvidia.ko*" > /dev/null || return 1
    # ...E o marker precisa casar com a versao instalada + hash ATUAL do
    # fragmento. Rebuild de MESMA versao (gatilho tipico: editar o
    # kernel-fragment.config) nao muda kver e `make modules_install` nao
    # remove /lib/modules/$kver/video/nvidia.ko — so o hash detecta que o
    # modulo foi compilado contra um .config antigo => reinstala o driver.
    [[ "$marker" == "${inst}:$(fragment_hash)" ]] || return 1
    return 0
}

do_nvidia() {
    # Politica no do_fn (efeito colateral permitido aqui, ao contrario do
    # probe): sysfs ausente e erro fatal, nunca "sem GPU".
    require_pci_bus
    if ! gpu_present; then
        if [[ "$NVIDIA_MODE" == "auto" ]]; then
            log_warn "=================================================================="
            log_warn "!!  NENHUMA GPU NVIDIA VISIVEL (lspci -d 10de: vazio)           !!"
            log_warn "!!  PULANDO a instalacao do nvidia-drivers (NVIDIA_MODE=auto).  !!"
            log_warn "!!  Numa VM sem passthrough isto e o esperado. No bare metal    !!"
            log_warn "!!  com a RTX 5060 Ti a sub-etapa REATIVA SOZINHA na proxima    !!"
            log_warn "!!  execucao. Para validar o build sem GPU: NVIDIA_MODE=force.  !!"
            log_warn "=================================================================="
            mark_done 04-nvidia skipped-no-gpu
            return 0
        fi
        # NVIDIA_MODE=force: segue em frente — o CONFIG_CHECK do ebuild audita
        # nosso kernel mesmo sem GPU (validacao de build na VM)
        log_warn "NVIDIA_MODE=force: instalando nvidia-drivers SEM GPU visivel (validacao de build)"
    fi

    # Selecao de versao em RUNTIME: o que o portage enxerga agora vs o minimo
    # com suporte a Blackwell ($NVIDIA_MIN_VER). Hoje o estavel (595.91.07)
    # ja atende; isto e rede de seguranca contra arvores antigas.
    #
    # O accept_keywords e NOSSO (so este script o escreve) — remover ANTES de
    # resolver, simetrico com o package.use abaixo: se o estavel corrente ja
    # satisfaz o minimo, o arquivo some de vez (sem deixar ~amd64 permanente
    # poluindo os `emerge -uDN @world` futuros); se ainda nao satisfaz, o
    # fluxo abaixo o reescreve — ele so persiste enquanto for necessario.
    rm -f /etc/portage/package.accept_keywords/nvidia-drivers
    local ver base
    ver="$(resolve_nvidia_version)"
    if [[ -z "$ver" ]] || ! version_ge "${ver%%-r*}" "$NVIDIA_MIN_VER"; then
        log_warn "melhor nvidia-drivers visivel ('${ver:-nenhum}') < minimo Blackwell ($NVIDIA_MIN_VER) — liberando ~amd64 para o pacote"
        mkdir -p /etc/portage/package.accept_keywords
        cat > /etc/portage/package.accept_keywords/nvidia-drivers <<EOF
# Gerado por 04-kernel.sh — o estavel da arvore ainda nao suporta Blackwell
>=x11-drivers/nvidia-drivers-${NVIDIA_MIN_VER} ~amd64
EOF
        ver="$(resolve_nvidia_version)"
        if [[ -z "$ver" ]] || ! version_ge "${ver%%-r*}" "$NVIDIA_MIN_VER"; then
            die "mesmo com ~amd64, nenhum nvidia-drivers >= $NVIDIA_MIN_VER visivel (melhor: '${ver:-nenhum}') — arvore do portage muito antiga? rode emerge --sync e re-execute"
        fi
    fi
    base="${ver%%-r*}"
    log_info "nvidia-drivers resolvido em runtime: $ver (minimo Blackwell: $NVIDIA_MIN_VER)"

    # Ramo 580.x: USE kernel-open e OBRIGATORIO para Blackwell (GSP-only).
    # Em >=595 o flag nao existe mais (modulos abertos sempre) — nesse caso
    # removemos nosso arquivo para nao poluir com USE de flag inexistente.
    mkdir -p /etc/portage/package.use
    if [[ "$base" == 580.* ]]; then
        cat > /etc/portage/package.use/nvidia-drivers <<'EOF'
# Gerado por 04-kernel.sh — ramo 580.x: kernel-open obrigatorio p/ Blackwell
x11-drivers/nvidia-drivers kernel-open
EOF
        log_info "ramo 580.x: package.use/nvidia-drivers com kernel-open gravado"
    else
        # arquivo e NOSSO (so este script o escreve) — remover e seguro
        rm -f /etc/portage/package.use/nvidia-drivers
        # ...mas remover o NOSSO arquivo nao basta: em >=595 o flag kernel-open
        # nao existe mais e o emerge morre com "unknown USE flag". Se o usuario
        # deixou kernel-open em OUTRO arquivo do package.use/ ou no make.conf,
        # a falha so apareceria depois de horas de compilacao. Varremos antes
        # e abortamos com mensagem acionavel (fail-closed).
        local -a stray=()
        local f
        if [[ -d /etc/portage/package.use ]]; then
            while IFS= read -r f; do
                stray+=("$f")
            done < <(grep -rlsE '(^|[[:space:]])-?kernel-open([[:space:]]|$)' \
                        /etc/portage/package.use 2>/dev/null || true)
        fi
        # make.conf: so o USE global importa (linhas comentadas nao contam)
        if [[ -f /etc/portage/make.conf ]] \
           && grep -qsE '^[[:space:]]*USE=.*[^-[:alnum:]]kernel-open' /etc/portage/make.conf; then
            stray+=(/etc/portage/make.conf)
        fi
        if (( ${#stray[@]} > 0 )); then
            local s
            for s in "${stray[@]}"; do
                log_error "kernel-open encontrado em: $s"
            done
            die "nvidia-drivers $ver (ramo >=595) NAO tem mais o USE flag kernel-open (os modulos abertos sao sempre usados) — remova 'kernel-open' dos arquivos listados acima e re-execute, senao o emerge falhara apos horas de compilacao"
        fi
    fi

    # Emerge do driver (compila o modulo contra /usr/src/linux recem-buildado;
    # o CONFIG_CHECK do ebuild valida o nosso .config de novo).
    emerge x11-drivers/nvidia-drivers

    local installed
    installed="$(installed_nvidia_version)"
    [[ -n "$installed" ]] || die "emerge terminou mas nvidia-drivers nao consta no vardb — instalacao inconsistente"
    # Marker com valor: versao instalada + hash do fragmento contra o qual o
    # modulo foi compilado — o probe compara com o hash ATUAL, entao rebuild
    # de kernel de MESMA versao (fragmento editado) invalida esta sub-etapa.
    mark_done 04-nvidia "${installed}:$(fragment_hash)"
    log_info "nvidia-drivers $installed instalado"
}

# ---------------------------------------------------------------------------
# Execucao
# ---------------------------------------------------------------------------

run_step 04-sources      probe_sources      do_sources
run_step 04-kernel-build probe_kernel_build do_kernel_build

if [[ "$NVIDIA_MODE" == "skip" ]]; then
    log_info "NVIDIA_MODE=skip — sub-etapa 04-nvidia pulada por configuracao"
else
    run_step 04-nvidia probe_nvidia do_nvidia
fi

log_info "==== 04-kernel concluido ===="
