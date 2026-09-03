#!/usr/bin/env bash
# 15-validate.sh — PROVA, antes do reboot, que a sessao grafica tem o que precisa.
#
# Fase: sistema JA INSTALADO E BOOTADO (regra 2). Nunca no live ISO, nunca no
# chroot da instalacao — require_booted_system() recusa, fail-closed.
#
# POR QUE ESTA ETAPA EXISTE, e por que ela roda ANTES da 14 (ver ORDEM_ETAPAS no
# install-desktop.sh: 10 -> 11 -> 12 -> 13 -> 15 -> 14):
#
#   1. O RUNTIME DA NVIDIA NUNCA FOI VALIDADO NESTE PROJETO. O nvidia-drivers foi
#      COMPILADO durante a instalacao, mas a instalacao inteira foi validada em
#      QEMU — e QEMU nao tem GPU. Ninguem jamais viu esse driver INICIALIZAR
#      nesta maquina. Este script e a primeira vez que alguem confere.
#
#   2. O modo de falha caro deste modulo nao e "erro na tela". E o silencio: o
#      usuario reinicia, digita 'dbus-run-session niri --session', a tela pisca e
#      ele volta ao TTY sem UMA linha de explicacao. A partir dali o diagnostico
#      e caro, porque as causas plausiveis (EGL ausente, seat, dbus, grupos,
#      XDG_RUNTIME_DIR) sao invisiveis e produzem exatamente o MESMO sintoma.
#
#   Falhar AQUI, com o TTY ainda funcionando e uma mensagem acionavel, e
#   incomparavelmente melhor que uma tela preta sem console para diagnosticar.
#
# SUB-ETAPAS (run_step, cada uma com probe FUNCIONAL — nunca so o marker):
#   15-check-egl           : o caminho EGL/GBM da NVIDIA, nvidia_drm, modeset, DRM
#   15-check-seat          : seat e dbus de pe, grupos, XDG_RUNTIME_DIR, audio
#   15-check-session-files : .desktop com Exec correto, binarios, config.kdl
#   15-report              : veredicto final + o que observar no primeiro boot
#
# SOBRE run_step NUMA ETAPA DE VALIDACAO — a ressalva que o codigo resolve:
# run_step foi feito para MUTACAO idempotente: ele grava marker e PULA o trabalho
# quando o probe passa. Validacao e o oposto — precisa reexecutar sempre, porque
# o estado muda entre uma rodada e outra (e provar que mudou e o objetivo).
# A conciliacao esta nos probes: TODOS medem o sistema REAL a cada chamada e
# NENHUM consulta step_done. Quando um probe passa, o trabalho ja esta feito de
# fato e nao ha o que reexecutar; quando reprova, o do_fn roda e imprime a
# tabela. O marker vira registro do ultimo resultado conhecido, nunca autoridade.
#
# POR QUE ACUMULA FALHAS EM VEZ DE MORRER NA PRIMEIRA:
# um validador que aborta no primeiro problema obriga o ciclo "conserta, roda de
# novo, descobre o proximo". Como cada rodada aqui e barata e as falhas costumam
# vir em grupo (esquecer a 13 inteira derruba seat, dbus e grupos de uma vez),
# reportar TODAS de uma vez e o que economiza tempo. Mesmo padrao do
# require_atoms (lib-desktop.sh) e da tabela do preflight_hardware (lib.sh).
#
# O QUE ESTE SCRIPT DELIBERADAMENTE NAO FAZ:
#   - nao toca em NENHUM arquivo do instalador base (regra 1)
#   - NAO CONSERTA NADA: quem instala e a 12, quem habilita e a 13. Um validador
#     que conserta esconde justamente o que deveria mostrar, e passa a mascarar a
#     etapa quebrada em vez de denuncia-la. Na proxima execucao voce ja nao sabe
#     se o sistema estava certo ou se foi o script que o consertou.
#   - nao inicia servico, nao instala pacote, nao escreve em $HOME (regra 4)
#   - nao tenta iniciar o compositor: isso derrubaria o TTY de quem esta rodando
#   - nao valida a gramatica KDL do config (ver o comentario em check_niri_config)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib-desktop.sh ja faz, nesta ordem: TARGET_ROOT="" -> vars.sh -> lib.sh ->
# vars-desktop.sh. O TARGET_ROOT vazio e o que faz state_dir() apontar para
# /var/lib/gentoo-install/state no sistema bootado (ver a "armadilha central"
# documentada no topo do lib-desktop.sh). NAO sourceie vars.sh/lib.sh aqui.
# shellcheck source=./lib-desktop.sh disable=SC1091
source "$SCRIPT_DIR/lib-desktop.sh"

init_logging_desktop 15-validate
# Repetida aqui, e nao so no install-desktop.sh, porque os scripts do projeto
# rodam standalone para debug — mesmo padrao do require_phase nos 00-06.
require_booted_system
require_root

# ---------------------------------------------------------------------------
# Resolucao do usuario alvo
# ---------------------------------------------------------------------------
#
# Mesma exigencia da 13: validar grupos e XDG_RUNTIME_DIR de um usuario que nao
# existe produziria um relatorio inteiro sobre ninguem.
[[ -n "${DESKTOP_USER:-}" ]] \
    || die "DESKTOP_USER esta vazio. Defina o usuario alvo em vars-desktop.sh ou no ambiente (ex.: DESKTOP_USER=rodrigo $0). Este script valida a sessao DE ALGUEM — sem saber de quem, nao ha o que validar."

id -u "$DESKTOP_USER" &>/dev/null \
    || die "o usuario '$DESKTOP_USER' nao existe neste sistema. Confira com 'getent passwd' e ajuste DESKTOP_USER. O instalador base cria o usuario definido em USERNAME (vars.sh)."

case "$DESKTOP_SEAT_PROVIDER" in
    seatd|elogind) : ;;
    *)
        die "DESKTOP_SEAT_PROVIDER='$DESKTOP_SEAT_PROVIDER' e invalido. Valores aceitos: 'seatd' ou 'elogind'. Este script valida a rota escolhida — com um valor invalido ele validaria a rota errada e aprovaria um sistema quebrado."
        ;;
esac

# ---------------------------------------------------------------------------
# Guarda de init: as verificacoes de servico sao todas de OpenRC
# ---------------------------------------------------------------------------
#
# Mesma postura da 13: em vez de deixar cada check falhar com "rc-update:
# command not found" e produzir um relatorio de falhas falsas, recusamos aqui.
if [[ "${INIT_SYSTEM:-openrc}" != "openrc" ]]; then
    die "INIT_SYSTEM='${INIT_SYSTEM:-}' — este script valida somente o caminho OpenRC. Todas as verificacoes de servico usam rc-update/rc-service, e em systemd as condicoes de sessao sao outras (systemd-logind ja fornece seat, XDG_RUNTIME_DIR e session tracking nativamente). Validar com as perguntas erradas e pior que nao validar: aprovaria um sistema sem ter olhado para o que importa nele."
fi

command -v rc-update &>/dev/null \
    || die "o comando 'rc-update' nao existe, mas INIT_SYSTEM=openrc. Sem ele nao ha como verificar servico nenhum. Verifique se sys-apps/openrc esta instalado."

if [[ "$DESKTOP_SEAT_PROVIDER" == "seatd" ]]; then
    SEAT_SVC="seatd"
    SEAT_RUNLEVEL="default"
    SEAT_OUTRO="elogind"
else
    SEAT_SVC="elogind"
    SEAT_RUNLEVEL="boot"
    SEAT_OUTRO="seatd"
fi

USER_HOME="$(user_home)"
NIRI_SESSION_DESKTOP="/usr/share/wayland-sessions/niri.desktop"
NIRI_CONFIG="$USER_HOME/.config/niri/config.kdl"
EGL_PLATFORM_DIR="/usr/share/egl/egl_external_platform.d"

# ---------------------------------------------------------------------------
# Helpers de leitura (identicos aos da 13, e repetidos aqui de proposito)
# ---------------------------------------------------------------------------
#
# Os scripts numerados nao podem ser sourceados uns pelos outros: eles EXECUTAM
# acoes no topo (init_logging, require_booted_system, run_step), nao sao
# bibliotecas. Sourcear a 13 daqui rodaria a 13 inteira — habilitando servicos
# dentro de um script que promete apenas ler. Mesma justificativa que o
# lib-desktop.sh registra para o pkg_installed, que existe em duas copias.
#
# Estes helpers sao TODOS somente-leitura: nenhum deles altera o sistema.

# svc_in_runlevel <servico> <runlevel>: 0 se o servico esta no runlevel.
# grep -qx (linha inteira) e essencial: sem o -x, "dbus" casaria com um
# "dbus-daemon" hipotetico e o relatorio aprovaria um servico nao habilitado.
svc_in_runlevel() {
    local svc="$1" runlevel="$2"
    rc-update show "$runlevel" 2>/dev/null | awk '{print $1}' | grep -qx "$svc"
}

# svc_running <servico>: 0 se o servico esta RODANDO AGORA.
# A distincao entre habilitado e rodando e o coracao desta etapa: `rc-update add`
# so agenda para o PROXIMO boot, e um seatd habilitado porem parado nao serve
# para a sessao que o usuario vai abrir daqui a cinco minutos.
svc_running() {
    rc-service "$1" status &>/dev/null
}

svc_script_exists() {
    [[ -x "/etc/init.d/$1" ]]
}

# user_in_group <usuario> <grupo>: 0 se o usuario pertence ao grupo.
#
# `id -nG <usuario>` consulta o NSS para AQUELE usuario — nao as credenciais do
# processo atual (que aqui e root, via sudo). Por isso o resultado ja reflete um
# `gpasswd -a` feito ha um minuto, mesmo que a sessao de login do usuario ainda
# tenha a lista antiga. E exatamente a pergunta que queremos: "no proximo login,
# ele tera o grupo?".
user_in_group() {
    local user="$1" grp="$2"
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"
}

