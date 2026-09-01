#!/usr/bin/env bash
# 11-nvidia-wayland.sh — liga USE=wayland no nvidia-drivers e prova que o
# caminho EGL/GBM existe ANTES de instalar o compositor.
#
# Fase: sistema JA INSTALADO E BOOTADO (regra 2). Nunca no live ISO, nunca no
# chroot da instalacao — require_booted_system() recusa, fail-closed.
#
# ESTA E A ETAPA QUE DECIDE SE O DESKTOP SOBE. As duas frentes de pesquisa
# (nvidia-wayland e stack-desktop) convergiram no mesmo achado:
#
#   O USE flag 'wayland' do x11-drivers/nvidia-drivers NAO e default-on
#   (IUSE="+X abi_x86_32 abi_x86_64 persistenced powerd +static-libs +tools
#   wayland" — repare que 'wayland' nao tem o '+'), e o instalador base NAO o
#   liga em lugar nenhum: package.use/nvidia-drivers do 04-kernel.sh contem
#   apenas '-tools' (mais 'kernel-open' no ramo 580) e 'media-libs/libglvnd X'.
#
# Sem esse flag o Portage nao puxa gui-libs/egl-gbm nem gui-libs/egl-wayland, e
# NENHUM compositor Wayland inicia na NVIDIA. O modo de falha e cruel e e a
# razao desta etapa vir ANTES do 12-niri-stack: o driver compila normalmente,
# instala sem erro e so quebra em runtime, com tela preta silenciosa. Descobrir
# isso depois de compilar o niri inteiro custa a noite.
#
# ORDEM DAS SUB-ETAPAS (cada uma existe porque a seguinte depende dela):
#   11-nvidia-branch-probe : descobre o ramo (580 vs >=595) e GRAVA o resultado
#   11-nvidia-use-wayland  : escreve o USE flag em arquivo PROPRIO
#   11-nvidia-rebuild      : reconstroi o driver com o flag novo
#   11-egl-libs-check      : PROVA que as libs EGL apareceram
#   11-modeset-check       : PROVA que o KMS esta ativo (bifurca por ramo)
#
# O QUE ESTE SCRIPT DELIBERADAMENTE NAO FAZ:
#   - nao toca em NENHUM arquivo do instalador (regra 1)
#   - nao reescreve /etc/portage/package.use/nvidia-drivers (territorio do 04)
#   - nao sobrescreve /etc/modprobe.d/nvidia.conf (propriedade do Portage)
#   - nao exporta GBM_BACKEND nem __GLX_VENDOR_LIBRARY_NAME (folclore obsoleto)
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

init_logging_desktop 11-nvidia-wayland
# Repetida aqui, e nao so no install-desktop.sh, porque os scripts do projeto
# rodam standalone para debug — mesmo padrao do require_phase nos 00-06.
require_booted_system
require_root

# Arquivo de USE que PERTENCE a este modulo. O nome comeca com "desktop-" para
# deixar obvio, num `ls /etc/portage/package.use/`, quem o escreveu.
NVIDIA_USE_FILE="/etc/portage/package.use/desktop-nvidia-wayland"

# ---------------------------------------------------------------------------
# Helpers locais (somente leitura — usados pelos probes)
# ---------------------------------------------------------------------------

# nvidia_installed_use: imprime o conteudo do arquivo USE do pacote nvidia-drivers
# INSTALADO, lido direto do VDB do Portage.
#
# POR QUE O VDB E NAO `equery uses`: o /var/db/pkg/<cat>/<pkg>/USE e gravado pelo
# Portage no momento do merge e registra exatamente com que flags o pacote que
# esta em disco FOI CONSTRUIDO. E a autoridade real. `equery uses` exige
# app-portage/gentoolkit, que o instalador base nao instala — depender dele aqui
# transformaria um probe em erro de "comando nao encontrado".
#
# Diferenca que importa para a idempotencia: o package.use diz o que voce PEDIU;
# o VDB diz o que voce TEM. O probe desta etapa precisa do segundo, senao ele
# reportaria "feito" assim que o arquivo fosse escrito, ANTES do rebuild.
nvidia_installed_use() {
    local d
    for d in /var/db/pkg/x11-drivers/nvidia-drivers-[0-9]*; do
        [[ -d "$d" && -f "$d/USE" ]] || continue
        cat "$d/USE"
        return 0
    done
    return 1
}

