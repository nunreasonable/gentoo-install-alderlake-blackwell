#!/usr/bin/env bash
# vars.sh — variaveis editaveis da instalacao automatizada do Gentoo.
#
# Este arquivo e APENAS sourced (nunca executado) — por isso nao tem `set -e`
# nem logica alguma; somente atribuicoes com defaults.
# A forma `: "${VAR:=default}"` permite override por variavel de ambiente:
#   TARGET_DISK=/dev/vda ./install.sh
#
# Edite os valores abaixo ANTES de rodar ./install.sh no live ISO.

# ---------------------------------------------------------------------------
# Disco e particionamento
# ---------------------------------------------------------------------------

# Disco alvo INTEIRO que sera APAGADO e reparticionado (GPT).
# Bare metal NVMe: /dev/nvme0n1 — VM QEMU com disco virtio: /dev/vda
# Symlinks estaveis (/dev/disk/by-id/..., by-path/...) tambem sao aceitos e
# ate recomendados (imunes a reordenacao de discos); validate_vars canonicaliza
# o caminho para o nome de kernel (ex.: /dev/nvme0n1) logo no inicio — prompts
# e logs sempre mostram o nome canonico.
: "${TARGET_DISK:=/dev/nvme0n1}"

# Tamanho da ESP (particao EFI, montada em /efi). Handbook atual recomenda 1GiB.
# Formato aceito: <numero>MiB ou <numero>GiB
: "${EFI_SIZE:=1GiB}"

# Tamanho da particao de swap. 16GiB e um bom valor para 32GB de RAM sem hibernacao.
: "${SWAP_SIZE:=16GiB}"

# Tamanho da particao raiz. Vazio ("") = usa todo o resto do disco (recomendado).
: "${ROOT_SIZE:=}"

# Filesystem da raiz: ext4 ou xfs.
# Nota: o Handbook atual recomenda xfs; ext4 continua perfeitamente suportado.
: "${ROOT_FS:=ext4}"

# Ponto de montagem do sistema alvo durante a fase live (padrao do Handbook).
: "${TARGET_ROOT:=/mnt/gentoo}"

# ---------------------------------------------------------------------------
# Identidade do sistema
# ---------------------------------------------------------------------------

# Hostname da maquina instalada.
: "${TARGET_HOSTNAME:=gentoo}"

# Timezone (caminho relativo a /usr/share/zoneinfo).
: "${TIMEZONE:=America/Sao_Paulo}"

# Keymap do console (teclado ABNT2 brasileiro).
: "${KEYMAP:=br-abnt2}"

# Locale principal do sistema (en_US.UTF-8 tambem e gerado sempre, como fallback).
: "${LOCALE:=pt_BR.UTF-8}"

# Sistema de init: openrc ou systemd.
# Deriva TUDO: stage3 baixado, perfil eselect, arquivos de hostname/keymap,
# svc_enable e pacotes extras. Trocar DEPOIS de comecar exige --reset + wipe.
: "${INIT_SYSTEM:=openrc}"

# ---------------------------------------------------------------------------
# Compilacao
# ---------------------------------------------------------------------------

# Jobs paralelos do make/emerge. i5-12600K tem 16 threads: 16+1 = -j17.
: "${MAKEOPTS:=-j17}"

# Valor de -march= nos COMMON_FLAGS. "native" detecta a CPU real.
# ATENCAO em VM: use `-cpu host` no QEMU, senao "native" compila para a CPU
# falsa emulada e o binario nao roda no bare metal.
: "${CFLAGS_ARCH:=native}"

# ---------------------------------------------------------------------------
# Download e verificacao
# ---------------------------------------------------------------------------

# Mirror do Gentoo para stage3 e afins.
: "${MIRROR:=https://distfiles.gentoo.org}"

# Fingerprint da chave GPG do Release Engineering do Gentoo (assina o stage3).
# Confira em https://www.gentoo.org/downloads/signatures/ — expira 2028-07-01.
: "${RELENG_KEY_FPR:=13EBBDBEDE7A12775DFDB1BABB572E0E2D182910}"

# ---------------------------------------------------------------------------
# NVIDIA (RTX 5060 Ti / Blackwell)
# ---------------------------------------------------------------------------

