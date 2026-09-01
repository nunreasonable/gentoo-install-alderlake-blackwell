#!/usr/bin/env bash
# lib-desktop.sh — biblioteca ADITIVA do modulo de desktop (niri/Wayland/NVIDIA).
#
# Este arquivo e APENAS sourced pelo install-desktop.sh e pelos scripts 10-15,
# nesta ordem obrigatoria:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib-desktop.sh"   # ele mesmo faz source de vars-desktop.sh e ../lib.sh
#   require_booted_system
#   init_logging 1X-nome
#
# REGRA 1 DO PROJETO: o instalador base (install.sh, lib.sh, vars.sh, 00-06,
# kernel-fragment.config) esta VALIDADO e NAO pode ser modificado. Este modulo
# REUSA lib.sh via source e acrescenta somente o que o instalador nao tem:
#   1. a guarda de ambiente "sistema instalado E bootado" (regra 2, fail-closed)
#   2. helpers de verificacao do Portage em RUNTIME (regra 3: nunca chutar atom)
#   3. escrita idempotente de arquivos de configuracao (regra 4: nada destrutivo)
#
# Nada aqui formata, reparticiona ou remove pacote. O modulo so instala pacotes
# e escreve configuracao em $HOME e /etc.

set -euo pipefail

# ---------------------------------------------------------------------------
# Localizacao dos arquivos (o modulo vive em desktop/, o instalador no pai)
# ---------------------------------------------------------------------------

# Diretorio deste arquivo (desktop/) e a raiz do instalador (o pai).
DESKTOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$DESKTOP_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# ARMADILHA CENTRAL DO MODULO — leia antes de mexer em qualquer coisa aqui.
# ---------------------------------------------------------------------------
#
# lib.sh:480 define state_dir() escolhendo o caminho dos markers pela fase:
#
#     state_dir() {
#         if [[ "$(current_phase)" == "chroot" ]]; then
#             echo "/var/lib/gentoo-install/state"
#         else
#             echo "$TARGET_ROOT/var/lib/gentoo-install/state"
#         fi
#     }
#
# e current_phase() (lib.sh:46) retorna "chroot" SOMENTE se existe a sentinela
# /etc/gentoo-install/.inside-chroot, senao retorna "live".
#
# No sistema JA INSTALADO E BOOTADO — que e exatamente onde este modulo roda —
# a sentinela NAO existe: o install.sh a remove ao sair do chroot com sucesso.
# Portanto current_phase() reporta "live", e state_dir() cairia no ramo do
# TARGET_ROOT. Com o default de vars.sh (TARGET_ROOT=/mnt/gentoo) isso daria
#     /mnt/gentoo/var/lib/gentoo-install/state
# que NAO existe no sistema bootado: run_step/mark_done/step_done gravariam os
# markers num caminho errado (ou criariam /mnt/gentoo do nada), e a idempotencia
# do modulo inteiro seria silenciosamente falsa a cada execucao.
#
# SOLUCAO (sem tocar UMA LINHA do lib.sh, preservando a regra 1):
# exportar TARGET_ROOT="" ANTES do source do lib.sh. Com a string vazia, o ramo
# "live" concatena "" + "/var/lib/gentoo-install/state" e devolve
#     /var/lib/gentoo-install/state
# que e o caminho CORRETO no sistema bootado. run_step, mark_done, step_done,
# step_value, clear_marker e svc_enable passam a funcionar sem alteracao.
#
# Efeito colateral verificado e desejavel: init_logging (lib.sh:84) testa
# `mountpoint -q "$TARGET_ROOT"`, que com string vazia falha silenciosamente e
# faz o log cair em /tmp/gentoo-install/. Como isso nao e o destino que
# queremos num sistema bootado, o modulo NAO usa o init_logging do instalador
# as cegas — ver init_logging_desktop() mais abaixo.
#
# DUAS COISAS QUE O MODULO NUNCA PODE CHAMAR:
#
#   require_phase — mataria o script. A fase reportada e "live" (a sentinela nao
#     existe), mas nos NAO estamos num live ISO. A guarda correta para este
#     modulo e require_booted_system(), definida neste arquivo.
#
#   validate_vars — mataria o script. lib.sh:320 exige TARGET_ROOT nao-vazio e
#     absoluto (`die "TARGET_ROOT='' invalido"`), e nos o esvaziamos de
#     proposito. Alem disso validate_vars valida TARGET_DISK e as guardas de
#     particionamento, que sao irrelevantes (e perigosas) para um modulo que nao
#     encosta em disco.
#
# Por isso o source abaixo vem com TARGET_ROOT="" ANTES, e nao depois.
TARGET_ROOT=""
export TARGET_ROOT

# vars.sh do instalador: da os defaults de INIT_SYSTEM, USERNAME, MAKEOPTS etc.
# que os helpers deste arquivo consultam. E so atribuicao com `: "${VAR:=...}"`,
# nao executa logica nenhuma — seguro de sourcear aqui.
# ATENCAO: vars.sh define TARGET_ROOT com `: "${TARGET_ROOT:=/mnt/gentoo}"`.
# A forma := so atribui se a variavel estiver NAO-DEFINIDA ou VAZIA — e a nossa
# esta definida porem VAZIA, entao ela SERIA sobrescrita para /mnt/gentoo.
# Por isso reafirmamos TARGET_ROOT="" DEPOIS do source de vars.sh, logo abaixo.
# shellcheck source=../vars.sh
source "$INSTALLER_DIR/vars.sh"

