#!/usr/bin/env bash
# vars-desktop.sh — variaveis editaveis do MODULO DE DESKTOP (niri + Wayland).
#
# Este arquivo e APENAS sourced (nunca executado) — por isso nao tem `set -e`
# nem logica alguma; somente atribuicoes com defaults, exatamente como vars.sh.
# A forma `: "${VAR:=default}"` permite override por variavel de ambiente:
#   DESKTOP_USER=rodrigo ./install-desktop.sh
#
# ESCOPO: este modulo e ADITIVO ao instalador base (00-06). Ele NAO modifica
# nenhum arquivo do instalador; escreve apenas em arquivos PROPRIOS dentro de
# /etc/portage/*.d/ (o Portage faz a uniao dos arquivos do diretorio) e em
# $HOME do usuario alvo. Nunca formata, nunca reparticiona, nunca remove
# pacote do usuario.
#
# FASE: o modulo SO roda no sistema JA INSTALADO E BOOTADO. A guarda
# require_booted_system() (lib-desktop.sh) recusa live ISO e chroot com
# deteccao positiva e fail-closed. Edite os valores abaixo ANTES de rodar
# ./install-desktop.sh, ja com o sistema bootado do disco.

# ---------------------------------------------------------------------------
# Compatibilidade com o lib.sh do instalador (NAO REMOVA)
# ---------------------------------------------------------------------------
#
# DESCOBERTA CRITICA, verificada lendo lib.sh:
#
#   current_phase() (lib.sh:46) retorna "chroot" apenas se existe a sentinela
#   $CHROOT_SENTINEL (/etc/gentoo-install/.inside-chroot). No sistema BOOTADO
#   essa sentinela NAO existe — o install.sh a remove ao sair do chroot —
#   entao current_phase() reporta "live".
#
#   Consequencia: state_dir() (lib.sh:480), no ramo "live", devolve
#   "$TARGET_ROOT/var/lib/gentoo-install/state". Com o TARGET_ROOT default do
#   vars.sh (/mnt/gentoo) isso resolveria para
#   /mnt/gentoo/var/lib/gentoo-install/state — caminho que NAO existe no
#   sistema bootado. run_step, mark_done e step_done gravariam no lugar errado
#   e o modulo perderia idempotencia (todo run rodaria tudo de novo).
#
# SOLUCAO, sem tocar UMA LINHA do lib.sh (regra 1 preservada): exportamos
# TARGET_ROOT VAZIO. Com string vazia, o ramo "live" de state_dir() concatena
# "" + "/var/lib/gentoo-install/state" e devolve o caminho CORRETO do sistema
# bootado. run_step/mark_done/step_done/svc_enable passam a funcionar sem
# alteracao nenhuma no instalador.
#
# O modulo tambem NUNCA chama require_phase() — ela mataria o script. A guarda
# de fase do modulo e require_booted_system(), que e mais estrita e positiva.
#
# Este export precisa acontecer ANTES do source do ../lib.sh. Como este
# arquivo e sempre sourced primeiro, e aqui que ele mora.
#
# ATENCAO: nao troque `=` por `:=` aqui. Precisamos FORCAR o vazio mesmo se o
# ambiente (ou um vars.sh sourced antes) ja tiver TARGET_ROOT=/mnt/gentoo.
export TARGET_ROOT=""

# ---------------------------------------------------------------------------
# Identidade / alvo
# ---------------------------------------------------------------------------

# Usuario alvo que recebe os dotfiles, os grupos e a sessao grafica.
#
# Default VAZIO de proposito, COM DETECCAO em runtime. O modulo tenta, nesta
# ordem: (1) ler o valor registrado pelo marker de state do 06; (2) achar o
# UNICO usuario com UID >= 1000 em /etc/passwd. Se encontrar ZERO ou MAIS DE
# UM, o modulo MORRE pedindo o valor explicito.
#
# Nunca assumimos "gentoo" (o default do vars.sh) porque o usuario real quase
# certamente trocou esse valor na instalacao — e escrever dotfiles no $HOME
# errado seria uma falha silenciosa das mais caras de diagnosticar.
: "${DESKTOP_USER:=}"

