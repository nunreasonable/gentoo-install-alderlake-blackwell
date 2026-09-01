#!/usr/bin/env bash
# 12-niri-stack.sh — instala o compositor e o MINIMO para a sessao ser USAVEL.
#
# Fase: sistema JA INSTALADO E BOOTADO (regra 2). Nunca no live ISO, nunca no
# chroot da instalacao — require_booted_system() recusa, fail-closed.
#
# PRIORIDADE DECLARADA DESTA ETAPA: o minimo que sobe uma sessao usavel.
# Aparencia NAO entra aqui — tema, fonte, paleta e config.kdl sao da etapa 14,
# que roda por ULTIMO, depois que a etapa 15 provar que a sessao pode subir.
# Escrever tema num sistema onde o compositor nao inicia e desperdicio e ainda
# envenena o diagnostico, porque mistura sintoma de tema com sintoma de
# compositor.
#
# POR QUE ESTA ETAPA VEM DEPOIS DA 11: o USE=wayland do nvidia-drivers nao e
# default-on e o instalador base nao o liga em lugar nenhum. Sem ele nao existe
# caminho EGL/GBM e NENHUM compositor Wayland inicia — mas o modo de falha e
# cruel, porque tudo COMPILA normalmente e so quebra em runtime, com tela preta
# silenciosa. A etapa 11 prova o caminho EGL ANTES de gastarmos horas compilando
# o niri. Se voce chegou aqui, aquilo ja foi provado.
#
# ORDEM DAS SUB-ETAPAS (cada uma existe porque a seguinte depende dela):
#   12-seat-provider : provedor de seat — sem ele o niri NUNCA inicia
#   12-niri          : o compositor + verificacao critica do .desktop
#   12-terminal      : ferramenta de RECUPERACAO — etapa propria e obrigatoria
#   12-launcher      : fuzzel, o binario do bind default Mod+D
#   12-xwayland      : xwayland-satellite + xwayland (apps X11)
#   12-bar-notify    : waybar + mako
#   12-portals       : xdg-desktop-portal + backends -gnome e -gtk
#   12-audio         : pipewire + wireplumber (habilitacao fica no 13)
#
# O QUE ESTE SCRIPT DELIBERADAMENTE NAO FAZ:
#   - nao toca em NENHUM arquivo do instalador (regra 1)
#   - nao escreve package.use nem package.accept_keywords (territorio da 10)
#   - nao habilita servico nenhum (territorio da 13)
#   - nao escreve config em $HOME (territorio da 14)
#   - nao sobrescreve /usr/share/xdg-desktop-portal/niri-portals.conf (do ebuild)
#   - nao edita /usr/share/wayland-sessions/niri.desktop (do ebuild; ver 12-niri)
#   - nao instala xdg-desktop-portal-wlr (NAO funciona com niri — ver 12-portals)
#   - nao usa --autounmask-write nem ACCEPT_LICENSE=* global
#   - nao remove pacote nenhum (regra 4)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib-desktop.sh ja faz, nesta ordem: TARGET_ROOT="" -> vars.sh -> lib.sh ->
# vars-desktop.sh. O TARGET_ROOT vazio e o que faz state_dir() apontar para
# /var/lib/gentoo-install/state no sistema bootado (ver a "armadilha central"
# documentada no topo do lib-desktop.sh). NAO sourceie vars.sh/lib.sh aqui.
# shellcheck source=./lib-desktop.sh disable=SC1091
source "$SCRIPT_DIR/lib-desktop.sh"

init_logging_desktop 12-niri-stack
# Repetida aqui, e nao so no install-desktop.sh, porque os scripts do projeto
# rodam standalone para debug — mesmo padrao do require_phase nos 00-06.
require_booted_system
require_root

# Caminho do .desktop que o ebuild do niri instala. E o arquivo que a sub-etapa
# 12-niri inspeciona (nunca edita) para provar que USE=systemd nao vazou.
NIRI_SESSION_DESKTOP="/usr/share/wayland-sessions/niri.desktop"

