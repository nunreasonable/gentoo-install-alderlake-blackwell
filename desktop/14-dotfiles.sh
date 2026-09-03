#!/usr/bin/env bash
# 14-dotfiles.sh — configuracao do USUARIO: config.kdl do niri, fontes, tema
# GTK/cursor, barra e terminal.
#
# Fase: sistema JA INSTALADO E BOOTADO (regra 2). Nunca no live ISO, nunca no
# chroot da instalacao — require_booted_system() recusa, fail-closed.
#
# POR QUE ESTE SCRIPT E O ULTIMO (depois inclusive do 15-validate):
#
#   Aparencia so importa se a sessao sobe. Escrever tema num sistema onde o
#   compositor nao inicia e desperdicio, e — pior — ENVENENA O DIAGNOSTICO,
#   porque passa a misturar sintoma de tema com sintoma de compositor. Quando
#   alguem ve a tela errada, precisa saber se o problema e o niri, a NVIDIA ou
#   um dotfile; rodar a estetica por ultimo mantem essas causas separadas.
#
# A REGRA QUE ATRAVESSA O ARQUIVO INTEIRO: TODA escrita em $HOME e TODO gsettings
# passam por run_as_user. Os motivos sao dois, ambos verificados na pesquisa:
#
#   1. gsettings rodado como root escreve no dconf do ROOT — o valor "sumiria"
#      da sessao do usuario sem erro nenhum, que e o pior tipo de falha.
#   2. dotfile criado por root dentro do $HOME do usuario nasce com dono errado.
#      Um ~/.config/niri/config.kdl que o usuario nao consegue ler nem editar e
#      um jeito silencioso de quebrar a sessao grafica inteira.
#
# Como o modulo roda com sudo, o default seria fazer tudo errado. Por isso o
# script NUNCA escreve em $HOME direto: todo caminho passa por run_as_user.
#
# ORDEM DAS SUB-ETAPAS (cada uma existe porque a seguinte depende dela):
#   14-niri-config     : o config.kdl — sem ele nao ha binds nem Xwayland
#   14-fontconfig      : fontes + 50-user.conf (senao a config e IGNORADA)
#   14-gtk-theme       : gsettings (autoridade em Wayland) + settings.ini
#   14-bar-config      : waybar (CSS + JSON) com a paleta
#   14-terminal-config : terminal com a mesma paleta e a mesma fonte
#
# O QUE ESTE SCRIPT DELIBERADAMENTE NAO FAZ:
#   - nao toca em NENHUM arquivo do instalador (regra 1)
#   - nao sobrescreve config que o usuario ja tenha escrito (regra 4)
#   - nao instala pacote de tema de overlay: a paleta e hex escrito nos configs
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

init_logging_desktop 14-dotfiles
# Repetida aqui, e nao so no install-desktop.sh, porque os scripts do projeto
# rodam standalone para debug — mesmo padrao do require_phase nos 00-06.
require_booted_system
require_root

# HOME real do usuario alvo, lido do /etc/passwd via getent (user_home do
# lib-desktop.sh). NUNCA montado como "/home/$user": o home pode estar em outro
# caminho, e adivinhar isso escreveria a config inteira num diretorio que
# ninguem le — falha silenciosa e cara de diagnosticar.
USER_HOME="$(user_home)"

# Diretorios de config do usuario, todos derivados do HOME real.
NIRI_CONFIG_DIR="$USER_HOME/.config/niri"
NIRI_CONFIG="$NIRI_CONFIG_DIR/config.kdl"
FONTCONFIG_DIR="$USER_HOME/.config/fontconfig"
FONTCONFIG_FILE="$FONTCONFIG_DIR/fonts.conf"

# ---------------------------------------------------------------------------
# ROTA DE ARRANQUE DO PIPEWIRE — decidida pela etapa 13, obedecida aqui
# ---------------------------------------------------------------------------
#
# A etapa 13 nao consegue habilitar o PipeWire de um jeito unico: servicos de
# USUARIO (`rc-update add -U`) exigem OpenRC >= 0.60, e em versao anterior a
# unica rota disponivel e o wrapper /usr/bin/gentoo-pipewire-launcher no
# autostart do COMPOSITOR — que e um arquivo DESTA etapa, nao daquela. Por isso
# a 13 MEDE a versao do OpenRC, decide, e grava a decisao no marker
# '13-audio-route'. Aqui nao se decide nada: apenas se obedece.
#
# AS DUAS ROTAS SAO MUTUAMENTE EXCLUSIVAS, e declarar as duas NAO e redundancia
# inofensiva: o PipeWire subiria DUAS VEZES na mesma sessao. Duas instancias
# disputando os mesmos dispositivos dao audio cortado, dispositivo que some do
# mixer e erro de socket ja em uso — e o sintoma nao aponta para a causa. Por
# isso a linha de spawn-at-startup so pode existir quando a rota e exatamente
# 'launcher'.
#
# VALORES POSSIVEIS (gravados por 13-audio-user-services):
#   "user-services" -> `rc-update add -U` ja feito na 13; NAO declarar o launcher
#   "launcher"      -> fallback de OpenRC < 0.60; declarar o launcher aqui
#   ""              -> marker AUSENTE. Acontece em dois casos legitimos:
#                      (a) media-video/pipewire nao esta instalado — a 13 pula a
#                          etapa de audio inteira, o que e escolha valida;
#                      (b) esta etapa foi rodada standalone, antes da 13.
#
# POR QUE O VAZIO (ou um valor desconhecido) NAO DECLARA A LINHA — e tambem nao
# mata o script: sem saber a rota, os dois erros possiveis tem pesos MUITO
# diferentes. Declarar a linha numa maquina de rota 'user-services' quebra o
# audio de forma confusa e duradoura. NAO declarar, numa maquina que precisava
# do launcher, deixa o audio sem arrancar — chato, porem obvio e corrigivel com
# UMA linha, que este script imprime no final. Fail-closed aqui e escolher o
# erro menor e AVISAR com a correcao exata, nao abortar a etapa de aparencia.
PIPEWIRE_LAUNCHER="/usr/bin/gentoo-pipewire-launcher"
AUDIO_ROUTE="$(step_value 13-audio-route)"

case "$AUDIO_ROUTE" in
    user-services|launcher|"")
        :
        ;;
    *)
        # Valor que nenhuma versao da 13 grava: state corrompido ou editado a
        # mao. Nao adivinhamos qual rota ele quis dizer — tratamos como
        # desconhecido, que ja tem comportamento definido (nao declarar).
        log_warn "o marker '13-audio-route' contem um valor inesperado ('$AUDIO_ROUTE'). Os unicos valores gravados pela etapa 13 sao 'user-services' e 'launcher'. Tratando como DESCONHECIDO: o launcher do PipeWire NAO sera declarado no config.kdl. Inspecione o estado real com: cat $DESKTOP_STATE_DIR/13-audio-route"
        AUDIO_ROUTE="desconhecido"
        ;;
esac

log_info "rota de audio herdada da etapa 13: '${AUDIO_ROUTE:-(marker ausente)}'"

# ---------------------------------------------------------------------------
# PALETA — hex direto, sem pacote de tema
# ---------------------------------------------------------------------------
#
# DECISAO CONSCIENTE, e a justificativa e o oposto de uma limitacao: NAO existe
# nenhum pacote catppuccin no ::gentoo. Isso e VANTAGEM, nao problema — a paleta
# e apenas uma lista de hex aplicada em arquivos de config que este script ja vai
# gerar de qualquer forma. Escrevendo os hex a mao, o modulo inteiro permanece
# dentro do ::gentoo: zero overlay novo, zero ~amd64, zero dependencia de um
# pacote de tema que pode quebrar num update ou ficar sem manutencao.
#
# Hex da variante Mocha (escura), da especificacao oficial do Catppuccin.
palette_set() {
    case "$DESKTOP_PALETTE" in
        catppuccin-mocha)
            PAL_BASE="#1e1e2e"      # fundo principal
            PAL_SURFACE0="#313244"  # elementos elevados / borda inativa
            PAL_TEXT="#cdd6f4"      # texto principal
            PAL_SUBTEXT="#a6adc8"   # texto secundario
            PAL_MAUVE="#cba6f7"     # acento (foco)
            PAL_RED="#f38ba8"
            PAL_GREEN="#a6e3a1"
            PAL_YELLOW="#f9e2af"
            PAL_BLUE="#89b4fa"
            PAL_PINK="#f5c2e7"
            PAL_TEAL="#94e2d5"
            ;;
        *)
            # Regra 3 aplicada a estetica: em vez de cair num default silencioso
            # e escrever uma cor que o usuario nao pediu, morremos dizendo o que
            # existe. Acrescentar uma paleta e acrescentar um case aqui.
            die "DESKTOP_PALETTE='$DESKTOP_PALETTE' desconhecida. A unica paleta implementada e 'catppuccin-mocha'. Para acrescentar outra, adicione um case em palette_set() com os hex correspondentes — o modulo escreve cor por hex, nao instala pacote de tema."
            ;;
    esac
}
palette_set

# Versao dos hex SEM o '#', exigida pelo formato INI do foot (que usa
# 'background=1e1e2e'). Derivadas dos valores acima para que exista UMA fonte de
# verdade da paleta: mudar o hex la em cima muda todos os formatos de uma vez.
#
# So existem as variantes que o foot.ini realmente consome — alacritty e kitty
# usam os hex COM '#', direto das variaveis originais.
PAL_BASE_RAW="${PAL_BASE#\#}"
PAL_TEXT_RAW="${PAL_TEXT#\#}"
PAL_SURFACE0_RAW="${PAL_SURFACE0#\#}"
PAL_RED_RAW="${PAL_RED#\#}"
PAL_GREEN_RAW="${PAL_GREEN#\#}"
PAL_YELLOW_RAW="${PAL_YELLOW#\#}"
PAL_BLUE_RAW="${PAL_BLUE#\#}"
PAL_PINK_RAW="${PAL_PINK#\#}"
PAL_TEAL_RAW="${PAL_TEAL#\#}"
PAL_SUBTEXT_RAW="${PAL_SUBTEXT#\#}"

# ---------------------------------------------------------------------------
# Helpers locais de escrita como USUARIO
# ---------------------------------------------------------------------------
#
# O lib-desktop.sh tem write_config_if_absent e write_managed_file, mas os dois
# escrevem como o usuario ATUAL — que aqui e root. Usa-los direto em $HOME
# criaria dotfile com dono root (ver o comentario no topo). Estes wrappers sao a
# versao "como o usuario" deles, com a mesma semantica:
#
#   user_write_if_absent  -> arquivo do USUARIO: nunca sobrescreve (regra 4)
#   user_write_managed    -> arquivo do MODULO: reescreve se o conteudo mudou
#
# A distincao entre os dois e deliberada e importa: config.kdl do niri e do
# usuario (ele vai editar), enquanto o CSS da waybar e gerado a partir da paleta
# e pode ser regerado quando a paleta muda.

