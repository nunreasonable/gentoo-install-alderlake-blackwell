#!/usr/bin/env bash
# 16-clavis.sh — Clavis Shell: o shell Quickshell que da ao niri barra,
# notificacoes, launcher, settings e tema dinamico. E o rice de referencia
# (StatIndet/quickshell), portado para Gentoo/OpenRC.
#
# Fase: sistema JA INSTALADO E BOOTADO (regra 2), depois da 12 (niri existe) e
# depois da 14 (config.kdl do usuario existe) — ver a nota de ORDEM no fim.
#
# POR QUE ESTA ETAPA E DIFERENTE DAS OUTRAS. Todas as etapas anteriores
# instalam pacotes que o Portage conhece. O Clavis NAO tem ebuild, nem na
# arvore nem na GURU, e nem seus dois irmaos (key-cli, keytop). Isto aqui e,
# portanto, a unica parte do modulo que compila codigo de terceiro a partir do
# git. Duas consequencias que moldam o script inteiro:
#
#   1. O Portage nao rastreia nada disto. Nao ha `emerge --unmerge` para
#      desfazer. Por isso a instalacao fica confinada a prefixos previsiveis
#      (CLAVIS_PREFIX e o venv do key-cli) e o desinstalar e documentado no
#      README do modulo em vez de automatizado — remover arquivo que o gerente
#      de pacotes nao conhece e territorio do operador.
#   2. Um upstream "under active development" (a descricao do repo e
#      literalmente "Works on my machine.") pode quebrar entre dois `git pull`.
#      Por isso DESKTOP_CLAVIS_REF existe e o default NAO e um branch movel.
#
# O QUE ESTA ETAPA NAO FAZ, DE PROPOSITO: nao escreve nada em
# ~/.config/clavis/. Verificado no codigo do upstream: todo servico de
# configuracao e self-healing — dispara `mkdir -p` no start e um FileView com
# onLoadFailed que carrega os defaults embutidos e chama save(). Materializar
# esses JSON aqui so criaria divergencia com o upstream a cada versao, sem
# ganho nenhum. A unica integracao que exige acao externa e o config.kdl do
# niri, e mesmo essa o proprio shell faz — desde que o arquivo ja exista.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-desktop.sh"

init_logging_desktop 16-clavis
# Repetida aqui, e nao so no install-desktop.sh, porque os scripts do projeto
# rodam standalone para debug — mesmo padrao das etapas anteriores.
require_booted_system
require_root

if [[ "$DESKTOP_CLAVIS" != "yes" ]]; then
    # OMISSAO, nunca remocao — mesma semantica de NVIDIA_MODE=skip no 04.
    # Quem ja tem o Clavis instalado continua com ele.
    log_info "DESKTOP_CLAVIS=no — etapa pulada (nada e instalado e nada existente e removido)"
    exit 0
fi

# Daqui para baixo mexemos no sistema de verdade: emerge, escrita em
# /etc/portage, compilacao no HOME do usuario, venv em /opt e uma linha nova no
# config.kdl. Tudo que veio antes e leitura.
dry_run_guard 16-clavis-keywords 16-clavis-use 16-clavis-deps \
              16-clavis-build 16-key-cli 16-keytop 16-clavis-fonts \
              16-clavis-autostart

CLAVIS_SRC="$DESKTOP_CLAVIS_SRC"
CLAVIS_BUILD="$CLAVIS_SRC/build"
KEY_VENV="$DESKTOP_CLAVIS_KEY_VENV"
KEY_BIN="/usr/local/bin/key"
KEYWORDS_FILE=/etc/portage/package.accept_keywords/clavis
PKGUSE_FILE=/etc/portage/package.use/clavis

# ---------------------------------------------------------------------------
# 16-clavis-keywords — ~amd64 apenas para quem realmente precisa
# ---------------------------------------------------------------------------
#
# Arquivo PROPRIO (package.accept_keywords/clavis), como as demais etapas: o
# modulo nunca edita os arquivos do instalador base nem os da etapa 10.
#
# So dois atoms. O qtkeychain e ESTAVEL em amd64 e nao entra — destravar por
# precaucao esconde de voce quando um pacote de fato precisou ser destravado.

gen_clavis_keywords() {
    printf '%s\n' "# Keywords ~amd64 exigidas pelo Clavis Shell."
    printf '%s\n' "#"
    printf '%s\n' "# gui-apps/quickshell e o runtime do shell; media-sound/libcava e a"
    printf '%s\n' "# biblioteca do visualizador de audio. Os dois vem da GURU, que e ~arch"
    printf '%s\n' "# por politica do overlay."
    printf '%s\n' "#"
    printf '%s\n' "# dev-libs/qtkeychain NAO esta aqui: ele e estavel em amd64."
    printf '%s\n' ""
    printf '%s\n' "gui-apps/quickshell ~amd64"
    printf '%s\n' ">=media-sound/libcava-1.0.0 ~amd64"
}