# ---------------------------------------------------------------------------
# Validacao das escolhas — ANTES de qualquer probe
# ---------------------------------------------------------------------------
#
# Toda validacao de valor acontece AQUI, uma unica vez, e nao espalhada dentro
# das funcoes que geram listas de atoms. A razao e uma armadilha real do bash
# que este modulo precisa evitar:
#
#   Os probes leem as listas com `mapfile -t atoms < <(gera_atoms)`. A
#   substituicao de processo `< <(...)` roda o gerador NUM SUBSHELL. Se o
#   gerador chamasse die() por causa de um valor invalido, o `exit 1` mataria
#   APENAS o subshell — o mapfile continuaria com sucesso (ele leu o que deu),
#   o probe seguiria em frente e poderia retornar 0. Resultado: run_step
#   PULARIA a etapa silenciosamente diante de uma configuracao invalida.
#
# Isso e exatamente o "falhar em silencio" que o projeto proibe. Validar cedo,
# no escopo principal do script, garante que um valor errado mate o script na
# hora — com mensagem acionavel e antes de instalar coisa alguma.
validate_desktop_choices() {
    case "$DESKTOP_SEAT_PROVIDER" in
        seatd|elogind) ;;
        *) die "DESKTOP_SEAT_PROVIDER='$DESKTOP_SEAT_PROVIDER' invalido — use 'seatd' ou 'elogind'. Sao solucoes CONCORRENTES de seat management: escolha uma. Sem um provedor de seat ativo o niri nao consegue abrir /dev/dri e falha ao iniciar." ;;
    esac

    case "$DESKTOP_TERMINAL" in
        foot|alacritty|kitty) ;;
        *) die "DESKTOP_TERMINAL='$DESKTOP_TERMINAL' invalido — use foot, alacritty ou kitty. O terminal e a ferramenta de RECUPERACAO da sessao: entrar no niri sem terminal deixa voce numa tela vazia sem forma de abrir nada." ;;
    esac

    case "$DESKTOP_LAUNCHER" in
        fuzzel|none) ;;
        *) die "DESKTOP_LAUNCHER='$DESKTOP_LAUNCHER' nao e suportado por este modulo — use 'fuzzel' (o launcher recomendado pelo ebuild do niri e o binario do bind default Mod+D) ou 'none'. Nao instalamos um pacote cujo nome nao foi verificado (regra 3)." ;;
    esac

    case "$DESKTOP_BAR" in
        waybar|none) ;;
        *) die "DESKTOP_BAR='$DESKTOP_BAR' invalido — use 'waybar' ou 'none'." ;;
    esac

    case "$DESKTOP_NOTIFY" in
        mako|swaync|none) ;;
        *) die "DESKTOP_NOTIFY='$DESKTOP_NOTIFY' invalido — use 'mako' (::gentoo, estavel), 'swaync' (GURU, ~amd64, arrasta GTK4/Vala/Granite) ou 'none'." ;;
    esac

    case "$DESKTOP_ENABLE_XWAYLAND" in
        yes|no) ;;
        *) die "DESKTOP_ENABLE_XWAYLAND='$DESKTOP_ENABLE_XWAYLAND' invalido — use 'yes' ou 'no'." ;;
    esac

    case "$DESKTOP_ENABLE_SCREENCAST" in
        yes|no) ;;
        *) die "DESKTOP_ENABLE_SCREENCAST='$DESKTOP_ENABLE_SCREENCAST' invalido — use 'yes' ou 'no'." ;;
    esac
}

validate_desktop_choices

# ---------------------------------------------------------------------------
# Helper local de instalacao
# ---------------------------------------------------------------------------