# user_file_exists <caminho>: 0 se o arquivo existe, testado COMO O USUARIO.
#
# Nao basta testar com [[ -e ]] como root: se o $HOME estiver num filesystem de
# rede com root_squash, ou com permissoes restritivas, o teste do root pode
# divergir do que o usuario realmente enxerga. O probe tem de refletir a
# realidade de quem vai usar o arquivo.
user_file_exists() {
    run_as_user test -e "$1" 2>/dev/null
}

# user_write_if_absent <arquivo> <conteudo>: escreve como $DESKTOP_USER, e
# SOMENTE se o arquivo ainda nao existir.
#
# NUNCA sobrescreve. Arquivo de config e propriedade do usuario: se ele ja
# customizou, o modulo nao tem o direito de reescrever. A regra 4 proibe operacao
# destrutiva, e apagar a configuracao de alguem e destrutivo mesmo que nenhum
# arquivo seja formalmente "removido".
#
# O conteudo entra por STDIN do `su`, e nao como argumento, de proposito: config
# tem aspas, chaves, cifrao e quebra de linha, e passar isso por linha de comando
# seria um convite a quoting quebrado. `cat > arquivo` le do stdin herdado.
user_write_if_absent() {
    local file="$1" content="$2"

    if user_file_exists "$file"; then
        log_info "'$file' ja existe — preservado como esta (o modulo nunca sobrescreve config do usuario)"
        return 0
    fi

    run_as_user mkdir -p "$(dirname "$file")" \
        || die "nao foi possivel criar o diretorio de '$file' como o usuario '$DESKTOP_USER'."
    printf '%s\n' "$content" | run_as_user tee "$file" > /dev/null \
        || die "falha ao escrever '$file' como o usuario '$DESKTOP_USER'."
    log_info "'$file' criado (dono: $DESKTOP_USER)"
}

# user_write_managed <arquivo> <conteudo>: escreve como $DESKTOP_USER, e so
# reescreve se o conteudo em disco DIFERIR do desejado.
#
# Nao mexer em mtime a toa e proposital: mtime gratuito faz ferramentas de config
# e o proprio usuario julgarem que o arquivo mudou sem motivo, e polui o
# diagnostico de "o que mudou desde o ultimo boot". Idempotente por construcao —
# rodar duas vezes nao muda nada na segunda.
user_write_managed() {
    local file="$1" content="$2" current=""

    if user_file_exists "$file"; then
        current="$(run_as_user cat "$file" 2>/dev/null || true)"
        if [[ "$current" == "$content" ]]; then
            log_info "'$file' ja esta com o conteudo esperado — nada a fazer"
            return 0
        fi
    fi

    run_as_user mkdir -p "$(dirname "$file")" \
        || die "nao foi possivel criar o diretorio de '$file' como o usuario '$DESKTOP_USER'."
    printf '%s\n' "$content" | run_as_user tee "$file" > /dev/null \
        || die "falha ao escrever '$file' como o usuario '$DESKTOP_USER'."
    log_info "'$file' escrito pelo modulo desktop (dono: $DESKTOP_USER)"
}

# ensure_installed <atom>...: garante os pacotes instalados, sem reinstalar.
#
# Tres cuidados que a arquitetura do projeto exige:
#   1. verifica o VDB ANTES (pkg_installed): se tudo ja esta la, nem chama emerge
#   2. valida cada atom com have_atom: regra 3 — nunca chutar nome de pacote.
#      Um atom invisivel morre aqui com mensagem acionavel, em vez de fazer o
#      emerge falhar depois de baixar meio mundo.
#   3. --noreplace: a intencao e "garantir instalado", nao "reinstalar". Sem ele,
#      re-executar o script recompilaria pacote a toa.
ensure_installed() {
    local atom faltando=()
    for atom in "$@"; do
        pkg_installed "$atom" || faltando+=("$atom")
    done

    if (( ${#faltando[@]} == 0 )); then
        log_info "pacotes ja instalados: $*"
        return 0
    fi

    # Regra 3: prova que os atoms existem antes de mandar o emerge tentar.
    require_atoms "${faltando[@]}"

    log_info "instalando: ${faltando[*]}"
    emerge --noreplace "${faltando[@]}" \
        || die "o emerge de '${faltando[*]}' FALHOU. Veja o log completo em $LOGFILE. Como esta e a etapa de APARENCIA, a falha aqui NAO impede a sessao de subir: voce pode reinstalar depois e rodar este script novamente."
}

# ---------------------------------------------------------------------------
# 14-niri-config — o config.kdl do niri
# ---------------------------------------------------------------------------
#
# HONESTIDADE OBRIGATORIA SOBRE O QUE NAO FOI CONFIRMADO:
#
# A pesquisa NAO conseguiu confirmar o schema KDL completo da versao 26.04 do
# GURU, nem se o niri cria um config.kdl sozinho na primeira execucao ou usa um
# default puramente embutido em memoria. O que FOI verificado na doc upstream e
# usado aqui, literalmente:
#
#   spawn-at-startup "waybar"
#   Mod+T hotkey-overlay-title="Open a Terminal: alacritty" { spawn "alacritty"; }
#   Mod+D hotkey-overlay-title="Run an Application: fuzzel" { spawn "fuzzel"; }
#   Mod+Q repeat=false { close-window; }
#   cursor { xcursor-theme "..."; xcursor-size N }
#
# Diante da incerteza, a postura correta nao e escrever um config elaborado e
# torcer: e escrever o MINIMO CONSERVADOR e depois PROVAR que ele e valido.
#
# A PROVA: se o binario do niri oferecer o subcomando `validate` (confirmado na
# doc upstream, incluindo o argumento -c/--config), ele e executado ANTES de o
# arquivo ser aceito. Se a validacao reprovar, o arquivo escrito e REMOVIDO e o
# niri volta a usar o config embutido dele — que sobe. Nunca deixamos um config
# invalido no lugar, porque um config invalido impede a sessao de iniciar, e
# esta etapa (a de estetica) nao pode ser a causa de o desktop nao subir.

# niri_supports_validate: 0 se o binario aceita `niri validate`.
#
# Testado de verdade, e nao presumido pela versao: chamamos `niri validate
# --help` e vemos se ele sai com sucesso. Versao do GURU pode divergir da doc
# upstream, e o custo de checar e um processo de milissegundos.
#
# Roda como usuario porque e assim que o binario sera usado — e porque um
# eventual $XDG_CONFIG_HOME do usuario nao deve vazar do ambiente do root.
niri_supports_validate() {
    command -v niri > /dev/null 2>&1 || return 1
    run_as_user niri validate --help > /dev/null 2>&1
}

# niri_config_valid <arquivo>: 0 se o niri considera o config VALIDO.
#
# Usa -c para validar o arquivo EXATO que acabamos de escrever, sem depender de
# qual caminho o niri escolheria sozinho ($NIRI_CONFIG/XDG_CONFIG_HOME/etc).
niri_config_valid() {
    run_as_user niri validate -c "$1" > /dev/null 2>&1
}

# niri_config_content: monta o texto do config.kdl conforme as escolhas do
# usuario em vars-desktop.sh.
#
# O conteudo e MINIMO de proposito. Cada bloco abaixo existe por um motivo
# funcional concreto, nao por gosto — o niri ja tem defaults sensatos para o
# resto, e quanto menos schema nao-confirmado escrevemos, menor a chance de
# gerar um config que a versao instalada rejeita.
# niri_binds_launcher: os binds de lancador/shell, que dependem de QUEM e o
# shell da sessao.
#
# Com o Clavis, "abrir um aplicativo" nao e mais spawn de um binario: o
# spotlight do Clavis e uma janela do proprio shell, aberta por IPC. O bind
# passa a chamar `key ipc call spotlight toggle` — comando literal extraido do
# AppShell.qml do upstream, nao inventado.
#
# BUG QUE ISTO TAMBEM CORRIGE: o bind era `spawn "$DESKTOP_LAUNCHER"` sem
# guarda. Com DESKTOP_LAUNCHER=none — valor documentado e aceito — o config.kdl
# saia com `spawn "none"`, um bind que tenta executar um binario chamado
# literalmente "none" e falha em silencio a cada Mod+D (o niri manda a saida do
# spawn para /dev/null).
#
# O BIND DE RESGATE. Quando o Clavis e o shell, o fuzzel continua INSTALADO e
# ganha um bind proprio em Mod+Shift+Space. Isso e deliberado e nao e
# redundancia: o spotlight do Clavis depende do shell estar vivo, do venv do
# key-cli, do symlink no PATH e do socket de IPC. O fuzzel nao depende de
# nenhum dos quatro. Se o Clavis nao subir, o Mod+D nao faz nada — e essa e a
# unica rota grafica que sobra alem do terminal.
#
# Por que o fuzzel fica e o mako nao: o mako DISPUTA org.freedesktop.Notifications
# com o servidor de notificacoes do Clavis, e quem ganha depende da ordem de
# arranque. O fuzzel nao e daemon, nao registra nome no D-Bus e nao roda ate
# ser invocado — nao ha o que disputar.
niri_binds_launcher() {
    if [[ "$DESKTOP_CLAVIS" == "yes" ]]; then
        cat <<'KDLCLAVIS'
    // Lancador do Clavis (spotlight). A janela e do proprio shell e e aberta
    // por IPC — nao ha binario de launcher. Se o shell NAO estiver rodando
    // este bind nao faz nada, em silencio. Diagnostico, num terminal:
    //     key ipc call spotlight toggle
    Mod+D hotkey-overlay-title="Abrir um aplicativo (Clavis)" { spawn "key" "ipc" "call" "spotlight" "toggle"; }

    // Historico de area de transferencia e seletor de papel de parede.
    // 'apps', 'wallpapers' e 'clipboard' sao os UNICOS modos que o
    // openMode aceita (LauncherWindow.qml); qualquer outro nao abre nada.
    Mod+V hotkey-overlay-title="Area de transferencia (Clavis)" { spawn "key" "ipc" "call" "spotlight" "openMode" "clipboard"; }
    Mod+Shift+W hotkey-overlay-title="Papeis de parede (Clavis)" { spawn "key" "ipc" "call" "spotlight" "openMode" "wallpapers"; }

    // Busca web: metodo proprio, NAO e um modo de openMode.
    Mod+Shift+D hotkey-overlay-title="Busca web (Clavis)" { spawn "key" "ipc" "call" "spotlight" "web"; }

    // Sidebars: esquerda e o centro de notificacoes (o que substitui o popup
    // do mako), direita sao os quick settings. 'left' e 'right' sao os unicos
    // valores aceitos.
    Mod+N hotkey-overlay-title="Notificacoes (Clavis)" { spawn "key" "ipc" "call" "sidebar" "toggle" "left"; }
    Mod+Shift+N hotkey-overlay-title="Quick settings (Clavis)" { spawn "key" "ipc" "call" "sidebar" "toggle" "right"; }

    // Bloqueio de tela: usa ext-session-lock-v1, o mesmo protocolo do
    // swaylock. Idempotente — repetir devolve ALREADY_LOCKED.
    Super+Alt+L hotkey-overlay-title="Bloquear a tela (Clavis)" { spawn "key" "ipc" "call" "lock" "open"; }
KDLCLAVIS
        # O resgate so existe se o fuzzel for de fato instalado.
        if [[ "$DESKTOP_LAUNCHER" == "fuzzel" ]]; then
            cat <<'KDLRESGATE'

    // RESGATE. Nao compartilha nenhum ponto de falha com o Clavis: sem IPC,
    // sem venv, sem PATH de symlink, sem shell vivo. Se o Mod+D parou de
    // responder, e por aqui que voce abre alguma coisa.
    Mod+Shift+Space hotkey-overlay-title="Lancador de resgate (fuzzel)" { spawn "fuzzel"; }
KDLRESGATE
        fi
        return 0
    fi

    # Caminho sem Clavis, preservado byte a byte — exceto pela guarda de
    # 'none', que antes gerava `spawn "none"`.
    if [[ "$DESKTOP_LAUNCHER" == "none" ]]; then
        printf '%s\n' "    // Nenhum lancador: DESKTOP_LAUNCHER=none. Sem bind de Mod+D."
        return 0
    fi
    cat <<KDLFUZZEL
    // Lancador de aplicativos.
    Mod+D hotkey-overlay-title="Abrir um aplicativo: $DESKTOP_LAUNCHER" { spawn "$DESKTOP_LAUNCHER"; }
KDLFUZZEL
}

niri_config_content() {
    # Binario do terminal conforme a escolha. O bind Mod+T precisa apontar para
    # o que realmente foi instalado pela etapa 12 — apontar para um binario
    # ausente faz o bind falhar EM SILENCIO, e o usuario fica numa sessao onde
    # "o atalho do terminal nao faz nada", que e pessimo de diagnosticar.
    local term_bin
    case "$DESKTOP_TERMINAL" in
        foot)      term_bin="foot" ;;
        alacritty) term_bin="alacritty" ;;
        kitty)     term_bin="kitty" ;;
        *) die "DESKTOP_TERMINAL='$DESKTOP_TERMINAL' invalido — use foot, alacritty ou kitty." ;;
    esac

    cat <<KDL