probe_clavis_keywords() {
    [[ -f "$KEYWORDS_FILE" ]] || return 1
    local desired
    desired="$(_managed_header "16-clavis.sh"; gen_clavis_keywords)" || return 1
    [[ "$(cat "$KEYWORDS_FILE")" == "$desired" ]]
}

do_clavis_keywords() {
    write_managed_file "$KEYWORDS_FILE" "$(gen_clavis_keywords)" "16-clavis.sh"
}

run_step 16-clavis-keywords probe_clavis_keywords do_clavis_keywords

# ---------------------------------------------------------------------------
# 16-clavis-use — as USE que NAO sao default e sem as quais o build falha
# ---------------------------------------------------------------------------
#
# Tres linhas, e nenhuma e cosmetica. Cada uma foi derivada do ebuild ou do
# CMakeLists do upstream, nao de receita:
#
#   dev-qt/qtbase[vulkan]   O quickshell declara RDEPEND dev-qt/qtbase:6=
#                           [dbus,vulkan,X?]. A USE 'vulkan' NAO e default no
#                           qtbase; sem ela o emerge do quickshell para pedindo
#                           --autounmask-write. 'dbus' e default, mas fica
#                           declarada porque e requisito duro e um perfil que a
#                           desligue deve falhar aqui, nao la na frente.
#
#   dev-qt/qttools[linguist]  O Clavis pede o componente LinguistTools do Qt6
#                           (core/CMakeLists.txt), que e quem fornece lrelease.
#                           Default '+', declarada pelo mesmo motivo.
#
#   media-sound/libcava[pipewire]  NAO e default. O plugin de cava do Clavis
#                           linka PkgConfig::Pipewire junto de PkgConfig::Cava.
#
# O SLOT do qtkeychain NAO aparece aqui, e a ausencia e deliberada: ele e
# SLOT="0/1", nao ':6'. Escrever 'dev-libs/qtkeychain:6' faz o Portage recusar
# o atom. O ':6' do Qt engana justamente porque o pacote e Qt6-only na arvore
# atual — a versao Qt5 foi removida, e com ela o slot que muita documentacao
# antiga ainda menciona.

gen_clavis_use() {
    printf '%s\n' "# USE flags exigidas pelo Clavis Shell — arquivo PROPRIO do modulo."
    printf '%s\n' "#"
    printf '%s\n' "# Cada flag foi validada contra o IUSE real do ebuild (have_use_flag)"
    printf '%s\n' "# antes de ser escrita, nunca copiada de receita."
    printf '%s\n' ""
    printf '%s\n' "# vulkan NAO e default no qtbase, e o quickshell exige qtbase[dbus,vulkan]."
    _use_line_clavis dev-qt/qtbase:6 dbus vulkan
    printf '%s\n' ""
    printf '%s\n' "# linguist fornece o lrelease que o componente Qt6 LinguistTools usa."
    _use_line_clavis dev-qt/qttools:6 linguist
    printf '%s\n' ""
    printf '%s\n' "# pipewire NAO e default no libcava; o plugin de cava do Clavis o exige."
    _use_line_clavis media-sound/libcava pipewire
}

# Mesmo contrato do _use_line da etapa 10: valida contra o IUSE REAL antes de
# escrever. Duplicado aqui em vez de importado porque o da 10 e local ao
# arquivo dela; a validacao em si mora no lib-desktop.sh e e compartilhada.
_use_line_clavis() {
    local atom="$1"; shift
    local flag bare
    for flag in "$@"; do
        bare="${flag#-}"
        have_use_flag "$atom" "$bare" \
            || die "o USE flag '$bare' NAO existe no IUSE de '$atom' nesta versao da arvore. Gravar flag inexistente em package.use faz o Portage recusar o emerge inteiro. Confira com: portageq metadata / ebuild \$(portageq best_visible / $atom) IUSE"
    done
    printf '%s %s\n' "$atom" "$*"
}

probe_clavis_use() {
    [[ -f "$PKGUSE_FILE" ]] || return 1
    local desired
    desired="$(_managed_header "16-clavis.sh"; gen_clavis_use)" || return 1
    [[ "$(cat "$PKGUSE_FILE")" == "$desired" ]]
}

do_clavis_use() {
    write_managed_file "$PKGUSE_FILE" "$(gen_clavis_use)" "16-clavis.sh"
}

run_step 16-clavis-use probe_clavis_use do_clavis_use

