#!/usr/bin/env bash
# 06-users-services.sh — hostname, keymap, senhas, usuario e servicos.
#
# Fase: chroot (rodado dentro do sistema alvo, via install.sh ou standalone).
# Implementa as secoes do Handbook AMD64:
#   - "Configuring the system" -> System information (hostname)
#   - "Configuring the system" -> Networking -> The hosts file (/etc/hosts)
#   - "Configuring the system" -> keymaps do console (OpenRC) / vconsole (systemd)
#   - "Finalizing" -> Set the root password / Adding a user for daily use
#   - "Configuring the network" -> DHCP (dhcpcd)
#   - "Installing system tools" -> Filesystem tools (dosfstools; xfsprogs
#     quando ROOT_FS=xfs) — nos dois inits
#   - "Installing system tools" -> System logger + Cron daemon (so OpenRC;
#     systemd ja traz journald e timers)
#   - "Installing system tools" -> Remote access (sshd)
#   - (systemd) machine-id + systemd-firstboot + preset-all (enable-only)
#
# Cada sub-etapa passa por run_step com probe FUNCIONAL (o marker e so cache).
# Unica excecao: o preset-all (enable-only) roda SEMPRE, fora de run_step —
# nao ha probe funcional barato para ele e a acao nunca desabilita nada (a
# justificativa completa esta no comentario da propria funcao).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/vars.sh"   # SEMPRE vars.sh ANTES de lib.sh
source "$SCRIPT_DIR/lib.sh"
init_logging 06-users-services
require_phase chroot
validate_vars

# ---------------------------------------------------------------------------
# Helpers locais (sem efeito colateral — usados pelos probes)
# ---------------------------------------------------------------------------

# pkg_installed <categoria/nome>: testa no VDB do Portage se o pacote esta
# instalado (autoridade real; nao depende de qlist/portage-utils).
pkg_installed() {
    compgen -G "/var/db/pkg/${1}-[0-9]*" > /dev/null
}