# nvidia_has_wayland: 0 se o driver INSTALADO foi construido com USE=wayland.
#
# Este e o probe funcional central da etapa, compartilhado por 11-nvidia-use-wayland
# e 11-nvidia-rebuild. Escrever o package.use nao muda o VDB: so o rebuild muda.
# Por isso as duas sub-etapas so ficam "feitas" depois que o driver em disco
# realmente tem o flag — que e a condicao que o desktop precisa.
#
# grep -qw: 'wayland' tem de aparecer como PALAVRA inteira. Sem o -w, um flag
# hipotetico como "wayland-foo" daria falso positivo.
nvidia_has_wayland() {
    local use
    use="$(nvidia_installed_use)" || return 1
    printf '%s' "$use" | grep -qw wayland
}

# egl_json_present: 0 se ha pelo menos um arquivo de configuracao de EGL
# external platform instalado.
#
# E o teste de PONTA do caminho EGL: nao basta o pacote estar no VDB, o arquivo
# JSON precisa existir em disco, porque e ele que o libglvnd le em runtime para
# descobrir a plataforma externa (o 15_nvidia_gbm.json e afins). Um pacote
# instalado sem o JSON significaria merge incompleto.
egl_json_present() {
    compgen -G '/usr/share/egl/egl_external_platform.d/*.json' > /dev/null
}

# modeset_active: 0 se o nvidia_drm esta com modesetting LIGADO.
#
# PROBE SOBRE O SISTEMA REAL, exatamente o que a arquitetura do projeto pede: le
# o parametro efetivo do modulo carregado em /sys, em vez de inferir a partir de
# arquivo de configuracao. Config diz intencao; /sys diz o que de fato aconteceu.
#
# Retorna 1 tambem quando o modulo nao esta carregado (o arquivo nao existe) —
# que e o caso correto de "nao provado", coerente com o fail-closed do modulo.
modeset_active() {
    local f=/sys/module/nvidia_drm/parameters/modeset
    [[ -r "$f" ]] || return 1
    [[ "$(cat "$f" 2>/dev/null)" == "Y" ]]
}

# ---------------------------------------------------------------------------
# 11-nvidia-branch-probe — descobre o ramo do driver e REGISTRA
# ---------------------------------------------------------------------------
#
# Nao e cosmetico: TODA a logica seguinte bifurca aqui, e a pesquisa nao
# conseguiu confirmar qual ramo o 04-kernel.sh resolveu nesta maquina. As
# diferencas sao grandes e mutuamente incompativeis:
#
#   580 LTS : USE=kernel-open ainda existe e e obrigatorio para Blackwell;
#             nvidia.conf traz 'options nvidia-drm modeset=1'; NAO depende de
#             gui-libs/egl-wayland2.
#   >=595   : USE=kernel-open FOI REMOVIDO (declara-lo quebra o emerge);
#             modeset=1 virou default do driver e a linha foi REMOVIDA do
#             nvidia.conf; depende de egl-wayland E egl-wayland2 juntos.
#
# O modulo DESCOBRE em vez de assumir. O marker guarda a versao completa para
# que o diagnostico posterior (e o 15-validate) saiba contra o que validar.
probe_branch() {
    # Autoridade: o driver tem de estar instalado e o ramo tem de ser
    # determinavel AGORA. O marker sozinho nao vale — se o usuario atualizou o
    # driver de 580 para 595 entre execucoes, o valor gravado ficou obsoleto e a
    # etapa precisa rodar de novo para regravar.
    local branch recorded
    branch="$(nvidia_branch)" || return 1
    recorded="$(step_value 11-nvidia-branch)"
    [[ -n "$recorded" && "$recorded" == "$branch" ]]
}

