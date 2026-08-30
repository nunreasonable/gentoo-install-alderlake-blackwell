#!/usr/bin/env bash
# 00-partition.sh — Handbook AMD64, "Preparing the disks":
#   - particionamento GPT via sgdisk (layout UEFI: ESP + swap + root)
#   - criacao dos filesystems (mkfs.vfat, mkswap, mkfs.ext4/xfs)
#   - montagem do sistema alvo (root em $TARGET_ROOT, ESP em $TARGET_ROOT/efi)
#
# Fase: live (roda no minimal install ISO, NUNCA dentro do chroot).
# Idempotente: cada sub-etapa passa por run_step com probe funcional; nenhuma
# acao destrutiva decide com base em marker — so no estado real do disco.
# confirm_destruction so e chamada quando o probe do layout diz que a tabela
# GPT atual NAO bate com o layout esperado — ou, via _confirm_reformat, quando
# um mkfs vai destruir um filesystem existente sem que a 00-gpt tenha rodado
# nesta execucao.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/vars.sh"
source "$SCRIPT_DIR/lib.sh"
init_logging 00-partition
require_phase live
validate_vars

# Devices das 3 particoes (EFI_PART/SWAP_PART/ROOT_PART), com sufixo "p"
# correto para nvme/vd/sd — nunca concatenar na mao.
compute_partitions

# Type GUIDs GPT do layout fixo (equivalentes aos codigos sgdisk ef00/8200/8300).
readonly GUID_ESP="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"   # ef00 EFI System
readonly GUID_SWAP="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"  # 8200 Linux swap
readonly GUID_ROOT="0FC63DAF-8483-4772-8E79-3D69D8477DE4"  # 8300 Linux filesystem

# ---------------------------------------------------------------------------
# Helpers locais
# ---------------------------------------------------------------------------

# _sgdisk_size <valor>: converte o formato de vars.sh (1GiB/512MiB) para o
# sufixo de uma letra que o sgdisk entende (1G/512M — binario, mesmo valor).
_sgdisk_size() {
    echo "${1%iB}"
}

# _part_matches <numero> <type-guid> <partlabel>: retorna 0 se a particao N do
# disco alvo existe com o type GUID e o PARTLABEL exatos. Somente leitura.
_part_matches() {
    local n="$1" guid="$2" label="$3" info
    info="$(sgdisk -i "$n" "$TARGET_DISK" 2>/dev/null)" || return 1
    grep -qi "^Partition GUID code: ${guid}" <<< "$info" || return 1
    grep -q  "^Partition name: '${label}'" <<< "$info" || return 1
}

# _assert_not_mounted_elsewhere <device>: mkfs/mkswap recusam rodar se a
# particao estiver montada (ou ativa como swap) em qualquer lugar — o do_fn
# so roda quando o filesystem esta errado/ausente, entao qualquer mount ativo
# aqui e situacao anomala que exige intervencao manual.
_assert_not_mounted_elsewhere() {
    local dev="$1" mnt
    mnt="$(findmnt -rno TARGET "$dev" 2>/dev/null || true)"
    [[ -z "$mnt" ]] \
        || die "particao $dev esta montada em '$mnt' — desmonte antes de reformatar"
    if grep -q "^$(realpath "$dev") " /proc/swaps; then
        die "particao $dev esta ativa como swap — rode swapoff antes de reformatar"
    fi
}

# _fs_type <device>: imprime o TYPE do blkid (vazio se sem filesystem/ausente).
_fs_type() {
    blkid -s TYPE -o value "$1" 2>/dev/null || true
}

# Flags de processo das guardas destrutivas abaixo:
#   GPT_RECREATED......... do_gpt rodou NESTA execucao (particoes recem-criadas
#                          e ja limpas pelo wipefs);
#   REFORMAT_CONFIRMED.... cache do prompt de _confirm_reformat (pergunta no
#                          maximo uma vez por execucao).
GPT_RECREATED="no"
REFORMAT_CONFIRMED="no"

# _confirm_reformat <device>: guarda das sub-etapas 00-mkfs-*. Quando a 00-gpt
# foi PULADA nesta execucao (layout GPT ja batia — ex.: disco de uma instalacao
# anterior feita por estes scripts) mas a particao contem uma assinatura de
# filesystem que o mkfs vai destruir (caso tipico: ROOT_FS trocado em vars.sh),
# o "ERASE <disco>" nunca foi digitado nesta execucao — re-exige a mesma
# confirmacao do do_gpt antes de reformatar. Particao recem-criada ou sem
# assinatura segue sem prompt.
_confirm_reformat() {
    local dev="$1" fstype
    [[ "$GPT_RECREATED" == "no" ]] || return 0
    fstype="$(_fs_type "$dev")"
    [[ -n "$fstype" ]] || return 0
    [[ "$REFORMAT_CONFIRMED" == "no" ]] || return 0
    log_warn "particao $dev contem um filesystem '$fstype' que sera destruido, mas a confirmacao ERASE nao foi exigida nesta execucao (00-gpt foi pulada: o layout GPT ja batia)"
    confirm_destruction
    REFORMAT_CONFIRMED="yes"
}

