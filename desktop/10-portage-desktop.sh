#!/usr/bin/env bash
# 10-portage-desktop.sh — prepara o PORTAGE para o stack grafico (fase: sistema
# ja instalado e BOOTADO).
#
# PAPEL DESTA ETAPA: deixar a arvore CAPAZ DE RESOLVER os atoms do desktop.
# Ela NAO instala nada do stack grafico — nem niri, nem terminal, nem barra.
# Os unicos emerges que ela faz sao de FERRAMENTA (eselect-repository e
# cpuid2cpuflags), porque sem elas nao da para habilitar overlay nem gerar
# CPU_FLAGS_X86.
#
# POR QUE ELA VEM PRIMEIRO, ANTES DE TUDO:
# metade do stack NAO existe no ::gentoo — gui-wm/niri, gui-apps/fuzzel e
# gui-apps/xwayland-satellite retornam HTTP 404 em packages.gentoo.org (os tres
# confirmados). Sem o overlay GURU habilitado e sem as keywords ~amd64 escritas,
# o primeiro emerge da etapa 12 morre com "no ebuilds to satisfy". Descobrir
# isso na etapa 12 significa descobrir depois de ja ter esperado.
#
# Sub-etapas (run_step):
#   10-guru-repo         -> habilita o overlay GURU (probe: portageq get_repo_path)
#   10-cpu-flags         -> gera CPU_FLAGS_X86 na maquina real (opt-out)
#   10-accept-keywords   -> destrava os ~amd64 do stack, em arquivo PROPRIO
#   10-package-use       -> escreve as USE flags do stack (NAO as do nvidia)
#   10-atoms-resolvable  -> PORTAO: prova que todos os atoms resolvem
#
# REGRA 1 PRESERVADA: este script nunca edita arquivo do instalador base. Ele
# escreve somente em arquivos PROPRIOS dentro de /etc/portage/*.d/ — o Portage
# faz a uniao dos arquivos de cada diretorio, entao acrescentar um arquivo novo
# e aditivo por construcao. Em particular, package.use/nvidia-drivers e
# TERRITORIO DO 04-kernel.sh e nao e tocado aqui (o delta de USE do driver vive
# na etapa 11, isolado, pelo mesmo motivo).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# UM source so: lib-desktop.sh orquestra vars-desktop.sh, ../vars.sh e ../lib.sh
# na ordem correta (e, critico, exporta TARGET_ROOT="" ANTES do ../lib.sh para
# que state_dir() aponte para /var/lib/gentoo-install/state no sistema bootado).
# shellcheck source=lib-desktop.sh
source "$SCRIPT_DIR/lib-desktop.sh"

init_logging_desktop 10-portage-desktop

# Guarda de fase repetida aqui, e nao so no install-desktop.sh, porque os
# scripts deste projeto rodam standalone para debug — mesmo padrao do
# require_phase, que o instalador repete em todos os 00-06. E a unica coisa que
# impede rodar no live ISO ou dentro do chroot da instalacao.
require_booted_system
require_root

# Diretorios de configuracao do Portage. O 02-portage-config.sh ja garante que
# eles existem no sistema instalado; ainda assim cada escrita usa mkdir -p (via
# write_managed_file), porque depender de estado alheio e como um probe mente.
PORTAGE_DIR="/etc/portage"
KEYWORDS_FILE="$PORTAGE_DIR/package.accept_keywords/desktop-niri"
PKGUSE_FILE="$PORTAGE_DIR/package.use/desktop-niri"
CPUFLAGS_FILE="$PORTAGE_DIR/package.use/00cpu-flags"

# ---------------------------------------------------------------------------
# Composicao do stack a partir das escolhas de vars-desktop.sh
# ---------------------------------------------------------------------------
#
# As listas sao montadas UMA vez e reusadas pelas tres etapas que precisam
# delas (keywords, package.use e o portao de resolucao). Montar em um lugar so
# evita a divergencia classica: destravar a keyword de um pacote e esquecer de
# inclui-lo no portao, ou vice-versa.

