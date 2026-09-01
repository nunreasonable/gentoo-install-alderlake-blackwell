#!/usr/bin/env bash
# 10a-profile-world.sh — troca do perfil para 23.0/desktop + emerge -uDN @world.
#
# ETAPA OPT-IN E ISOLADA. Nao roda por padrao: o install-desktop.sh so a insere
# na sequencia com --with-profile-world (ou quando DESKTOP_SWITCH_PROFILE=yes /
# DESKTOP_UPDATE_WORLD=yes). Rodar standalone tambem funciona: ./10a-profile-world.sh
#
# POR QUE ESTE SCRIPT EXISTE SEPARADO DA ETAPA 10
# -----------------------------------------------
# Trocar o perfil e rodar `emerge -uDN @world` sao as DUAS acoes de maior risco e
# maior duracao do modulo inteiro: elas mexem no sistema JA VALIDADO pelo
# instalador base e levam horas. Enterra-las dentro da etapa 10 faria com que
# rodar o modulo "para instalar o niri" disparasse uma recompilacao geral do
# sistema sem o usuario jamais ter pedido isso. Por isso vivem num arquivo
# proprio, DESLIGADAS por default, cada uma atras de uma confirmacao que mostra
# o custo MEDIDO antes de perguntar.
#
# TRADE-OFF (a decisao e do usuario; o script so a torna informada)
# ----------------------------------------------------------------
# A FAVOR de trocar o perfil:
#   O perfil default/linux/amd64/23.0/desktop herda targets/desktop, cujo
#   make.defaults ja entrega globalmente: wayland, X, elogind, dbus, policykit,
#   pipewire, screencast, vulkan, opengl, dri, sound, udev, upower — ou seja,
#   praticamente todo o conjunto minimo que este modulo precisaria escrever a
#   mao em package.use. O wiki do Gentoo e categorico: perfis desktop "are to be
#   used for any graphical installation, whether using a desktop environment,
#   window manager, xorg, wayland", e nao usa-los "will lead to a heavy setup and
#   maintenance burden and various potential issues". Reescrever esse conjunto a
#   mao no make.conf e reimplementar o perfil de forma pior e sem manutencao
#   upstream.
#   Bonus concreto para este projeto: com wayland GLOBAL, o -uDN @world ja
#   reconstroi o x11-drivers/nvidia-drivers com USE=wayland de tabela — que e
#   exatamente o ponto de falha numero um do modulo (a flag NAO e default-on e o
#   instalador base nao a liga em lugar nenhum).
#
# CONTRA:
#   Dispara um rebuild grande num sistema que foi validado como esta. E voltar
#   atras NAO e de graca: reverter o perfil exige outro `emerge -uDN @world`
#   completo. O wiki recomenda backup antes de mudancas de sistema, e este
#   script avisa isso em voz alta antes de qualquer acao.
#
# DECISAO: opt-in, com o custo REAL medido e exibido antes de confirmar. Este
# script NUNCA estima horas — a pesquisa foi categorica de que nao existe
# estimativa publicada confiavel, e que a unica resposta honesta e rodar com
# --pretend e contar os pacotes. E o que fazemos.
#
# ORDEM: se esta etapa for usada, ela roda ANTES da 11-nvidia-wayland. Trocar
# para o perfil desktop liga USE=wayland globalmente e o @world ja reconstroi o
# driver NVIDIA; rodar a 10a DEPOIS da 11 recompilaria o driver DUAS vezes.
#
# Fase: sistema JA INSTALADO E BOOTADO (regra 2). require_booted_system() recusa
# live ISO e chroot com deteccao positiva e fail-closed.
# Idempotente: cada sub-etapa passa por run_step com probe funcional.

set -euo pipefail

# Captura do ambiente ORIGINAL, obrigatoriamente ANTES do source do
# lib-desktop.sh (que sourceia vars-desktop.sh e aplica os defaults com
# `: "${VAR:=no}"`). Depois desse source e impossivel distinguir "o usuario
# passou no" de "ninguem passou nada" — as duas viram a string "no".
# Guardamos aqui apenas a EXISTENCIA, que e o que a decisao mais abaixo precisa.
[[ -n "${DESKTOP_SWITCH_PROFILE+x}" ]] && _ENV_DESKTOP_SWITCH_PROFILE=1
[[ -n "${DESKTOP_UPDATE_WORLD+x}" ]] && _ENV_DESKTOP_UPDATE_WORLD=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib-desktop.sh e quem faz o source de ../vars.sh, ../lib.sh e vars-desktop.sh
# na ordem correta (e quem zera TARGET_ROOT antes do lib.sh, para os markers
# caírem em /var/lib/gentoo-install/state e nao em /mnt/gentoo/...).
# shellcheck source=lib-desktop.sh
source "$SCRIPT_DIR/lib-desktop.sh"

