#!/usr/bin/env bash
# install-desktop.sh — orquestrador do modulo de desktop (niri/Wayland/NVIDIA).
#
# Equivale ao install.sh do instalador base, mas para a fase POS-BOOT: roda no
# sistema Gentoo JA INSTALADO E BOOTADO do disco. NAO roda no live ISO nem
# dentro do chroot da instalacao — require_booted_system (lib-desktop.sh) recusa
# os dois com deteccao POSITIVA e fail-closed.
#
# Este modulo e ADITIVO. Ele nao modifica nenhum arquivo do instalador base
# (install.sh, lib.sh, vars.sh, 00-06, kernel-fragment.config): faz SOURCE do
# lib.sh (atraves do lib-desktop.sh) e reaproveita run_step/logging/die/
# svc_enable sem alterar uma linha.
#
# ORDEM DAS ETAPAS e o PORQUE de cada posicao (cada uma depende da anterior de
# forma verificavel):
#
#   10  overlay GURU + keywords + package.use. PRIMEIRO e absoluto: niri,
#       fuzzel e xwayland-satellite NAO existem no ::gentoo. Sem o overlay o
#       primeiro emerge do 12 falha com "no ebuilds to satisfy". Termina num
#       PORTAO (require_atoms) que prova que todo atom resolve — segundos agora
#       em vez de descobrir um nome de pacote errado na hora 3 de compilacao.
#   10a perfil 23.0/desktop + emerge -uDN @world. OPT-IN, default DESLIGADO,
#       script proprio: sao as duas acoes de maior risco (mexem no sistema ja
#       validado e demoram horas). Se rodarem, tem de ser ANTES do 11, porque
#       o perfil desktop liga USE=wayland GLOBALMENTE e o @world ja reconstroi
#       o nvidia-drivers — rodar a 10a depois da 11 recompilaria o driver DUAS
#       vezes.
#   11  USE=wayland no nvidia-drivers. ANTES do compositor: e o ponto de falha
#       numero um do projeto. USE=wayland NAO e default-on e o instalador base
#       nao a liga em lugar nenhum; sem ela nao ha egl-gbm/egl-wayland e o niri
#       nao inicia. O modo de falha e cruel: o driver COMPILA normalmente e so
#       quebra em runtime, com tela preta.
#   12  compositor + terminal + launcher JUNTOS, deliberadamente: entrar no
#       niri sem terminal e sem launcher deixa o usuario numa tela vazia sem
#       forma de abrir nada e sem saber como sair.
#   13  servicos (seatd/dbus/grupos). Depois dos pacotes, porque so da para
#       habilitar servico de pacote instalado. Indispensavel: o instalador base
#       NAO configura seatd, elogind nem dbus, entao um modulo que so faz
#       emerge produz um sistema onde o niri instala e NUNCA inicia.
#   15  validacao ANTES da 14 e antes de qualquer reboot. Falhar aqui com
#       mensagem acionavel evita o pior cenario: reiniciar, cair em tela preta
#       e nao ter console para diagnosticar.
#   14  dotfiles/aparencia POR ULTIMO. Tema so importa se a sessao sobe;
#       escrever tema num sistema onde o compositor nao inicia e desperdicio e
#       ainda envenena o diagnostico (mistura sintoma de tema com sintoma de
#       compositor).
#
# Este orquestrador NUNCA faz emerge diretamente — so chama os numerados.
# Um assunto por script, como no instalador base.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Captura do ambiente ORIGINAL (antes de qualquer source)
# ---------------------------------------------------------------------------
#
# Obrigatoriamente ANTES do source do lib-desktop.sh: ele sourceia o
# vars-desktop.sh, que aplica os defaults com `: "${VAR:=no}"`. Depois desse
# source e IMPOSSIVEL distinguir "o usuario passou no" de "ninguem passou nada"
# — as duas viram a string "no".
#
# Guardamos o VALOR (nao so a existencia) porque o run_script precisa repassar
# ao filho exatamente o que o usuario pediu, quando ele pediu algo. Sem esta
# captura, o repasse de "--with-profile-world" nao teria como preservar o
# escape hatch `DESKTOP_SWITCH_PROFILE=no ./install-desktop.sh --with-profile-world`.
[[ -n "${DESKTOP_SWITCH_PROFILE+x}" ]] && _ENV_SWITCH_PROFILE="$DESKTOP_SWITCH_PROFILE"
[[ -n "${DESKTOP_UPDATE_WORLD+x}" ]]   && _ENV_UPDATE_WORLD="$DESKTOP_UPDATE_WORLD"

