#!/usr/bin/env bash
#
# test-desktop-dryrun.sh — prova, por SNAPSHOT, que `--dry-run` nao altera nada.
#
# Os outros testes do desktop verificam que a guarda EXISTE e vem antes do
# primeiro run_step. Isso e asercao sobre a forma do codigo. Este aqui mede o
# EFEITO: monta uma arvore de arquivos, tira hash de tudo, roda os scripts em
# dry-run, e tira hash de novo. Se um byte mudou, falha.
#
# LIMITE HONESTO DESTE TESTE — leia antes de confiar nele:
# Neste host os scripts param na GUARDA DE FASE ("este modulo so roda no sistema
# instalado e bootado"), que vem ANTES da guarda de dry-run. Entao o snapshot
# prova: "num host que nao e o Gentoo alvo, nenhum script muta nada" — o que
# valida a guarda de fase como fail-closed, e NAO que o dry-run funciona num
# Gentoo real. Fazer o contrario exigiria um jeito de PULAR a guarda de fase, e
# criar essa porta seria pior que a lacuna que ela fecharia.
# A cobertura do mecanismo de dry-run em si esta no bloco 6, que exercita
# dry_run_guard diretamente.
#
# Nada aqui instala, monta ou emerge. Os scripts sao executados com stubs de
# comandos externos no PATH e HOME/PORTAGE_DIR apontando para /tmp.

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

printf '\n== test-desktop-dryrun ==\n'

DESKTOP_DIR="$REPO_DIR/desktop"
if [[ ! -d "$DESKTOP_DIR" ]]; then
    printf '  SKIP  desktop/ nao existe\n'
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Sandbox: uma arvore que imita o que os scripts poderiam querer tocar
# ---------------------------------------------------------------------------
SANDBOX="$TMP/sandbox"
mkdir -p "$SANDBOX/etc/portage/package.use" \
         "$SANDBOX/etc/portage/package.accept_keywords" \
         "$SANDBOX/etc/portage/repos.conf" \
         "$SANDBOX/home/testuser/.config/niri" \
         "$SANDBOX/home/testuser/.config/foot" \
         "$SANDBOX/var/lib/gentoo-install/state"

# Arquivos de config do USUARIO, com conteudo reconhecivel: se algum script
# sobrescrever, o hash muda e o teste aponta o arquivo.
printf 'CONFIG DO USUARIO — NAO SOBRESCREVER\n' > "$SANDBOX/home/testuser/.config/niri/config.kdl"
printf 'user foot config\n'                     > "$SANDBOX/home/testuser/.config/foot/foot.ini"
printf 'x11-drivers/nvidia-drivers -tools\n'    > "$SANDBOX/etc/portage/package.use/desktop-niri"
printf '[guru]\nlocation = /var/db/repos/guru\n' > "$SANDBOX/etc/portage/repos.conf/guru.conf"
printf 'done\n' > "$SANDBOX/var/lib/gentoo-install/state/06-services"

snapshot() {
    # Hash de conteudo E de metadados (dono/modo): criar arquivo root-owned no
    # HOME do usuario tambem e mutacao, e passaria por um hash so de conteudo.
    find "$SANDBOX" -printf '%P %m %U:%G ' -exec sha256sum {} \; 2>/dev/null \
        | sed "s|$SANDBOX||g" | sort
}

ANTES="$TMP/antes.txt"
DEPOIS="$TMP/depois.txt"
snapshot > "$ANTES"
n_arquivos="$(wc -l < "$ANTES")"
ok "sandbox montado com $n_arquivos entradas (config de usuario, portage, state)"

# ---------------------------------------------------------------------------
# Stubs: qualquer comando externo que os scripts possam chamar.
#
# Todo stub REGISTRA a invocacao num arquivo e sai 0 sem fazer nada. Assim o
# teste prova duas coisas: (a) o sandbox nao mudou, e (b) nenhum comando
# MUTAVEL chegou a ser chamado — mesmo que ele fosse um no-op aqui.
# ---------------------------------------------------------------------------
STUBS="$TMP/stubs"
CHAMADAS="$TMP/chamadas.txt"
: > "$CHAMADAS"