do_branch() {
    pkg_installed x11-drivers/nvidia-drivers \
        || die "x11-drivers/nvidia-drivers NAO esta instalado neste sistema. Esta etapa pressupoe o instalador base concluido (o 04-kernel.sh instala o driver). Verifique com: qlist -I x11-drivers/nvidia-drivers"

    local branch ver
    branch="$(nvidia_branch)" \
        || die "nao foi possivel determinar o ramo do nvidia-drivers. Verifique a saida de: portageq best_version / x11-drivers/nvidia-drivers"

    ver="$(portageq best_version / x11-drivers/nvidia-drivers 2>/dev/null || true)"
    log_info "nvidia-drivers instalado: ${ver:-desconhecido} — ramo resolvido: $branch"

    case "$branch" in
        580)
            log_info "ramo 580 LTS: o USE kernel-open existe (e o 04 ja o ligou, obrigatorio para Blackwell); egl-wayland2 NAO se aplica; nvidia.conf poe modeset=1 via modprobe"
            ;;
        595+)
            log_info "ramo >=595: o USE kernel-open NAO existe mais (modulos abertos sempre usados — correto para Blackwell/GB206); egl-wayland2 se aplica; modeset=1 e default do driver"
            ;;
    esac

    # Grava o RAMO no marker que o probe compara, e a versao completa em marker
    # separado (informativo, para o 15-validate e para o diagnostico humano).
    mark_done 11-nvidia-branch "$branch"
    mark_done 11-nvidia-version "${ver:-desconhecido}"
}

# Sob --dry-run paramos AQUI, ANTES do primeiro run_step. Tudo acima e leitura
# (helpers de probe e o caminho do package.use); a primeira gravacao vem do
# do_branch logo abaixo, que ja grava marker de estado. Parar antes tambem evita
# a bifurcacao seguinte, que LE esse marker recem-escrito.
dry_run_guard 11-nvidia-branch-probe 11-nvidia-use-wayland 11-nvidia-rebuild \
              11-egl-libs-check 11-modeset-check

run_step 11-nvidia-branch-probe probe_branch do_branch

# Ramo resolvido, disponivel para as sub-etapas seguintes.
NVIDIA_BRANCH="$(step_value 11-nvidia-branch)"

# ---------------------------------------------------------------------------
# 11-nvidia-use-wayland — A CORRECAO CENTRAL DO PROJETO
# ---------------------------------------------------------------------------
#
# POR QUE ARQUIVO SEPARADO, e nao editar package.use/nvidia-drivers:
#
# Aquele arquivo e TERRITORIO DO 04-kernel.sh, que o reescreve INTEIRO (cat >)
# com conteudo DIFERENTE conforme o ramo — com kernel-open no 580, sem no >=595.
# Se este modulo o reescrevesse com um template fixo, quebraria o instalador
# validado na proxima execucao dele (regra 1). Como o Portage faz a UNIAO de
# todos os arquivos de /etc/portage/package.use/, uma linha em arquivo proprio
# tem exatamente o mesmo efeito, sem colisao de dono.
#
# GUARDA CRITICA — o arquivo NAO pode conter a string kernel-open fora de
# comentario: o 04-kernel.sh (linhas 626-632) varre TODO o /etc/portage/package.use/
# procurando esse flag quando o ramo e >=595, e ABORTA a instalacao se o achar.
# Verifiquei o regex do 04 contra o conteudo que este script escreve: ele ignora
# linhas iniciadas por '#', entao mencionar o assunto em comentario e seguro —
# mas a linha de USE efetiva declara SOMENTE 'wayland', e nada mais.
probe_use_wayland() {
    # PROBE FUNCIONAL sobre o pacote REAL: o driver instalado tem o flag?
    # Deliberadamente NAO testamos a existencia do arquivo de config: arquivo
    # escrito e intencao, nao resultado. Testar o arquivo faria a etapa se
    # declarar concluida sem que o driver tivesse sido reconstruido.
    nvidia_has_wayland
}