# ---------------------------------------------------------------------------
# Carregamento da biblioteca do modulo
# ---------------------------------------------------------------------------
#
# UM source so, de proposito. O lib-desktop.sh e quem orquestra o resto da
# cadeia, na ordem correta e com o cuidado que ela exige:
#   1. define TARGET_ROOT=""    (antes de tudo)
#   2. source ../vars.sh        (que, com `: "${TARGET_ROOT:=/mnt/gentoo}"`,
#                                REPOE o default — a forma := sobrescreve
#                                variavel definida-porem-VAZIA)
#   3. REAFIRMA TARGET_ROOT=""  (esta linha e o que realmente faz state_dir()
#                                apontar para /var/lib/gentoo-install/state)
#   4. source ../lib.sh e vars-desktop.sh
#
# O passo 3 e sutil e nao-obvio: sem ele os markers iriam parar em
# /mnt/gentoo/var/lib/... e a idempotencia do modulo seria silenciosamente
# falsa. Reimplementar essa sequencia aqui seria duplicar a parte mais fragil
# do modulo em dois lugares — por isso o orquestrador delega e nao repete.
#
# Consequencia herdada, valida tambem aqui: este script NUNCA chama
# require_phase (a fase reportada e "live" mas nao estamos num live ISO) nem
# validate_vars (ela morre com TARGET_ROOT vazio e valida disco/particoes que
# nao tem sentido na fase pos-boot).
# shellcheck source=lib-desktop.sh
source "$SCRIPT_DIR/lib-desktop.sh"

# ---------------------------------------------------------------------------
# Ajuda
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Uso: ./desktop/install-desktop.sh [OPCOES]

Modulo ADITIVO de desktop (niri + Wayland + NVIDIA) para o sistema Gentoo JA
INSTALADO E BOOTADO. Recusa rodar no live ISO e dentro do chroot.

Sem opcoes: roda as etapas 10 -> 11 -> 12 -> 13 -> 15 -> 14, nessa ordem.
A etapa 10a (troca de perfil + emerge -uDN @world) e OPT-IN e NAO roda por
padrao — veja --with-profile-world.

Opcoes:
  --list                lista as etapas na ordem de execucao e sai.
  --only <etapa>        roda somente a etapa indicada (ex.: --only 11).
  --from <etapa>        comeca na etapa indicada e segue ate o fim da ordem.
  --with-profile-world  INCLUI a etapa 10a (troca para o perfil
                        default/linux/amd64/23.0/desktop e roda
                        emerge -uDN @world). DEMORA HORAS e reconstroi grande
                        parte do sistema, INCLUSIVE o nvidia-drivers.
  --dry-run             imprime o que faria, sem emergir nem escrever nada.
                        Repassado aos numerados via DESKTOP_DRY_RUN=yes.
  --reset <marker>      remove UM marker do state para forcar a re-execucao da
                        sub-etapa. NUNCA remove pacote (regra 4). Sem
                        argumento, apenas LISTA os markers existentes.
  -h, --help            mostra esta ajuda e sai.

Etapas:
  10   overlay GURU, package.accept_keywords, package.use + portao de atoms
  10a  (opt-in) perfil 23.0/desktop + emerge -uDN @world
  11   nvidia-drivers com USE=wayland (egl-gbm/egl-wayland)
  12   niri + terminal + launcher + utilitarios Wayland
  13   servicos (seatd/dbus) e grupos do usuario
  15   validacao pre-reboot da sessao
  14   dotfiles e aparencia (por ultimo, de proposito)

A ordem NAO e numerica: a 15 roda ANTES da 14 porque validar que a sessao sobe
e mais urgente que estetica.

Variaveis uteis (veja vars-desktop.sh):
  DESKTOP_USER=<nome>       usuario dono da sessao grafica
  DESKTOP_ASSUME_YES=yes    pula os prompts das acoes caras (automacao)

  DESKTOP_SWITCH_PROFILE / DESKTOP_UPDATE_WORLD  sao as DUAS acoes da etapa
  10a. --with-profile-world liga as duas; definir uma delas no ambiente TEM
  PRECEDENCIA sobre a flag, o que permite pedir so uma das duas:
      DESKTOP_SWITCH_PROFILE=no ./desktop/install-desktop.sh --with-profile-world
  (atualiza o @world sem trocar o perfil).
EOF
}

# --help sai ANTES de logging e de qualquer guarda: tem de poder rodar em
# qualquer maquina, inclusive no host de desenvolvimento, so para consulta.
for _arg in "$@"; do
    case "$_arg" in
        -h|--help)
            usage
            exit 0
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Mapeamento etapa -> script
# ---------------------------------------------------------------------------
#
# ORDEM_ETAPAS e a fonte de verdade da sequencia. A 10a NAO esta aqui: ela e
# inserida logo depois da 10 somente quando --with-profile-world e passado.
ORDEM_ETAPAS=(10 11 12 13 15 14)

