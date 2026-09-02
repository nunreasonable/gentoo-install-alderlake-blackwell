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

# --- USE do nvidia-drivers: -tools em TODOS os ramos ---------------------
# 'tools' vem ligado por default e instala o nvidia-settings, que puxa
# gtk+ -> librsvg -> adwaita -> cairo[X] / freetype[harfbuzz]. Num sistema base
# esses USE nao estao ligados e o emerge PARA pedindo --autounmask-write.
dn="$(extract_fn "$KERNEL_SH" do_nvidia)"
heredocs="$(grep -c 'x11-drivers/nvidia-drivers -tools' <<< "$dn" || true)"
if (( heredocs >= 2 )); then
    ok "package.use/nvidia-drivers fixa -tools nos dois ramos (580.x e >=595)"
else
    no "-tools nao esta fixado em todos os ramos do do_nvidia" \
       "encontrei $heredocs ocorrencia(s); ramo sem -tools trava o emerge no autounmask"
fi
# libglvnd[X] acompanha nvidia-drivers[X] nos dois ramos: sem isso o emerge
# para pedindo --autounmask-write so por causa dessa dependencia.
glv="$(grep -c '^media-libs/libglvnd X' <<< "$dn" || true)"
if (( glv >= 2 )); then
    ok "package.use declara libglvnd X nos dois ramos (dependencia de nvidia-drivers[X])"
else
    no "libglvnd X ausente em algum ramo" \
       "encontrei $glv; com X ligado no driver, o emerge trava no autounmask"
fi
# Coerencia: se o driver mantem X, libglvnd precisa de X. Se alguem desligar X
# no driver, a linha do libglvnd vira supérflua — mas nunca o contrario.
if grep -qE '^x11-drivers/nvidia-drivers .*-X( |$)' <<< "$dn" && (( glv > 0 )); then
    no "driver com -X mas libglvnd X ainda declarado (incoerente)"
else
    ok "coerencia entre X do driver e X do libglvnd"
fi

# kernel-open so pode aparecer como flag ATIVO no ramo 580.x.
if grep -qE '^x11-drivers/nvidia-drivers .*[^-]kernel-open' <<< "$dn"; then
    ok "kernel-open aparece como flag ativo (ramo 580.x)"
else
    no "kernel-open sumiu do ramo 580.x (obrigatorio para Blackwell no 580)"
fi
# O instalador nao pode reescrever config do portage sozinho.
# Ignora comentarios: a documentacao do proprio codigo explica por que NAO usa
# a flag, e citaria a si mesma.
au="$(grep -rnE '^[^#]*--autounmask-write' "$REPO_DIR"/*.sh || true)"
if [[ -n "$au" ]]; then
    no "algum script usa --autounmask-write (reescreve config do portage sem o operador)" "$au"
else
    ok "nenhum script usa --autounmask-write (so mencionado em comentario)"
fi

# --- a varredura de kernel-open nao pode acusar o proprio arquivo --------
# Regressao do tipo "probe reprova o que o do_fn acabou de escrever": o arquivo
# gerado MENCIONA kernel-open num comentario ao explicar por que nao o usa.
scan_tmp="$(mktemp -d)"
mkdir -p "$scan_tmp/package.use"
# Extrai os corpos dos heredocs de package.use gerados pelo do_nvidia — o
# conteudo REAL que vai para o disco, nao uma imitacao.
awk '/<<.EOF.$/ { inhd=1; next } inhd && /^EOF$/ { inhd=0; print "---FIM---"; next } inhd { print }' \
    <<< "$dn" > "$scan_tmp/heredocs.txt"
n=0
while IFS= read -r line; do
    if [[ "$line" == "---FIM---" ]]; then n=$((n+1)); continue; fi
    printf '%s\n' "$line" >> "$scan_tmp/package.use/gerado-$n"
done < "$scan_tmp/heredocs.txt"
printf '# comentario do usuario mencionando kernel-open\nx11-drivers/nvidia-drivers kernel-open\n' \
    > "$scan_tmp/package.use/do-usuario"

found=()
# Captura os hits em vez de usar 'grep -q' no fim do pipe (mesmo padrao do
# test-desktop.sh). Com 'grep -q' o consumidor sai no primeiro casamento e mata
# o 'grep -v' a montante com SIGPIPE (141); sob 'pipefail' o status do pipeline
# inteiro vira 141 mesmo tendo casado, e o 'if' cairia no ramo falso — um falso
# negativo silencioso que depende so de quanto coube no buffer do pipe.
while IFS= read -r f; do
    hits="$(grep -vE '^[[:space:]]*#' "$f" 2>/dev/null \
        | grep -E '(^|[[:space:]])-?kernel-open([[:space:]]|$)' || true)"
    if [[ -n "$hits" ]]; then
        found+=("$(basename "$f")")
    fi