# Home do usuario alvo. Default vazio: e DERIVADO de `getent passwd` em
# runtime, nunca montado a mao como /home/$user. Home pode estar em outro
# caminho e um palpite errado escreveria config num diretorio que ninguem le.
: "${DESKTOP_USER_HOME:=}"

# ---------------------------------------------------------------------------
# Escolhas de stack
# ---------------------------------------------------------------------------
#
# Tudo que a pesquisa deixou EM ABERTO virou variavel aqui, com o default
# justificado — em vez de virar chute enterrado no meio de um script.

# Provedor de seat/sessao: seatd | elogind
#
# Default "seatd", e a justificativa importa:
#   - sys-auth/seatd 0.9.3-r1 e ESTAVEL amd64 e e DEPEND DIRETO do niri
#     (o ebuild declara sys-auth/seatd:=), entao ele entra na maquina de
#     qualquer jeito.
#   - sys-auth/elogind teve informacao DIVERGENTE entre as frentes de pesquisa
#     (uma reporta 255.24 como estavel amd64, outra reporta TODAS as versoes
#     como ~amd64). Nao da para tratar isso como fato. O modulo verifica em
#     runtime com `portageq best_visible` antes de qualquer emerge.
#
# CUSTO REAL DO DEFAULT (leia antes de aceitar): seatd resolve APENAS seat
# management. Ele NAO cria XDG_RUNTIME_DIR, e sys-auth/polkit NAO tem backend
# seatd (as unicas opcoes de session tracking do ebuild sao elogind ou
# systemd). Com "seatd" o modulo cria XDG_RUNTIME_DIR por outro meio e o
# polkit fica DEGRADADO: montar disco removivel pelo gerenciador de arquivos e
# suspender/desligar pelo menu tendem a pedir senha de root ou simplesmente
# nao funcionar.
#
# Quem quer desktop COMPLETO (automount, suspend, polkit funcional) troca para
# "elogind" — conscientemente, sabendo que pode exigir package.accept_keywords
# e que as USE flags de waybar (logind), mako (elogind) e pipewire (elogind)
# precisam ser coerentes com a escolha. NAO instale os dois: sao solucoes
# concorrentes e dois daemons de seat brigam pelo mesmo recurso.
: "${DESKTOP_SEAT_PROVIDER:=seatd}"

# Terminal: foot | alacritty | kitty
#
# Default "foot" por um motivo tecnico, nao por gosto: o foot renderiza em CPU
# via pixman e NAO abre contexto EGL/GL. Ele nao depende do caminho EGL/GBM da
# NVIDIA — que e exatamente o subsistema que este projeto NUNCA validou (o
# driver foi compilado no QEMU, que nao tem GPU).
#
# alacritty e kitty sao GPU-accelerated e sao os PRIMEIROS a falhar se o EGL
# estiver errado. O terminal e a ferramenta de RECUPERACAO: ele nao pode
# depender do subsistema que estamos testando. Se o niri subir e o foot
# funcionar, voce tem um terminal para diagnosticar o resto.
#
# A rice de referencia usa KITTY, entao kitty e o default aqui.
#
# Mas a referencia roda num Apple M2 com Asahi, onde o caminho GPU e conhecido
# e estavel — nao numa Blackwell com driver proprietario que este projeto nunca
# viu funcionar. Por isso o modulo instala TAMBEM o terminal de recuperacao
# abaixo, e o amarra a um atalho proprio. Um terminal a mais custa segundos de
# compilacao; ficar sem terminal numa sessao grafica que subiu pela metade
# custa um reboot as cegas.
: "${DESKTOP_TERMINAL:=kitty}"

