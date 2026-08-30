#!/usr/bin/env bash
# 02-portage-config.sh — configuracao do Portage escrita DE FORA do chroot.
#
# Fase: live. Escreve em $TARGET_ROOT/etc/portage/ (o stage3 ja precisa ter
# sido extraido pelo 01-stage3.sh).
#
# Implementa os seguintes passos do Handbook AMD64:
#   - "Installing the Gentoo installation files > Configuring compile options"
#     (COMMON_FLAGS, MAKEOPTS em make.conf)
#   - "Installing the base system > Configuring the ACCEPT_LICENSE variable"
#     (ACCEPT_LICENSE global + excecao por pacote em package.license/)
#   - "Installing the base system > Configuring the USE variable"
#     (bloco USE vazio comentado + VIDEO_CARDS)
#   - "Configuring the bootloader > Emerge" (GRUB_PLATFORMS=efi-64 antes do grub)
#
# Idempotencia: cada arquivo gerado carrega um header fixo; o probe compara o
# sha256 do arquivo no alvo com o sha256 do conteudo desejado gerado em runtime.
# Editar vars.sh (MAKEOPTS, CFLAGS_ARCH...) muda o conteudo desejado -> o probe
# reporta nao-feito -> o arquivo e reescrito na proxima execucao.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/vars.sh"   # SEMPRE vars.sh ANTES de lib.sh
source "$SCRIPT_DIR/lib.sh"
init_logging 02-portage-config
require_phase live
validate_vars

# Restaura os mounts do alvo se preciso (idempotente; sobrevive a reboot do
# live ISO). Morre com instrucao clara se o 00 ainda nao rodou.
ensure_target_mounts
# Se o log comecou em /tmp (alvo nao montado no init_logging), anexa ao alvo.
attach_log_to_target

# Guarda de pre-requisito: o stage3 precisa estar extraido (probe real do 01).
[[ -f "$TARGET_ROOT/etc/gentoo-release" ]] \
    || die "stage3 nao encontrado em $TARGET_ROOT (falta /etc/gentoo-release) — rode 01-stage3.sh primeiro"
[[ -d "$TARGET_ROOT/etc/portage" ]] \
    || die "$TARGET_ROOT/etc/portage nao existe — stage3 corrompido ou incompleto? Re-rode 01-stage3.sh"

PORTAGE_DIR="$TARGET_ROOT/etc/portage"

# Header presente em todo arquivo gerado por este script (o probe exige ele).
GENERATED_HEADER="# GERADO-POR: gentoo-install/02-portage-config.sh — nao edite a mao; edite vars.sh e re-rode o script"

# ---------------------------------------------------------------------------
# Geradores de conteudo (deterministicos — o probe hasheia a saida deles)
# ---------------------------------------------------------------------------

# _sha256_stdin: imprime so o hash sha256 do stdin.
_sha256_stdin() {
    sha256sum | awk '{print $1}'
}

# _write_generated <arquivo> <gen_fn>: escreve a saida de gen_fn no arquivo de
# forma atomica (tmp + mv no mesmo filesystem). Nao decide nada — quem decide
# se precisa escrever e o probe do run_step.
_write_generated() {
    local file="$1" gen_fn="$2"
    "$gen_fn" > "${file}.tmp"
    mv -f "${file}.tmp" "$file"
    log_info "escrito $file"
}

# _probe_generated <arquivo> <gen_fn>: retorna 0 se o arquivo existe, contem o
# header gerado E o conteudo bate byte-a-byte (via sha256) com o desejado.
_probe_generated() {
    local file="$1" gen_fn="$2"
    [[ -f "$file" ]] || return 1
    grep -qF "$GENERATED_HEADER" "$file" || return 1
    [[ "$(_sha256_stdin < "$file")" == "$("$gen_fn" | _sha256_stdin)" ]]
}