# Guarda de fase repetida aqui de proposito: os scripts deste projeto rodam
# standalone para debug, e esta guarda e a UNICA coisa que impede executar na
# fase errada — mesmo padrao do require_phase repetido em todos os 00-06.
require_booted_system
require_root
init_logging_desktop 10a-profile-world

# ---------------------------------------------------------------------------
# Constantes locais
# ---------------------------------------------------------------------------

# Perfil alvo, POR NOME EXATO — nunca por numero. A numeracao do
# `eselect profile list` muda entre snapshots do repositorio, entao numero e
# referencia instavel. Mesmo criterio do 03-chroot-setup.sh:37.
#
# Derivado de INIT_SYSTEM para nao quebrar quem instalou com systemd, exatamente
# como o instalador base deriva o TARGET_PROFILE dele.
DESKTOP_TARGET_PROFILE="default/linux/amd64/23.0/desktop"
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    # No layout 23.0 o perfil de desktop com systemd e .../23.0/desktop/systemd.
    # A existencia e verificada em runtime mais abaixo (nunca assumida).
    DESKTOP_TARGET_PROFILE="$DESKTOP_TARGET_PROFILE/systemd"
fi

# ---------------------------------------------------------------------------
# Autorizacao vinda do orquestrador (--with-profile-world)
# ---------------------------------------------------------------------------
#
# REDE DE SEGURANCA, nao o caminho normal. O caminho normal e o run_script do
# install-desktop.sh, que hoje EXPORTA DESKTOP_SWITCH_PROFILE e
# DESKTOP_UPDATE_WORLD para o filho sempre que a 10a foi pedida (por
# --with-profile-world ou por --only 10a), respeitando valor explicito do
# ambiente. Com isso este bloco nao dispara em nenhuma invocacao real vinda do
# orquestrador: as variaveis chegam preenchidas e nos as respeitamos.
#
# Ele fica porque a alternativa e pior. Se alguem um dia agendar a 10a por um
# caminho novo e esquecer o repasse, sem este bloco a 10a pularia as DUAS
# sub-etapas e o usuario acharia que trocou de perfil quando nada aconteceu —
# uma flag que nao faz nada e pior que uma flag ausente. Com ele, o modo de
# falha vira um aviso alto seguido da confirmacao interativa de sempre.
#
# O gatilho e SO DESKTOP_FROM_ORCHESTRATOR. Ja foi "ou DESKTOP_DRY_RUN", pela
# ideia de que so o run_script a exportava; mas ela tambem existe quando o
# usuario roda `DESKTOP_DRY_RUN=yes ./10a-profile-world.sh` standalone, e ai a
# inferencia disparava sem nenhum orquestrador envolvido. Inofensivo na pratica
# (o dry-run morre antes de agir, mais abaixo), porem e o motivo errado para
# chegar em "yes" — e viraria armadilha se essa ordem mudasse.
#
# ESCAPE HATCH: quem setou as variaveis explicitamente no ambiente manda, mesmo
# que o valor seja "no". Capturamos isso ANTES do source do lib-desktop.sh? Nao:
# o `: "${VAR:=default}"` do vars-desktop.sh nao distingue "veio do ambiente" de
# "veio do default". Por isso testamos as variaveis ORIGINAIS do ambiente, que o
# bash preserva com o sufixo +x apenas se elas existiam antes deste processo.
# Assim `DESKTOP_SWITCH_PROFILE=no ./install-desktop.sh --with-profile-world`
# continua significando "nao troque o perfil".
#
# Cada acao ainda passa pelo confirm_expensive antes de tocar em nada: isto NAO
# cria acao automatica, apenas evita o no-op silencioso.
_10a_autorizacao_explicita="no"
[[ -n "${_ENV_DESKTOP_SWITCH_PROFILE+x}" || -n "${_ENV_DESKTOP_UPDATE_WORLD+x}" ]] \
    && _10a_autorizacao_explicita="yes"