# emerge_pkgs <rotulo> <atom>...: garante os atoms instalados, de forma
# idempotente e verificada.
#
# TRES decisoes deliberadas, cada uma respondendo a uma regra do projeto:
#
#   1. require_atoms ANTES do emerge (regra 3). Prova em SEGUNDOS que todo atom
#      resolve — overlay habilitado, keyword aceita, nome correto. A alternativa
#      e descobrir um nome errado depois de horas de compilacao ja gastas. A
#      etapa 10 ja rodou esse portao para o stack inteiro, mas repetimos por
#      grupo porque este script roda standalone para debug e porque o estado do
#      Portage pode ter mudado entre as etapas.
#
#   2. --noreplace: a intencao aqui e "garantir instalado", NUNCA "reinstalar".
#      Sem ele, cada re-execucao do modulo recompilaria o niri inteiro a toa.
#      Este e o flag que torna a etapa barata de repetir.
#
#   3. --oneshot: nao acrescenta os atoms ao @world... e por isso NAO o usamos.
#      Os pacotes deste modulo sao escolha explicita do usuario e devem
#      sobreviver a um `emerge --depclean`. Deixar o niri fora do @world faria o
#      depclean remove-lo silenciosamente — exatamente o tipo de surpresa que a
#      regra 4 existe para evitar.
emerge_pkgs() {
    local label="$1"; shift
    (( $# > 0 )) || return 0

    log_info "[$label] verificando a visibilidade dos atoms antes de compilar"
    require_atoms "$@"

    log_info "[$label] instalando: $*"
    emerge --noreplace "$@" \
        || die "falha ao instalar [$label]: $*. O emerge acima tem a causa real (conflito de USE, keyword, REQUIRED_USE ou erro de compilacao). NAO use --autounmask-write para 'resolver': isso reescreve a config do Portage as cegas. Veja $LOGFILE."
}

# all_installed <atom>...: 0 somente se TODOS os atoms estao no VDB.
# Base dos probes funcionais: consulta o banco de pacotes instalados do Portage,
# que e a autoridade real sobre o que esta em disco — nunca um marker.
all_installed() {
    local a
    for a in "$@"; do
        pkg_installed "$a" || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# 12-seat-provider — o pre-requisito silencioso
# ---------------------------------------------------------------------------
#
# ESTA E A ETAPA QUE A PESQUISA APONTOU COMO O ERRO MAIS CARO DE OMITIR: o
# instalador base 00-06 NAO instala nem configura seatd, elogind ou dbus
# (confirmado por grep, zero ocorrencias). Um modulo que so faz `emerge niri`
# produz um sistema onde o compositor compila, instala e NUNCA INICIA — ele
# morre no arranque ao falhar em abrir o seat, com uma mensagem que nao diz
# obviamente "faltou seat provider".
#
# NOTA SOBRE "NUNCA OS DOIS": a regra e sobre DAEMONS CONCORRENTES, nao sobre o
# pacote. sys-auth/seatd e DEPEND DIRETO do niri (o ebuild declara
# sys-auth/seatd:=), entao a libseat entra na maquina de qualquer forma — nao ha
# como "escolher elogind" e nao ter seatd instalado. O que a escolha controla e
# QUAL backend fica ativo, e isso ja foi decidido nas USE flags que a etapa 10
# escreveu:
#   rota seatd   -> sys-auth/seatd[builtin,server]        (daemon standalone)
#   rota elogind -> sys-auth/seatd[builtin,elogind,-server] + sys-auth/elogind
#                   (libseat com backend logind, SEM daemon concorrente)
# Instalar elogind E seatd[server] ao mesmo tempo poria dois daemons brigando
# pelo mesmo recurso — e por isso que o -server e a linha que importa.
#
# dbus entra aqui, junto, porque o comando de arranque do niri em OpenRC e
# literalmente `dbus-run-session niri --session`: sem dbus o comando NAO EXISTE.
# Ele viria como dependencia transitiva, mas declara-lo torna o probe honesto.

# seat_atoms: imprime os atoms do provedor de seat conforme a rota escolhida.
seat_atoms() {
    printf '%s\n' sys-auth/seatd
    printf '%s\n' sys-apps/dbus
    [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]] && printf '%s\n' sys-auth/elogind
    return 0
}

probe_seat_provider() {
    local -a atoms=()
    mapfile -t atoms < <(seat_atoms)
    all_installed "${atoms[@]}" || return 1

    # PROBE FUNCIONAL, nao apenas "o pacote esta la": verificamos as USE flags
    # com que o pacote em disco FOI CONSTRUIDO, lendo o VDB do Portage.
    #
    # A diferenca importa e ja mordeu este projeto na etapa 11: o package.use
    # diz o que voce PEDIU; o VDB diz o que voce TEM. Um seatd instalado ANTES
    # da etapa 10 escrever as USE flags (por exemplo, arrastado como dependencia
    # de outra coisa) estaria presente porem SEM 'builtin'/'server' — e o
    # servico OpenRC da etapa 13 simplesmente nao funcionaria, sem erro claro.
    local use_file d
    for d in /var/db/pkg/sys-auth/seatd-[0-9]*; do
        [[ -d "$d" && -f "$d/USE" ]] || continue
        use_file="$d/USE"
        break
    done
    [[ -n "${use_file:-}" ]] || return 1

    # builtin e exigido nas duas rotas (e a libseat embutida que o compositor usa).
    grep -qw builtin "$use_file" || return 1

    if [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]]; then
        # Rota elogind: o backend logind na libseat, e o daemon standalone
        # DESLIGADO para nao concorrer com o elogind.
        grep -qw elogind "$use_file" || return 1
        grep -qw server  "$use_file" && return 1
    else
        # Rota seatd puro: o daemon standalone precisa existir para a etapa 13
        # ter o que habilitar no runlevel.
        grep -qw server "$use_file" || return 1
    fi
    return 0
}

do_seat_provider() {
    local -a atoms=()
    mapfile -t atoms < <(seat_atoms)
    emerge_pkgs 12-seat-provider "${atoms[@]}"

    # Se chegamos aqui e o probe ainda reprovar, a causa quase certa e USE flag:
    # o pacote ja estava instalado com as flags erradas e o --noreplace, por
    # definicao, nao o reconstruiu. Mensagem acionavel em vez de deixar o
    # run_step morrer com o generico "do_fn terminou mas o probe reporta
    # nao-feito", que nao diria o que fazer.
    if ! probe_seat_provider; then
        die "sys-auth/seatd esta instalado mas NAO com as USE flags que esta rota exige (rota '$DESKTOP_SEAT_PROVIDER'). Isso acontece quando o pacote entrou como dependencia ANTES de a etapa 10 escrever o package.use — e o --noreplace, corretamente, nao reconstroi o que ja existe. Reconstrua explicitamente com: emerge --changed-use sys-auth/seatd${DESKTOP_SEAT_PROVIDER:+ }$( [[ $DESKTOP_SEAT_PROVIDER == elogind ]] && printf 'sys-auth/elogind' ) — e rode este script de novo."
    fi
}

# Sob --dry-run paramos AQUI. O validate_desktop_choices la em cima JA rodou de
# proposito: e somente-leitura e recusa combinacao invalida do vars-desktop.sh, o
# tipo de erro que so vale a pena descobrir ANTES da execucao real. Daqui para
# baixo toda sub-etapa chama emerge_pkgs, que compila de verdade.
dry_run_guard 12-seat-provider 12-niri 12-terminal 12-launcher 12-xwayland \
              12-bar-notify 12-portals 12-audio

run_step 12-seat-provider probe_seat_provider do_seat_provider

# ---------------------------------------------------------------------------
# 12-niri — o compositor, e a verificacao que a pesquisa marcou como CRITICA
# ---------------------------------------------------------------------------
#
# A ARMADILHA MAIOR DE TODO O PROJETO mora aqui, e ela e silenciosa.
#
# O .desktop upstream do niri tem `Exec=niri-session`. O script niri-session
# detecta systemctl ou dinitctl e, nao achando nenhum dos dois, imprime
# "No systemd or dinit detected, please use niri --session instead" e SAI.
# Em OpenRC isso significa: a sessao morre no arranque, normalmente voltando
# para o display manager ou para o TTY sem mensagem visivel.
#
# O ebuild do GURU JA CORRIGE isso: quando USE=-systemd e USE=dbus, o bloco
# `if ! use systemd` do src_prepare reescreve o resources/niri.desktop trocando
# o Exec por `dbus-run-session niri --session`. Ou seja: USE=-systemd NAO E
# COSMETICO, E FUNCIONAL.
#
# POR ISSO ESTA SUB-ETAPA VERIFICA O CONTEUDO DO ARQUIVO E NAO O EDITA:
#   - se o Exec estiver certo, o ebuild fez seu trabalho;
#   - se estiver errado, significa que USE=systemd VAZOU (o package.use da etapa
#     10 nao foi aplicado, ou alguem o sobrescreveu). O certo e MORRER com a
#     causa raiz, nao "consertar" o arquivo: um sed nosso seria sobrescrito no
#     proximo emerge do niri, e o usuario ficaria com uma bomba-relogio que
#     explode semanas depois, num update, sem relacao obvia com este modulo.
#
# Corrigir o sintoma e esconder a causa. Preferimos a mensagem acionavel.

probe_niri() {
    # 1. o binario existe (o pacote realmente instalou algo executavel)
    command -v niri >/dev/null 2>&1 || return 1
    # 2. o .desktop da sessao existe (e o que um DM listaria, e o que a etapa 15
    #    inspeciona ao validar a sessao)
    [[ -f "$NIRI_SESSION_DESKTOP" ]] || return 1
    # 3. e — a parte que importa — o Exec NAO e o niri-session quebrado.
    #    O grep procura a linha Exec= cujo valor comeca com "niri-session",
    #    ancorado para nao casar com "dbus-run-session niri --session".
    ! grep -qE '^Exec=[[:space:]]*niri-session([[:space:]]|$)' "$NIRI_SESSION_DESKTOP"
}

do_niri() {
    emerge_pkgs 12-niri gui-wm/niri

    # Verificacao POS-EMERGE, separada do probe para dar uma mensagem especifica.
    # O probe apenas responde sim/nao; aqui explicamos o que fazer.
    [[ -f "$NIRI_SESSION_DESKTOP" ]] \
        || die "o emerge do gui-wm/niri terminou mas '$NIRI_SESSION_DESKTOP' nao existe. Sem esse arquivo nenhum display manager lista a sessao. Confira a saida do emerge em $LOGFILE."

    if grep -qE '^Exec=[[:space:]]*niri-session([[:space:]]|$)' "$NIRI_SESSION_DESKTOP"; then
        die "'$NIRI_SESSION_DESKTOP' esta com Exec=niri-session — isso significa que o niri foi construido com USE=systemd. Em OpenRC essa sessao MORRE no arranque: o script niri-session procura systemctl/dinitctl e, sem nenhum dos dois, imprime 'No systemd or dinit detected' e sai. O ebuild so reescreve esse Exec para 'dbus-run-session niri --session' quando USE=-systemd e USE=dbus. NAO edite este arquivo a mao (ele pertence ao ebuild e seria sobrescrito no proximo emerge). CORRIJA A CAUSA: confirme a linha 'gui-wm/niri dbus screencast -systemd' em /etc/portage/package.use/desktop-niri (rode a etapa 10 novamente se faltar) e reconstrua com: emerge --changed-use gui-wm/niri"
    fi

    log_info "niri.desktop verificado: Exec correto para OpenRC (nao e niri-session)"
}

run_step 12-niri probe_niri do_niri

# ---------------------------------------------------------------------------
# 12-terminal — etapa PROPRIA e obrigatoria
# ---------------------------------------------------------------------------
#
# Esta e uma etapa separada de proposito, e nao um item na lista de pacotes.
#
# O terminal e a ferramenta de RECUPERACAO da sessao. Entrar no niri sem
# terminal instalado deixa o usuario numa tela vazia, sem forma nenhuma de abrir
# nada — e a saida (Mod+Shift+E) nao e obvia para quem nunca usou o compositor.
# Se o launcher tambem falhar, a unica saida e o TTY. Por isso a fase NAO pode
# ser declarada concluida sem terminal instalado.
#
# O default DESKTOP_TERMINAL=foot e uma escolha tecnica, nao de gosto: o foot
# renderiza em CPU via pixman e NAO abre contexto EGL/GL, entao nao depende do
# caminho EGL/GBM da NVIDIA — que e exatamente o subsistema que este projeto
# nunca validou em hardware real. alacritty e kitty sao GPU-accelerated e sao os
# PRIMEIROS a falhar se o EGL estiver errado. A ferramenta de diagnostico nao
# pode depender do subsistema sob diagnostico.

# terminal_atom: traduz DESKTOP_TERMINAL no atom correspondente.
# Repare nas CATEGORIAS, que sao diferentes entre si e sao um erro classico de
# digitacao: gui-apps/foot mas x11-terms/alacritty e x11-terms/kitty.
# O valor ja foi validado por validate_desktop_choices no topo do script, entao
# aqui basta traduzir. Nao repetimos o die: dentro de uma substituicao de
# comando ele funcionaria, mas dentro de `< <(...)` seria engolido pelo subshell
# — e ter duas validacoes com comportamentos diferentes e pior que ter uma so.
terminal_atom() {
    case "$DESKTOP_TERMINAL" in
        foot)      printf '%s\n' gui-apps/foot ;;
        alacritty) printf '%s\n' x11-terms/alacritty ;;
        kitty)     printf '%s\n' x11-terms/kitty ;;
    esac
}