# ---------------------------------------------------------------------------
# 16-clavis-deps — dependencias, e a colisao cava/libcava
# ---------------------------------------------------------------------------
#
# A COLISAO. media-sound/cava (arvore, karlstav/cava) e media-sound/libcava
# (GURU, fork LukashonakV) instalam AMBOS o binario /usr/bin/cava. Nao ha
# blocker declarado em nenhum dos dois ebuilds — grep por '!media-sound' nos
# dois nao retorna nada — entao o Portage deixa instalar os dois e a colisao
# so aparece no merge: com FEATURES=collision-protect o emerge aborta; sem ele,
# um sobrescreve o outro em silencio.
#
# O Clavis precisa da BIBLIOTECA (libcava.pc + headers em /usr/include/cava),
# e so o fork a fornece — o ebuild da arvore diz textualmente "ignoring
# libcavacore for now". O libcava e superconjunto: da a lib E o binario cava.
#
# Nao desinstalamos nada (regra do projeto: omissao, nunca remocao). Abortamos
# com o comando exato, porque a decisao de remover um pacote instalado e do
# operador.
CLAVIS_DEPS=(
    gui-apps/quickshell
    media-sound/libcava
    dev-libs/qtkeychain
    dev-qt/qtbase:6
    dev-qt/qtdeclarative:6
    dev-qt/qtshadertools:6
    dev-qt/qttools:6
    media-video/pipewire
    dev-vcs/git
    dev-util/cmake
    dev-build/ninja
    dev-python/pip
)

assert_no_cava_collision() {
    pkg_installed media-sound/cava || return 0
    die "media-sound/cava esta instalado e COLIDE com media-sound/libcava: os dois instalam /usr/bin/cava. O Clavis precisa do libcava (fork LukashonakV), que fornece a biblioteca E o binario — o da arvore fornece so o binario. Remova o da arvore e re-execute: emerge --unmerge media-sound/cava"
}

probe_clavis_deps() {
    local atom
    for atom in "${CLAVIS_DEPS[@]}"; do
        pkg_installed "${atom%%:*}" || return 1
    done
    # O pkg-config e a autoridade sobre o que o CMake vai achar. Um libcava
    # instalado SEM o .pc (ou com o binario vindo do pacote errado) passa no
    # pkg_installed e reprova no configure, horas depois.
    pkg-config --exists libcava 2>/dev/null || return 1
    pkg-config --exists libpipewire-0.3 2>/dev/null || return 1
}

do_clavis_deps() {
    assert_no_cava_collision

    # --noreplace: a etapa e re-executada a cada retomada e o Qt inteiro nao
    # pode ser remergido por causa de um pacote pequeno que faltou (foi o 1.5
    # do Ciclo 1).
    emerge --noreplace "${CLAVIS_DEPS[@]}" \
        || die "falha ao instalar as dependencias do Clavis. Se o emerge parou pedindo --autounmask-write, o package.use da sub-etapa anterior nao cobriu algum flag: leia a sugestao do Portage e me reporte em vez de aplicar direto (o modulo nunca reescreve config do Portage sozinho). Log: $LOGFILE"

    # Verificacao pos-emerge, no espirito do 1.3 do Ciclo 1: um emerge que sai
    # 0 nao prova que o .pc existe, e e o .pc que o CMake procura.
    pkg-config --exists libcava \
        || die "media-sound/libcava foi instalado mas 'pkg-config --exists libcava' falha. Sem o libcava.pc o configure do Clavis aborta (ele tenta 'libcava' e depois 'cava', o segundo REQUIRED). Confira: pkg-config --list-all | grep -i cava"
    pkg-config --exists libpipewire-0.3 \
        || die "libpipewire-0.3.pc nao encontrado apesar de media-video/pipewire estar instalado."
}

run_step 16-clavis-deps probe_clavis_deps do_clavis_deps

# ---------------------------------------------------------------------------
# 16-clavis-build — compilar e instalar o shell
# ---------------------------------------------------------------------------
#
# DUAS ARMADILHAS DO CMAKE DESTE UPSTREAM, as duas confirmadas lendo o
# core/CMakeLists.txt:
#
#   1. NAO existe install(TARGETS). Os .so dos modulos QML sao instalados por
#      copia de diretorio da BUILD-TREE (FILES_MATCHING PATTERN "*.so*"). Ou
#      seja: `cmake --install` sobre uma build-tree nao compilada instala um
#      diretorio vazio e SAI COM 0. E o modo de falha do 1.3 outra vez — o
#      comando mente. Por isso verificamos os artefatos depois do build E
#      depois do install.
#
#   2. CLAVIS_CONFIG_INSTALL_DIR e RELATIVO por default ("etc/xdg/quickshell/
#      clavis"), entao o CMake o ancora no prefixo. Com PREFIX=/usr isso vira
#      /usr/etc/xdg/..., que o XDG nao le. Passamos o caminho ABSOLUTO, que o
#      CMake respeita como esta.
#
# BUILD_TESTING vem do modulo CTest com default ON e arrastaria Qt6::Test e
# bash para o build. Desligado explicitamente.
#
# COMPILA COMO O USUARIO, instala como root. Compilar como root deixaria a
# build-tree e o ~/.cache do Qt com dono root dentro do HOME do usuario, que e
# a forma silenciosa de quebrar a sessao seguinte.

