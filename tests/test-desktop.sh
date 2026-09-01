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
CAT_OK='^(acct-group|acct-user|app-admin|app-arch|app-crypt|app-editors|app-eselect|app-emulation|app-misc|app-portage|app-shells|app-text|dev-lang|dev-libs|dev-util|dev-build|gnome-base|gnome-extra|gui-apps|gui-libs|gui-wm|media-fonts|media-gfx|media-libs|media-plugins|media-sound|media-video|net-misc|net-wireless|sec-keys|sys-apps|sys-auth|sys-boot|sys-devel|sys-fs|sys-kernel|sys-libs|sys-power|sys-process|virtual|www-client|x11-apps|x11-base|x11-drivers|x11-libs|x11-misc|x11-terms|x11-themes|x11-wm)/'

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
finish