done < <(find "$scan_tmp/package.use" -type f | sort)
ngen="$(find "$scan_tmp/package.use" -name 'gerado-*' | wc -l)"
rm -rf "$scan_tmp"

if (( ngen < 2 )); then
    no "nao consegui extrair os dois heredocs de package.use do do_nvidia" "extrai $ngen"
elif [[ "${found[*]}" == "do-usuario" ]]; then
    ok "varredura de kernel-open: acusa o arquivo do usuario, ignora os $ngen gerados"
elif [[ "${found[*]}" == *"gerado-0"* ]]; then
    ok "ramo 580.x declara kernel-open de verdade (esperado); usuario tambem acusado"
else
    no "varredura de kernel-open com resultado errado" "acusou: ${found[*]:-nada}"
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

# --- a sentinela de resume nao pode virar entrada de boot -------------------
# Regressao de 2026-09-02 (Ciclo 3): o grub-mkconfig imprimiu
#   Found linux image: /boot/kernel-fragment.sha256-6.18.48-gentoo
# e criou um menuentry tentando bootar um arquivo de texto de ~130 bytes. O
# /etc/grub.d/10_linux itera sobre estes globs e gera uma entrada por match.
printf '\n  -- sentinela do kernel vs globs do grub.d/10_linux --\n'

sent_fn="$(extract_fn "$KERNEL_SH" kernel_sentinel)"
if [[ -z "$sent_fn" ]]; then
    no "04-kernel nao define kernel_sentinel"
else
    sent_path="$(bash -c 'eval "$1"; kernel_sentinel 6.18.48-gentoo' _ "$sent_fn")"
    ok "kernel_sentinel resolve para $sent_path"
    for g in '/boot/vmlinuz-*' '/boot/vmlinux-*' '/vmlinuz-*' '/vmlinux-*' '/boot/kernel-*'; do
        # shellcheck disable=SC2053  # comparar COM glob e exatamente o ponto aqui
        if [[ "$sent_path" == $g ]]; then
            no "a sentinela casa com o glob $g do 10_linux" \
               "o grub-mkconfig geraria um menuentry falso apontando para ela"
        else
            ok "sentinela nao casa com o glob $g"
        fi
    done
fi

# O nome antigo so pode sobreviver na migracao e na invalidacao, nunca na
# gravacao. extract_fn (nao grep no arquivo) para nao casar com os comentarios
# que explicam a regressao.
build_fn="$(extract_fn "$KERNEL_SH" do_kernel_build)"
if grep -qE '>[[:space:]]*"?/boot/kernel-fragment' <<< "$build_fn"; then
    no "do_kernel_build ainda grava a sentinela com o nome antigo"
else
    ok "do_kernel_build grava a sentinela pelo nome novo"
fi

# E um grub.cfg ja contaminado tem de ser reprovado, para ser regerado.
if grep -qF 'kernel-fragment.sha256' <<< "$(extract_fn "$REPO_DIR/05-bootloader.sh" probe_grub_cfg)"; then
    ok "probe_grub_cfg reprova grub.cfg que referencia a sentinela antiga"
else
    no "probe_grub_cfg aceita grub.cfg contaminado" \
       "quem instalou antes da correcao ficaria com a entrada falsa para sempre"
fi

# --- 06-sudo ----------------------------------------------------------------
# Pedido do operador (2026-09-02) apos o primeiro boot: `sudo: comando nao
# encontrado`. Um sudoers invalido faz o sudo recusar TUDO, inclusive o visudo
# que consertaria — por isso as asercoes abaixo cobrem ORDEM e MODO, nao so
# presenca.
printf '\n  -- 06-sudo --\n'

if grep -qE '^run_step 06-sudo ' "$USERS_SH"; then
    ok "06-sudo esta registrado como sub-etapa"
else
    no "nao existe run_step 06-sudo"
fi

# Ordem: o sudo depende do usuario existir para o aviso sobre wheel fazer sentido.
ln_users="$(grep -n '^run_step 06-users ' "$USERS_SH" | cut -d: -f1)"
ln_sudo="$(grep -n '^run_step 06-sudo ' "$USERS_SH" | cut -d: -f1)"
if [[ -n "$ln_users" && -n "$ln_sudo" ]] && (( ln_sudo > ln_users )); then
    ok "06-sudo roda depois de 06-users"