# Terminal de RECUPERACAO, sempre instalado alem do principal: foot | none
#
# foot renderiza em CPU via pixman e NAO abre contexto EGL/GL. Ele nao depende
# do caminho EGL/GBM da NVIDIA — que e exatamente o subsistema nunca validado
# neste projeto (o driver foi compilado no QEMU, que nao tem GPU).
# kitty e alacritty sao GPU-accelerated e sao os PRIMEIROS a falhar se o EGL
# estiver errado: abrem preto, ou nao abrem.
#
# Se o kitty nao abrir, use o atalho do terminal de recuperacao (ver
# DESKTOP_BIND_RECOVERY_TERM) e diagnostique de dentro da sessao, em vez de
# reiniciar no escuro.
: "${DESKTOP_RECOVERY_TERMINAL:=foot}"

# ---------------------------------------------------------------------------
# Aparencia (a "rice")
# ---------------------------------------------------------------------------

# Ferramenta de papel de parede: swaybg | none
#
# O niri NAO desenha fundo: sem um cliente de wallpaper a area vaga fica PRETA.
# swaybg e o mais simples e nao usa GPU alem do necessario.
# (gui-apps/swww, mais bonito por causa das transicoes, NAO existe no ::gentoo —
# verificado; entao nao e oferecido aqui.)
: "${DESKTOP_WALLPAPER_TOOL:=swaybg}"

# Caminho da imagem de papel de parede. VAZIO = usa apenas a cor solida.
#
# A imagem NAO acompanha este repositorio, e nao vai acompanhar: e obra de um
# artista publicada no Pixiv, sem licenca de redistribuicao. Baixar para uso
# proprio e uma coisa; embutir num repositorio publico e outra.
#
# A rice de referencia usa esta:
#   Pagina do artista: https://www.pixiv.net/en/artworks/115453639  (imagem p4)
#
# O DESKTOP_WALLPAPER_URL abaixo automatiza o download para o SEU disco.
#
# VAZIO (default) = a etapa 14 usa $HOME/.local/share/wallpapers/gentoo-chan.png,
# com o $HOME DERIVADO do getent em runtime. Nao montamos o caminho aqui porque
# DESKTOP_USER_HOME so e resolvido depois — interpolar agora daria "/.local/...".
: "${DESKTOP_WALLPAPER:=}"

# Nome do arquivo dentro de ~/.local/share/wallpapers/ quando DESKTOP_WALLPAPER
# esta vazio e ha URL para baixar.
: "${DESKTOP_WALLPAPER_NAME:=gentoo-chan.png}"

# URL para baixar o wallpaper, se ele ainda nao existir no caminho acima.
# VAZIO = nao baixa nada (voce coloca o arquivo a mao).
#
# ARMADILHA do Pixiv: o i.pximg.net RECUSA hotlink. Um wget/curl direto devolve
# 403 Forbidden. E preciso mandar o cabecalho `Referer: https://www.pixiv.net/`,
# o que a etapa 14 faz. Nao adianta colar a URL no navegador e esperar que um
# download simples funcione.
: "${DESKTOP_WALLPAPER_URL:=https://i.pximg.net/img-original/img/2024/01/31/22/22/27/115453639_p4.png}"

# Modo de escala do swaybg: fill | fit | stretch | center | tile
# "fill" preserva proporcao e cobre a tela (recorta o excedente).
: "${DESKTOP_WALLPAPER_MODE:=fill}"

# Cor de fundo usada quando nao ha wallpaper, ou nas bordas com mode=fit.
# Default = base do Catppuccin Mocha, para nao dar preto puro na tela.
: "${DESKTOP_WALLPAPER_COLOR:=1e1e2e}"

# Cantos arredondados das janelas, em pixels. 0 desliga.
# Sintaxe verificada no default-config.kdl do upstream do niri:
# window-rule { geometry-corner-radius N; clip-to-geometry true }
: "${DESKTOP_CORNER_RADIUS:=12}"

# fastfetch: e a peca central do terminal na rice de referencia. (yes|no)
: "${DESKTOP_INSTALL_FASTFETCH:=yes}"

# neovim: a referencia usa. Desligue se voce ja tem o seu editor. (yes|no)
: "${DESKTOP_INSTALL_NEOVIM:=no}"

# ---------------------------------------------------------------------------
# Shell
# ---------------------------------------------------------------------------