if [[ "$_10a_autorizacao_explicita" == "no" ]] \
    && [[ -n "${DESKTOP_FROM_ORCHESTRATOR:-}" ]] \
    && [[ "$DESKTOP_SWITCH_PROFILE" != "yes" && "$DESKTOP_UPDATE_WORLD" != "yes" ]]; then
    log_warn "esta etapa foi agendada pelo orquestrador mas as variaveis de"
    log_warn "autorizacao NAO chegaram pelo ambiente — o run_script deveria te-las"
    log_warn "exportado. Assumindo que o pedido da etapa JA e a autorizacao."
    log_warn "Isto e uma rede de seguranca, nao o caminho normal: se voce esta vendo"
    log_warn "esta mensagem, o repasse do install-desktop.sh regrediu."
    log_warn "As duas acoes seguem pedindo confirmacao interativa antes de alterar nada."
    DESKTOP_SWITCH_PROFILE="yes"
    DESKTOP_UPDATE_WORLD="yes"
fi

# Comando de atualizacao do @world usado tanto no --pretend quanto na execucao
# real. Uma unica definicao para que a contagem MEDIDA e o que roda de verdade
# nao possam divergir — se fossem duas listas separadas, o numero mostrado ao
# usuario poderia nao corresponder ao que sera compilado.
#
# --keep-going: num @world grande, um unico pacote quebrado nao deve abortar
# horas de trabalho ja feito; o que falhou e reportado no fim.
WORLD_UPDATE_ARGS=(--update --deep --newuse @world)
WORLD_EMERGE_ARGS=("${WORLD_UPDATE_ARGS[@]}" --keep-going)

# ---------------------------------------------------------------------------
# Aviso obrigatorio de backup
# ---------------------------------------------------------------------------
#
# Exibido ANTES de qualquer acao e independente de qual sub-etapa vai rodar.
# O wiki do Gentoo recomenda explicitamente que sistemas sejam copiados antes de
# mudancas de sistema ("systems should be regularly backed up - particularly
# before system changes"), e trocar de perfil e o exemplo canonico disso.
aviso_backup() {
    log_warn "===================================================================="
    log_warn "ETAPA 10a — ACOES DE ALTO RISCO E LONGA DURACAO"
    log_warn "===================================================================="
    log_warn "Esta etapa pode trocar o perfil do Portage e reconstruir grande parte"
    log_warn "do sistema (emerge -uDN @world). Ela mexe num sistema que ja foi"
    log_warn "validado pelo instalador base."
    log_warn ""
    log_warn "FACA BACKUP ANTES. O wiki do Gentoo recomenda backup particularmente"
    log_warn "antes de mudancas de sistema. Reverter a troca de perfil NAO e de"
    log_warn "graca: exige outro 'emerge -uDN @world' completo."
    log_warn ""
    log_warn "Nenhuma estimativa de duracao sera dada — nao existe estimativa"
    log_warn "confiavel. O script mede e mostra a contagem REAL de pacotes antes de"
    log_warn "pedir sua confirmacao."
    log_warn "===================================================================="
}

aviso_backup

# ---------------------------------------------------------------------------
# Helpers locais
# ---------------------------------------------------------------------------

# perfil_existe <nome>: 0 se o perfil e oferecido pelo eselect nesta arvore.
#
# REGRA 3 (nunca inventar): a existencia do perfil .../23.0/desktop (e sobretudo
# do .../23.0/desktop/systemd) e verificada contra a arvore REAL antes de
# qualquer tentativa de set. Um `eselect profile set` com nome inexistente falha
# de forma pouco clara; falhar aqui rende mensagem acionavel.
#
# Compara por linha exata apos remover a numeracao e os marcadores de selecao do
# eselect ("[12] default/... *"), porque a coluna de numero e decorativa.
perfil_existe() {
    local alvo="$1"
    eselect profile list 2>/dev/null \
        | sed 's/^[[:space:]]*\[[0-9]*\][[:space:]]*//; s/[[:space:]]*\*[[:space:]]*$//' \
        | grep -qx -- "$alvo"
}