do_use_wayland() {
    # Regra 3: nunca escrever em package.use sem antes perguntar ao ebuild se o
    # flag existe. Um flag inexistente faz o Portage recusar o emerge — e foi
    # exatamente esse o desastre do kernel-open no ramo >=595.
    require_use_flag x11-drivers/nvidia-drivers wayland

    # A linha de USE efetiva e uma so. Todo o resto e comentario explicando o
    # porque para o proximo leitor, no estilo do instalador.
    write_managed_file "$NVIDIA_USE_FILE" \
'# USE=wayland no driver NVIDIA — o delta obrigatorio para o desktop Wayland.
#
# Este flag NAO e default-on no ebuild e o instalador base nao o liga em lugar
# nenhum. Sem ele o Portage nao puxa gui-libs/egl-gbm nem gui-libs/egl-wayland
# (categoria gui-libs, NAO media-libs), e nenhum compositor Wayland inicia:
# o driver compila normal e so falha em runtime, com tela preta.
#
# Arquivo SEPARADO de proposito: package.use/nvidia-drivers pertence ao
# 04-kernel.sh, que o reescreve inteiro e com conteudo diferente por ramo.
# O Portage faz a uniao dos arquivos deste diretorio, entao a linha abaixo
# se soma ao que o 04 declarou, sem conflito de dono.
#
# NAO acrescente aqui o flag de modulo aberto do ramo 580: o 04-kernel.sh varre
# este diretorio e aborta a instalacao se encontrar aquele flag num sistema com
# driver >=595, onde ele deixou de existir. Aquele assunto e do 04, nao deste
# modulo.
x11-drivers/nvidia-drivers wayland' \
        11-nvidia-wayland.sh

    # Auto-verificacao: confirma que o arquivo que acabamos de escrever nao
    # dispara a varredura do 04. Barato, e protege contra alguem editar o texto
    # acima no futuro e introduzir o token numa linha efetiva sem perceber.
    if grep -vE '^[[:space:]]*#' "$NVIDIA_USE_FILE" \
       | grep -qE '(^|[[:space:]])-?kernel-open([[:space:]]|$)'; then
        die "BUG NESTE SCRIPT: '$NVIDIA_USE_FILE' contem o flag de modulo aberto numa linha efetiva. Isso faria o 04-kernel.sh abortar a instalacao no ramo >=595. Remova o flag daquela linha."
    fi

    log_info "USE=wayland declarado em '$NVIDIA_USE_FILE' — o driver ainda precisa ser RECONSTRUIDO para o flag valer (proxima sub-etapa)"
}

# NOTA SOBRE O CONTRATO DO run_step: probe_use_wayland so retorna 0 quando o
# driver INSTALADO tem o flag, e do_use_wayland apenas escreve o arquivo. Se
# esta sub-etapa rodasse sozinha, o run_step morreria em "do_fn terminou mas o
# probe ainda reporta nao-feito" — corretamente, porque escrever o arquivo NAO
# resolve o problema. Por isso a escrita e o rebuild sao UMA sub-etapa do ponto
# de vista do run_step: do_use_wayland escreve E o rebuild acontece em seguida,
# dentro da mesma funcao do_fn. Ver do_nvidia_wayland abaixo.

# ---------------------------------------------------------------------------
# 11-nvidia-rebuild — reconstroi o driver com o flag novo
# ---------------------------------------------------------------------------
#
# --changed-use e o argumento correto: reconstroi apenas se o conjunto de USE
# efetivo mudou em relacao ao que esta no VDB. Se o driver ja tiver wayland (por
# exemplo porque o 10a trocou o perfil para 23.0/desktop, que liga wayland
# globalmente), este emerge vira no-op — que e a idempotencia que a arquitetura
# pede. Diferenca importante para --newuse: o --changed-use ignora mudanca em
# flags que nao afetam o pacote, evitando rebuild inutil.
#
# --oneshot: NAO acrescenta o driver ao @world. Ele ja esta la (o 04 o instalou);
# registrar de novo poluiria o world file sem beneficio.
do_nvidia_rebuild() {
    # Recompilar o driver NVIDIA nao e rapido, e este modulo roda no sistema real
    # do usuario. Acao cara pede consentimento explicito (DESKTOP_ASSUME_YES=yes
    # pula, para automacao).
    if ! confirm_expensive \
        "reconstruir x11-drivers/nvidia-drivers com USE=wayland" \
"O driver NVIDIA sera RECOMPILADO para ganhar o backend Wayland (USE=wayland).

Por que e obrigatorio: sem esse flag nao existem gui-libs/egl-gbm e
gui-libs/egl-wayland, e o compositor nao consegue criar o EGLDisplay via GBM.
O sintoma, se voce pular esta etapa, e tela preta no primeiro boot grafico —
sem erro no emerge, porque o driver compila normalmente de qualquer jeito.

Nada e removido: o driver e reconstruido no lugar, com a mesma versao." \
        --changed-use --oneshot x11-drivers/nvidia-drivers
    then
        die "rebuild do nvidia-drivers RECUSADO pelo usuario. Sem USE=wayland o compositor nao inicia — as etapas 12 em diante nao fazem sentido neste estado. Re-execute este script quando puder recompilar o driver."
    fi

    log_info "reconstruindo x11-drivers/nvidia-drivers com --changed-use (isto leva tempo)"
    emerge --changed-use --oneshot x11-drivers/nvidia-drivers \
        || die "o emerge do nvidia-drivers FALHOU. Veja o log completo em $LOGFILE. Causas comuns: (1) as fontes do kernel em /usr/src/linux nao correspondem ao kernel em execucao — o modulo e compilado contra elas; (2) espaco em disco; (3) o CONFIG_CHECK do ebuild reprovou algum simbolo do kernel."

    # PROVA pos-emerge: o VDB tem de refletir o flag. Se o emerge foi no-op por
    # algum motivo inesperado, e melhor descobrir aqui, com mensagem clara, do
    # que na tela preta depois do reboot.
    nvidia_has_wayland \
        || die "o emerge terminou, mas o nvidia-drivers no VDB continua SEM o USE=wayland. Verifique se algum outro arquivo em /etc/portage/package.use/ desliga o flag explicitamente (procure por '-wayland') e confira o USE efetivo com: emerge -pv x11-drivers/nvidia-drivers"
}

