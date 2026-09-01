#!/usr/bin/env bash
# 13-services.sh — habilita servicos, grupos e sessao. E o que transforma
# "pacotes instalados" num "sistema onde a sessao realmente inicia".
#
# Fase: sistema JA INSTALADO E BOOTADO (regra 2). Nunca no live ISO, nunca no
# chroot da instalacao — require_booted_system() recusa, fail-closed.
#
# POR QUE ESTA ETAPA EXISTE. A pesquisa foi enfatica e o codigo confirma: o
# instalador base (00-06) NAO configura seatd, NAO configura elogind e NAO
# configura dbus — um grep por esses nomes nos scripts 00-06 nao retorna nada.
# Consequencia pratica: um modulo de desktop que apenas rode `emerge niri`
# produz uma maquina onde o compositor COMPILA, INSTALA e NUNCA INICIA, porque
# falha ao abrir o seat. O sintoma e uma sessao que morre em silencio, quase
# sempre sem mensagem visivel, e e caro de diagnosticar sem saber disto.
#
# ORDEM DAS SUB-ETAPAS (cada uma existe porque a seguinte depende dela):
#   13-seat-service       : seat provider de pe (seatd OU elogind)
#   13-dbus-service       : dbus no boot — 'dbus-run-session' precisa existir
#   13-user-groups        : video/input (+seat) no usuario, de forma ADITIVA
#   13-pam-session        : (so elogind) prova que pam_elogind.so esta ativo
#   13-xdg-runtime-dir    : (so seatd) supre o furo conhecido da rota seatd
#   13-audio-user-services: PipeWire como servico de USUARIO, nao de sistema
#
# ESTE SCRIPT VEM DEPOIS DO 12 de proposito: so da para habilitar servico de
# pacote que ja esta instalado. Rodar antes daria "service not found" em vez de
# uma mensagem util.
#
# O QUE ESTE SCRIPT DELIBERADAMENTE NAO FAZ:
#   - nao toca em NENHUM arquivo do instalador base (regra 1)
#   - nao usa `usermod -G` (substituiria a lista de grupos e removeria
#     wheel/portage/audio que o 06 configurou) — so `gpasswd -a`, aditivo
#   - nao edita /etc/pam.d/ as cegas (arquivo de configuracao do sistema com
#     update pendente do Portage; editar por cima e destrutivo — regra 4)
#   - nao instala seatd E elogind juntos (sao provedores CONCORRENTES)
#   - nao roda `rc-update add pipewire default` como root: nao existe servico
#     de SISTEMA para o PipeWire, e o proprio ebuild marca USE=system-service
#     como "Not recommended"
#   - nao remove pacote, nao formata, nao reparticiona (regra 4)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib-desktop.sh ja faz, nesta ordem: TARGET_ROOT="" -> vars.sh -> lib.sh ->
# vars-desktop.sh. O TARGET_ROOT vazio e o que faz state_dir() apontar para
# /var/lib/gentoo-install/state no sistema bootado (ver a "armadilha central"
# documentada no topo do lib-desktop.sh). NAO sourceie vars.sh/lib.sh aqui.
# shellcheck source=./lib-desktop.sh disable=SC1091
source "$SCRIPT_DIR/lib-desktop.sh"

init_logging_desktop 13-services
# Repetida aqui, e nao so no install-desktop.sh, porque os scripts do projeto
# rodam standalone para debug — mesmo padrao do require_phase nos 00-06.
require_booted_system
require_root

# ---------------------------------------------------------------------------
# Resolucao do usuario alvo
# ---------------------------------------------------------------------------
#
# DESKTOP_USER pode vir vazio de vars-desktop.sh (o default la e vazio DE
# PROPOSITO, com deteccao em runtime). Aqui ele precisa existir de verdade:
# adicionar grupo a um usuario inexistente e uma falha silenciosa das caras —
# o comando falha, o script segue, e a sessao quebra so no proximo boot.
[[ -n "${DESKTOP_USER:-}" ]] \
    || die "DESKTOP_USER esta vazio. Defina o usuario alvo em vars-desktop.sh ou no ambiente (ex.: DESKTOP_USER=rodrigo $0). Este script precisa saber a QUEM adicionar os grupos video/input/seat — sem isso a sessao grafica nao abre o seat."

id -u "$DESKTOP_USER" &>/dev/null \
    || die "o usuario '$DESKTOP_USER' nao existe neste sistema. Confira com 'getent passwd' e ajuste DESKTOP_USER. O instalador base cria o usuario definido em USERNAME (vars.sh)."

# Validacao da escolha de provedor de seat. Fail-closed: um valor digitado
# errado (ex.: "logind") nao pode virar "nenhum dos dois ramos rodou" em
# silencio, que deixaria a maquina sem seat provider nenhum.
case "$DESKTOP_SEAT_PROVIDER" in
    seatd|elogind) : ;;
    *)
        die "DESKTOP_SEAT_PROVIDER='$DESKTOP_SEAT_PROVIDER' e invalido. Valores aceitos: 'seatd' ou 'elogind'. Sao provedores CONCORRENTES de seat/sessao — escolha UM, nunca os dois (dois daemons de seat brigam pelo mesmo recurso)."
        ;;
esac

log_info "provedor de seat escolhido: $DESKTOP_SEAT_PROVIDER | usuario alvo: $DESKTOP_USER"

# ---------------------------------------------------------------------------
# Helpers locais (somente leitura — usados pelos probes)
# ---------------------------------------------------------------------------

# svc_in_runlevel <servico> <runlevel>: 0 se o servico esta no runlevel.
#
# Mesma logica de comparacao do svc_enable do lib.sh (linha 1211): pega a
# PRIMEIRA coluna do `rc-update show` e compara a linha INTEIRA com grep -qx.
# O -x importa: sem ele, "dbus" casaria com um hipotetico "dbus-daemon", e o
# probe reportaria "feito" para um servico que nao esta habilitado.
svc_in_runlevel() {
    local svc="$1" runlevel="$2"
    rc-update show "$runlevel" 2>/dev/null | awk '{print $1}' | grep -qx "$svc"
}