clavis_cmake_defs() {
    printf '%s\n' \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCLAVIS_CONFIG_INSTALL_DIR=/etc/xdg/quickshell/clavis \
        -DBUILD_TESTING=OFF
}

# O diretorio de modulos QML depende do libdir da distro. Perguntamos ao CMake
# em vez de assumir lib64: o Gentoo usa lib64 em multilib e lib em no-multilib,
# e adivinhar aqui e como adivinhar caminho de home.
clavis_qml_dir() {
    local libdir
    libdir="$(pkg-config --variable=libdir Qt6Core 2>/dev/null)" || libdir=""
    [[ -n "$libdir" ]] || libdir=/usr/lib64
    printf '%s/qt6/qml\n' "$libdir"
}

probe_clavis_build() {
    local qmldir
    qmldir="$(clavis_qml_dir)"
    # Os DOIS modulos nativos, e o .so de verdade — nao so o diretorio, que a
    # copia do CMake cria mesmo quando nao ha o que copiar.
    compgen -G "$qmldir/Clavis/*.so" > /dev/null || return 1
    compgen -G "$qmldir/M3Shapes/*.so" > /dev/null || return 1
    # A config do Quickshell, que e o que o `key shell` carrega.
    [[ -f /etc/xdg/quickshell/clavis/shell.qml ]] || return 1
    # E o ref pedido tem de ser o instalado: trocar DESKTOP_CLAVIS_REF precisa
    # invalidar esta sub-etapa, senao o operador troca a versao e nada acontece.
    [[ "$(step_value 16-clavis-build)" == "$DESKTOP_CLAVIS_REF" ]]
}

do_clavis_build() {

    local home
    home="$(user_home)"

    # O checkout vive no HOME do usuario e pertence a ele: e ele quem compila.
    if [[ ! -d "$CLAVIS_SRC/.git" ]]; then
        run_as_user mkdir -p "$(dirname "$CLAVIS_SRC")" \
            || die "nao foi possivel criar o diretorio pai de '$CLAVIS_SRC' como '$DESKTOP_USER'."
        run_as_user git clone "$DESKTOP_CLAVIS_URL" "$CLAVIS_SRC" \
            || die "falha ao clonar $DESKTOP_CLAVIS_URL em '$CLAVIS_SRC'."
    fi

    run_as_user git -C "$CLAVIS_SRC" fetch --tags origin \
        || die "falha no 'git fetch' em '$CLAVIS_SRC'. Sem rede? Confira com: ping -c1 github.com"
    run_as_user git -C "$CLAVIS_SRC" checkout --detach "$DESKTOP_CLAVIS_REF" \
        || die "o ref '$DESKTOP_CLAVIS_REF' nao existe em $DESKTOP_CLAVIS_URL. Liste os disponiveis com: git -C '$CLAVIS_SRC' tag --list"

    # Build-tree LIMPA a cada troca de ref. O cache do CMake guarda caminhos e
    # resultados de find_package do configure anterior; reaproveita-lo entre
    # refs diferentes e como confiar num marker em vez do probe.
    run_as_user rm -rf "$CLAVIS_BUILD" \
        || die "nao foi possivel limpar a build-tree '$CLAVIS_BUILD'."

    local sha
    # tail -1: o `su -` do run_as_user e login shell e le os rc do usuario, que
    # podem escrever em stdout. Mesmo cuidado que o gsettings_get da 14 ja toma.
    sha="$(run_as_user git -C "$CLAVIS_SRC" rev-parse HEAD 2>/dev/null | tail -1)" || sha=""
    [[ -n "$sha" ]] || die "nao foi possivel ler o SHA de '$CLAVIS_SRC'."

    local -a defs
    mapfile -t defs < <(clavis_cmake_defs)

    run_as_user cmake -S "$CLAVIS_SRC" -B "$CLAVIS_BUILD" -G Ninja \
        "${defs[@]}" -DCLAVIS_RELEASE="$DESKTOP_CLAVIS_REF" -DCLAVIS_COMMIT="$sha" \
        || die "o 'cmake configure' do Clavis falhou. Causa mais comum: um pkg-config ausente (libcava, libpipewire-0.3) ou Qt6Keychain sem o pacote de desenvolvimento. Log: $LOGFILE"

    run_as_user cmake --build "$CLAVIS_BUILD" \
        || die "a compilacao do Clavis falhou. Log: $LOGFILE"

    # O install COPIA da build-tree. Se o build nao produziu os .so, o install
    # instalaria vazio e sairia 0. Verificamos aqui, antes.
    compgen -G "$CLAVIS_BUILD/qml/Clavis/*.so" > /dev/null \
        || die "a compilacao terminou mas nenhum .so apareceu em '$CLAVIS_BUILD/qml/Clavis'. O 'cmake --install' deste upstream copia da build-tree (nao ha install(TARGETS)), entao instalar agora produziria um diretorio vazio SEM erro."

    cmake --install "$CLAVIS_BUILD" \
        || die "o 'cmake --install' do Clavis falhou."

    probe_clavis_build_artifacts_or_die
    mark_done 16-clavis-build "$DESKTOP_CLAVIS_REF"
    log_info "Clavis Shell '$DESKTOP_CLAVIS_REF' ($sha) instalado"
}