# contar_pacotes_world: imprime quantos pacotes um `-uDN @world` instalaria ou
# reconstruiria AGORA. Retorna !=0 se o calculo nao pode ser feito.
#
# POR QUE NAO USAMOS emerge_pretend_count() DO lib-desktop.sh AQUI:
# aquele helper roda `emerge --pretend --quiet`, e o --quiet SUPRIME justamente
# as linhas "[ebuild ...]" que ele proprio tenta contar com grep — a contagem
# viria 0 em vez de falhar, e um 0 falso e pior que erro nenhum, porque
# convenceria o usuario de que nao ha nada a fazer. Aqui chamamos o emerge SEM
# --quiet e contamos as linhas de pacote de verdade.
#
# --pretend nao instala nada (seguro sob a regra 5: este script so calcula).
# --columns estabiliza o formato das linhas de pacote entre versoes do Portage.
contar_pacotes_world() {
    local saida
    # O emerge pode sair !=0 em @world com conflito de slot mesmo produzindo
    # saida util; guardamos a saida e decidimos pelo conteudo, nao pelo status.
    saida="$(emerge --pretend --columns "${WORLD_UPDATE_ARGS[@]}" 2>&1)" || true
    [[ -n "$saida" ]] || return 1
    # Linhas de pacote comecam com "[ebuild ...", "[binary ..." ou "[nomerge ...".
    # Contamos apenas ebuild/binary: nomerge e pacote que NAO sera tocado.
    printf '%s\n' "$saida" | grep -cE '^\[(ebuild|binary)' || true
}

# mostrar_amostra_world: loga as primeiras linhas do --pretend para o usuario ter
# ideia do QUE muda, nao so de quantos. Puramente informativo, nunca fatal.
mostrar_amostra_world() {
    local saida
    saida="$(emerge --pretend --columns "${WORLD_UPDATE_ARGS[@]}" 2>&1)" || true
    [[ -n "$saida" ]] || return 0
    log_info "amostra do que o -uDN @world faria (primeiras 20 linhas de pacote):"
    printf '%s\n' "$saida" | grep -E '^\[(ebuild|binary)' | head -20 || true
}

# ---------------------------------------------------------------------------
# 10a-profile-switch — troca do perfil para 23.0/desktop
# ---------------------------------------------------------------------------

# Probe: o perfil corrente JA e o alvo.
#
# Autoridade = current_profile() (lib.sh:635), que resolve o symlink
# /etc/portage/make.profile — a fonte CANONICA, que e o que o Portage realmente
# le. Nunca parseamos `eselect profile show`, cuja saida e apresentacao.
# Marker nenhum participa desta decisao: se alguem trocou o perfil a mao, o
# probe enxerga o estado real.
probe_profile_switch() {
    local cur
    cur="$(current_profile)" || return 1
    [[ "$cur" == "$DESKTOP_TARGET_PROFILE" ]]
}