group_exists() {
    getent group "$1" &>/dev/null
}

# user_has_bin <binario>: 0 se o binario existe no PATH DO USUARIO ALVO.
#
# Sutileza que importa: o PATH do root (este script, sob sudo) nao e o mesmo do
# usuario. Um binario num prefixo do usuario apareceria como ausente se
# testassemos com o PATH do root — falso negativo justamente nos itens que o
# config.kdl invoca POR NOME.
#
# ATENCAO: usa run_as_user, que na rota seatd executa o ~/.bash_profile como
# efeito colateral. Por isso o snapshot do XDG_RUNTIME_DIR e tirado ANTES de
# qualquer chamada a esta funcao — ver o bloco de snapshot logo abaixo.
user_has_bin() {
    run_as_user command -v "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# SNAPSHOT DO XDG_RUNTIME_DIR — medido AGORA, antes de qualquer run_as_user
# ---------------------------------------------------------------------------
#
# ARMADILHA REAL, e ela e sutil: run_as_user usa `su - <user>`, que e um shell de
# LOGIN e portanto executa o ~/.bash_profile do usuario. Na rota seatd, o trecho
# que a 13 instalou nesse arquivo CRIA /run/user/$UID quando ele nao existe.
#
# Ou seja: se este script chamasse run_as_user antes de medir, o proprio ato de
# medir criaria o diretorio, e o relatorio anunciaria "XDG_RUNTIME_DIR existe" —
# uma verdade produzida pela medicao, nao encontrada por ela. No boot seguinte,
# antes do primeiro login, ele nao existiria.
#
# Por isso a medicao acontece AQUI, no topo, com as ferramentas do root (stat), e
# o resultado fica em variaveis. Qualquer run_as_user depois disto ja nao
# contamina a leitura. NAO MOVA ESTE BLOCO PARA BAIXO.
#
# (O que prova a saude duradoura da rota nao e o diretorio existir agora, e sim o
# MECANISMO que o recria a cada boot — o script de local.d e o trecho no perfil.
# Os dois sao verificados separadamente em check_xdg_runtime.)
TARGET_UID="$(id -u "$DESKTOP_USER")"
XDG_DIR="/run/user/$TARGET_UID"
LOCAL_D_SCRIPT="/etc/local.d/create-runuser.start"

XDG_PARENT_EXISTS="nao"
XDG_PARENT_MODE=""
if [[ -d /run/user ]]; then
    XDG_PARENT_EXISTS="sim"
    XDG_PARENT_MODE="$(stat -c '%a' /run/user 2>/dev/null || echo '?')"
fi

XDG_DIR_EXISTS="nao"
XDG_DIR_MODE=""
XDG_DIR_OWNER=""
if [[ -d "$XDG_DIR" ]]; then
    XDG_DIR_EXISTS="sim"
    XDG_DIR_MODE="$(stat -c '%a' "$XDG_DIR" 2>/dev/null || echo '?')"
    XDG_DIR_OWNER="$(stat -c '%u' "$XDG_DIR" 2>/dev/null || echo '?')"
fi

# ---------------------------------------------------------------------------
# Acumulador de resultados
# ---------------------------------------------------------------------------
#
# Tres categorias, e a fronteira entre elas e a decisao de projeto mais
# importante deste arquivo:
#
#   OK     : a condicao foi PROVADA.
#   AVISO  : algo que NAO impede a sessao de subir (audio, barra, apps X11), ou
#            que so pode ser provado depois de um novo login (grupo recem
#            adicionado, XDG_RUNTIME_DIR que nasce no login). Marcar isso como
#            falha faria o script reprovar todo primeiro uso — e um validador que
#            sempre reprova e ignorado, o que destroi o valor dele exatamente
#            quando a falha for de verdade.
#   FALHA  : a sessao NAO vai subir, ou nao vai subir no proximo boot. Qualquer
#            uma reprova o script inteiro.
#
# Fail-closed: um check que nao consegue MEDIR (comando ausente, leitura vazia)
# registra FALHA, nunca OK. Na duvida, reprova.
OKS=()
AVISOS=()
FALHAS=()

check_ok() {
    OKS+=("$1")
    log_info "  [OK]    $1"
}

# check_warn <titulo> <o-que-fazer>
check_warn() {
    AVISOS+=("$1|$2")
    log_warn "  [AVISO] $1"
}

# check_fail <titulo> <o-que-fazer>
check_fail() {
    FALHAS+=("$1|$2")
    log_error "  [FALHA] $1"
}

# _secao <titulo>: cabecalho de bloco, para o relatorio nao virar uma parede de
# linhas indistinguiveis.
_secao() {
    log_info "-------------------------------------------------------------"
    log_info "  $1"
    log_info "-------------------------------------------------------------"
}

# ===========================================================================
# 15-check-egl — o caminho grafico da NVIDIA
# ===========================================================================
#
# ESTA E A SUB-ETAPA QUE JUSTIFICA O SCRIPT EXISTIR.
#
# A pesquisa classificou como "armadilha numero 1" o fato de que USE=wayland NAO
# e default-on no nvidia-drivers e o instalador base nao a liga em lugar nenhum
# (package.use/nvidia-drivers so tem '-tools' e 'media-libs/libglvnd X'). Sem
# essa flag o Portage nao instala gui-libs/egl-gbm nem gui-libs/egl-wayland, e
# nenhum compositor Wayland consegue criar um EGLDisplay na GPU.
#
# O que verificamos e o RESULTADO dessa flag NO DISCO, nao a flag em si: um
# package.use correto que nunca foi seguido de re-emerge deixa o arquivo certo e
# o sistema errado. O que vale e o que esta instalado.

# _egl_gbm_lib_present: 0 se a libnvidia-egl-gbm existe em disco.
#
# Busca por PADRAO em vez de caminho fixo: o sufixo de versao (.so.1.1.2) muda
# entre releases do driver e o diretorio varia entre /usr/lib64 e os caminhos
# multilib. Fixar o caminho exato daria falso negativo na proxima atualizacao.
_egl_gbm_lib_present() {
    compgen -G "/usr/lib*/libnvidia-egl-gbm.so*" > /dev/null 2>&1 \
        || compgen -G "/usr/lib*/*/libnvidia-egl-gbm.so*" > /dev/null 2>&1
}

# _nvidia_modeset_enabled: 0 se o modesetting do nvidia-drm esta ATIVO AGORA.
#
# A fonte e a melhor possivel: o proprio kernel, via
# /sys/module/nvidia_drm/parameters/modeset. Nao inferimos de cmdline nem de
# arquivo de modprobe — lemos o estado efetivo.
#
# Por que isso e melhor que checar a cmdline: no ramo >=595 a NVIDIA passou a
# habilitar modeset=1 por default e o ebuild REMOVEU a linha do nvidia.conf.
# Quem procurar 'nvidia-drm.modeset=1' na cmdline concluiria "faltando" num
# sistema perfeitamente correto. O arquivo em /sys responde a pergunta certa —
# "o modesetting esta ligado?" — independente de COMO foi ligado.
_nvidia_modeset_enabled() {
    local v
    v="$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null)" || return 1
    [[ "$v" == "Y" ]]
}

# PROBE: "esta verificacao ja foi EXECUTADA nesta rodada?".
#
# ATENCAO — ESTA SEMANTICA E DELIBERADA E NAO PODE SER TROCADA pela pergunta
# aparentemente mais natural "o sistema esta saudavel?" (isto e,
# `_egl_gbm_lib_present && _nvidia_modeset_enabled`). Motivo, lido no contrato do
# run_step (lib.sh:689): se o probe AINDA reprovar depois do do_fn, ele chama
# die("sub-etapa inconsistente").
#
# Como este script NAO CONSERTA NADA, num sistema de fato quebrado — EGL ausente,
# que e precisamente o caso que esta etapa existe para diagnosticar — o probe de
# saude continuaria reprovando apos o do_fn e o run_step MATARIA o script com uma
# mensagem generica, ANTES do relatorio. O usuario perderia as demais
# verificacoes e a lista de correcoes: exatamente o oposto do objetivo.
#
# Com a semantica "ja executei", o do_fn sempre roda, sempre MEDE o sistema real
# e sempre registra o resultado nos acumuladores. O veredicto de saude fica onde
# ele pertence — no relatorio final e no exit code, que reprovam com mensagem
# acionavel item a item.
#
# A idempotencia continua correta: a flag e uma global de PROCESSO (nasce vazia a
# cada execucao), nunca um marker em disco. Rodar o script de novo remede tudo.
probe_check_egl() {
    [[ "${_CHECKED_EGL:-nao}" == "sim" ]]
}

do_check_egl() {
    # Marca no inicio: o contrato do probe e "esta verificacao foi executada",
    # e ela foi — independentemente de o resultado ser bom ou ruim.
    _CHECKED_EGL="sim"
    _secao "GRAFICO / NVIDIA — o caminho EGL/GBM e o DRM"

    # --- Ramo do driver: o contexto em que todo o resto e interpretado ---
    local branch=""
    if branch="$(nvidia_branch)"; then
        log_info "  ramo do nvidia-drivers: $branch ($(portageq best_version / x11-drivers/nvidia-drivers 2>/dev/null || echo 'versao indeterminada'))"
    else
        check_warn "nao foi possivel determinar a versao do x11-drivers/nvidia-drivers instalado" "As verificacoes de NVIDIA seguem, mas sem o contexto de ramo (580 LTS vs >=595), que muda o que e esperado em modeset e nas libs EGL. Confira com: portageq best_version / x11-drivers/nvidia-drivers"
    fi

    # --- libnvidia-egl-gbm: a prova material da USE=wayland ---
    #
    # Se esta falhar, o compositor nao inicia — e o usuario descobriria isso na
    # tela preta, sem console. E a linha mais importante do script.
    if _egl_gbm_lib_present; then
        check_ok "libnvidia-egl-gbm presente (o backend GBM/EGL da NVIDIA existe em disco)"
    else
        check_fail "libnvidia-egl-gbm AUSENTE — nenhum compositor Wayland consegue criar EGLDisplay na GPU e o niri NAO INICIA (tela preta, sem mensagem)" "Causa quase certa: o x11-drivers/nvidia-drivers foi construido SEM USE=wayland (essa flag NAO e default-on e o instalador base nao a liga). Rode a etapa 11: ./desktop/install-desktop.sh --only 11 — ela escreve a flag e reconstroi o driver. Confira depois com: ls /usr/lib64/libnvidia-egl-gbm.so*"
    fi

    # --- Manifestos EGL external platform ---
    #
    # AVISO e nao FALHA de proposito: os nomes e a quantidade de JSONs variam por
    # ramo (>=595 traz egl-wayland E egl-wayland2; o 580 nao traz o segundo) e a
    # lib GBM acima ja e a evidencia decisiva. Transformar variacao esperada de
    # nomenclatura em falha bloquearia um sistema que funciona.
    if [[ -d "$EGL_PLATFORM_DIR" ]]; then
        local n_json
        n_json="$(find "$EGL_PLATFORM_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
        if (( n_json > 0 )); then
            check_ok "$n_json manifesto(s) EGL em $EGL_PLATFORM_DIR ($(find "$EGL_PLATFORM_DIR" -maxdepth 1 -name '*.json' -printf '%f ' 2>/dev/null || true))"
        else
            check_warn "$EGL_PLATFORM_DIR existe mas esta VAZIO" "Sao esses JSONs que dizem ao libglvnd como falar com a plataforma Wayland/GBM. Combinado com a libnvidia-egl-gbm ausente, confirma driver sem USE=wayland (etapa 11)."
        fi
    else
        check_warn "$EGL_PLATFORM_DIR nao existe" "O diretorio de manifestos EGL external platform e criado pelos pacotes gui-libs/egl-gbm e gui-libs/egl-wayland, que so entram com USE=wayland no nvidia-drivers (etapa 11)."
    fi

    # --- Modulo nvidia_drm carregado ---
    #
    # Lemos /sys/module (estado real do kernel) e nao a saida do lsmod: o
    # diretorio existe sempre que o modulo esta carregado, inclusive builtin, e
    # nao depende de o binario lsmod estar instalado.
    if [[ -d /sys/module/nvidia_drm ]]; then
        check_ok "modulo nvidia_drm carregado"
    else
        check_fail "modulo nvidia_drm NAO carregado — sem ele nao ha DRM da NVIDIA e o compositor nao encontra a GPU" "Verifique 'lsmod | grep nvidia' e 'dmesg | grep -i nvidia'. Este kernel NAO tem initramfs: o modulo e carregado tarde, pelo udev. Confirme que o pacote esta instalado para o kernel EM EXECUCAO — a versao do modulo tem de casar com 'uname -r'."
    fi

    # --- modeset: pre-requisito absoluto de Wayland na NVIDIA ---
    if _nvidia_modeset_enabled; then
        check_ok "nvidia_drm modeset=Y (modesetting DRM ativo)"
    elif [[ -e /sys/module/nvidia_drm/parameters/modeset ]]; then
        local mv
        mv="$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo '?')"
        check_fail "nvidia_drm modeset='$mv' (esperado 'Y') — sem modesetting DRM o niri nao inicializa o backend e a sessao nao sobe" "No ramo >=595 modeset=1 e o default do driver, entao o valor '$mv' indica que algo o desligou explicitamente. Procure 'nvidia-drm.modeset=0' na cmdline (cat /proc/cmdline) ou uma linha 'options nvidia-drm modeset=0' em /etc/modprobe.d/. No ramo 580 a habilitacao e tratada pela etapa 11."
    else
        # Sem o modulo carregado o arquivo nem existe; a falha ja foi reportada
        # acima. Repetir como FALHA contaria o mesmo problema duas vezes e
        # inflaria o placar — o que confunde em vez de informar.
        check_warn "nao foi possivel ler /sys/module/nvidia_drm/parameters/modeset (modulo nao carregado)" "Resolva primeiro o item do modulo nvidia_drm; este valor so tem significado com o modulo de pe."
    fi

    # --- /dev/dri/card* e o acesso DO USUARIO ---
    #
    # Nao basta o device existir: o compositor roda como o USUARIO, e e o acesso
    # DELE que decide se a sessao abre. Esta e a diferenca entre "o driver esta
    # ok" e "a sessao vai funcionar" — que e a pergunta desta etapa.
    if compgen -G '/dev/dri/card*' > /dev/null; then
        local cards=()
        # shellcheck disable=SC2207
        cards=($(compgen -G '/dev/dri/card*'))
        check_ok "dispositivos DRM presentes: ${cards[*]}"

        # Grupo dono dos devices DRM. Tipicamente 'video'; lemos em vez de supor.
        local card="${cards[0]}" card_grp
        card_grp="$(stat -c '%G' "$card" 2>/dev/null || echo '?')"
        if [[ "$card_grp" == "?" ]]; then
            check_warn "nao foi possivel ler o grupo dono de $card" "Sem essa leitura nao da para provar que '$DESKTOP_USER' tem acesso ao DRM. Confira com: ls -l $card"
        elif user_in_group "$DESKTOP_USER" "$card_grp"; then
            check_ok "'$DESKTOP_USER' pertence ao grupo '$card_grp', dono de $card (acesso ao DRM garantido)"
        else
            check_fail "'$DESKTOP_USER' NAO esta no grupo '$card_grp', dono de $card — sem acesso ao DRM o compositor nao abre a GPU e a sessao morre no arranque" "gpasswd -a $DESKTOP_USER $card_grp   # aditivo; depois faca logout/login, porque grupo so vale em sessoes NOVAS. Ou rode a etapa 13."
        fi
    else
        check_fail "nenhum dispositivo DRM em /dev/dri/ — o compositor nao tera onde desenhar" "Nenhum driver de video assumiu a GPU. Reveja a etapa 11 (nvidia-wayland) e confira 'dmesg | grep -i drm' e o item do modulo nvidia_drm acima."
    fi

    # --- Nota sobre o handoff simpledrm -> nvidia-drm (risco NAO validado) ---
    #
    # Registrado como informacao, nunca como veredicto: a pesquisa classificou
    # isto como "o maior risco nao-validado do projeto" e ninguem testou esta
    # combinacao exata (kernel sem initramfs + simpledrm + Blackwell/GB206).
    # Emitir OK ou FALHA aqui seria inventar um veredicto sobre algo que so pode
    # ser medido depois do proximo boot. O relatorio final explica o escape hatch.
    if [[ -d /sys/module/simpledrm ]] || compgen -G '/sys/bus/platform/drivers/simple-framebuffer/*' > /dev/null 2>&1; then
        log_info "  (nota: simpledrm presente — o handoff simpledrm -> nvidia-drm sem initramfs e o risco NAO validado deste projeto; ver o bloco final do relatorio)"
    fi
}

# ===========================================================================
# 15-check-seat — seat, dbus, grupos, XDG_RUNTIME_DIR e audio
# ===========================================================================
#
# O instalador base (00-06) NAO configura seatd, elogind nem dbus — grep nos
# scripts 00-06 nao retorna nada. Sem um provedor de seat de pe, o niri instala e
# compila perfeitamente e NUNCA INICIA: falha ao abrir o seat, em silencio. Esta
# sub-etapa prova que a etapa 13 fez o seu trabalho.

# --- provedor de seat -------------------------------------------------------
#
# Duas condicoes, e as duas importam por motivos diferentes:
#   habilitado no runlevel certo -> vai subir no PROXIMO boot
#   rodando agora                -> a sessao pode ser testada SEM reiniciar
#
# O runlevel e verificado especificamente (default para seatd, boot para
# elogind): um elogind habilitado em 'default' sobe DEPOIS de o PAM criar a
# sessao, e o resultado e a primeira sessao nascer sem XDG_RUNTIME_DIR e sem
# registro no loginctl. Como o sintoma aparece so no login seguinte, engana.
check_seat_provider() {
    if ! svc_script_exists "$SEAT_SVC"; then
        # Sem init script nao ha o que habilitar nem o que rodar: as verificacoes
        # seguintes nao teriam sentido. Reportamos a causa raiz.
        local dica="Rode a etapa 13 (./desktop/install-desktop.sh --only 13), que instala e habilita o provedor."
        if [[ "$SEAT_SVC" == "seatd" ]]; then
            dica="O init script do seatd so e instalado com USE=server (o wiki Gentoo exige 'builtin' E 'server' para a rota OpenRC). Confira o package.use escrito pela etapa 10 e reinstale: emerge --newuse sys-auth/seatd"
        fi
        check_fail "'/etc/init.d/$SEAT_SVC' nao existe — nao ha provedor de seat instalado" "$dica"
        return 0
    fi

    if svc_in_runlevel "$SEAT_SVC" "$SEAT_RUNLEVEL"; then
        check_ok "$SEAT_SVC habilitado no runlevel '$SEAT_RUNLEVEL'"
    else
        # Diagnostico dirigido ao erro classico: habilitado, porem no runlevel
        # errado. Dizer "nao esta habilitado" quando ele esta em outro runlevel
        # mandaria o usuario procurar no lugar errado.
        local onde=""
        if svc_in_runlevel "$SEAT_SVC" default || svc_in_runlevel "$SEAT_SVC" boot || svc_in_runlevel "$SEAT_SVC" sysinit; then
            onde=" (ele APARECE em outro runlevel — runlevel errado e causa classica: no lugar errado ele sobe tarde demais e a primeira sessao nasce quebrada)"
        fi
        check_fail "$SEAT_SVC NAO esta habilitado no runlevel '$SEAT_RUNLEVEL'$onde" "rc-update add $SEAT_SVC $SEAT_RUNLEVEL   # ou rode a etapa 13"
    fi

    if svc_running "$SEAT_SVC"; then
        check_ok "$SEAT_SVC esta RODANDO agora"
    else
        check_fail "$SEAT_SVC esta parado — o compositor nao conseguira abrir o seat" "rc-service $SEAT_SVC start   # 'rc-update add' apenas agenda para o proximo boot; nao inicia nada agora"
    fi

    # Os dois provedores rodando juntos: sao CONCORRENTES, disputam o mesmo
    # recurso, e o resultado e nao-determinista — a sessao funciona num boot e nao
    # funciona no seguinte. Vale checar porque nada impede que uma instalacao
    # anterior (ou uma dependencia) tenha deixado o outro habilitado.
    if svc_script_exists "$SEAT_OUTRO" && svc_running "$SEAT_OUTRO"; then
        check_fail "'$SEAT_OUTRO' TAMBEM esta rodando, junto com '$SEAT_SVC' — sao provedores de seat CONCORRENTES" "Escolha UM. Para parar e desabilitar o que sobra: rc-service $SEAT_OUTRO stop && rc-update del $SEAT_OUTRO"
    fi
}

# --- dbus -------------------------------------------------------------------
#
# Nao e "mais um servico": o comando canonico de arranque do niri em OpenRC e
# literalmente 'dbus-run-session niri --session'. Sem barramento, o niri --session
# nao exporta as variaveis de ambiente nem registra os servicos D-Bus dele
# (incluindo o portal de screencast) — e tudo isso falha em silencio.
#
# O dbus quase sempre entra como dependencia transitiva, mas dependencia instala
# o PACOTE; ela nao HABILITA o servico. Sao coisas diferentes, e o instalador
# base (00-06) nao faz nem uma nem outra.
check_dbus() {
    if ! svc_script_exists dbus; then
        check_fail "'/etc/init.d/dbus' nao existe — sys-apps/dbus nao esta instalado (ou foi construido sem o init script)" "O binario 'dbus-run-session', que e o comando de arranque do niri em OpenRC, vem deste pacote. Rode as etapas 12 e 13."
        return 0
    fi

    if svc_in_runlevel dbus default; then
        check_ok "dbus habilitado no runlevel 'default'"
    else
        check_fail "dbus NAO esta habilitado no runlevel 'default'" "rc-update add dbus default   # ou rode a etapa 13"
    fi

    if svc_running dbus; then
        check_ok "dbus esta RODANDO agora"
    else
        check_fail "dbus esta parado — 'dbus-run-session niri --session' nao vai funcionar" "rc-service dbus start"
    fi
}

# --- grupos -----------------------------------------------------------------
#
#   video : dispositivos DRM (/dev/dri/*). Sem ele nao ha saida grafica.
#   input : dispositivos de entrada. Com elogind o acesso normalmente vem por ACL
#           da sessao, e o grupo e o FALLBACK — que e justamente o que salva
#           quando a sessao NAO e reconhecida, o cenario em que voce mais precisa
#           dele. Por isso ele e exigido nas duas rotas.
#   seat  : SO na rota seatd, exigido explicitamente pelo wiki Gentoo do Seatd.
#           Sem ele o compositor falha ao abrir o seat e morre no arranque.
#
# 'pipewire' entra como AVISO e nao como falha: audio nao e pre-requisito da
# sessao grafica, e reprovar por causa dele esconderia as falhas que importam.
check_user_groups() {
    local grupos=(video input)
    [[ "$DESKTOP_SEAT_PROVIDER" == "seatd" ]] && grupos+=(seat)

    local grp faltando=()
    for grp in "${grupos[@]}"; do
        if ! group_exists "$grp"; then
            # Grupo inexistente nao e "usuario fora do grupo": e sistema
            # incompleto, e a correcao e outra. Distinguir evita mandar o usuario
            # rodar um gpasswd que so vai dar erro.
            if [[ "$grp" == "seat" ]]; then
                check_fail "o grupo 'seat' NAO EXISTE neste sistema" "Ele e criado pelo ebuild do sys-auth/seatd — a ausencia indica que o pacote nao foi instalado. Rode a etapa 12."
            else
                check_fail "o grupo '$grp' NAO EXISTE neste sistema" "Os grupos 'video' e 'input' fazem parte do baselayout do Gentoo; a ausencia indica um sistema base incompleto. Confira: getent group $grp"
            fi
            continue
        fi
        user_in_group "$DESKTOP_USER" "$grp" || faltando+=("$grp")
    done

    if (( ${#faltando[@]} == 0 )); then
        check_ok "'$DESKTOP_USER' pertence a todos os grupos exigidos (${grupos[*]})"
        # Efeito colateral que engana muita gente, por isso o lembrete explicito.
        log_info "  (lembrete: a lista de grupos e fixada no LOGIN — a sessao atual ainda pode ter a lista antiga; confira com: id -nG $DESKTOP_USER)"
    else
        # gpasswd -a, um por vez, e NUNCA `usermod -G`: este ultimo SUBSTITUI a
        # lista inteira e removeria wheel/audio/portage que o 06 configurou —
        # quebrando o sudo do usuario de quebra. A instrucao aqui e aditiva.
        local lista="${faltando[*]}" cmds="" g
        for g in "${faltando[@]}"; do
            cmds+="gpasswd -a $DESKTOP_USER $g; "
        done
        check_fail "'$DESKTOP_USER' NAO pertence a: $lista" "${cmds}# aditivo, um grupo por vez. NUNCA use 'usermod -G' aqui: ele substitui a lista inteira e removeria wheel/audio/portage. Depois: logout/login."
    fi

    if group_exists pipewire && ! user_in_group "$DESKTOP_USER" pipewire; then
        check_warn "'$DESKTOP_USER' nao esta no grupo 'pipewire'" "Nao impede a sessao de subir; o wiki do PipeWire recomenda a inclusao: gpasswd -a $DESKTOP_USER pipewire"
    fi
}

# --- XDG_RUNTIME_DIR --------------------------------------------------------
#
# E onde vivem os sockets do Wayland, do PipeWire e do D-Bus de sessao. Sem ele,
# nada disso funciona — e o sintoma e de novo uma sessao que morre calada.
#
# DUAS PERGUNTAS DIFERENTES, e as duas precisam de resposta:
#
#   1. O diretorio esta la AGORA?  -> util, mas insuficiente: /run e tmpfs e o
#      conteudo some a cada boot.
#   2. Existe MECANISMO que o recria a cada boot?  -> esta e a que decide se o
#      sistema esta saudavel. E ela difere por rota:
#
#        seatd   : o seatd resolve APENAS seat management; ele NAO cria
#                  XDG_RUNTIME_DIR. Quem faz isso e o script de local.d (que cria
#                  /run/user a cada boot) mais o trecho no ~/.bash_profile (que
#                  cria /run/user/$UID no login). Faltando um dos dois, quebra.
#        elogind : o proprio elogind cria e gerencia /run/user/$UID pelo ciclo de
#                  vida da sessao — MAS so se o PAM registrar a sessao, o que
#                  depende de pam_elogind.so estar referenciado em /etc/pam.d.
#                  Essa linha e a causa numero um de "elogind rodando e mesmo
#                  assim sem XDG_RUNTIME_DIR".
#
# A ausencia do diretorio AGORA e AVISO, nao falha: na rota seatd ele nasce no
# proximo login (o trecho do perfil roda la), e na rota elogind quando o PAM cria
# a sessao. Reprovar por isso faria o script reprovar todo primeiro uso, logo
# depois da 13, quando na verdade esta tudo certo.
#
# Ja o diretorio existir com DONO OU PERMISSAO ERRADOS e FALHA: /run/user e 1777,
# entao qualquer usuario pode ter criado o diretorio de outro primeiro. Abrir os
# sockets da sessao dentro de um diretorio alheio e um problema de seguranca, e o
# proprio trecho instalado pela 13 se recusa a usar o diretorio nesse caso — o
# que aqui apareceria como "sessao sem XDG_RUNTIME_DIR" sem explicacao.
check_xdg_runtime() {
    if [[ "$DESKTOP_SEAT_PROVIDER" == "seatd" ]]; then
        # --- Mecanismo, peca 1: o script de sistema ---
        if [[ -x "$LOCAL_D_SCRIPT" ]]; then
            check_ok "'$LOCAL_D_SCRIPT' existe e e executavel (recria /run/user a cada boot)"
        elif [[ -e "$LOCAL_D_SCRIPT" ]]; then
            # Distincao que vale ouro: existe porem sem o bit de execucao. O
            # OpenRC IGNORA o arquivo em silencio, e quem olha so a existencia
            # conclui que esta tudo certo.
            check_fail "'$LOCAL_D_SCRIPT' existe mas NAO e executavel — o OpenRC ignora scripts de local.d sem o bit de execucao, em silencio" "chmod +x $LOCAL_D_SCRIPT"
        else
            check_fail "'$LOCAL_D_SCRIPT' nao existe — na rota seatd nada recria /run/user apos o boot (/run e tmpfs e some inteiro)" "Rode a etapa 13: ./desktop/install-desktop.sh --only 13"
        fi

        # O script de local.d so roda se o servico 'local' estiver habilitado.
        if svc_in_runlevel local default; then
            check_ok "servico 'local' habilitado no runlevel 'default' (e o que executa o script acima)"
        else
            check_fail "o servico 'local' NAO esta habilitado — o script de local.d nunca sera executado no boot" "rc-update add local default"
        fi

        # --- Mecanismo, peca 2: o trecho no perfil do usuario ---
        #
        # Lido com as ferramentas do root de proposito: run_as_user aqui EXECUTA
        # o proprio trecho que estamos tentando verificar (ver o snapshot).
        if grep -qF 'XDG_RUNTIME_DIR (modulo desktop' "$USER_HOME/.bash_profile" 2>/dev/null; then
            check_ok "o trecho de XDG_RUNTIME_DIR esta em '$USER_HOME/.bash_profile' (cria /run/user/\$UID no login)"
        else
            check_fail "'$USER_HOME/.bash_profile' NAO contem o trecho de XDG_RUNTIME_DIR — na rota seatd nada define a variavel na sessao" "Rode a etapa 13: ./desktop/install-desktop.sh --only 13"
        fi

        # --- /run/user (o diretorio pai) ---
        if [[ "$XDG_PARENT_EXISTS" == "sim" ]]; then
            if [[ "$XDG_PARENT_MODE" == "1777" ]]; then
                check_ok "/run/user existe com o sticky bit (1777)"
            else
                # Sem o sticky bit, um usuario pode apagar ou renomear o
                # diretorio de outro. Nao impede o boot de hoje, mas e um furo.
                check_warn "/run/user existe com modo '$XDG_PARENT_MODE' (esperado 1777)" "O sticky bit impede que um usuario apague o diretorio de outro. Corrija com: chmod 1777 /run/user"
            fi
        else
            check_fail "/run/user NAO existe — nenhum XDG_RUNTIME_DIR pode ser criado dentro dele" "mkdir -p /run/user && chmod 1777 /run/user   # e rode a etapa 13 para que isso se repita a cada boot"
        fi
    else
        # --- Rota elogind: o mecanismo e o PAM ---
        #
        # O probe olha o CONTEUDO do arquivo, e nao o pacote instalado: as linhas
        # chegam como ATUALIZACAO do Portage sob CONFIG_PROTECT e costumam ficar
        # paradas num arquivo ._cfg* ate alguem rodar dispatch-conf. Verificar o
        # pacote reportaria "tudo certo" exatamente no cenario quebrado.
        if grep -qE '^[[:space:]]*-?session.*pam_elogind\.so' /etc/pam.d/system-login 2>/dev/null; then
            check_ok "pam_elogind.so referenciado em /etc/pam.d/system-login (o PAM registra a sessao no elogind)"
        else
            local pendentes
            pendentes="$(find /etc/pam.d -maxdepth 1 -name '._cfg*' 2>/dev/null | head -n 5)" || pendentes=""
            local dica="Aplique a atualizacao pendente do Portage com 'dispatch-conf' (recomendado, mostra o diff) ou 'etc-update'. NAO edite o arquivo a mao: em PAM a ORDEM das linhas e semantica e uma linha no lugar errado pode TRANCAR VOCE PARA FORA do sistema."
            [[ -n "$pendentes" ]] && dica="Ha arquivos ._cfg PENDENTES em /etc/pam.d/ — a linha correta provavelmente ja esta la esperando. $dica"
            check_fail "pam_elogind.so NAO esta referenciado em /etc/pam.d/system-login — sem isso o PAM nao registra a sessao, XDG_RUNTIME_DIR nunca e criado e o loginctl nao lista sessao nenhuma (causa numero um dessa falha)" "$dica"
        fi

        # /run/user na rota elogind e criado pelo proprio elogind; nao ha script
        # de local.d a verificar.
        if [[ "$XDG_PARENT_EXISTS" == "sim" ]]; then
            check_ok "/run/user existe (gerenciado pelo elogind)"
        else
            check_warn "/run/user ainda nao existe" "O elogind o cria quando a primeira sessao e registrada. Se continuar ausente depois de um login, o problema esta no pam_elogind.so acima."
        fi

        # loginctl: evidencia FORTE de que o PAM registrou o login. A ausencia
        # NAO e falha — e esperada quando o usuario ainda nao logou, que e o caso
        # tipico ao rodar isto por sudo a partir de um TTY de root.
        if command -v loginctl &>/dev/null; then
            if loginctl list-sessions 2>/dev/null | grep -q "$DESKTOP_USER"; then
                check_ok "loginctl lista uma sessao de '$DESKTOP_USER'"
            else
                check_warn "loginctl nao lista sessao de '$DESKTOP_USER'" "Se o usuario ainda nao fez login, isso e ESPERADO. Se ele JA esta logado, a causa e quase sempre o pam_elogind.so ausente (item acima). Confira com: loginctl list-sessions"
            fi
        else
            check_warn "'loginctl' nao encontrado no PATH" "O binario faz parte do sys-auth/elogind. Sua ausencia com DESKTOP_SEAT_PROVIDER=elogind sugere que o pacote nao esta instalado (etapa 12)."
        fi
    fi

    # --- O diretorio do usuario, comum as duas rotas ---
    #
    # Valores do SNAPSHOT tirado no topo do script (nunca remedidos aqui): entre
    # la e aqui pode ter havido um run_as_user, que na rota seatd criaria o
    # diretorio como efeito colateral da propria medicao.
    if [[ "$XDG_DIR_EXISTS" != "sim" ]]; then
        local quem="o trecho no ~/.bash_profile, no proximo login"
        [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]] && quem="o elogind, quando o PAM registrar a sessao no proximo login"
        check_warn "$XDG_DIR ainda nao existe" "Esperado NESTE momento: ele e criado por $quem. Confirme depois de um logout/login com: su - $DESKTOP_USER -c 'echo \$XDG_RUNTIME_DIR'"
        return 0
    fi

    if [[ "$XDG_DIR_OWNER" == "$TARGET_UID" && "$XDG_DIR_MODE" == "700" ]]; then
        check_ok "$XDG_DIR existe, com dono '$DESKTOP_USER' (uid $TARGET_UID) e modo 0700"
    else
        # Este e o caso perigoso, e ele e silencioso: o trecho instalado pela 13
        # DESEXPORTA a variavel quando encontra dono/permissao errados, entao a
        # sessao simplesmente nasce sem XDG_RUNTIME_DIR e nada explica o motivo.
        check_fail "$XDG_DIR existe com dono/permissao INCORRETOS (uid '$XDG_DIR_OWNER', modo '$XDG_DIR_MODE'; esperado uid '$TARGET_UID', modo '700') — como /run/user e 1777, isso normalmente significa que OUTRO usuario criou este diretorio primeiro" "O trecho instalado pela etapa 13 se recusa a usar um diretorio assim (desexporta a variavel por seguranca), e a sessao nasce sem XDG_RUNTIME_DIR. Com o usuario deslogado: rm -rf $XDG_DIR   # ele sera recriado corretamente no proximo login"
    fi
}

# --- audio (NUNCA fatal) ----------------------------------------------------
#
# Audio nao e pre-requisito para a sessao subir. Uma falha de audio marcada como
# FALHA reprovaria o script e esconderia, no meio do ruido, as condicoes que
# realmente impedem o desktop de iniciar.
#
# ORDEM IMPORTA E LIMITA O QUE DA PARA VERIFICAR: a 15 roda ANTES da 14. Na rota
# 'launcher', o config.kdl que declara o spawn-at-startup provavelmente AINDA NAO
# EXISTE — checa-lo aqui produziria um falso negativo garantido. Por isso, nessa
# rota, verificamos apenas o que ja tem de estar de pe agora: o binario do wrapper.
check_audio_route() {
    if ! pkg_installed media-video/pipewire; then
        log_info "  (media-video/pipewire nao esta instalado — nada de audio a validar; escolha valida)"
        return 0
    fi

    local rota
    rota="$(step_value 13-audio-route)"

    case "$rota" in
        user-services)
            local out svc faltando=()
            # `rc-update -U show` lista o runlevel do usuario que RODA o comando:
            # como root ele mostraria o runlevel do ROOT, que nao interessa.
            if out="$(run_as_user rc-update -U show default 2>/dev/null)"; then
                for svc in pipewire pipewire-pulse; do
                    printf '%s\n' "$out" | awk '{print $1}' | grep -qx "$svc" || faltando+=("$svc")
                done
                if (( ${#faltando[@]} == 0 )); then
                    check_ok "audio: servicos de usuario (pipewire, pipewire-pulse) habilitados para '$DESKTOP_USER'"
                else
                    check_warn "audio: faltam servicos de usuario para '$DESKTOP_USER': ${faltando[*]}" "su - $DESKTOP_USER -c 'rc-update add -U ${faltando[*]} default'   # NUNCA como root: sem o -U (ou como root) a config vai para o runlevel do root e o audio do usuario fica sem servico"
                fi
            else
                check_warn "audio: nao foi possivel ler o runlevel de usuario de '$DESKTOP_USER'" "Confira manualmente: su - $DESKTOP_USER -c 'rc-update -U show default'"
            fi
            ;;
        launcher)
            if [[ -x /usr/bin/gentoo-pipewire-launcher ]]; then
                check_ok "audio: rota 'launcher' (OpenRC < 0.60) e o wrapper existe — a etapa 14 o declara no spawn-at-startup do config.kdl"
            else
                check_warn "audio: a rota registrada e 'launcher', mas /usr/bin/gentoo-pipewire-launcher NAO existe" "As duas rotas de arranque do PipeWire ficam indisponiveis. O wrapper vem do media-video/pipewire: emerge --newuse media-video/pipewire"
            fi
            ;;
        "")
            check_warn "audio: o PipeWire esta instalado, mas a etapa 13 nao registrou rota de arranque (marker '13-audio-route' ausente)" "A etapa 14 nao vai declarar o launcher sem esse marker (declara-lo por engano faria o PipeWire subir duas vezes). Rode a 13: ./desktop/install-desktop.sh --only 13"
            ;;
        *)
            check_warn "audio: o marker '13-audio-route' contem um valor inesperado ('$rota')" "Os unicos valores gravados pela etapa 13 sao 'user-services' e 'launcher'. Inspecione com: cat $DESKTOP_STATE_DIR/13-audio-route"
            ;;
    esac
}

# PROBE: "esta verificacao ja foi EXECUTADA nesta rodada?" — mesma semantica
# deliberada de probe_check_egl (ver a justificativa completa la). Um probe de
# saude aqui faria o run_step matar o script justamente quando o seat estivesse
# quebrado, que e o caso que mais precisa chegar ao relatorio.
probe_check_seat() {
    [[ "${_CHECKED_SEAT:-nao}" == "sim" ]]
}

do_check_seat() {
    _CHECKED_SEAT="sim"
    _secao "SEAT / SESSAO — o que permite ao compositor abrir a GPU"
    check_seat_provider
    check_dbus
    check_user_groups
    check_xdg_runtime
    check_audio_route
}

# ===========================================================================
# 15-check-session-files — o que a sessao executa
# ===========================================================================
#
# Aqui verificamos os arquivos e binarios que a sessao INVOCA. O erro mais caro
# desta categoria e o Exec= do niri.desktop: se ele apontar para 'niri-session'
# num sistema OpenRC, a sessao morre instantaneamente. O script upstream
# niri-session procura systemctl ou dinitctl e, nao achando nenhum, imprime
# "No systemd or dinit detected, please use niri --session instead" e sai —
# tipicamente sem nada visivel para o usuario, que so ve a tela voltar.

# _niri_desktop_exec_ok: 0 se o Exec= do .desktop NAO e o niri-session cru.
#
# A ancora e importante: procuramos uma linha Exec= que COMECE com
# 'niri-session', e nao a substring em qualquer posicao. Sem a ancora, o Exec
# CORRETO ('dbus-run-session niri --session') tambem casaria com uma busca
# ingenua por "niri-session"... e o script reprovaria justamente o caso bom.
_niri_desktop_exec_ok() {
    ! grep -qE '^Exec=[[:space:]]*niri-session([[:space:]]|$)' "$NIRI_SESSION_DESKTOP" 2>/dev/null
}

# PROBE: "esta verificacao ja foi EXECUTADA nesta rodada?" — mesma semantica
# deliberada de probe_check_egl (ver a justificativa completa la). Vale
# especialmente aqui: um niri ausente ou um Exec=niri-session sao condicoes que
# este script NAO conserta, e um probe de saude transformaria as duas no die()
# generico do run_step em vez da mensagem especifica que o do_fn produz.
probe_check_session_files() {
    [[ "${_CHECKED_SESSION_FILES:-nao}" == "sim" ]]
}

# --- config.kdl do usuario --------------------------------------------------
#
# "Valido" aqui significa: existe, e legivel PELO USUARIO e tem conteudo.
#
# NAO validamos a gramatica KDL de proposito. A unica ferramenta que conhece o
# schema real da versao instalada e o proprio niri, e a pesquisa NAO confirmou um
# subcomando estavel de validacao (nem o esquema completo do KDL da versao do
# GURU). Inventar um parser de KDL aqui produziria falsos negativos em sintaxe
# legitima — pior que nao verificar.
#
# O teste de leitura COMO USUARIO e o que pega o erro real e comum: arquivo
# criado com dono root dentro do $HOME, que deixa a sessao sem config sem dizer
# por que.
check_niri_config() {
    if [[ ! -f "$NIRI_CONFIG" ]]; then
        check_warn "$NIRI_CONFIG nao existe" "Esperado se a etapa 14-dotfiles ainda nao rodou (ela e a ULTIMA de proposito, e roda DEPOIS desta). Sem ele o niri usa o config default embutido, cujos binds apontam para alacritty/fuzzel e que faz spawn de waybar."
        return 0
    fi

    local cfg_owner
    cfg_owner="$(stat -c '%U' "$NIRI_CONFIG" 2>/dev/null || echo '?')"
    if ! run_as_user test -r "$NIRI_CONFIG"; then
        check_fail "$NIRI_CONFIG existe mas '$DESKTOP_USER' NAO consegue ler (dono: $cfg_owner)" "Quase sempre significa que o arquivo foi criado como root dentro do \$HOME. Corrija com: chown -R $DESKTOP_USER: $USER_HOME/.config/niri"
    elif [[ ! -s "$NIRI_CONFIG" ]]; then
        check_warn "$NIRI_CONFIG existe porem esta VAZIO" "O niri cai no config default embutido, que faz spawn de waybar — se a barra nao estiver instalada, gera erro de spawn no log a cada boot. A etapa 14 escreve um config minimo viavel."
    else
        check_ok "$NIRI_CONFIG presente (dono $cfg_owner, legivel pelo usuario)"
    fi
}

do_check_session_files() {
    _CHECKED_SESSION_FILES="sim"
    _secao "SESSAO — arquivos e binarios que o arranque invoca"

    # --- Os dois binarios do comando de arranque ---
    #
    # Verificar isto custa milissegundos e evita o pior desfecho possivel desta
    # etapa: aprovar o sistema inteiro e o usuario descobrir, depois do reboot,
    # que o comando que mandamos digitar nao existe.
    if command -v dbus-run-session &>/dev/null; then
        check_ok "'dbus-run-session' encontrado no PATH (primeiro binario do comando de arranque)"
    else
        check_fail "'dbus-run-session' NAO existe — e o primeiro binario do comando de arranque do niri em OpenRC" "Vem do sys-apps/dbus: emerge --noreplace sys-apps/dbus"
    fi

    if command -v niri &>/dev/null; then
        check_ok "'niri' encontrado no PATH ($(command -v niri))"
    else
        check_fail "o compositor 'niri' NAO esta no PATH" "Rode a etapa 12: ./desktop/install-desktop.sh --only 12. Lembre que gui-wm/niri NAO existe no ::gentoo — vem do overlay GURU, habilitado pela etapa 10."
    fi

    # --- Clavis, quando ele e o shell da sessao ---
    #
    # O GATE E O ARTEFATO NO DISCO, NAO O MARKER. A tentacao seria
    # `step_done 16-clavis-build`, e ela esta errada por duas razoes que o
    # lib.sh:667 deixa claras: o run_step grava o marker quando o PROBE passa,
    # mesmo sem o do_fn rodar, e o `mark_done` sem valor grava a string literal
    # 'done' — que nao e o ref e faria o proprio probe da 16 reprovar depois.
    # Alem disso `step_value` nunca falha (retorna vazio via `|| true`), entao
    # usa-lo direto num `if` da sempre verdadeiro.
    #
    # O shell.qml e o mesmo predicado que a 16 usa para dizer "instalado". Ele
    # e um fato do disco: nao mente, nao depende da semantica de marker, e nao
    # exige que a 16 tenha rodado NESTA execucao.
    if [[ "$DESKTOP_CLAVIS" == "yes" ]]; then
        if [[ -f /etc/xdg/quickshell/clavis/shell.qml ]]; then
            check_ok "Clavis instalado (/etc/xdg/quickshell/clavis/shell.qml presente)"

            # O `key` e o que o spawn-at-startup invoca, e ele resolve por PATH.
            # Perguntamos ao USUARIO, nao ao root: o PATH e outro, e e o do
            # usuario que vale no login.
            if run_as_user command -v key &>/dev/null; then
                check_ok "'key' no PATH de '$DESKTOP_USER' (e o que o spawn-at-startup do niri invoca)"
            else
                check_fail "'key' NAO esta no PATH de '$DESKTOP_USER' — o spawn-at-startup do niri nao vai encontra-lo e o Clavis nao sobe" "A etapa 16 instala o key-cli num venv e liga /usr/local/bin/key. Rode: ./desktop/install-desktop.sh --only 16"
            fi

            if command -v qs &>/dev/null; then
                check_ok "'qs' (quickshell) encontrado — e o runtime que o 'key shell' executa"
            else
                check_fail "'qs' NAO esta no PATH: sem o quickshell o 'key shell' nao tem o que rodar" "emerge --noreplace gui-apps/quickshell (a etapa 16 cuida das keywords)"
            fi

            # Este projeto compila o Clavis fora do Portage, entao um upgrade de
            # Qt ou um --depclean podem deixar os modulos QML linkados contra uma
            # libQt6 que nao existe mais. O sintoma seria identico a "o shell nao
            # sobe", e sem esta checagem o diagnostico comecaria do lugar errado.
            local qml_so libs_faltando=""
            for qml_so in /usr/lib*/qt6/qml/Clavis/*.so; do
                [[ -f "$qml_so" ]] || continue
                if ldd "$qml_so" 2>/dev/null | grep -q 'not found'; then
                    libs_faltando="$libs_faltando ${qml_so##*/}"
                fi
            done
            if [[ -n "$libs_faltando" ]]; then
                check_fail "modulos QML do Clavis com biblioteca ausente:$libs_faltando" "O Clavis e compilado FORA do Portage, entao um upgrade de Qt nao o reconstroi. Recompile: ./desktop/install-desktop.sh --only 16 (apague antes o marker: rm $(state_dir)/16-clavis-build)"
            else
                check_ok "modulos QML do Clavis com todas as bibliotecas resolvidas (ldd)"
            fi
        else
            # AVISO e nao FALHA, e a distincao importa: a 15 roda ANTES da 16 no
            # ORDEM_ETAPAS. Numa instalacao limpa este caminho e o NORMAL, e
            # reprovar aqui abortaria o install-desktop.sh antes de o Clavis ter
            # tido a chance de ser instalado.
            check_warn "DESKTOP_CLAVIS=yes mas o Clavis ainda nao esta instalado" "Normal se a etapa 16 ainda nao rodou — ela vem DEPOIS desta na sequencia. Se ja rodou, houve falha: veja o log da 16."
        fi

        # Com o Clavis, barra e notificacoes vem do proprio shell. As sub-etapas
        # da 12 reportam 'nada a fazer' silenciosamente com 'none', entao o
        # usuario nunca leria o porque em lugar nenhum.
        [[ "$DESKTOP_BAR" == "none" ]] \
            && log_info "  (nota: DESKTOP_BAR=none porque o Clavis desenha a propria barra — nao ha waybar a validar)"
        [[ "$DESKTOP_NOTIFY" == "none" ]] \
            && log_info "  (nota: DESKTOP_NOTIFY=none porque o Clavis e o servidor de notificacoes — dois daemons disputariam org.freedesktop.Notifications)"
    fi

    # --- O Exec do .desktop: a armadilha mais cara do stack ---
    if [[ -f "$NIRI_SESSION_DESKTOP" ]]; then
        if _niri_desktop_exec_ok; then
            check_ok "$NIRI_SESSION_DESKTOP com Exec correto para OpenRC ($(grep -m1 '^Exec=' "$NIRI_SESSION_DESKTOP" 2>/dev/null || echo '(sem linha Exec=)'))"
        else
            check_fail "$NIRI_SESSION_DESKTOP tem 'Exec=niri-session', que em OpenRC MORRE no arranque (o script procura systemctl/dinitctl, nao acha, imprime 'No systemd or dinit detected' e sai)" "Significa que o niri foi construido com USE=systemd. NAO EDITE ESSE ARQUIVO A MAO — ele pertence ao ebuild e seria sobrescrito no proximo emerge. CORRIJA A CAUSA: confirme a linha 'gui-wm/niri dbus screencast -systemd' em /etc/portage/package.use/ (etapa 10) e reconstrua: emerge --changed-use gui-wm/niri"
        fi
    else
        # Ausencia e NORMAL neste projeto: sem display manager, ninguem le esse
        # arquivo. Registramos como nota para nao gerar ruido no placar.
        log_info "  (nota: $NIRI_SESSION_DESKTOP nao existe — normal com DESKTOP_GREETER=none, pois o arranque e pelo TTY e esse arquivo so e usado por display manager)"
    fi

    # --- Terminal: a ferramenta de recuperacao ---
    #
    # FALHA e nao AVISO, e a razao e pratica: entrar no niri sem terminal deixa o
    # usuario numa tela vazia, sem forma de abrir nada e sem saber como sair
    # (Mod+Shift+E nao e obvio). O terminal e o que torna a sessao diagnosticavel
    # — por isso a etapa 12 o trata como pre-condicao para se declarar concluida.
    if [[ -n "${DESKTOP_TERMINAL:-}" && "$DESKTOP_TERMINAL" != "none" ]]; then
        if user_has_bin "$DESKTOP_TERMINAL"; then
            check_ok "terminal '$DESKTOP_TERMINAL' disponivel no PATH de '$DESKTOP_USER'"
        else
            check_fail "o terminal '$DESKTOP_TERMINAL' NAO esta no PATH de '$DESKTOP_USER' — voce entraria numa sessao grafica sem conseguir abrir nada nem diagnosticar" "O bind Mod+T do config.kdl invoca esse binario POR NOME. Rode a etapa 12: ./desktop/install-desktop.sh --only 12"
        fi
    fi

    # --- Launcher (AVISO: com o terminal presente, a sessao segue utilizavel) ---
    if [[ -n "${DESKTOP_LAUNCHER:-}" && "$DESKTOP_LAUNCHER" != "none" ]]; then
        if user_has_bin "$DESKTOP_LAUNCHER"; then
            check_ok "launcher '$DESKTOP_LAUNCHER' disponivel no PATH de '$DESKTOP_USER'"
        else
            check_warn "o launcher '$DESKTOP_LAUNCHER' nao esta no PATH de '$DESKTOP_USER'" "O bind Mod+D falhara em SILENCIO (sem mensagem na tela). A sessao continua utilizavel pelo terminal. Rode a etapa 12 para instalar."
        fi
    fi

    # --- Xwayland: instalar o pacote NAO basta ---
    #
    # O niri nao integra o xwayland-satellite sozinho: e preciso declarar
    # spawn-at-startup no config.kdl (etapa 14). Verificamos as DUAS pecas,
    # porque cada uma sem a outra e inutil. Como a 14 roda DEPOIS desta, a
    # ausencia da linha ainda nao e problema — por isso tudo aqui e AVISO.
    if [[ "${DESKTOP_ENABLE_XWAYLAND:-no}" == "yes" ]]; then
        if user_has_bin xwayland-satellite; then
            if [[ -f "$NIRI_CONFIG" ]] && grep -q 'xwayland-satellite' "$NIRI_CONFIG" 2>/dev/null; then
                check_ok "xwayland-satellite instalado E declarado em spawn-at-startup no config.kdl"
            elif [[ -f "$NIRI_CONFIG" ]]; then
                check_warn "xwayland-satellite instalado, mas o config.kdl NAO o declara em spawn-at-startup" "O niri NAO integra Xwayland sozinho: sem essa linha NENHUM app X11 abre (inclui muitos jogos e Electron antigo). A etapa 14 escreve essa linha."
            else
                check_warn "xwayland-satellite instalado; o config.kdl ainda nao existe" "Normal se a etapa 14 ainda nao rodou. Ela precisa declarar 'spawn-at-startup \"xwayland-satellite\"', senao nenhum app X11 abre."
            fi
        else
            check_warn "DESKTOP_ENABLE_XWAYLAND=yes, mas 'xwayland-satellite' nao esta no PATH" "Nenhum aplicativo X11 abrira na sessao (o niri nao tem Xwayland embutido). A sessao Wayland em si funciona normalmente. Rode a etapa 12."
        fi
    fi

    # --- Barra de status ---
    if [[ "${DESKTOP_BAR:-none}" != "none" ]]; then
        if user_has_bin "$DESKTOP_BAR"; then
            check_ok "barra '$DESKTOP_BAR' disponivel no PATH de '$DESKTOP_USER'"
        else
            check_warn "a barra '$DESKTOP_BAR' nao esta no PATH de '$DESKTOP_USER'" "Se o config.kdl declarar o spawn dela, o compositor registra erro de spawn no log a cada boot — ruido que atrapalha o diagnostico. A sessao funciona sem barra. Rode a etapa 12."
        fi
    fi

    check_niri_config
}

# ===========================================================================
# 15-report — veredicto final
# ===========================================================================
#
# O relatorio nao repete a tabela: ele CONCLUI. Imprime o placar, as falhas e os
# avisos com a acao corretiva de cada um, e — no bloco final, fora do run_step —
# os pontos que a pesquisa NAO conseguiu confirmar.

# PROBE: sempre reprova ate que o do_fn tenha rodado NESTA execucao.
#
# O relatorio e a SAIDA do script — pula-lo porque "ja rodou antes" produziria
# uma execucao silenciosa, que e o oposto do proposito desta etapa. A global
# abaixo faz o run_step aceitar a sub-etapa depois que o do_fn imprimiu.
probe_report() {
    [[ "${_REPORT_DONE:-nao}" == "sim" ]]
}

do_report() {
    printf '\n'
    printf '========================================================================\n'
    printf '  15-validate — RELATORIO DA SESSAO\n'
    printf '========================================================================\n'
    printf 'usuario alvo    : %s\n' "$DESKTOP_USER"
    printf 'provedor de seat: %s (runlevel esperado: %s)\n' "$SEAT_SVC" "$SEAT_RUNLEVEL"
    printf 'verificacoes    : %d OK, %d aviso(s), %d falha(s)\n' \
        "${#OKS[@]}" "${#AVISOS[@]}" "${#FALHAS[@]}"

    # Itens sao gravados como "titulo|o-que-fazer" e separados aqui. O separador
    # '|' nao aparece em nenhum titulo escrito neste arquivo.
    local _item
    if (( ${#AVISOS[@]} > 0 )); then
        printf '\n--- AVISOS (a sessao sobe, porem degradada) ---\n'
        for _item in "${AVISOS[@]}"; do
            printf '\n  * %s\n' "${_item%%|*}"
            printf '    -> %s\n' "${_item#*|}"
        done
    fi

    if (( ${#FALHAS[@]} > 0 )); then
        printf '\n--- FALHAS (a sessao NAO vai subir) ---\n'
        for _item in "${FALHAS[@]}"; do
            printf '\n  * %s\n' "${_item%%|*}"
            printf '    -> %s\n' "${_item#*|}"
        done
    fi

    printf '\n========================================================================\n'

    _REPORT_DONE="sim"
}

# ===========================================================================
# Execucao
# ===========================================================================
#
# Ordem deliberada: primeiro o caminho grafico (a razao de o script existir),
# depois seat/sessao, depois os arquivos que a sessao invoca, e por fim o
# relatorio.
#
# NOTA SOBRE run_as_user: check_audio_route e as verificacoes de binario do
# usuario o utilizam, e na rota seatd o `su -` executa o ~/.bash_profile como
# efeito colateral. O snapshot do XDG_RUNTIME_DIR (topo do arquivo) ja protege a
# medicao contra isso; esta ordem e a segunda linha de defesa.

log_info "==== validacao pre-reboot — usuario '$DESKTOP_USER', rota '$DESKTOP_SEAT_PROVIDER' ===="

# Sob --dry-run paramos AQUI — e este e o unico numerado onde a guarda NAO
# existe por causa de efeito colateral. As verificacoes daqui para baixo sao
# todas somente-leitura (pkg_installed, stat, grep, `rc-update show`,
# `rc-service status`): nenhum emerge, nenhuma escrita em /etc ou no $HOME,
# nenhum servico habilitado ou iniciado. Rodar tudo isso num dry-run seria, em
# si, inofensivo. A guarda esta aqui por DOIS motivos concretos:
#
#   1. ESTADO. As linhas finais gravam `mark_done 15-validate "ok"` ou apagam o
#      marker com `clear_marker 15-validate`. E pouco, mas e disco, e --dry-run
#      promete nao escrever nada — e um marker mentiroso aqui e pior que a
#      media, porque ele afirma "esta maquina passou na validacao".
#
#   2. FALHA ESPURIA, que e a razao mais forte. Num dry-run nada foi instalado,
#      nenhum servico foi habilitado e nenhuma USE foi escrita: as verificacoes
#      reprovariam em bloco e o `die` do fim do arquivo mataria o script. Como a
#      ORDEM_ETAPAS e (10 11 12 13 15 14), o orquestrador abortaria ali e a
#      etapa 14 nunca apareceria no dry-run. O usuario receberia um relatorio de
#      desastre logo depois de ler "nenhuma config sera escrita" — assustador,
#      inutil e falso, porque o que ele mediu foi o sistema que ele ja tinha, e
#      nao o resultado do modulo.
#
# Validar de verdade exige o sistema de verdade: rode este script sem --dry-run,
# depois que as etapas 10 a 13 tiverem rodado.
dry_run_guard 15-check-egl 15-check-seat 15-check-session-files 15-report

run_step 15-check-egl           probe_check_egl           do_check_egl
run_step 15-check-seat          probe_check_seat          do_check_seat
run_step 15-check-session-files probe_check_session_files do_check_session_files
run_step 15-report              probe_report              do_report

# ---------------------------------------------------------------------------
# Pontos NAO VALIDADOS — o que observar no primeiro boot
# ---------------------------------------------------------------------------
#
# Impresso SEMPRE, com falha ou sem falha, e de proposito fora do run_step: sao
# coisas que so se manifestam APOS o primeiro boot grafico e que NENHUM script
# pode verificar por antecipacao. Se o usuario nao souber que existem, vai
# interpretar um sintoma esperado (tela preta ao trocar de TTY, 1 GiB de VRAM)
# como defeito irrecuperavel — e possivelmente reinstalar o sistema por nada.

cat <<'NAOVALIDADO'

========================================================================
  PONTOS NAO VALIDADOS — o que observar no PRIMEIRO BOOT GRAFICO
========================================================================
Os itens abaixo NAO puderam ser verificados por este script, e nao por
descuido: eles so se manifestam depois que a sessao grafica sobe. Estao
aqui para que voce reconheca o sintoma em vez de confundi-lo com defeito.

1) HANDOFF simpledrm -> nvidia-drm SEM INITRAMFS  (o maior risco do projeto)
   Este kernel e compilado SEM initramfs e com DRM_SIMPLEDRM +
   FRAMEBUFFER_CONSOLE. O modulo nvidia carrega TARDE, e a transicao do
   simpledrm para o nvidia-drm e uma janela que ninguem testou nesta
   combinacao exata (kernel sem initramfs + simpledrm + Blackwell/GB206).

   SINTOMA: tela preta no boot, ou o console para de responder ao trocar
   de TTY (Ctrl+Alt+F1..F6).

   ESCAPE HATCH (a primeira coisa a tentar):
       descomente 'options nvidia-drm fbdev=0' em /etc/modprobe.d/nvidia.conf
   O driver vem com fbdev LIGADO por default e assume o console, sobrepondo
   o simpledrm. O fbdev=0 desfaz exatamente esse comportamento — o proprio
   comentario do arquivo reconhece que isso causa problema em alguns setups.

   IMPORTANTE: esse arquivo PERTENCE ao ebuild. Descomentar a linha que ja
   existe la e o caminho certo; nao o reescreva do zero, ou voce perde as
   opcoes de suspend/resume corretas do seu ramo de driver.

2) VAZAMENTO DE VRAM no driver proprietario
   O niri deveria usar por volta de 100 MiB de VRAM. Se voce ver ~1 GiB no
   nvtop ou no nvidia-smi, foi afetado pelo bug de heap (o driver nao
   devolve os buffers ao pool).

   CORRECAO: application profile com GLVidHeapReuseRatio=0 para o processo
   'niri', em /etc/nvidia/nvidia-application-profiles-rc.d/.

   VERIFIQUE ANTES DE ESCREVER: drivers recentes ja embarcam esse profile
   com o valor correto. Sobrescrever as cegas pode conflitar com o arquivo
   do proprio driver — inspecione o diretorio antes de criar qualquer coisa.

3) PORTALS (xdg-desktop-portal) SOB OpenRC
   As fontes DIVERGEM e nao ha como decidir isto sem testar no hardware:
     - o wiki do Gentoo afirma que os portals exigem o script niri-session;
     - o autor do niri afirma que 'niri --session' ja sobe os servicos
       D-Bus dele, incluindo o portal de screencast.
   Em OpenRC nao existe systemd user unit: os portals sao ativados por D-Bus.

   SINTOMA se estiver quebrado: compartilhamento de tela nao funciona, e os
   dialogos de "abrir arquivo" de apps GTK/Electron falham ou vem vazios.

   NAO tente resolver trocando para 'niri-session' — esse script NAO
   funciona em OpenRC (ver abaixo). Trate como validacao pendente.

========================================================================
NAOVALIDADO

# ---------------------------------------------------------------------------
# Veredicto e saida
# ---------------------------------------------------------------------------
#
# Sair com 1 quando ha FALHA e o que faz desta etapa um PORTAO de verdade: o
# install-desktop.sh interrompe a cadeia e a 14 nao roda. Isso e deliberado e
# segue a prioridade do projeto — escrever tema e fonte num sistema onde o
# compositor nao inicia e desperdicio, e ainda envenena o diagnostico, porque
# passa a misturar sintoma de tema com sintoma de compositor.
#
# Morremos DEPOIS de imprimir o relatorio inteiro, nunca antes: o usuario precisa
# ver TODOS os problemas de uma vez, e nao descobrir um por execucao.
if (( ${#FALHAS[@]} > 0 )); then
    # O marker e removido, e nao apenas deixado de escrever: um marker antigo de
    # uma rodada que passou seria uma afirmacao FALSA sobre o sistema de agora.
    clear_marker 15-validate
    die "$(( ${#FALHAS[@]} )) verificacao(oes) FALHARAM — a sessao grafica NAO vai subir deste jeito. Corrija os itens listados acima (cada um traz o comando exato; a maioria se resolve rodando a etapa 11 ou a 13) e rode esta validacao de novo: $0. NAO reinicie esperando que melhore: nenhum destes itens se resolve sozinho no boot, e depois do reboot voce pode nao ter console para diagnosticar. Log completo em $LOGFILE."
fi

# Chegou aqui: nenhuma falha. O marker registra QUE a validacao passou — ele nao
# e lido para pular trabalho (os probes medem o sistema real; ver o comentario
# sobre run_step no topo), serve como registro do ultimo resultado conhecido.
mark_done 15-validate "ok"

log_info "==== 15-validate concluido: nenhuma falha ===="
if (( ${#AVISOS[@]} > 0 )); then
    log_warn "${#AVISOS[@]} aviso(s) registrado(s) acima — nenhum impede a sessao de subir, mas vale ler."
fi

cat <<INSTRUCOES
========================================================================
  SESSAO VALIDADA — O QUE FAZER AGORA
========================================================================
As condicoes que decidem se o compositor sobe estao satisfeitas:

  * caminho EGL/GBM da NVIDIA presente e modesetting DRM ativo
  * $SEAT_SVC habilitado (runlevel '$SEAT_RUNLEVEL') e rodando
  * dbus habilitado (runlevel 'default') e rodando
  * '$DESKTOP_USER' nos grupos exigidos, com acesso ao DRM
  * XDG_RUNTIME_DIR com mecanismo de criacao no lugar
  * os binarios do comando de arranque existem

ANTES DE TESTAR, FACA LOGOUT/LOGIN (ou reinicie). Dois efeitos da etapa 13
so valem em sessoes NOVAS, e ignorar isso leva a um diagnostico errado —
voce veria a falha e concluiria que a validacao mentiu:

  1. a lista de grupos e fixada no LOGIN; o shell atual ainda tem a antiga
  2. XDG_RUNTIME_DIR nasce no login (pelo perfil do shell, na rota seatd,
     ou pelo PAM, na rota elogind)

Depois do novo login, a partir de um TTY e NAO como root:

    dbus-run-session niri --session

NUNCA use 'niri-session' em OpenRC: aquele script procura systemd ou dinit,
nao encontra, imprime "No systemd or dinit detected" e sai na hora.

SE A TELA FICAR PRETA OU A SESSAO MORRER MESMO ASSIM, nesta ordem:

    rc-service $SEAT_SVC status
        # o seat provider continua de pe?
    id -nG $DESKTOP_USER
        # os grupos entraram nesta sessao?
    echo \$XDG_RUNTIME_DIR
        # deve imprimir $XDG_DIR
    cat /sys/module/nvidia_drm/parameters/modeset
        # deve imprimir Y
    niri --session 2>&1 | tail -40
        # a mensagem real do compositor, sem o dbus-run-session no meio

Se nem o Ctrl+Alt+F2 devolver um TTY, veja o item (1) do bloco
"PONTOS NAO VALIDADOS" acima: o escape hatch e 'nvidia-drm fbdev=0'.

O passo seguinte e a etapa 14 (dotfiles e aparencia). Ela e cosmetica: se
algo la falhar, a sessao continua subindo.
========================================================================

INSTRUCOES