else
    no "06-sudo nao roda depois de 06-users (users=$ln_users sudo=$ln_sudo)"
fi

sudo_fn="$(extract_fn "$USERS_SH" do_sudo)"
if [[ -z "$sudo_fn" ]]; then
    no "do_sudo nao existe"
else
    # visudo -c ANTES do install: verificar depois de publicar seria tarde.
    ln_check="$(grep -n 'visudo -cqf' <<< "$sudo_fn" | tail -1 | cut -d: -f1)"
    ln_pub="$(grep -n 'install -m' <<< "$sudo_fn" | head -1 | cut -d: -f1)"
    if [[ -n "$ln_check" && -n "$ln_pub" ]] && (( ln_check < ln_pub )); then
        ok "do_sudo valida com visudo -c ANTES de publicar"
    else
        no "do_sudo publica sem validar antes (check=$ln_check publish=$ln_pub)"
    fi

    # O diretorio tem de ser criado ANTES de publicar nele. O emerge do sudo nao
    # o cria, e o @includedir para um diretorio inexistente nao e erro para o
    # sudo — falhou no bare metal em 2026-09-02 com "No such file or directory".
    ln_mkdir="$(grep -n 'install -d' <<< "$sudo_fn" | head -1 | cut -d: -f1)"
    if [[ -n "$ln_mkdir" && -n "$ln_pub" ]] && (( ln_mkdir < ln_pub )); then
        ok "do_sudo cria /etc/sudoers.d antes de publicar nele"
    else
        no "do_sudo publica em /etc/sudoers.d sem garantir que o diretorio existe" \
           "mkdir=$ln_mkdir publish=$ln_pub"
    fi

    # 0440: o sudo recusa ler sudoers com permissao mais frouxa.
    if grep -qE 'install -m 0440 -o root -g root' <<< "$sudo_fn"; then
        ok "o drop-in e publicado com 0440 root:root"
    else
        no "o drop-in nao e publicado com 0440 root:root" "o sudo recusaria le-lo"
    fi

    # ENABLE_SUDO=no e omissao, nunca remocao.
    if grep -qE 'emerge.*(-C|--unmerge|--depclean)|rm -f /etc/sudoers' <<< "$sudo_fn"; then
        no "do_sudo remove algo — ENABLE_SUDO=no deve ser omissao, nao remocao"
    else
        ok "ENABLE_SUDO=no nao desinstala nem apaga nada"
    fi

    # Nome do drop-in: o sudo IGNORA arquivos com ponto ou til em sudoers.d.
    dropin="$(grep -oE '/etc/sudoers\.d/[A-Za-z0-9_-]+' <<< "$sudo_fn" | head -1)"
    base="${dropin##*/}"
    if [[ -n "$base" && "$base" != *.* && "$base" != *"~"* ]]; then
        ok "nome do drop-in ('$base') nao tem ponto nem til — o sudo o le"
    else
        no "nome do drop-in ('$base') seria ignorado pelo sudo"
    fi
fi

# O regex do includedir tem de casar as duas formas validas e recusar comentario.
inc_fn="$(extract_fn "$USERS_SH" _sudoers_includes_dir)"
if [[ -z "$inc_fn" ]]; then
    no "_sudoers_includes_dir nao existe"
else
    STMP="$(mktemp -d)"
    check_inc() {
        printf '%s\n' "$2" > "$STMP/sudoers"
        if bash -c 'eval "$1"; _sudoers_includes_dir "$2"' _ "$inc_fn" "$STMP/sudoers"; then
            printf 'MATCH'
        else
            printf 'NOMATCH'
        fi
    }
    assert_eq MATCH   "$(check_inc x '@includedir /etc/sudoers.d')"  "aceita '@includedir' (forma moderna do Gentoo)"
    assert_eq MATCH   "$(check_inc x '#includedir /etc/sudoers.d')"  "aceita '#includedir' (forma legada — nao e comentario no sudo)"
    assert_eq NOMATCH "$(check_inc x '# includedir /etc/sudoers.d')" "recusa '# includedir' com espaco (isso e comentario de verdade)"
    assert_eq NOMATCH "$(check_inc x '@includedir /etc/sudoers.d.bak')" "recusa diretorio diferente"
    assert_eq NOMATCH "$(check_inc x 'Defaults env_reset')"          "recusa sudoers sem includedir"
    rm -rf "$STMP"
fi

finish