do_profile_switch() {
    # Opt-in: sem o pedido explicito, a etapa nao acontece. Este teste vive no
    # do_fn (e nao num if em volta do run_step) para que o script rodado
    # standalone tambem respeite a variavel.
    if [[ "$DESKTOP_SWITCH_PROFILE" != "yes" ]]; then
        die "a troca de perfil nao foi autorizada (DESKTOP_SWITCH_PROFILE='$DESKTOP_SWITCH_PROFILE'). Esta etapa e OPT-IN por ser cara e mexer no sistema ja validado. Para autorizar: rode com --with-profile-world, ou DESKTOP_SWITCH_PROFILE=yes $0"
    fi

    local cur
    cur="$(current_profile)" \
        || die "/etc/portage/make.profile nao existe ou nao resolve — o sistema esta sem perfil valido. Nao troco de perfil por cima de um estado quebrado. eselect diz: $(eselect_profile_show)"
    log_info "perfil atual: $cur"
    log_info "perfil alvo:  $DESKTOP_TARGET_PROFILE"

    # REGRA 3: prova que o alvo existe na arvore REAL antes de tentar o set.
    perfil_existe "$DESKTOP_TARGET_PROFILE" \
        || die "o perfil '$DESKTOP_TARGET_PROFILE' NAO aparece em 'eselect profile list' nesta arvore. Nao vou chutar outro nome. Rode 'eselect profile list' e escolha o perfil desktop correspondente ao seu INIT_SYSTEM ('$INIT_SYSTEM'); se a arvore estiver velha, sincronize antes (emerge --sync)."

    # A troca em si e barata; o que custa e o @world que vem depois. Por isso a
    # contagem MEDIDA mostrada aqui e a do -uDN @world: e ela que representa o
    # custo real da decisao que o usuario esta tomando agora.
    mostrar_amostra_world
    local desc
    desc="Trocar o perfil do Portage:
    de:    $cur
    para:  $DESKTOP_TARGET_PROFILE

O perfil desktop liga globalmente wayland, X, elogind, dbus, policykit,
pipewire, screencast, vulkan, opengl, dri, sound, udev e upower. Isso resolve de
uma vez a USE=wayland do nvidia-drivers (o ponto de falha numero um deste
projeto), mas RECONSTROI grande parte do sistema.

Reverter exige outro 'emerge -uDN @world' completo. Faca backup antes.

A contagem abaixo e o custo REAL: quantos pacotes o 'emerge -uDN @world'
precisaria tocar depois desta troca."

    # confirm_expensive sem comando de pretend: passamos a contagem ja calculada
    # por contar_pacotes_world, porque o helper do lib-desktop.sh usa --quiet e
    # contaria 0 (ver o comentario em contar_pacotes_world).
    local n
    if n="$(contar_pacotes_world)"; then
        desc="$desc

Pacotes que o -uDN @world instalaria/reconstruiria apos a troca: $n
(contagem MEDIDA nesta maquina agora; NAO ha estimativa confiavel de duracao —
 o tempo depende do hardware, da rede e dos pacotes envolvidos.)"
    else
        log_warn "nao foi possivel calcular a contagem com --pretend; a confirmacao seguira sem o numero"
    fi

    confirm_expensive "troca de perfil para $DESKTOP_TARGET_PROFILE" "$desc" \
        || die "troca de perfil recusada pelo usuario — nada foi alterado. O modulo pode seguir sem ela, mas entao a USE=wayland do nvidia-drivers precisa ser garantida pela etapa 11."

    if [[ "${DESKTOP_DRY_RUN:-no}" == "yes" ]]; then
        die "DESKTOP_DRY_RUN=yes — a troca de perfil seria feita agora ('eselect profile set $DESKTOP_TARGET_PROFILE'), mas nada foi alterado. Rode sem dry-run para aplicar."
    fi

    # Por NOME exato, nunca por numero.
    eselect profile set "$DESKTOP_TARGET_PROFILE"

    # Verificar DEPOIS de aplicar, pela fonte canonica: o eselect pode sair 0 e
    # ainda assim deixar o symlink apontando para outro lugar. Mesmo cuidado do
    # 03-chroot-setup.sh:240-243.
    cur="$(current_profile)" \
        || die "apos 'eselect profile set $DESKTOP_TARGET_PROFILE', /etc/portage/make.profile nao existe ou nao resolve. eselect diz: $(eselect_profile_show)"
    [[ "$cur" == "$DESKTOP_TARGET_PROFILE" ]] \
        || die "perfil errado apos o set: /etc/portage/make.profile resolve para '$cur', esperado '$DESKTOP_TARGET_PROFILE'. eselect diz: $(eselect_profile_show)"

    log_info "perfil trocado com sucesso para $cur"
    log_warn "O perfil mudou, mas os pacotes AINDA estao construidos com as USE antigas."
    log_warn "O sistema so fica coerente depois do 'emerge -uDN @world' (sub-etapa 10a-world-update)."
    log_warn "Rodar com DESKTOP_UPDATE_WORLD=yes e o caminho normal daqui."
}

# So registramos a sub-etapa quando ela foi pedida. Sem isso, rodar o script
# standalone (ou com apenas DESKTOP_UPDATE_WORLD=yes) faria o run_step chamar o
# do_fn, que morreria no die de autorizacao — transformando "nao pedi isso" em
# erro fatal.
if [[ "$DESKTOP_SWITCH_PROFILE" == "yes" ]]; then
    run_step 10a-profile-switch probe_profile_switch do_profile_switch
else
    log_info "[10a-profile-switch] DESKTOP_SWITCH_PROFILE=no — troca de perfil NAO solicitada, pulando (perfil atual: $(current_profile 2>/dev/null || echo '(indeterminado)'))"
fi

# ---------------------------------------------------------------------------
# 10a-world-update — emerge -uDN @world
# ---------------------------------------------------------------------------