# Versao minima de x11-drivers/nvidia-drivers com suporte a Blackwell.
# O estavel atual (595.91.07) ja atende; isto e so a rede de seguranca.
: "${NVIDIA_MIN_VER:=580.173.02}"

# auto  = instala se `lspci -d 10de:` enxergar GPU NVIDIA, senao pula com aviso
#         (na VM sem passthrough pula sozinho; no bare metal reativa sozinho)
# force = instala mesmo sem GPU visivel (valida o build na VM)
# skip  = nunca instala
: "${NVIDIA_MODE:=auto}"

# ---------------------------------------------------------------------------
# Usuarios e senhas
# ---------------------------------------------------------------------------

# Usuario nao-root a criar. TROQUE pelo seu nome de usuario antes de instalar.
: "${USERNAME:=gentoo}"

# Grupos suplementares do usuario (separados por virgula).
: "${USER_GROUPS:=wheel,audio,video,usb,portage}"

# Hashes de senha pre-computados (formato crypt, ex.: saida de `openssl passwd -6`).
# Vazio = `passwd` interativo no final da instalacao (funciona atraves do chroot).
: "${ROOT_PASSWORD_HASH:=}"
: "${USER_PASSWORD_HASH:=}"

# ---------------------------------------------------------------------------
# Servicos e comportamento
# ---------------------------------------------------------------------------

# Habilitar sshd no boot? (yes|no)
: "${ENABLE_SSHD:=yes}"

# Habilitar cliente DHCP (dhcpcd) no boot? (yes|no)
: "${ENABLE_DHCP:=yes}"

# grub-install --removable (instala em EFI/BOOT/BOOTX64.EFI — util em VM/firmware
# teimoso que ignora entradas de NVRAM). (yes|no)
: "${GRUB_REMOVABLE:=no}"

# yes = pula a confirmacao interativa "ERASE <disco>" (SO use em VM automatizada!)
# Num sistema INSTALADO (nao live ISO) o bypass e IGNORADO: o prompt ERASE
# continua obrigatorio — protecao contra um `export AUTO_CONFIRM=yes` esquecido
# no ambiente de um host real.
: "${AUTO_CONFIRM:=no}"

# yes = permite rodar a fase live a partir de um sistema INSTALADO (nao live
# ISO) — uso deliberado: instalar num SEGUNDO disco a partir da distro atual.
# Com o default "no", a validacao aborta cedo ao detectar que o / do sistema
# em execucao vive num disco real (evidencia de que NAO estamos num live ISO).
# Mesmo com yes, AUTO_CONFIRM nunca pula o prompt ERASE num sistema instalado.
: "${ALLOW_INSTALLED_HOST:=no}"

# yes = roda `emerge -uDN @world` na etapa 03 (demora; opcional na 1a instalacao).
: "${UPDATE_WORLD:=no}"

# ---------------------------------------------------------------------------
# Preflight de hardware
# ---------------------------------------------------------------------------
#
# Este instalador e hardware-targeted (i5-12600K + RTX 5060 Ti + B760M-E D4 +
# 32 GiB + NVMe + UEFI). Antes de tocar no disco, preflight_hardware imprime
# uma tabela com um veredicto por item e ABORTA se algo for comprovadamente
# incompativel. Sao FATAIS apenas tres itens, os unicos confiaveis de detectar
# E realmente fatais: firmware sem UEFI, CPU nao-Intel e disco alvo ausente
# ou que nao e um disco inteiro. Falta de GPU NVIDIA NAO e fatal (a VM valida
# o resto e o 04 decide sozinho via NVIDIA_MODE), e nenhum match exato de
# modelo (placa, GPU, VRAM) e obrigatorio — esses sao sempre AVISO.

# yes = PULA o preflight inteiro, INCLUSIVE as tres verificacoes fatais.
# Escape hatch para hardware novo que o instalador ainda nao conhece: voce
# assume o risco de descobrir a incompatibilidade com o disco ja apagado.
: "${SKIP_HW_PREFLIGHT:=no}"

# yes = modo estrito: promove todo AVISO a FALHA, entao QUALQUER divergencia
# do hardware alvo aborta (placa diferente, GPU diferente, menos RAM...).
# Util em CI ou antes de uma instalacao de producao, para garantir que voce
# esta mesmo na maquina alvo. Com "no" (default) os avisos so sao logados.
: "${HW_PREFLIGHT_STRICT:=no}"