probe_clavis_build_artifacts_or_die() {
    local qmldir
    qmldir="$(clavis_qml_dir)"
    compgen -G "$qmldir/Clavis/*.so" > /dev/null \
        || die "o 'cmake --install' saiu com 0 mas nao ha .so em '$qmldir/Clavis'. Confira o CLAVIS_QML_INSTALL_DIR do build."
    [[ -f /etc/xdg/quickshell/clavis/shell.qml ]] \
        || die "o shell.qml nao foi instalado em /etc/xdg/quickshell/clavis. Sem ele o 'key shell' nao tem o que carregar."
}

run_step 16-clavis-build probe_clavis_build do_clavis_build

# ---------------------------------------------------------------------------
# 16-key-cli — o comando `key`, num venv dedicado
# ---------------------------------------------------------------------------
#
# POR QUE VENV, E NAO pip. O Gentoo marca o interpretador do sistema como
# EXTERNALLY-MANAGED (PEP 668): o site-packages e territorio do Portage e o pip
# se recusa a escrever la, corretamente. As alternativas e por que nao:
#
#   pip --user                  escreve em ~/.local/lib/pythonX.Y/, versionado
#                               pelo MINOR do Python. Um `eselect python set`
#                               faz o comando `key` sumir do PATH sem aviso.
#   pip --break-system-packages cria arquivos que o Portage nao conhece e que
#                               sobrevivem ao unmerge do proprio Python.
#   pipx                        seria o ideal, mas dev-python/pipx NAO EXISTE
#                               na arvore do Gentoo (verificado em 2026-09-03).
#
# Sobra o venv dedicado com symlink no PATH, que e o que o pipx faria a mao. O
# key-cli tem ZERO dependencias de runtime, entao o venv e stdlib + o pacote.

probe_key_cli() {
    [[ -x "$KEY_VENV/bin/key" ]] || return 1
    [[ -L "$KEY_BIN" && "$(readlink -f "$KEY_BIN")" == "$(readlink -f "$KEY_VENV/bin/key")" ]] || return 1
    # Funcional: o binario tem de EXECUTAR. Um venv cujo interpretador sumiu
    # (Python removido pelo Portage) ainda tem o arquivo e o symlink.
    "$KEY_VENV/bin/key" version > /dev/null 2>&1 || return 1
    [[ "$(step_value 16-key-cli)" == "$DESKTOP_CLAVIS_KEY_REF" ]]
}

do_key_cli() {

    # Recriado do zero a cada mudanca de ref: `pip install --upgrade` num venv
    # existente deixa artefato da versao anterior quando o layout do pacote
    # muda, e este upstream esta em movimento.
    rm -rf "$KEY_VENV" || die "nao foi possivel remover o venv anterior '$KEY_VENV'."
    python3 -m venv "$KEY_VENV" \
        || die "falha ao criar o venv em '$KEY_VENV'. O modulo venv exige USE=ensurepip em dev-lang/python (default '+'). Confira: python3 -m venv --help"

    "$KEY_VENV/bin/pip" install --quiet --upgrade pip \
        || die "falha ao atualizar o pip dentro do venv '$KEY_VENV'."
    "$KEY_VENV/bin/pip" install --quiet "git+${DESKTOP_CLAVIS_KEY_URL}@${DESKTOP_CLAVIS_KEY_REF}" \
        || die "falha ao instalar o key-cli de ${DESKTOP_CLAVIS_KEY_URL}@${DESKTOP_CLAVIS_KEY_REF}. Log: $LOGFILE"

    [[ -x "$KEY_VENV/bin/key" ]] \
        || die "o pip terminou mas '$KEY_VENV/bin/key' nao existe. O entry point 'key = key_cli:main' do pyproject.toml nao foi gerado."

    # /usr/local/bin esta no PATH default do Gentoo, e o `key` PRECISA estar no
    # PATH: o proprio Clavis o resolve por PATH (shutil.which), e o
    # spawn-at-startup do niri herda o PATH da sessao, nao um caminho absoluto.
    ln -sfn "$KEY_VENV/bin/key" "$KEY_BIN" \
        || die "falha ao criar o symlink '$KEY_BIN'."

    mark_done 16-key-cli "$DESKTOP_CLAVIS_KEY_REF"
    log_info "key-cli '$DESKTOP_CLAVIS_KEY_REF' instalado em '$KEY_VENV' e ligado em '$KEY_BIN'"
}