probe_terminal() {
    local atom
    atom="$(terminal_atom)" || return 1
    pkg_installed "$atom" || return 1

    # Alem do pacote, exigimos o BINARIO no PATH: e o binario que o bind Mod+T
    # do config.kdl (etapa 14) vai invocar. Um pacote instalado cujo executavel
    # nao esta no PATH deixaria o bind falhando em silencio — que e o sintoma
    # que esta etapa existe para impedir.
    command -v "$DESKTOP_TERMINAL" >/dev/null 2>&1
}

do_terminal() {
    local atom
    atom="$(terminal_atom)"
    emerge_pkgs 12-terminal "$atom"

    command -v "$DESKTOP_TERMINAL" >/dev/null 2>&1 \
        || die "'$atom' foi instalado mas o binario '$DESKTOP_TERMINAL' nao esta no PATH. O bind Mod+T do config.kdl chama esse binario pelo nome — sem ele o atalho falha em silencio dentro da sessao. Confira o que o pacote instalou com: qlist $atom | grep bin/"
}

run_step 12-terminal probe_terminal do_terminal

# ---------------------------------------------------------------------------
# 12-launcher — o binario do bind default Mod+D
# ---------------------------------------------------------------------------
#
# gui-apps/fuzzel vive no GURU (~amd64) — NAO existe no ::gentoo (HTTP 404
# confirmado). E o launcher recomendado pelo proprio ebuild do niri (optfeature
# "Application launcher") e o binario referenciado no bind default Mod+D do
# config KDL.
#
# Sem ele o bind falha EM SILENCIO: o usuario aperta Mod+D, nada acontece, e nao
# ha mensagem de erro visivel dentro da sessao. Junto com o terminal, este e o
# par minimo que torna a sessao operavel.

