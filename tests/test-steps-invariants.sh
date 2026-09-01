#!/usr/bin/env bash
#
# test-steps-invariants.sh — invariantes das etapas que a auditoria pediu para
# conferir sem reescrever: flags de resume, sentinela do sync, semantica de
# NVIDIA_MODE=skip e o branch systemd (nunca executado de verdade).
#
# Tudo estatico ou via funcoes puras. Nada aqui instala, monta ou emerge.

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

printf '\n== test-steps-invariants ==\n'

INSTALL_SH="$REPO_DIR/install.sh"
CHROOT_SH="$REPO_DIR/03-chroot-setup.sh"
KERNEL_SH="$REPO_DIR/04-kernel.sh"
USERS_SH="$REPO_DIR/06-users-services.sh"

# ==========================================================================
# 1. --only / --from / resume
# ==========================================================================
# Rodamos o install.sh de verdade, mas SO em caminhos que terminam antes de
# qualquer acao: --help, e combinacoes invalidas. TARGET_DISK aponta para um
# device inexistente como cinto-e-suspensorio: se algum caminho escapar para
# validate_vars, ele morre ali em vez de tocar em disco.
run_install() {
    ( cd "$REPO_DIR" && TARGET_DISK=/dev/nao-existe-para-teste timeout 20 \
        ./install.sh "$@" < /dev/null 2>&1 )
    printf 'EXIT=%s\n' "$?"
}
exit_of() { sed -n 's/^EXIT=//p' <<< "$1" | tail -n1; }

out="$(run_install --help)"
assert_eq "0" "$(exit_of "$out")" "--help sai com 0"
assert_contains "$out" "--from" "--help documenta --from"
assert_contains "$out" "--only" "--help documenta --only"
assert_contains "$out" "--reset" "--help documenta --reset"

for bad in "--only 9" "--only abc" "--from 9" "--from abc" "--only 3 --from 4" "--flag-que-nao-existe"; do
    # shellcheck disable=SC2086  # split proposital: sao varios argumentos
    out="$(run_install $bad)"
    if [[ "$(exit_of "$out")" == "0" ]]; then
        no "'$bad' deveria ser recusado" "$out"
    else
        ok "'$bad' e recusado"
    fi
done

# --repartition sem --reset nao pode reparticionar sozinho.
out="$(run_install --repartition)"
if [[ "$(exit_of "$out")" == "0" ]]; then
    no "--repartition sozinho deveria ser recusado ou exigir --reset" "$out"
else
    ok "--repartition sozinho nao prossegue"
fi

# A sentinela de fase so pode ser removida quando a invocacao cobre 03-06.
ec="$(extract_fn "$INSTALL_SH" enter_chroot)"
if grep -q 'covers_full_phase' <<< "$ec"; then
    ok "enter_chroot distingue invocacao parcial de fase completa"
else
    no "enter_chroot nao tem a nocao de fase completa (sentinela sairia cedo demais)"
fi

# ==========================================================================
# 2. Sync: sentinela e completude da arvore
# ==========================================================================
probe_sync="$(extract_fn "$CHROOT_SH" probe_sync)"
do_sync="$(extract_fn "$CHROOT_SH" do_sync)"

if grep -q 'SYNC_STARTED' <<< "$probe_sync"; then
    ok "probe_sync considera a sentinela de sync interrompido"
else
    no "probe_sync ignora sync interrompido"
fi
# A sentinela tem de ser criada ANTES do webrsync e removida so DEPOIS do sync.
started_line="$(grep -n 'SYNC_STARTED' <<< "$do_sync" | head -n1 | cut -d: -f1)"
webrsync_line="$(grep -n 'emerge-webrsync' <<< "$do_sync" | head -n1 | cut -d: -f1)"
rm_line="$(grep -n 'rm -f "\$SYNC_STARTED"' <<< "$do_sync" | head -n1 | cut -d: -f1)"
sync_line="$(grep -n 'emerge --sync' <<< "$do_sync" | head -n1 | cut -d: -f1)"
if [[ -n "$started_line" && -n "$webrsync_line" ]] && (( started_line < webrsync_line )); then
    ok "do_sync cria a sentinela ANTES do emerge-webrsync"
else
    no "sentinela de sync criada tarde demais (interrupcao pareceria sucesso)"
fi
if [[ -n "$rm_line" && -n "$sync_line" ]] && (( rm_line > sync_line )); then
    ok "do_sync remove a sentinela so DEPOIS do emerge --sync"