# svc_in_runlevel <servico> <runlevel>: (OpenRC) testa se o servico ja esta
# no runlevel dado. Mesma logica de leitura usada por svc_enable em lib.sh.
svc_in_runlevel() {
    rc-update show "$2" 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

# svc_is_enabled <servico> [runlevel]: teste unificado OpenRC/systemd,
# somente leitura (para probes).
svc_is_enabled() {
    local svc="$1" runlevel="${2:-default}"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        svc_in_runlevel "$svc" "$runlevel"
    else
        systemctl is-enabled "$svc" &>/dev/null
    fi
}

# shadow_hash <usuario>: imprime o campo de senha do /etc/shadow (vazio se o
# usuario nao existe). Senha definida = campo comecando com '$'.
shadow_hash() {
    getent shadow "$1" 2>/dev/null | cut -d: -f2
}

# interactive_passwd <usuario> <nome-da-var-de-hash>: roda `passwd` lendo e
# escrevendo direto no /dev/tty (o stdout/stderr do script passam pelo tee do
# logging; o prompt precisa do terminal real do console live, que funciona
# atraves do chroot).
interactive_passwd() {
    local user="$1" hash_var="$2"
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        die "sem terminal para 'passwd $user' interativo — defina $hash_var em vars.sh (ex.: openssl passwd -6) para modo nao-interativo"
    fi
    log_info "defina agora a senha de '$user' (prompt no console):"
    passwd "$user" < /dev/tty > /dev/tty 2>&1
}

# ---------------------------------------------------------------------------
# 06-hostname — Handbook: Configuring the system -> Set the hostname
# Handbook atual: `echo tux > /etc/hostname` para os DOIS inits (o init
# script hostname do OpenRC >=0.44 le /etc/hostname, com PRECEDENCIA sobre
# /etc/conf.d/hostname). No OpenRC gravamos TAMBEM /etc/conf.d/hostname com
# o mesmo valor: cinto e suspensorio — cobre OpenRC antigo que so le conf.d
# e evita que um /etc/hostname criado por fora divirja silenciosamente.
# ---------------------------------------------------------------------------

probe_hostname() {
    [[ "$(cat /etc/hostname 2>/dev/null)" == "$TARGET_HOSTNAME" ]] || return 1
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        grep -qx "hostname=\"$TARGET_HOSTNAME\"" /etc/conf.d/hostname 2>/dev/null
    fi
}

do_hostname() {
    printf '%s\n' "$TARGET_HOSTNAME" > /etc/hostname
    log_info "hostname '$TARGET_HOSTNAME' gravado em /etc/hostname"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        cat > /etc/conf.d/hostname <<EOF
# Gerado por 06-users-services.sh (instalacao automatizada do Gentoo).
# NOTA: /etc/hostname (metodo do Handbook atual) tem precedencia no
# OpenRC >=0.44; este arquivo fica como fallback com o MESMO valor.
hostname="$TARGET_HOSTNAME"
EOF
        log_info "hostname '$TARGET_HOSTNAME' tambem gravado em /etc/conf.d/hostname (fallback OpenRC)"
    fi
}

run_step 06-hostname probe_hostname do_hostname

# ---------------------------------------------------------------------------
# 06-hosts — Handbook: Configuring the system -> Networking -> The hosts file
# "On OpenRC systems, the hostname chosen above MUST be configured in
# /etc/hosts" (sem ele, o proprio nome nao resolve via nsswitch 'files':
# hostname -f falha, sudo reclama, sshd/MTAs sofrem timeouts de lookup).
# No systemd o Handbook nao exige, mas e inofensivo — roda nos dois inits.
# Idempotente: reescreve as linhas de loopback existentes ou faz append.
# ---------------------------------------------------------------------------

# Probe ancorado nas DUAS linhas de loopback que do_hosts escreve (no espirito
# do probe_fstab do 03): o hostname precisa aparecer como campo proprio depois
# do endereco. Um "$TARGET_HOSTNAME" solto num comentario ou numa linha de rede
# qualquer NAO conta como feito.
probe_hosts() {
    local host_re
    # o hostname vira parte de uma ERE: escapa os metacaracteres (o '.' de um
    # FQDN e o mais provavel) para nao casar por acidente.
    host_re="$(sed 's/[][^$.*\\+?(){}|/]/\\&/g' <<< "$TARGET_HOSTNAME")"
    grep -Eq "^127\.0\.0\.1[[:blank:]]+([^[:blank:]#]+[[:blank:]]+)*${host_re}([[:blank:]]|$)" /etc/hosts 2>/dev/null || return 1
    grep -Eq "^::1[[:blank:]]+([^[:blank:]#]+[[:blank:]]+)*${host_re}([[:blank:]]|$)" /etc/hosts 2>/dev/null
}

do_hosts() {
    touch /etc/hosts
    if grep -q '^127\.0\.0\.1[[:space:]]' /etc/hosts; then
        sed -i "s|^127\.0\.0\.1[[:space:]].*|127.0.0.1\t$TARGET_HOSTNAME localhost|" /etc/hosts
    else
        printf '127.0.0.1\t%s localhost\n' "$TARGET_HOSTNAME" >> /etc/hosts
    fi
    if grep -q '^::1[[:space:]]' /etc/hosts; then
        sed -i "s|^::1[[:space:]].*|::1\t\t$TARGET_HOSTNAME localhost|" /etc/hosts
    else
        printf '::1\t\t%s localhost\n' "$TARGET_HOSTNAME" >> /etc/hosts
    fi
    log_info "hostname '$TARGET_HOSTNAME' registrado nas linhas de loopback de /etc/hosts"
}

run_step 06-hosts probe_hosts do_hosts

# ---------------------------------------------------------------------------
# 06-keymap — Handbook: Configuring the system -> keymaps / vconsole
# OpenRC: /etc/conf.d/keymaps (edicao pontual, preserva o resto do arquivo
# stock) + servico keymaps no runlevel "boot".
# systemd: KEYMAP= em /etc/vconsole.conf.
# ---------------------------------------------------------------------------

probe_keymap() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        grep -qx "keymap=\"$KEYMAP\"" /etc/conf.d/keymaps 2>/dev/null \
            && svc_in_runlevel keymaps boot
    else
        grep -qx "KEYMAP=$KEYMAP" /etc/vconsole.conf 2>/dev/null
    fi
}