probe_launcher() {
    # "none" nao e um valor documentado em vars-desktop.sh para esta variavel,
    # mas aceitamos como escape: quem deliberadamente nao quer launcher nao deve
    # ser bloqueado — desde que tenha terminal, a sessao continua operavel.
    [[ "$DESKTOP_LAUNCHER" == "none" ]] && return 0
    pkg_installed gui-apps/fuzzel || return 1
    command -v fuzzel >/dev/null 2>&1
}

do_launcher() {
    if [[ "$DESKTOP_LAUNCHER" == "none" ]]; then
        log_warn "DESKTOP_LAUNCHER=none — nenhum lancador sera instalado. O bind Mod+D do config default do niri vai falhar em silencio; use o terminal ($DESKTOP_TERMINAL) para abrir aplicativos."
        return 0
    fi

    emerge_pkgs 12-launcher gui-apps/fuzzel

    command -v fuzzel >/dev/null 2>&1 \
        || die "gui-apps/fuzzel foi instalado mas o binario 'fuzzel' nao esta no PATH. O bind Mod+D o chama pelo nome; sem ele o atalho falha silenciosamente dentro da sessao."
}

run_step 12-launcher probe_launcher do_launcher

# ---------------------------------------------------------------------------
# 12-xwayland — apps X11 nao vem de graca
# ---------------------------------------------------------------------------
#
# O niri NAO tem Xwayland embutido e NAO integra o xwayland-satellite sozinho.
# Sem este pacote, NENHUM aplicativo X11 abre — o que inclui muitos jogos,
# Electron antigo e boa parte do software legado.
#
# INSTALAR O PACOTE E SO METADE DO TRABALHO. A outra metade e a linha
# `spawn-at-startup "xwayland-satellite"` no ~/.config/niri/config.kdl, que a
# etapa 14 escreve. Sem a linha, o pacote fica instalado e inerte, e o sintoma e
# identico ao de nao te-lo instalado — armadilha classica de diagnostico.
#
# NOTA SOBRE LLVM (custo de disco inesperado, nao erro): o ebuild do niri declara
# LLVM_COMPAT 19..22 e o do xwayland-satellite 17..21. Se os slots escolhidos
# nao coincidirem, o Portage pode instalar DUAS versoes de LLVM na maquina. Isso
# funciona, mas surpreende quem ve o espaco em disco depois.