else
    no "sentinela de sync removida cedo demais"
fi
# Arvore truncada nao pode passar: exige ebuild real nas categorias usadas.
if grep -q 'SYNC_REQUIRED_PKGS' <<< "$probe_sync"; then
    ok "probe_sync exige categorias reais (arvore truncada nao passa)"
else
    no "probe_sync aceita arvore so com timestamp.chk"
fi
if grep -q 'x11-drivers/nvidia-drivers' "$CHROOT_SH"; then
    ok "a verificacao de completude da arvore inclui nvidia-drivers"
else
    no "nvidia-drivers saiu da verificacao de completude da arvore"
fi

# ==========================================================================
# 3. NVIDIA_MODE=skip e OMISSAO, nunca remocao
# ==========================================================================
# skip nao pode desinstalar, desmascarar nem apagar configuracao existente.
skip_block="$(grep -n 'NVIDIA_MODE" == "skip"' -A6 "$KERNEL_SH")"
if grep -qE 'emerge.*(-C|--unmerge|--depclean)|qmerge -U' <<< "$skip_block"; then
    no "o caminho de NVIDIA_MODE=skip contem remocao de pacote" "$skip_block"
else
    ok "NVIDIA_MODE=skip nao remove pacote nenhum"
fi
if grep -qE 'emerge .*(-C|--unmerge|--depclean)' "$REPO_DIR"/*.sh; then
    no "algum script desinstala pacotes" "$(grep -nE 'emerge .*(-C|--unmerge|--depclean)' "$REPO_DIR"/*.sh)"
else
    ok "nenhum script do projeto desinstala pacotes (skip nao vira uninstall)"
fi
pn="$(extract_fn "$KERNEL_SH" probe_nvidia)"
if grep -q 'skip' <<< "$pn"; then
    ok "probe_nvidia trata skip como 'nada a fazer'"
else
    no "probe_nvidia nao trata NVIDIA_MODE=skip"
fi
if grep -qi 'skip' "$REPO_DIR/vars.sh" && grep -qiE 'nao (instala|desinstala)|OMISSAO' "$REPO_DIR/vars.sh"; then
    ok "vars.sh documenta a semantica de skip explicitamente"
else
    no "vars.sh nao documenta que skip nao remove nada"
fi

# ==========================================================================
# 4. Branch systemd (NUNCA executado — asercoes estaticas)
# ==========================================================================
# Cada item que o systemd exige tem de existir e estar guardado por INIT_SYSTEM.
for item in 'machine-id' 'firstboot' 'preset' 'vconsole'; do
    if grep -qi -- "$item" "$USERS_SH"; then
        ok "06 trata '$item' (branch systemd)"
    else
        no "06 nao trata '$item' no branch systemd"
    fi
done
# Os pacotes so-OpenRC nao podem ser instalados no systemd.
sc="$(extract_fn "$USERS_SH" do_syslog_cron)"
if grep -qE 'sysklogd|cronie' <<< "$sc"; then
    guard="$(grep -B8 'do_syslog_cron\|06-syslog-cron' "$USERS_SH" | grep -c 'openrc' || true)"
    if (( guard > 0 )); then
        ok "sysklogd/cronie ficam restritos ao OpenRC"
    else
        no "sysklogd/cronie nao parecem guardados por INIT_SYSTEM=openrc"
    fi
fi
# svc_enable precisa cobrir os dois inits.
se="$(extract_fn "$REPO_DIR/lib.sh" svc_enable)"
if grep -q 'rc-update' <<< "$se" && grep -q 'systemctl' <<< "$se"; then
    ok "svc_enable cobre rc-update (OpenRC) e systemctl (systemd)"
else
    no "svc_enable nao cobre os dois inits"
fi
# O perfil systemd tem de ser derivado de INIT_SYSTEM, nao fixo.
if grep -qE 'TARGET_PROFILE=.*systemd' "$CHROOT_SH"; then
    ok "TARGET_PROFILE deriva de INIT_SYSTEM (sub-perfil systemd)"
else
    no "TARGET_PROFILE nao contempla o sub-perfil systemd"
fi
# E o stage3 do flavor certo.
if grep -qE 'INIT_SYSTEM' "$REPO_DIR/01-stage3.sh"; then
    ok "01-stage3 escolhe o tarball pelo INIT_SYSTEM"
else
    no "01-stage3 nao deriva o flavor do stage3 de INIT_SYSTEM"
fi

finish