# Reafirmacao obrigatoria: vars.sh acabou de repor /mnt/gentoo (ver acima).
# Esta linha e o que realmente faz state_dir() apontar para /var/lib/... .
TARGET_ROOT=""
export TARGET_ROOT

# lib.sh do instalador: run_step, logging, die, markers, svc_enable,
# _host_is_installed_system. NUNCA reimplementar nada disso aqui.
# shellcheck source=../lib.sh
source "$INSTALLER_DIR/lib.sh"

# vars-desktop.sh: variaveis proprias do modulo (DESKTOP_USER, DESKTOP_ASSUME_YES,
# escolhas de terminal/notificador etc.). E responsabilidade de OUTRO arquivo.
# Sourceado depois do lib.sh para poder sobrescrever defaults se precisar.
# Ausente = o modulo ainda funciona com os fallbacks definidos logo abaixo, para
# que este arquivo possa ser testado isoladamente.
if [[ -f "$DESKTOP_DIR/vars-desktop.sh" ]]; then
    # shellcheck source=./vars-desktop.sh disable=SC1091
    source "$DESKTOP_DIR/vars-desktop.sh"
fi

# ---------------------------------------------------------------------------
# Defaults minimos (fallback se vars-desktop.sh ainda nao existe)
# ---------------------------------------------------------------------------
#
# Todos com `: "${VAR:=...}"` para que vars-desktop.sh, quando existir, e o
# ambiente do usuario tenham precedencia. Nenhum deles substitui vars-desktop.sh
# — sao so a rede de seguranca que permite `bash -n` e testes isolados.

# Usuario dono da sessao grafica. Herda USERNAME do instalador por padrao: e o
# usuario que o 06 criou. gsettings e dotfiles rodam como ELE, nunca como root.
: "${DESKTOP_USER:=${USERNAME:-gentoo}}"

# yes = nao pergunta nada nas acoes caras (troca de perfil, -uDN @world).
# Default "no": acao cara exige consentimento explicito.
: "${DESKTOP_ASSUME_YES:=no}"

# Diretorio dos markers deste modulo — o MESMO do instalador, ja que os scripts
# usam o run_step dele. Exposto como variavel so para as mensagens de erro.
: "${DESKTOP_STATE_DIR:=/var/lib/gentoo-install/state}"

# ---------------------------------------------------------------------------
# Logging do modulo
# ---------------------------------------------------------------------------

# init_logging_desktop <nome-do-script>: equivalente ao init_logging do
# instalador, porem com destino FIXO em /var/log/gentoo-install/.
#
# Por que nao reusar init_logging direto: ele escolhe o diretorio por
# current_phase()/mountpoint de TARGET_ROOT. Como o modulo zera TARGET_ROOT (ver
# a armadilha central acima), a fase reportada e "live" e o mountpoint falha,
# entao o log cairia em /tmp/gentoo-install/ e sumiria no proximo boot. Num
# sistema instalado o lugar certo e /var/log.
#
# O resto do contrato e identico ao do instalador: LOGFILE e a variavel global
# que o trap ERR e o die() do lib.sh citam nas mensagens, e o `tee -a` acumula
# re-execucoes do mesmo script no mesmo arquivo.
init_logging_desktop() {
    local script_name="$1" logdir="/var/log/gentoo-install"
    mkdir -p "$logdir" \
        || die "nao foi possivel criar $logdir — rode o modulo como root (sudo)."
    LOGFILE="$logdir/${script_name}.log"
    # fd 9 guarda o stdout original, mesmo contrato do lib.sh:99.
    if ! { true >&9; } 2>/dev/null; then
        exec 9>&1
    fi
    exec > >(tee -a "$LOGFILE") 2>&1
    # RUIDO JUSTIFICADO (SC2034): LOGGING_TEE_PID e declarada em lib.sh:39 e LIDA
    # em lib.sh:158-159, onde o `wait` garante que o tee esvazie o buffer antes do
    # script sair. Manter a atribuicao aqui preserva esse contrato; remove-la faria
    # o lib.sh esperar por um PID vazio e perder o fim do log.
    # shellcheck disable=SC2034
    LOGGING_TEE_PID=$!
    log_info "==== $script_name (modulo desktop) iniciado — log: $LOGFILE ===="
}

# ---------------------------------------------------------------------------
# GUARDA DE FASE — regra 2, fail-closed, por EVIDENCIA POSITIVA
# ---------------------------------------------------------------------------
#
# O modulo instala pacotes e escreve em /etc e em $HOME. Rodar por engano no
# live ISO ou dentro do chroot da instalacao gravaria no lugar errado (ou no
# sistema errado). Por isso a guarda NAO procura sinais de live ISO (deteccao
# negativa, que falha em aberto quando um sinal novo aparece): ela PROVA, item a
# item, que estamos num sistema instalado e realmente bootado.
#
# FAIL-CLOSED POR CONSTRUCAO: qualquer condicao que nao possa ser PROVADA —
# comando ausente, erro de leitura, saida vazia — resulta em die. Na duvida,
# recusa. Cada mensagem diz O QUE foi detectado e o que fazer.
#
# Chamada UMA vez pelo install-desktop.sh antes de qualquer outra coisa, e
# TAMBEM no topo de cada script numerado (10-15), porque os scripts do projeto
# rodam standalone para debug — mesmo padrao do require_phase do instalador, que
# e repetido em todos os 00-06.
require_booted_system() {
    log_info "guarda de ambiente: verificando que estamos num sistema instalado e bootado..."

    _rbs_check_not_chroot
    _rbs_check_pid1_is_init
    _rbs_check_root_on_real_disk
    _rbs_check_rootfs_type
    _rbs_check_no_chroot_sentinel
    _rbs_check_target_not_mounted
    _rbs_check_install_finished
    _rbs_check_init_running

    log_info "guarda de ambiente: OK — sistema instalado e bootado, modulo pode prosseguir"
}