# desktop_atoms_guru: atoms que vivem no overlay GURU e estao em ~amd64.
# Estes sao os que EXIGEM tanto o overlay quanto a keyword.
desktop_atoms_guru() {
    # Os tres confirmados como inexistentes no ::gentoo (HTTP 404) e presentes
    # no GURU. O niri e o compositor; o fuzzel e o launcher do bind Mod+D; o
    # xwayland-satellite e o que faz app X11 abrir (o niri NAO tem Xwayland
    # embutido — instalar o pacote e so metade, a outra metade e o
    # spawn-at-startup no config.kdl, que a etapa 14 escreve).
    printf '%s\n' gui-wm/niri
    [[ "$DESKTOP_LAUNCHER" == "fuzzel" ]] && printf '%s\n' gui-apps/fuzzel
    [[ "$DESKTOP_ENABLE_XWAYLAND" == "yes" ]] && printf '%s\n' gui-apps/xwayland-satellite
    # swaync tambem e do GURU (~amd64). So entra se o usuario escolheu a
    # central de notificacoes; o default mako esta no ::gentoo e e estavel.
    [[ "$DESKTOP_NOTIFY" == "swaync" ]] && printf '%s\n' gui-apps/swaync
    return 0
}

# desktop_atoms_tree: atoms do ::gentoo que o stack precisa.
#
# Cada um destes foi verificado na pesquisa como EXISTENTE no ::gentoo, mas
# varios tiveram a keyword marcada como "nao verificada". Por isso nenhum deles
# ganha keyword as cegas: o portao 10-atoms-resolvable testa a visibilidade REAL
# e, se algum nao resolver, morre dizendo qual — em vez de o modulo despejar
# ~amd64 em pacote que talvez ja seja estavel.
desktop_atoms_tree() {
    printf '%s\n' sys-auth/seatd
    printf '%s\n' sys-apps/dbus
    printf '%s\n' x11-base/xwayland

    case "$DESKTOP_TERMINAL" in
        foot)      printf '%s\n' gui-apps/foot ;;
        alacritty) printf '%s\n' x11-terms/alacritty ;;
        kitty)     printf '%s\n' x11-terms/kitty ;;
        *) die "DESKTOP_TERMINAL='$DESKTOP_TERMINAL' invalido — use foot, alacritty ou kitty. O terminal e a ferramenta de RECUPERACAO da sessao; entrar no niri sem terminal deixa voce numa tela vazia sem forma de abrir nada." ;;
    esac

    # Terminal de recuperacao, ALEM do principal. kitty e alacritty dependem de
    # EGL/GL — o caminho da NVIDIA que este projeto nunca validou. O foot
    # renderiza em CPU e sobe mesmo com o EGL quebrado.
    #
    # Com DESKTOP_TERMINAL=foot o atom sai repetido na lista. E inofensivo: o
    # probe so faz have_atom em cada item, e emerge com atom repetido e no-op.
    case "$DESKTOP_RECOVERY_TERMINAL" in
        foot)  printf '%s\n' gui-apps/foot ;;
        none)  : ;;
        *) die "DESKTOP_RECOVERY_TERMINAL='$DESKTOP_RECOVERY_TERMINAL' invalido — use foot ou none. Este e o terminal que tem de abrir quando o principal NAO abre; um terminal acelerado por GPU nao serve para esse papel." ;;
    esac

    # Shell. gentoo-zsh-completions traz completion de emerge/eselect/rc-service.
    if [[ "$DESKTOP_SHELL" == "zsh" ]]; then
        printf '%s\n' app-shells/zsh
        printf '%s\n' app-shells/gentoo-zsh-completions
    fi

    [[ "$DESKTOP_BAR"    == "waybar" ]] && printf '%s\n' gui-apps/waybar
    [[ "$DESKTOP_NOTIFY" == "mako"   ]] && printf '%s\n' gui-apps/mako

    # screencast puxa xdg-desktop-portal-gnome como RDEPEND do niri. Declaramos
    # o atom explicitamente no portao para que a falta dele apareca AQUI (em
    # segundos) e nao no meio do emerge do niri.
    if [[ "$DESKTOP_ENABLE_SCREENCAST" == "yes" ]]; then
        printf '%s\n' sys-apps/xdg-desktop-portal
        printf '%s\n' sys-apps/xdg-desktop-portal-gnome
        printf '%s\n' media-video/pipewire
    fi

    [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]] && printf '%s\n' sys-auth/elogind

    # Papel de parede: o niri NAO desenha fundo nenhum sozinho — sem um cliente
    # de wallpaper a area vaga fica PRETA. Na rice de referencia o wallpaper e
    # metade do visual, entao swaybg entra como parte do stack, nao como enfeite.
    [[ "$DESKTOP_WALLPAPER_TOOL" == "swaybg" ]] && printf '%s\n' gui-apps/swaybg

    # fastfetch: e a peca central do terminal na referencia (logo do Gentoo em
    # ASCII + blocos de info). Verificado como app-misc/fastfetch no ::gentoo.
    [[ "$DESKTOP_INSTALL_FASTFETCH" == "yes" ]] && printf '%s\n' app-misc/fastfetch

    # Editor: a referencia mostra neovim. Opcional — quem ja tem o seu desliga.
    [[ "$DESKTOP_INSTALL_NEOVIM" == "yes" ]] && printf '%s\n' app-editors/neovim

    return 0
}