# svc_running <servico>: 0 se o servico esta RODANDO AGORA.
#
# Distincao que importa e que o svc_enable do lib.sh nao cobre: `rc-update add`
# so agenda o servico para o PROXIMO boot. Um seatd habilitado porem parado
# significa que o niri, se iniciado agora, ainda falha ao abrir o seat. Por isso
# o probe desta etapa exige as DUAS coisas — habilitado E de pe.
#
# `rc-service <svc> status` retorna 0 apenas quando o servico esta started.
svc_running() {
    rc-service "$1" status &>/dev/null
}

# svc_script_exists <servico>: 0 se o init script existe em /etc/init.d.
#
# Serve para dar uma mensagem ACIONAVEL antes de chamar rc-update: sem isto, um
# pacote nao instalado (ou instalado com a USE errada) produziria um erro cru do
# rc-update, sem dizer QUAL pacote falta nem POR QUE.
svc_script_exists() {
    [[ -x "/etc/init.d/$1" ]]
}

# user_in_group <usuario> <grupo>: 0 se o usuario ja pertence ao grupo.
# `id -nG` lista os grupos EFETIVOS resolvidos pelo sistema (inclui o grupo
# primario), que e a autoridade real — mais confiavel que parsear /etc/group,
# que ignoraria o grupo primario e fontes NSS que nao sejam arquivos locais.
user_in_group() {
    local user="$1" grp="$2"
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"
}