run_step 16-key-cli probe_key_cli do_key_cli

# ---------------------------------------------------------------------------
# 16-keytop — monitor de sistema, OPCIONAL de verdade
# ---------------------------------------------------------------------------
#
# O SystemMonitorService do Clavis degrada com mensagem tratada quando o keytop
# falta: o resto do shell funciona inteiro. Por isso esta sub-etapa nao pode
# derrubar a etapa — o custo de falhar aqui (perder os graficos de CPU/GPU) e
# muito menor que o de nao ter sessao grafica.
#
# "Opcional" so vale se o codigo concordar: o probe reporta FEITO quando a
# instalacao foi tentada e falhou, senao a etapa reprovaria para sempre e o
# operador nunca passaria daqui. O marker guarda QUAL desfecho houve.

probe_keytop() {
    [[ "$DESKTOP_CLAVIS_KEYTOP" == "yes" ]] || return 0
    case "$(step_value 16-keytop)" in
        # Tentativa anterior falhou e o operador foi avisado. Nao insistimos a
        # cada re-execucao: quem quiser tentar de novo apaga o marker.
        skipped) return 0 ;;
        installed) command -v keytop > /dev/null 2>&1 && return 0 ;;
    esac
    return 1
}

do_keytop() {
    if [[ "$DESKTOP_CLAVIS_KEYTOP" != "yes" ]]; then
        log_info "DESKTOP_CLAVIS_KEYTOP=no — keytop nao sera instalado (o Clavis funciona sem ele, com os graficos de sistema degradados)"
        return 0
    fi

    local src="$DESKTOP_CLAVIS_KEYTOP_SRC" build
    build="$src/build"

    # Todo o bloco e nao-fatal: cada passo que falhar cai no aviso e grava o
    # desfecho. `set -e` nao ajuda aqui — queremos justamente NAO morrer.
    if _keytop_try "$src" "$build"; then
        mark_done 16-keytop installed
        log_info "keytop instalado"
    else
        mark_done 16-keytop skipped
        log_warn "keytop NAO foi instalado. Isto nao impede a sessao: o SystemMonitorService do Clavis trata a ausencia e o resto do shell funciona. Para tentar de novo depois: rm $(state_dir)/16-keytop && ./desktop/install-desktop.sh --only 16"
    fi
}

_keytop_try() {
    local src="$1" build="$2" sha
    if [[ ! -d "$src/.git" ]]; then
        run_as_user git clone "$DESKTOP_CLAVIS_KEYTOP_URL" "$src" || return 1
    fi
    run_as_user git -C "$src" fetch --tags origin || return 1
    run_as_user git -C "$src" checkout --detach "$DESKTOP_CLAVIS_KEYTOP_REF" || return 1
    run_as_user rm -rf "$build" || return 1
    run_as_user cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr || return 1
    run_as_user cmake --build "$build" || return 1
    cmake --install "$build" || return 1
    command -v keytop > /dev/null 2>&1 || return 1
    return 0
}

run_step 16-keytop probe_keytop do_keytop

# ---------------------------------------------------------------------------
# 16-clavis-autostart — arranque em OpenRC, via niri
# ---------------------------------------------------------------------------
#
# O upstream so empacota units systemd (packaging/systemd/user/). Elas NAO sao
# acoplamento: `systemctl` aparece em exatamente um arquivo do projeto inteiro
# — o README. O arranque real e o comando `key shell`, standalone.
#
# Traducao das duas units para OpenRC:
#
#   clavis-shell.service       -> spawn-at-startup "key" "shell"
#   clavis-clipboard.service   -> spawn-at-startup "key" "clipboard" "watch"
#                                 (ExecStart literal da unit)
#
# As diretivas Requisite=/PartOf=/After=niri.service codificam "so roda
# enquanto o niri roda, e morre junto". O spawn-at-startup reproduz isso
# naturalmente: o processo e filho do niri. O que ele NAO reproduz e o
# Restart=on-failure — o niri nao reinicia spawn que morre. Aceitamos a
# diferenca em vez de inventar um wrapper com laco: um shell que morre e um
# sintoma que o operador precisa ver, nao esconder atras de um restart.
#
# O config.kdl e ARQUIVO DO USUARIO: nao reescrevemos. Acrescentamos as duas
# linhas se ausentes, como o usuario, no mesmo padrao do 13-xdg-runtime-dir.