# ---------------------------------------------------------------------------
# 10-guru-repo — habilita o overlay GURU
# ---------------------------------------------------------------------------
#
# PROBE FUNCIONAL, nao marker: a pesquisa foi explicita neste ponto. O marker
# diria "eu ja rodei"; so o portageq diz "o Portage realmente enxerga o repo".
# Um `eselect repository disable guru` feito a mao depois desta etapa tornaria
# o marker uma mentira — e o probe pega isso e re-executa.

probe_guru_repo() {
    local path
    path="$(portageq get_repo_path / "$DESKTOP_GURU_REPO" 2>/dev/null)" || return 1
    [[ -n "$path" ]] || return 1
    # Nao basta o portageq devolver um caminho: o repo tem de estar SINCRONIZADO
    # em disco. Um `eselect repository enable` sem o `emaint sync` deixa o
    # caminho configurado e o diretorio vazio — e nesse estado o emerge falha
    # exatamente com o "no ebuilds to satisfy" que esta etapa existe para evitar.
    # profiles/repo_name e o arquivo que todo repo sincronizado tem.
    [[ -d "$path" && -s "$path/profiles/repo_name" ]]
}

do_guru_repo() {
    # app-eselect/eselect-repository: ::gentoo, estavel amd64. E a ferramenta
    # oficial para habilitar overlay (escreve em /etc/portage/repos.conf/).
    # --noreplace: a intencao aqui e "garantir instalado", nao "reinstalar".
    if ! pkg_installed app-eselect/eselect-repository; then
        log_info "instalando app-eselect/eselect-repository (necessario para habilitar o overlay)"
        emerge --noreplace app-eselect/eselect-repository \
            || die "falha ao instalar app-eselect/eselect-repository. Sem ela nao da para habilitar o overlay GURU, e sem o GURU os atoms gui-wm/niri, gui-apps/fuzzel e gui-apps/xwayland-satellite nao existem. Veja $LOGFILE."
    fi

    # ADITIVO: enable nunca remove repositorio existente. Se o repo ja estiver
    # habilitado (caso de re-execucao apos um sync que falhou), o eselect
    # reclama que ja existe — o que NAO e erro para nos, por isso o `|| true`
    # e o probe logo a seguir sendo a autoridade real sobre o resultado.
    if ! repo_enabled "$DESKTOP_GURU_REPO"; then
        log_info "habilitando o overlay '$DESKTOP_GURU_REPO' via eselect repository"
        eselect repository enable "$DESKTOP_GURU_REPO" \
            || die "'eselect repository enable $DESKTOP_GURU_REPO' falhou. Confira se o nome do overlay esta correto com 'eselect repository list'. Veja $LOGFILE."
    fi

    # O sync e o que de fato traz os ebuilds para o disco. Pode demorar alguns
    # minutos na primeira vez — e um clone completo do overlay.
    log_info "sincronizando o overlay '$DESKTOP_GURU_REPO' (pode demorar alguns minutos na primeira vez)"
    emaint sync -r "$DESKTOP_GURU_REPO" \
        || die "'emaint sync -r $DESKTOP_GURU_REPO' falhou — verifique a conectividade de rede e o espaco em disco. Sem o overlay sincronizado nenhum atom do niri resolve. Veja $LOGFILE."

    # NOTA sobre o que estamos aceitando conscientemente: o GURU e um overlay
    # mantido pela COMUNIDADE, sem o QA oficial do Gentoo, e todo o material
    # dele esta em ~amd64. Aceitamos porque nao ha alternativa no ::gentoo para
    # o compositor escolhido — nao porque o risco seja zero.
}

