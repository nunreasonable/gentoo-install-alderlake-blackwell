#!/usr/bin/env bash
#
# test-desktop.sh — invariantes do MODULO DE DESKTOP (desktop/).
#
# O modulo de desktop e ADITIVO: ele roda no sistema JA INSTALADO E BOOTADO,
# depois que o instalador base (00-06) terminou. Isso muda completamente o
# perfil de risco em relacao ao instalador, e e o que estes testes cobrem:
#
#   1. a guarda de fase RECUSA rodar em live ISO / dentro do chroot;
#   2. nenhum script do desktop toca em disco (sgdisk/mkfs/parted/wipefs/dd);
#   3. nenhum --autounmask-write (reescreve a config do Portage as cegas);
#   4. nenhum ACCEPT_LICENSE=* global (aceitaria licenca que o usuario nao viu);
#   5. todo atom mencionado tem a forma categoria/nome;
#   6. os scripts sao idempotentes por construcao (toda acao dentro de run_step);
#   7. o instalador base nao e referenciado para ESCRITA.
#
# Nenhum teste aqui executa emerge, instala pacote ou roda os scripts do modulo.
# Sao asercoes estaticas sobre o codigo, mais a guarda de fase exercitada em
# ISOLAMENTO com stubs (as funcoes _rbs_* sao extraidas e chamadas com die/
# state_dir falsos, nunca contra o sistema real deste host).

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

printf '\n== test-desktop ==\n'

DESKTOP_DIR="$REPO_DIR/desktop"
LIBD="$DESKTOP_DIR/lib-desktop.sh"

if [[ ! -d "$DESKTOP_DIR" ]]; then
    no "diretorio desktop/ existe" "nao encontrei $DESKTOP_DIR"
    finish; exit
fi

# Scripts numerados + orquestrador (os que EXECUTAM acao). lib-desktop.sh e
# vars-desktop.sh sao biblioteca/config e entram so onde faz sentido.
mapfile -t DESKTOP_ACTION < <(find "$DESKTOP_DIR" -maxdepth 1 -name '1*.sh' -o -maxdepth 1 -name 'install-desktop.sh' | sort)
mapfile -t DESKTOP_ALL < <(find "$DESKTOP_DIR" -maxdepth 1 -name '*.sh' | sort)

# ---------------------------------------------------------------------------
# 0. Estrutura minima: os arquivos do contrato existem e sao executaveis
# ---------------------------------------------------------------------------
# O orquestrador morre se um numerado faltar; este teste pega isso antes.
for f in install-desktop.sh lib-desktop.sh vars-desktop.sh \
         10-portage-desktop.sh 10a-profile-world.sh 11-nvidia-wayland.sh \
         12-niri-stack.sh 13-services.sh 14-dotfiles.sh 15-validate.sh; do
    if [[ -f "$DESKTOP_DIR/$f" ]]; then
        ok "desktop/$f existe"
    else
        no "desktop/$f existe" "arquivo ausente — o orquestrador abortaria"
    fi
done

# Os numerados sao chamados como executavel pelo run_script (nao via `bash x.sh`),
# entao o bit +x faz parte do contrato.
for f in "${DESKTOP_ACTION[@]}"; do
    if [[ -x "$f" ]]; then
        ok "$(basename "$f") e executavel"
    else
        no "$(basename "$f") e executavel" "run_script morre com 'nao e executavel'"
    fi
done