# ---------------------------------------------------------------------------
# Sub-etapa 00-gpt — Handbook: "Partitioning the disk with GPT for UEFI"
# Layout fixo: 1=ESP (+$EFI_SIZE, ef00, gentoo-esp), 2=swap (+$SWAP_SIZE, 8200,
# gentoo-swap), 3=root ($ROOT_SIZE ou resto do disco, 8300, gentoo-root).
# ---------------------------------------------------------------------------

# Probe: a tabela GPT atual bate com o layout esperado? Checa numero exato de
# particoes (3) + type GUID + PARTLABEL de cada uma via sgdisk. Sem efeitos
# colaterais — apenas leitura.
probe_gpt() {
    sgdisk -p "$TARGET_DISK" > /dev/null 2>&1 || return 1
    local nparts
    nparts="$(lsblk -nro TYPE "$TARGET_DISK" | grep -c '^part$' || true)"
    [[ "$nparts" -eq 3 ]] || return 1
    _part_matches 1 "$GUID_ESP"  "$EFI_PARTLABEL"  || return 1
    _part_matches 2 "$GUID_SWAP" "$SWAP_PARTLABEL" || return 1
    _part_matches 3 "$GUID_ROOT" "$ROOT_PARTLABEL" || return 1
}

do_gpt() {
    # O probe ja disse que o layout NAO bate: confirmacao destrutiva exigida
    # (AUTO_CONFIRM=yes bypassa em VM). O outro caminho que exige confirmacao
    # e o _confirm_reformat dos 00-mkfs-*, quando esta sub-etapa e pulada.
    confirm_destruction

    # O log deste script pode estar dentro do alvo (re-particionamento
    # standalone com o alvo montado) — solta o fd do tee antes de desmontar
    # (detach_logging_to_tmp e o helper compartilhado de lib.sh).
    detach_logging_to_tmp

    # Solta qualquer uso residual do disco alvo antes do zap: desativa swap e
    # desmonta o alvo (validate_vars ja garantiu que nada esta montado fora de
    # $TARGET_ROOT).
    local dev mnt
    while read -r dev mnt; do
        [[ "$mnt" == "[SWAP]" ]] || continue
        swapoff "$dev"
        log_info "swap desativado em $dev"
    done < <(lsblk -nrpo NAME,MOUNTPOINT "$TARGET_DISK")

    # umount -R cobre tambem pseudo-mounts (proc/sys/dev/run) que
    # ensure_chroot_mounts possa ter deixado sob o alvo — eles nao aparecem no
    # lsblk do disco e fariam um umount simples de $TARGET_ROOT falhar por
    # child mounts. Retry: o tee antigo pode levar um instante para soltar o
    # fd apos o detach_logging_to_tmp (mesma logica do repartition_prep do
    # install.sh).
    if mountpoint -q "$TARGET_ROOT"; then
        local try ok="no"
        for try in 1 2 3 4 5; do
            if umount -R "$TARGET_ROOT" 2>/dev/null; then
                ok="yes"
                break
            fi
            sleep 1
        done
        [[ "$ok" == "yes" ]] \
            || die "nao foi possivel desmontar $TARGET_ROOT — feche o que estiver usando o alvo e tente de novo"
        log_info "desmontado (recursivo) $TARGET_ROOT"
    fi

    # Cinto e suspensorio: qualquer particao do disco ainda montada em outro
    # lugar (validate_vars ja barrou esse cenario, mas confere antes do zap).
    # sort -rk2 desmonta os mountpoints mais profundos antes.
    while read -r dev mnt; do
        [[ -n "$mnt" && "$mnt" != "[SWAP]" ]] || continue
        umount "$mnt"
        log_info "desmontado $mnt"
    done < <(lsblk -nrpo NAME,MOUNTPOINT "$TARGET_DISK" | sort -rk2)

    # Holders ativos (LVM/LUKS/RAID de uma instalacao anterior, que live ISOs
    # costumam auto-ativar) seguram a tabela ANTIGA no kernel: o BLKRRPART do
    # sgdisk falharia em silencio (exit 0 com warning) e os device nodes
    # antigos continuariam validos com a geometria anterior. Nenhuma guarda de
    # mount/swap pega um PV/container aberto mas nao montado — morre com
    # instrucao em vez de zapar por cima.
    if lsblk -nro TYPE "$TARGET_DISK" | grep -Eq '^(lvm|crypt|raid[0-9]*|dm|mpath)$'; then
        die "particoes de $TARGET_DISK tem holders ativos (LVM/LUKS/RAID — veja 'lsblk $TARGET_DISK') — desative-os antes de reparticionar (vgchange -an / cryptsetup close / mdadm --stop) e re-execute"
    fi

    # Zera a tabela de particoes (GPT + MBR protetivo) e cria o layout novo
    # numa unica chamada: type GUIDs (-t) e PARTLABELs (-c) exatos.
    # ROOT_SIZE vazio => particao 3 ocupa todo o resto do disco ("0").
    local root_end="0"
    [[ -n "$ROOT_SIZE" ]] && root_end="+$(_sgdisk_size "$ROOT_SIZE")"
    sgdisk --zap-all "$TARGET_DISK"
    sgdisk \
        -n "1:0:+$(_sgdisk_size "$EFI_SIZE")"  -t 1:ef00 -c "1:$EFI_PARTLABEL" \
        -n "2:0:+$(_sgdisk_size "$SWAP_SIZE")" -t 2:8200 -c "2:$SWAP_PARTLABEL" \
        -n "3:0:${root_end}"                   -t 3:8300 -c "3:$ROOT_PARTLABEL" \
        "$TARGET_DISK"

    # Forca e VERIFICA a releitura da tabela pelo kernel. O sgdisk retorna
    # exit 0 MESMO quando o BLKRRPART falha ('Warning: The kernel is still
    # using the old partition table'); nesse estado os nodes antigos
    # continuam existindo com os offsets da tabela ANTERIOR e o wait por
    # [[ -b ]] passaria imediatamente — o mkfs escreveria na geometria errada.
    local attempt reread_ok="no"
    for attempt in 1 2 3 4 5; do
        if blockdev --rereadpt "$TARGET_DISK" 2>/dev/null; then
            reread_ok="yes"
            break
        fi
        sleep 1
    done
    if [[ "$reread_ok" == "no" ]] && command -v partprobe > /dev/null 2>&1; then
        partprobe "$TARGET_DISK" 2>/dev/null && reread_ok="yes" || true
    fi
    [[ "$reread_ok" == "yes" ]] \
        || die "o kernel nao releu a tabela de particoes nova de $TARGET_DISK (blockdev --rereadpt/partprobe falharam) — algo ainda segura o disco (veja 'lsblk $TARGET_DISK'); resolva e re-execute"

    # Aguarda o kernel/udev criarem os device nodes das particoes novas e
    # confirma que o KERNEL enxerga o layout novo (lsblk le a visao do kernel;
    # o sgdisk -i do probe le do disco e nao detectaria a dessincronizacao).
    command -v udevadm > /dev/null 2>&1 && udevadm settle || true
    local i labels kernel_sees="no"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -b "$EFI_PART" && -b "$SWAP_PART" && -b "$ROOT_PART" ]]; then
            labels="$(lsblk -nro PARTLABEL "$TARGET_DISK" 2>/dev/null || true)"
            if grep -qx "$EFI_PARTLABEL" <<<"$labels" \
               && grep -qx "$SWAP_PARTLABEL" <<<"$labels" \
               && grep -qx "$ROOT_PARTLABEL" <<<"$labels"; then
                kernel_sees="yes"
                break
            fi
        fi
        sleep 1
    done
    [[ "$kernel_sees" == "yes" ]] \
        || die "o kernel nao enxerga o layout novo de $TARGET_DISK ($EFI_PARTLABEL/$SWAP_PARTLABEL/$ROOT_PARTLABEL ausentes no lsblk apos a releitura) — device nodes stale; nao e seguro formatar"

    # sgdisk --zap-all zera apenas as estruturas GPT/MBR, nao os superblocos:
    # como o layout novo tem os mesmos offsets, o blkid ainda enxergaria as
    # assinaturas vfat/swap/ext4 antigas e os probes de mkfs pulariam a
    # reformatacao. Apaga as assinaturas das 3 particoes recem-criadas — a
    # destruicao ja foi confirmada por confirm_destruction acima.
    wipefs -a "$EFI_PART" "$SWAP_PART" "$ROOT_PART"

    # Sinaliza para as guardas dos 00-mkfs-* (_confirm_reformat): a destruicao
    # foi confirmada e as particoes estao limpas — nao re-perguntar.
    GPT_RECREATED="yes"
}