# ---------------------------------------------------------------------------
# 10-cpu-flags — CPU_FLAGS_X86 gerado NA MAQUINA REAL
# ---------------------------------------------------------------------------
#
# CPU_FLAGS_X86 nao e a mesma coisa que CFLAGS, e a diferenca importa: CFLAGS
# apenas PERMITEM que o compilador gere certas instrucoes; CPU_FLAGS_X86 faz o
# ebuild compilar rotinas de assembly escritas a mao ja otimizadas. Uma nao
# substitui a outra.
#
# O valor TEM de ser gerado na maquina alvo — nunca copiado de tabela ou de post
# de forum, que e como se acaba com uma flag que a CPU nao tem e um SIGILL no
# meio de um emerge.
#
# NOTA TECNICA sobre o i5-12600K: e Alder Lake HIBRIDO (6 P-cores Golden Cove +
# 4 E-cores Gracemont). Como os E-cores NAO tem AVX-512, o conjunto efetivo
# exposto pelo CPUID e o denominador comum e avx512* NAO deve aparecer na saida.
# Se aparecer, algo esta errado (E-cores desabilitados na UEFI, por exemplo) e
# vale investigar antes de compilar o mundo com uma flag que metade dos nucleos
# nao executa.

probe_cpu_flags() {
    # Se o usuario optou por nao gerar, a etapa esta "feita" por definicao —
    # sem isso o run_step chamaria o do_fn e depois falharia no re-probe.
    [[ "$DESKTOP_SET_CPU_FLAGS" == "yes" ]] || return 0
    # Probe funcional: o arquivo existe E contem a variavel de verdade, em linha
    # nao-comentada. Arquivo vazio ou so com cabecalho nao conta como feito.
    [[ -f "$CPUFLAGS_FILE" ]] || return 1
    grep -vE '^[[:space:]]*#' "$CPUFLAGS_FILE" 2>/dev/null \
        | grep -qE 'CPU_FLAGS_X86='
}

do_cpu_flags() {
    if ! pkg_installed app-portage/cpuid2cpuflags; then
        log_info "instalando app-portage/cpuid2cpuflags (le o CPUID da maquina real)"
        emerge --noreplace app-portage/cpuid2cpuflags \
            || die "falha ao instalar app-portage/cpuid2cpuflags. Se nao quiser gerar CPU_FLAGS_X86, defina DESKTOP_SET_CPU_FLAGS=no em vars-desktop.sh. Veja $LOGFILE."
    fi

    local flags
    flags="$(cpuid2cpuflags 2>/dev/null)" \
        || die "cpuid2cpuflags falhou ao ler o CPUID desta maquina. Veja $LOGFILE."
    [[ -n "$flags" ]] \
        || die "cpuid2cpuflags devolveu saida VAZIA — isso nao e esperado numa CPU x86. Nao gravamos um valor vazio porque isso desligaria silenciosamente todas as otimizacoes. Investigue rodando 'cpuid2cpuflags' a mao."

    # A saida ja vem no formato "CPU_FLAGS_X86: mmx sse ...". O wiki manda gravar
    # como uma linha */* em package.use — aplica a TODOS os pacotes, que e o
    # comportamento desejado para uma propriedade da CPU.
    local line="*/* ${flags}"
    log_info "CPU_FLAGS_X86 detectado nesta maquina: $flags"

    # Aviso, nao erro: a presenca de avx512 e suspeita neste hardware hibrido,
    # mas quem manda e o CPUID real — nao o nosso pressuposto sobre o modelo.
    if [[ "$flags" == *avx512* ]]; then
        log_warn "a saida contem avx512, o que NAO e esperado no i5-12600K (os E-cores Gracemont nao suportam AVX-512). Confira se os E-cores estao habilitados na UEFI antes de compilar o mundo com esta flag."
    fi

    write_managed_file "$CPUFLAGS_FILE" "$line" "10-portage-desktop.sh"
}