xwayland_atoms() {
    printf '%s\n' gui-apps/xwayland-satellite
    # x11-base/xwayland e DEPEND do satellite (>=23.1) e viria junto de qualquer
    # forma. Declaramos explicitamente para que uma eventual falta apareca no
    # require_atoms, em segundos, e nao no meio da compilacao.
    printf '%s\n' x11-base/xwayland
}

probe_xwayland() {
    [[ "$DESKTOP_ENABLE_XWAYLAND" == "yes" ]] || return 0
    local -a atoms=()
    mapfile -t atoms < <(xwayland_atoms)
    all_installed "${atoms[@]}" || return 1
    command -v xwayland-satellite >/dev/null 2>&1
}

do_xwayland() {
    if [[ "$DESKTOP_ENABLE_XWAYLAND" != "yes" ]]; then
        log_warn "DESKTOP_ENABLE_XWAYLAND=$DESKTOP_ENABLE_XWAYLAND — suporte a X11 NAO sera instalado. Nenhum aplicativo X11 (incluindo muitos jogos e Electron antigo) abrira dentro do niri."
        return 0
    fi

    local -a atoms=()
    mapfile -t atoms < <(xwayland_atoms)
    emerge_pkgs 12-xwayland "${atoms[@]}"

    command -v xwayland-satellite >/dev/null 2>&1 \
        || die "gui-apps/xwayland-satellite foi instalado mas o binario 'xwayland-satellite' nao esta no PATH. Ele e invocado por nome no spawn-at-startup do config.kdl."

    # Lembrete explicito da metade que falta. Nao escrevemos o config aqui:
    # $HOME e territorio da etapa 14, e misturar as duas quebraria a ordem de
    # validacao (sessao primeiro, aparencia e configuracao depois).
    log_info "xwayland-satellite instalado. LEMBRETE: instalar o pacote NAO basta — a etapa 14 precisa declarar 'spawn-at-startup \"xwayland-satellite\"' no ~/.config/niri/config.kdl, senao nenhum app X11 abre."
}

run_step 12-xwayland probe_xwayland do_xwayland

# ---------------------------------------------------------------------------
# 12-bar-notify — barra de status e notificacoes
# ---------------------------------------------------------------------------
#
# WAYBAR NAO E OPCIONAL POR UM MOTIVO NAO-ESTETICO: a doc upstream indica que o
# config default do niri ja faz spawn-at-startup da waybar. Se ela nao estiver
# instalada, o compositor gera um erro de spawn no log A CADA BOOT — ruido
# permanente que confunde exatamente o diagnostico que as etapas 15 e seguintes
# dependem. Instalar a barra e mais barato que aprender a ignorar o erro.
#
# A USE=niri (escrita pela etapa 10) e o ponto critico da waybar: sem ela a
# barra sobe normalmente mas NAO le os workspaces do niri, e o usuario conclui
# que "a barra esta quebrada". Ela ja existe na 0.14.0, que e ESTAVEL amd64 —
# nao e preciso destravar a 0.15.0 so por isso.
#
# mako e o daemon de notificacoes recomendado pela doc upstream do niri, esta no
# ::gentoo e e estavel. swaync e a alternativa COM painel de historico, mas vive
# no GURU (~amd64) e arrasta GTK4, Vala, Granite, libadwaita, libhandy, sassc e
# gui-libs/gtk4-layer-shell (que nao tem versao estavel) — muito tempo de emerge
# por um ganho que o mako ja entrega em boa parte.

# Valores ja validados por validate_desktop_choices no topo (ver o comentario
# la sobre o subshell do `< <(...)` engolir o die).
bar_notify_atoms() {
    [[ "$DESKTOP_BAR" == "waybar" ]] && printf '%s\n' gui-apps/waybar
    case "$DESKTOP_NOTIFY" in
        mako)   printf '%s\n' gui-apps/mako ;;
        swaync) printf '%s\n' gui-apps/swaync ;;
        none)   ;;
    esac
    return 0
}