// config.kdl do niri — gerado pelo modulo desktop (14-dotfiles.sh).
//
// Este arquivo e SEU. O modulo nunca o sobrescreve: se ele existe, a etapa
// 14-niri-config nao faz nada. Edite a vontade e valide com:
//     niri validate -c ~/.config/niri/config.kdl
//
// Config MINIMO de proposito: o niri tem defaults sensatos e cada linha nao
// necessaria e uma chance a mais de incompatibilidade entre versoes.
// Referencia completa: https://github.com/niri-wm/niri/wiki

// Aparencia do cursor.
//
// ATENCAO — VALOR UNICO EM TRES LUGARES: este bloco, o gsettings
// (org.gnome.desktop.interface cursor-theme/cursor-size) e o ambiente da
// sessao PRECISAM concordar. Divergencia entre eles e a causa do sintoma
// classico de cursor que muda de tamanho ou de forma ao cruzar de uma janela
// para outra. O niri define XCURSOR_THEME/XCURSOR_SIZE a partir daqui.
cursor {
    xcursor-theme "$DESKTOP_CURSOR_THEME"
    xcursor-size $DESKTOP_CURSOR_SIZE
}

// Cores do foco. Paleta $DESKTOP_PALETTE aplicada como hex direto — nao ha
// pacote de tema envolvido, o que mantem o modulo inteiro dentro do ::gentoo.
layout {
    focus-ring {
        width 2
        active-color "$PAL_MAUVE"
        inactive-color "$PAL_SURFACE0"
    }

    // Espacamento entre janelas.
    gaps 8
}
KDL

    # Cantos arredondados. Sintaxe VERIFICADA no resources/default-config.kdl
    # do upstream (YaLTeR/niri): a regra vive num window-rule, nao no layout.
    #
    # clip-to-geometry e obrigatorio junto: sem ele o niri arredonda a BORDA mas
    # o conteudo da janela continua quadrado, e o resultado sao quinas do app
    # vazando por cima do canto arredondado.
    if [[ "$DESKTOP_CORNER_RADIUS" -gt 0 ]]; then
        cat <<KDL

// Cantos arredondados em todas as janelas.
window-rule {
    geometry-corner-radius $DESKTOP_CORNER_RADIUS
    clip-to-geometry true
}
KDL
    fi

    # Xwayland: o niri NAO tem Xwayland embutido e NAO integra o satellite
    # sozinho. Instalar o pacote NAO BASTA — sem esta linha de spawn, NENHUM
    # app X11 abre (inclui muitos jogos e Electron antigo). E o tipo de coisa
    # que so aparece semanas depois, quando um app legado falha sem explicacao.
    if [[ "$DESKTOP_ENABLE_XWAYLAND" == "yes" ]]; then
        cat <<'KDL'

// Xwayland via xwayland-satellite. SEM esta linha, nenhum aplicativo X11 abre,
// mesmo com o pacote gui-apps/xwayland-satellite instalado — o niri nao o
// inicia por conta propria.
spawn-at-startup "xwayland-satellite"
KDL
    fi

    # A barra so e declarada se o usuario a escolheu. Declarar spawn de um
    # binario ausente gera erro de spawn no log a CADA boot — ruido puro, que
    # depois confunde quem estiver diagnosticando um problema de verdade.
    if [[ "$DESKTOP_BAR" == "waybar" ]]; then
        cat <<'KDL'

// Barra de status.
spawn-at-startup "waybar"
KDL
    fi

    # Papel de parede. O niri nao desenha fundo: sem isto a area vaga fica
    # PRETA, e numa rice o wallpaper e metade do visual.
    #
    # Com DESKTOP_WALLPAPER vazio ainda declaramos o swaybg, mas so com a cor
    # solida: melhor um fundo na cor da paleta do que preto puro. As aspas
    # simples no heredoc sao importantes — o $ do swaybg nao pode expandir aqui.
    if [[ "$DESKTOP_WALLPAPER_TOOL" == "swaybg" ]]; then
        # A imagem so entra no config se ELA EXISTE agora. O swaybg SAI COM ERRO
        # quando o -i aponta para arquivo ausente — e um spawn-at-startup que
        # morre deixa o fundo preto, que e exatamente o que estamos evitando.
        # A etapa 14-wallpaper roda ANTES desta, entao o download ja aconteceu
        # (ou ja falhou com aviso) quando chegamos aqui.
        local wp
        wp="$(wallpaper_path)"
        if [[ -s "$wp" ]]; then
            cat <<KDL

// Papel de parede (o niri nao desenha fundo sozinho).
spawn-at-startup "swaybg" "-i" "$wp" "-m" "$DESKTOP_WALLPAPER_MODE"
KDL
        else
            cat <<KDL

// Nenhuma imagem em '$wp': cor solida da paleta, para a area vaga nao ficar
// preta. Coloque a imagem la e rode: ./desktop/install-desktop.sh --only 14
spawn-at-startup "swaybg" "-c" "#$DESKTOP_WALLPAPER_COLOR"
KDL
        fi
    fi

    # Notificacoes: idem. So declara o que foi instalado.
    if [[ "$DESKTOP_NOTIFY" == "mako" ]]; then
        cat <<'KDL'

// Daemon de notificacoes.
spawn-at-startup "mako"
KDL
    fi

    # Audio: SO na rota 'launcher'. Ver o bloco ROTA DE ARRANQUE DO PIPEWIRE no
    # topo deste arquivo para o porque de a decisao vir da etapa 13 e de as duas
    # rotas nunca poderem coexistir.
    #
    # Caminho ABSOLUTO de proposito, e nao o nome nu: o spawn-at-startup do niri
    # resolve pelo PATH do processo do compositor, que na sessao de um TTY pode
    # nao incluir o diretorio do wrapper. Um spawn que falha por PATH nao produz
    # erro visivel — apenas audio que nunca sobe, sem nenhuma pista do motivo.
    if [[ "$AUDIO_ROUTE" == "launcher" ]]; then
        cat <<KDL

// PipeWire via wrapper, porque esta maquina tem OpenRC < 0.60 e portanto NAO
// tem servicos de usuario ('rc-update add -U'). A etapa 13 mediu a versao e
// registrou esta rota no marker '13-audio-route'.
//
// NAO acrescente 'rc-update add -U pipewire' junto com esta linha: as duas
// rotas sao mutuamente exclusivas e, declaradas juntas, o PipeWire sobe DUAS
// vezes e as instancias brigam pelos mesmos dispositivos.
spawn-at-startup "$PIPEWIRE_LAUNCHER"
KDL
    fi

    # Binds minimos. A sintaxe (incluindo hotkey-overlay-title e o repeat=false
    # do close-window) foi copiada da forma verificada no config default upstream.
    #
    # Mod+T e Mod+D nao sao luxo: sem terminal e sem lancador acessiveis, o
    # usuario entra numa tela vazia sem NENHUMA forma de abrir algo — e sem
    # saber como sair. Mod+Shift+E (sair) esta aqui pelo mesmo motivo.
    cat <<KDL

binds {
    // Ajuda: mostra todos os atalhos ativos. E a primeira coisa a apertar
    // quando voce esquecer qualquer um dos de baixo.
    Mod+Shift+Slash { show-hotkey-overlay; }

    // Terminal — a ferramenta de RECUPERACAO da sessao.
    Mod+T hotkey-overlay-title="Abrir um terminal: $term_bin" { spawn "$term_bin"; }

$(niri_binds_launcher)

    // Fechar a janela em foco.
    Mod+Q repeat=false { close-window; }

    // Navegacao entre colunas (o niri e scrollable-tiling: as janelas vivem
    // numa fita horizontal que rola).
    Mod+Left  { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up    { focus-window-up; }
    Mod+Down  { focus-window-down; }

    // Mover a coluna em foco.
    Mod+Shift+Left  { move-column-left; }
    Mod+Shift+Right { move-column-right; }

    // Alternar tela cheia / maximizar.
    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }

    // Sair da sessao do niri. NAO e obvio sem isto: quem entra sem saber como
    // sair costuma desligar a maquina no botao.
    Mod+Shift+E { quit; }
}
KDL
}