# gen_make_conf: make.conf enxuto, conforme o Handbook AMD64
# ("Configuring compile options" + "Configuring the ACCEPT_LICENSE variable"
#  + "Configuring the USE variable" + GRUB_PLATFORMS do capitulo do bootloader).
# NAO usamos ACCEPT_LICENSE="*" global — licencas nao-livres sao liberadas
# pacote a pacote em package.license/ (ver sub-etapa 02-nvidia-license).
gen_make_conf() {
    cat <<EOF
$GENERATED_HEADER

# --- Flags de compilacao (Handbook: Configuring compile options) -----------
# -march=$CFLAGS_ARCH: no i5-12600K (Alder Lake, 6P+4E) "native" resolve para
# alderlake — P-cores e E-cores compartilham o mesmo ISA baseline (AVX-512
# desabilitado de fabrica), entao um unico -march serve para os dois tipos.
# CAVEAT VM: com "native" dentro do QEMU e OBRIGATORIO usar \`-cpu host\`,
# senao o codigo e otimizado para a CPU falsa emulada pelo QEMU e o sistema
# gerado nao corresponde ao bare metal (podendo nem rodar nele).
COMMON_FLAGS="-march=$CFLAGS_ARCH -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

# Jobs paralelos: 12600K tem 16 threads -> 16+1 (valor vem de vars.sh)
MAKEOPTS="$MAKEOPTS"

# --- USE flags (Handbook: Configuring the USE variable) --------------------
# Bloco deixado vazio de proposito: o perfil 23.0 ja traz bons defaults.
# Adicione seus USE flags aqui (desktop, gaming, pipewire, wayland...).
#USE=""

# --- Hardware (Handbook: VIDEO_CARDS / bootloader) -------------------------
# RTX 5060 Ti (Blackwell): driver proprietario nvidia (04-kernel.sh instala)
VIDEO_CARDS="nvidia"
# GRUB somente UEFI 64-bit (Handbook: Configuring the bootloader > Emerge)
GRUB_PLATFORMS="efi-64"

# --- Licencas (Handbook: Configuring the ACCEPT_LICENSE variable) ----------
# Somente licencas livres por padrao; excecoes pontuais (ex.: nvidia-drivers,
# linux-firmware, intel-microcode) entram em /etc/portage/package.license/.
# NUNCA use ACCEPT_LICENSE="*" global.
ACCEPT_LICENSE="@FREE"

# Saida de ferramentas de build sempre em ingles (facilita buscar erros)
LC_MESSAGES=C.utf8
EOF
}

# gen_nvidia_license: excecao de licenca por pacote para o driver NVIDIA
# (Handbook: ACCEPT_LICENSE > via package.license). O ramo >=595 usa a licenca
# NVIDIA-2025; NVIDIA-2023 cobre ramos anteriores (rede de seguranca caso a
# selecao de versao do 04 caia no ramo 580.x para Blackwell).
gen_nvidia_license() {
    cat <<EOF
$GENERATED_HEADER
x11-drivers/nvidia-drivers NVIDIA-2025 NVIDIA-2023
EOF
}

# ---------------------------------------------------------------------------
# Sub-etapa 02-make-conf: escreve /etc/portage/make.conf no alvo
# (Handbook: Configuring compile options — o stage3 ja traz um make.conf de
#  fabrica; substituimos pelo nosso, enxuto e regeneravel)
# ---------------------------------------------------------------------------

probe_make_conf() {
    _probe_generated "$PORTAGE_DIR/make.conf" gen_make_conf
}

do_make_conf() {
    _write_generated "$PORTAGE_DIR/make.conf" gen_make_conf
    # marker carrega o hash do conteudo gerado (registro/auditoria)
    mark_done 02-make-conf "$(gen_make_conf | _sha256_stdin)"
}

run_step 02-make-conf probe_make_conf do_make_conf

# ---------------------------------------------------------------------------
# Sub-etapa 02-package-dirs: cria os diretorios de configuracao por pacote
# (Handbook: package.use / package.license / package.accept_keywords sao a
#  forma recomendada de excecoes pontuais — os scripts 04+ escrevem neles)
# ---------------------------------------------------------------------------

probe_package_dirs() {
    [[ -d "$PORTAGE_DIR/package.use" \
    && -d "$PORTAGE_DIR/package.license" \
    && -d "$PORTAGE_DIR/package.accept_keywords" ]]
}

do_package_dirs() {
    mkdir -p "$PORTAGE_DIR/package.use" \
             "$PORTAGE_DIR/package.license" \
             "$PORTAGE_DIR/package.accept_keywords"
    log_info "diretorios package.{use,license,accept_keywords} criados em $PORTAGE_DIR"
}

run_step 02-package-dirs probe_package_dirs do_package_dirs

# ---------------------------------------------------------------------------
# Sub-etapa 02-nvidia-license: libera a licenca do driver NVIDIA por pacote
# (Handbook: Configuring the ACCEPT_LICENSE variable > package.license)
# ---------------------------------------------------------------------------

probe_nvidia_license() {
    _probe_generated "$PORTAGE_DIR/package.license/nvidia-drivers" gen_nvidia_license
}

do_nvidia_license() {
    _write_generated "$PORTAGE_DIR/package.license/nvidia-drivers" gen_nvidia_license
    mark_done 02-nvidia-license "$(gen_nvidia_license | _sha256_stdin)"
}

run_step 02-nvidia-license probe_nvidia_license do_nvidia_license

# ---------------------------------------------------------------------------
# Encerramento
# ---------------------------------------------------------------------------

# Garante o log completo no alvo (no-op se o log ja nasceu la)
attach_log_to_target
log_info "==== 02-portage-config concluido — Portage configurado em $PORTAGE_DIR ===="