# group_exists <grupo>: 0 se o grupo existe no sistema.
# Necessario porque `gpasswd -a` falha se o grupo nao existe, e o grupo 'seat'
# so passa a existir DEPOIS que o sys-auth/seatd e instalado (o ebuild o cria).
group_exists() {
    getent group "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# Guarda de init: este script inteiro pressupoe OpenRC
# ---------------------------------------------------------------------------
#
# INIT_SYSTEM=openrc e o DEFAULT do instalador e o unico caminho JA EXECUTADO
# neste projeto (systemd e suportado no codigo mas nunca foi rodado). Todos os
# comandos abaixo — rc-update, rc-service, `rc-update add -U`, o runlevel 'boot'
# do elogind — sao especificos de OpenRC.
#
# Fail-closed: em vez de deixar cada sub-etapa falhar com um erro cru de
# "rc-update: command not found", recusamos aqui com a explicacao completa.
if [[ "${INIT_SYSTEM:-openrc}" != "openrc" ]]; then
    die "INIT_SYSTEM='${INIT_SYSTEM:-}' — este script implementa somente o caminho OpenRC. Todos os comandos usados aqui (rc-update, rc-service, 'rc-update add -U' para servicos de usuario, runlevel 'boot' do elogind) sao especificos de OpenRC. Em systemd a configuracao de seat/sessao e completamente diferente (systemd-logind ja fornece seat, XDG_RUNTIME_DIR e session tracking nativamente, e o PipeWire usa 'systemctl --user enable'). O caminho systemd nunca foi executado neste projeto e nao sera adivinhado aqui."
fi

command -v rc-update &>/dev/null \
    || die "o comando 'rc-update' nao existe, mas INIT_SYSTEM=openrc. Sem ele nao ha como habilitar servico nenhum. Verifique se sys-apps/openrc esta instalado."

# ===========================================================================
# 13-seat-service — o provedor de seat de pe
# ===========================================================================
#
# O QUE E UM SEAT PROVIDER E POR QUE ELE E OBRIGATORIO: o compositor Wayland
# precisa abrir /dev/dri (DRM) e os dispositivos de input SEM rodar como root.
# Quem concede esse acesso e o seat provider. O niri declara DEPEND direto em
# sys-auth/seatd:= — ou seja, a biblioteca (libseat) entra na maquina de
# qualquer jeito; o que se decide aqui e qual BACKEND vai atende-la.
#
# RUNLEVEL IMPORTA, E ERRAR E CAUSA CLASSICA DE FALHA:
#   seatd   -> runlevel 'default' (confirmado no wiki Gentoo do Seatd:
#              "rc-update add seatd default")
#   elogind -> runlevel 'boot', NAO 'default' (confirmado no wiki Gentoo do
#              elogind: "rc-update add elogind boot")
#
# A razao do 'boot' no elogind e de ordem: ele precisa estar de pe ANTES de o
# PAM criar a sessao de login. No runlevel 'default' ele sobe tarde demais, e o
# resultado e a primeira sessao nascer quebrada — sem XDG_RUNTIME_DIR e sem
# registro no loginctl. Como o sintoma aparece so no login seguinte, esse erro e
# especialmente confuso.

if [[ "$DESKTOP_SEAT_PROVIDER" == "seatd" ]]; then
    SEAT_SVC="seatd"
    SEAT_RUNLEVEL="default"
    SEAT_PKG="sys-auth/seatd"
else
    SEAT_SVC="elogind"
    SEAT_RUNLEVEL="boot"
    SEAT_PKG="sys-auth/elogind"
fi

# PROBE FUNCIONAL, nao marker: exige as duas condicoes REAIS — habilitado no
# runlevel certo E rodando agora. Um seatd habilitado porem parado nao serve
# para a sessao que o usuario vai abrir daqui a pouco.
probe_seat_service() {
    svc_in_runlevel "$SEAT_SVC" "$SEAT_RUNLEVEL" && svc_running "$SEAT_SVC"
}

do_seat_service() {
    # O pacote precisa estar instalado ANTES: e ele que traz o init script.
    pkg_installed "$SEAT_PKG" \
        || die "$SEAT_PKG nao esta instalado, entao nao existe o init script '/etc/init.d/$SEAT_SVC' para habilitar. Rode a etapa 12-niri-stack antes desta (ela instala o compositor e o provedor de seat). Sem um provedor de seat de pe, o compositor nao consegue abrir /dev/dri e a sessao morre no arranque."

    # Init script ausente com pacote instalado = quase sempre USE flag errada.
    # Esta e a mensagem que economiza a hora de diagnostico: no seatd, o init
    # script so e instalado com USE=server; sem ele o pacote entrega apenas a
    # libseat e nao ha daemon nenhum para habilitar.
    if ! svc_script_exists "$SEAT_SVC"; then
        if [[ "$SEAT_SVC" == "seatd" ]]; then
            die "$SEAT_PKG esta instalado, mas '/etc/init.d/seatd' NAO existe. A causa quase certa e USE flag: o init script do seatd so e instalado com USE=server, e o wiki Gentoo do Seatd exige 'builtin' E 'server' para a rota OpenRC. Verifique com: portageq metadata / ebuild \$(portageq best_visible / $SEAT_PKG) IUSE — e confirme que a etapa 10-portage-desktop escreveu 'sys-auth/seatd builtin server' em /etc/portage/package.use/. Depois reinstale com: emerge --newuse $SEAT_PKG"
        else
            die "$SEAT_PKG esta instalado, mas '/etc/init.d/elogind' NAO existe. Verifique se o pacote foi construido para OpenRC (USE=-systemd) e reinstale com: emerge --newuse $SEAT_PKG"
        fi
    fi

    # REUSO do svc_enable do lib.sh (linha 1211): ja e idempotente (checa
    # `rc-update show` antes de adicionar) e ja bifurca OpenRC/systemd.
    # Nao ha razao para reimplementar — regra do projeto.
    svc_enable "$SEAT_SVC" "$SEAT_RUNLEVEL"

    # Habilitar so agenda para o proximo boot; queremos o servico de pe AGORA,
    # para que a validacao do 15 possa testar a sessao sem exigir reboot.
    if ! svc_running "$SEAT_SVC"; then
        log_info "iniciando o servico '$SEAT_SVC' agora (rc-update apenas agenda para o proximo boot)"
        rc-service "$SEAT_SVC" start \
            || die "'rc-service $SEAT_SVC start' FALHOU. Sem o provedor de seat rodando, o compositor nao consegue acesso a DRM/input e a sessao grafica nao inicia. Veja o log do servico com 'rc-service $SEAT_SVC status' e $LOGFILE."
    fi
}

# Sob --dry-run paramos AQUI. As recusas la em cima JA rodaram de proposito
# (INIT_SYSTEM != openrc, ausencia do rc-update, usuario inexistente): sao
# somente-leitura e sao justamente o que um dry-run deveria descobrir. Daqui
# para baixo mexemos no sistema de verdade — rc-update, rc-service start,
# gpasswd, /etc/local.d e o ~/.bash_profile do usuario.
dry_run_guard 13-seat-service 13-dbus-service 13-user-groups 13-pam-session \
              13-xdg-runtime-dir 13-audio-user-services

run_step 13-seat-service probe_seat_service do_seat_service

# ===========================================================================
# 13-dbus-service — o barramento de sistema
# ===========================================================================
#
# POR QUE E INDISPENSAVEL, e nao "mais um servico": o comando canonico de
# arranque do niri em OpenRC e literalmente
#
#     dbus-run-session niri --session
#
# O binario `dbus-run-session` vem do sys-apps/dbus. Sem o pacote, o comando de
# arranque NAO EXISTE. E o niri --session, por sua vez, importa as variaveis de
# ambiente para o D-Bus e registra os servicos D-Bus dele (incluindo o portal de
# screencast) — sem barramento, tudo isso morre em silencio.
#
# O dbus costuma entrar como dependencia transitiva, mas a dependencia instala o
# PACOTE; ela nao HABILITA o servico. Sao coisas diferentes, e o instalador base
# nao faz nem uma nem outra (grep por dbus nos 00-06: zero ocorrencias).

probe_dbus_service() {
    svc_in_runlevel dbus default && svc_running dbus
}

do_dbus_service() {
    pkg_installed sys-apps/dbus \
        || die "sys-apps/dbus nao esta instalado. Ele e obrigatorio: o arranque do niri em OpenRC e 'dbus-run-session niri --session', e esse binario vem deste pacote. Rode a etapa 12-niri-stack antes desta."

    svc_script_exists dbus \
        || die "sys-apps/dbus esta instalado mas '/etc/init.d/dbus' nao existe. Reinstale com: emerge --newuse sys-apps/dbus"

    svc_enable dbus default

    if ! svc_running dbus; then
        log_info "iniciando o servico 'dbus' agora"
        rc-service dbus start \
            || die "'rc-service dbus start' FALHOU. Sem o barramento de sistema, 'dbus-run-session niri --session' nao funciona e os portais/notificacoes nao sobem. Veja $LOGFILE."
    fi
}

run_step 13-dbus-service probe_dbus_service do_dbus_service

# ===========================================================================
# 13-user-groups — acesso a DRM e input, de forma ADITIVA
# ===========================================================================
#
# GRUPOS E POR QUE CADA UM:
#   video : acesso aos dispositivos DRM (/dev/dri/*). Exigido pelo wiki Gentoo
#           do Seatd e necessario para a GPU NVIDIA. O instalador base JA
#           adiciona 'video' (USER_GROUPS=wheel,audio,video,usb,portage), entao
#           aqui normalmente e um no-op — mas o probe confirma em vez de supor.
#   input : acesso aos dispositivos de entrada. Com elogind o acesso vem por ACL
#           da sessao; o grupo e o FALLBACK de quando a sessao nao e reconhecida
#           — exatamente o cenario de diagnostico em que voce mais precisa dele.
#   seat  : SO na rota seatd. O wiki Gentoo do Seatd o exige explicitamente
#           ("gpasswd -a larry seat"). Sem ele o compositor falha ao abrir o
#           seat e morre no arranque.
#
# REGRA 4, APLICADA COM RIGOR — POR QUE `gpasswd -a` E NUNCA `usermod -G`:
# `usermod -G a,b,c` SUBSTITUI a lista inteira de grupos suplementares. Usa-lo
# aqui removeria wheel, audio, usb e portage, que o 06 configurou — quebrando o
# sudo do usuario de quebra. `gpasswd -a` acrescenta UM grupo e nao remove nada.
# A diferenca e a fronteira entre aditivo e destrutivo.

# Monta a lista de grupos exigidos conforme a rota escolhida.
DESKTOP_GROUPS=(video input)
if [[ "$DESKTOP_SEAT_PROVIDER" == "seatd" ]]; then
    DESKTOP_GROUPS+=(seat)
fi

# Grupo 'pipewire': o wiki do PipeWire recomenda adicionar o usuario a ele.
# ATENCAO A UMA SUTILEZA DO WIKI: ele tambem diz que o usuario tipicamente NAO
# deve estar no grupo 'audio' (isso permite controle exclusivo do dispositivo e
# atrapalha o PipeWire). O instalador base JA colocou o usuario em 'audio' — e
# este modulo NAO o remove, porque remover grupo e destrutivo e esta fora do
# escopo (regra 4). Fica registrado como observacao no relatorio final.
if group_exists pipewire; then
    DESKTOP_GROUPS+=(pipewire)
fi

probe_user_groups() {
    local grp
    for grp in "${DESKTOP_GROUPS[@]}"; do
        # Grupo que nem existe no sistema nao pode estar "OK" — reprovar aqui
        # faz o do_fn rodar e emitir a mensagem explicativa correta.
        group_exists "$grp" || return 1
        user_in_group "$DESKTOP_USER" "$grp" || return 1
    done
    return 0
}

do_user_groups() {
    local grp
    for grp in "${DESKTOP_GROUPS[@]}"; do
        if ! group_exists "$grp"; then
            # O grupo 'seat' e criado pelo ebuild do sys-auth/seatd; se ele nao
            # existe, o pacote nao foi instalado (ou foi com a USE errada).
            if [[ "$grp" == "seat" ]]; then
                die "o grupo 'seat' nao existe neste sistema. Ele e criado pelo ebuild do sys-auth/seatd — sua ausencia indica que o pacote nao foi instalado. Rode a etapa 12-niri-stack antes desta. Sem o grupo 'seat', o compositor falha ao abrir o seat e a sessao morre no arranque."
            fi
            die "o grupo '$grp' nao existe neste sistema, entao nao ha como adicionar '$DESKTOP_USER' a ele. Grupos 'video' e 'input' fazem parte do baselayout do Gentoo — a ausencia deles indica um sistema base incompleto. Confira com: getent group $grp"
        fi

        if user_in_group "$DESKTOP_USER" "$grp"; then
            log_info "usuario '$DESKTOP_USER' ja pertence ao grupo '$grp' — nada a fazer"
            continue
        fi

        # ADITIVO, um grupo por vez. Nunca `usermod -G` (ver comentario acima).
        gpasswd -a "$DESKTOP_USER" "$grp" \
            || die "falha ao adicionar '$DESKTOP_USER' ao grupo '$grp' com gpasswd. Veja $LOGFILE."
        log_info "usuario '$DESKTOP_USER' adicionado ao grupo '$grp' (aditivo, nenhum grupo removido)"
    done

    # AVISO QUE EVITA UM DIAGNOSTICO ERRADO: mudanca de grupo so vale para
    # sessoes NOVAS. O shell atual (e qualquer sessao ja aberta) continua com a
    # lista antiga ate o proximo login. Quem testar o niri sem deslogar vai ver
    # a falha de seat e concluir que esta etapa nao funcionou.
    log_warn "grupos so passam a valer em sessoes NOVAS — faca logout/login (ou reinicie) antes de testar a sessao grafica. Verifique depois com: id -nG $DESKTOP_USER"
}

run_step 13-user-groups probe_user_groups do_user_groups

# ===========================================================================
# 13-pam-session — SOMENTE na rota elogind
# ===========================================================================
#
# ESTA E A CAUSA #1 DE "elogind instalado, servico rodando, e mesmo assim
# loginctl nao mostra sessao e XDG_RUNTIME_DIR nao existe".
#
# O modulo PAM pam_elogind.so precisa estar referenciado em /etc/pam.d. As
# linhas chegam como ATUALIZACAO do Portage para arquivos ja existentes em
# /etc/pam.d/ e, por causa do CONFIG_PROTECT, ficam paradas em arquivos ._cfg*
# ate alguem rodar dispatch-conf ou etc-update. Ou seja: o pacote esta
# instalado, o servico esta de pe, e a peca que falta e uma linha de texto que o
# Portage deixou numa fila que ninguem esvaziou.
#
# POR QUE O PROBE OLHA O CONTEUDO E NAO O PACOTE: verificar `pkg_installed
# sys-auth/elogind` reportaria "feito" exatamente no cenario quebrado descrito
# acima. O unico probe honesto le o arquivo real.
#
# POR QUE O do_fn NAO EDITA O ARQUIVO: /etc/pam.d/system-login e um arquivo de
# configuracao do SISTEMA, sob CONFIG_PROTECT, com uma atualizacao pendente do
# proprio Portage. Escrever por cima com um append cego (a) pode inserir a linha
# na ordem errada — em PAM a ORDEM DAS LINHAS e semantica, e uma linha no lugar
# errado pode TRANCAR O USUARIO PARA FORA do sistema; e (b) conflitaria com o
# ._cfg pendente, dobrando a linha quando ele fosse finalmente aplicado.
# Errar aqui custa o acesso a maquina. Instruir e a acao correta e segura.

probe_pam_session() {
    # Rota seatd nao usa PAM do elogind: a etapa nao se aplica e o probe passa.
    # Retornar 0 aqui faz o run_step registrar como concluida sem executar nada
    # — que e a semantica correta de "nao se aplica a esta configuracao".
    [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]] || return 0

    # grep -q em arquivo inexistente ja retorna != 0, o que reprova o probe e
    # leva a mensagem explicativa. Sem -F/-x aqui de proposito: a linha pode ter
    # variacoes de espacamento e o prefixo '-' opcional; o que importa e a
    # PRESENCA de uma referencia ativa (nao comentada) ao modulo.
    grep -qE '^[[:space:]]*-?session.*pam_elogind\.so' /etc/pam.d/system-login 2>/dev/null
}