# audit_audio_route: confere a rota de audio contra o config.kdl REAL e avisa.
#
# Nunca corrige e nunca mata o script — de proposito, por dois motivos:
#   1. o config.kdl pode ser do USUARIO (o modulo so o escreve quando nao existe)
#      e editar arquivo alheio e destrutivo (regra 4);
#   2. audio nao e pre-requisito da sessao grafica. Um aviso preciso, com a linha
#      exata para copiar, resolve sem risco de quebrar o que ja funciona.
#
# Le o arquivo COMO O USUARIO: root pode enxergar um $HOME que o usuario nao le
# (root_squash em NFS, permissao restritiva), e o que importa aqui e o que o
# compositor — que roda como o usuario — vai efetivamente carregar.
# audit_clavis_migration: confere o config.kdl REAL contra a escolha de shell.
#
# Existe pelo mesmo motivo estrutural do audit_audio_route, e fica FORA do
# run_step pelo mesmo motivo: quando o usuario ja tem config.kdl, o probe da
# sub-etapa passa, o do_fn nunca roda, e nada dentro do run_step chegaria a
# olhar para o arquivo. Quem ja instalou antes desta mudanca tem um config.kdl
# com os spawns antigos e NAO o recebe de volta — a regra de nunca sobrescrever
# config do usuario esta funcionando, e o preco dela e este aviso.
#
# Avisa, nunca corrige: o arquivo e do usuario. `log_warn`, jamais `die`.
audit_clavis_migration() {
    [[ "$DESKTOP_CLAVIS" == "yes" ]] || return 0
    user_file_exists "$NIRI_CONFIG" || return 0

    local achou="nao"

    # O pior dos tres, e o unico que nao e cosmetico: dois servidores de
    # notificacao no mesmo bus de sessao. O nome org.freedesktop.Notifications e
    # unico; quem sobe primeiro ganha, e a ordem nao e deterministica entre
    # logins. Se o mako ganha, o Clavis nao acusa erro — o painel dele so fica
    # vazio para sempre.
    if run_as_user grep -qF 'spawn-at-startup "mako"' "$NIRI_CONFIG" 2>/dev/null; then
        log_warn "MIGRACAO: '$NIRI_CONFIG' ainda tem 'spawn-at-startup \"mako\"' e o Clavis esta ativo. Os dois disputam org.freedesktop.Notifications no D-Bus e QUEM GANHA DEPENDE DA ORDEM DE ARRANQUE. Se o mako ganhar, o painel de notificacoes do Clavis fica permanentemente vazio, sem nenhum erro visivel. REMOVA essa linha do arquivo."
        achou="sim"
    fi

    if run_as_user grep -qF 'spawn-at-startup "waybar"' "$NIRI_CONFIG" 2>/dev/null; then
        log_warn "MIGRACAO: '$NIRI_CONFIG' ainda tem 'spawn-at-startup \"waybar\"'. O Clavis desenha a propria barra, entao voce vera DUAS. Cosmetico, mas remova a linha."
        achou="sim"
    fi

    if run_as_user grep -qF 'spawn "fuzzel"' "$NIRI_CONFIG" 2>/dev/null \
       && ! run_as_user grep -qF 'spawn "key" "ipc" "call" "spotlight"' "$NIRI_CONFIG" 2>/dev/null; then
        log_warn "MIGRACAO: o Mod+D de '$NIRI_CONFIG' ainda chama o fuzzel direto, nao o spotlight do Clavis. Nada quebra — o fuzzel continua instalado de proposito — mas voce nao tem o launcher do Clavis. Para trocar, substitua o bind por:"
        log_warn "    Mod+D { spawn \"key\" \"ipc\" \"call\" \"spotlight\" \"toggle\"; }"
        achou="sim"
    fi

    if [[ "$achou" == "sim" ]]; then
        log_warn "Estes avisos aparecem porque o modulo NUNCA reescreve o config.kdl do usuario. Para adotar o arquivo novo por inteiro — DESCARTANDO suas customizacoes — apague '$NIRI_CONFIG' e rode: ./desktop/install-desktop.sh --only 14"
    fi
}

audit_audio_route() {
    # Sem PipeWire instalado nao ha rota nenhuma a auditar, e a 13 registrou isso
    # nao gravando o marker. Silencio e a resposta certa: o usuario que optou por
    # nao ter audio nao precisa de aviso sobre audio.
    pkg_installed media-video/pipewire || return 0

    local tem_linha="nao"
    if user_file_exists "$NIRI_CONFIG" \
        && run_as_user grep -qF 'gentoo-pipewire-launcher' "$NIRI_CONFIG" 2>/dev/null; then
        tem_linha="sim"
    fi

    case "$AUDIO_ROUTE" in
        launcher)
            if [[ "$tem_linha" == "sim" ]]; then
                log_info "rota 'launcher': o config.kdl declara o gentoo-pipewire-launcher — coerente com a decisao da etapa 13"
                return 0
            fi
            # Cenario tipico: o usuario ja tinha um config.kdl proprio, entao o
            # probe passou e este script nao escreveu nada nele. A rota exige a
            # linha, e sem ela o PipeWire simplesmente nao arranca na sessao.
            log_warn "a etapa 13 registrou a rota 'launcher' (OpenRC < 0.60, sem servicos de usuario), mas '$NIRI_CONFIG' NAO declara o gentoo-pipewire-launcher. Como o arquivo ja existia, este script nao o alterou — config.kdl pertence a voce (regra 4). Sem essa linha o PipeWire nao sobe na sessao e o audio fica mudo. Acrescente ao seu config.kdl, no nivel raiz:"
            log_warn "    spawn-at-startup \"$PIPEWIRE_LAUNCHER\""
            log_warn "e valide depois com: niri validate -c $NIRI_CONFIG"
            ;;
        user-services)
            if [[ "$tem_linha" == "nao" ]]; then
                log_info "rota 'user-services': o config.kdl nao declara o launcher — coerente com a decisao da etapa 13"
                return 0
            fi
            # A divergencia PERIGOSA: as duas rotas declaradas ao mesmo tempo.
            #
            # ORIGEM MAIS PROVAVEL, e nao e edicao do usuario: MIGRACAO DE ROTA.
            # A maquina rodou um dia com OpenRC < 0.60, este script gerou um
            # config.kdl COM a linha do launcher, o OpenRC foi atualizado, a 13
            # re-mediu e trocou a rota para 'user-services'. O config.kdl daquela
            # epoca continua la porque este script nao reescreve arquivo que ja
            # existe (write-if-absent, regra 4). Dizer isso na mensagem importa:
            # sem essa frase o usuario procura por uma edicao que ele nunca fez.
            log_warn "CONFLITO DE ROTAS DE AUDIO: a etapa 13 habilitou o PipeWire como servico de USUARIO (rc-update add -U), mas '$NIRI_CONFIG' TAMBEM declara o gentoo-pipewire-launcher. Se voce nao editou esse arquivo, a causa tipica e MIGRACAO DE ROTA: esta maquina rodava com OpenRC < 0.60, o config.kdl foi gerado com o launcher, o OpenRC foi atualizado e a etapa 13 passou a preferir os servicos de usuario — mas o config.kdl nao e reescrito porque ja existe e pertence a voce (regra 4). As duas rotas sao mutuamente exclusivas: juntas, o PipeWire sobe DUAS vezes e as instancias disputam os mesmos dispositivos — audio cortado, dispositivo sumindo do mixer e erro de socket ja em uso. Remova a linha do spawn-at-startup do launcher (a rota de servico de usuario ja cobre o arranque), ou desabilite os servicos com: su - $DESKTOP_USER -c 'rc-update del -U pipewire default'"
            ;;
        *)
            # Marker ausente ou ilegivel COM pipewire instalado: quase sempre e
            # esta etapa rodada standalone, antes da 13. Dizemos exatamente o que
            # falta e como descobrir a rota correta, em vez de adivinhar por ele.
            log_warn "media-video/pipewire esta instalado, mas a rota de arranque dele nao foi registrada pela etapa 13 (marker '13-audio-route' ausente ou invalido). Este script NAO declarou o launcher no config.kdl, porque declara-lo numa maquina de rota 'user-services' faria o PipeWire subir duas vezes. Rode a etapa 13 primeiro — ela mede a versao do OpenRC e decide a rota: ./desktop/install-desktop.sh --only 13"
            ;;
    esac
}

probe_niri_config() {
    # PROBE FUNCIONAL: o arquivo existe, do ponto de vista do USUARIO?
    #
    # Nao consultamos marker: o usuario pode ter apagado o config, e nesse caso
    # queremos reescrever. Marker e cache, probe e autoridade.
    user_file_exists "$NIRI_CONFIG"
}

do_niri_config() {
    local content
    content="$(niri_config_content)"

    # write-if-absent: se chegamos aqui o probe ja garantiu que o arquivo nao
    # existe, mas usamos o helper mesmo assim porque ele e a barreira explicita
    # contra sobrescrever config do usuario (regra 4).
    user_write_if_absent "$NIRI_CONFIG" "$content"

    # ---------------------------------------------------------------------
    # VALIDACAO — a parte que impede esta etapa de quebrar a sessao
    # ---------------------------------------------------------------------
    if ! niri_supports_validate; then
        # Sem `niri validate` nao ha como PROVAR que o config e bom. Nao
        # inventamos confianca: avisamos com clareza e dizemos exatamente como
        # recuperar se a sessao nao subir.
        log_warn "o binario 'niri' nao oferece o subcomando 'validate' (ou nao esta instalado) — NAO foi possivel validar o config.kdl automaticamente."
        log_warn "se a sessao nao subir depois disso, remova '$NIRI_CONFIG' e o niri voltara a usar o config embutido dele, que funciona."
        return 0
    fi

    if niri_config_valid "$NIRI_CONFIG"; then
        log_info "config.kdl validado com 'niri validate' — sintaxe e semantica aceitas pela versao instalada"
        return 0
    fi

    # REPROVOU. O config que ESTE script escreveu e invalido para a versao
    # instalada (schema do KDL diverge do que a doc upstream documenta).
    #
    # Acao correta e conservadora: remover o arquivo. Um config invalido IMPEDE
    # o niri de iniciar; sem arquivo nenhum, o niri usa o default embutido e a
    # sessao SOBE. Entre "bonito e quebrado" e "padrao e funcionando", esta
    # etapa — que e a de estetica — sempre escolhe funcionando.
    log_error "o config.kdl gerado NAO passou em 'niri validate'. Saida do validador:"
    run_as_user niri validate -c "$NIRI_CONFIG" 2>&1 | while IFS= read -r line; do
        log_error "    $line"
    done

    run_as_user rm -f "$NIRI_CONFIG" \
        || die "o config.kdl gerado e invalido E nao foi possivel remove-lo. REMOVA '$NIRI_CONFIG' A MAO antes de reiniciar: um config invalido impede o niri de iniciar."

    log_warn "'$NIRI_CONFIG' foi REMOVIDO — o niri usara o config embutido dele, e a sessao continua podendo subir."
    die "o config.kdl gerado por este modulo nao e compativel com a versao do niri instalada (o schema KDL mudou). O arquivo foi removido, entao NADA foi quebrado: o niri usara o default embutido. Para ter um config proprio, escreva '$NIRI_CONFIG' a mao seguindo a referencia da SUA versao (https://github.com/niri-wm/niri/wiki) e valide com 'niri validate -c'. Depois rode este script de novo — ele preserva o que voce escrever."
}