# Shell do usuario: zsh | keep
#
# A rice de referencia usa zsh. "keep" nao mexe no shell atual.
#
# Se voce escolher zsh, o modulo instala app-shells/zsh e
# app-shells/gentoo-zsh-completions (completion de emerge/eselect/rc-service,
# que e metade do valor de zsh num Gentoo) e troca o shell do usuario.
#
# O login do ROOT nunca e alterado. Trocar o shell do root e como se perde o
# acesso a um sistema quando o shell novo nao sobe por qualquer motivo.
: "${DESKTOP_SHELL:=zsh}"

# Rodar fastfetch ao abrir um shell interativo? (yes|no)
# E o que produz a tela da rice de referencia ao abrir o terminal.
: "${DESKTOP_FASTFETCH_ON_LOGIN:=yes}"

# Lancador de aplicativos: fuzzel
#
# ---------------------------------------------------------------------------
# Sentinelas de intencao do operador
# ---------------------------------------------------------------------------
#
# Gravadas AQUI, antes de qualquer ': "${VAR:=default}"', e a ordem e
# load-bearing: o ':=' ATRIBUI a variavel, e depois dele '${VAR+x}' esta sempre
# setado. Ou seja, dali para a frente nao ha mais como distinguir "o operador
# escolheu waybar" de "o default e waybar".
#
# Essa distincao e o que faz a derivacao do Clavis (fim deste arquivo) ser
# segura: ela so desliga barra e notificacoes quando o operador NAO opinou.
# Errar isto tem dois desfechos, e um deles e ruim: a derivacao nunca disparar
# (o recurso nao funciona, mas nada quebra) ou disparar sempre (ignora a
# escolha explicita do operador, que e o modo perigoso).
_DESKTOP_BAR_SET="${DESKTOP_BAR+1}"
_DESKTOP_NOTIFY_SET="${DESKTOP_NOTIFY+1}"

# gui-apps/fuzzel vive no overlay GURU (~amd64) — NAO existe no ::gentoo
# (HTTP 404 confirmado). E o launcher recomendado pelo proprio ebuild do niri
# (optfeature "Application launcher") e o binario referenciado no bind default
# Mod+D do config KDL. Sem ele, o bind falha em silencio.
: "${DESKTOP_LAUNCHER:=fuzzel}"

# Barra de status: waybar | none
#
# Default "waybar": a 0.14.0 e ESTAVEL amd64 e JA TEM a USE=niri (modulos
# nativos de workspaces/window do niri) — nao e preciso destravar a 0.15.0.
# ARMADILHA: sem USE=niri a barra sobe mas nao mostra workspace nenhum.
#
# Use "none" se preferir sessao sem barra. Atencao: a doc upstream indica que
# o config default do niri ja faz spawn de waybar; se voce escolher "none",
# o config.kdl que o modulo escreve NAO deve declarar esse spawn, senao gera
# erro de spawn no log a cada boot — ruido que confunde o diagnostico.
: "${DESKTOP_BAR:=waybar}"

# Daemon de notificacoes: mako | none | swaync
#
# Default "mako": gui-apps/mako 1.11.0 e ESTAVEL no ::gentoo e e o daemon
# recomendado pela doc upstream do niri.
#
# "swaync" so se voce quiser a central/painel de historico de notificacoes.
# Custo alto: vive no GURU (~amd64) e arrasta GTK4, Vala, Granite, libadwaita,
# libhandy, sassc e gui-libs/gtk4-layer-shell (que NAO tem versao estavel).
# Numa maquina que compila do zero isso e muito tempo de emerge por um ganho
# que o mako ja entrega em boa parte.
: "${DESKTOP_NOTIFY:=mako}"