do_pam_session() {
    # Chegar aqui com seatd seria um bug de logica (o probe ja retornou 0).
    [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]] || return 0

    log_error "pam_elogind.so NAO esta referenciado em /etc/pam.d/system-login."

    # Diagnostico util: mostrar o que EXISTE hoje, para o usuario ver o estado
    # real em vez de acreditar na nossa descricao dele.
    log_info "referencias a elogind encontradas hoje em /etc/pam.d/:"
    grep -r elogind /etc/pam.d/ 2>/dev/null | while IFS= read -r line; do
        log_info "    $line"
    done || true

    # Procura os ._cfg pendentes: se existirem, esta e a prova de que o
    # diagnostico acima esta certo e a correcao e simplesmente aplicar o update.
    local pending
    pending="$(find /etc/pam.d -maxdepth 1 -name '._cfg*' 2>/dev/null | head -n 20)" || pending=""
    if [[ -n "$pending" ]]; then
        log_warn "ha atualizacoes de configuracao PENDENTES em /etc/pam.d/ (arquivos ._cfg):"
        printf '%s\n' "$pending" | while IFS= read -r f; do
            log_warn "    $f"
        done
    fi

    die "$(cat <<EOF
CONFIGURACAO PAM DO ELOGIND AUSENTE — acao manual necessaria.