# ---------------------------------------------------------------------------
# 14-fontconfig — fontes + a config de usuario que so funciona com 50-user.conf
# ---------------------------------------------------------------------------
#
# DUAS COISAS PRECISAM ACONTECER, e a segunda e a que quase todo mundo esquece:
#
#   1. as fontes instaladas (atoms verificados em packages.gentoo.org)
#   2. /etc/fonts/conf.d/50-user.conf HABILITADO
#
# O item 2 e a armadilha silenciosa desta etapa: SEM 50-user.conf habilitado, o
# arquivo ~/.config/fontconfig/fonts.conf e simplesmente IGNORADO — sem erro,
# sem aviso, sem log. Toda a configuracao de fonte parece "nao ter efeito" e nao
# ha nenhuma pista do motivo. O wiki do Gentoo e explicito: so depois que
# 50-user.conf esta habilitado e que a config do usuario passa a ser lida.
#
# ATOMS — todos VERIFICADOS em packages.gentoo.org, nenhum chutado:
#   media-fonts/fira-code          6.2         estavel amd64
#   media-fonts/symbols-nerd-font  3.5.1/3.4.0 estavel amd64
#   media-fonts/noto               20260701    estavel amd64
#   media-fonts/noto-emoji         20250912    estavel amd64
#
# ATENCAO AO NOME: 'media-fonts/nerd-fonts' NAO EXISTE no ::gentoo (HTTP 404
# confirmado) — so em overlays de terceiros. O atom correto para os icones e
# media-fonts/symbols-nerd-font, que e a variante Symbols-Only, usada como
# FALLBACK do fontconfig sobre a fonte mono. E assim que os icones da waybar
# aparecem SEM precisar de uma fonte repatcheada.

FONT_ATOMS=(
    media-fonts/fira-code
    media-fonts/symbols-nerd-font
    media-fonts/noto
    media-fonts/noto-emoji
)

# fontconfig_user_conf_enabled: 0 se o 50-user.conf esta ativo em /etc/fonts/conf.d/.
#
# PROBE FUNCIONAL sobre o sistema real: o eselect fontconfig cria um SYMLINK em
# /etc/fonts/conf.d/ apontando para o arquivo em conf.avail. Testamos o link, que
# e o estado que o fontconfig de fato le, em vez de confiar na saida de texto do
# eselect (que muda de formato entre versoes) ou num marker.
#
# O wiki nota que este arquivo "pode ja vir habilitado" em algumas instalacoes —
# ou seja, o estado default nao e garantido. Mais um motivo para medir em vez de
# supor: se ja estiver ativo, a etapa nao faz nada.
fontconfig_user_conf_enabled() {
    [[ -e /etc/fonts/conf.d/50-user.conf ]]
}

# fonts_installed: 0 se TODAS as fontes do stack estao no VDB.
fonts_installed() {
    local atom
    for atom in "${FONT_ATOMS[@]}"; do
        pkg_installed "$atom" || return 1
    done
    return 0
}

# font_family_available <familia>: 0 se o fontconfig JA ENXERGA a familia.
#
# Este e o probe de PONTA da etapa: nao basta o pacote estar instalado, o
# fontconfig precisa ter indexado a fonte e ser capaz de resolve-la pelo NOME que
# os configs usam ("Fira Code", "Symbols Nerd Font"). Pacote instalado mas cache
# nao atualizado e um estado real, e e exatamente o que produz caixinhas vazias
# na barra.
#
# fc-list com o filtro de familia e a consulta direta a base do fontconfig.
font_family_available() {
    command -v fc-list > /dev/null 2>&1 || return 1
    fc-list : family 2>/dev/null | grep -qiF "$1"
}

# fontconfig_content: o XML de configuracao de fonte do usuario.
#
# Faz duas coisas distintas:
#
#   1. RENDERIZACAO: antialias, hinting e subpixel. NOTA DE HONESTIDADE —
#      hintslight e escolha deliberada, NAO doutrina do Gentoo (o wiki mostra
#      hintfull no exemplo). hintslight preserva melhor o desenho de fontes com
#      ligaduras como a Fira Code, que e justamente a mono deste stack.
#      O bloco de subpixel RGB assume painel LCD com layout RGB horizontal, que
#      e o caso comum em desktop; em painel BGR/vertical isso produz franjas
#      coloridas e voce deve trocar 'rgb' pelo layout correto.
#
#   2. FALLBACK: encadeia mono -> Symbols Nerd Font -> Noto Color Emoji. E esta
#      cadeia que faz os icones da waybar aparecerem sem fonte repatcheada: o
#      fontconfig cai no Symbols Nerd Font para os glifos que a Fira Code nao
#      tem. O nome da familia e EXATAMENTE 'Symbols Nerd Font'.
fontconfig_content() {
    cat <<XML
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!--
  Gerado pelo modulo desktop (14-dotfiles.sh) do gentoo-install.

  ATENCAO: este arquivo so e lido se /etc/fonts/conf.d/50-user.conf estiver
  habilitado. O modulo habilita com 'eselect fontconfig enable 50-user.conf'.
  Sem isso, tudo aqui e IGNORADO EM SILENCIO.

  Mudancas aqui NAO afetam aplicativos que ja estao rodando — reinicie o app
  (ou a sessao) para ver o efeito.
-->
<fontconfig>

  <!-- Renderizacao. hintslight preserva o desenho de fontes com ligaduras
       (Fira Code) melhor que hintfull. -->
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
  </match>

  <!-- Monoespacada: a fonte do terminal e da barra.
       A cadeia de fallback e o que faz os icones aparecerem: glifo que a
       '$DESKTOP_FONT_MONO' nao tem e buscado na 'Symbols Nerd Font'. -->
  <alias>
    <family>monospace</family>
    <prefer>
      <family>$DESKTOP_FONT_MONO</family>
      <family>Symbols Nerd Font</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>

  <!-- Interface. -->
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>$DESKTOP_FONT_UI</family>
      <family>Symbols Nerd Font</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>

  <alias>
    <family>serif</family>
    <prefer>
      <family>Noto Serif</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
</fontconfig>
XML
}

probe_fontconfig() {
    # PROBE FUNCIONAL, em tres partes — todas precisam ser verdade:
    #   1. os pacotes de fonte estao instalados
    #   2. o 50-user.conf esta habilitado (senao o item 3 seria inutil)
    #   3. o arquivo de config do usuario existe
    #
    # A ordem importa no diagnostico: se so o item 2 falha, a config existe mas
    # nao e lida — que e exatamente a falha silenciosa que esta etapa evita.
    fonts_installed || return 1
    fontconfig_user_conf_enabled || return 1
    user_file_exists "$FONTCONFIG_FILE" || return 1
    return 0
}

do_fontconfig() {
    # 1. Fontes. ensure_installed valida os atoms antes (regra 3) e usa
    #    --noreplace: re-executar nao recompila nada.
    ensure_installed "${FONT_ATOMS[@]}"

    # 2. O passo critico e silencioso.
    if fontconfig_user_conf_enabled; then
        log_info "50-user.conf ja esta habilitado em /etc/fonts/conf.d/"
    else
        command -v eselect > /dev/null 2>&1 \
            || die "o comando 'eselect' nao existe neste sistema, entao nao da para habilitar o 50-user.conf. Sem ele, '$FONTCONFIG_FILE' e IGNORADO em silencio pelo fontconfig. Instale app-admin/eselect e rode este script de novo."

        log_info "habilitando 50-user.conf (sem ele a config de fonte do usuario e ignorada em silencio)"
        eselect fontconfig enable 50-user.conf \
            || die "'eselect fontconfig enable 50-user.conf' FALHOU. Sem esse arquivo habilitado, o fontconfig IGNORA '$FONTCONFIG_FILE' sem emitir erro nenhum — os icones da barra apareceriam como caixas vazias e nada indicaria o motivo. Verifique a saida de 'eselect fontconfig list'."
    fi

    # 3. A config do usuario. write-managed (e nao if-absent) porque este arquivo
    #    e derivado das variaveis de fonte do modulo: se DESKTOP_FONT_MONO mudar,
    #    o arquivo deve acompanhar. Ainda assim so reescreve se o conteudo
    #    diferir, entao rodar duas vezes nao mexe no mtime.
    user_write_managed "$FONTCONFIG_FILE" "$(fontconfig_content)"

    # 4. Atualiza o cache do fontconfig como o USUARIO. Sem isso, a fonte recem
    #    instalada pode nao ser resolvida pelo nome ate o proximo login.
    #    Nao e fatal se falhar: o cache se reconstroi sozinho quando necessario.
    if command -v fc-cache > /dev/null 2>&1; then
        run_as_user fc-cache -f > /dev/null 2>&1 \
            || log_warn "fc-cache falhou; o cache sera reconstruido automaticamente no proximo login"
    fi

    # 5. Verificacao de ponta, NAO fatal.
    #
    # Por que so avisa em vez de morrer: o nome exato da familia instalada pelo
    # symbols-nerd-font nao foi confirmado na pesquisa (pode haver tambem a
    # variante 'Symbols Nerd Font Mono'). Como esta e a etapa de estetica e o
    # sintoma de falha e cosmetico (icone vira caixinha), o certo e informar com
    # precisao e seguir — nao derrubar a etapa inteira por causa de um glifo.
    if ! font_family_available "Symbols Nerd Font"; then
        log_warn "o fontconfig ainda nao resolve a familia 'Symbols Nerd Font'. Os icones da barra podem aparecer como caixas vazias."
        log_warn "confira o nome REAL da familia instalada com: fc-list | grep -i 'symbols nerd'"
        log_warn "se o nome divergir, ajuste o <family> em '$FONTCONFIG_FILE'."
    else
        log_info "fontconfig resolve 'Symbols Nerd Font' — os icones da barra devem renderizar"
    fi
}

# ---------------------------------------------------------------------------
# 14-gtk-theme — tema escuro, icones e cursor
# ---------------------------------------------------------------------------
#
# EM WAYLAND A AUTORIDADE E O gsettings, NAO o settings.ini.
#
# Isto inverte o habito de quem vem do X11 e e a causa de muita confusao: em
# Wayland o GTK le gtk-theme, icon-theme, cursor-theme e font-name do schema
# org.gnome.desktop.interface. O ~/.config/gtk-3.0/settings.ini so era a
# autoridade no X11, via XSETTINGS.
#
# EXCECAO QUE OBRIGA A ESCREVER OS DOIS: gtk-application-prefer-dark-theme
# CONTINUA sendo lido do settings.ini. Por isso o script escreve gsettings E
# settings.ini com valores IDENTICOS — nao e redundancia por preguica, e cinto e
# suspensorio com motivo tecnico. Os dois metodos nao conflitam quando concordam;
# divergir e que causa comportamento erratico.
#
# LIMITE CONHECIDO E NAO CONTORNAVEL AQUI: apps GTK4/libadwaita IGNORAM tema GTK.
# Eles respeitam apenas color-scheme='prefer-dark'. Instalar um tema e esperar
# que o Nautilus moderno mude de cara nao funciona — para ele so vale o
# color-scheme (propagado pelo portal). O tema atua nos apps GTK3.
#
# DEPENDENCIAS QUE NAO SAO OPCIONAIS:
#   gnome-base/gsettings-desktop-schemas -> sem ele: "No such schema
#     org.gnome.desktop.interface" e NADA aplica.
#   gnome-base/dconf -> sem ele o gsettings usa backend em memoria e os valores
#     se PERDEM ao reiniciar a sessao. O sintoma e "configurei e voltou tudo".
# Nenhum dos dois vem por padrao num perfil 23.0 sem /desktop.