# ---------------------------------------------------------------------------
# 1. GUARDA DE FASE — recusa live ISO e chroot, fail-closed
# ---------------------------------------------------------------------------
# Exercitamos as funcoes REAIS extraidas do lib-desktop.sh, com die/log/
# state_dir stubados. Assim o teste mede a logica de verdade sem depender do
# ambiente deste host (que e um Fedora, nem live ISO nem Gentoo).
guard_eval() {
    # $1 = codigo a rodar depois de carregar as funcoes da guarda
    # $2 = valor de CHROOT_SENTINEL ; $3 = valor devolvido por state_dir()
    local code="$1" sentinel="${2:-/nao/existe/sentinela}" state="${3:-/nao/existe/state}"
    bash -c '
        set -uo pipefail
        LIBD="$1"; CHROOT_SENTINEL="$2"; STATE_FAKE="$3"
        die() { echo "DIE: $*"; exit 42; }
        log_info() { :; }
        log_warn() { :; }
        state_dir() { echo "$STATE_FAKE"; }
        _host_is_installed_system() { return 0; }
        # extrai as funcoes da guarda do arquivo real
        eval "$(awk "/^_rbs_check_[a-z_]*\(\) \{|^require_booted_system\(\) \{/,/^\}/" "$LIBD")"
        eval "$4"
    ' _ "$LIBD" "$sentinel" "$state" "$code" 2>&1
}

# (a) sentinela de chroot PRESENTE -> tem de recusar
sent_tmp="$(mktemp -d)"; touch "$sent_tmp/.inside-chroot"
out="$(guard_eval '_rbs_check_no_chroot_sentinel; echo NAO_RECUSOU' "$sent_tmp/.inside-chroot")"
if grep -q 'NAO_RECUSOU' <<< "$out"; then
    no "guarda recusa quando a sentinela de chroot existe" "$out"
else
    ok "guarda recusa quando a sentinela de chroot existe"
fi
assert_contains "$out" "DENTRO do chroot" "a recusa por sentinela explica que estamos no chroot"

# (b) sentinela AUSENTE -> nao pode recusar por esse motivo
out="$(guard_eval '_rbs_check_no_chroot_sentinel; echo SEGUIU' "$sent_tmp/nao-existe")"
assert_contains "$out" "SEGUIU" "guarda nao recusa quando a sentinela esta ausente"

# (c) state da instalacao AUSENTE -> tem de recusar
out="$(guard_eval '_rbs_check_install_finished; echo NAO_RECUSOU' "" "$sent_tmp/state-inexistente")"
if grep -q 'NAO_RECUSOU' <<< "$out"; then
    no "guarda recusa quando o state da instalacao nao existe" "$out"
else
    ok "guarda recusa quando o state da instalacao nao existe"
fi

# (d) state existe mas SEM os markers finais do 06 -> instalacao a meio caminho.
# Este e o caso que distingue "instalou" de "comecou a instalar": um chroot de
# instalacao pela metade TAMBEM tem o diretorio de state.
st="$sent_tmp/state"; mkdir -p "$st"; touch "$st/00-partition" "$st/04-kernel"
out="$(guard_eval '_rbs_check_install_finished; echo NAO_RECUSOU' "" "$st")"
if grep -q 'NAO_RECUSOU' <<< "$out"; then
    no "guarda recusa instalacao incompleta (sem markers do 06)" "$out"
else
    ok "guarda recusa instalacao incompleta (sem markers do 06)"
fi

# (e) so um dos dois markers finais -> ainda incompleto
touch "$st/06-users"
out="$(guard_eval '_rbs_check_install_finished; echo NAO_RECUSOU' "" "$st")"
if grep -q 'NAO_RECUSOU' <<< "$out"; then
    no "guarda recusa com 06-users mas sem 06-services" "$out"
else
    ok "guarda recusa com 06-users mas sem 06-services"
fi

# (f) instalacao completa -> a checagem de state passa
touch "$st/06-services"
out="$(guard_eval '_rbs_check_install_finished; echo SEGUIU' "" "$st")"
assert_contains "$out" "SEGUIU" "guarda aceita quando os markers 06-users e 06-services existem"

# (g) rootfs de live ISO -> recusa por TIPO de filesystem.
# Stub do findmnt devolvendo squashfs (a assinatura de um live ISO).
stub_dir="$sent_tmp/stubs"
make_stub "$stub_dir" findmnt 'echo squashfs'
out="$(PATH="$stub_dir:$PATH" guard_eval '_rbs_check_rootfs_type; echo NAO_RECUSOU')"
if grep -q 'NAO_RECUSOU' <<< "$out"; then
    no "guarda recusa rootfs squashfs (live ISO)" "$out"
else
    ok "guarda recusa rootfs squashfs (live ISO)"
fi
for fs in tmpfs overlay ramfs rootfs iso9660; do
    make_stub "$stub_dir" findmnt "echo $fs"
    out="$(PATH="$stub_dir:$PATH" guard_eval '_rbs_check_rootfs_type; echo NAO_RECUSOU')"
    if grep -q 'NAO_RECUSOU' <<< "$out"; then
        no "guarda recusa rootfs $fs" "$out"
    else
        ok "guarda recusa rootfs $fs"
    fi
done

# (h) FAIL-CLOSED: findmnt falhando nao pode virar "pode prosseguir".
make_stub "$stub_dir" findmnt 'exit 1'
out="$(PATH="$stub_dir:$PATH" guard_eval '_rbs_check_rootfs_type; echo NAO_RECUSOU')"
if grep -q 'NAO_RECUSOU' <<< "$out"; then
    no "guarda e fail-closed quando findmnt falha" "deixou passar: $out"
else
    ok "guarda e fail-closed quando findmnt falha"
fi

# (i) PID 1 nao sendo init (assinatura de chroot/container) -> recusa.
if [[ -r /proc/1/comm ]]; then
    ok "PID 1 legivel neste host (checagem (b) da guarda e exercitavel)"
else
    ok "PID 1 nao legivel — checagem (b) e fail-closed por construcao"
fi
guard_src="$(sed -n '/^_rbs_check_pid1_is_init() {/,/^}/p' "$LIBD")"
assert_contains "$guard_src" "die" "a checagem de PID 1 morre quando o PID 1 nao e init"

# (j) A guarda chama TODAS as sub-checagens, e nao um subconjunto.
req_src="$(sed -n '/^require_booted_system() {/,/^}/p' "$LIBD")"
for c in _rbs_check_not_chroot _rbs_check_pid1_is_init _rbs_check_root_on_real_disk \
         _rbs_check_rootfs_type _rbs_check_no_chroot_sentinel _rbs_check_target_not_mounted \
         _rbs_check_install_finished _rbs_check_init_running; do
    assert_contains "$req_src" "$c" "require_booted_system chama $c"
done

# (k) Todo script que EXECUTA acao chama a guarda (rodam standalone para debug).
# ATENCAO: exigimos a CHAMADA em posicao de comando, nao a mera mencao do nome.
# Todo script do modulo CITA require_booted_system no cabecalho em comentario;
# um 'grep -q require_booted_system' passaria mesmo com a chamada comentada —
# falso negativo confirmado por mutacao (comentar a chamada nao derrubava o
# teste). Por isso o padrao ancora no inicio da linha, fora de comentario.
for f in "${DESKTOP_ACTION[@]}"; do
    if grep -qE '^[[:space:]]*require_booted_system([[:space:]]|$)' "$f"; then
        ok "$(basename "$f") chama require_booted_system"
    else
        no "$(basename "$f") chama require_booted_system" "rodaria sem guarda em standalone"
    fi
done

# Mesma logica para require_root: o modulo escreve em /etc e chama emerge.
for f in "${DESKTOP_ACTION[@]}"; do
    if grep -qE '^[[:space:]]*require_root([[:space:]]|$)' "$f"; then
        ok "$(basename "$f") chama require_root"
    else
        no "$(basename "$f") chama require_root" "falharia no meio de um emerge em vez de cedo"
    fi
done

# E a ORDEM importa: a guarda tem de vir ANTES de qualquer acao. Conferimos que
# require_booted_system aparece antes do primeiro run_step do arquivo.
for f in "${DESKTOP_ACTION[@]}"; do
    b="$(basename "$f")"
    [[ "$b" == "install-desktop.sh" ]] && continue
    lg="$(grep -nE '^[[:space:]]*require_booted_system([[:space:]]|$)' "$f" | head -1 | cut -d: -f1)"
    lr="$(grep -nE '^[[:space:]]*run_step ' "$f" | head -1 | cut -d: -f1)"
    if [[ -n "$lg" && -n "$lr" ]] && (( lg < lr )); then
        ok "$b chama a guarda ANTES do primeiro run_step"
    else
        no "$b chama a guarda ANTES do primeiro run_step" "guarda na linha ${lg:-ausente}, run_step na ${lr:-ausente}"
    fi
done

# (l) O modulo NUNCA pode usar require_phase nem validate_vars do instalador:
# require_phase exige a fase de instalacao (o oposto do que o modulo quer) e
# validate_vars morre com TARGET_ROOT vazio, que e justamente o que o modulo usa.
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(grep -nE '^[^#]*\b(require_phase|validate_vars)\b' "$f" || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao chama require_phase/validate_vars"
    else
        no "$(basename "$f") nao chama require_phase/validate_vars" "$hits"
    fi
done

# ---------------------------------------------------------------------------
# 2. NENHUMA OPERACAO DE DISCO
# ---------------------------------------------------------------------------
# O modulo instala pacotes e escreve config. Nunca formata, reparticiona nem
# apaga disco. Um sgdisk aqui destruiria o sistema que o modulo deveria enfeitar.
# Ignoramos comentarios e mensagens (die/log_*/printf/echo), que citam esses
# nomes legitimamente ao explicar o que o modulo NAO faz.
# strip_noise: remove comentarios e MENSAGENS ao usuario, que citam
# legitimamente nomes perigosos ao explicar o que o modulo NAO faz.
#
# printf/echo NAO sao removidos aqui: e justamente com printf que este modulo
# ESCREVE package.use e config. Filtra-los criaria um ponto cego — confirmado
# por mutacao (um 'printf "... kernel-open"' injetado passava despercebido).
# Removemos so as funcoes de log/erro, cujo conteudo e texto para humano.
strip_noise() {
    sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "$1" \
        | grep -vE '\b(log_info|log_warn|log_error|die|check_fail|check_warn)\b'
}

# strip_noise_all: o mesmo, sobre TODOS os arquivos do modulo de uma vez.
strip_noise_all() {
    local f
    for f in "${DESKTOP_ALL[@]}"; do strip_noise "$f"; done
}
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(strip_noise "$f" | grep -nE '(^|[^[:alnum:]_./-])(sgdisk|mkfs(\.[a-z0-9]+)?|parted|wipefs|blkdiscard|shred)([[:space:]]|$)' || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao invoca sgdisk/mkfs/parted/wipefs"
    else
        no "$(basename "$f") nao invoca sgdisk/mkfs/parted/wipefs" "$hits"
    fi
done

# `dd` merece regra propria: e o comando mais facil de escrever por engano com
# of=/dev/sdX. Nenhum uso legitimo existe neste modulo.
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(strip_noise "$f" | grep -nE '(^|[^[:alnum:]_./-])dd[[:space:]]+(if|of|bs)=' || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao invoca dd com if=/of=/bs="
    else
        no "$(basename "$f") nao invoca dd com if=/of=/bs=" "$hits"
    fi
done

# rm -rf EXECUTADO e destrutivo. Permitimos rm de arquivo unico (o 14 remove um
# config.kdl que ele mesmo acabou de criar segundos antes).
#
# strip_noise ja remove log_/die/printf/echo, mas uma mensagem de die pode ser
# longa e continuar em linhas seguintes (o 15-validate ENSINA o usuario a rodar
# 'rm -rf' num diretorio de runtime — texto, nao execucao). Por isso exigimos
# que o rm esteja no INICIO de um comando, e nao no meio de uma string.
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(strip_noise "$f" \
        | grep -nE '(^|[;&|]|\bthen\b|\belse\b|\bdo\b)[[:space:]]*rm[[:space:]]+-[a-zA-Z]*[rR]' || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao executa rm -r"
    else
        no "$(basename "$f") nao executa rm -r" "$hits"
    fi
done

# mount/umount: o modulo roda num sistema ja bootado; nao monta nada.
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(strip_noise "$f" | grep -nE '(^|[^[:alnum:]_./-])(umount|mount)[[:space:]]+[-/$]' || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao monta/desmonta filesystem"
    else
        no "$(basename "$f") nao monta/desmonta filesystem" "$hits"
    fi
done

# ---------------------------------------------------------------------------
# 3. NENHUM --autounmask-write
# ---------------------------------------------------------------------------
# --autounmask-write faz o Portage reescrever /etc/portage/* sozinho, as cegas.
# O modulo escreve keywords e USE de forma explicita e auditavel; deixar o
# emerge fazer isso esconderia exatamente a decisao que o projeto quer registrar.
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(strip_noise "$f" | grep -nE '\-\-autounmask' || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao usa --autounmask*"
    else
        no "$(basename "$f") nao usa --autounmask*" "$hits"
    fi
done

# ---------------------------------------------------------------------------
# 4. NENHUM ACCEPT_LICENSE=* global
# ---------------------------------------------------------------------------
# ACCEPT_LICENSE="*" aceitaria QUALQUER licenca sem o usuario ver. O instalador
# base usa "@FREE" e libera a licenca da NVIDIA por atom, em package.license.
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(strip_noise "$f" | grep -nE 'ACCEPT_LICENSE[[:space:]]*=[[:space:]]*"?\*' || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao define ACCEPT_LICENSE=*"
    else
        no "$(basename "$f") nao define ACCEPT_LICENSE=*" "$hits"
    fi
done

# Nenhuma reescrita de ACCEPT_LICENSE, seja qual for o valor: a licenca e
# territorio do instalador base (make.conf + package.license/nvidia-drivers).
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(strip_noise "$f" | grep -nE '^[^=]*\bACCEPT_LICENSE=' || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao reatribui ACCEPT_LICENSE"
    else
        no "$(basename "$f") nao reatribui ACCEPT_LICENSE" "$hits"
    fi
done

# ---------------------------------------------------------------------------
# 5. FORMA DOS ATOMS: categoria/nome
# ---------------------------------------------------------------------------
# Regra 3 do projeto: nada de nome de pacote chutado. Um atom sem categoria
# ("niri" em vez de "gui-wm/niri") e ambiguo para o Portage e costuma ser o
# sintoma de um nome inventado. Coletamos os atoms que aparecem em contexto de
# emerge/require_atoms/have_atom e conferimos a forma de cada um.
#
# A lista de categorias vem do proprio texto: exigimos que a parte antes da
# barra seja uma categoria plausivel do Portage (letras minusculas, digitos,
# hifen) e que exista a barra.
# Categorias reais do Portage. Um prefixo fora desta lista, em posicao de atom,
# e sinal de nome inventado — exatamente o que a regra 3 do projeto proibe.
CAT_OK='^(acct-group|acct-user|app-admin|app-arch|app-crypt|app-editors|app-eselect|app-emulation|app-misc|app-portage|app-shells|app-text|dev-lang|dev-libs|dev-util|dev-build|dev-cpp|gnome-base|gnome-extra|gui-apps|gui-libs|gui-wm|media-fonts|media-gfx|media-libs|media-plugins|media-sound|media-video|net-misc|net-wireless|sec-keys|sys-apps|sys-auth|sys-boot|sys-devel|sys-fs|sys-kernel|sys-libs|sys-power|sys-process|virtual|www-client|x11-apps|x11-base|x11-drivers|x11-libs|x11-misc|x11-terms|x11-themes|x11-wm)/'

# (a) Argumentos LITERAIS passados as funcoes de pacote tem de ser categoria/nome.
# Extraimos so os tokens que parecem nome de pacote (nao variaveis, nao flags,
# nao operadores), o que evita varrer prosa de comentario para dentro do teste.
# ANCORAGEM: so linhas em que a funcao esta em POSICAO DE COMANDO (inicio da
# linha, possivelmente atras de if/!/&&). Sem isso, o grep pega a prosa dos
# comentarios que MENCIONAM as funcoes e o teste vira ruido.
atoms_usados="$(grep -hoE '(^|[[:space:]]|;|&&|\|\||!)(require_atoms|have_atom|pkg_installed|have_use_flag)[[:space:]]+[a-z][a-z0-9+_.-]*/[a-zA-Z0-9][a-zA-Z0-9+_.-]*' "${DESKTOP_ALL[@]}" \
    | sed -E 's/.*(require_atoms|have_atom|pkg_installed|have_use_flag)[[:space:]]+//' \
    | sort -u || true)"
# O teste util nao e "os que tem barra tem barra" (tautologia), e sim: NENHUMA
# chamada em posicao de comando passa um nome NU (sem categoria e sem ser
# variavel). "emerge niri" seria aceito pelo Portage e instalaria o pacote
# errado — ou nenhum; e o sintoma classico de nome chutado.
nus="$(strip_noise_all \
    | grep -hnE '(^|[[:space:]]|;|&&|\|\||!)(require_atoms|have_atom|pkg_installed)[[:space:]]+[a-z][a-z0-9+_.-]*([[:space:]]|$)' \
    | grep -vE '(require_atoms|have_atom|pkg_installed)[[:space:]]+[a-z][a-z0-9+_.-]*/' \
    | grep -vE '(require_atoms|have_atom|pkg_installed)[[:space:]]+("|\$)' || true)"
if [[ -z "$nus" ]]; then
    ok "nenhuma chamada de pacote recebe nome NU (sem categoria/) — $(grep -c . <<< "$atoms_usados") atoms literais conferidos"
else
    no "nenhuma chamada de pacote recebe nome NU (sem categoria/)" "$nus"
fi

# (b) E cada um usa uma categoria REAL do Portage.
bad_cat=""
while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    [[ "$a" == *"/"* ]] || continue
    grep -qE "$CAT_OK" <<< "$a/" || bad_cat+="$a "
done <<< "$atoms_usados"
if [[ -z "$bad_cat" ]]; then
    ok "todo atom passado as funcoes de pacote usa categoria conhecida do Portage"
else
    no "todo atom passado as funcoes de pacote usa categoria conhecida do Portage" "categoria suspeita: $bad_cat"
fi

# (c) Os atoms escritos nos arquivos gerados de package.use/package.accept_keywords
# tambem tem de ter categoria. Estes sao os que o Portage le de verdade.
# Linha de package.use / package.accept_keywords tem forma propria: comeca a
# linha com o atom e e seguida de USE flags ou de uma keyword (~amd64, **).
# Ancorar no INICIO DA LINHA e o que separa a linha de config gerada da prosa
# de comentario e dos caminhos de arquivo ("etc/portage", "run/user").
# A categoria precisa conter hifen ou ser uma das poucas sem hifen (virtual),
# o que descarta "usr/lib64", "dev/dri" e amigos.
# Duas fontes, porque o modulo escreve package.use de duas formas:
#   (1) linhas literais (heredoc / printf com o atom no inicio da linha);
#   (2) via os geradores _use_line/_keyword_line, que recebem o atom como 1o
#       argumento — a forma dominante no 10-portage-desktop.sh.
# Sem a fonte (2) este teste conferiria quase nada e daria falsa seguranca.
atoms_cfg="$( { strip_noise_all \
        | grep -hoE "^(  *)?([a-z][a-z0-9]*-[a-z0-9]+|virtual)/[a-zA-Z0-9][a-zA-Z0-9+_.-]*[[:space:]]+(-?[a-z][a-z0-9+_-]*|~amd64|\*\*)" \
        | awk '{print $1}'
      grep -hoE '_(use|keyword)_line[[:space:]]+"?[a-z][a-z0-9-]*/[a-zA-Z0-9][a-zA-Z0-9+_.-]*' "${DESKTOP_ALL[@]}" \
        | sed -E 's/.*line[[:space:]]+"?//'
    } | sort -u || true)"
bad_cfg=""
while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    grep -qE "$CAT_OK" <<< "$a/" || bad_cfg+="$a "
done <<< "$atoms_cfg"
if [[ -z "$bad_cfg" ]]; then
    ok "atoms escritos em package.use/accept_keywords usam categoria conhecida ($(grep -c . <<< "$atoms_cfg") atoms)"
else
    no "atoms escritos em package.use/accept_keywords usam categoria conhecida" "suspeitos: $bad_cfg"
fi

# media-fonts/nerd-fonts NAO EXISTE no ::gentoo (404 confirmado na pesquisa).
# O atom correto e media-fonts/symbols-nerd-font. Regressao facil de cometer.
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(strip_noise "$f" | grep -nE 'media-fonts/nerd-fonts' || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao usa media-fonts/nerd-fonts (atom inexistente)"
    else
        no "$(basename "$f") nao usa media-fonts/nerd-fonts (atom inexistente)" "$hits"
    fi
done

# ---------------------------------------------------------------------------
# 6. IDEMPOTENCIA POR CONSTRUCAO: toda acao dentro de run_step
# ---------------------------------------------------------------------------
# A arquitetura do projeto e "probe e autoridade, marker e cache". Um emerge
# fora de run_step rodaria de novo a cada execucao, quebrando a retomada.
for f in "${DESKTOP_ACTION[@]}"; do
    b="$(basename "$f")"
    [[ "$b" == "install-desktop.sh" ]] && continue   # orquestrador: chama scripts, nao faz acao
    n="$(grep -cE '^[[:space:]]*run_step ' "$f")"
    if (( n > 0 )); then
        ok "$b organiza suas acoes em run_step ($n sub-etapas)"
    else
        no "$b organiza suas acoes em run_step" "nenhum run_step encontrado"
    fi
done

# Todo emerge REAL (nao citado em texto) tem de estar dentro de uma funcao —
# nunca no corpo principal, onde rodaria antes/fora do controle do probe.
for f in "${DESKTOP_ACTION[@]}"; do
    b="$(basename "$f")"
    # linhas de emerge executavel: comeco de comando, nao dentro de string
    hits="$(strip_noise "$f" | grep -nE '^[[:space:]]*(if[[:space:]]+)?!?[[:space:]]*(saida=.*)?\$?\(?emerge[[:space:]]' || true)"
    if [[ -z "$hits" ]]; then
        ok "$b nao tem emerge no nivel de topo"
        continue
    fi
    # confirma que cada ocorrencia esta indentada (dentro de funcao/bloco)
    top=""
    while IFS= read -r line; do
        # linha sem indentacao nenhuma = nivel de topo
        grep -qE '^[0-9]+:emerge' <<< "$line" && top+="$line "
    done <<< "$hits"
    if [[ -z "$top" ]]; then
        ok "$b tem emerge apenas dentro de funcao (indentado)"
    else
        no "$b tem emerge apenas dentro de funcao" "no topo: $top"
    fi
done

# run_step recebe 3 argumentos (nome, probe, do): a forma que garante o contrato
# probe->do->probe. Uma chamada com 2 argumentos seria acao sem probe.
for f in "${DESKTOP_ACTION[@]}"; do
    b="$(basename "$f")"
    [[ "$b" == "install-desktop.sh" ]] && continue
    ruins="$(grep -hoE '^[[:space:]]*run_step[[:space:]]+[^#]*' "$f" \
             | awk '{ if (NF < 4) print }' || true)"
    if [[ -z "$ruins" ]]; then
        ok "$b chama run_step sempre com nome+probe+do"
    else
        no "$b chama run_step sempre com nome+probe+do" "$ruins"
    fi
done

# ---------------------------------------------------------------------------
# 7. O INSTALADOR BASE NAO E REFERENCIADO PARA ESCRITA
# ---------------------------------------------------------------------------
# O modulo faz SOURCE do lib.sh/vars.sh (leitura, permitido e desejado), mas
# nunca ESCREVE nos arquivos do instalador, que estao validados.
BASE_FILES='(install\.sh|lib\.sh|vars\.sh|0[0-6]-[a-z-]*\.sh|kernel-fragment\.config)'
for f in "${DESKTOP_ALL[@]}"; do
    b="$(basename "$f")"
    # redirecionamento (> ou >>), sed -i, tee, cp/mv com destino no instalador
    hits="$(strip_noise "$f" \
        | grep -nE "(>>?[[:space:]]*\"?[^|]*/?$BASE_FILES|sed[[:space:]]+-i[^|]*$BASE_FILES|tee[^|]*$BASE_FILES|(cp|mv)[[:space:]][^|]*$BASE_FILES)" || true)"
    if [[ -z "$hits" ]]; then
        ok "$b nao escreve nos arquivos do instalador base"
    else
        no "$b nao escreve nos arquivos do instalador base" "$hits"
    fi
done

# O source do lib.sh/vars.sh acontece em UM lugar so: lib-desktop.sh. Essa
# centralizacao e o que impede a cadeia fragil (TARGET_ROOT="" -> vars.sh ->
# reafirmacao -> lib.sh) de ser duplicada e divergir entre arquivos.
# O caminho e montado com $INSTALLER_DIR, entao casamos pelo sufixo do arquivo.
sourcers=""
for f in "${DESKTOP_ALL[@]}"; do
    grep -qE '^[[:space:]]*(source|\.)[[:space:]]+.*/(lib|vars)\.sh"?[[:space:]]*$' "$f" \
        && sourcers+="$(basename "$f") "
done
if [[ "$sourcers" == "lib-desktop.sh " ]]; then
    ok "so lib-desktop.sh faz source de ../lib.sh e ../vars.sh"
else
    no "so lib-desktop.sh faz source de ../lib.sh e ../vars.sh" "tambem: ${sourcers:-nenhum}"
fi

# ---------------------------------------------------------------------------
# 8. A ARMADILHA DO TARGET_ROOT
# ---------------------------------------------------------------------------
# vars.sh usa `: "${TARGET_ROOT:=/mnt/gentoo}"`, e a forma := sobrescreve
# variavel definida-porem-VAZIA. Se o modulo usasse := em vez de =, o
# state_dir() voltaria a apontar para /mnt/gentoo/var/lib/... e TODOS os markers
# do modulo iriam para o caminho errado — idempotencia silenciosamente falsa.
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(strip_noise "$f" | grep -nE ':[[:space:]]*"\$\{TARGET_ROOT:=' || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao usa := sobre TARGET_ROOT"
    else
        no "$(basename "$f") nao usa := sobre TARGET_ROOT" "$hits"
    fi
done

# E a reafirmacao DEPOIS do source de vars.sh precisa existir: sem ela, o
# TARGET_ROOT="" definido antes seria desfeito pelo proprio vars.sh.
linha_vars="$(grep -nE '^[[:space:]]*(source|\.)[[:space:]]+.*/vars\.sh' "$LIBD" | head -1 | cut -d: -f1)"
linha_reafirma="$(grep -n '^TARGET_ROOT=""' "$LIBD" | tail -1 | cut -d: -f1)"
if [[ -n "$linha_vars" && -n "$linha_reafirma" ]] && (( linha_reafirma > linha_vars )); then
    ok "lib-desktop.sh reafirma TARGET_ROOT=\"\" DEPOIS do source de ../vars.sh"
else
    no "lib-desktop.sh reafirma TARGET_ROOT=\"\" DEPOIS do source de ../vars.sh" \
       "vars.sh na linha ${linha_vars:-?}, reafirmacao na ${linha_reafirma:-ausente}"
fi

# Prova FUNCIONAL da armadilha: com TARGET_ROOT=/mnt/gentoo herdado do
# ambiente, o valor final tem de ser vazio. Rodamos so o trecho de sourcing,
# sem executar nada do modulo.
out="$(TARGET_ROOT=/mnt/gentoo bash -c '
    set -uo pipefail
    cd "$1" || exit 1
    TARGET_ROOT=""
    export TARGET_ROOT
    source ./vars.sh 2>/dev/null || true
    # esta e a reafirmacao que o lib-desktop.sh faz
    TARGET_ROOT=""
    printf "FINAL=[%s]\n" "$TARGET_ROOT"
' _ "$REPO_DIR")"
assert_contains "$out" "FINAL=[]" "TARGET_ROOT=/mnt/gentoo herdado do ambiente termina vazio"

# Sem a reafirmacao, vars.sh repoe /mnt/gentoo — este teste documenta o BUG que
# a reafirmacao evita (se um dia ele passar a devolver vazio, vars.sh mudou).
out="$(TARGET_ROOT=/mnt/gentoo bash -c '
    set -uo pipefail
    cd "$1" || exit 1
    TARGET_ROOT=""
    export TARGET_ROOT
    source ./vars.sh 2>/dev/null || true
    printf "SEM_REAFIRMACAO=[%s]\n" "$TARGET_ROOT"
' _ "$REPO_DIR")"
assert_contains "$out" "SEM_REAFIRMACAO=[/mnt/gentoo]" \
    "sem a reafirmacao, vars.sh repoe /mnt/gentoo (justifica a reafirmacao)"

# ---------------------------------------------------------------------------
# 9. NAO SABOTAR O 04-kernel.sh (guarda do kernel-open)
# ---------------------------------------------------------------------------
# O 04-kernel.sh ABORTA a instalacao se achar o token 'kernel-open' NAO
# comentado em qualquer arquivo sob /etc/portage/package.use/ no ramo >=595.
# Nenhum script do modulo pode EMITIR esse token para dentro de package.use.
# Distinguimos EMITIR o token de DEFENDER-SE dele: o 11-nvidia-wayland.sh tem
# uma auto-verificacao que faz grep pelo token no arquivo que acabou de escrever
# e morre se o encontrar. Essa linha CONTEM o token, mas e o contrario de
# sabota-lo. Por isso ignoramos ocorrencias dentro de grep/die.
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(strip_noise "$f" \
        | grep -nE 'kernel-open' \
        | grep -vE '\b(grep|die|check_fail|check_warn)\b' || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao emite o token kernel-open"
    else
        no "$(basename "$f") nao emite o token kernel-open" "$hits"
    fi
done

# E a defesa em profundidade do 11 continua existindo: se alguem remover a
# auto-verificacao, o modulo perde a rede que protege o 04-kernel.sh.
if grep -qE 'kernel-open' "$DESKTOP_DIR/11-nvidia-wayland.sh"; then
    ok "11-nvidia-wayland.sh mantem a auto-verificacao contra o token kernel-open"
else
    no "11-nvidia-wayland.sh mantem a auto-verificacao contra o token kernel-open" \
       "a protecao que impede sabotar o 04-kernel.sh sumiu"
fi

# E o modulo nao pode escrever no package.use/nvidia-drivers, que e territorio
# do 04-kernel.sh: precisa usar arquivo separado.
for f in "${DESKTOP_ALL[@]}"; do
    hits="$(strip_noise "$f" | grep -nE '>[[:space:]]*"?[^"]*package\.use/nvidia-drivers' || true)"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$f") nao sobrescreve package.use/nvidia-drivers"
    else
        no "$(basename "$f") nao sobrescreve package.use/nvidia-drivers" "$hits"
    fi
done

# ---------------------------------------------------------------------------
# 10. CONTRATO DO ORQUESTRADOR
# ---------------------------------------------------------------------------
ORQ="$DESKTOP_DIR/install-desktop.sh"

# Toda etapa da ORDEM_ETAPAS tem arquivo correspondente que existe.
ordem="$(grep -oE '^ORDEM_ETAPAS=\([^)]*\)' "$ORQ" | tr -d '()' | sed 's/ORDEM_ETAPAS=//')"
if [[ -n "$ordem" ]]; then
    ok "ORDEM_ETAPAS declarada: $ordem"
    for step in $ordem; do
        script="$(sed -n "/^step_script() {/,/^}/p" "$ORQ" \
                  | grep -E "^[[:space:]]*$step\)" | grep -oE '[0-9]+a?-[a-z-]+\.sh' | head -1)"
        if [[ -n "$script" && -f "$DESKTOP_DIR/$script" ]]; then
            ok "etapa $step -> $script existe"
        else
            no "etapa $step -> script existe" "mapeado para '${script:-nada}'"
        fi
    done
else
    no "ORDEM_ETAPAS declarada" "nao encontrei ORDEM_ETAPAS no orquestrador"
fi

# ORDEM: a 10a (troca de perfil + @world) tem de rodar ANTES da 11 (NVIDIA).
# Trocar o perfil liga USE=wayland global e o -uDN @world ja reconstroi o
# nvidia-drivers; inverter a ordem recompila o driver DUAS vezes.
insercao="$(grep -n '"10a"' "$ORQ" | head -1)"
# RUIDO JUSTIFICADO (SC2016): as aspas simples sao DELIBERADAS. Procuramos o
# texto literal '$_n' no codigo-fonte do orquestrador; expandir a variavel aqui
# (que nem existe neste script) faria o padrao casar com string vazia.
# shellcheck disable=SC2016
if grep -qE '\$_n"?[[:space:]]*==[[:space:]]*"10"' "$ORQ" && [[ -n "$insercao" ]]; then
    ok "a 10a e inserida logo apos a etapa 10 (antes da 11)"
else
    no "a 10a e inserida logo apos a etapa 10 (antes da 11)" "$insercao"
fi

# A 15 (validacao) roda antes da 14 (dotfiles) por design; ambas na ordem.
if grep -qE '^ORDEM_ETAPAS=\(10 11 12 13 15 14\)' "$ORQ"; then
    ok "ORDEM_ETAPAS e (10 11 12 13 15 14) — 15 valida antes do 14 escrever dotfiles"
else
    ok "ORDEM_ETAPAS difere do esperado — confira se a mudanca foi intencional: $ordem"
fi

# O orquestrador nao pode aceitar etapa do instalador base (0-6): erro tipico
# de quem vem do install.sh.
if grep -qE '0\[0-6\]|00?-06|etapa[s]? 0' "$ORQ"; then
    ok "o orquestrador trata explicitamente as etapas 00-06 do instalador base"
else
    no "o orquestrador trata explicitamente as etapas 00-06 do instalador base" \
       "nao achei mensagem dedicada"
fi

# ---------------------------------------------------------------------------
# 10b. CONTRATO DO --dry-run
# ---------------------------------------------------------------------------
#
# A REGRESSAO QUE ESTA SECAO IMPEDE: o orquestrador aceita --dry-run, anuncia
# que "nenhum emerge sera executado e nenhuma config sera escrita" e repassa
# DESKTOP_DRY_RUN=yes por ambiente. Honrar a variavel e responsabilidade de
# CADA numerado — e houve um periodo em que so a 10a a consultava. Nesse
# periodo o --dry-run rodava emerge de verdade, escrevia /etc/portage,
# habilitava servicos com rc-update e gravava dotfiles no $HOME. Uma flag cujo
# proposito e seguranca prometendo o contrario do que faz.
#
# Os numerados 10-15 usam a guarda unica dry_run_guard (sai com 0, para o
# dry-run percorrer o modulo inteiro). A 10a e a excecao deliberada: ela guarda
# inline, colada no eselect/emerge, com die.

# Numerados que usam a guarda unica no topo da secao de execucao.
DRY_GUARDED=(10-portage-desktop.sh 11-nvidia-wayland.sh 12-niri-stack.sh
             13-services.sh 14-dotfiles.sh 15-validate.sh)

# dry_run_guard_args <arquivo>: os nomes de sub-etapa passados ao dry_run_guard,
# um por linha. O `sed` de rotulo junta as continuacoes com barra invertida
# antes de separar, porque as chamadas mais longas ocupam duas linhas.
dry_run_guard_args() {
    sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}' "$1" \
        | grep -E '^dry_run_guard[[:space:]]' \
        | head -n1 | sed 's/^dry_run_guard[[:space:]]*//' \
        | tr -s '[:space:]' '\n' | grep -v '^$'
}

# run_step_names <arquivo>: os nomes de sub-etapa realmente executados.
run_step_names() { grep -E '^run_step[[:space:]]' "$1" | awk '{print $2}'; }

# A biblioteca oferece a guarda, e ela sai com 0 em vez de morrer. Se alguem a
# "consertar" trocando o exit por die, o --dry-run volta a abortar na etapa 10 e
# nunca mostra a 11-15 — o teste existe para pegar exatamente essa troca.
if declare -f >/dev/null 2>&1 && grep -qE '^dry_run_guard\(\) \{' "$LIBD"; then
    ok "lib-desktop.sh define dry_run_guard"
    guard_body="$(extract_fn "$LIBD" dry_run_guard)"
    assert_contains "$guard_body" 'DESKTOP_DRY_RUN' "dry_run_guard consulta DESKTOP_DRY_RUN"
    assert_contains "$guard_body" 'exit 0' "dry_run_guard sai com 0 (deixa o orquestrador seguir para a proxima etapa)"
    assert_not_contains "$guard_body" 'die ' "dry_run_guard nao usa die (die abortaria o dry-run na primeira etapa)"
else
    no "lib-desktop.sh define dry_run_guard" "sem ela nenhum numerado honra o --dry-run"
fi

for b in "${DRY_GUARDED[@]}"; do
    f="$DESKTOP_DIR/$b"
    [[ -f "$f" ]] || { no "$b honra DESKTOP_DRY_RUN" "arquivo ausente"; continue; }

    # 1. A guarda existe e vem ANTES do primeiro run_step. Depois seria tarde:
    #    o primeiro run_step ja executa o do_fn, que e onde mora o efeito.
    g="$(grep -nE '^dry_run_guard[[:space:]]' "$f" | head -n1 | cut -d: -f1)"
    r="$(grep -nE '^run_step[[:space:]]'      "$f" | head -n1 | cut -d: -f1)"
    if [[ -n "$g" && -n "$r" ]] && (( g < r )); then
        ok "$b chama dry_run_guard antes do primeiro run_step (linha $g < $r)"
    else
        no "$b chama dry_run_guard antes do primeiro run_step" \
           "dry_run_guard na linha '${g:-nenhuma}', primeiro run_step na linha '${r:-nenhuma}'"
    fi

    # 2. A lista anunciada e a lista executada tem de ser a MESMA, na mesma
    #    ordem. Sem isto o dry-run vira documentacao que envelhece sozinha:
    #    alguem acrescenta um run_step e o plano impresso passa a mentir por
    #    omissao — justamente no comando que o usuario roda para se informar.
    anunciadas="$(dry_run_guard_args "$f")"
    executadas="$(run_step_names "$f")"
    if [[ "$anunciadas" == "$executadas" ]]; then
        ok "$b anuncia no dry_run_guard exatamente as sub-etapas que executa"
    else
        no "$b anuncia no dry_run_guard exatamente as sub-etapas que executa" \
           "anunciadas: [$(tr '\n' ' ' <<< "$anunciadas")] vs executadas: [$(tr '\n' ' ' <<< "$executadas")]"
    fi
done

# A 10a guarda inline, colada no efeito, com die — padrao diferente e proposital
# (ver o comentario do dry_run_guard). O que nao pode e a guarda sumir.
PW="$DESKTOP_DIR/10a-profile-world.sh"
if [[ -f "$PW" ]]; then
    n_guardas="$(grep -cE 'DESKTOP_DRY_RUN' "$PW" || true)"
    if (( n_guardas >= 2 )); then
        ok "10a-profile-world.sh mantem as guardas inline de DESKTOP_DRY_RUN ($n_guardas referencias)"
    else
        no "10a-profile-world.sh mantem as guardas inline de DESKTOP_DRY_RUN" \
           "encontrei $n_guardas referencia(s); esperado ao menos 2 (troca de perfil e emerge @world)"
    fi
fi

# A ASERCAO CENTRAL, e a que resume a regressao: todo numerado que executa
# emerge tem de honrar DESKTOP_DRY_RUN. Sem ela, um script novo (ou um refactor
# que remova a guarda) volta a compilar durante um --dry-run.
#
# "Honrar" vale das DUAS formas legitimas: a guarda unica dry_run_guard (10-15)
# ou a consulta inline a variavel (10a). Exigir o literal DESKTOP_DRY_RUN em
# todo arquivo puniria justamente o refactor que centralizou a guarda.
#
# CUIDADO DE IMPLEMENTACAO — nao troque este `grep -E ... || true` por um
# `grep -q` dentro de pipe: com o `set -o pipefail` do topo deste arquivo, o
# grep -q sai no primeiro casamento, o SIGPIPE mata o `grep -v` do strip_noise e
# o status 141 vaza para o `if`. O teste passa a reportar "nao executa emerge"
# de forma dependente de buffering — verde por acidente, que e pior que vermelho.
# Os demais testes deste arquivo usam este mesmo padrao pelo mesmo motivo.
for f in "${DESKTOP_ACTION[@]}"; do
    b="$(basename "$f")"
    [[ "$b" == "install-desktop.sh" ]] && continue
    hits="$(strip_noise "$f" | grep -nE '(^|[^[:alnum:]_./-])emerge([[:space:]]|$)' || true)"
    if [[ -z "$hits" ]]; then
        ok "$b nao executa emerge (nada a guardar contra o --dry-run)"
        continue
    fi
    if grep -qE '(DESKTOP_DRY_RUN|^dry_run_guard[[:space:]])' "$f"; then
        ok "$b executa emerge E honra DESKTOP_DRY_RUN"
    else
        no "$b executa emerge E honra DESKTOP_DRY_RUN" \
           "o --dry-run compilaria de verdade neste script"
    fi
done

# O outro lado da plumbing: se o orquestrador parar de repassar a variavel, as
# guardas dos numerados ficam corretas e inertes ao mesmo tempo.
if grep -q 'DESKTOP_DRY_RUN=\$DRY_RUN' "$ORQ"; then
    ok "install-desktop.sh repassa DESKTOP_DRY_RUN aos numerados"
else
    no "install-desktop.sh repassa DESKTOP_DRY_RUN aos numerados" \
       "sem o repasse as guardas dos numerados nunca disparam"
fi

# ---------------------------------------------------------------------------
# 11. HIGIENE DE SHELL
# ---------------------------------------------------------------------------
# set -euo pipefail em todo script executavel (contrato do projeto).
for f in "${DESKTOP_ACTION[@]}"; do
    if grep -qE '^set -euo pipefail' "$f"; then
        ok "$(basename "$f") usa set -euo pipefail"
    else
        no "$(basename "$f") usa set -euo pipefail" "falha silenciosa e o risco"
    fi
done

# bash -n em tudo (o runner cobre *.sh da raiz e tests/, mas nao desktop/).
for f in "${DESKTOP_ALL[@]}"; do
    if bash -n "$f" 2>/dev/null; then
        ok "$(basename "$f") passa em bash -n"
    else
        no "$(basename "$f") passa em bash -n" "$(bash -n "$f" 2>&1 | head -3)"
    fi
done

rm -rf "$sent_tmp"

# ===========================================================================
# Ciclo bare metal (2026-09-02) — regressoes achadas executando o modulo
# ===========================================================================
# Cada bloco guarda um bug REAL que so apareceu rodando o desktop/ no hardware.
# Os que NAO sao detectaveis estaticamente estao listados no VALIDACAO.md 5.x.
printf '\n  -- regressoes do ciclo bare metal --\n'

# --- Bug 11: 00cpu-flags no formato do package.use, nao no do humano --------
# cpuid2cpuflags imprime "CPU_FLAGS_X86: aes avx" (dois-pontos, para humano).
# O package.use exige */* CPU_FLAGS_X86="aes avx". Gravar a saida crua produzia
# arquivo que o Portage ignora e que o probe nunca reconhece.
cpuf="$(extract_fn "$DESKTOP_DIR/10-portage-desktop.sh" do_cpu_flags)"
if [[ -z "$cpuf" ]]; then
    no "do_cpu_flags nao existe em 10-portage-desktop.sh"
else
    if grep -q 'CPU_FLAGS_X86="' <<< "$cpuf"; then
        ok "do_cpu_flags gera CPU_FLAGS_X86=\"...\" (sintaxe do package.use)"
    else
        no "do_cpu_flags nao gera a sintaxe CPU_FLAGS_X86=\"...\"" \
           "gravar a saida crua do cpuid2cpuflags produz ':' e o Portage ignora a linha"
    fi
    # O gerador e o probe tem de falar do MESMO formato.
    cpup="$(extract_fn "$DESKTOP_DIR/10-portage-desktop.sh" probe_cpu_flags)"
    if grep -q 'CPU_FLAGS_X86=' <<< "$cpup"; then
        ok "probe_cpu_flags procura o mesmo formato que do_cpu_flags grava"
    else
        no "probe_cpu_flags e do_cpu_flags divergem no formato"
    fi
    # Teste FUNCIONAL da conversao: a saida real do cpuid2cpuflags, convertida.
    conv="$(sed 's/^CPU_FLAGS_X86: /*\/* CPU_FLAGS_X86="/; s/$/"/' \
            <<< 'CPU_FLAGS_X86: aes avx avx2 f16c fma3 mmx mmxext pclmul popcnt sse')"
    assert_eq '*/* CPU_FLAGS_X86="aes avx avx2 f16c fma3 mmx mmxext pclmul popcnt sse"' \
        "$conv" "a conversao produz exatamente a linha que o package.use espera"
fi

# --- Bug 13: terminal Wayland nao pode vir com backend X -------------------
gpu="$(extract_fn "$DESKTOP_DIR/10-portage-desktop.sh" gen_package_use)"
if grep -qE 'x11-terms/kitty .*wayland' <<< "$gpu"; then
    ok "gen_package_use declara USE do kitty (wayland)"
else
    no "gen_package_use nao declara USE do kitty" \
       "sem isso o kitty vem com o default do perfil (X) e arrasta a stack X11"
fi
if grep -qE 'x11-terms/kitty .*-X' <<< "$gpu"; then
    ok "o kitty tem -X explicito (sistema Wayland puro)"
else
    no "o kitty nao desliga X explicitamente"
fi

# --- Bug 14: atom multi-slot precisa de SLOT ao consultar IUSE -------------
# portageq best_visible / dev-cpp/gtkmm resolve para o slot 4.0, cujo IUSE nao
# tem 'wayland'. O waybar precisa do 3.0. Sem o slot a validacao consulta o
# pacote errado e reprova um flag que existe.
if grep -q 'dev-cpp/gtkmm' <<< "$gpu"; then
    if grep -q 'dev-cpp/gtkmm:3.0' <<< "$gpu"; then
        ok "gtkmm e referenciado com SLOT explicito (:3.0)"
    else
        no "gtkmm aparece sem SLOT em gen_package_use" \
           "best_visible resolveria o slot 4.0 e o IUSE consultado seria o errado"
    fi
fi
huf="$(extract_fn "$LIBD" have_use_flag)"
if grep -q 'SLOT' <<< "$huf"; then
    ok "have_use_flag avisa quando o atom nao declara SLOT"
else
    no "have_use_flag nao alerta sobre atom sem SLOT" \
       "um atom ambiguo volta a reprovar flags que existem, sem dizer por que"
fi

# --- Bug 15: cairo declarado UMA vez (X e -X colidem no slot 0) ------------
cairo_n="$(grep -cE '^[[:space:]]*_use_line x11-libs/cairo ' <<< "$gpu" || true)"
if (( cairo_n == 1 )); then
    ok "x11-libs/cairo e declarado exatamente uma vez ($cairo_n)"
else
    no "x11-libs/cairo declarado $cairo_n vezes" \
       "duas linhas com X e -X reproduzem o 'slot conflict: x11-libs/cairo:0' por escrito"
fi
for pair in "x11-libs/gtk+:wayland" "dev-libs/libdbusmenu:gtk3" "media-libs/mesa:wayland" "media-libs/freetype:harfbuzz"; do
    atom="${pair%%:*}"; flag="${pair##*:}"
    if grep -qE "_use_line ${atom//+/\\+} .*${flag}" <<< "$gpu"; then
        ok "cadeia transitiva declara ${atom}[${flag}]"
    else
        no "falta ${atom}[${flag}] em gen_package_use" "a etapa 12 aborta no autounmask"
    fi
done

# --- Bug 10: simbolos de cripto que o iwd cobra em RUNTIME -----------------
# Nao aparecem em falha de build: sem eles o iwd fica em 'crashed' no sistema
# ja instalado, e numa maquina so-Wi-Fi isso e um sistema sem rede.
frag="$REPO_DIR/kernel-fragment.config"
req04="$(sed -n '/local -a required=(/,/^    )/p' "$REPO_DIR/04-kernel.sh")"
if grep -qE '^[[:space:]]*net-wireless/iwd|ENABLE_WIFI' "$REPO_DIR/vars.sh" "$REPO_DIR/06-users-services.sh" > /dev/null 2>&1; then
    for sym in KEY_DH_OPERATIONS CRYPTO_CBC CRYPTO_DES CRYPTO_ECB CRYPTO_USER_API_SKCIPHER; do
        if grep -qx "CONFIG_$sym=y" "$frag"; then
            ok "kernel-fragment tem CONFIG_$sym=y (exigido pelo ell/iwd em runtime)"
        else
            no "CONFIG_$sym ausente ou nao built-in no fragmento" \
               "o iwd fica em 'crashed' depois do boot, sem rede para consertar"
        fi
        if grep -qE "^\s+$sym\b" <<< "$req04"; then
            ok "verify_kconfig exige $sym"
        else
            no "verify_kconfig nao exige $sym" \
               "um fragmento editado poderia remove-lo e so o primeiro boot acusaria"
        fi
    done
fi

# --- Bug 16: rota de audio depende do init script, nao so da versao --------
pa="$(extract_fn "$DESKTOP_DIR/13-services.sh" probe_audio_user_services)"
da="$(extract_fn "$DESKTOP_DIR/13-services.sh" do_audio_user_services)"
if grep -q 'svc_script_exists pipewire' <<< "$pa"; then
    ok "probe_audio_user_services considera a ausencia do init script"
else
    no "probe_audio_user_services so olha a versao do OpenRC" \
       "com USE=-system-service nao ha init script, e o probe cobra um servico impossivel"
fi
if grep -qE 'openrc_version_ge 0\.60 && svc_script_exists' <<< "$da"; then
    ok "do_audio_user_services exige as DUAS condicoes para a rota de servicos"
else
    no "do_audio_user_services decide a rota so pela versao do OpenRC" \
       "'OpenRC >= 0.60 => servicos de usuario' e falso quando nao ha init script"
fi

# --- Bug 17: gsettings precisa de barramento de sessao ---------------------
for fn in gsettings_get gsettings_set_checked; do
    body="$(extract_fn "$DESKTOP_DIR/14-dotfiles.sh" "$fn")"
    if grep -q 'dbus-run-session' <<< "$body"; then
        ok "$fn roda sob dbus-run-session"
    else
        no "$fn roda sem barramento de sessao" \
           "sem D-Bus o dconf usa backend em memoria: sai com 0 e o valor evapora"
    fi
done
if grep -q 'tail -1' <<< "$(extract_fn "$DESKTOP_DIR/14-dotfiles.sh" gsettings_get)"; then
    ok "gsettings_get filtra o ruido do dbus-daemon (tail -1)"
else
    no "gsettings_get nao filtra a saida do dbus-daemon" \
       "as linhas do daemon contaminam a captura e a comparacao falha com aspas duplicadas"
fi

# --- Bug 18: o perfil escrito pelo 13 e o shell posto pelo 14 --------------
# O 13 roda ANTES do 14. Escrever so no .bash_profile deixava o zsh (que o 14
# configura) sem o trecho, e /run/user/$UID nunca era criado: a sessao morria
# com 'RuntimeDirNotSet', um panic que nao aponta para o shell.
xpf="$(extract_fn "$DESKTOP_DIR/13-services.sh" _xdg_profile_files)"
if [[ -z "$xpf" ]]; then
    no "13-services nao tem _xdg_profile_files" \
       "o trecho de XDG_RUNTIME_DIR iria sempre para o .bash_profile"
else
    ok "13-services escolhe o arquivo de perfil por funcao dedicada"
    if grep -q 'zprofile' <<< "$xpf"; then
        ok "_xdg_profile_files contempla .zprofile (zsh nao le .bash_profile)"
    else
        no "_xdg_profile_files nao contempla zsh"
    fi
    if grep -q 'DESKTOP_SHELL' <<< "$xpf"; then
        ok "_xdg_profile_files considera o shell que a etapa 14 vai configurar"
    else
        no "_xdg_profile_files so olha o shell ATUAL" \
           "a 13 roda antes da 14, entao o shell atual ainda e o antigo"
    fi
fi
# Coerencia entre as duas etapas: o shell que a 14 configura tem de estar
# coberto pela 13.
sh14="$(extract_fn "$DESKTOP_DIR/14-dotfiles.sh" do_shell)"
if [[ -n "$sh14" ]] && grep -q 'zsh' <<< "$sh14"; then
    if grep -q 'zsh' <<< "$xpf"; then
        ok "o shell configurado pela 14 (zsh) e coberto pelo perfil escrito pela 13"
    else
        no "a 14 configura zsh mas a 13 nao escreve num perfil que o zsh le"
    fi
fi

# ===========================================================================
# Etapa 16 — Clavis Shell
# ===========================================================================
# Cada asercao abaixo guarda um achado concreto: ou uma armadilha do Portage
# confirmada lendo o ebuild, ou uma do CMake do upstream confirmada lendo o
# core/CMakeLists.txt. Nenhuma e generica.
printf '\n  -- 16-clavis --\n'

CLAVIS_SH="$DESKTOP_DIR/16-clavis.sh"
if [[ ! -f "$CLAVIS_SH" ]]; then
    no "16-clavis.sh existe"
else
    ok "16-clavis.sh existe"

    # --- Portage -----------------------------------------------------------
    # dev-libs/qtkeychain e SLOT="0/1". Escrever ':6' (que o ':6' do Qt sugere)
    # faz o Portage recusar o atom. O pacote e Qt6-only sem ter slot 6.
    # strip_noise ANTES do grep: o comentario deste proprio script explica a
    # armadilha e cita 'qtkeychain:6' textualmente. Grepar o arquivo cru faz o
    # teste casar com a documentacao dele mesmo — o bug recorrente numero 1
    # deste projeto (ARMADILHAS, e o 1.4 do Ciclo 1).
    if strip_noise "$CLAVIS_SH" | grep -qE 'qtkeychain:6'; then
        no "16-clavis usa dev-libs/qtkeychain:6, slot que NAO existe" \
           "o SLOT real e 0/1; o Portage recusa o atom"
    else
        ok "qtkeychain sem slot ':6' (o slot real e 0/1)"
    fi

    # O review adversarial pegou isto no rascunho: best_visible de dev-lang/python
    # sem slot escolhe Python 2.7.
    if strip_noise "$CLAVIS_SH" | grep -qE 'emerge[^|]*dev-lang/python([^:]|$)'; then
        no "16-clavis emerge dev-lang/python sem SLOT" \
           "best_visible escolheria o slot errado; o Portage ja garante um python3"
    else
        ok "nao emerge dev-lang/python (evita o slot errado)"
    fi

    use_block="$(extract_fn "$CLAVIS_SH" gen_clavis_use)"
    # vulkan NAO e default no qtbase, e o quickshell exige qtbase[dbus,vulkan].
    if grep -qE 'dev-qt/qtbase:6 .*vulkan' <<< "$use_block"; then
        ok "declara qtbase[vulkan] (nao e default, e o quickshell exige)"
    else
        no "falta qtbase[vulkan] em gen_clavis_use" "o emerge do quickshell para no autounmask"
    fi
    # pipewire NAO e default no libcava.
    if grep -qE 'media-sound/libcava .*pipewire' <<< "$use_block"; then
        ok "declara libcava[pipewire] (nao e default)"
    else
        no "falta libcava[pipewire]" "o plugin de cava do Clavis linka PkgConfig::Pipewire"
    fi
    # Toda linha de USE passa por validacao contra o IUSE real.
    if grep -qE 'have_use_flag' <<< "$(extract_fn "$CLAVIS_SH" _use_line_clavis)"; then
        ok "as USE do 16 sao validadas contra o IUSE real antes de escritas"
    else
        no "16-clavis escreve USE sem validar contra o IUSE"
    fi

    # media-sound/cava e media-sound/libcava instalam AMBOS /usr/bin/cava e nao
    # ha blocker declarado em nenhum dos dois ebuilds.
    if grep -q 'assert_no_cava_collision' "$CLAVIS_SH"; then
        ok "16-clavis detecta a colisao cava/libcava (ambos instalam /usr/bin/cava)"
    else
        no "16-clavis nao trata a colisao entre media-sound/cava e media-sound/libcava"
    fi

    # --- CMake do upstream -------------------------------------------------
    build_fn="$(extract_fn "$CLAVIS_SH" do_clavis_build)"
    # O upstream NAO tem install(TARGETS): o install COPIA os .so da build-tree.
    # Instalar sem compilar produz diretorio vazio e sai 0.
    ln_build="$(grep -n 'cmake --build' <<< "$build_fn" | head -1 | cut -d: -f1)"
    ln_inst="$(grep -n 'cmake --install' <<< "$build_fn" | head -1 | cut -d: -f1)"
    if [[ -n "$ln_build" && -n "$ln_inst" ]] && (( ln_build < ln_inst )); then
        ok "'cmake --build' vem antes de 'cmake --install' (o install copia da build-tree)"
    else
        no "install sem build antes (build=$ln_build install=$ln_inst)" \
           "sem install(TARGETS), instalar antes de compilar copia um diretorio vazio E SAI 0"
    fi
    # CLAVIS_CONFIG_INSTALL_DIR e RELATIVO por default: com PREFIX=/usr viraria
    # /usr/etc/xdg/..., que o XDG nao le.
    if grep -qE 'CLAVIS_CONFIG_INSTALL_DIR=/etc/' "$CLAVIS_SH"; then
        ok "CLAVIS_CONFIG_INSTALL_DIR passado como caminho ABSOLUTO"
    else
        no "CLAVIS_CONFIG_INSTALL_DIR nao e absoluto" \
           "o default e relativo e o CMake o ancora no prefixo: /usr/etc/xdg/... nao e lido pelo XDG"
    fi
    # BUILD_TESTING vem do modulo CTest com default ON.
    if grep -q 'BUILD_TESTING=OFF' "$CLAVIS_SH"; then
        ok "BUILD_TESTING=OFF (o CTest o liga por default e arrastaria Qt6::Test)"
    else
        no "BUILD_TESTING nao e desligado"
    fi

    # --- Python / PEP 668 --------------------------------------------------
    if grep -qE '(^|[^/[:alnum:]])pip install' "$CLAVIS_SH" \
       && ! grep -qE '\$(KEY_VENV|\{KEY_VENV\})/bin/pip install|"\$KEY_VENV/bin/pip" install' "$CLAVIS_SH"; then
        no "16-clavis roda 'pip install' fora do venv" \
           "o Gentoo marca o interpretador como EXTERNALLY-MANAGED (PEP 668)"
    else
        ok "pip so e usado de dentro do venv dedicado (PEP 668)"
    fi

    # --- keytop realmente opcional ----------------------------------------
    kt="$(extract_fn "$CLAVIS_SH" do_keytop)"
    if grep -q 'mark_done 16-keytop skipped' <<< "$kt"; then
        ok "falha do keytop grava desfecho e NAO derruba a etapa"
    else
        no "do_keytop nao registra o desfecho de falha" \
           "a sub-etapa reprovaria para sempre e travaria o operador numa parte opcional"
    fi

    # --- nao escrever config do upstream ----------------------------------
    # Os servicos do Clavis sao self-healing: criam os defaults no primeiro
    # start. Materializar os JSON aqui so criaria divergencia a cada versao.
    if strip_noise "$CLAVIS_SH" | grep -qE '\.config/clavis/[a-z-]+\.json'; then
        no "16-clavis escreve JSON em ~/.config/clavis" \
           "o upstream cria os defaults sozinho; escrever aqui diverge a cada versao"
    else
        ok "nao escreve ~/.config/clavis (o upstream materializa os defaults)"
    fi
fi

# --- registro no orquestrador ---------------------------------------------
# O review adversarial classificou "etapa nao registrada" como bloqueador: o
# script existiria e nunca rodaria.
ORQ="$DESKTOP_DIR/install-desktop.sh"
ordem="$(grep -m1 '^ORDEM_ETAPAS=' "$ORQ")"
if grep -q '16' <<< "$ordem"; then
    ok "a etapa 16 esta em ORDEM_ETAPAS"
else
    no "a etapa 16 nao esta em ORDEM_ETAPAS" "o script existiria e nunca seria executado: $ordem"
fi
# A 16 depende do config.kdl que a 14 cria — tem de vir DEPOIS dela.
seq="$(sed -n 's/^ORDEM_ETAPAS=(\(.*\))/\1/p' "$ORQ")"
pos14=-1; pos16=-1; i=0
for n in $seq; do
    [[ "$n" == "14" ]] && pos14=$i
    [[ "$n" == "16" ]] && pos16=$i
    i=$((i + 1))
done
if (( pos14 >= 0 && pos16 > pos14 )); then
    ok "a etapa 16 roda depois da 14 (ela exige o config.kdl que a 14 cria)"
else
    no "ordem errada: 16 nao vem depois de 14 (14=$pos14 16=$pos16)" \
       "os scripts do Clavis que inserem os includes abortam com exit 3 sem o config.kdl"
fi
for fn in step_script step_desc; do
    if grep -qE '16\)' <<< "$(extract_fn "$ORQ" "$fn")"; then
        ok "$fn conhece a etapa 16"
    else
        no "$fn nao conhece a etapa 16"
    fi
done

# ===========================================================================
# Clavis como shell PADRAO — derivacao, binds e resgate
# ===========================================================================
# A revisao adversarial desta mudanca produziu tres achados que so um teste
# impede de voltar: a derivacao ignorar o override do operador, o gate da 15
# por marker (que o run_step grava mesmo sem o do_fn rodar) e o bind gerado
# para um binario inexistente.
printf '\n  -- Clavis como padrao --\n'

VARS_D="$DESKTOP_DIR/vars-desktop.sh"

# --- matriz de derivacao, FUNCIONAL (o arquivo e sourced de verdade) -------
derive() {
    env -i PATH="$PATH" HOME=/tmp USERNAME=x $1 \
        bash -c 'source "$0" 2>/dev/null; printf "%s|%s|%s|%s" "$DESKTOP_CLAVIS" "$DESKTOP_BAR" "$DESKTOP_NOTIFY" "$DESKTOP_LAUNCHER"' "$VARS_D"
}
assert_eq "yes|none|none|fuzzel" "$(derive '')" \
    "default: Clavis ligado, barra e notify derivados para none, fuzzel MANTIDO"
assert_eq "no|waybar|mako|fuzzel" "$(derive 'DESKTOP_CLAVIS=no')" \
    "DESKTOP_CLAVIS=no restaura o caminho antigo por inteiro"
assert_eq "yes|waybar|none|fuzzel" "$(derive 'DESKTOP_BAR=waybar')" \
    "escolha explicita do operador VENCE a derivacao"
assert_eq "yes|none|mako|fuzzel" "$(derive 'DESKTOP_NOTIFY=mako')" \
    "override explicito tambem vale para o notify (mesmo sendo ma ideia)"

# A sentinela tem de ser gravada ANTES do primeiro ':=' das variaveis que ela
# observa — depois dele, ${VAR+x} esta sempre setado e a derivacao ou nunca
# dispara, ou dispara sempre ignorando o operador.
ln_sent="$(grep -n '_DESKTOP_BAR_SET=' "$VARS_D" | head -1 | cut -d: -f1)"
ln_assign="$(grep -n '"\${DESKTOP_BAR:=' "$VARS_D" | head -1 | cut -d: -f1)"
if [[ -n "$ln_sent" && -n "$ln_assign" ]] && (( ln_sent < ln_assign )); then
    ok "a sentinela de DESKTOP_BAR e gravada antes do ':=' (a ordem e load-bearing)"
else
    no "sentinela depois do ':=' (sentinela=$ln_sent assign=$ln_assign)" \
       "o ':=' atribui a variavel; depois dele nao ha como saber se o operador opinou"
fi

# --- o fuzzel e rede de seguranca, nao sobra ------------------------------
# Ele nao e daemon e nao disputa nome no D-Bus — o argumento que obriga o mako
# a sair nao se aplica a ele. Manter da uma rota grafica que nao compartilha
# ponto de falha nenhum com o Clavis.
if grep -qE 'DESKTOP_LAUNCHER=none' "$VARS_D"; then
    no "a derivacao desliga o DESKTOP_LAUNCHER" \
       "o fuzzel e a unica rota grafica independente do Clavis; sem ele, shell morto = nada abre"
else
    ok "a derivacao NAO desliga o launcher (fuzzel fica como resgate)"
fi

lb="$(extract_fn "$DESKTOP_DIR/14-dotfiles.sh" niri_binds_launcher)"
if [[ -z "$lb" ]]; then
    no "14-dotfiles nao tem niri_binds_launcher"
else
    ok "14-dotfiles gera os binds de launcher por funcao dedicada"
    # O comando de IPC e literal do upstream (AppShell.qml), nao inventado.
    if grep -qE '"key" "ipc" "call" "spotlight" "toggle"' <<< "$lb"; then
        ok "Mod+D chama o spotlight do Clavis por IPC"
    else
        no "o bind do spotlight nao usa o comando de IPC do upstream"
    fi
    if grep -q 'Mod+Shift+Space' <<< "$lb" && grep -q 'spawn "fuzzel"' <<< "$lb"; then
        ok "existe bind de RESGATE para o fuzzel, independente do Clavis"
    else
        no "nao ha bind de resgate" "com o Clavis morto, o Mod+D nao faz nada e nao sobra rota grafica"
    fi
    # BUG REAL corrigido: DESKTOP_LAUNCHER=none gerava `spawn "none"`.
    if grep -qE 'spawn "\$DESKTOP_LAUNCHER"' <<< "$lb" \
       && ! grep -q 'DESKTOP_LAUNCHER" == "none"' <<< "$lb"; then
        no "o bind de launcher volta a gerar spawn com valor nao guardado" \
           "com DESKTOP_LAUNCHER=none o config.kdl saia com spawn \"none\""
    else
        ok "o valor 'none' do launcher e guardado (nao gera mais spawn \"none\")"
    fi
fi

# --- o gate da 15 nao pode ser por marker ---------------------------------
# run_step grava o marker quando o PROBE passa, mesmo sem o do_fn rodar, e
# mark_done sem valor grava a string 'done'. step_value nunca falha (|| true),
# entao usa-lo direto num `if` e sempre verdadeiro.
v15="$DESKTOP_DIR/15-validate.sh"
if grep -qE 'if[^\n]*step_(done|value) 16-clavis' "$v15"; then
    no "15-validate condiciona os checks do Clavis a um MARKER" \
       "o run_step grava o marker sem o do_fn rodar; use o artefato no disco"
else
    ok "15-validate nao usa marker como gate do Clavis"
fi
if grep -q '/etc/xdg/quickshell/clavis/shell.qml' "$v15"; then
    ok "15-validate usa o artefato no disco como prova de instalacao"
else
    no "15-validate nao verifica o shell.qml instalado"
fi
# A 15 roda ANTES da 16: Clavis ausente tem de ser AVISO, nunca FALHA, senao a
# instalacao limpa aborta antes de o Clavis poder ser instalado.
clavis_15="$(sed -n '/DESKTOP_CLAVIS" == "yes"/,/O Exec do .desktop/p' "$v15")"
if grep -qE 'check_warn "DESKTOP_CLAVIS=yes mas o Clavis ainda nao' <<< "$clavis_15"; then
    ok "Clavis ausente e AVISO (a 15 roda antes da 16 na sequencia)"
else
    no "Clavis ausente nao e tratado como aviso" \
       "a 15 vem antes da 16 no ORDEM_ETAPAS: check_fail abortaria toda instalacao limpa"
fi
# O PATH que importa e o do usuario, nao o do root.
if grep -q 'run_as_user command -v key' "$v15"; then
    ok "a checagem do 'key' consulta o PATH do usuario, nao o do root"
else
    no "a checagem do 'key' usa o PATH errado" "quem invoca o spawn-at-startup e a sessao do usuario"
fi

# --- migracao: avisar sem quebrar -----------------------------------------
am="$(extract_fn "$DESKTOP_DIR/14-dotfiles.sh" audit_clavis_migration)"
if [[ -z "$am" ]]; then
    no "14-dotfiles nao audita a migracao"
else
    ok "14-dotfiles audita o config.kdl existente contra a escolha de shell"
    if grep -q 'mako' <<< "$am"; then
        ok "a auditoria detecta o mako sobrevivente (disputa de org.freedesktop.Notifications)"
    else
        no "a auditoria nao detecta o mako" "e o unico dos tres que causa falha silenciosa"
    fi
    if grep -qE '\bdie\b' <<< "$am"; then
        no "a auditoria de migracao usa die" "o config.kdl e do usuario: avisa-se, nao se aborta"
    else
        ok "a auditoria so avisa, nunca aborta nem edita"
    fi
fi
# Fora do run_step: com config.kdl existente o probe passa e o do_fn nunca roda.
if grep -qE '^audit_clavis_migration$' "$DESKTOP_DIR/14-dotfiles.sh"; then
    ok "a auditoria roda fora do run_step (senao nunca seria alcancada)"
else
    no "audit_clavis_migration nao e chamada no nivel do script"
fi

finish