O que falta: a linha
    -session    optional    pam_elogind.so
em /etc/pam.d/system-login (e 'session optional pam_elogind.so' em
/etc/pam.d/elogind-user).

Por que isso importa: sem essa linha o PAM nao registra a sessao no elogind.
O sintoma e enganoso — o pacote esta instalado e o servico esta rodando, mas
'loginctl' nao lista sessao nenhuma, XDG_RUNTIME_DIR nunca e criado e o
compositor nao encontra seat. E a causa numero um dessa falha.

Por que este script NAO corrige sozinho: /etc/pam.d/system-login esta sob
CONFIG_PROTECT do Portage e quase sempre ja tem a atualizacao correta parada
num arquivo ._cfg. Em PAM a ORDEM das linhas e semantica: inserir no lugar
errado pode TRANCAR VOCE PARA FORA do sistema. Um append cego tambem
duplicaria a linha quando o ._cfg fosse aplicado. Aplicar o update pendente e
a acao correta e segura.

COMO CORRIGIR:
    dispatch-conf        # (recomendado: mostra o diff antes de aplicar)
  ou
    etc-update

Depois confira e rode este script de novo:
    grep -r elogind /etc/pam.d/
    $0
EOF
)"
}

run_step 13-pam-session probe_pam_session do_pam_session

# ===========================================================================
# 13-xdg-runtime-dir — SOMENTE na rota seatd
# ===========================================================================
#
# O FURO CONHECIDO DA ROTA SEATD: o seatd resolve APENAS seat management. Ele
# NAO cria XDG_RUNTIME_DIR — essa e responsabilidade do logind, que na rota
# seatd nao existe. E XDG_RUNTIME_DIR e onde vivem os sockets do Wayland, do
# PipeWire e do D-Bus de sessao: sem ele, nada disso funciona.
#
# Sao DUAS pecas, e faltar qualquer uma quebra tudo:
#   1. /run/user existir, com o sticky bit (parte de SISTEMA, via /etc/local.d)
#   2. /run/user/$UID existir com modo 0700 e a variavel exportada (parte de
#      USUARIO, no perfil do shell)
#
# Ambas vem do wiki Gentoo "Configuring a system without elogind" — conteudo
# literal, nao inventado. /run e tmpfs, some a cada boot: por isso a peca 1 e um
# script de local.d (roda a cada boot) e nao um mkdir feito uma vez.
#
# Com elogind esta etapa e PULADA: seria conflitante, porque o elogind ja cria e
# gerencia /run/user/$UID com o ciclo de vida da sessao.

LOCAL_D_SCRIPT="/etc/local.d/create-runuser.start"

# Trecho para o perfil do usuario. Conteudo do wiki, com uma unica adaptacao
# deliberada: o wiki usa [[ ]] (bashism) num script /bin/sh; aqui o destino e o
# ~/.bash_profile do usuario, que E bash, entao a construcao e valida.
# O guard `test -z` garante idempotencia de execucao: se o elogind (ou um DM)
# ja definiu XDG_RUNTIME_DIR, o trecho respeita o valor existente.
read -r -d '' XDG_PROFILE_SNIPPET <<'SNIPPET' || true
# --- XDG_RUNTIME_DIR (modulo desktop: rota seatd, sem elogind) ---
# O seatd NAO cria XDG_RUNTIME_DIR — diferente do elogind, ele so faz seat
# management. Sem esta variavel nao ha socket do Wayland, do PipeWire nem do
# D-Bus de sessao. Conteudo baseado no wiki Gentoo "Configuring a system
# without elogind".
if test -z "${XDG_RUNTIME_DIR}"; then
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
fi
if test -d "${XDG_RUNTIME_DIR}"; then
    # Permissao errada e sinal de que outro usuario criou o diretorio primeiro
    # (/run/user e 1777). Nesse caso NAO usamos o diretorio: melhor falhar de
    # forma visivel que abrir sockets de sessao num diretorio alheio.
    _xdg_perms="$(stat -c '%a %u' "${XDG_RUNTIME_DIR}" 2>/dev/null)"
    if [ "${_xdg_perms}" != "700 $(id -u)" ]; then
        export -n XDG_RUNTIME_DIR
        echo "AVISO: XDG_RUNTIME_DIR (${XDG_RUNTIME_DIR}) tem permissoes/dono incorretos — variavel desexportada por seguranca."
    fi
    unset _xdg_perms
else
    mkdir -p "${XDG_RUNTIME_DIR}"
    chmod 0700 "${XDG_RUNTIME_DIR}"
fi
# --- fim XDG_RUNTIME_DIR ---
SNIPPET

probe_xdg_runtime_dir() {
    # Rota elogind: nao se aplica (o elogind ja cria e gerencia /run/user/$UID
    # com o ciclo de vida da sessao). Retornar 0 registra a etapa como concluida
    # sem executar nada — semantica correta de "nao se aplica".
    if [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]]; then
        return 0
    fi

    # Peca 1: o script de sistema existe e e executavel (local.d so roda
    # arquivos com o bit de execucao — sem ele o script e ignorado em silencio).
    [[ -x "$LOCAL_D_SCRIPT" ]] || return 1

    # Peca 2: o trecho esta no perfil do usuario. Procuramos a linha-marca do
    # bloco, nao um arquivo inteiro, porque o ~/.bash_profile pertence ao
    # usuario e pode ter muito mais coisa.
    local home
    home="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)" || return 1
    [[ -n "$home" ]] || return 1
    grep -qF 'XDG_RUNTIME_DIR (modulo desktop' "$home/.bash_profile" 2>/dev/null
}