probe_bar_notify() {
    local -a atoms=()
    mapfile -t atoms < <(bar_notify_atoms)
    (( ${#atoms[@]} == 0 )) && return 0
    all_installed "${atoms[@]}" || return 1

    # Probe funcional extra na waybar: a USE=niri e o que diferencia uma barra
    # util de uma barra sem workspaces. Lemos o VDB (o que foi CONSTRUIDO), nao
    # o package.use (o que foi PEDIDO).
    if [[ "$DESKTOP_BAR" == "waybar" ]]; then
        local d use_file=""
        for d in /var/db/pkg/gui-apps/waybar-[0-9]*; do
            [[ -d "$d" && -f "$d/USE" ]] || continue
            use_file="$d/USE"
            break
        done
        [[ -n "$use_file" ]] || return 1
        grep -qw niri "$use_file" || return 1
    fi
    return 0
}

do_bar_notify() {
    if [[ "$DESKTOP_BAR" == "none" ]]; then
        log_warn "DESKTOP_BAR=none — a barra NAO sera instalada. ATENCAO: o config default do niri faz spawn de waybar; a etapa 14 NAO deve declarar esse spawn no config.kdl, senao o compositor gera erro de spawn no log a cada boot."
    fi
    if [[ "$DESKTOP_NOTIFY" == "none" ]]; then
        log_warn "DESKTOP_NOTIFY=none — nenhum daemon de notificacoes. Aplicativos que enviam notificacao via D-Bus nao terao quem as exiba."
    fi

    local -a atoms=()
    mapfile -t atoms < <(bar_notify_atoms)
    emerge_pkgs 12-bar-notify "${atoms[@]}"

    # Mensagem especifica para o caso da USE=niri ausente — o probe generico
    # nao explicaria por que reprovou.
    if [[ "$DESKTOP_BAR" == "waybar" ]] && ! probe_bar_notify; then
        die "gui-apps/waybar esta instalada mas NAO foi construida com USE=niri. Sem essa flag a barra sobe e funciona, porem NAO le os workspaces do niri — e o sintoma parece 'barra quebrada'. A flag ja existe na 0.14.0 (estavel amd64). Confirme a linha 'gui-apps/waybar niri ...' em /etc/portage/package.use/desktop-niri (rode a etapa 10 se faltar) e reconstrua com: emerge --changed-use gui-apps/waybar"
    fi
}

run_step 12-bar-notify probe_bar_notify do_bar_notify

# ---------------------------------------------------------------------------
# 12-portals — e a armadilha do backend errado
# ---------------------------------------------------------------------------
#
# ARMADILHA EVITADA AQUI: o reflexo natural de quem vem de WM tiling em Wayland
# e instalar sys-apps/xdg-desktop-portal-wlr. Isso NAO FUNCIONA com o niri, que
# nao e baseado em wlroots. Instalar o -wlr da a sensacao de "portais instalados"
# e o screenshare continua sem funcionar, sem erro obvio.
#
# O backend CORRETO e o -gnome (screencast) — o proprio ebuild do niri declara
# RDEPEND="screencast? ( sys-apps/xdg-desktop-portal-gnome )" — com o -gtk como
# fallback, exigido pelo niri-portals.conf que o ebuild instala com
# `default=gnome;gtk;` e que aponta Access e Notification para o gtk.
#
# NAO SOBRESCREVEMOS /usr/share/xdg-desktop-portal/niri-portals.conf: ele vem do
# ebuild, ja com a cadeia correta. Reescreve-lo geraria conflito de CONFIG_PROTECT
# no proximo emerge e pisaria em arquivo do gerenciador de pacotes (regra 4).
#
# NOTA (fora do escopo desta etapa, mas relevante para o diagnostico futuro): a
# partir do xdg-desktop-portal-gnome 47.0 o file chooser padrao passou a ser o
# nautilus. Sem um gerenciador de arquivos instalado, dialogos de abrir/salvar
# podem falhar. A alternativa e apontar org.freedesktop.impl.portal.FileChooser
# para o gtk. Nada disso e feito aqui: nao e "minimo para a sessao subir".

portal_atoms() {
    printf '%s\n' sys-apps/xdg-desktop-portal
    printf '%s\n' sys-apps/xdg-desktop-portal-gnome
    printf '%s\n' sys-apps/xdg-desktop-portal-gtk
}

probe_portals() {
    local -a atoms=()
    mapfile -t atoms < <(portal_atoms)
    all_installed "${atoms[@]}"
}

do_portals() {
    local -a atoms=()
    mapfile -t atoms < <(portal_atoms)
    emerge_pkgs 12-portals "${atoms[@]}"

    # Aviso explicito se o -wlr estiver presente. NAO o removemos: a regra 4
    # proibe remover pacote do usuario, e ele pode estar la por outro motivo.
    # Mas o usuario precisa saber que ele nao serve para o niri, porque a
    # presenca dele e uma pista falsa poderosa durante o diagnostico.
    if pkg_installed sys-apps/xdg-desktop-portal-wlr; then
        log_warn "sys-apps/xdg-desktop-portal-wlr esta instalado nesta maquina. Ele NAO funciona com o niri (que nao e baseado em wlroots) e pode competir pela mesma interface de portal. Este modulo NAO o remove (regra: nunca remover pacote do usuario), mas se o screenshare falhar, ele e o primeiro suspeito."
    fi

    # O arquivo vem do ebuild do niri. Se faltar, os portais nao sabem qual
    # backend usar nesta sessao. Aviso, nao erro: a sessao ainda sobe sem ele.
    local niri_portals="/usr/share/xdg-desktop-portal/niri-portals.conf"
    if [[ -f "$niri_portals" ]]; then
        log_info "niri-portals.conf presente (instalado pelo ebuild do niri) — nao e modificado por este modulo"
    else
        log_warn "'$niri_portals' NAO existe. Ele deveria vir do ebuild do gui-wm/niri e e o que define a cadeia de portais (default=gnome;gtk;). Sem ele, screencast e dialogos de arquivo podem escolher o backend errado."
    fi
}

run_step 12-portals probe_portals do_portals

# ---------------------------------------------------------------------------
# 12-audio — pipewire E wireplumber (o segundo nao e opcional)
# ---------------------------------------------------------------------------
#
# ARMADILHA: instalar apenas o media-video/pipewire deixa o audio MUDO, sem
# nenhum dispositivo listado — e o sintoma nao aponta para a causa. O
# media-video/wireplumber e o gerenciador de sessao/politica: e ele que roteia
# e que faz os dispositivos aparecerem. Na pratica, e obrigatorio.
#
# A HABILITACAO NAO ACONTECE AQUI, e isso e deliberado: em OpenRC o PipeWire
# NAO e servico de sistema. `rc-update add pipewire default` como root
# simplesmente nao funciona — sao servicos de USUARIO (`rc-update add -U`, que
# exige OpenRC recente) ou o wrapper gentoo-pipewire-launcher no autostart do
# compositor. O proprio ebuild marca USE=system-service como "Not recommended".
# Essa decisao (e a medicao da versao do OpenRC, via openrc_version_ge) pertence
# a etapa 13, que e a dona dos servicos.

probe_audio() {
    # Sem screencast o pipewire nao e estritamente necessario para a sessao
    # SUBIR; audio continua desejavel, mas nao e o "minimo usavel" desta etapa e
    # nao vamos forcar a instalacao contra a escolha do usuario.
    [[ "$DESKTOP_ENABLE_SCREENCAST" == "yes" ]] || return 0
    all_installed media-video/pipewire media-video/wireplumber
}

do_audio() {
    if [[ "$DESKTOP_ENABLE_SCREENCAST" != "yes" ]]; then
        log_warn "DESKTOP_ENABLE_SCREENCAST=$DESKTOP_ENABLE_SCREENCAST — pipewire/wireplumber nao serao instalados por esta etapa. Sem eles nao ha audio nem screencast/screenshare na sessao."
        return 0
    fi

    # wireplumber vem junto no MESMO emerge, de proposito: um sistema com
    # pipewire e sem wireplumber e um sistema com audio mudo, e a janela entre
    # dois emerges separados e exatamente onde alguem interrompe o processo e
    # fica no pior dos dois mundos.
    emerge_pkgs 12-audio media-video/pipewire media-video/wireplumber

    log_info "pipewire e wireplumber instalados. A HABILITACAO e da etapa 13: em OpenRC estes sao servicos de USUARIO (rc-update add -U) ou o wrapper gentoo-pipewire-launcher no autostart — 'rc-update add pipewire default' como root NAO funciona."
}

run_step 12-audio probe_audio do_audio

# ---------------------------------------------------------------------------
# Relatorio final
# ---------------------------------------------------------------------------

log_info "==== 12-niri-stack concluido com sucesso ===="
log_info "compositor: $(command -v niri) | terminal: $DESKTOP_TERMINAL | launcher: $DESKTOP_LAUNCHER"
log_info "seat: $DESKTOP_SEAT_PROVIDER | barra: $DESKTOP_BAR | notificacoes: $DESKTOP_NOTIFY"
log_info "xwayland: $DESKTOP_ENABLE_XWAYLAND | screencast/audio: $DESKTOP_ENABLE_SCREENCAST"

# O aviso final existe porque este e o ponto do projeto em que e mais tentador
# reiniciar e "testar logo" — e onde isso mais custa caro. Os pacotes estao em
# disco, mas NADA ainda esta habilitado nem configurado: sem o seat provider no
# runlevel (etapa 13) o niri falha ao abrir o seat e a sessao morre no arranque,
# com um sintoma (tela preta) indistinguivel do problema de NVIDIA que a etapa 11
# tratou. Diagnosticar as duas coisas ao mesmo tempo e o pior cenario possivel.
cat <<'PROXIMOS'

========================================================================
  PACOTES INSTALADOS — A SESSAO AINDA NAO ESTA PRONTA
========================================================================
Esta etapa instalou o stack, mas NAO habilitou nem configurou nada.
NAO reinicie para "testar" ainda: sem os servicos da etapa 13 o niri
falha ao abrir o seat e a sessao morre no arranque — e o sintoma (tela
preta) e identico ao de um problema de NVIDIA, o que torna o diagnostico
muito mais dificil do que precisa ser.

FALTA, nesta ordem:
  13-services : habilitar o provedor de seat e o dbus no runlevel, e
                colocar o usuario nos grupos (video, seat/input). Sem
                isso o compositor nao consegue acesso a DRM/input.
  15-validate : PROVAR que a sessao pode subir, ANTES de qualquer
                reboot. Falhar aqui, com mensagem acionavel, e muito
                melhor que reiniciar e cair numa tela preta sem console.
  14-dotfiles : config.kdl, tema e fontes — por ULTIMO, so depois que a
                sessao comprovadamente sobe.

Quando chegar a hora de iniciar a sessao no TTY, o comando em OpenRC e:

    dbus-run-session niri --session

NUNCA use 'niri-session' em OpenRC: esse script procura systemctl ou
dinitctl e, sem nenhum dos dois, imprime "No systemd or dinit detected"
e sai — a sessao morre na hora, normalmente sem mensagem visivel.
========================================================================

PROXIMOS