# Habilitar screencast/screenshare? (yes|no)
#
# yes (default) liga USE=screencast no niri. Consequencias verificadas no
# ebuild: puxa media-video/pipewire (DEPEND) e sys-apps/xdg-desktop-portal-gnome
# (RDEPEND), e exige llvm-core/clang no BDEPEND (bindgen).
#
# CUSTO: se a maquina ainda nao tem clang, isso adiciona uma compilacao pesada
# e inesperada. O i5-12600K aguenta, mas o tempo surpreende quem nao esperava.
#
# REQUIRED_USE do ebuild: screencast? ( dbus ). O modulo NUNCA desliga dbus —
# alem de abortar o emerge no pkg_pretend, dbus e o que faz o comando de
# arranque em OpenRC existir (dbus-run-session).
: "${DESKTOP_ENABLE_SCREENCAST:=yes}"

# Habilitar suporte a aplicativos X11? (yes|no)
#
# yes (default) instala gui-apps/xwayland-satellite (GURU, ~amd64) e declara
# `spawn-at-startup "xwayland-satellite"` no config.kdl.
#
# ATENCAO: o niri NAO tem Xwayland embutido e NAO integra o satellite sozinho.
# Instalar o pacote NAO basta — sem a linha de spawn no config, NENHUM app X11
# abre (inclui muitos jogos e Electron antigo).
: "${DESKTOP_ENABLE_XWAYLAND:=yes}"

# Display manager: none | greetd
#
# Default "none", e isso e uma decisao de ordem de validacao: valida-se a
# sessao direto do TTY com `dbus-run-session niri --session` PRIMEIRO. So
# depois que a sessao comprovadamente sobe e que faz sentido acrescentar um DM.
#
# greetd tem duas pegadinhas documentadas no Gentoo:
#   1. gui-libs/greetd NAO instala init script OpenRC proprio. Quem fornece o
#      servico (chamado "display-manager") e gui-libs/display-manager-init.
#      `rc-update add greetd default` simplesmente NAO EXISTE.
#   2. problema conhecido com XDG_RUNTIME_DIR — o elogind nao o define para o
#      greetd, que precisa defini-lo duas vezes (usuario greeter e usuario real).
#
# Adicionar um DM antes de a sessao subir mistura sintoma de DM com sintoma de
# compositor e envenena o diagnostico.
: "${DESKTOP_GREETER:=none}"

# ---------------------------------------------------------------------------
# Acoes de alto risco (opt-in — default NAO)
# ---------------------------------------------------------------------------
#
# Estas duas mexem no sistema JA VALIDADO e demoram HORAS. Ficam isoladas no
# script 10a-profile-world.sh, desligadas por default. Rodar o modulo "para
# instalar o niri" nao pode disparar recompilacao geral sem o usuario pedir.
#
# Se forem usadas, tem de rodar ANTES do 11-nvidia-wayland: trocar para o
# perfil 23.0/desktop liga USE=wayland GLOBALMENTE e o -uDN @world ja
# reconstroi o nvidia-drivers de tabela. Fazer 10a DEPOIS do 11 recompilaria o
# driver NVIDIA duas vezes.

# Trocar o perfil para default/linux/amd64/23.0/desktop? (yes|no)
#
# O instalador base deixa o perfil default/linux/amd64/23.0 SEM sufixo
# /desktop, e o bloco USE do make.conf VAZIO. O perfil desktop herda
# targets/desktop, que ja traz wayland, X, elogind, dbus, policykit, pipewire,
# screencast, vulkan, opengl, dri, sound, udev e upower — praticamente todo o
# conjunto que este modulo precisaria escrever a mao.
#
# O wiki e categorico: perfis desktop devem ser usados em qualquer instalacao
# grafica, e nao usa-los leva a "heavy setup and maintenance burden".
#
# CUSTO E IRREVERSIBILIDADE: trocar de perfil num sistema instalado exige
# `emerge -uDN @world` completo, e VOLTAR ATRAS exige outro @world completo.
# Nao ha estimativa honesta de duracao — rode com -p/--pretend antes e conte os
# pacotes. Faca backup, como o wiki recomenda para mudancas de sistema.
: "${DESKTOP_SWITCH_PROFILE:=no}"