do_xdg_runtime_dir() {
    if [[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]]; then
        return 0
    fi

    # --- Peca 1: script de sistema (roda a cada boot, pois /run e tmpfs) ---
    #
    # write_managed_file e apropriado aqui: /etc/local.d/create-runuser.start e
    # um arquivo que PERTENCE a este modulo (nome proprio, criado por nos),
    # diferente de config do usuario ou de arquivo de pacote.
    write_managed_file "$LOCAL_D_SCRIPT" "$(cat <<'EOF'
#!/bin/sh
# Cria o diretorio pai dos XDG_RUNTIME_DIR. Necessario porque a rota seatd nao
# tem logind para faze-lo, e /run e tmpfs (o conteudo some a cada boot).
# Conteudo do wiki Gentoo "Configuring a system without elogind".
#
# O sticky bit (1777) permite que cada usuario crie o proprio subdiretorio e
# impede que um usuario apague ou renomeie o diretorio de outro. Ele NAO impede
# que um usuario CRIE o diretorio de outro — por isso o trecho no perfil do
# usuario confere dono e permissao antes de usar.
mkdir -p /run/user
chmod 1777 /run/user
EOF
)" "13-services.sh"

    chmod +x "$LOCAL_D_SCRIPT" \
        || die "nao foi possivel tornar '$LOCAL_D_SCRIPT' executavel. Sem o bit de execucao o OpenRC IGNORA o script em silencio, e /run/user nunca sera criado."

    # O servico local precisa estar habilitado, senao o script nunca roda.
    if svc_script_exists local; then
        svc_enable local default
    else
        log_warn "'/etc/init.d/local' nao existe — nao foi possivel garantir que '$LOCAL_D_SCRIPT' rode no boot. Verifique se sys-apps/openrc fornece o servico 'local'."
    fi

    # Cria /run/user agora, para nao exigir reboot antes da validacao do 15.
    mkdir -p /run/user || die "falha ao criar /run/user."
    chmod 1777 /run/user || die "falha ao ajustar permissoes de /run/user."
    log_info "/run/user criado agora (1777) — o script de local.d o recriara nos proximos boots"

    # --- Peca 2: trecho no perfil do usuario ---
    #
    # ESCRITO COMO O USUARIO (run_as_user), nunca como root: um ~/.bash_profile
    # com dono root dentro do $HOME e um jeito silencioso de quebrar a sessao.
    local home
    home="$(user_home)"

    # append_line_once compara linha inteira; aqui o conteudo e um BLOCO, entao
    # a guarda de idempotencia e a linha-marca verificada pelo probe. Fazemos a
    # checagem explicitamente para nao duplicar o bloco em re-execucoes.
    if grep -qF 'XDG_RUNTIME_DIR (modulo desktop' "$home/.bash_profile" 2>/dev/null; then
        log_info "'$home/.bash_profile' ja contem o trecho de XDG_RUNTIME_DIR — nada a fazer"
    else
        # `tee -a` dentro do su: o append acontece com a identidade do usuario,
        # entao um arquivo criado agora nasce com o dono correto.
        printf '\n%s\n' "$XDG_PROFILE_SNIPPET" \
            | run_as_user tee -a "$home/.bash_profile" > /dev/null \
            || die "falha ao acrescentar o trecho de XDG_RUNTIME_DIR em '$home/.bash_profile'."
        log_info "trecho de XDG_RUNTIME_DIR acrescentado a '$home/.bash_profile' (como '$DESKTOP_USER')"
    fi

    log_warn "XDG_RUNTIME_DIR so passa a existir na sessao apos NOVO login (o trecho roda no perfil do shell). Faca logout/login antes de testar a sessao grafica."
}

run_step 13-xdg-runtime-dir probe_xdg_runtime_dir do_xdg_runtime_dir

# ===========================================================================
# 13-audio-user-services — PipeWire como servico de USUARIO
# ===========================================================================
#
# ARMADILHA CENTRAL DESTA ETAPA: `rc-update add pipewire default` como root NAO
# FUNCIONA. Nao existe servico de SISTEMA para o PipeWire no Gentoo — o proprio
# ebuild marca USE=system-service como "Not recommended". O PipeWire roda por
# SESSAO DE USUARIO, e o mecanismo do OpenRC para isso e a flag -U:
#
#     rc-update add -U pipewire default
#     rc-update add -U pipewire-pulse default
#
# (comandos confirmados no wiki Gentoo do PipeWire)
#
# Servicos de usuario exigem OpenRC >= 0.60 — versao em que o suporte passou a
# ser embutido e habilitado por default. A pesquisa NAO confirmou qual versao o
# stage3 deste projeto entrega, entao o modulo MEDE em vez de supor, e cai num
# fallback documentado quando a versao e anterior.
#
# O -U tambem muda QUEM roda o comando: sem root, como o proprio usuario. Rodar
# como root gravaria a configuracao no runlevel de usuario do ROOT, e o audio do
# usuario real continuaria sem servico nenhum — falha silenciosa classica.
#
# FALLBACK (OpenRC < 0.60): /usr/bin/gentoo-pipewire-launcher no autostart do
# compositor. Quem escreve o config.kdl e a etapa 14, entao aqui apenas
# REGISTRAMOS a decisao num marker que o 14 le. Sem isso, o 14 teria de
# adivinhar a rota — e as duas sao mutuamente exclusivas (declarar as duas faria
# o PipeWire subir duas vezes).
#
# O FALLBACK NAO E DEFINITIVO: o marker registra a decisao, mas quem manda e a
# versao do OpenRC, que muda com um `emerge -u`. Por isso o probe re-mede a
# versao em vez de aceitar o marker 'launcher' como prova — do contrario a
# maquina ficaria presa no wrapper para sempre. A migracao de volta para
# 'user-services' e portanto um caminho ESPERADO, e tem uma consequencia no
# config.kdl que o do_fn avisa (ver a MIGRACAO adiante).