# step_script <etapa>: nome do arquivo da etapa. Estes nomes sao o contrato
# entre este orquestrador e os scripts numerados.
step_script() {
    case "$1" in
        10)  echo "10-portage-desktop.sh" ;;
        10a) echo "10a-profile-world.sh" ;;
        11)  echo "11-nvidia-wayland.sh" ;;
        12)  echo "12-niri-stack.sh" ;;
        13)  echo "13-services.sh" ;;
        14)  echo "14-dotfiles.sh" ;;
        15)  echo "15-validate.sh" ;;
        *)   die "etapa inexistente: '$1' — veja ./desktop/install-desktop.sh --list" ;;
    esac
}

# step_desc <etapa>: descricao curta, usada por --list e pelo resumo final.
step_desc() {
    case "$1" in
        10)  echo "overlay GURU + keywords + package.use + portao de atoms" ;;
        10a) echo "(opt-in) perfil 23.0/desktop + emerge -uDN @world" ;;
        11)  echo "nvidia-drivers com USE=wayland" ;;
        12)  echo "niri + terminal + launcher" ;;
        13)  echo "servicos (seatd/dbus) e grupos" ;;
        14)  echo "dotfiles e aparencia" ;;
        15)  echo "validacao pre-reboot" ;;
        *)   echo "?" ;;
    esac
}

# _is_valid_step <etapa>: aceita apenas os identificadores conhecidos.
# Rejeita os numeros do instalador base com mensagem propria: pedir "--only 4"
# aqui e o erro tipico de quem vem do install.sh.
_is_valid_step() {
    case "$1" in
        10|10a|11|12|13|14|15) return 0 ;;
        0|1|2|3|4|5|6|00|01|02|03|04|05|06)
            die "etapa '$1' pertence ao INSTALADOR BASE (00-06), nao ao modulo de desktop. As etapas deste modulo sao: ${ORDEM_ETAPAS[*]} (e 10a, opt-in)."
            ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Parse de argumentos
# ---------------------------------------------------------------------------

ONLY_STEP=""
FROM_STEP=""
DO_LIST="no"
DRY_RUN="no"
WITH_PROFILE_WORLD="no"
DO_RESET="no"
RESET_MARKER=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                DO_LIST="yes"
                ;;
            --dry-run)
                DRY_RUN="yes"
                ;;
            --with-profile-world)
                WITH_PROFILE_WORLD="yes"
                ;;
            --only)
                [[ $# -ge 2 ]] || die "--only exige o identificador da etapa (ex.: --only 11)"
                ONLY_STEP="$2"
                shift
                ;;
            --only=*)
                ONLY_STEP="${1#--only=}"
                ;;
            --from)
                [[ $# -ge 2 ]] || die "--from exige o identificador da etapa (ex.: --from 12)"
                FROM_STEP="$2"
                shift
                ;;
            --from=*)
                FROM_STEP="${1#--from=}"
                ;;
            --reset)
                DO_RESET="yes"
                # argumento OPCIONAL: sem ele, LISTAMOS os markers em vez de
                # apagar. `--reset` sozinho nunca pode ser destrutivo por
                # acidente.
                if [[ $# -ge 2 && "$2" != -* ]]; then
                    RESET_MARKER="$2"
                    shift
                fi
                ;;
            --reset=*)
                DO_RESET="yes"
                RESET_MARKER="${1#--reset=}"
                ;;
            *)
                die "argumento desconhecido: '$1' — veja ./desktop/install-desktop.sh --help"
                ;;
        esac
        shift
    done

    if [[ -n "$FROM_STEP" && -n "$ONLY_STEP" ]]; then
        die "--from e --only sao mutuamente exclusivos"
    fi
    if [[ -n "$ONLY_STEP" ]]; then
        _is_valid_step "$ONLY_STEP" \
            || die "etapa invalida para --only: '$ONLY_STEP' (validas: ${ORDEM_ETAPAS[*]} e 10a)"
    fi
    if [[ -n "$FROM_STEP" ]]; then
        _is_valid_step "$FROM_STEP" \
            || die "etapa invalida para --from: '$FROM_STEP' (validas: ${ORDEM_ETAPAS[*]} e 10a)"
        # A 10a e opt-in e nao tem posicao propria na ORDEM_ETAPAS, entao
        # "comecar a partir dela" e ambiguo. Quem quer so a 10a usa --only.
        if [[ "$FROM_STEP" == "10a" ]]; then
            die "--from 10a nao e suportado (a 10a e opt-in e nao tem posicao fixa na sequencia). Use '--only 10a' para rodar so ela, ou '--with-profile-world' para inclui-la no fluxo completo."
        fi
    fi
}

parse_args "$@"