THEME_ATOMS=(
    gnome-base/gsettings-desktop-schemas
    gnome-base/dconf
    x11-themes/adwaita-icon-theme
    x11-themes/papirus-icon-theme
)

# Valores aplicados. Definidos UMA vez e reusados nos dois lugares (gsettings e
# settings.ini) — e essa unica origem que garante que os dois nao divirjam.
GTK_ICON_THEME="Papirus-Dark"
GTK_FONT_NAME="$DESKTOP_FONT_UI 11"
GTK_MONO_FONT_NAME="$DESKTOP_FONT_MONO 11"

# gsettings_get <schema> <chave>: le um valor, como o USUARIO.
#
# NOTA SOBRE D-BUS: rodando de um TTY via `su`, normalmente NAO ha barramento de
# sessao. O backend dconf funciona mesmo assim para leitura/escrita direta no
# banco do usuario (~/.config/dconf/user) — o que muda e que aplicativos ja
# rodando nao recebem a notificacao de mudanca. Como esta etapa roda ANTES de a
# sessao grafica existir, isso e exatamente o que queremos: gravar o valor para
# que a sessao futura o leia.
# dbus-run-session e OBRIGATORIO, nao decorativo. Estas helpers rodam a partir
# de um shell de root que NAO tem barramento de sessao. Sem D-Bus o dconf cai
# num backend EM MEMORIA: o `gsettings set` sai com 0 e o valor evapora ao fim
# do processo. O sintoma era a propria checagem abaixo acusando
#     o valor de 'color-scheme' foi gravado mas a releitura devolveu 'default'
# — ou seja, o gsettings_set_checked funcionou como projetado e revelou o
# problema; o que faltava era a sessao. Observado no bare metal em 2026-09-02.
#
# O `tail -1` existe por causa da correcao acima: o dbus-daemon que o
# dbus-run-session sobe escreve linhas proprias, e sem o filtro a captura vinha
# contaminada — a comparacao falhava com ''prefer-dark'' != 'prefer-dark'
# (aspas duplicadas), que parece bug de formato e nao e.
gsettings_get() {
    run_as_user dbus-run-session gsettings get "$1" "$2" 2>/dev/null | tail -1
}

# gsettings_set_checked <schema> <chave> <valor>: grava e CONFERE.
#
# Escrever sem conferir seria fragil justamente pelo caso do dconf ausente: o
# comando "funciona" (sai com 0) mas o valor nao persiste. Lendo de volta,
# transformamos uma falha silenciosa em erro visivel.
gsettings_set_checked() {
    local schema="$1" key="$2" value="$3" got

    # dbus-run-session: ver o comentario de gsettings_get. Sem barramento de
    # sessao o dconf usa backend em memoria e esta gravacao nao persiste.
    run_as_user dbus-run-session gsettings set "$schema" "$key" "$value" \
        || die "falha ao gravar '$key' em '$schema' via gsettings. Causa mais provavel: gnome-base/gsettings-desktop-schemas nao esta instalado (o erro tipico e 'No such schema'). Confira com: gsettings list-schemas | grep org.gnome.desktop.interface"

    got="$(gsettings_get "$schema" "$key")" || got=""
    # O gsettings devolve strings entre aspas simples ('Adwaita'); comparamos sem
    # elas para nao depender do formato de saida.
    got="${got#\'}"; got="${got%\'}"
    if [[ "$got" != "$value" ]]; then
        die "o valor de '$key' foi gravado mas a releitura devolveu '$got' em vez de '$value'. Isso indica que o backend do dconf nao esta persistindo — verifique se gnome-base/dconf esta instalado. Sem ele, o gsettings usa um backend em memoria e as configuracoes se perdem ao reiniciar a sessao."
    fi
}

# gtk_settings_ini_content: o settings.ini, com os MESMOS valores do gsettings.
gtk_settings_ini_content() {
    cat <<INI
# Gerado pelo modulo desktop (14-dotfiles.sh) do gentoo-install.
#
# EM WAYLAND ESTE ARQUIVO NAO E A AUTORIDADE: o GTK le tema, icones, cursor e
# fonte do gsettings (org.gnome.desktop.interface). Ele existe por DUAS razoes:
#   1. gtk-application-prefer-dark-theme AINDA e lido daqui, mesmo em Wayland;
#   2. cobre aplicativos iniciados sem dbus/gsettings disponivel.
#
# Os valores DEVEM ser identicos aos do gsettings. Se voce mudar um, mude o
# outro — divergencia produz comportamento inconsistente entre aplicativos.
[Settings]
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=$GTK_ICON_THEME
gtk-cursor-theme-name=$DESKTOP_CURSOR_THEME
gtk-cursor-theme-size=$DESKTOP_CURSOR_SIZE
gtk-font-name=$GTK_FONT_NAME
INI
}

probe_gtk_theme() {
    # PROBE FUNCIONAL: consulta o estado REAL do dconf do usuario, nao um marker.
    #
    # color-scheme e a chave decisiva — e a unica que apps GTK4/libadwaita
    # respeitam, entao e ela que define se o "modo escuro" existe de fato.
    local scheme cursor

    pkg_installed gnome-base/gsettings-desktop-schemas || return 1
    pkg_installed gnome-base/dconf || return 1

    scheme="$(gsettings_get org.gnome.desktop.interface color-scheme)" || return 1
    [[ "$scheme" == "'prefer-dark'" ]] || return 1

    # O cursor precisa bater com o que o config.kdl do niri declara: valores
    # divergentes produzem cursor que muda de tamanho ao cruzar janelas.
    cursor="$(gsettings_get org.gnome.desktop.interface cursor-theme)" || return 1
    [[ "$cursor" == "'$DESKTOP_CURSOR_THEME'" ]] || return 1

    user_file_exists "$USER_HOME/.config/gtk-3.0/settings.ini" || return 1
    user_file_exists "$USER_HOME/.config/gtk-4.0/settings.ini" || return 1
    return 0
}

do_gtk_theme() {
    ensure_installed "${THEME_ATOMS[@]}"

    # O nome do diretorio do tema de icones NAO foi confirmado na pesquisa (o
    # src_install do ebuild nao pode ser lido). Em vez de gravar um valor que
    # pode nao existir e deixar os icones quebrados sem explicacao, medimos o
    # disco e avisamos. Nao e fatal: icone ausente e cosmetico, e o GTK cai no
    # tema default (Adwaita) sozinho.
    if [[ ! -d "/usr/share/icons/$GTK_ICON_THEME" ]]; then
        log_warn "o tema de icones '$GTK_ICON_THEME' nao foi encontrado em /usr/share/icons/."
        log_warn "confira o nome real com: ls /usr/share/icons/ | grep -i papirus"
        log_warn "os icones cairao no tema default ate o nome ser ajustado."
    fi

    # --- gsettings: a autoridade em Wayland ---
    #
    # color-scheme e a chave mais importante do bloco: e a unica que apps
    # GTK4/libadwaita respeitam.
    gsettings_set_checked org.gnome.desktop.interface color-scheme          'prefer-dark'
    gsettings_set_checked org.gnome.desktop.interface icon-theme            "$GTK_ICON_THEME"
    gsettings_set_checked org.gnome.desktop.interface cursor-theme          "$DESKTOP_CURSOR_THEME"
    gsettings_set_checked org.gnome.desktop.interface cursor-size           "$DESKTOP_CURSOR_SIZE"
    gsettings_set_checked org.gnome.desktop.interface font-name             "$GTK_FONT_NAME"
    gsettings_set_checked org.gnome.desktop.interface monospace-font-name   "$GTK_MONO_FONT_NAME"

    # --- settings.ini: GTK3 e GTK4, valores IDENTICOS aos de cima ---
    local ini
    ini="$(gtk_settings_ini_content)"
    user_write_managed "$USER_HOME/.config/gtk-3.0/settings.ini" "$ini"
    user_write_managed "$USER_HOME/.config/gtk-4.0/settings.ini" "$ini"

    # --- Qt6, se o qt6ct estiver instalado ---
    #
    # NAO instalamos gui-apps/qt6ct: neste stack quase nada e Qt (niri, waybar,
    # fuzzel e foot sao Wayland/GTK-free), e puxar Qt so para casar tema seria
    # peso sem retorno. Mas se o usuario ja o tem, escrevemos a config para os
    # apps Qt nao destoarem do resto.
    #
    # ATENCAO A CATEGORIA: e gui-apps/qt6ct — 'x11-misc/qt6ct' NAO existe (404).
    # E qt5ct nao existe mais no ::gentoo, entao nao ha regra para ele aqui.
    if pkg_installed gui-apps/qt6ct; then
        log_info "gui-apps/qt6ct detectado — escrevendo a config de tema do Qt6"
        user_write_managed "$USER_HOME/.config/qt6ct/qt6ct.conf" "$(cat <<QTCONF
# Gerado pelo modulo desktop (14-dotfiles.sh) do gentoo-install.
# Ativa-se exportando QT_QPA_PLATFORMTHEME=qt6ct no ambiente da sessao.
[Appearance]
icon_theme=$GTK_ICON_THEME
[Fonts]
general="$DESKTOP_FONT_UI,11,-1,5,50,0,0,0,0,0"
fixed="$DESKTOP_FONT_MONO,11,-1,5,50,0,0,0,0,0"
QTCONF
)"
    fi

    log_info "tema aplicado: color-scheme=prefer-dark, icones=$GTK_ICON_THEME, cursor=$DESKTOP_CURSOR_THEME/$DESKTOP_CURSOR_SIZE"
    log_info "lembrete: apps GTK4/libadwaita ignoram tema GTK e seguem apenas o color-scheme"
}

# ---------------------------------------------------------------------------
# 14-bar-config — waybar (JSON de modulos + CSS com a paleta)
# ---------------------------------------------------------------------------
#
# A waybar precisa de DOIS arquivos e falta de qualquer um degrada o resultado:
#   ~/.config/waybar/config  -> quais modulos aparecem (JSON)
#   ~/.config/waybar/style.css -> como eles se parecem (CSS)
#
# O modulo "niri/workspaces" so funciona se o pacote foi construido com USE=niri
# (garantida na etapa 10). Sem essa flag a barra sobe, mas sem workspace nenhum —
# uma falha que parece de configuracao e nao e.
#
# Se DESKTOP_BAR=none, a etapa inteira e pulada de forma limpa: nao escrevemos
# config de um programa que nao esta instalado.

WAYBAR_DIR="$USER_HOME/.config/waybar"