# Rodar `emerge -uDN @world`? (yes|no)
#
# Obrigatorio DEPOIS de trocar o perfil (senao os pacotes ficam construidos com
# o USE antigo e o sistema fica num estado meio-termo). Tambem util sozinho,
# mas demorado. Default "no" pelo mesmo motivo do UPDATE_WORLD do vars.sh.
: "${DESKTOP_UPDATE_WORLD:=no}"

# Gerar CPU_FLAGS_X86 com app-portage/cpuid2cpuflags? (yes|no)
#
# Default "yes" — esta e barata e segura, por isso e a unica acao "de ajuste"
# ligada por default. Instala app-portage/cpuid2cpuflags (estavel amd64), roda
# o binario na maquina REAL e grava a saida em package.use/00cpu-flags.
#
# CPU_FLAGS_X86 nao e o mesmo que CFLAGS: CFLAGS apenas PERMITEM que o
# compilador gere instrucoes; CPU_FLAGS_X86 faz o ebuild compilar assembly
# escrito a mao ja otimizado. Uma coisa nao substitui a outra.
#
# O valor TEM de ser gerado na maquina alvo — nunca copiado de tabela. Nota
# sobre o i5-12600K: e Alder Lake HIBRIDO (P-cores Golden Cove + E-cores
# Gracemont); como os E-cores nao tem AVX-512, o conjunto efetivo e o
# denominador comum e AVX-512 nao deve aparecer na saida.
: "${DESKTOP_SET_CPU_FLAGS:=yes}"

# Pular as confirmacoes interativas das acoes caras? (yes|no)
#
# Default "no". Com "yes", troca de perfil e @world rodam sem perguntar — use
# apenas em automacao, onde voce ja sabe o que vai acontecer. Nao afeta
# nenhuma guarda de fase: require_booted_system() NUNCA e pulavel.
: "${DESKTOP_ASSUME_YES:=no}"

# ---------------------------------------------------------------------------
# Aparencia (aplicada so no 14, depois de a sessao funcionar)
# ---------------------------------------------------------------------------
#
# Prioridade explicita do projeto: estetica so importa se a sessao sobe.
# Escrever tema num sistema onde o compositor nao inicia e desperdicio e ainda
# mistura sintoma de tema com sintoma de compositor.

# Paleta de cores aplicada aos configs de niri, waybar, fuzzel e terminal.
#
# Default "catppuccin-mocha". A justificativa e boa: NAO existe pacote
# catppuccin no ::gentoo — e isso e uma VANTAGEM, nao um problema. A paleta e
# so uma lista de hex escrita nos arquivos de config que o modulo ja vai gerar
# de qualquer forma. Resultado: zero overlay novo, zero ~amd64, zero
# dependencia de um pacote de tema que pode quebrar num update.
#
# Hex da variante Mocha (escura), especificacao oficial:
#   base #1e1e2e | text #cdd6f4 | mauve #cba6f7 | surface0 #313244 | crust #11111b
: "${DESKTOP_PALETTE:=catppuccin-mocha}"

# Tema e tamanho do cursor.
#
# "Adwaita" vem de x11-themes/adwaita-icon-theme (estavel amd64), que instala
# os cursores no caminho upstream /usr/share/icons/Adwaita/cursors — que e
# onde compositores Wayland procuram. Temas de cursor antigos do x11-themes
# (os *-xcursors) podem cair no descasamento historico de caminho e deixar o
# cursor invisivel ou deslocado.
#
# VALOR UNICO, REUSADO EM TRES LUGARES: gsettings
# (org.gnome.desktop.interface cursor-theme/cursor-size), o bloco
# `cursor { xcursor-theme ...; xcursor-size ... }` do config.kdl do niri, e o
# ambiente da sessao. Divergencia entre os tres e a causa do sintoma classico
# de cursor que muda de tamanho/forma ao cruzar de uma janela para outra.
: "${DESKTOP_CURSOR_THEME:=Adwaita}"
: "${DESKTOP_CURSOR_SIZE:=24}"