# ---------------------------------------------------------------------------
# 10-accept-keywords — destrava SO o que precisa, em arquivo PROPRIO
# ---------------------------------------------------------------------------
#
# Arquivo proprio do modulo (desktop-niri), nunca editando os do instalador.
# Escrevemos APENAS os atoms cuja keyword ~amd64 a pesquisa confirmou. Pacote
# cuja keyword NAO foi confirmada nao ganha ~amd64 preventivo: destravar por
# precaucao e como desligar um alarme porque ele pode tocar. Se algum deles
# estiver de fato mascarado, o portao 10-atoms-resolvable acusa em segundos e
# diz exatamente qual.

gen_keywords() {
    local a
    printf '%s\n' "# Keywords ~amd64 exigidas pelo stack grafico (niri/Wayland)."
    printf '%s\n' "#"
    printf '%s\n' "# gui-wm/niri, gui-apps/fuzzel e gui-apps/xwayland-satellite NAO existem no"
    printf '%s\n' "# ::gentoo (HTTP 404 confirmado nos tres) e vivem no overlay GURU, onde a"
    printf '%s\n' "# unica keyword dos ebuilds e ~amd64. Como o perfil deste sistema e estavel,"
    printf '%s\n' "# sem estas linhas o emerge recusa com 'masked by: ~amd64 keyword'."
    printf '%s\n' "#"
    printf '%s\n' "# Somente atoms VERIFICADOS como ~amd64 entram aqui. Pacote de keyword nao"
    printf '%s\n' "# confirmada nao ganha destrave preventivo — a etapa 10-atoms-resolvable"
    printf '%s\n' "# prova a visibilidade real e aponta o culpado se algo faltar."
    printf '%s\n' ""

    # Os atoms do GURU: todos ~amd64 por construcao do overlay.
    while IFS= read -r a; do
        [[ -n "$a" ]] && printf '%s ~amd64\n' "$a"
    done < <(desktop_atoms_guru)

    # elogind so entra se o usuario escolheu essa rota de seat/sessao. A
    # pesquisa DIVERGIU sobre a keyword dele (uma frente reporta 255.24 como
    # estavel amd64, outra reporta todas as versoes como ~amd64). Diante de
    # informacao conflitante, destravamos: uma keyword a mais num pacote que ja
    # e estavel e inofensiva (o Portage continua preferindo a estavel); a
    # ausencia dela num pacote ~amd64 e um emerge que falha.
    if [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]]; then
        printf '%s\n' ""
        printf '%s\n' "# DESKTOP_SEAT_PROVIDER=elogind: a pesquisa divergiu sobre a keyword estavel"
        printf '%s\n' "# do elogind. Destravar e o lado seguro do erro — se a versao visivel ja for"
        printf '%s\n' "# estavel, esta linha simplesmente nao tem efeito."
        printf '%s\n' "sys-auth/elogind ~amd64"
    fi
}

probe_accept_keywords() {
    # Probe funcional: o arquivo existe E todo atom esperado esta presente numa
    # linha nao-comentada. Comparar so a existencia do arquivo deixaria passar o
    # caso em que o usuario mudou DESKTOP_NOTIFY para swaync depois da primeira
    # execucao — o arquivo existiria, mas sem a linha nova.
    [[ -f "$KEYWORDS_FILE" ]] || return 1

    local a
    while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        grep -vE '^[[:space:]]*#' "$KEYWORDS_FILE" 2>/dev/null \
            | grep -qE "^[[:space:]]*${a//\//\\/}([[:space:]]|$)" || return 1
    done < <(desktop_atoms_guru)

    if [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]]; then
        grep -vE '^[[:space:]]*#' "$KEYWORDS_FILE" 2>/dev/null \
            | grep -qE '^[[:space:]]*sys-auth/elogind([[:space:]]|$)' || return 1
    fi
    return 0
}

do_accept_keywords() {
    write_managed_file "$KEYWORDS_FILE" "$(gen_keywords)" "10-portage-desktop.sh"
}