# --list sai antes da guarda de ambiente: e consulta pura, nao toca em nada e
# tem de funcionar tambem no host de desenvolvimento.
if [[ "$DO_LIST" == "yes" ]]; then
    printf 'Etapas do modulo de desktop, na ordem de execucao:\n\n'
    for _n in "${ORDEM_ETAPAS[@]}"; do
        printf '  %-4s %-26s %s\n' "$_n" "$(step_script "$_n")" "$(step_desc "$_n")"
        # a 10a aparece logo depois da 10 para deixar clara a posicao dela
        if [[ "$_n" == "10" ]]; then
            printf '  %-4s %-26s %s\n' "10a" "$(step_script 10a)" "$(step_desc 10a)"
            printf '       (so roda com --with-profile-world)\n'
        fi
    done
    printf '\nObservacao: a 15 roda ANTES da 14 de proposito — validar que a\n'
    printf 'sessao sobe e mais urgente que aparencia.\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
#
# init_logging_desktop (lib-desktop.sh), e nao o init_logging do instalador:
# aquele escolhe o diretorio por current_phase()/mountpoint de TARGET_ROOT e,
# com TARGET_ROOT vazio, mandaria o log para /tmp/gentoo-install/ — que some no
# proximo boot. Num sistema instalado o lugar certo e /var/log/gentoo-install/,
# junto dos logs da instalacao.
init_logging_desktop "install-desktop"

# ---------------------------------------------------------------------------
# GUARDA DE FASE — REGRA 2, antes de qualquer outra coisa
# ---------------------------------------------------------------------------
#
# require_booted_system e fail-closed por construcao: exige que TODAS as
# condicoes sejam PROVADAS. Qualquer uma indeterminada (comando ausente, erro
# de leitura, saida vazia) resulta em die. E deteccao POSITIVA — prova que
# estamos bootados do disco — em vez de sair procurando sinais de live ISO, que
# e uma lista aberta e sempre incompleta.
#
# Roda UMA vez aqui; cada script numerado tambem a chama quando invocado
# standalone (os scripts do projeto rodam standalone para debug, e a guarda e a
# unica coisa que impede rodar na fase errada — mesmo papel do require_phase no
# instalador base, que se repete em todos os 00-06).
require_booted_system

# Root: instalar pacote e escrever em /etc exige. A etapa 14 (dotfiles) e a
# unica que escreve em $HOME, e ela faz o drop de privilegio sozinha via
# run_as_user.
require_root

# ---------------------------------------------------------------------------
# --reset (nunca destrutivo alem do marker)
# ---------------------------------------------------------------------------
#
# REGRA 4: este modulo NUNCA remove pacote do usuario, nunca formata, nunca
# reparticiona. O --reset apaga SO um marker do state, para forcar a
# re-execucao de uma sub-etapa. Como o PROBE e a autoridade, apagar o marker de
# algo que continua feito no sistema real apenas faz o run_step re-confirmar e
# regravar o marker — nada e refeito de verdade.
do_reset() {
    local dir
    dir="$(state_dir)"

    if [[ -z "$RESET_MARKER" ]]; then
        log_info "--reset sem argumento: apenas LISTANDO os markers existentes (nada foi apagado)."
        if [[ -d "$dir" ]]; then
            local f found="no" base
            for f in "$dir"/*; do
                [[ -e "$f" ]] || continue
                base="$(basename "$f")"
                [[ "$base" == ".installer" ]] && continue
                printf '  %s\n' "$base"
                found="yes"
            done
            [[ "$found" == "yes" ]] || log_info "  (nenhum marker em $dir)"
        else
            log_info "  (state dir inexistente: $dir)"
        fi
        log_info "Para remover um: ./desktop/install-desktop.sh --reset <nome-do-marker>"
        return 0
    fi

    # O alvo tem de ser um marker do nosso state dir, nunca um caminho
    # arbitrario. Fail-closed.
    if [[ "$RESET_MARKER" == */* || "$RESET_MARKER" == *..* ]]; then
        die "--reset aceita apenas o NOME de um marker (sem barras), nao um caminho: '$RESET_MARKER'"
    fi
    # Markers do instalador base sao intocaveis: eles sao a evidencia de que a
    # instalacao terminou (condicao (g) da guarda de ambiente). Apagar um deles
    # faria o proprio modulo recusar rodar na proxima invocacao.
    if [[ "$RESET_MARKER" == 0[0-6]-* ]]; then
        die "'$RESET_MARKER' e um marker do INSTALADOR BASE (00-06). Este modulo nao mexe no state do instalador — inclusive porque a guarda de ambiente usa esses markers como prova de que a instalacao foi concluida."
    fi

    if [[ -e "$dir/$RESET_MARKER" ]]; then
        clear_marker "$RESET_MARKER"
        log_info "--reset: marker '$RESET_MARKER' removido. Nenhum pacote foi tocado."
    else
        log_info "--reset: marker '$RESET_MARKER' nao existe em $dir — nada a apagar."
    fi
}