do_keymap() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        # troca so a linha keymap= do arquivo stock (mantem windowkeys etc.)
        if grep -q '^keymap=' /etc/conf.d/keymaps 2>/dev/null; then
            sed -i "s|^keymap=.*|keymap=\"$KEYMAP\"|" /etc/conf.d/keymaps
        else
            printf 'keymap="%s"\n' "$KEYMAP" >> /etc/conf.d/keymaps
        fi
        log_info "keymap '$KEYMAP' gravado em /etc/conf.d/keymaps"
        # keymaps roda no runlevel boot (ja e default no stage3; idempotente)
        svc_enable keymaps boot
    else
        touch /etc/vconsole.conf
        if grep -q '^KEYMAP=' /etc/vconsole.conf; then
            sed -i "s|^KEYMAP=.*|KEYMAP=$KEYMAP|" /etc/vconsole.conf
        else
            printf 'KEYMAP=%s\n' "$KEYMAP" >> /etc/vconsole.conf
        fi
        log_info "keymap '$KEYMAP' gravado em /etc/vconsole.conf"
    fi
}

run_step 06-keymap probe_keymap do_keymap

# ---------------------------------------------------------------------------
# 06-machine-id + 06-firstboot + presets — Handbook (systemd): Init and
# boot configuration -> systemd. Exclusivos do systemd; no OpenRC nao
# existem e sao pulados por completo.
# ---------------------------------------------------------------------------

probe_machine_id() {
    # machine-id valido = 32 hex minusculos ("uninitialized" ou vazio = nao feito)
    grep -qxE '[0-9a-f]{32}' /etc/machine-id 2>/dev/null
}

do_machine_id() {
    systemd-machine-id-setup
    log_info "machine-id gerado: $(cat /etc/machine-id)"
}

# systemd-firstboot preenche APENAS o que estiver faltando (nao sobrescreve o
# que 03/06 ja configuraram); o probe checa a existencia de cada artefato.
probe_firstboot() {
    grep -q '^LANG=' /etc/locale.conf 2>/dev/null \
        && [[ -e /etc/localtime ]] \
        && [[ -s /etc/hostname ]] \
        && grep -q '^KEYMAP=' /etc/vconsole.conf 2>/dev/null
}

do_firstboot() {
    systemd-firstboot \
        --locale="$LOCALE" \
        --keymap="$KEYMAP" \
        --timezone="$TIMEZONE" \
        --hostname="$TARGET_HOSTNAME"
}

# Handbook (systemd): `systemctl preset-all --preset-mode=enable-only` apos
# machine-id/firstboot — habilita as unidades que o preset da distro liga por
# padrao (systemd-timesyncd etc.) "to ensure a smooth transition from the
# live environment to the installation's first boot".
# EXATAMENTE enable-only: o preset-all completo poderia DESABILITAR os
# `systemctl enable` de sshd/dhcpcd feitos em 06-services; enable-only nunca
# desliga nada, entao a ordem relativa a 06-services e indiferente.
# SEM run_step, de proposito: roda SEMPRE, como report_news_items (03:148) e
# refresh_environment (03:240). Nao existe probe funcional barato e estavel
# aqui — o conjunto de unidades presetadas depende dos arquivos *-preset da
# versao instalada —, e um probe por marker seria pior que nada: um marker
# gravado sem o preset ter surtido efeito (state restaurado, execucao parcial,
# preset-all que falhou no meio) deixaria unidades como systemd-timesyncd
# desabilitadas para sempre, sem nada detectar. Como a acao e barata,
# naturalmente idempotente e enable-only NUNCA desabilita nada, executar
# incondicionalmente e estritamente mais seguro do que confiar num cache.
apply_distro_presets() {
    systemctl preset-all --preset-mode=enable-only
    log_info "presets da distro aplicados (systemctl preset-all --preset-mode=enable-only)"
}