AUDIO_SERVICES=(pipewire pipewire-pulse)

probe_audio_user_services() {
    # PipeWire ausente = etapa nao se aplica. Isso e legitimo: o audio nao e
    # pre-requisito para a sessao subir, e o usuario pode ter optado por nao
    # instalar. Reportar "feito" evita transformar uma escolha valida em erro.
    pkg_installed media-video/pipewire || return 0

    # Rota de fallback ja registrada: a decisao esta tomada e o 14 fara o resto
    # (declarar o launcher no spawn-at-startup do config.kdl). Nao ha servico de
    # usuario para conferir nesta rota, entao a etapa esta concluida — MAS so
    # enquanto a premissa que produziu o fallback continuar verdadeira.
    #
    # POR QUE RE-MEDIR O OpenRC EM VEZ DE CONFIAR SO NO MARKER: o marker guarda
    # uma DECISAO, e a decisao dependia de um fato do sistema (OpenRC < 0.60) que
    # muda com um simples `emerge -u sys-apps/openrc`. Tratar o marker sozinho
    # como prova tornaria o fallback PERMANENTE: uma vez gravado 'launcher', a
    # maquina nunca mais mediria a versao e ficaria presa no wrapper para sempre,
    # mesmo ja tendo servicos de usuario disponiveis — que sao a rota preferida.
    # E o pior tipo de falha: silenciosa e indistinguivel do funcionamento
    # correto. Marker e cache, o estado real do sistema e a autoridade; e a mesma
    # regra do run_step, aplicada aqui ao fato que SUSTENTA o marker.
    #
    # Com o OpenRC ja atualizado, este probe REPROVA de proposito: o do_fn roda
    # de novo, re-mede, habilita os servicos de usuario e reescreve o marker para
    # 'user-services'. O do_fn avisa sobre o config.kdl herdado da rota antiga
    # (ver a MIGRACAO la embaixo), e a 14 audita o arquivo de verdade.
    #
    # `if` explicito em vez de `[[ ... ]] && return 0`: aquela forma devolveria o
    # status do teste como retorno da funcao quando falso, que aqui ate seria o
    # desejado — mas por acidente, nao por intencao. Probe e contrato: tem de ser
    # obvio na leitura. openrc_version_ge apenas le `openrc --version`, entao o
    # probe continua sem efeito colateral nenhum.
    if [[ "$(step_value 13-audio-route)" == "launcher" ]] && ! openrc_version_ge 0.60; then
        return 0
    fi

    # Rota de user services: os dois servicos precisam estar no runlevel de
    # usuario. `rc-update -U show` lista o runlevel do usuario que RODA o
    # comando — por isso a consulta vai via run_as_user, e nao como root.
    local svc out
    out="$(run_as_user rc-update -U show default 2>/dev/null)" || return 1
    for svc in "${AUDIO_SERVICES[@]}"; do
        printf '%s\n' "$out" | awk '{print $1}' | grep -qx "$svc" || return 1
    done
    return 0
}

do_audio_user_services() {
    if ! pkg_installed media-video/pipewire; then
        log_info "media-video/pipewire nao esta instalado — etapa de audio nao se aplica"
        return 0
    fi

    # Rota gravada por uma execucao ANTERIOR, lida antes de qualquer mark_done:
    # e o unico jeito de saber, depois, que houve MIGRACAO de rota. Vazio na
    # primeira execucao da maquina.
    local rota_anterior
    rota_anterior="$(step_value 13-audio-route)"

    # AVISO QUE EVITA "audio instalado e mudo": o PipeWire sozinho nao roteia
    # nada. Quem aplica a politica de dispositivos e o wireplumber — sem ele
    # nenhum dispositivo aparece. Nao e fatal para a sessao grafica, entao
    # avisamos em vez de matar o script.
    if ! pkg_installed media-video/wireplumber; then
        log_warn "media-video/wireplumber NAO esta instalado. O PipeWire sozinho nao aplica politica de dispositivo nenhuma: o audio fica MUDO e nenhum dispositivo aparece. Instale com: emerge --noreplace media-video/wireplumber"
    fi

    # Bifurcacao MEDIDA, nao suposta.
    if openrc_version_ge 0.60; then
        log_info "OpenRC >= 0.60 — usando servicos de USUARIO (rc-update add -U)"

        local svc
        for svc in "${AUDIO_SERVICES[@]}"; do
            if ! svc_script_exists "$svc"; then
                log_warn "'/etc/init.d/$svc' nao existe — pulando. Verifique as USE flags do media-video/pipewire (o binario pipewire-pulse depende de USE=sound-server)."
                continue
            fi

            # Idempotencia: `rc-update add` repetido nao duplica, mas checar
            # antes deixa o log honesto sobre o que mudou de verdade.
            if run_as_user rc-update -U show default 2>/dev/null | awk '{print $1}' | grep -qx "$svc"; then
                log_info "servico de usuario '$svc' ja esta no runlevel default de '$DESKTOP_USER'"
                continue
            fi

            # RODADO COMO O USUARIO — note o -U. Como root isso gravaria no
            # runlevel de usuario do root e o audio do usuario real ficaria sem
            # servico, sem nenhum erro visivel.
            run_as_user rc-update add -U "$svc" default \
                || die "falha ao habilitar o servico de usuario '$svc' para '$DESKTOP_USER'. Confira manualmente com: su - $DESKTOP_USER -c 'rc-update -U show default'"
            log_info "servico de usuario '$svc' habilitado para '$DESKTOP_USER'"
        done

        # Registra a rota para o 15 (validacao) e o 14 (config.kdl).
        mark_done 13-audio-route "user-services"

        # MIGRACAO 'launcher' -> 'user-services': esta maquina ja rodou no
        # fallback e o OpenRC foi atualizado desde entao. O problema e que o
        # config.kdl escrito NAQUELA epoca declara o spawn-at-startup do
        # launcher, e a 14 nao reescreve config.kdl existente (write-if-absent,
        # regra 4). Sem intervencao, as duas rotas ficam ativas ao mesmo tempo e
        # o PipeWire sobe DUAS vezes — o sintoma (audio cortado, dispositivo
        # sumindo do mixer, socket ja em uso) nao aponta para a causa.
        #
        # Avisamos aqui e nao corrigimos: config.kdl e arquivo do USUARIO e mexer
        # nele seria destrutivo (regra 4). A 14 confere o arquivo de verdade e
        # repete o aviso com o caminho exato — este aqui existe porque a 13 pode
        # ser rodada sozinha (--only 13), sem a 14 depois.
        if [[ "$rota_anterior" == "launcher" ]]; then
            log_warn "a rota de audio MUDOU de 'launcher' para 'user-services': o OpenRC foi atualizado para >= 0.60 desde a ultima execucao, entao os servicos de usuario passaram a existir e sao a rota preferida."
            log_warn "ATENCAO ao config.kdl herdado da rota antiga: se ele foi gerado quando a rota era 'launcher', ainda contem 'spawn-at-startup \"/usr/bin/gentoo-pipewire-launcher\"'. Com os servicos de usuario agora habilitados, as duas rotas ficam ativas e o PipeWire sobe DUAS vezes. REMOVA essa linha do config.kdl de '$DESKTOP_USER' (a etapa 14 nao a remove: o arquivo ja existe e pertence a voce)."
        fi
    else
        # FALLBACK documentado. Nao e erro: e a rota correta nesta versao.
        local have_ver
        have_ver="$(openrc --version 2>/dev/null | head -n1)" || have_ver="desconhecida"
        log_warn "OpenRC anterior a 0.60 (detectado: $have_ver) — servicos de USUARIO nao estao disponiveis nesta versao."

        # A existencia do launcher e verificada, nao presumida: se ele nao
        # existir, as duas rotas estao fechadas e o usuario precisa saber agora.
        if [[ -x /usr/bin/gentoo-pipewire-launcher ]]; then
            log_info "fallback: /usr/bin/gentoo-pipewire-launcher sera declarado no autostart do compositor pela etapa 14 (spawn-at-startup no config.kdl)"
            mark_done 13-audio-route "launcher"
        else
            die "OpenRC < 0.60 (sem servicos de usuario) e /usr/bin/gentoo-pipewire-launcher NAO existe — as duas rotas de arranque do PipeWire estao indisponiveis. O launcher e instalado pelo media-video/pipewire; verifique a instalacao com 'emerge --newuse media-video/pipewire' ou atualize o OpenRC para >= 0.60 e rode este script novamente."
        fi
    fi

    log_warn "servicos de USUARIO do PipeWire so sobem quando '$DESKTOP_USER' faz login — nao no boot do sistema. Isso e o comportamento correto: audio e por sessao."
}