CLAVIS_SPAWN_SHELL='spawn-at-startup "key" "shell"'
CLAVIS_SPAWN_CLIP='spawn-at-startup "key" "clipboard" "watch"'

niri_config_path() {
    printf '%s/.config/niri/config.kdl\n' "$(user_home)"
}

probe_clavis_autostart() {
    local cfg
    cfg="$(niri_config_path)"
    [[ -f "$cfg" ]] || return 1
    grep -qxF "$CLAVIS_SPAWN_SHELL" "$cfg" || return 1
    grep -qxF "$CLAVIS_SPAWN_CLIP" "$cfg" || return 1
}

do_clavis_autostart() {

    local cfg
    cfg="$(niri_config_path)"

    # O config.kdl precisa EXISTIR antes do primeiro start do Clavis por um
    # motivo alem deste: os scripts do proprio shell que inserem os includes de
    # effects/cursor saem com codigo 3 quando o arquivo principal nao existe.
    # Quem cria o config.kdl e a etapa 14 — se ela nao rodou, o erro tem de
    # dizer isso, e nao criar um config.kdl improvisado por baixo dela.
    [[ -f "$cfg" ]] \
        || die "'$cfg' nao existe. Ele e criado pela etapa 14 (dotfiles) e o Clavis depende dele: os scripts que inserem os includes de effects e cursor abortam quando o config principal falta. Rode antes: ./desktop/install-desktop.sh --only 14"

    if command -v niri > /dev/null 2>&1; then
        run_as_user niri validate --config "$cfg" > /dev/null 2>&1 \
            || log_warn "'niri validate' reprovou '$cfg'. As linhas de spawn-at-startup serao acrescentadas mesmo assim, mas o niri pode recusar o arquivo inteiro no proximo login. Confira com: niri validate --config '$cfg'"
    fi

    local line
    for line in "$CLAVIS_SPAWN_SHELL" "$CLAVIS_SPAWN_CLIP"; do
        if grep -qxF "$line" "$cfg"; then
            log_info "'$cfg' ja contem: $line"
            continue
        fi
        printf '\n%s\n' "$line" | run_as_user tee -a "$cfg" > /dev/null \
            || die "falha ao acrescentar '$line' em '$cfg'."
        log_info "acrescentado a '$cfg' (como '$DESKTOP_USER'): $line"
    done

    log_warn "O Clavis so sobe no PROXIMO login da sessao grafica — o spawn-at-startup roda quando o niri inicia, nao agora."
}

# ---------------------------------------------------------------------------
# 16-clavis-fonts — o unico download fora do Portage deste projeto
# ---------------------------------------------------------------------------
#
# Duas das tres familias que o Clavis pede estao empacotadas e entram por
# emerge. A Material Symbols Rounded NAO existe em ::gentoo nem na GURU
# (verificado listando media-fonts/ dos dois em 2026-09-03), e nao ha
# substituto: o symbols-nerd-font que o modulo ja instala e Nerd Fonts
# (Powerline/Devicons), conjunto de glifos completamente diferente.
#
# Ela e obrigatoria de fato: Components/MaterialSymbol.qml e usado em 121
# arquivos e declara variableAxes com FILL e opsz — exige a fonte VARIAVEL, que
# um TTF estatico nao reproduz.
#
# NADA AQUI E FATAL. O resolveFamily() do Clavis nunca lanca erro: sem a fonte,
# o shell sobe com tofu no lugar dos icones. Feio, diagnosticavel, e muito
# melhor que abortar a instalacao por causa de um download que pode falhar por
# falta de rede. Por isso todo o bloco avisa em vez de morrer.
CLAVIS_FONT_PKGS=(
    media-fonts/nerdfonts   # [jetbrainsmono] da "JetBrainsMono Nerd Font"
    media-fonts/lxgw-wenkai # familia base; a variante "GB Screen" nao e empacotada
)
CLAVIS_SYMBOLS_TTF_NAME='MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf'

clavis_symbols_path() {
    printf '%s/.local/share/fonts/%s\n' "$(user_home)" "$CLAVIS_SYMBOLS_TTF_NAME"
}

probe_clavis_fonts() {
    [[ "$DESKTOP_CLAVIS_FONTS" == "yes" ]] || return 0
    # fc-list e a autoridade: o arquivo existir nao prova que o fontconfig o
    # enxerga (cache desatualizado, diretorio errado, arquivo truncado).
    run_as_user fc-list 2>/dev/null | grep -qi 'Material Symbols Rounded' || return 1
    local pkg
    for pkg in "${CLAVIS_FONT_PKGS[@]}"; do
        pkg_installed "$pkg" || return 1
    done
}