# do_fn combinada: escreve o package.use E reconstroi. As duas coisas juntas sao
# o que satisfaz o probe (driver instalado com +wayland) — separa-las faria o
# run_step falhar corretamente, porque escrever config nao muda o pacote em disco.
do_nvidia_wayland() {
    do_use_wayland
    do_nvidia_rebuild
}

run_step 11-nvidia-use-wayland probe_use_wayland do_nvidia_wayland

# Sub-etapa nominal do plano, mantida como PONTO DE VERIFICACAO independente.
# Depois do passo anterior o probe ja deve estar satisfeito; se nao estiver, o
# run_step re-executa (e o emerge --changed-use sera no-op se nada mudou).
run_step 11-nvidia-rebuild probe_use_wayland do_nvidia_wayland

# ---------------------------------------------------------------------------
# 11-egl-libs-check — PROVA que o caminho EGL/GBM existe
# ---------------------------------------------------------------------------
#
# DECISAO DELIBERADA: esta etapa NAO instala os atoms a mao, so VERIFICA.
#
# Dois motivos concretos. Primeiro, a categoria correta e gui-libs — NAO
# media-libs; 'media-libs/egl-wayland' nao existe e um emerge com esse atom
# falha na hora (erro comum, documentado na pesquisa). Segundo, e mais
# importante: o CONJUNTO muda por ramo — no >=595 sao TRES pacotes (egl-gbm,
# egl-wayland e egl-wayland2, porque a NVIDIA hoje entrega as duas versoes da
# lib), enquanto no 580 sao dois. Listar a mao erraria em um dos ramos.
#
# O jeito certo e deixar o RDEPEND de USE=wayland resolver e aqui apenas provar
# que resolveu. Se faltar alguma, o problema NAO e "falta instalar" — e que o
# rebuild nao surtiu efeito, e instalar o atom a mao mascararia a causa raiz.
probe_egl_libs() {
    pkg_installed gui-libs/egl-gbm || return 1
    pkg_installed gui-libs/egl-wayland || return 1
    # egl-wayland2 SO existe como dependencia no ramo >=595. Exigi-lo no 580
    # seria um falso negativo permanente.
    if [[ "$NVIDIA_BRANCH" == "595+" ]]; then
        pkg_installed gui-libs/egl-wayland2 || return 1
    fi
    egl_json_present
}