# Fontes. media-fonts/fira-code (monoespacada com ligaduras) e media-fonts/noto
# (sans de cobertura ampla) sao ambas ESTAVEIS amd64 no ::gentoo.
#
# Os icones da waybar NAO vem de uma fonte repatcheada: vem de
# media-fonts/symbols-nerd-font (estavel amd64), configurada no fontconfig como
# FALLBACK sobre a mono. ATENCAO ao atom: "media-fonts/nerd-fonts" NAO EXISTE
# no ::gentoo (404 confirmado) — so em overlays de terceiros.
: "${DESKTOP_FONT_MONO:=Fira Code}"
: "${DESKTOP_FONT_UI:=Noto Sans}"

# ---------------------------------------------------------------------------
# Overlay
# ---------------------------------------------------------------------------

# Nome do overlay onde vivem niri, fuzzel, xwayland-satellite (e swaync, se
# escolhido). Habilitado via app-eselect/eselect-repository.
#
# Este e o passo 0 obrigatorio do modulo: gui-wm/niri, gui-apps/fuzzel e
# gui-apps/xwayland-satellite NAO existem no ::gentoo — HTTP 404 confirmado em
# packages.gentoo.org para os tres. Sem o overlay habilitado, o primeiro emerge
# falha com "no ebuilds to satisfy".
#
# DECISAO CONSCIENTE: o GURU e um overlay mantido pela comunidade, SEM o QA
# oficial do Gentoo, e todo o material dele esta em ~amd64. Estamos aceitando
# isso porque nao ha alternativa no ::gentoo para o compositor escolhido.
#
# O probe da etapa 10 deve testar `portageq get_repo_path / guru` — o estado
# REAL do Portage — e nunca apenas a existencia de um marker.
: "${DESKTOP_GURU_REPO:=guru}"

# ---------------------------------------------------------------------------
# Limiares de espaco em disco (preflight)
# ---------------------------------------------------------------------------

# Consumidos por check_disk_space() no install-desktop.sh. Sao AVISOS, nunca
# die: o modulo e retomavel e o usuario pode estar liberando espaco em paralelo;
# abortar por uma leitura de df seria pior que avisar e deixar decidir.
#
# Os numeros nao sao estimativa de "tamanho do desktop" (nao ha numero publicado
# confiavel para isso): sao o piso abaixo do qual um build de fonte grande
# (niri em Rust, xwayland-satellite com clang, e llvm/qt6 num @world de desktop)
# tem risco alto de morrer com "No space left on device" no meio.
#
# /var/tmp/portage e onde o Portage compila (PORTAGE_TMPDIR). Se ele estiver no
# mesmo filesystem de /, a checagem reporta o mesmo numero duas vezes — o que e
# a verdade, e nao um bug.
: "${DESKTOP_MIN_FREE_ROOT_GIB:=10}"
: "${DESKTOP_MIN_FREE_TMP_GIB:=15}"

# ---------------------------------------------------------------------------
# Clavis Shell (etapa 16)
# ---------------------------------------------------------------------------

# Instalar o Clavis Shell? (yes|no)
#
# O Clavis (StatIndet/quickshell) e um shell Quickshell completo para niri:
# barra, notificacoes, launcher, settings center e tema dinamico por matugen.
# E o rice de referencia deste modulo.
#
# ELE SUBSTITUI a barra e o daemon de notificacoes. Com DESKTOP_CLAVIS=yes,
# DESKTOP_BAR e DESKTOP_NOTIFY sao DERIVADOS para 'none' no fim deste arquivo —
# mas so se voce nao os tiver definido. Escolha explicita sempre vence.
#
# O mako sair NAO e economia, e correcao: ele e o servidor de notificacoes do
# Clavis disputam o nome org.freedesktop.Notifications no D-Bus de sessao, que
# e unico. Quem sobe primeiro ganha, e a ordem nao e deterministica entre
# logins. Se o mako ganha, o Clavis nao morre — o painel de notificacoes dele
# so fica permanentemente vazio, sem erro visivel.
#
# O FUZZEL CONTINUA INSTALADO, e isso e deliberado. O Clavis tem spotlight
# proprio e o Mod+D passa a chama-lo, mas o fuzzel ganha um bind de resgate em
# Mod+Shift+Space. Ele nao e daemon, nao registra nome no D-Bus e nao roda ate
# ser invocado — nao ha o que disputar, o custo em runtime e zero, e ele e a
# unica rota grafica que nao compartilha ponto de falha nenhum com o Clavis
# (nem IPC, nem venv, nem symlink no PATH, nem o shell estar vivo).
#
# 'no' e OMISSAO, nunca remocao: nada e instalado e nada existente e desfeito,
# e o caminho sem Clavis fica identico ao que era antes desta variavel existir.
: "${DESKTOP_CLAVIS:=yes}"