# waybar_has_niri_module: 0 se o binario foi construido com USE=niri.
#
# Le o VDB (o que foi REALMENTE construido), e nao o package.use (o que foi
# PEDIDO). A distincao importa: escrever o flag nao reconstroi o pacote.
waybar_has_niri_module() {
    local d
    for d in /var/db/pkg/gui-apps/waybar-[0-9]*; do
        [[ -d "$d" && -f "$d/USE" ]] || continue
        grep -qw niri "$d/USE" && return 0
        return 1
    done
    return 1
}

waybar_config_content() {
    cat <<JSON
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "spacing": 4,

    "//": "Layout enxuto, no espirito da rice de referencia: workspaces em",
    "//": "pilulas a esquerda, relogio ao centro, e so o essencial a direita.",
    "//": "cpu/memory/network foram deixados de fora de proposito — sao ruido",
    "//": "visual permanente para informacao que voce consulta sob demanda.",
    "//": "Para traze-los de volta, some ao modules-right abaixo.",
    "modules-left": ["niri/workspaces"],
    "modules-center": ["clock"],
    "modules-right": ["pulseaudio", "tray"],

    "niri/workspaces": {
        "format": "{value}"
    },

    "niri/window": {
        "format": "{}",
        "max-length": 60
    },

    "clock": {
        "format": "{:%H:%M}",
        "format-alt": "{:%Y-%m-%d %H:%M}",
        "tooltip-format": "<tt>{calendar}</tt>"
    },

    "cpu": {
        "format": "CPU {usage}%",
        "interval": 5
    },

    "memory": {
        "format": "RAM {percentage}%",
        "interval": 5
    },

    "network": {
        "format-wifi": "{essid} ({signalStrength}%)",
        "format-ethernet": "eth",
        "format-disconnected": "sem rede",
        "tooltip-format": "{ifname}: {ipaddr}"
    },

    "pulseaudio": {
        "format": "vol {volume}%",
        "format-muted": "mudo",
        "on-click": "pavucontrol"
    },

    "tray": {
        "spacing": 8
    }
}
JSON
}

# CSS com a paleta aplicada como hex direto — sem pacote de tema.
waybar_style_content() {
    cat <<CSS
/*
 * Gerado pelo modulo desktop (14-dotfiles.sh) do gentoo-install.
 * Paleta: $DESKTOP_PALETTE (hex direto, sem pacote de tema).
 */

* {
    font-family: "$DESKTOP_FONT_MONO", "Symbols Nerd Font", monospace;
    font-size: 13px;
    border: none;
    border-radius: 0;
    min-height: 0;
}

window#waybar {
    background-color: $PAL_BASE;
    color: $PAL_TEXT;
}

#workspaces button {
    padding: 0 8px;
    color: $PAL_SUBTEXT;
    background-color: transparent;
}

#workspaces button.focused,
#workspaces button.active {
    color: $PAL_BASE;
    background-color: $PAL_MAUVE;
}

#workspaces button.urgent {
    color: $PAL_BASE;
    background-color: $PAL_RED;
}

#window {
    padding: 0 10px;
    color: $PAL_SUBTEXT;
}

#clock {
    padding: 0 10px;
    color: $PAL_MAUVE;
    font-weight: bold;
}

#cpu,
#memory,
#network,
#pulseaudio,
#tray {
    padding: 0 10px;
    background-color: $PAL_SURFACE0;
    color: $PAL_TEXT;
    margin: 4px 2px;
}

#pulseaudio.muted {
    color: $PAL_RED;
}

#network.disconnected {
    color: $PAL_RED;
}
CSS
}

probe_bar_config() {
    # DESKTOP_BAR=none: nada a fazer, e a etapa esta legitimamente "feita".
    # Retornar 0 aqui e o que faz o run_step pular sem executar nem falhar.
    [[ "$DESKTOP_BAR" == "waybar" ]] || return 0

    user_file_exists "$WAYBAR_DIR/config" || return 1
    user_file_exists "$WAYBAR_DIR/style.css" || return 1
    return 0
}

do_bar_config() {
    if [[ "$DESKTOP_BAR" != "waybar" ]]; then
        log_info "DESKTOP_BAR='$DESKTOP_BAR' — nenhuma barra configurada"
        return 0
    fi

    # Avisa sobre a USE=niri ausente. Nao e fatal: a barra funciona, so nao
    # mostra workspaces. Morrer aqui seria desproporcional numa etapa de
    # estetica — mas ficar calado deixaria o usuario procurando erro no JSON.
    if pkg_installed gui-apps/waybar && ! waybar_has_niri_module; then
        log_warn "gui-apps/waybar foi construido SEM USE=niri: a barra vai subir, mas os modulos 'niri/workspaces' e 'niri/window' ficarao vazios."
        log_warn "corrija com: echo 'gui-apps/waybar niri' >> /etc/portage/package.use/desktop-niri && emerge --changed-use gui-apps/waybar"
    fi

    # if-absent: config de barra e do usuario — se ele ja ajustou os modulos,
    # nao sobrescrevemos (regra 4).
    user_write_if_absent "$WAYBAR_DIR/config" "$(waybar_config_content)"
    user_write_if_absent "$WAYBAR_DIR/style.css" "$(waybar_style_content)"
}

# ---------------------------------------------------------------------------
# 14-terminal-config — o terminal escolhido, com a mesma paleta e fonte
# ---------------------------------------------------------------------------
#
# Cada terminal tem formato PROPRIO de config, e escrever o formato errado nao
# da erro — o programa so ignora o arquivo. Por isso ha um gerador por terminal,
# e nao um template generico:
#   foot      -> INI  (~/.config/foot/foot.ini)      — hex SEM '#'
#   alacritty -> TOML (~/.config/alacritty/alacritty.toml) — hex COM '#'
#   kitty     -> conf (~/.config/kitty/kitty.conf)   — hex COM '#'

# terminal_config_path: caminho do arquivo de config do terminal escolhido.
terminal_config_path() {
    case "$DESKTOP_TERMINAL" in
        foot)      printf '%s\n' "$USER_HOME/.config/foot/foot.ini" ;;
        alacritty) printf '%s\n' "$USER_HOME/.config/alacritty/alacritty.toml" ;;
        kitty)     printf '%s\n' "$USER_HOME/.config/kitty/kitty.conf" ;;
        *) die "DESKTOP_TERMINAL='$DESKTOP_TERMINAL' invalido — use foot, alacritty ou kitty." ;;
    esac
}

# O foot usa INI e cores SEM o '#'. Escrever com '#' faz o foot ignorar a cor.
terminal_config_foot() {
    cat <<INI
# Gerado pelo modulo desktop (14-dotfiles.sh) do gentoo-install.
# Paleta: $DESKTOP_PALETTE. ATENCAO: o foot espera hex SEM o '#'.
font=$DESKTOP_FONT_MONO:size=11
dpi-aware=yes

[cursor]
style=beam

[colors]
alpha=1.0
background=$PAL_BASE_RAW
foreground=$PAL_TEXT_RAW

regular0=$PAL_SURFACE0_RAW
regular1=$PAL_RED_RAW
regular2=$PAL_GREEN_RAW
regular3=$PAL_YELLOW_RAW
regular4=$PAL_BLUE_RAW
regular5=$PAL_PINK_RAW
regular6=$PAL_TEAL_RAW
regular7=$PAL_TEXT_RAW

bright0=$PAL_SUBTEXT_RAW
bright1=$PAL_RED_RAW
bright2=$PAL_GREEN_RAW
bright3=$PAL_YELLOW_RAW
bright4=$PAL_BLUE_RAW
bright5=$PAL_PINK_RAW
bright6=$PAL_TEAL_RAW
bright7=$PAL_TEXT_RAW
INI
}

# O alacritty usa TOML e cores COM o '#', entre aspas.
terminal_config_alacritty() {
    cat <<TOML
# Gerado pelo modulo desktop (14-dotfiles.sh) do gentoo-install.
# Paleta: $DESKTOP_PALETTE.

[font]
size = 11.0

[font.normal]
family = "$DESKTOP_FONT_MONO"

[colors.primary]
background = "$PAL_BASE"
foreground = "$PAL_TEXT"

[colors.normal]
black   = "$PAL_SURFACE0"
red     = "$PAL_RED"
green   = "$PAL_GREEN"
yellow  = "$PAL_YELLOW"
blue    = "$PAL_BLUE"
magenta = "$PAL_PINK"
cyan    = "$PAL_TEAL"
white   = "$PAL_TEXT"

[colors.bright]
black   = "$PAL_SUBTEXT"
red     = "$PAL_RED"
green   = "$PAL_GREEN"
yellow  = "$PAL_YELLOW"
blue    = "$PAL_BLUE"
magenta = "$PAL_PINK"
cyan    = "$PAL_TEAL"
white   = "$PAL_TEXT"
TOML
}

# O kitty usa formato proprio "chave valor" e cores COM o '#'.
terminal_config_kitty() {
    cat <<CONF
# Gerado pelo modulo desktop (14-dotfiles.sh) do gentoo-install.
# Paleta: $DESKTOP_PALETTE.
font_family      $DESKTOP_FONT_MONO
font_size        11.0

background       $PAL_BASE
foreground       $PAL_TEXT
cursor           $PAL_MAUVE

color0  $PAL_SURFACE0
color1  $PAL_RED
color2  $PAL_GREEN
color3  $PAL_YELLOW
color4  $PAL_BLUE
color5  $PAL_PINK
color6  $PAL_TEAL
color7  $PAL_TEXT

color8  $PAL_SUBTEXT
color9  $PAL_RED
color10 $PAL_GREEN
color11 $PAL_YELLOW
color12 $PAL_BLUE
color13 $PAL_PINK
color14 $PAL_TEAL
color15 $PAL_TEXT
CONF
}

probe_terminal_config() {
    user_file_exists "$(terminal_config_path)"
}

do_terminal_config() {
    local content
    case "$DESKTOP_TERMINAL" in
        foot)      content="$(terminal_config_foot)" ;;
        alacritty) content="$(terminal_config_alacritty)" ;;
        kitty)     content="$(terminal_config_kitty)" ;;
        *) die "DESKTOP_TERMINAL='$DESKTOP_TERMINAL' invalido — use foot, alacritty ou kitty." ;;
    esac

    # if-absent: o terminal e a ferramenta de trabalho do usuario e a config dele
    # costuma ser a primeira que ele personaliza. Nunca sobrescrevemos.
    user_write_if_absent "$(terminal_config_path)" "$content"
}

# ---------------------------------------------------------------------------
# Execucao
# ---------------------------------------------------------------------------
#
# Ordem deliberada: o config.kdl vem primeiro porque e o unico arquivo desta
# etapa que pode IMPEDIR a sessao de subir (e por isso e o unico validado). O
# resto e cosmetico e nao tem poder de quebrar o compositor.
#
# O fontconfig vem antes do tema porque o tema referencia nomes de fonte que so
# resolvem depois que as fontes existem e o cache foi atualizado.