if [[ "$DO_RESET" == "yes" ]]; then
    do_reset
    exit 0
fi

# ---------------------------------------------------------------------------
# Identidade do state
# ---------------------------------------------------------------------------
#
# state_identity_check e do lib.sh e funciona aqui porque state_dir() ja
# resolve para /var/lib/gentoo-install/state (ver o bloco de carregamento da
# biblioteca). Avisa se o state foi criado por outro commit do instalador; nao
# aborta por isso (mesmo schema => resume continua).
state_identity_check

# ---------------------------------------------------------------------------
# Pre-requisitos de runtime (todos com mensagem acionavel)
# ---------------------------------------------------------------------------
#
# Falhar AQUI custa segundos. Falhar no meio de um emerge de niri/rust custa
# horas. Por isso tudo que da para confrontar barato e confrontado antes.
check_prereqs() {
    # --- usuario alvo ---
    # O modulo escreve em $HOME (config do niri, fontconfig, gsettings) e
    # precisa saber de QUEM. user_home() morre se a conta nao existe ou se o
    # home vier vazio — escrever dotfile na home errada e silencioso e chato de
    # desfazer.
    local home
    home="$(user_home)"
    log_info "usuario alvo da sessao grafica: '$DESKTOP_USER' (home: $home)"

    # --- init system ---
    # O projeto inteiro foi validado com OpenRC; o caminho systemd existe no
    # instalador mas NUNCA foi executado. Nao e fatal, mas o usuario precisa
    # saber que os comandos de sessao e varias USE flags mudam.
    if [[ "${INIT_SYSTEM:-openrc}" != "openrc" ]]; then
        log_warn "INIT_SYSTEM='${INIT_SYSTEM:-}' (nao e openrc)."
        log_warn "O caminho systemd NUNCA foi executado neste projeto — trate tudo daqui para frente como nao validado."
        log_warn "Os comandos de SESSAO mudam: com systemd o 'niri-session' passa a ser valido;"
        log_warn "com OpenRC o correto e 'dbus-run-session niri --session' (o niri-session procura"
        log_warn "systemd/dinit e ABORTA se nao achar nenhum dos dois)."
        log_warn "As USE flags tambem mudam: '-systemd' deixa de ser o certo em varios pacotes."
    fi

    # --- Portage utilizavel ---
    # Sem estes binarios nenhuma etapa seguinte funciona; morrer agora e
    # infinitamente melhor que morrer no meio da 10.
    local b
    for b in emerge portageq; do
        command -v "$b" >/dev/null 2>&1 \
            || die "'$b' nao encontrado no PATH. Este modulo precisa do Portage funcional; rode-o no sistema Gentoo instalado."
    done

    # --- GPU NVIDIA presente ---
    # Sem lspci nao da para PROVAR a presenca da GPU. Nao morremos por isso (o
    # modulo ainda tem trabalho util a fazer), mas avisamos alto.
    if command -v lspci >/dev/null 2>&1; then
        if lspci -d 10de: 2>/dev/null | grep -qiE 'vga|3d controller|display controller'; then
            log_info "GPU NVIDIA detectada no barramento (lspci -d 10de:)"
        else
            log_warn "Nenhuma GPU NVIDIA vista por 'lspci -d 10de:'. O alvo deste projeto e uma RTX 5060 Ti."
            log_warn "Numa VM sem passthrough as etapas 11 e 15 nao terao o que validar em runtime."
        fi
    else
        log_warn "lspci indisponivel (sys-apps/pciutils) — nao foi possivel confirmar a GPU NVIDIA."
    fi

    # --- driver instalado ---
    # A etapa 11 vai RECONSTRUIR o driver com USE=wayland. Se ele nem esta
    # instalado (NVIDIA_MODE=skip no instalador), o custo muda muito: passa a
    # ser instalacao do zero, nao rebuild.
    if pkg_installed x11-drivers/nvidia-drivers; then
        log_info "x11-drivers/nvidia-drivers instalado (a etapa 11 vai reconstrui-lo com USE=wayland)"
    else
        log_warn "x11-drivers/nvidia-drivers NAO esta instalado neste sistema."
        log_warn "O instalador base (04-kernel.sh) normalmente o instala; se NVIDIA_MODE=skip foi usado,"
        log_warn "a etapa 11 vai instala-lo do zero — bem mais demorado que um rebuild."
    fi

    # --- espaco em disco ---
    check_disk_space
}