do_egl_libs() {
    # Chegar aqui significa que o driver TEM USE=wayland (as sub-etapas
    # anteriores provaram isso no VDB) mas as libs EGL nao apareceram. Isso e
    # inconsistencia de arvore, nao "falta um emerge" — por isso a mensagem
    # diagnostica em vez de instalar cegamente.
    local faltando=()
    pkg_installed gui-libs/egl-gbm || faltando+=("gui-libs/egl-gbm")
    pkg_installed gui-libs/egl-wayland || faltando+=("gui-libs/egl-wayland")
    if [[ "$NVIDIA_BRANCH" == "595+" ]]; then
        pkg_installed gui-libs/egl-wayland2 || faltando+=("gui-libs/egl-wayland2")
    fi

    if (( ${#faltando[@]} > 0 )); then
        # Distingue os dois diagnosticos possiveis, que pedem acoes DIFERENTES:
        # o atom nao existe/nao esta visivel na arvore (problema de repositorio ou
        # de keyword) versus o atom existe mas nao foi instalado (o RDEPEND do
        # USE=wayland nao foi puxado). A pesquisa nao confirmou individualmente a
        # visibilidade de todos estes pacotes, entao o modulo mede em runtime em
        # vez de supor — regra 3.
        local p best
        for p in "${faltando[@]}"; do
            if best="$(have_atom "$p")"; then
                log_error "dependencia EGL NAO INSTALADA: $p (existe e esta visivel na arvore como $best)"
            else
                log_error "dependencia EGL NAO VISIVEL para o Portage: $p (o atom nao resolve — repositorio ausente, keyword faltando ou nome incorreto)"
            fi
        done
        die "o nvidia-drivers esta instalado COM USE=wayland, mas as bibliotecas EGL acima nao foram puxadas — o rebuild nao surtiu o efeito esperado. Elas sao RDEPEND do flag wayland e deveriam vir sozinhas. Diagnostico, nesta ordem: (1) confira o USE efetivo com 'emerge -pv x11-drivers/nvidia-drivers'; (2) veja se algo em /etc/portage/ mascara os pacotes ('emerge -pv gui-libs/egl-gbm'); (3) ATENCAO a categoria — e gui-libs, nunca media-libs. Nao instale os atoms a mao sem entender o motivo: o conjunto correto muda entre o ramo 580 e o >=595."
    fi

    # Pacotes presentes mas sem os JSON: merge incompleto do proprio driver.
    egl_json_present \
        || die "os pacotes EGL estao instalados, mas /usr/share/egl/egl_external_platform.d/ nao tem nenhum arquivo .json. Esse diretorio e o que o libglvnd le em runtime para achar a plataforma externa da NVIDIA; vazio, o compositor nao encontra o backend. Tente reinstalar o driver: emerge --oneshot x11-drivers/nvidia-drivers"
}

run_step 11-egl-libs-check probe_egl_libs do_egl_libs

# Relatorio informativo: mostra o que de fato existe, para o log de diagnostico.
if egl_json_present; then
    log_info "arquivos de EGL external platform encontrados:"
    for _json in /usr/share/egl/egl_external_platform.d/*.json; do
        log_info "    $_json"
    done
fi

# ---------------------------------------------------------------------------
# 11-modeset-check — PROVA que o KMS esta ativo
# ---------------------------------------------------------------------------
#
# Modesetting DRM e pre-requisito absoluto de qualquer compositor Wayland na
# NVIDIA. O probe le /sys/module/nvidia_drm/parameters/modeset — o estado REAL do
# modulo carregado — em vez de inspecionar arquivo de configuracao.
#
# Bifurcacao por ramo, e aqui esta uma correcao de folclore que a pesquisa
# desfez: em >=595 a NVIDIA passou a habilitar modeset=1 POR DEFAULT e o ebuild
# REMOVEU a linha do nvidia.conf de proposito. Copiar 'nvidia-drm.modeset=1'
# para a cmdline nesse ramo e ruido, nao correcao. No 580 o proprio nvidia.conf
# do ebuild ja poe 'options nvidia-drm modeset=1' via modprobe, entao mesmo la o
# parametro de cmdline normalmente e redundante — so entra se o probe FALHAR.
probe_modeset() {
    modeset_active
}

do_modeset() {
    # Caso 1: o modulo nem esta carregado. Nao ha o que corrigir por config —
    # e um problema anterior (driver nao carregou), e mexer no GRUB nao ajuda.
    if [[ ! -e /sys/module/nvidia_drm/parameters/modeset ]]; then
        if [[ "$NVIDIA_BRANCH" == "595+" ]]; then
            die "o modulo nvidia_drm NAO esta carregado (/sys/module/nvidia_drm/ nao existe), entao nao da para provar que o KMS esta ativo. No ramo >=595 o modeset ja e default do driver, e a causa quase certa e o modulo nao ter sido carregado neste boot. Verifique: 'lsmod | grep nvidia' e 'dmesg | grep -i nvidia'. Este kernel e SEM initramfs, entao o nvidia_drm carrega tarde — se o driver acabou de ser reconstruido, REINICIE e rode este script de novo."
        fi
        die "o modulo nvidia_drm NAO esta carregado (/sys/module/nvidia_drm/ nao existe). Como o driver foi reconstruido agora, o modulo em memoria pode ser o antigo. REINICIE e re-execute este script; se depois do reboot continuar ausente, veja 'dmesg | grep -i nvidia'."
    fi

    # Caso 2: modulo carregado, porem com modeset=N.
    if [[ "$NVIDIA_BRANCH" == "595+" ]]; then
        # Nao escrevemos nada: no >=595 o default e Y, e um N aqui significa que
        # ALGUEM desligou explicitamente. Escrever na cmdline por cima
        # esconderia a causa real em vez de corrigi-la.
        die "nvidia_drm esta carregado com modeset=N, mas no ramo >=595 o default do driver e Y — ou seja, algo DESLIGOU o modesetting explicitamente. Procure por 'nvidia-drm.modeset=0' ou 'nvidia_drm.modeset=0' em /etc/default/grub e por 'options nvidia-drm modeset=0' em /etc/modprobe.d/*.conf, remova a ocorrencia e reinicie. NAO acrescente o parametro na cmdline por cima: isso mascararia a causa."
    fi

    # Ramo 580: o nvidia.conf do ebuild ja deveria ter posto modeset=1 via
    # modprobe. Se ainda assim o probe falhou, a cmdline do kernel e o caminho
    # confiavel — especialmente aqui, num kernel SEM initramfs.
    log_warn "ramo 580: nvidia_drm carregado com modeset=N apesar do nvidia.conf do ebuild — acrescentando o parametro na linha de comando do kernel"

    local grub_default=/etc/default/grub
    [[ -f "$grub_default" ]] \
        || die "'$grub_default' nao existe — o 05-bootloader.sh deveria te-lo criado. Sem ele nao da para acrescentar o parametro de forma idempotente."

    # IDEMPOTENCIA — e aqui esta a sutileza que exige edicao no LUGAR em vez de
    # simplesmente acrescentar uma linha ao arquivo:
    #
    # o 05-bootloader.sh escreve UMA linha 'GRUB_CMDLINE_LINUX="intel_iommu=on"'.
    # O /etc/default/grub e SOURCEADO como shell pelo grub-mkconfig, entao uma
    # segunda linha 'GRUB_CMDLINE_LINUX=...' nao se soma a primeira: ela a
    # SOBRESCREVE, e o intel_iommu=on do instalador seria silenciosamente
    # perdido. Por isso injetamos o parametro DENTRO do valor ja existente.
    if grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX=.*nvidia[-_]drm\.modeset=1' "$grub_default"; then
        log_info "'$grub_default' ja contem nvidia-drm.modeset=1 — nada a fazer"
    else
        grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX=' "$grub_default" \
            || die "'$grub_default' nao tem nenhuma linha GRUB_CMDLINE_LINUX= para editar. Arquivo inesperado: revise-o a mao antes de continuar."

        cp -a "$grub_default" "$grub_default.bak-desktop" \
            || die "nao foi possivel criar a copia de seguranca '$grub_default.bak-desktop'."
        log_info "copia de seguranca criada: $grub_default.bak-desktop"

        # Acrescenta o parametro ANTES da aspa final, preservando o conteudo.
        sed -i -E 's|^([[:space:]]*GRUB_CMDLINE_LINUX="[^"]*)"|\1 nvidia-drm.modeset=1"|' "$grub_default" \
            || die "falha ao editar '$grub_default'."

        grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX=.*nvidia-drm\.modeset=1' "$grub_default" \
            || die "a edicao de '$grub_default' nao surtiu efeito — o formato do arquivo nao e o esperado. A copia original esta em '$grub_default.bak-desktop'; ajuste a mao acrescentando nvidia-drm.modeset=1 ao GRUB_CMDLINE_LINUX."

        log_info "nvidia-drm.modeset=1 acrescentado ao GRUB_CMDLINE_LINUX (intel_iommu=on preservado)"
    fi

    # Regera o grub.cfg para o parametro valer no proximo boot.
    command -v grub-mkconfig > /dev/null 2>&1 \
        || die "grub-mkconfig nao encontrado, mas /etc/default/grub foi editado. Instale sys-boot/grub ou regere o grub.cfg a mao."
    grub-mkconfig -o /boot/grub/grub.cfg \
        || die "grub-mkconfig FALHOU depois de editar '$grub_default'. O sistema ainda tem o grub.cfg antigo (bootavel). Veja $LOGFILE."
    log_info "/boot/grub/grub.cfg regerado"

    # O parametro so passa a valer no PROXIMO boot: o modulo ja esta carregado
    # com modeset=N agora. Portanto o probe continuaria falhando, e o run_step
    # mataria o script com "do_fn terminou mas o probe ainda reporta nao-feito".
    # Encerramos aqui com instrucao explicita, que e a mensagem acionavel certa.
    die "nvidia-drm.modeset=1 foi configurado no GRUB, mas so tera efeito APOS REINICIAR (o modulo ja esta em memoria com modeset=N). REINICIE agora e execute este script novamente para que a verificacao passe."
}

run_step 11-modeset-check probe_modeset do_modeset

# ---------------------------------------------------------------------------
# Relatorio final e ESCAPE HATCH
# ---------------------------------------------------------------------------

log_info "==== 11-nvidia-wayland concluido com sucesso ===="
log_info "ramo do driver: $NVIDIA_BRANCH | versao: $(step_value 11-nvidia-version)"
log_info "nvidia-drivers com USE=wayland: OK | libs EGL/GBM: OK | nvidia_drm modeset: Y"

# O escape hatch e IMPRESSO, nunca aplicado automaticamente. Motivo: fbdev=0 e um
# botao de escape, nao uma melhoria — aplica-lo preventivamente trocaria um
# problema possivel por outro certo, e envenenaria o diagnostico.
#
# Este e o risco nao-validado numero um do projeto: kernel SEM initramfs +
# DRM_SIMPLEDRM + Blackwell (modulo aberto). O nvidia-drm carrega tarde, e a
# janela de handoff simpledrm -> nvidia-drm fica exposta. O default do ebuild e
# fbdev LIGADO, com a nvidia assumindo o console; o proprio comentario do
# nvidia.conf reconhece que isso pode causar problema de tty/resume em alguns
# setups. O usuario precisa ter a saida NA MAO antes de reiniciar.
cat <<'ESCAPE'

========================================================================
  ANTES DE REINICIAR — GUARDE ESTA INSTRUCAO
========================================================================
Se apos o reboot voce cair em TELA PRETA, ou se o console parar de trocar
de TTY (Ctrl+Alt+F1..F6), o suspeito numero um e o handoff do framebuffer:
este kernel nao tem initramfs, usa DRM_SIMPLEDRM no console, e o modulo
nvidia-drm carrega tarde assumindo o framebuffer por cima do simpledrm.

CORRECAO (a partir de um TTY ou de um live ISO, com o sistema montado):

  1. Edite /etc/modprobe.d/nvidia.conf
  2. Encontre a linha JA EXISTENTE, comentada:
         #options nvidia-drm fbdev=0
  3. DESCOMENTE-A (remova apenas o '#') e reinicie.

Por que mexer nesse arquivo e seguro APENAS assim: /etc/modprobe.d/nvidia.conf
pertence ao gerenciador de pacotes (vem do ebuild) e contem opcoes que este
modulo NAO pode perder — no ramo >=595, NVreg_UseKernelSuspendNotifiers=1, cuja
ausencia quebra suspend/resume. Descomentar uma linha preserva o resto; um
arquivo reescrito por cima, nao. Se precisar de outros ajustes, crie um arquivo
novo /etc/modprobe.d/zz-nvidia-desktop.conf, que e lido DEPOIS.

NAO exporte GBM_BACKEND nem __GLX_VENDOR_LIBRARY_NAME "por seguranca": em
driver moderno sao desnecessarios, e ha relato de __GLX_VENDOR_LIBRARY_NAME=nvidia
IMPEDIR o login em sessao Wayland. Teste primeiro sem variavel nenhuma.
========================================================================

ESCAPE