# ---------------------------------------------------------------------------
# 10-package-use — USE flags do stack (as do NVIDIA ficam na etapa 11)
# ---------------------------------------------------------------------------
#
# ATENCAO CRITICA, verificada no codigo (04-kernel.sh:626-632): o 04 varre TODOS
# os arquivos de /etc/portage/package.use/ e ABORTA a instalacao se encontrar o
# texto do flag de modulo aberto do NVIDIA em linha NAO-COMENTADA. O regex dele
# casa o token isolado por espaco em branco. Portanto NENHUM arquivo escrito por
# este modulo pode conter esse texto fora de um comentario — e, como este
# proprio bloco precisa mencionar o assunto, ele esta todo em linhas iniciadas
# por '#', que a varredura do 04 ignora. Escrever esse flag aqui sabotaria o
# instalador validado, que e exatamente o tipo de dano que a regra 1 proibe.
#
# Igualmente por isso, as USE do driver NAO sao escritas neste arquivo: elas
# pertencem a etapa 11, isoladas, porque package.use/nvidia-drivers e territorio
# do 04 e o conteudo dele muda conforme o ramo do driver.
#
# CADA flag passa por have_use_flag ANTES de ser escrita. Escrever um flag que o
# ebuild nao declara faz o Portage recusar o emerge — e descobrir isso horas
# depois, no meio de uma compilacao, e o custo que esta verificacao evita.

# _use_line <atom> <flag>...: valida cada flag contra o IUSE REAL do ebuild e
# imprime a linha do package.use. Flags negativas ("-systemd") sao validadas
# pelo nome sem o sinal — o que importa e o flag EXISTIR no IUSE; desliga-lo e
# sempre legitimo se ele existe.
_use_line() {
    local atom="$1"; shift
    local flag bare
    for flag in "$@"; do
        bare="${flag#-}"
        have_use_flag "$atom" "$bare" \
            || die "o USE flag '$bare' NAO existe no IUSE de '$atom' nesta versao da arvore. Gravar um flag inexistente em package.use faz o Portage recusar o emerge do stack inteiro. Confira o IUSE real com: portageq metadata / ebuild \$(portageq best_visible / $atom) IUSE"
    done
    printf '%s %s\n' "$atom" "$*"
}