if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    run_step 06-machine-id probe_machine_id do_machine_id
    run_step 06-firstboot probe_firstboot do_firstboot
    apply_distro_presets
    # marker legado de quando o preset passava por run_step: se ficou de uma
    # instalacao anterior, some agora — nao ha mais nada que o consulte.
    clear_marker 06-preset
else
    log_info "INIT_SYSTEM=openrc — pulando machine-id/firstboot/preset (exclusivos do systemd)"
fi

# ---------------------------------------------------------------------------
# 06-root-password — Handbook: Finalizing -> Set the root password
# Hash em vars.sh -> chpasswd -e (nao-interativo); vazio -> passwd via tty.
# ---------------------------------------------------------------------------

probe_root_password() {
    local cur
    cur="$(shadow_hash root)"
    if [[ -n "$ROOT_PASSWORD_HASH" ]]; then
        # com hash declarado, a autoridade e o proprio /etc/shadow bater com ele
        [[ "$cur" == "$ROOT_PASSWORD_HASH" ]]
    else
        # sem hash: basta existir senha definida (campo crypt comeca com '$')
        [[ "$cur" == \$* ]]
    fi
}

do_root_password() {
    if [[ -n "$ROOT_PASSWORD_HASH" ]]; then
        printf '%s:%s\n' root "$ROOT_PASSWORD_HASH" | chpasswd -e
        log_info "senha de root aplicada via chpasswd -e (hash de vars.sh)"
    else
        interactive_passwd root ROOT_PASSWORD_HASH
    fi
}

run_step 06-root-password probe_root_password do_root_password

# ---------------------------------------------------------------------------
# 06-users — Handbook: Finalizing -> Adding a user for daily use
# useradd -m -G $USER_GROUPS; re-execucao repara grupos faltantes via usermod.
# ---------------------------------------------------------------------------