# De onde vem o Clavis, e em que ponto da historia.
#
# O DEFAULT NAO E UM BRANCH MOVEL, e isso e deliberado. A descricao do
# repositorio upstream e literalmente "Works on my machine." e o README diz
# "under active development". Apontar para 'main' significa que duas execucoes
# do instalador em dias diferentes produzem sistemas diferentes — o oposto do
# que este projeto persegue. Fixe uma tag e suba quando VOCE decidir.
#
# Para ver o que existe:  git ls-remote --tags $DESKTOP_CLAVIS_URL
: "${DESKTOP_CLAVIS_URL:=https://github.com/StatIndet/quickshell}"
: "${DESKTOP_CLAVIS_REF:=main}"

# Onde o checkout vive. Fica no HOME porque quem COMPILA e o usuario: compilar
# como root deixaria a build-tree e o cache do Qt com dono root dentro do HOME,
# que e a forma silenciosa de quebrar a sessao seguinte.
: "${DESKTOP_CLAVIS_SRC:=${HOME:-/home/$USERNAME}/src/clavis-shell}"

# key-cli: o comando `key`, que e o que efetivamente inicia o shell.
#
# Instalado num venv dedicado com symlink em /usr/local/bin, e nao com pip:
# o Gentoo marca o interpretador do sistema como EXTERNALLY-MANAGED (PEP 668),
# o `pip --user` fica versionado pelo minor do Python (um `eselect python set`
# faria o comando sumir do PATH), e dev-python/pipx NAO existe na arvore.
: "${DESKTOP_CLAVIS_KEY_URL:=https://github.com/StatIndet/key-cli}"
: "${DESKTOP_CLAVIS_KEY_REF:=main}"
: "${DESKTOP_CLAVIS_KEY_VENV:=/opt/clavis/key-cli}"

# keytop: monitor de sistema que alimenta os graficos de CPU/GPU do shell.
#
# OPCIONAL de verdade: o SystemMonitorService do Clavis trata a ausencia dele
# com mensagem e o resto do shell funciona inteiro. A etapa 16 nao morre se a
# compilacao dele falhar — perder os graficos custa muito menos que ficar sem
# sessao grafica.
: "${DESKTOP_CLAVIS_KEYTOP:=yes}"
: "${DESKTOP_CLAVIS_KEYTOP_URL:=https://github.com/StatIndet/keytop}"
: "${DESKTOP_CLAVIS_KEYTOP_REF:=main}"
: "${DESKTOP_CLAVIS_KEYTOP_SRC:=${HOME:-/home/$USERNAME}/src/clavis-keytop}"

# ---------------------------------------------------------------------------
# Derivacao: o Clavis desliga o que ele substitui
# ---------------------------------------------------------------------------
#
# Precisa vir DEPOIS de todos os ': "${VAR:=default}"' — ele age sobre valores
# ja resolvidos — e usa as sentinelas gravadas no topo, nao o valor atual.
#
# DESKTOP_LAUNCHER NAO entra aqui de proposito: ver o comentario de
# DESKTOP_CLAVIS. O fuzzel fica como rede de seguranca.
if [[ "$DESKTOP_CLAVIS" == "yes" ]]; then
    [[ -n "$_DESKTOP_BAR_SET" ]]    || DESKTOP_BAR=none
    [[ -n "$_DESKTOP_NOTIFY_SET" ]] || DESKTOP_NOTIFY=none
fi
unset _DESKTOP_BAR_SET _DESKTOP_NOTIFY_SET