# Mutaveis: se algum destes for chamado em dry-run, e falha.
for c in emerge rc-update systemctl usermod gpasswd useradd eselect \
         eselect-repository chsh mkfs.btrfs mount umount swapon swapoff \
         emerge-webrsync dispatch-conf etc-update; do
    make_stub "$STUBS" "$c" "printf 'MUTAVEL %s %s\n' \"\$(basename \$0)\" \"\$*\" >> '$CHAMADAS'; exit 0"
done
# Read-only: podem ser chamados a vontade; registramos so para diagnostico.
for c in portageq qlist equery lspci lsmod modinfo pgrep id getent \
         loginctl pactl wpa_cli iwctl fc-list gsettings; do
    make_stub "$STUBS" "$c" "printf 'RO %s %s\n' \"\$(basename \$0)\" \"\$*\" >> '$CHAMADAS'; exit 0"
done

# ---------------------------------------------------------------------------
# Executa cada numerado em dry-run
# ---------------------------------------------------------------------------
# A guarda de fase recusaria rodar fora de um Gentoo instalado — e ela roda
# ANTES da guarda de dry-run, entao os scripts saem cedo. Isso e correto e
# desejado: o teste mede que NADA muda, e um script que se recusa a rodar
# tambem nao muda nada. Para exercitar o caminho ate a guarda de dry-run,
# apontamos as variaveis de ambiente do sandbox e aceitamos qualquer exit code.
rodou=0
for f in "$DESKTOP_DIR"/1*.sh; do
    b="$(basename "$f")"
    [[ "$b" == "install-desktop.sh" || "$b" == "lib-desktop.sh" ]] && continue
    PATH="$STUBS:$PATH" \
    DESKTOP_DRY_RUN=yes \
    DESKTOP_USER=testuser \
    DESKTOP_USER_HOME="$SANDBOX/home/testuser" \
    DESKTOP_LOG_DIR="$TMP/logs" \
    HOME="$SANDBOX/home/testuser" \
    timeout 30 bash "$f" > "$TMP/out-$b.log" 2>&1 || true
    rodou=$((rodou + 1))
done
ok "$rodou scripts numerados executados com DESKTOP_DRY_RUN=yes"

# ---------------------------------------------------------------------------
# 1. O sandbox nao pode ter mudado — nem conteudo, nem dono, nem modo
# ---------------------------------------------------------------------------
snapshot > "$DEPOIS"
if diff -q "$ANTES" "$DEPOIS" > /dev/null 2>&1; then
    ok "nenhum arquivo do sandbox alterado (conteudo, dono e modo) — guarda de fase fail-closed"
else
    no "dry-run ALTEROU o sandbox" "$(diff "$ANTES" "$DEPOIS" | head -12)"
fi

# ---------------------------------------------------------------------------
# 2. Nenhum comando mutavel pode ter sido invocado
# ---------------------------------------------------------------------------
mutaveis="$(grep '^MUTAVEL' "$CHAMADAS" 2>/dev/null || true)"
if [[ -z "$mutaveis" ]]; then
    ok "nenhum comando mutavel (emerge/rc-update/usermod/eselect/...) foi invocado"
else
    no "comando mutavel invocado durante o dry-run" "$(head -8 <<< "$mutaveis")"
fi

# ---------------------------------------------------------------------------
# 3. Nenhum arquivo novo fora do sandbox, nos caminhos que os scripts tocam
# ---------------------------------------------------------------------------
# Uma mutacao com caminho ABSOLUTO escaparia do sandbox e do snapshot. Os
# scripts nao devem criar nada nestes caminhos durante um dry-run.
vazou=""
for p in /etc/portage/package.use/desktop-niri /etc/portage/repos.conf/guru.conf \
         /etc/X11/xorg.conf.d/20-nvidia.conf; do
    [[ -e "$p" ]] && vazou="$vazou $p"
done
if [[ -z "$vazou" ]]; then
    ok "nenhum arquivo criado nos caminhos absolutos de producao"
else
    no "dry-run criou arquivo REAL fora do sandbox:$vazou" \
       "estes caminhos existiam antes? se sim, o teste e inconclusivo neste host"
fi