gen_package_use() {
    printf '%s\n' "# USE flags do stack grafico (niri/Wayland) — arquivo PROPRIO do modulo."
    printf '%s\n' "#"
    printf '%s\n' "# As USE do x11-drivers/nvidia-drivers NAO estao aqui: elas vivem na etapa 11,"
    printf '%s\n' "# isoladas, porque package.use/nvidia-drivers e territorio do 04-kernel.sh e"
    printf '%s\n' "# seu conteudo muda conforme o ramo do driver instalado."
    printf '%s\n' "#"
    printf '%s\n' "# Todo flag abaixo foi validado contra o IUSE real do ebuild antes de ser"
    printf '%s\n' "# escrito (have_use_flag), nunca copiado de receita."
    printf '%s\n' ""

    # --- niri -------------------------------------------------------------
    printf '%s\n' "# niri: -systemd NAO e cosmetico, e FUNCIONAL. Com USE=systemd o bloco"
    printf '%s\n' "# 'if ! use systemd' do src_prepare NAO reescreve o resources/niri.desktop, e"
    printf '%s\n' "# o .desktop instalado fica com Exec=niri-session. O script niri-session"
    printf '%s\n' "# upstream detecta systemctl/dinitctl e, sem nenhum dos dois, imprime 'No"
    printf '%s\n' "# systemd or dinit detected' e SAI — a sessao morre no arranque. Em OpenRC o"
    printf '%s\n' "# comando correto e 'dbus-run-session niri --session'."
    printf '%s\n' "#"
    printf '%s\n' "# dbus fica LIGADO sempre: REQUIRED_USE exige 'screencast? ( dbus )', e sem"
    printf '%s\n' "# dbus o proprio comando de arranque do OpenRC deixa de existir."
    local niri_flags=(dbus -systemd)
    [[ "$DESKTOP_ENABLE_SCREENCAST" == "yes" ]] && niri_flags=(dbus screencast -systemd)
    _use_line gui-wm/niri "${niri_flags[@]}"
    printf '%s\n' ""

    # --- waybar -----------------------------------------------------------
    if [[ "$DESKTOP_BAR" == "waybar" ]]; then
        printf '%s\n' "# waybar: a USE=niri e o ponto critico — sem ela a barra sobe mas nao le"
        printf '%s\n' "# workspaces do niri. Ela ja existe na 0.14.0, que e ESTAVEL amd64, entao"
        printf '%s\n' "# nao e preciso destravar a 0.15.0 so por causa disso."
        _use_line gui-apps/waybar niri tray pipewire network -systemd -pulseaudio
        printf '%s\n' ""
    fi

    # --- mako -------------------------------------------------------------
    if [[ "$DESKTOP_NOTIFY" == "mako" ]]; then
        printf '%s\n' "# mako: daemon de notificacoes recomendado pela doc upstream do niri."
        local mako_flags=(icons -systemd)
        # elogind so entra se essa for a rota de sessao escolhida — misturar as
        # duas rotas gera conflito de dependencia.
        [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]] && mako_flags=(icons elogind -systemd)
        _use_line gui-apps/mako "${mako_flags[@]}"
        printf '%s\n' ""
    fi

    # --- fuzzel -----------------------------------------------------------
    if [[ "$DESKTOP_LAUNCHER" == "fuzzel" ]]; then
        printf '%s\n' "# fuzzel: png e svg para renderizar icone de aplicativo no launcher."
        _use_line gui-apps/fuzzel png svg
        printf '%s\n' ""
    fi

    # --- pipewire ---------------------------------------------------------
    if [[ "$DESKTOP_ENABLE_SCREENCAST" == "yes" ]]; then
        printf '%s\n' "# pipewire: sound-server e OBRIGATORIA para ele servir audio de verdade."
        printf '%s\n' "# -system-service porque o proprio ebuild marca essa flag como 'Not"
        printf '%s\n' "# recommended': em OpenRC o PipeWire e servico de USUARIO, nao de sistema."
        local pw_flags=(sound-server pipewire-alsa extra dbus -systemd -system-service)
        [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]] && pw_flags+=(elogind)
        _use_line media-video/pipewire "${pw_flags[@]}"
        printf '%s\n' ""
    fi

    # --- seatd ------------------------------------------------------------
    printf '%s\n' "# seatd: e DEPEND DIRETO do niri (sys-auth/seatd:=), entao entra na maquina"
    printf '%s\n' "# de qualquer forma. O que a escolha controla e QUAL backend a libseat usa."
    if [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]]; then
        printf '%s\n' "# Rota elogind: apenas a libseat com backend logind, SEM o daemon standalone."
        printf '%s\n' "# Ligar 'server' aqui junto com elogind poria dois daemons de seat"
        printf '%s\n' "# concorrentes brigando pelo mesmo recurso."
        _use_line sys-auth/seatd builtin elogind -server
    else
        printf '%s\n' "# Rota seatd puro: builtin E server sao ambos necessarios para o servico"
        printf '%s\n' "# OpenRC funcionar como substituto do (e)logind (wiki Gentoo, Seatd)."
        _use_line sys-auth/seatd builtin server
    fi
    printf '%s\n' ""

    # --- swaylock ---------------------------------------------------------
    # So escrevemos a linha se o pacote for visivel: swaylock nao e instalado
    # por esta etapa e pode nem estar na lista do usuario. Escrever package.use
    # para pacote inexistente nao quebra o Portage, mas have_use_flag morreria.
    if have_atom gui-apps/swaylock >/dev/null 2>&1; then
        printf '%s\n' "# swaylock: SEM USE=pam ele compila normalmente mas voce NAO consegue"
        printf '%s\n' "# destravar a tela — bloqueio permanente da sessao. A flag e +pam por"
        printf '%s\n' "# default; a linha existe para que um -pam acidental nunca passe."
        _use_line gui-apps/swaylock pam gdk-pixbuf
        printf '%s\n' ""
    fi
}