# ---------------------------------------------------------------------------
# Sub-etapas 00-mkfs-* — Handbook: "Creating file systems"
# ESP em FAT32 (obrigatorio p/ UEFI), swap via mkswap, raiz em $ROOT_FS.
# Probe por blkid -s TYPE; mkfs recusa se a particao estiver montada.
# ---------------------------------------------------------------------------

probe_mkfs_efi() {
    [[ -b "$EFI_PART" ]] || return 1
    [[ "$(_fs_type "$EFI_PART")" == "vfat" ]]
}

do_mkfs_efi() {
    _assert_not_mounted_elsewhere "$EFI_PART"
    _confirm_reformat "$EFI_PART"
    mkfs.vfat -F 32 "$EFI_PART"
}

probe_mkfs_swap() {
    [[ -b "$SWAP_PART" ]] || return 1
    [[ "$(_fs_type "$SWAP_PART")" == "swap" ]]
}

do_mkfs_swap() {
    _assert_not_mounted_elsewhere "$SWAP_PART"
    _confirm_reformat "$SWAP_PART"
    mkswap "$SWAP_PART"
}

probe_mkfs_root() {
    [[ -b "$ROOT_PART" ]] || return 1
    [[ "$(_fs_type "$ROOT_PART")" == "$ROOT_FS" ]]
}