# (a) NAO estamos em chroot: o / que enxergamos tem de ser o MESMO inode/device
# que o / do PID 1. Num chroot eles diferem, porque o processo enxerga um
# subdiretorio como raiz enquanto o init continua na raiz real.
# Fail-closed: se qualquer stat falhar (o que acontece com /proc nao montado),
# nao da para provar nada -> die.
_rbs_check_not_chroot() {
    local root_id pid1_root_id
    root_id="$(stat -c '%d:%i' / 2>/dev/null)" \
        || die "guarda de ambiente: nao foi possivel ler a identidade de '/' com stat. Sem essa leitura nao da para provar que nao estamos num chroot — abortando por precaucao (fail-closed)."
    pid1_root_id="$(stat -c '%d:%i' /proc/1/root/. 2>/dev/null)" \
        || die "guarda de ambiente: nao foi possivel ler /proc/1/root/. — /proc nao esta montado ou nao ha permissao. Rode como root num sistema bootado normalmente."
    [[ -n "$root_id" && -n "$pid1_root_id" ]] \
        || die "guarda de ambiente: leitura de identidade de '/' retornou vazia — abortando por precaucao (fail-closed)."
    [[ "$root_id" == "$pid1_root_id" ]] \
        || die "guarda de ambiente: CHROOT DETECTADO — o '/' deste shell ($root_id) e diferente do '/' do PID 1 ($pid1_root_id). Este modulo so pode rodar no sistema ja instalado e BOOTADO, nunca dentro do chroot da instalacao. Saia do chroot, reinicie na instalacao concluida e rode de la."
}

# (b) O PID 1 e um init de verdade. Num chroot interativo o "PID 1" visto pelo
# shell costuma ser bash/sh — evidencia direta de que nao ha init rodando.
_rbs_check_pid1_is_init() {
    local comm
    comm="$(cat /proc/1/comm 2>/dev/null)" \
        || die "guarda de ambiente: nao foi possivel ler /proc/1/comm — /proc indisponivel. Abortando por precaucao (fail-closed)."
    [[ -n "$comm" ]] \
        || die "guarda de ambiente: /proc/1/comm veio vazio — abortando por precaucao (fail-closed)."
    case "$comm" in
        init|openrc-init|systemd) : ;;
        *)
            die "guarda de ambiente: o PID 1 e '$comm', que nao e um init (esperado: init, openrc-init ou systemd). Isso indica chroot ou container, nao um sistema bootado. Reinicie no sistema instalado e rode o modulo de la."
            ;;
    esac
}

# (c) O / vive numa cadeia de devices que termina num disco REAL.
# REUSO ELEGANTE: _host_is_installed_system (lib.sh:244) ja resolve a cadeia com
# lsblk e exige TYPE=disk. O instalador a usa para RECUSAR rodar num host
# instalado; o modulo usa a MESMA funcao com o sentido INVERTIDO, para EXIGIR
# host instalado. Uma unica implementacao, dois usos opostos — nada reimplementado.
# Live ISO tem / em overlay/tmpfs (SOURCE nem e block device) ou em loop/rom.
_rbs_check_root_on_real_disk() {
    _host_is_installed_system \
        || die "guarda de ambiente: o '/' em execucao NAO vive num disco real (lsblk nao encontrou TYPE=disk na cadeia). Isso e a assinatura de um live ISO (overlay/tmpfs/squashfs em loop). Este modulo so roda no sistema instalado e bootado."
}

# (d) O filesystem da raiz nao e um dos tipos usados por live ISO/container.
# Complementa (c): (c) olha o DEVICE, este olha o TIPO de filesystem.
_rbs_check_rootfs_type() {
    local fstype
    fstype="$(findmnt -no FSTYPE / 2>/dev/null)" \
        || die "guarda de ambiente: findmnt nao conseguiu determinar o filesystem de '/'. Abortando por precaucao (fail-closed)."
    [[ -n "$fstype" ]] \
        || die "guarda de ambiente: o tipo de filesystem de '/' veio vazio — abortando por precaucao (fail-closed)."
    case "$fstype" in
        squashfs|tmpfs|overlay|ramfs|rootfs|iso9660)
            die "guarda de ambiente: o '/' esta em '$fstype', filesystem tipico de live ISO ou container — nao de um sistema instalado. Reinicie na instalacao concluida e rode o modulo de la."
            ;;
    esac
    log_info "guarda de ambiente: rootfs em '$fstype' (disco real)"
}

# (e) A sentinela de chroot do instalador esta AUSENTE.
# Redundante com (a) de proposito: se por qualquer motivo o modulo for chamado
# de dentro do chroot que o install.sh montou, esta e a evidencia mais direta e
# barata. Usa a constante CHROOT_SENTINEL do proprio lib.sh (linha 23).
_rbs_check_no_chroot_sentinel() {
    [[ ! -e "$CHROOT_SENTINEL" ]] \
        || die "guarda de ambiente: a sentinela de chroot $CHROOT_SENTINEL existe — estamos DENTRO do chroot da instalacao. Saia do chroot e reinicie no sistema instalado antes de rodar o modulo de desktop."
}