probe_package_use() {
    # O conteudo depende das escolhas de vars-desktop.sh, entao o probe compara
    # o arquivo em disco com o conteudo DESEJADO de agora. Se o usuario trocar
    # DESKTOP_BAR de waybar para none e rodar de novo, o conteudo diverge e a
    # etapa re-executa — que e o comportamento correto.
    #
    # Este probe e barato em I/O mas chama have_use_flag (portageq) via
    # gen_package_use. E o preco de um probe que verifica o conteudo REAL em vez
    # de confiar num marker.
    [[ -f "$PKGUSE_FILE" ]] || return 1
    local desired
    desired="$(_managed_header "10-portage-desktop.sh"; gen_package_use)" || return 1
    [[ "$(cat "$PKGUSE_FILE")" == "$desired" ]]
}

do_package_use() {
    write_managed_file "$PKGUSE_FILE" "$(gen_package_use)" "10-portage-desktop.sh"
}

# ---------------------------------------------------------------------------
# 10-atoms-resolvable — PORTAO
# ---------------------------------------------------------------------------
#
# Esta etapa nao tem "do": ela nao muda nada no sistema. Ela PROVA que tudo que
# as proximas etapas vao emergir e visivel para o Portage AGORA — overlay
# habilitado, keyword aceita, nome de pacote correto.
#
# A razao de existir e economica: falhar aqui custa segundos; falhar na etapa 12
# custa horas de compilacao ja gastas antes de o emerge chegar no atom errado.
# require_atoms acumula TODAS as falhas e morre listando a lista inteira com o
# diagnostico provavel, em vez de o usuario descobrir um problema por vez.

probe_atoms_resolvable() {
    local -a atoms=()
    mapfile -t -O "${#atoms[@]}" atoms < <(desktop_atoms_guru)
    mapfile -t -O "${#atoms[@]}" atoms < <(desktop_atoms_tree)

    # Silencioso de proposito: o probe roda sempre (inclusive na re-execucao em
    # que tudo ja esta certo) e nao deve poluir o log com a lista completa. O
    # relatorio detalhado fica para o do_fn, que so roda quando algo falhou.
    local a
    for a in "${atoms[@]}"; do
        [[ -n "$a" ]] || continue
        have_atom "$a" >/dev/null 2>&1 || return 1
    done
    return 0
}

do_atoms_resolvable() {
    # Chegar aqui significa que o probe reprovou: pelo menos um atom nao resolve.
    # require_atoms loga cada atom resolvido, lista os que faltam e morre com as
    # causas provaveis em ordem (overlay ausente > keyword faltando > nome
    # errado). Nao ha acao corretiva automatica: adivinhar o que o usuario quis
    # dizer e exatamente o que a regra 3 proibe.
    local -a atoms=()
    mapfile -t -O "${#atoms[@]}" atoms < <(desktop_atoms_guru)
    mapfile -t -O "${#atoms[@]}" atoms < <(desktop_atoms_tree)

    log_info "portao de resolucao: verificando ${#atoms[@]} atoms do stack escolhido"
    require_atoms "${atoms[@]}"
}

# ---------------------------------------------------------------------------
# Execucao
# ---------------------------------------------------------------------------
#
# Ordem deliberada: o overlay tem de existir antes de qualquer probe que consulte
# atom do GURU (keywords e package.use consultam o IUSE via portageq, o que exige
# o ebuild em disco), e o portao vem por ultimo porque so faz sentido depois de
# keywords e USE escritas.

log_info "etapa 10: preparando o Portage para o stack grafico (nenhum pacote do desktop e instalado aqui)"

# Sob --dry-run paramos AQUI. Tudo acima e leitura (definicao das funcoes e dos
# caminhos de /etc/portage); a primeira escrita real vem do do_guru_repo logo
# abaixo, que faz `emerge --noreplace app-eselect/eselect-repository`.
dry_run_guard 10-guru-repo 10-cpu-flags 10-accept-keywords 10-package-use 10-atoms-resolvable

run_step 10-guru-repo        probe_guru_repo        do_guru_repo
run_step 10-cpu-flags        probe_cpu_flags        do_cpu_flags
run_step 10-accept-keywords  probe_accept_keywords  do_accept_keywords
run_step 10-package-use      probe_package_use      do_package_use
run_step 10-atoms-resolvable probe_atoms_resolvable do_atoms_resolvable

log_info "etapa 10 concluida: overlay habilitado, keywords e USE escritas, todos os atoms resolvem."
log_info "proxima etapa: 11-nvidia-wayland (liga USE=wayland no driver ANTES de instalar o compositor)."