do_mkfs_root() {
    _assert_not_mounted_elsewhere "$ROOT_PART"
    _confirm_reformat "$ROOT_PART"
    # -F/-f: o probe ja disse que o filesystem atual esta errado/ausente e a
    # destruicao foi confirmada no do_gpt desta execucao ou no
    # _confirm_reformat acima; sem o force o mkfs pararia num prompt
    # interativo ao ver assinatura antiga.
    case "$ROOT_FS" in
        ext4) mkfs.ext4 -F "$ROOT_PART" ;;
        xfs)  mkfs.xfs  -f "$ROOT_PART" ;;
        *)    die "ROOT_FS='$ROOT_FS' inesperado (validate_vars deveria ter barrado)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Sub-etapa 00-mount — Handbook: "Mounting the root partition"
# Root em $TARGET_ROOT, ESP em $TARGET_ROOT/efi (layout atual do Handbook:
# ESP em /efi, kernels continuam em /boot), swapon ("Activating the swap
# partition"). Probe funcional pelos mounts reais — e esta sub-etapa que
# restaura a visibilidade do state dir apos um reboot do live ISO, por isso
# ela nunca depende de marker e re-executa sempre que os mounts cairem.
# ---------------------------------------------------------------------------

probe_mount() {
    # root montada em $TARGET_ROOT e vinda da particao certa?
    mountpoint -q "$TARGET_ROOT" || return 1
    [[ "$(findmnt -rno SOURCE "$TARGET_ROOT" 2>/dev/null)" == "$(realpath "$ROOT_PART")" ]] || return 1
    # ESP montada em $TARGET_ROOT/efi e vinda da particao certa?
    mountpoint -q "$TARGET_ROOT/efi" || return 1
    [[ "$(findmnt -rno SOURCE "$TARGET_ROOT/efi" 2>/dev/null)" == "$(realpath "$EFI_PART")" ]] || return 1
    # swap ativo?
    grep -q "^$(realpath "$SWAP_PART") " /proc/swaps
}

do_mount() {
    # ensure_target_mounts (lib.sh) e idempotente: monta so o que falta.
    ensure_target_mounts
}

# ---------------------------------------------------------------------------
# Execucao
# ---------------------------------------------------------------------------

run_step "00-gpt"       probe_gpt       do_gpt
run_step "00-mkfs-efi"  probe_mkfs_efi  do_mkfs_efi
run_step "00-mkfs-swap" probe_mkfs_swap do_mkfs_swap
run_step "00-mkfs-root" probe_mkfs_root do_mkfs_root

# Na primeira passada as sub-etapas acima rodam com $TARGET_ROOT ainda
# desmontado: state_dir aponta para dentro do alvo, entao os markers cairam no
# tmpfs do live ISO, embaixo do mountpoint — sombreados assim que o 00-mount
# montar a raiz real por cima (e enganosos se o alvo for desmontado depois).
# Descarta a arvore fantasma; os markers sao regravados apos o mount, ja no
# filesystem alvo. Perder marker aqui nunca re-executa nada destrutivo: os
# probes funcionais sao a autoridade.
if ! mountpoint -q "$TARGET_ROOT"; then
    rm -rf "$(state_dir)"
fi

run_step "00-mount"     probe_mount     do_mount

# Regrava no filesystem alvo (agora montado) os markers das sub-etapas que
# rodaram antes do mount, honrando o contrato do state_dir de lib.sh (o state
# vive NO ALVO e sobrevive as duas fases e a reboot do live ISO).
for _step in 00-gpt 00-mkfs-efi 00-mkfs-swap 00-mkfs-root; do
    step_done "$_step" || mark_done "$_step"
done
unset _step

# O log deste script comecou em /tmp (alvo ainda nao montado); agora que a
# raiz esta em $TARGET_ROOT, anexa a copia integral ao filesystem alvo.
attach_log_to_target

log_info "00-partition concluido: $TARGET_DISK particionado, formatado e montado em $TARGET_ROOT"

# Copia final do log ja com as ultimas linhas (idempotente — sobrescreve).
attach_log_to_target