# (f) O ponto de montagem do alvo NAO esta montado. Se /mnt/gentoo e mountpoint,
# a leitura mais provavel e: estamos no live ISO com o sistema alvo montado.
# Nota: a variavel TARGET_ROOT foi zerada de proposito (armadilha central), entao
# a checagem usa o caminho literal do default do instalador.
_rbs_check_target_not_mounted() {
    local target="/mnt/gentoo"
    if mountpoint -q "$target" 2>/dev/null; then
        die "guarda de ambiente: '$target' esta MONTADO, o que indica live ISO com o sistema alvo montado (fase de instalacao). Este modulo roda no sistema ja bootado. Se o mount for residual, desmonte-o antes de continuar."
    fi
}

# (g) EVIDENCIA DE INSTALACAO CONCLUIDA. So checar que o diretorio de state
# existe seria fraco: um chroot de instalacao a meio caminho tambem o teria.
# Exigimos os markers FINAIS do 06 — se eles existem, a instalacao chegou ao
# fim, e nao apenas comecou.
#
# Coerencia arquitetural: como state_dir() do lib.sh agora resolve para
# /var/lib/gentoo-install/state (gracas ao TARGET_ROOT=""), esta checagem usa a
# PROPRIA state_dir(), e nao um caminho hardcoded. Assim, se o caminho do state
# mudar no instalador, a guarda acompanha sozinha.
_rbs_check_install_finished() {
    local dir missing=() m
    dir="$(state_dir)"
    [[ -d "$dir" ]] \
        || die "guarda de ambiente: o diretorio de state do instalador nao existe em '$dir'. Isso indica que este sistema nao foi instalado por este instalador, ou que a instalacao nao chegou ao fim. O modulo de desktop pressupoe o sistema base instalado e bootado."

    # Markers gravados pelas ultimas sub-etapas do 06-users-services.sh
    # (verificados no codigo: run_step 06-users e run_step 06-services).
    for m in 06-users 06-services; do
        [[ -e "$dir/$m" ]] || missing+=("$m")
    done
    if (( ${#missing[@]} > 0 )); then
        die "guarda de ambiente: faltam os markers finais da instalacao em '$dir': ${missing[*]}. A instalacao base nao foi concluida (a etapa 06-users-services.sh nao terminou). Conclua a instalacao antes de rodar o modulo de desktop."
    fi
    log_info "guarda de ambiente: instalacao base concluida (markers 06-users e 06-services presentes)"
}

# (h) O init esta REALMENTE de pe. Em OpenRC, /run/openrc/softlevel so existe
# quando o OpenRC subiu de verdade — jamais dentro de um chroot. E a prova final
# de "bootado", e nao apenas "montado".
_rbs_check_init_running() {
    if [[ "${INIT_SYSTEM:-openrc}" == "openrc" ]]; then
        [[ -e /run/openrc/softlevel ]] \
            || die "guarda de ambiente: INIT_SYSTEM=openrc mas /run/openrc/softlevel nao existe — o OpenRC nao esta em execucao. Esse arquivo so aparece num sistema realmente bootado (nunca em chroot). Reinicie no sistema instalado e rode o modulo de la."
        log_info "guarda de ambiente: OpenRC em execucao (runlevel '$(cat /run/openrc/softlevel 2>/dev/null || echo desconhecido)')"
    else
        # systemd: a existencia de /run/systemd/system e o teste canonico
        # (o proprio systemd o documenta como "estamos rodando sob systemd?").
        [[ -d /run/systemd/system ]] \
            || die "guarda de ambiente: INIT_SYSTEM=systemd mas /run/systemd/system nao existe — o systemd nao esta gerenciando este sistema. Reinicie no sistema instalado e rode o modulo de la."
        log_info "guarda de ambiente: systemd em execucao"
    fi
}

# require_root: o modulo escreve em /etc e chama emerge. Falhar aqui, cedo e com
# mensagem clara, e muito melhor que falhar no meio de um emerge.
require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] \
        || die "este script precisa de root (escreve em /etc/portage e chama emerge). Rode com sudo. As etapas de $HOME rodam como '$DESKTOP_USER' automaticamente, via run_as_user."
}

# ---------------------------------------------------------------------------
# VERIFICACAO EM RUNTIME DO PORTAGE — regra 3: nunca chutar nome de pacote
# ---------------------------------------------------------------------------
#
# A pesquisa marcou varios atoms como "provavel" ou "nao verificado" (keywords
# de fuzzel, waybar, alacritty, xdg-desktop-portal-*, e sobretudo QUAL ramo de
# nvidia-drivers o 04 resolveu). Em vez de assumir, o modulo DESCOBRE em runtime
# e falha com mensagem acionavel. Estes helpers sao a implementacao disso.

# pkg_installed <categoria/nome>: 0 se o pacote esta instalado, olhando o VDB do
# Portage diretamente (autoridade real, sem depender de portage-utils).
# Mesma implementacao ja usada em 04-kernel.sh:45 e 06-users-services.sh:42 —
# repetida aqui porque este modulo nao pode sourcear os scripts numerados do
# instalador (eles executam acoes no topo, nao sao bibliotecas).
pkg_installed() {
    compgen -G "/var/db/pkg/${1}-[0-9]*" > /dev/null
}

# have_atom <atom>: 0 se o atom EXISTE e esta VISIVEL para o Portage (repositorio
# habilitado + keyword aceita + nao mascarado), imprimindo a melhor versao.
# 1 caso contrario, sem imprimir nada.
#
# Esta e a checagem que substitui o chute de nome de pacote. `best_visible` e
# mais rigoroso que a mera existencia do ebuild: um pacote do GURU sem o overlay
# habilitado, ou um ~amd64 sem package.accept_keywords, NAO e visivel — que e
# exatamente o modo de falha que a pesquisa apontou como "o erro que custa uma
# hora". O mesmo comando ja e usado pelo 04-kernel.sh:125.
have_atom() {
    local atom="$1" best
    best="$(portageq best_visible / "$atom" 2>/dev/null)" || return 1
    [[ -n "$best" ]] || return 1
    printf '%s\n' "$best"
}

# require_atoms <atom>...: exige que TODOS os atoms sejam visiveis.
# ACUMULA as falhas e, no fim, morre listando TODAS de uma vez com o motivo
# provavel. Falhar uma vez com a lista inteira e muito melhor que o usuario
# descobrir os problemas um por um, um emerge de cada vez.
require_atoms() {
    local atom best missing=() found=()
    for atom in "$@"; do
        if best="$(have_atom "$atom")"; then
            found+=("$atom -> $best")
        else
            missing+=("$atom")
        fi
    done

    local f
    for f in "${found[@]}"; do
        log_info "atom resolvido: $f"
    done

    if (( ${#missing[@]} > 0 )); then
        log_error "os seguintes atoms NAO sao visiveis para o Portage:"
        for f in "${missing[@]}"; do
            log_error "    $f"
        done
        die "$(( ${#missing[@]} )) atom(s) nao resolvem. Causas provaveis, nesta ordem: (1) o overlay GURU nao esta habilitado — niri, fuzzel e xwayland-satellite NAO existem no ::gentoo; confira com 'portageq get_repo_path / guru'; (2) falta a keyword ~amd64 em /etc/portage/package.accept_keywords/; (3) o nome do pacote esta errado — confira em packages.gentoo.org. Rode a etapa 10-portage-desktop antes desta."
    fi
}

# have_use_flag <atom> <flag>: 0 se o flag EXISTE no IUSE do ebuild.
#
# ANTIDOTO DIRETO PARA A ARMADILHA DO kernel-open: a pesquisa confirmou que em
# nvidia-drivers >=595 o flag kernel-open DEIXOU DE EXISTIR, e que o 04-kernel.sh
# ABORTA se encontrar esse flag em qualquer package.use quando o ramo resolvido
# for >=595. Escrever um flag que o ebuild nao declara quebra o emerge (e, no
# caso do kernel-open, sabota o instalador validado). Regra: NUNCA escrever em
# package.use sem antes perguntar ao ebuild se o flag existe.
#
# Le o IUSE do metadata cache do Portage (`portageq metadata`), que e a fonte
# autoritativa e nao exige app-portage/gentoolkit instalado. O prefixo "+"/"-"
# dos defaults do IUSE e removido antes da comparacao.
have_use_flag() {
    local atom="$1" flag="$2" best cpv iuse f
    best="$(have_atom "$atom")" || return 1
    # best_visible devolve o CPV completo (categoria/nome-versao), que e o que
    # `portageq metadata` espera.
    cpv="$best"
    iuse="$(portageq metadata / ebuild "$cpv" IUSE 2>/dev/null)" || return 1
    [[ -n "$iuse" ]] || return 1
    for f in $iuse; do
        # remove o default (+dbus -> dbus, -systemd -> systemd)
        f="${f#[+-]}"
        [[ "$f" == "$flag" ]] && return 0
    done
    return 1
}

# require_use_flag <atom> <flag>: idem, porem fatal e com mensagem acionavel.
# Use antes de escrever o flag em package.use.
require_use_flag() {
    local atom="$1" flag="$2"
    have_use_flag "$atom" "$flag" \
        || die "o USE flag '$flag' NAO existe no IUSE de '$atom' nesta versao. Escrever um flag inexistente em package.use faz o Portage recusar o emerge. Confira o IUSE real com: portageq metadata / ebuild \$(portageq best_visible / $atom) IUSE"
}

# nvidia_branch: imprime o ramo do x11-drivers/nvidia-drivers em uso — "580" ou
# "595+" — e retorna 1 se nao conseguir determinar.
#
# TODA a logica de NVIDIA do modulo bifurca aqui. A pesquisa NAO conseguiu
# confirmar qual ramo o 04-kernel.sh resolveu nesta maquina, e as diferencas sao
# grandes e incompativeis entre si:
#
#   ramo 580 LTS : USE=kernel-open AINDA existe e e obrigatorio para Blackwell;
#                  nvidia.conf traz 'options nvidia-drm modeset=1' e
#                  NVreg_PreserveVideoMemoryAllocations=1; NAO depende de
#                  egl-wayland2.
#   ramo >=595   : USE=kernel-open FOI REMOVIDO (declara-lo quebra o emerge);
#                  modeset=1 virou default do driver; nvidia.conf usa
#                  NVreg_UseKernelSuspendNotifiers=1; depende de egl-wayland E
#                  egl-wayland2 ao mesmo tempo.
#
# Por isso o modulo DESCOBRE em vez de assumir. Prioridade: a versao INSTALADA
# (o que de fato vai rodar) e mais relevante que a visivel na arvore; so caimos
# na visivel se nada estiver instalado ainda.
nvidia_branch() {
    local ver=""
    # best_version consulta o VDB (instalado). Formato: categoria/nome-versao.
    ver="$(portageq best_version / x11-drivers/nvidia-drivers 2>/dev/null)" || ver=""
    if [[ -z "$ver" ]]; then
        ver="$(portageq best_visible / x11-drivers/nvidia-drivers 2>/dev/null)" || ver=""
    fi
    [[ -n "$ver" ]] || return 1

    # Extrai o major da versao: "x11-drivers/nvidia-drivers-595.91.07" -> 595
    local major="${ver##*-}"      # 595.91.07
    major="${major%%.*}"          # 595
    [[ "$major" =~ ^[0-9]+$ ]] || return 1

    if (( major >= 595 )); then
        printf '595+\n'
    else
        printf '580\n'
    fi
}

# openrc_version_ge <versao>: 0 se a versao do OpenRC instalado e >= a pedida.
#
# Serve para decidir a rota do PipeWire: user services (`rc-update add -U`)
# exigem OpenRC recente; em versao anterior a rota obrigatoria e o
# gentoo-pipewire-launcher no autostart do compositor. A pesquisa nao confirmou
# a versao que o stage3 atual entrega, entao o modulo mede em vez de supor.
#
# Usa `sort -V` (ordenacao de versao do coreutils) em vez de comparacao
# lexicografica, que erraria em casos como 0.60 vs 0.9.
openrc_version_ge() {
    local want="$1" have
    have="$(openrc --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1)" || have=""
    [[ -n "$have" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1)" == "$want" ]]
}

# repo_enabled <nome>: 0 se o repositorio/overlay esta habilitado.
# Probe correto para o GURU, conforme a pesquisa: testar o repo de verdade, e
# nao a existencia de um marker.
repo_enabled() {
    local path
    path="$(portageq get_repo_path / "$1" 2>/dev/null)" || return 1
    [[ -n "$path" && -d "$path" ]]
}

# ---------------------------------------------------------------------------
# ESCRITA IDEMPOTENTE DE CONFIGURACAO — regra 4: nada destrutivo
# ---------------------------------------------------------------------------

# _managed_header <arquivo-de-origem>: cabecalho dos arquivos que o modulo gera.
# Deixa explicito para o usuario (e para o proximo leitor) quem escreveu aquilo.
_managed_header() {
    printf '# Gerado por %s do modulo desktop (gentoo-install).\n' "$1"
    printf '# Reescrito automaticamente quando o conteudo esperado muda.\n'
    printf '# Edicoes manuais neste arquivo PODEM ser sobrescritas.\n'
}

# write_managed_file <arquivo> <conteudo> [origem]: escreve um arquivo que
# PERTENCE ao modulo, com cabecalho identificando a origem.
#
# So reescreve se o conteudo final diferir do que ja esta em disco. Isso evita
# mexer em mtime a toa — o que importa porque mtime gratuito faria o Portage e
# ferramentas de config julgarem o arquivo alterado sem motivo, e polui o
# diagnostico de "o que mudou desde o ultimo boot".
#
# Idempotente por construcao: rodar duas vezes nao muda nada na segunda.
write_managed_file() {
    local file="$1" content="$2" origin="${3:-${BASH_SOURCE[1]##*/}}"
    local desired dir
    desired="$(_managed_header "$origin"; printf '%s\n' "$content")"

    dir="$(dirname "$file")"
    mkdir -p "$dir" || die "nao foi possivel criar o diretorio '$dir' para escrever '$file'."

    if [[ -f "$file" ]] && [[ "$(cat "$file")" == "$desired" ]]; then
        log_info "'$file' ja esta com o conteudo esperado — nada a fazer"
        return 0
    fi

    printf '%s\n' "$desired" > "$file" \
        || die "falha ao escrever '$file' — verifique permissoes (o script precisa de root)."
    log_info "'$file' escrito pelo modulo desktop"
}

# write_config_if_absent <arquivo> <conteudo> [origem]: escreve SOMENTE se o
# arquivo nao existe. NUNCA sobrescreve.
#
# E o oposto de write_managed_file, e a distincao e deliberada: arquivos que
# pertencem ao USUARIO (config.kdl do niri, dotfiles, temas) sao dele, nao do
# modulo. Se ele ja customizou, o modulo nao tem o direito de reescrever — a
# regra 4 proibe operacao destrutiva, e apagar a configuracao de alguem e
# destrutivo mesmo que nenhum arquivo seja "removido".
write_config_if_absent() {
    local file="$1" content="$2" origin="${3:-${BASH_SOURCE[1]##*/}}"
    local dir

    if [[ -e "$file" ]]; then
        log_info "'$file' ja existe — preservado como esta (o modulo nunca sobrescreve config do usuario)"
        return 0
    fi

    dir="$(dirname "$file")"
    mkdir -p "$dir" || die "nao foi possivel criar o diretorio '$dir' para escrever '$file'."
    {
        _managed_header "$origin"
        printf '%s\n' "$content"
    } > "$file" || die "falha ao escrever '$file'."
    log_info "'$file' criado pelo modulo desktop"
}

# append_line_once <arquivo> <linha>: acrescenta a linha somente se ela ainda
# nao existir (comparacao de linha INTEIRA, nao substring).
#
# Usado no /etc/default/grub, onde a pesquisa alertou explicitamente: "o modulo
# precisa editar /etc/default/grub e regerar grub.cfg de forma idempotente (nao
# duplicar o parametro se ja existir)".
#
# grep -qxF: -x exige match da linha inteira e -F trata o texto como literal —
# sem os dois, uma linha que contenha a outra como substring geraria falso
# positivo, e caracteres como '.' e '*' seriam interpretados como regex.
append_line_once() {
    local file="$1" line="$2"
    if [[ -f "$file" ]] && grep -qxF -- "$line" "$file"; then
        log_info "'$file' ja contem a linha desejada — nada a fazer"
        return 0
    fi
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$line" >> "$file" \
        || die "falha ao acrescentar linha em '$file'."
    log_info "linha acrescentada a '$file': $line"
}

# run_as_user <comando>...: executa o comando como $DESKTOP_USER.
#
# OBRIGATORIO para gsettings e para qualquer escrita em $HOME. A pesquisa foi
# explicita: "gsettings precisa rodar como USUARIO com D-Bus de sessao ativo. Se
# o modulo rodar gsettings como root ou fora da sessao grafica, escreve no lugar
# errado (ou falha)". Como o modulo roda com sudo, sem este wrapper os dotfiles
# nasceriam com dono root dentro do $HOME do usuario — que e um jeito silencioso
# de quebrar a sessao grafica inteira.
#
# `su - <user> -c` (com o hifen) monta o ambiente de login do usuario: HOME,
# USER, SHELL e PATH corretos. Sem o hifen, HOME continuaria sendo /root e os
# dotfiles iriam para o lugar errado.
#
# Os argumentos sao citados individualmente com printf %q antes de virarem a
# string unica que o `su -c` exige, para que caminho com espaco ou aspas nao
# quebre nem permita injecao acidental.
run_as_user() {
    local user="$DESKTOP_USER" cmd

    id -u "$user" &>/dev/null \
        || die "o usuario '$user' nao existe neste sistema. Ajuste DESKTOP_USER em vars-desktop.sh (o instalador cria o usuario definido em USERNAME)."

    cmd="$(printf '%q ' "$@")"
    log_info "executando como '$user': $*"
    su - "$user" -c "$cmd"
}

# user_home: imprime o $HOME real de $DESKTOP_USER, lido do /etc/passwd.
# Nunca montar o caminho como "/home/$user": o home pode estar em outro lugar, e
# adivinhar caminho de home e exatamente o tipo de suposicao que a regra 3 proibe.
user_home() {
    local home
    home="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)" \
        || die "nao foi possivel consultar o home de '$DESKTOP_USER' via getent."
    [[ -n "$home" ]] \
        || die "o home de '$DESKTOP_USER' veio vazio do /etc/passwd — verifique a conta."
    printf '%s\n' "$home"
}

# ---------------------------------------------------------------------------
# CONFIRMACAO DE ACOES CARAS
# ---------------------------------------------------------------------------

# emerge_pretend_count <argumentos-do-emerge>...: imprime quantos pacotes o
# emerge instalaria/reconstruiria, contando as linhas de pacote do --pretend.
#
# Existe para que confirm_expensive mostre um numero REAL. A pesquisa foi
# categorica: nao existe estimativa publicada confiavel de duracao de um
# `-uDN @world`, e "a unica resposta honesta e rodar com -p/--pretend primeiro e
# contar os pacotes. NAO aceite estimativa de horas de ninguem". Entao o modulo
# nao inventa tempo: informa a contagem medida e deixa a decisao com o usuario.
#
# --pretend e --nodeps-free: nao instala nada, so calcula (seguro sob a regra 5).
emerge_pretend_count() {
    local out
    # NAO use --quiet aqui. O --quiet SUPRIME exatamente as linhas "[ebuild ...".
    # que contamos abaixo, entao a funcao devolvia 0 com sucesso (rc=0) em vez de
    # falhar — um zero FALSO, pior que erro nenhum, porque convenceria o usuario
    # de que nao ha nada a compilar logo antes de um emerge de horas.
    # Reproduzido com stub que imita a saida real do emerge nos dois modos.
    out="$(emerge --pretend "$@" 2>/dev/null)" || return 1
    # Linhas de pacote do --pretend comecam com "[ebuild ..." ou "[binary ...".
    # [nomerge] e excluido de proposito: sao pacotes que NAO serao tocados, e
    # conta-los inflaria o numero mostrado ao usuario.
    printf '%s\n' "$out" | grep -cE '^\[(ebuild|binary)' || true
}

# confirm_expensive <titulo> <descricao> [comando-de-pretend...]: prompt
# interativo para as acoes caras (troca de perfil, emerge -uDN @world).
#
# Retorna 0 se pode prosseguir, 1 se o usuario recusou.
#
# Se um comando de pretend for passado, a contagem REAL de pacotes e calculada e
# exibida ANTES da pergunta — numero medido, nunca estimativa inventada.
#
# DESKTOP_ASSUME_YES=yes pula o prompt (automacao). O default e "no": acao cara
# nao acontece por acidente. Le de /dev/tty, e nao de stdin, pelo mesmo motivo do
# confirm_destruction do instalador (lib.sh:1197): o stdout do script esta
# redirecionado para o tee do logging, e stdin pode nao ser o terminal.
confirm_expensive() {
    local title="$1" desc="$2"
    shift 2

    printf '\n'
    printf '========================================================================\n'
    printf '  ACAO CARA: %s\n' "$title"
    printf '========================================================================\n'
    printf '%s\n' "$desc"

    if (( $# > 0 )); then
        local count
        printf '\nCalculando a contagem real de pacotes com emerge --pretend (aguarde)...\n'
        if count="$(emerge_pretend_count "$@")"; then
            printf 'Pacotes que seriam instalados/reconstruidos: %s\n' "$count"
            printf '(contagem MEDIDA nesta maquina; nao ha estimativa confiavel de duracao —\n'
            printf ' o tempo depende do hardware, da rede e dos pacotes envolvidos.)\n'
        else
            log_warn "nao foi possivel calcular a contagem com --pretend; prosseguindo sem o numero"
        fi
    fi

    if [[ "$DESKTOP_ASSUME_YES" == "yes" ]]; then
        printf '\nDESKTOP_ASSUME_YES=yes — prosseguindo sem confirmacao interativa.\n'
        log_info "acao cara '$title' autorizada por DESKTOP_ASSUME_YES"
        return 0
    fi

    local reply
    printf '\nProsseguir? Digite exatamente "sim" para continuar: '
    IFS= read -r reply < /dev/tty \
        || die "nao foi possivel ler a confirmacao do terminal. Para automacao, use DESKTOP_ASSUME_YES=yes."
    if [[ "$reply" == "sim" ]]; then
        log_info "acao cara '$title' confirmada pelo usuario"
        return 0
    fi
    log_warn "acao cara '$title' RECUSADA pelo usuario (recebido: '$reply') — nada foi alterado"
    return 1
}

# ---------------------------------------------------------------------------
# DRY-RUN
# ---------------------------------------------------------------------------

# dry_run_guard <sub-etapa>...: ponto UNICO onde um script numerado honra
# DESKTOP_DRY_RUN=yes. Quando a variavel nao vale "yes" a funcao nao faz nada e
# o script segue seu curso normal.
#
# POR QUE ISTO EXISTE: o install-desktop.sh aceita --dry-run, imprime que
# "nenhum emerge sera executado e nenhuma config sera escrita" e repassa
# DESKTOP_DRY_RUN=yes por ambiente a cada numerado (install-desktop.sh:571).
# Mas HONRAR a variavel e responsabilidade de cada script — e enquanto so a
# 10a a consultava, a promessa era FALSA: o emerge rodava de verdade, o
# /etc/portage era escrito, o rc-update habilitava servicos e os dotfiles iam
# parar no $HOME do usuario. Uma flag cujo proposito e seguranca nao pode
# mentir; e esta funcao que faz a promessa valer.
#
# POR QUE `exit 0` E NAO `die`, ao contrario do 10a-profile-world.sh:309/395 —
# a diferenca e deliberada, nao esquecimento. Na 10a a guarda esta la embaixo,
# colada no eselect/emerge, e mata o script; funciona porque a 10a e opt-in e
# roda praticamente sozinha. Nos numerados 10-15 o mesmo `die` ABORTARIA o
# dry-run inteiro: o run_script do orquestrador trata saida nao-zero como
# "etapa falhou" e chama die (install-desktop.sh:594). O --dry-run morreria no
# primeiro emerge da etapa 10 e o usuario nunca veria as etapas 11 a 15 — ou
# seja, a flag ficaria segura e INUTIL ao mesmo tempo. Saindo com 0, o
# orquestrador segue para a etapa seguinte e o dry-run percorre o modulo
# inteiro, que e o unico motivo de um dry-run existir.
#
# POR QUE A CHAMADA FICA COLADA NO PRIMEIRO run_step de cada script, e nao na
# primeira linha do arquivo: assim TODO o preludio somente-leitura ainda roda
# sob --dry-run — a validacao das escolhas do vars-desktop.sh (12-niri-stack),
# a recusa de INIT_SYSTEM != openrc (13-services), a leitura do $HOME real do
# usuario (14-dotfiles). Um dry-run que pula essas checagens deixaria passar
# erro de configuracao que so apareceria na execucao de verdade, quando ja e
# tarde. Nada entre o topo do arquivo e a chamada pode ter efeito colateral —
# e o tests/test-desktop.sh vigia exatamente isso.
#
# Os nomes das sub-etapas sao passados a mao porque nao existe como um script
# descobrir os proprios run_step sem executa-los. A duplicacao e vigiada: o
# tests/test-desktop.sh compara esta lista com os run_step reais do arquivo e
# falha se as duas divergirem.
dry_run_guard() {
    [[ "${DESKTOP_DRY_RUN:-no}" == "yes" ]] || return 0

    local origem="${BASH_SOURCE[1]##*/}" etapa
    log_warn "DESKTOP_DRY_RUN=yes — '$origem' NAO vai alterar nada nesta execucao."
    log_warn "Nenhum emerge, nenhuma escrita em /etc ou no \$HOME, nenhum servico habilitado."

    if (( $# > 0 )); then
        log_info "Sem --dry-run, '$origem' executaria estas sub-etapas, nesta ordem:"
        for etapa in "$@"; do
            log_info "    $etapa"
        done
        # Dizer isto evita a leitura errada de que a lista e trabalho garantido:
        # o probe de cada sub-etapa e a autoridade, e o que ja estiver feito e
        # pulado. Medir isso aqui exigiria rodar os probes, e um deles
        # (probe_world_update) custa um `emerge --pretend` completo.
        log_info "(a lista e o PLANO, nao a previsao: cada sub-etapa consulta o proprio probe e pula o que ja estiver feito)"
    fi

    exit 0
}