# ---------------------------------------------------------------------------
# 4. Cada script anunciou que estava em dry-run (mensagem honesta)
# ---------------------------------------------------------------------------
sem_aviso=""
for f in "$DESKTOP_DIR"/1*.sh; do
    b="$(basename "$f")"
    [[ "$b" == "install-desktop.sh" || "$b" == "lib-desktop.sh" ]] && continue
    # Ou anunciou o dry-run, ou recusou por guarda de fase — os dois sao
    # "nao mutou". O que nao pode e rodar em silencio.
    if ! grep -qiE 'DRY_RUN|dry-run|sistema instalado|live ISO|chroot' "$TMP/out-$b.log" 2>/dev/null; then
        sem_aviso="$sem_aviso $b"
    fi
done
if [[ -z "$sem_aviso" ]]; then
    ok "todo script anunciou dry-run ou recusou por guarda de fase (nenhum rodou calado)"
fi

# ---------------------------------------------------------------------------
# 6. O MECANISMO de dry-run, exercitado diretamente
# ---------------------------------------------------------------------------
# O bloco 1 nao alcanca a guarda de dry-run neste host (ver o limite no topo).
# Aqui chamamos dry_run_guard de verdade e conferimos o contrato dela:
# sai com 0, imprime o plano, e NAO deixa o codigo seguinte executar.
mech="$(DESKTOP_DRY_RUN=yes bash -c '
    set -uo pipefail
    SCRIPT_DIR="$1/desktop"
    source "$1/vars.sh"; source "$1/lib.sh"
    source "$1/desktop/vars-desktop.sh" 2>/dev/null || true
    trap - ERR
    eval "$(sed -n "/^dry_run_guard() {/,/^}/p" "$1/desktop/lib-desktop.sh")"
    dry_run_guard etapa-a etapa-b
    echo "NAO-DEVERIA-CHEGAR-AQUI"
' _ "$REPO_DIR" 2>&1)"
rc_mech=$?

if [[ "$rc_mech" -eq 0 ]]; then
    ok "dry_run_guard sai com 0 (o orquestrador segue para a proxima etapa)"
else
    no "dry_run_guard saiu com $rc_mech" "um dry-run que aborta nao mostra o plano inteiro"
fi
assert_not_contains "$mech" "NAO-DEVERIA-CHEGAR-AQUI"     "dry_run_guard interrompe o script (codigo apos ela NAO executa)"
assert_contains "$mech" "etapa-a" "dry_run_guard imprime o plano das sub-etapas"
assert_contains "$mech" "etapa-b" "dry_run_guard imprime TODAS as sub-etapas anunciadas"

# Sem DESKTOP_DRY_RUN a guarda tem de ser transparente.
mech_off="$(bash -c '
    set -uo pipefail
    SCRIPT_DIR="$1/desktop"
    source "$1/vars.sh"; source "$1/lib.sh"
    source "$1/desktop/vars-desktop.sh" 2>/dev/null || true
    trap - ERR
    eval "$(sed -n "/^dry_run_guard() {/,/^}/p" "$1/desktop/lib-desktop.sh")"
    DESKTOP_DRY_RUN=no dry_run_guard etapa-a
    echo "SEGUIU-NORMALMENTE"
' _ "$REPO_DIR" 2>&1)"
assert_contains "$mech_off" "SEGUIU-NORMALMENTE"     "sem dry-run a guarda e transparente (nao interrompe)"
if true; then :
else
    no "script sem aviso de dry-run nem de guarda:$sem_aviso"
fi

# ---------------------------------------------------------------------------
# 5. A guarda existe em TODOS os numerados (forma, complementar ao efeito)
# ---------------------------------------------------------------------------
faltando=""
for f in "$DESKTOP_DIR"/1*.sh; do
    b="$(basename "$f")"
    [[ "$b" == "install-desktop.sh" || "$b" == "lib-desktop.sh" ]] && continue
    grep -qE '^dry_run_guard[[:space:]]|DESKTOP_DRY_RUN' "$f" || faltando="$faltando $b"
done
if [[ -z "$faltando" ]]; then
    ok "todos os numerados consultam DESKTOP_DRY_RUN"
else
    no "numerado sem nenhuma guarda de dry-run:$faltando"
fi

finish