# check_disk_space: avisa (nunca mata) quando / ou /var/tmp/portage estao abaixo
# do piso declarado em vars-desktop.sh.
#
# POR QUE AVISO E NAO die: o modulo e retomavel, o usuario pode estar liberando
# espaco em outro terminal, e uma leitura de df nao e prova suficiente para
# abortar um trabalho longo. Mas ficar em silencio tambem nao serve: compilar
# niri (Rust), xwayland-satellite (clang) e um @world de desktop (llvm/qt6)
# estoura disco com facilidade, e o sintoma no meio de um emerge de horas
# ("No space left on device") custa muito mais caro que este aviso.
check_disk_space() {
    local tmpdir="/var/tmp/portage" alvo
    # PORTAGE_TMPDIR pode ter sido movido; perguntamos ao Portage em vez de supor.
    if command -v portageq >/dev/null 2>&1; then
        alvo="$(portageq envvar PORTAGE_TMPDIR 2>/dev/null || true)"
        [[ -n "$alvo" ]] && tmpdir="${alvo%/}/portage"
    fi

    _free_gib() {
        # df do diretorio existente mais proximo: /var/tmp/portage so e criado
        # no primeiro emerge, e df num caminho inexistente falha.
        local p="$1"
        while [[ ! -d "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
        df -BG --output=avail "$p" 2>/dev/null | tail -1 | tr -dc '0-9' || true
    }

    local livre_root livre_tmp
    livre_root="$(_free_gib /)"
    livre_tmp="$(_free_gib "$tmpdir")"

    if [[ -n "$livre_root" ]] && (( livre_root < DESKTOP_MIN_FREE_ROOT_GIB )); then
        log_warn "espaco livre em '/': ${livre_root} GiB (recomendado: >= ${DESKTOP_MIN_FREE_ROOT_GIB} GiB)."
        log_warn "Um @world de desktop (llvm/qt6) pode nao caber. Libere espaco antes das etapas 10a/12."
    else
        log_info "espaco livre em '/': ${livre_root:-?} GiB"
    fi

    if [[ -n "$livre_tmp" ]] && (( livre_tmp < DESKTOP_MIN_FREE_TMP_GIB )); then
        log_warn "espaco livre em '$tmpdir': ${livre_tmp} GiB (recomendado: >= ${DESKTOP_MIN_FREE_TMP_GIB} GiB)."
        log_warn "E onde o Portage COMPILA. Sem espaco, o build de niri/llvm morre no meio com 'No space left on device'."
    else
        log_info "espaco livre em '$tmpdir': ${livre_tmp:-?} GiB"
    fi
}

check_prereqs

# ---------------------------------------------------------------------------
# Execucao das etapas
# ---------------------------------------------------------------------------

# run_script <etapa>: executa o script da etapa como processo FILHO.
#
# Processo filho, e nao source, de proposito: cada script tem o proprio
# preludio (set -euo pipefail, lib-desktop.sh, require_booted_system, logging,
# run_steps) e o proprio ciclo de vida, exatamente como no instalador base.
# Assim um script que morre nao derruba o estado do orquestrador, e cada um
# continua invocavel standalone para debug.
#
# DESKTOP_DRY_RUN e DESKTOP_USER atravessam por AMBIENTE: os numerados devem
# consultar DESKTOP_DRY_RUN e apenas imprimir o que fariam quando ela for "yes".
#
# AUTORIZACAO DA 10a — por que ela tambem tem de atravessar aqui:
#
#   --with-profile-world seta WITH_PROFILE_WORLD=yes e INSERE a 10a na lista de
#   etapas, mas quem decide se a 10a faz alguma coisa sao DESKTOP_SWITCH_PROFILE
#   e DESKTOP_UPDATE_WORLD, lidas DENTRO do processo filho. Elas nascem "no" no
#   vars-desktop.sh (`: "${VAR:=no}"`) e nao sao exportadas — entao, sem o
#   repasse abaixo, o filho enxergaria "no" nas duas, pularia as DUAS sub-etapas
#   e a flag seria um no-op silencioso: imprime os avisos, roda a 10a, nao muda
#   nada. Uma flag que nao faz nada e pior que uma flag ausente.
#
# ESCAPE HATCH: valor explicito do usuario SEMPRE ganha da flag. Por isso o
# repasse usa `${_ENV_*-yes}` (default do PARAMETRO, nao `:-`): se a variavel
# original existia no ambiente, o valor dela e repassado tal e qual, inclusive
# "no" — e `DESKTOP_SWITCH_PROFILE=no ./install-desktop.sh --with-profile-world`
# continua significando "atualize o @world, mas NAO troque o perfil".
# Quando ela nao existia, nao repassamos o "no" do default: mandamos "yes",
# que e o que a flag significa.
run_script() {
    local step="$1" script
    script="$(step_script "$step")"

    if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
        die "etapa $step: script '$script' nao existe em $SCRIPT_DIR. Este modulo e composto por varios arquivos; verifique se o diretorio desktop/ esta completo."
    fi
    if [[ ! -x "$SCRIPT_DIR/$script" ]]; then
        # Nao alteramos permissao silenciosamente: dizemos o comando exato.
        die "etapa $step: '$script' existe mas nao e executavel. Rode: chmod +x $SCRIPT_DIR/$script"
    fi

    # DESKTOP_FROM_ORCHESTRATOR=1 e verdade para TODA etapa chamada daqui, e a
    # 10a ja a procura pelo nome. Um numerado rodando standalone nao a ve (nem
    # vazia: inexistente), o que a torna um sinal confiavel de "quem me chamou
    # foi o orquestrador".
    local -a env_filho=(
        "DESKTOP_DRY_RUN=$DRY_RUN"
        "DESKTOP_USER=$DESKTOP_USER"
        "DESKTOP_FROM_ORCHESTRATOR=1"
    )

    # A autorizacao so viaja quando o usuario PEDIU a 10a explicitamente: pela
    # flag, ou por '--only 10a' (a unica outra forma de agenda-la — o '--from
    # 10a' e recusado no parse). Fora esses dois casos nao inventamos permissao
    # para a acao mais cara e mais irreversivel do modulo.
    if [[ "$WITH_PROFILE_WORLD" == "yes" || "$ONLY_STEP" == "10a" ]]; then
        env_filho+=(
            "DESKTOP_SWITCH_PROFILE=${_ENV_SWITCH_PROFILE-yes}"
            "DESKTOP_UPDATE_WORLD=${_ENV_UPDATE_WORLD-yes}"
        )
    fi

    # RUIDO JUSTIFICADO (SC2034): CURRENT_STEP e declarada em lib.sh:31 e LIDA em
    # lib.sh:196 pelo trap ERR, que a cita na mensagem de erro para dizer em qual
    # etapa a falha ocorreu. O ShellCheck nao segue o source de ../lib.sh (SC1091),
    # entao enxerga so a escrita. Mesmo padrao do install.sh:235 do instalador base.
    # shellcheck disable=SC2034
    CURRENT_STEP="$script"
    log_info ">>> etapa $step — $script ($(step_desc "$step"))"
    if ! env "${env_filho[@]}" "$SCRIPT_DIR/$script"; then
        die "etapa $step ($script) falhou — corrija o problema e re-execute ./desktop/install-desktop.sh (o modulo retoma da sub-etapa que falhou; log em ${LOGFILE:-/var/log/gentoo-install/install-desktop.log})"
    fi
    log_info "<<< etapa $step concluida"
    # Mesma justificativa da atribuicao acima: limpar CURRENT_STEP faz o trap ERR
    # do lib.sh voltar a dizer "(fora de run_step)" em vez de culpar a etapa que
    # ja terminou bem. shellcheck nao ve o leitor porque nao segue o source.
    # shellcheck disable=SC2034
    CURRENT_STEP=""
}

# monta a lista efetiva de etapas desta execucao
ETAPAS_A_RODAR=()

if [[ -n "$ONLY_STEP" ]]; then
    ETAPAS_A_RODAR=("$ONLY_STEP")
else
    _comecou="no"
    for _n in "${ORDEM_ETAPAS[@]}"; do
        # --from: pula tudo antes da etapa pedida
        if [[ -n "$FROM_STEP" && "$_comecou" == "no" ]]; then
            if [[ "$_n" == "$FROM_STEP" ]]; then
                _comecou="yes"
            else
                continue
            fi
        fi
        ETAPAS_A_RODAR+=("$_n")
        # A 10a entra LOGO DEPOIS da 10 e SOMENTE com --with-profile-world.
        # Esta posicao nao e estetica: trocar o perfil liga USE=wayland
        # globalmente e o emerge -uDN @world ja reconstroi o nvidia-drivers.
        # Rodar a 10a DEPOIS da 11 recompilaria o driver duas vezes.
        if [[ "$_n" == "10" && "$WITH_PROFILE_WORLD" == "yes" ]]; then
            ETAPAS_A_RODAR+=("10a")
        fi
    done
    if [[ -n "$FROM_STEP" && "$_comecou" == "no" ]]; then
        die "--from '$FROM_STEP' nao corresponde a nenhuma etapa da sequencia (${ORDEM_ETAPAS[*]})"
    fi
fi

if [[ "$DRY_RUN" == "yes" ]]; then
    log_warn "--dry-run ATIVO: nenhum emerge sera executado e nenhuma config sera escrita."
    log_warn "Os scripts numerados recebem DESKTOP_DRY_RUN=yes e devem apenas imprimir o que fariam."
fi

if [[ "$WITH_PROFILE_WORLD" == "yes" || "$ONLY_STEP" == "10a" ]]; then
    # Os valores REALMENTE repassados a 10a, e nao "o que a flag costuma
    # significar": com o escape hatch do ambiente os dois podem divergir, e o
    # usuario tem de ver qual das duas acoes caras foi de fato autorizada ANTES
    # de a 10a comecar.
    log_warn "etapa 10a AGENDADA: ela pode trocar o perfil para"
    log_warn "default/linux/amd64/23.0/desktop e rodar 'emerge -uDN @world'."
    log_warn "  DESKTOP_SWITCH_PROFILE=${_ENV_SWITCH_PROFILE-yes}   (troca de perfil)"
    log_warn "  DESKTOP_UPDATE_WORLD=${_ENV_UPDATE_WORLD-yes}   (emerge -uDN @world)"
    if [[ -n "${_ENV_SWITCH_PROFILE+x}" || -n "${_ENV_UPDATE_WORLD+x}" ]]; then
        log_warn "  (valor(es) vindos do SEU ambiente — eles tem precedencia sobre a flag)"
    fi
    log_warn "Isso DEMORA HORAS e reconstroi grande parte do sistema, INCLUSIVE o"
    log_warn "nvidia-drivers. Faca backup antes: voltar atras exige outro @world completo."
    log_warn "A propria 10a vai pedir confirmacao e mostrar a contagem MEDIDA de pacotes."
fi

log_info "etapas desta execucao: ${ETAPAS_A_RODAR[*]}"
for _n in "${ETAPAS_A_RODAR[@]}"; do
    run_script "$_n"
done

# ---------------------------------------------------------------------------
# Resumo final acionavel
# ---------------------------------------------------------------------------
#
# O resumo NAO afirma que a sessao funciona. Ele diz o que foi feito e o que
# continua NAO VALIDADO neste hardware — porque de fato ninguem testou esta
# combinacao (Blackwell + kernel sem initramfs + simpledrm) e prometer sucesso
# aqui seria o oposto de acionavel.
print_summary() {
    local start_cmd="dbus-run-session niri --session"
    if [[ "${INIT_SYSTEM:-openrc}" != "openrc" ]]; then
        start_cmd="niri-session   # (systemd; caminho NUNCA validado neste projeto)"
    fi

    log_info "=================================================================="
    log_info "Modulo de desktop: etapas concluidas (${ETAPAS_A_RODAR[*]})"
    log_info "=================================================================="
    log_info ""
    log_info "COMO INICIAR A SESSAO (de um TTY, como o usuario $DESKTOP_USER):"
    log_info ""
    log_info "    $start_cmd"
    log_info ""
    if [[ "${INIT_SYSTEM:-openrc}" == "openrc" ]]; then
        log_info "NUNCA use 'niri-session' com OpenRC: esse script upstream procura"
        log_info "systemctl/dinitctl e, nao achando nenhum dos dois, imprime 'No systemd"
        log_info "or dinit detected' e SAI — a sessao morre na hora, normalmente sem"
        log_info "mensagem visivel. Quem cria o barramento de sessao e o dbus-run-session."
    fi
    log_info ""
    log_info "PENDENTE DE VALIDACAO NO HARDWARE REAL (ninguem testou esta combinacao):"
    log_info ""
    log_info "  * O handoff simpledrm -> nvidia-drm. Este kernel NAO tem initramfs,"
    log_info "    entao o modulo nvidia carrega tarde e a janela de troca do console"
    log_info "    fica exposta. E o MAIOR risco nao-validado do projeto."
    log_info "  * Se der TELA PRETA ou o TTY parar de trocar: o botao de escape"
    log_info "    documentado e descomentar 'options nvidia-drm fbdev=0' em"
    log_info "    /etc/modprobe.d/nvidia.conf (o proprio ebuild ja deixa a linha la,"
    log_info "    comentada). NAO reescreva esse arquivo: ele pertence ao pacote e"
    log_info "    contem a opcao de suspend correta do ramo instalado."
    log_info "  * A RTX 5060 Ti e Blackwell/GB206 e usa OBRIGATORIAMENTE os modulos"
    log_info "    de kernel ABERTOS (a doc da NVIDIA diz que o sabor proprietario"
    log_info "    cobre so ate Hopper). O userspace segue proprietario — por isso o"
    log_info "    package.license do instalador continua necessario."
    log_info ""
    log_info "Log completo desta execucao:"
    log_info "    ${LOGFILE:-/var/log/gentoo-install/install-desktop.log}"
    log_info ""
    log_info "Este script NUNCA reinicia a maquina sozinho."
}

print_summary