log_info "etapa 14: configuracao do usuario '$DESKTOP_USER' (HOME: $USER_HOME)"
log_info "paleta: $DESKTOP_PALETTE | terminal: $DESKTOP_TERMINAL | barra: $DESKTOP_BAR | cursor: $DESKTOP_CURSOR_THEME/$DESKTOP_CURSOR_SIZE"

# Sob --dry-run paramos AQUI. Tudo acima e leitura e montagem de strings: o
# $HOME real vindo do getent, a rota de audio herdada da 13 e o conteudo dos
# dotfiles em variaveis. Nenhum byte foi para o disco ainda — a primeira escrita
# e o user_write_if_absent do do_niri_config logo abaixo.
# ---------------------------------------------------------------------------
# 14-shell — zsh como shell do usuario, com fastfetch no login
# ---------------------------------------------------------------------------
#
# O shell do ROOT nunca e tocado. Trocar o shell do root e como se perde acesso
# a um sistema quando o shell novo nao sobe.

probe_shell() {
    [[ "$DESKTOP_SHELL" == "zsh" ]] || return 0
    local sh
    sh="$(getent passwd "$DESKTOP_USER" | cut -d: -f7)"
    [[ "$sh" == */zsh ]] || return 1
    [[ -f "$(user_home)/.zshrc" ]] || return 1
    return 0
}

do_shell() {
    [[ "$DESKTOP_SHELL" == "zsh" ]] || { log_info "DESKTOP_SHELL=$DESKTOP_SHELL — shell do usuario nao sera alterado"; return 0; }

    local zsh_bin
    zsh_bin="$(command -v zsh)" \
        || die "zsh nao esta no PATH. A etapa 10 deveria te-lo instalado (app-shells/zsh) — rode ./desktop/install-desktop.sh --only 10 antes desta."

    # /etc/shells precisa listar o shell, senao chsh recusa e alguns servicos
    # (incluindo login via PAM) tratam a conta como sem shell valido.
    if ! grep -qxF "$zsh_bin" /etc/shells 2>/dev/null; then
        printf '%s\n' "$zsh_bin" >> /etc/shells
        log_info "'$zsh_bin' adicionado a /etc/shells"
    fi

    local atual
    atual="$(getent passwd "$DESKTOP_USER" | cut -d: -f7)"
    if [[ "$atual" != "$zsh_bin" ]]; then
        chsh -s "$zsh_bin" "$DESKTOP_USER" \
            || die "chsh falhou ao trocar o shell de '$DESKTOP_USER' para '$zsh_bin'."
        log_info "shell de '$DESKTOP_USER' alterado de '${atual:-nenhum}' para '$zsh_bin'"
    fi

    # .zshrc: config MINIMA e sem framework. A rice de referencia nao declara
    # oh-my-zsh/prezto e nao vamos inventar dependencia que o autor nao citou.
    # write_config_if_absent: se o usuario ja tem .zshrc, ele e dele.
    local ff=""
    [[ "$DESKTOP_FASTFETCH_ON_LOGIN" == "yes" && "$DESKTOP_INSTALL_FASTFETCH" == "yes" ]] && ff="
# Fetch ao abrir shell interativo (e a tela da rice de referencia).
# O teste de TTY evita rodar em shell nao-interativo (scp, rsync, cron), onde
# saida inesperada QUEBRA o protocolo do outro lado.
if [[ -o interactive ]] && command -v fastfetch > /dev/null; then
    fastfetch
fi"

    user_write_if_absent "$(user_home)/.zshrc" "# Config minima de zsh — sem framework, de proposito.

# Historico: compartilhado entre sessoes, sem duplicatas.
HISTFILE=\"\$HOME/.zsh_history\"
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE

# Completion. compinit e caro: o cache em .zcompdump e o que mantem o shell
# abrindo rapido. gentoo-zsh-completions traz emerge/eselect/rc-service.
autoload -Uz compinit && compinit -d \"\$HOME/.zcompdump\"
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# Navegacao
setopt AUTO_CD

# Prompt: usuario@host + diretorio + '%' — sem dependencia externa.
PROMPT='%F{magenta}%n%f@%F{blue}%m%f %F{cyan}%~%f %# '

alias ls='ls --color=auto'
alias grep='grep --color=auto'
$ff"
}

# ---------------------------------------------------------------------------
# 14-wallpaper — baixa a imagem, se preciso, e aponta o config
# ---------------------------------------------------------------------------
#
# ARMADILHA do Pixiv: i.pximg.net RECUSA hotlink e devolve 403 sem o cabecalho
# Referer apontando para pixiv.net. Um wget/curl direto NAO funciona.
#
# DIREITO AUTORAL: a imagem e do artista. Baixar para uso proprio e uma coisa;
# este repositorio nunca vai conte-la. Por isso o download acontece na SUA
# maquina, sob seu criterio, e nao ha imagem versionada aqui.

wallpaper_path() {
    if [[ -n "$DESKTOP_WALLPAPER" ]]; then
        printf '%s\n' "$DESKTOP_WALLPAPER"
    else
        printf '%s/.local/share/wallpapers/%s\n' "$(user_home)" "$DESKTOP_WALLPAPER_NAME"
    fi
}

probe_wallpaper() {
    [[ "$DESKTOP_WALLPAPER_TOOL" == "swaybg" ]] || return 0
    # Sem URL o modulo nao tem o que garantir: a cor solida do config basta.
    [[ -n "$DESKTOP_WALLPAPER_URL" ]] || return 0
    [[ -s "$(wallpaper_path)" ]]
}

do_wallpaper() {
    [[ "$DESKTOP_WALLPAPER_TOOL" == "swaybg" ]] || return 0
    [[ -n "$DESKTOP_WALLPAPER_URL" ]] || {
        log_info "DESKTOP_WALLPAPER_URL vazio — nenhum download; o swaybg usara a cor solida"
        return 0
    }

    local dest
    dest="$(wallpaper_path)"
    log_info "baixando o papel de parede de $DESKTOP_WALLPAPER_URL"
    log_warn "a imagem e obra de terceiro (Pixiv). Baixando para uso proprio; ela NAO acompanha este repositorio."

    # --referer: sem isto o i.pximg.net devolve 403. E a causa numero um de
    # 'baixei e veio um arquivo de 0 bytes' com links do Pixiv.
    # Baixa para .parcial e so promove no sucesso: um arquivo truncado no lugar
    # final faria o probe considerar feito e o swaybg mostrar tela preta.
    run_as_user mkdir -p "$(dirname "$dest")"
    if run_as_user wget --quiet --referer="https://www.pixiv.net/" \
            --user-agent="Mozilla/5.0" -O "$dest.parcial" "$DESKTOP_WALLPAPER_URL" \
       && [[ -s "$dest.parcial" ]]; then
        run_as_user mv "$dest.parcial" "$dest"
        log_info "papel de parede salvo em '$dest'"
    else
        run_as_user rm -f "$dest.parcial"
        log_warn "NAO consegui baixar o papel de parede."
        log_warn "O Pixiv exige o cabecalho Referer (ja enviado) e pode exigir sessao autenticada para algumas obras."
        log_warn "Baixe a imagem manualmente pela pagina https://www.pixiv.net/en/artworks/115453639 e salve em: $dest"
        log_warn "Depois rode: ./desktop/install-desktop.sh --only 14"
        log_warn "Ate la o swaybg usa a cor solida — a sessao sobe normalmente."
    fi
}

# A ordem aqui tem de ser EXATAMENTE a dos run_step abaixo — o teste
# test-desktop.sh compara as duas listas. O plano impresso pelo --dry-run e o
# comando que o usuario roda para se informar; se ele mente por omissao ou por
# ordem trocada, e pior que nao existir.
dry_run_guard 14-wallpaper 14-niri-config 14-fontconfig 14-gtk-theme 14-bar-config 14-terminal-config 14-shell

# O wallpaper vem ANTES do config do niri: o do_niri_config so declara o
# `swaybg -i` se a imagem JA existe no disco (senao cai na cor solida), entao o
# download precisa ter acontecido — ou falhado com aviso — antes desta decisao.
run_step 14-wallpaper       probe_wallpaper       do_wallpaper

run_step 14-niri-config     probe_niri_config     do_niri_config

# Auditoria da rota de audio CONTRA o arquivo que existe de verdade. Precisa vir
# depois do run_step e fora dele: quando o usuario ja tinha um config.kdl, o
# probe passa e o do_fn NUNCA roda — entao nada dentro do run_step teria olhado
# para o conteudo daquele arquivo. Este e o unico ponto em que uma divergencia
# entre a decisao da 13 e o config real pode ser vista.
audit_audio_route
audit_clavis_migration

run_step 14-fontconfig      probe_fontconfig      do_fontconfig
run_step 14-gtk-theme       probe_gtk_theme       do_gtk_theme
run_step 14-bar-config      probe_bar_config      do_bar_config
run_step 14-terminal-config probe_terminal_config do_terminal_config
run_step 14-shell           probe_shell           do_shell

log_info "==== 14-dotfiles concluido com sucesso ===="
log_info "todos os arquivos foram escritos como '$DESKTOP_USER' — nenhum dotfile com dono root"
if pkg_installed media-video/pipewire; then
    log_info "audio           : rota '${AUDIO_ROUTE:-(marker ausente)}'$([[ "$AUDIO_ROUTE" == "launcher" ]] && printf ' — launcher declarado no spawn-at-startup do config.kdl' || printf ' — launcher NAO declarado no config.kdl (correto para esta rota)')"
fi

cat <<'FINAL'

========================================================================
  CONFIGURACAO DO USUARIO APLICADA
========================================================================
Este era o ultimo passo do modulo de desktop. Para entrar na sessao, a
partir de um TTY (NAO como root):

    dbus-run-session niri --session

NUNCA use 'niri-session' em OpenRC: esse script procura systemd ou dinit,
nao encontra, imprime "No systemd or dinit detected" e sai — a sessao morre
na hora.

Atalhos do config gerado (se voce nao tinha um config.kdl proprio):
    Mod+T          abre o terminal
    Mod+D          abre o lancador de aplicativos
    Mod+Q          fecha a janela em foco
    Mod+Shift+/    mostra TODOS os atalhos
    Mod+Shift+E    sai da sessao

SE ALGO PARECER ERRADO NA APARENCIA (e nao na sessao):
  - icones como caixas vazias -> confira o nome real da fonte:
        fc-list | grep -i 'symbols nerd'
  - config de fonte sem efeito -> confira se o 50-user.conf esta ativo:
        eselect fontconfig list
  - mudanca de fonte nao aparece -> fontconfig nao afeta app ja rodando;
    reinicie o aplicativo ou a sessao.
  - app GTK4 continua claro -> apps libadwaita ignoram tema GTK e seguem
    apenas o color-scheme, que depende do portal estar ativo na sessao.

Nenhum destes sintomas impede a sessao de subir. Se o problema for a SESSAO
(tela preta, niri nao inicia), o culpado nao esta aqui — reveja a etapa
11-nvidia-wayland e a saida do 15-validate.
========================================================================

FINAL