run_step 13-audio-user-services probe_audio_user_services do_audio_user_services

# ===========================================================================
# Relatorio final
# ===========================================================================

log_info "==== 13-services concluido com sucesso ===="
log_info "provedor de seat : $SEAT_SVC (runlevel '$SEAT_RUNLEVEL') — habilitado e rodando"
log_info "dbus             : habilitado (runlevel 'default') e rodando"
log_info "grupos de '$DESKTOP_USER': $(id -nG "$DESKTOP_USER" 2>/dev/null || echo '(nao foi possivel ler)')"
if [[ "$DESKTOP_SEAT_PROVIDER" == "seatd" ]]; then
    log_info "XDG_RUNTIME_DIR  : via $LOCAL_D_SCRIPT + trecho no ~/.bash_profile (rota seatd)"
else
    log_info "sessao PAM       : pam_elogind.so presente em /etc/pam.d/system-login"
fi
if pkg_installed media-video/pipewire; then
    log_info "audio            : rota '$(step_value 13-audio-route)'"
fi

# Observacao registrada como AVISO, nao aplicada: remover grupo e destrutivo e
# esta fora do escopo do modulo (regra 4). O usuario decide.
if user_in_group "$DESKTOP_USER" audio && pkg_installed media-video/pipewire; then
    log_warn "'$DESKTOP_USER' pertence ao grupo 'audio' (herdado do instalador base). O wiki do PipeWire recomenda que usuarios normalmente NAO estejam nesse grupo, porque ele permite controle exclusivo do dispositivo e pode atrapalhar o PipeWire. Este modulo NAO remove grupos (seria destrutivo). Se quiser remover, faca manualmente: gpasswd -d $DESKTOP_USER audio"
fi

cat <<INSTRUCOES

========================================================================
  13-services concluido — O QUE PRECISA ACONTECER AGORA
========================================================================
FACA LOGOUT/LOGIN (ou reinicie) ANTES DE TESTAR A SESSAO GRAFICA.

Dois efeitos desta etapa so valem em sessoes NOVAS, e ignorar isso leva a
um diagnostico errado (voce veria a falha de seat e concluiria que a etapa
nao funcionou):

  1. Grupos (video, input$([[ "$DESKTOP_SEAT_PROVIDER" == "seatd" ]] && printf ', seat')): a lista de grupos e fixada
     no login. O shell atual ainda tem a lista antiga.
$(if [[ "$DESKTOP_SEAT_PROVIDER" == "seatd" ]]; then printf '  2. XDG_RUNTIME_DIR: e definido pelo perfil do shell, no login.\n'; else printf '  2. Sessao do elogind: e registrada pelo PAM, no login.\n'; fi)

Depois do novo login, confirme antes de tentar o compositor:

    id -nG $DESKTOP_USER          # deve listar video e input$([[ "$DESKTOP_SEAT_PROVIDER" == "seatd" ]] && printf ' e seat')
    echo \$XDG_RUNTIME_DIR         # deve imprimir /run/user/\$(id -u)
    rc-service $SEAT_SVC status$([[ "$DESKTOP_SEAT_PROVIDER" == "elogind" ]] && printf '\n    loginctl                     # deve listar sua sessao')

O proximo passo e a etapa 15-validate, que PROVA que a sessao tem tudo de
que precisa — rode-a ANTES de tentar iniciar o compositor pela primeira vez
e antes de qualquer reboot.

Lembrete do comando de arranque em OpenRC (nunca 'niri-session', que exige
systemd ou dinit e falha aqui):

    dbus-run-session niri --session

========================================================================

INSTRUCOES