do_clavis_fonts() {
    if [[ "$DESKTOP_CLAVIS_FONTS" != "yes" ]]; then
        log_info "DESKTOP_CLAVIS_FONTS=no — fontes nao serao instaladas (o shell sobe, mas os icones do Clavis viram tofu)"
        return 0
    fi

    # A USE do nerdfonts vai no arquivo proprio do modulo, validada como as
    # demais. Sem 'jetbrainsmono' o pacote instala so os simbolos.
    write_managed_file /etc/portage/package.use/clavis-fonts \
        "$(printf '%s\n' "# Fonte monoespacada que o Clavis pede por nome em Common/Fonts.qml." \
                          "$(_use_line_clavis media-fonts/nerdfonts jetbrainsmono)")" \
        "16-clavis.sh"

    emerge --noreplace "${CLAVIS_FONT_PKGS[@]}" \
        || log_warn "falha ao instalar as fontes empacotadas (${CLAVIS_FONT_PKGS[*]}). O Clavis sobe assim mesmo, com fallback do Qt para as monoespacadas e CJK. Log: $LOGFILE"

    local dest tmp
    dest="$(clavis_symbols_path)"
    if run_as_user fc-list 2>/dev/null | grep -qi 'Material Symbols Rounded'; then
        log_info "Material Symbols Rounded ja esta instalada e visivel ao fontconfig"
    else
        if ! run_as_user mkdir -p "$(dirname "$dest")"; then
            log_warn "nao foi possivel criar o diretorio de fontes de '$DESKTOP_USER' — a Material Symbols nao sera instalada e os icones do Clavis ficarao ausentes."
            return 0
        fi

        # Baixa para um temporario e so promove depois de verificar: um TTF
        # truncado por queda de rede fica no lugar do bom, o fontconfig o
        # ignora, e o sintoma (icones ausentes) e identico ao de nao ter
        # baixado nada — mas o probe passaria a mentir que baixou.
        tmp="${dest}.parcial"
        if run_as_user curl -fsSL --retry 2 -o "$tmp" "$DESKTOP_CLAVIS_SYMBOLS_URL"; then
            # A fonte tem ~15 MB; qualquer coisa muito menor e pagina de erro
            # ou download interrompido.
            local sz
            sz="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"
            if (( sz > 1000000 )) && head -c4 "$tmp" | grep -qa $'\x00\x01\x00\x00'; then
                if run_as_user mv -f "$tmp" "$dest"; then
                    log_info "Material Symbols Rounded instalada em '$dest' ($sz bytes)"
                else
                    # Aviso e nao die, pelo mesmo motivo do resto do bloco:
                    # nenhuma fonte vale abortar uma instalacao. O pior desfecho
                    # aqui e icone ausente.
                    log_warn "o download da fonte deu certo mas nao foi possivel move-la para '$dest'. Confira permissoes do diretorio de fontes de '$DESKTOP_USER'."
                fi
            else
                run_as_user rm -f "$tmp" || true
                log_warn "o download da Material Symbols Rounded veio invalido ($sz bytes, sem assinatura TTF) — provavelmente uma pagina de erro. Os icones do Clavis ficarao ausentes. Baixe a mao de $DESKTOP_CLAVIS_SYMBOLS_URL para '$dest'."
            fi
        else
            run_as_user rm -f "$tmp" 2>/dev/null || true
            log_warn "nao foi possivel baixar a Material Symbols Rounded (sem rede?). O Clavis sobe, mas os icones da barra, do tray e das sidebars ficarao ausentes. Baixe depois de $DESKTOP_CLAVIS_SYMBOLS_URL para '$dest' e rode: fc-cache -f"
        fi
    fi

    run_as_user fc-cache -f > /dev/null 2>&1 \
        || log_warn "'fc-cache -f' falhou como '$DESKTOP_USER'; as fontes novas so aparecerao no proximo login."
}

run_step 16-clavis-fonts probe_clavis_fonts do_clavis_fonts

run_step 16-clavis-autostart probe_clavis_autostart do_clavis_autostart

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------
#
# `key doctor --json` e o diagnostico do proprio upstream: ele faz which() em 9
# executaveis e reporta quais features ficam indisponiveis. Rodamos como o
# USUARIO, que e quem vai usar o shell — o PATH do root e outro.
log_info "===================================================================="
log_info "Clavis Shell instalado. Diagnostico do upstream (key doctor):"
run_as_user key doctor 2>&1 | tail -30 || log_warn "'key doctor' falhou ao rodar como '$DESKTOP_USER'."
log_info "===================================================================="
log_info "Para iniciar sem relogar:  dbus-run-session niri --session"
log_info "Rode isso COMO O USUARIO, nunca como root: como root o niri leria"
log_info "/root/.config/niri/config.kdl (que nao e o arquivo gerado pela 14) e"
log_info "o acesso ao render node, mediado pelo seatd, falharia."
log_info "Configuracao do shell: ~/.config/clavis/ (criada pelo proprio Clavis"
log_info "no primeiro start, com os defaults do upstream)."