# Probe: nao existe probe barato e honesto para "@world esta atualizado".
#
# EXCECAO DELIBERADA E DOCUMENTADA: este e o UNICO probe caro do modulo inteiro.
# Todos os outros consultam um arquivo, o VDB ou um servico em milissegundos;
# este roda um `emerge --pretend` completo, que leva dezenas de segundos porque o
# Portage precisa resolver o grafo de dependencias inteiro.
#
# A alternativa seria confiar num marker — e um marker aqui seria uma MENTIRA:
# ele diria "@world atualizado" para sempre, mesmo depois de um `emerge --sync`
# trazer 200 atualizacoes novas. Como o principio do projeto e "o PROBE e a
# autoridade, o MARKER e so cache", pagamos o custo do probe honesto.
#
# Consideramos feito quando a lista do -uDN @world vem VAZIA (zero pacotes a
# instalar ou reconstruir). Se o calculo falhar, retornamos "nao feito"
# (fail-closed): melhor oferecer trabalho ja feito do que pular trabalho real.
probe_world_update() {
    local n
    n="$(contar_pacotes_world)" || return 1
    [[ "$n" == "0" ]]
}

do_world_update() {
    if [[ "$DESKTOP_UPDATE_WORLD" != "yes" ]]; then
        die "o emerge -uDN @world nao foi autorizado (DESKTOP_UPDATE_WORLD='$DESKTOP_UPDATE_WORLD'). Esta etapa e OPT-IN por levar horas. Para autorizar: rode com --with-profile-world, ou DESKTOP_UPDATE_WORLD=yes $0"
    fi

    mostrar_amostra_world

    local desc n
    desc="Rodar: emerge --update --deep --newuse --keep-going @world

Reconstroi todos os pacotes cujas USE flags mudaram (tipicamente apos uma troca
de perfil) e atualiza o que estiver desatualizado.

--keep-going: um pacote quebrado no meio nao aborta o trabalho ja feito; as
falhas sao reportadas no fim.

Este e o passo LONGO. Deixe a maquina trabalhar."

    if n="$(contar_pacotes_world)"; then
        desc="$desc

Pacotes a instalar/reconstruir: $n
(contagem MEDIDA nesta maquina agora; NAO ha estimativa confiavel de duracao.)"
    else
        log_warn "nao foi possivel calcular a contagem com --pretend; a confirmacao seguira sem o numero"
    fi

    confirm_expensive "emerge -uDN @world" "$desc" \
        || die "emerge -uDN @world recusado pelo usuario — nada foi alterado. ATENCAO: se a troca de perfil ja foi aplicada, o sistema esta num estado meio-termo (perfil novo, pacotes construidos com as USE antigas). Rode esta etapa quando puder."

    if [[ "${DESKTOP_DRY_RUN:-no}" == "yes" ]]; then
        die "DESKTOP_DRY_RUN=yes — o 'emerge ${WORLD_EMERGE_ARGS[*]}' seria executado agora, mas nada foi alterado. Rode sem dry-run para aplicar."
    fi

    log_info "iniciando 'emerge ${WORLD_EMERGE_ARGS[*]}' — isto pode levar horas"
    # Sem --autounmask-write (regra do projeto): se faltar keyword ou USE, o
    # emerge deve PARAR e mostrar o que falta, e nao reescrever a configuracao do
    # usuario por conta propria.
    emerge "${WORLD_EMERGE_ARGS[@]}" \
        || die "o 'emerge -uDN @world' falhou. Com --keep-going, o que compilou foi mantido e apenas os pacotes com falha ficaram pendentes; o resumo no fim do log lista quais. Log completo: $LOGFILE. Corrija o(s) pacote(s) e rode esta etapa de novo — ela e retomavel."

    log_info "emerge -uDN @world concluido"
}

if [[ "$DESKTOP_UPDATE_WORLD" == "yes" ]]; then
    run_step 10a-world-update probe_world_update do_world_update
else
    log_info "[10a-world-update] DESKTOP_UPDATE_WORLD=no — atualizacao do @world NAO solicitada, pulando"
    # Aviso util: perfil novo sem @world deixa o sistema coerente so no papel.
    if [[ "$DESKTOP_SWITCH_PROFILE" == "yes" ]]; then
        log_warn "o perfil foi trocado nesta execucao mas o @world NAO foi atualizado."
        log_warn "Os pacotes continuam construidos com as USE flags ANTIGAS — inclusive o"
        log_warn "nvidia-drivers, que pode seguir sem USE=wayland. Rode com"
        log_warn "DESKTOP_UPDATE_WORLD=yes assim que possivel, ou garanta a flag na etapa 11."
    fi
fi

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------

log_info "===================================================================="
log_info "10a concluida. Perfil corrente: $(current_profile 2>/dev/null || echo '(indeterminado)')"
log_info "Proxima etapa da sequencia: 11-nvidia-wayland (USE=wayland no driver)."
log_info "===================================================================="