probe_users() {
    id -u "$USERNAME" &>/dev/null || return 1
    # todos os grupos suplementares pedidos precisam estar presentes
    local current_groups grp
    current_groups="$(id -nG "$USERNAME")"
    for grp in ${USER_GROUPS//,/ }; do
        grep -qwx "$grp" <<< "${current_groups// /$'\n'}" || return 1
    done
    return 0
}

do_users() {
    if id -u "$USERNAME" &>/dev/null; then
        # usuario ja existe (execucao parcial anterior): so completa os grupos
        usermod -aG "$USER_GROUPS" "$USERNAME"
        log_info "usuario '$USERNAME' ja existia — grupos ajustados ($USER_GROUPS)"
    else
        useradd -m -G "$USER_GROUPS" -s /bin/bash "$USERNAME"
        log_info "usuario '$USERNAME' criado (grupos: $USER_GROUPS)"
    fi
}

run_step 06-users probe_users do_users

# ---------------------------------------------------------------------------
# 06-user-password — Handbook: Finalizing -> Adding a user (senha)
# Mesma logica da senha de root; roda DEPOIS de 06-users (usuario existe).
# ---------------------------------------------------------------------------

probe_user_password() {
    local cur
    cur="$(shadow_hash "$USERNAME")"
    if [[ -n "$USER_PASSWORD_HASH" ]]; then
        [[ "$cur" == "$USER_PASSWORD_HASH" ]]
    else
        [[ "$cur" == \$* ]]
    fi
}

do_user_password() {
    if [[ -n "$USER_PASSWORD_HASH" ]]; then
        printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD_HASH" | chpasswd -e
        log_info "senha de '$USERNAME' aplicada via chpasswd -e (hash de vars.sh)"
    else
        interactive_passwd "$USERNAME" USER_PASSWORD_HASH
    fi
}

run_step 06-user-password probe_user_password do_user_password

# ---------------------------------------------------------------------------
# 06-dhcpcd — Handbook: Configuring the network -> Automatic (DHCP)
# Instala net-misc/dhcpcd somente quando ENABLE_DHCP=yes (o enable no boot
# acontece em 06-services).
# ---------------------------------------------------------------------------

probe_dhcpcd() {
    pkg_installed net-misc/dhcpcd
}

do_dhcpcd() {
    emerge --quiet net-misc/dhcpcd
}

if [[ "$ENABLE_DHCP" == "yes" ]]; then
    run_step 06-dhcpcd probe_dhcpcd do_dhcpcd
else
    log_info "ENABLE_DHCP=no — pulando instalacao do dhcpcd"
fi

# ---------------------------------------------------------------------------
# 06-fs-tools — Handbook: Installing system tools -> Filesystem tools
# Ferramentas de userspace dos filesystems usados: sys-fs/dosfstools SEMPRE
# (a ESP e vfat e o fstab do 03 lhe da passno 2 — sem fsck.vfat o fsck do
# primeiro boot falha e /efi nao monta) e sys-fs/xfsprogs quando ROOT_FS=xfs
# (fsck.xfs/xfs_repair para a raiz, passno 1). O e2fsprogs (ext4) ja vem no
# @system do stage3. Vale para os DOIS inits — roda fora do bloco OpenRC.
# ---------------------------------------------------------------------------

probe_fs_tools() {
    pkg_installed sys-fs/dosfstools || return 1
    if [[ "$ROOT_FS" == "xfs" ]]; then
        pkg_installed sys-fs/xfsprogs || return 1
    fi
    return 0
}

do_fs_tools() {
    local pkgs=(sys-fs/dosfstools)
    if [[ "$ROOT_FS" == "xfs" ]]; then
        pkgs+=(sys-fs/xfsprogs)
    fi
    emerge --quiet "${pkgs[@]}"
}

run_step 06-fs-tools probe_fs_tools do_fs_tools

# ---------------------------------------------------------------------------
# 06-syslog-cron — Handbook: Installing system tools -> System logger + Cron
# SOMENTE no OpenRC: o systemd ja traz journald (log) e timers (cron).
# ---------------------------------------------------------------------------

probe_syslog_cron() {
    pkg_installed app-admin/sysklogd && pkg_installed sys-process/cronie
}

do_syslog_cron() {
    emerge --quiet app-admin/sysklogd sys-process/cronie
}

if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    run_step 06-syslog-cron probe_syslog_cron do_syslog_cron
else
    log_info "INIT_SYSTEM=systemd — pulando sysklogd/cronie (journald e timers ja cobrem)"
fi

# ---------------------------------------------------------------------------
# 06-services — Handbook: Installing system tools / Remote access
# Habilita no boot: sysklogd+cronie (so OpenRC), sshd (ENABLE_SSHD=yes) e
# dhcpcd (ENABLE_DHCP=yes). svc_enable e chroot-safe nos dois inits.
# ---------------------------------------------------------------------------

probe_services() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        svc_is_enabled sysklogd || return 1
        svc_is_enabled cronie   || return 1
    fi
    if [[ "$ENABLE_SSHD" == "yes" ]]; then
        svc_is_enabled sshd || return 1
    fi
    if [[ "$ENABLE_DHCP" == "yes" ]]; then
        svc_is_enabled dhcpcd || return 1
    fi
    return 0
}

do_services() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        svc_enable sysklogd
        svc_enable cronie
    fi
    if [[ "$ENABLE_SSHD" == "yes" ]]; then
        svc_enable sshd
    else
        log_info "ENABLE_SSHD=no — sshd nao sera habilitado no boot"
    fi
    if [[ "$ENABLE_DHCP" == "yes" ]]; then
        svc_enable dhcpcd
    else
        log_info "ENABLE_DHCP=no — dhcpcd nao sera habilitado no boot"
    fi
}

run_step 06-services probe_services do_services

log_info "==== 06-users-services concluido com sucesso ===="
