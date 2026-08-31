#!/usr/bin/env bash
#
# 01-stage3.sh — download, verificacao e extracao do stage3 (fase live).
#
# Implementa o capitulo "Instalando os arquivos de instalacao do Gentoo" do
# Handbook AMD64 (Installation/Stage) em quatro sub-etapas idempotentes:
#   01-gpg-key  -> importa a chave do releng e CONFERE o fingerprint
#   01-download -> pointer clearsigned + tarball + .asc + .sha256
#   01-verify   -> gpg --verify (.asc e .sha256) + sha256sum --check + tamanho
#   01-extract  -> tar xpf ... -C $TARGET_ROOT (marker grava o flavor)
#
# Antes das sub-etapas ha um sanity check do relogio (Handbook "Setting the
# date and time"): relogio muito atrasado quebra o TLS do download e a
# verificacao GPG com erros cripticos.
#
# Qualquer falha de verificacao e FATAL e deleta o tarball baixado.
# Trocar INIT_SYSTEM depois do extract e fatal: exige ./install.sh --reset
# com wipe do disco (--reset --repartition).
#
# Se a arvore do stage3 ja esta extraida e integra, download/verificacao sao
# pulados por inteiro: a limpeza final ("Removing tarballs" do Handbook) pode
# remover o tarball sem que um resume re-baixe ~300MB a toa.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/vars.sh"
source "$SCRIPT_DIR/lib.sh"
init_logging 01-stage3
require_phase live
validate_vars

# O stage3 e baixado para DENTRO do filesystem alvo (nao para o tmpfs do live
# ISO): sobrevive a reboot do live e nao consome RAM. O 00 ja montou o alvo;
# ensure_target_mounts so restaura os mounts se o live ISO rebootou no meio.
ensure_target_mounts
attach_log_to_target

# ---------------------------------------------------------------------------
# Area de trabalho e constantes derivadas
# ---------------------------------------------------------------------------

WORKDIR="$TARGET_ROOT/var/tmp/gentoo-install/stage3"
AUTOBUILDS_URL="$MIRROR/releases/amd64/autobuilds"
# O nome do pointer inclui o flavor: trocar INIT_SYSTEM invalida o probe do
# download naturalmente (o pointer do outro flavor nao existe no workdir).
POINTER="$WORKDIR/latest-stage3-amd64-${INIT_SYSTEM}.txt"
POINTER_VERIFIED="$POINTER.verified"
mkdir -p "$WORKDIR"

# GNUPGHOME dedicado dentro do workdir: nao depende do keyring do live ISO e
# sobrevive a reboot (o probe do 01-gpg-key continua funcional apos reboot).
export GNUPGHOME="$WORKDIR/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
GPG=(gpg --batch --no-tty)

# Globais preenchidas por load_stage3_info a partir do pointer verificado.
STAGE3_REL_PATH=""
STAGE3_SIZE=""
TARBALL=""
TARBALL_ASC=""
TARBALL_SHA256=""
SHA256_VERIFIED=""

# fetch <url> <destino>: baixa com wget (fallback curl), com resume (-c/-C -)
# e destino atomico (.part -> mv). Ambos existem no minimal install ISO.
fetch() {
    local url="$1" out="$2"
    if command -v wget >/dev/null 2>&1; then
        # dot:giga = progresso compacto (o stdout passa pelo tee do logging)
        wget --progress=dot:giga -c -O "${out}.part" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -fL -C - -o "${out}.part" "$url"
    else
        die "nem wget nem curl disponiveis para download"
    fi
    mv -f "${out}.part" "$out"
}

# load_stage3_info: parseia o pointer JA VERIFICADO (payload extraido por
# `gpg --output`, sem armadura clearsign) e preenche as globais do tarball.
# Formato das linhas de dados: "<caminho relativo> <tamanho em bytes>".
# Retorna 1 se o pointer (ainda) nao existe ou nao tem exatamente 1 linha valida.
load_stage3_info() {
    local matches
    [[ -s "$POINTER_VERIFIED" ]] || return 1
    # So aceita o tarball do flavor corrente (timestamp puro no nome, o que
    # exclui variantes tipo -splitusr-) com tamanho numerico na 2a coluna.
    matches="$(awk -v flavor="$INIT_SYSTEM" '
        /^#/ { next }
        $1 ~ ("(^|/)stage3-amd64-" flavor "-[0-9TZ]+\\.tar\\.xz$") && $2 ~ /^[0-9]+$/ { print $1, $2 }
    ' "$POINTER_VERIFIED")"
    [[ -n "$matches" && "$(wc -l <<<"$matches")" -eq 1 ]] || return 1
    STAGE3_REL_PATH="${matches%% *}"
    STAGE3_SIZE="${matches##* }"
    TARBALL="$WORKDIR/$(basename "$STAGE3_REL_PATH")"
    TARBALL_ASC="$TARBALL.asc"
    TARBALL_SHA256="$TARBALL.sha256"
    SHA256_VERIFIED="$TARBALL.sha256.verified"
    return 0
}

# ===========================================================================
# Sanity do relogio — Handbook: "Setting the date and time". Num desktop novo
# ou com bateria CMOS fraca o live ISO pode subir com data absurda: o fetch
# https falha com erro criptico de certificado e o gpg rejeita chave/assinatura
# ("no futuro" ou "expirada"). Melhor falhar cedo apontando a causa raiz.
# NAO e sub-etapa com marker de proposito: o relogio precisa ser conferido em
# TODO run que baixa/verifica (a hora pode regredir entre reboots do live ISO).
# ===========================================================================

# Data de referencia embutida (geracao destes scripts): o relogio nunca pode
# estar ANTES dela.
CLOCK_REF_EPOCH=1788048000   # date -u -d '2026-08-30 00:00:00 UTC' +%s
CLOCK_REF_HUMAN="2026-08-30"

# Limite SUPERIOR: data de expiracao da chave releng (vars.sh:81). Um RTC
# corrompido para o futuro passava no piso e o gpg rejeitava a chave como
# "expirada" — exatamente o erro criptico que esta funcao existe para evitar.
# Instalar legitimamente depois desta data e possivel (a chave releng e
# rotacionada): por isso este limite so AVISA, apontando o relogio como causa
# provavel ANTES da mensagem do gpg. Atualize junto com RELENG_KEY_FPR.
CLOCK_KEY_EXPIRY_EPOCH=1846022400   # date -u -d '2028-07-01 00:00:00 UTC' +%s
CLOCK_KEY_EXPIRY_HUMAN="2028-07-01"

# _check_clock_upper: relogio depois da expiracao da chave releng. Nao e fatal
# (ver acima), mas o aviso precisa vir antes de qualquer chamada ao gpg.
_check_clock_upper() {
    local now
    now="$(date +%s)"
    (( now > CLOCK_KEY_EXPIRY_EPOCH )) || return 0
    log_warn "relogio do sistema marca $(date -u '+%Y-%m-%d %H:%M:%S UTC'), DEPOIS da expiracao ($CLOCK_KEY_EXPIRY_HUMAN) da chave releng RELENG_KEY_FPR=$RELENG_KEY_FPR"
    log_warn "se o gpg reclamar de chave/assinatura 'expirada' a seguir, a causa provavel e o relogio adiantado (bateria CMOS fraca / RTC corrompido) — confira com 'date -u' e acerte com 'chronyd -q'"
    log_warn "se a data estiver realmente correta, a chave releng foi rotacionada: atualize RELENG_KEY_FPR (https://www.gentoo.org/downloads/signatures/) e CLOCK_KEY_EXPIRY_EPOCH"
}

check_clock() {
    local now
    now="$(date +%s)"
    if (( now >= CLOCK_REF_EPOCH )); then
        _check_clock_upper
        return 0
    fi
    log_warn "relogio do sistema atrasado: agora e $(date -u '+%Y-%m-%d %H:%M:%S UTC'), anterior a referencia $CLOCK_REF_HUMAN"
    # Tenta acertar sozinho com o que a midia oferecer (o minimal ISO traz
    # chrony); timeout para nao travar indefinidamente sem rede.
    if command -v chronyd >/dev/null 2>&1; then
        log_info "tentando sincronizar com 'chronyd -q'..."
        timeout 60 chronyd -q || log_warn "'chronyd -q' falhou (sem rede ou NTP bloqueado?)"
    elif command -v ntpd >/dev/null 2>&1; then
        log_info "tentando sincronizar com 'ntpd -q -g'..."
        timeout 60 ntpd -q -g || log_warn "'ntpd -q -g' falhou (sem rede ou NTP bloqueado?)"
    fi
    now="$(date +%s)"
    (( now >= CLOCK_REF_EPOCH )) \
        || die "relogio do sistema esta antes de $CLOCK_REF_HUMAN — TLS e verificacao GPG do stage3 falhariam. Acerte a hora (ex.: 'chronyd -q' com rede, ou 'date MMDDhhmmYYYY' como no Handbook) e rode o script de novo"
    # O sync pode ter corrigido o piso mas deixado o relogio acima da expiracao.
    _check_clock_upper
}

# ===========================================================================
# Sub-etapa 01-gpg-key — Handbook: "Verifying and validating" (a chave do
# Release Engineering assina o pointer, o .asc e o .sha256; o fingerprint
# esperado vem de https://www.gentoo.org/downloads/signatures/).
# ===========================================================================

# _key_fingerprint_ok: o keyring contem EXATAMENTE UMA chave primaria e ela e
# RELENG_KEY_FPR? Presenca nao basta: todo `gpg --verify` daqui pra frente
# aceita QUALQUER chave do keyring, entao a propriedade que precisamos e
# exclusividade. Lista o keyring INTEIRO (sem filtrar por fingerprint, senao a
# consulta esconderia justamente as chaves extras), conta os registros "pub" e
# casa o "fpr" que segue cada "pub" (o 1o fpr apos um pub e o da primaria; os
# seguintes sao de subchaves). Nao confia no exit code do --list-keys.
# Fail-closed: keyring vazio/ilegivel => nenhum pub => retorna 1.
_key_fingerprint_ok() {
    "${GPG[@]}" --with-colons --list-keys 2>/dev/null \
        | awk -F: -v want="$RELENG_KEY_FPR" '
            $1 == "pub" { pub++; primary = 1; next }
            $1 == "fpr" && primary { got = toupper($10); primary = 0 }
            END { exit !(pub == 1 && got == toupper(want)) }
        '
}

probe_gpg_key() {
    _key_fingerprint_ok
}

do_gpg_key() {
    # Keyring reconstruido do ZERO a cada execucao: sem isto um keyring poluido
    # (import anterior de arquivo com N chaves) nunca seria descartado, e como o
    # $GNUPGHOME vive no WORKDIR dentro do alvo — sobrevive a reboot e a
    # ./install.sh --reset, que so apaga o state dir — o estado sujo se
    # perpetuaria a cada re-execucao.
    rm -rf "$GNUPGHOME"
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"

    # 1a opcao: keyserver oficial do Gentoo; fallback: chave embarcada na
    # midia oficial de instalacao (presente no minimal ISO).
    if "${GPG[@]}" --keyserver hkps://keys.gentoo.org --recv-keys "$RELENG_KEY_FPR"; then
        log_info "chave releng importada do keyserver hkps://keys.gentoo.org"
    elif [[ -r /usr/share/openpgp-keys/gentoo-release.asc ]]; then
        # O .asc da midia pode conter N chaves e o --import aceitaria TODAS,
        # cada uma virando autoridade valida para o stage3. Import em dois
        # tempos: keyring temporario descartavel recebe o arquivo inteiro, e de
        # la exportamos SOMENTE $RELENG_KEY_FPR para o keyring de verificacao —
        # que assim tem, por construcao, uma unica chave.
        log_warn "keyserver indisponivel — importando fallback /usr/share/openpgp-keys/gentoo-release.asc"
        # Declaracao SEPARADA da atribuicao: `local x="$(cmd)"` retorna o status
        # do `local` (0) e mascararia a falha do mktemp sob set -e, deixando o
        # caminho vazio para o rm -rf e o redirect adiante.
        local tmp_gnupghome tmp_rc=0
        tmp_gnupghome="$(mktemp -d "$WORKDIR/gnupg-fallback.XXXXXX")"
        [[ -n "$tmp_gnupghome" && -d "$tmp_gnupghome" ]] \
            || die "nao consegui criar keyring temporario para o fallback da chave releng"
        chmod 700 "$tmp_gnupghome"
        # Subshell: o GNUPGHOME alterado nao vaza para o resto do script.
        (
            export GNUPGHOME="$tmp_gnupghome"
            "${GPG[@]}" --import /usr/share/openpgp-keys/gentoo-release.asc >&2 || exit 1
            # --export com o fingerprint completo: so a releng sai daqui.
            "${GPG[@]}" --export "$RELENG_KEY_FPR"
        ) > "$tmp_gnupghome/releng.gpg" || tmp_rc=$?
        if (( tmp_rc == 0 )) && [[ -s "$tmp_gnupghome/releng.gpg" ]]; then
            "${GPG[@]}" --import "$tmp_gnupghome/releng.gpg" || tmp_rc=1
        else
            tmp_rc=1
        fi
        rm -rf "$tmp_gnupghome"
        (( tmp_rc == 0 )) \
            || die "fallback /usr/share/openpgp-keys/gentoo-release.asc nao contem a chave RELENG_KEY_FPR=$RELENG_KEY_FPR (ou o import falhou) — abortando"
    else
        die "nao consegui importar a chave releng: keyserver falhou e o fallback /usr/share/openpgp-keys/gentoo-release.asc nao existe"
    fi
    # Confere exclusividade + fingerprint contra RELENG_KEY_FPR; divergencia =
    # keyring inteiro descartado (nao deixamos chave suspeita para tras).
    if ! _key_fingerprint_ok; then
        rm -rf "$GNUPGHOME"
        die "keyring nao contem EXATAMENTE a chave RELENG_KEY_FPR=$RELENG_KEY_FPR (chave ausente, divergente ou chaves extras importadas) — keyring descartado, abortando"
    fi
}

# ===========================================================================
# Sub-etapa 01-download — Handbook: "Downloading the stage file". Baixa o
# pointer clearsigned latest-stage3-amd64-$INIT_SYSTEM.txt, verifica a
# assinatura, extrai o payload assinado com gpg --output, parseia
# caminho+tamanho e baixa tarball + .asc + .sha256.
# ===========================================================================

probe_download() {
    [[ -s "$POINTER" && -s "$POINTER_VERIFIED" ]] || return 1
    "${GPG[@]}" --verify "$POINTER" >/dev/null 2>&1 || return 1
    load_stage3_info || return 1
    [[ -s "$TARBALL" && -s "$TARBALL_ASC" && -s "$TARBALL_SHA256" ]] || return 1
    [[ "$(stat -c %s "$TARBALL")" -eq "$STAGE3_SIZE" ]] || return 1
}

do_download() {
    # O pointer e sempre re-baixado: e pequeno e aponta pro stage3 mais recente.
    rm -f "$POINTER" "$POINTER_VERIFIED"
    log_info "baixando pointer $AUTOBUILDS_URL/$(basename "$POINTER")"
    fetch "$AUTOBUILDS_URL/$(basename "$POINTER")" "$POINTER"

    # Verifica o clearsign; falha = fatal e deleta o pointer.
    if ! "${GPG[@]}" --verify "$POINTER"; then
        rm -f "$POINTER"
        die "assinatura GPG do pointer $(basename "$POINTER") INVALIDA — pointer deletado, abortando"
    fi
    # Extrai o payload ASSINADO (nunca parsear o clearsign cru).
    "${GPG[@]}" --yes --output "$POINTER_VERIFIED" --verify "$POINTER"

    load_stage3_info \
        || die "nao consegui parsear caminho+tamanho do stage3 no pointer verificado ($POINTER_VERIFIED)"
    log_info "stage3 mais recente: $STAGE3_REL_PATH ($STAGE3_SIZE bytes)"

    # Tarball com resume; pulado se ja esta completo (tamanho bate).
    if [[ -s "$TARBALL" && "$(stat -c %s "$TARBALL")" -eq "$STAGE3_SIZE" ]]; then
        log_info "tarball ja presente com o tamanho esperado — pulando re-download"
    else
        fetch "$AUTOBUILDS_URL/$STAGE3_REL_PATH" "$TARBALL"
    fi
    # .asc e .sha256 sempre frescos (pequenos; garante que casam com o tarball).
    rm -f "$TARBALL_ASC" "$TARBALL_SHA256" "$SHA256_VERIFIED"
    fetch "$AUTOBUILDS_URL/$STAGE3_REL_PATH.asc" "$TARBALL_ASC"
    fetch "$AUTOBUILDS_URL/$STAGE3_REL_PATH.sha256" "$TARBALL_SHA256"

    # Cross-check imediato do tamanho anunciado no pointer assinado.
    local actual_size
    actual_size="$(stat -c %s "$TARBALL")"
    if [[ "$actual_size" -ne "$STAGE3_SIZE" ]]; then
        rm -f "$TARBALL"
        die "tamanho do tarball ($actual_size bytes) difere do anunciado no pointer ($STAGE3_SIZE bytes) — tarball deletado, rode o script de novo"
    fi
}

# ===========================================================================
# Sub-etapa 01-verify — Handbook: "Verifying and validating the stage file":
#   1. gpg --verify tarball.asc tarball      (assinatura destacada)
#   2. gpg --output --verify tarball.sha256  (clearsign do arquivo de hash)
#   3. sha256sum --check                     (integridade do conteudo)
#   4. cross-check do tamanho anunciado no pointer
# Qualquer falha deleta o tarball (e artefatos) e aborta.
# ===========================================================================

# _tarball_hash_ok: recomputa o sha256 do tarball e compara com a linha
# correspondente do payload verificado do .sha256 (sem efeito colateral —
# usado pelo probe; o do_fn usa sha256sum --check, como no Handbook).
_tarball_hash_ok() {
    local name expected actual
    name="$(basename "$TARBALL")"
    [[ -s "$SHA256_VERIFIED" ]] || return 1
    expected="$(awk -v f="$name" '$2 == f && $1 ~ /^[0-9a-fA-F]{64}$/ { print tolower($1); exit }' "$SHA256_VERIFIED")"
    [[ -n "$expected" ]] || return 1
    actual="$(sha256sum "$TARBALL" | awk '{ print tolower($1) }')"
    [[ "$expected" == "$actual" ]]
}

probe_verify() {
    [[ -s "$TARBALL" && -s "$TARBALL_ASC" && -s "$TARBALL_SHA256" && -s "$SHA256_VERIFIED" ]] || return 1
    [[ "$(stat -c %s "$TARBALL")" -eq "$STAGE3_SIZE" ]] || return 1
    "${GPG[@]}" --verify "$TARBALL_ASC" "$TARBALL" >/dev/null 2>&1 || return 1
    "${GPG[@]}" --verify "$TARBALL_SHA256" >/dev/null 2>&1 || return 1
    _tarball_hash_ok
}

# verify_fail <motivo>: FALHA DE VERIFICACAO = fatal + deleta o tarball (e os
# artefatos derivados, para o proximo run re-baixar tudo limpo).
verify_fail() {
    log_error "falha de verificacao: $*"
    rm -f "$TARBALL" "$TARBALL.part" "$TARBALL_ASC" "$TARBALL_SHA256" "$SHA256_VERIFIED"
    die "tarball e artefatos de verificacao deletados — rode o script de novo para re-baixar"
}

do_verify() {
    local name checkfile="$WORKDIR/sha256.check" actual_size
    name="$(basename "$TARBALL")"

    # 1. assinatura destacada do tarball
    "${GPG[@]}" --verify "$TARBALL_ASC" "$TARBALL" \
        || verify_fail "assinatura GPG destacada (.asc) invalida para $name"

    # 2. clearsign do .sha256 — o payload assinado vai para $SHA256_VERIFIED
    "${GPG[@]}" --yes --output "$SHA256_VERIFIED" --verify "$TARBALL_SHA256" \
        || verify_fail "assinatura GPG do .sha256 invalida"

    # 3. sha256sum --check apenas na linha do tarball (o .sha256 pode listar
    # outros arquivos, ex.: .CONTENTS.gz, que nao baixamos)
    awk -v f="$name" '$2 == f && $1 ~ /^[0-9a-fA-F]{64}$/ { print $1 "  " f }' \
        "$SHA256_VERIFIED" > "$checkfile"
    [[ -s "$checkfile" ]] \
        || verify_fail "payload do .sha256 nao contem linha de hash para $name"
    (cd "$WORKDIR" && sha256sum --check --strict "$checkfile") \
        || verify_fail "sha256 do tarball NAO confere com o valor assinado"

    # 4. cross-check do tamanho anunciado no pointer assinado
    actual_size="$(stat -c %s "$TARBALL")"
    [[ "$actual_size" -eq "$STAGE3_SIZE" ]] \
        || verify_fail "tamanho do tarball ($actual_size bytes) difere do pointer ($STAGE3_SIZE bytes)"

    log_info "stage3 verificado com sucesso: assinatura .asc OK, .sha256 assinado OK, hash OK, tamanho OK"
}

# ===========================================================================
# Sub-etapa 01-extract — Handbook: "Unpacking the stage file".
# ===========================================================================

# Sentinela de extracao EM ANDAMENTO: criada antes do tar e removida so apos
# concluir. Vive no WORKDIR (nao no state dir) de proposito: sobrevive a
# ./install.sh --reset, entao a evidencia de extracao interrompida nao se
# perde junto com os markers.
EXTRACT_STARTED="$WORKDIR/extract-started"

# detect_flavor: heuristica funcional do flavor da arvore extraida em
# $TARGET_ROOT (stage3 systemd tem /lib/systemd/systemd; openrc nao).
detect_flavor() {
    if [[ -x "$TARGET_ROOT/lib/systemd/systemd" ]]; then
        echo systemd
    else
        echo openrc
    fi
}

# check_flavor_mismatch: trocar INIT_SYSTEM depois do extract e FATAL — o
# marker 01-extract carrega o flavor extraido e e a autoridade aqui.
check_flavor_mismatch() {
    local marked detected
    marked="$(step_value 01-extract)"
    if [[ -n "$marked" && "$marked" != "$INIT_SYSTEM" ]]; then
        die "o stage3 ja extraido em $TARGET_ROOT e '$marked', mas INIT_SYSTEM agora e '$INIT_SYSTEM'. Trocar de init no meio da instalacao NAO e suportado: rode ./install.sh --reset --repartition (apaga o state e o disco) ou volte INIT_SYSTEM para '$marked'."
    fi
    # Checagem funcional extra: marker presente mas a arvore extraida tem cara
    # de outro init? (marker mentindo / estado corrompido)
    if [[ -n "$marked" && -e "$TARGET_ROOT/etc/gentoo-release" ]]; then
        detected="$(detect_flavor)"
        [[ "$detected" == "$marked" ]] \
            || die "marker 01-extract diz '$marked' mas a arvore em $TARGET_ROOT parece ser '$detected' — estado inconsistente; rode ./install.sh --reset --repartition"
    fi
    # Marker AUSENTE (ex.: apos ./install.sh --reset) mas arvore ja extraida:
    # a guarda cai na mesma deteccao funcional — sem isto, trocar INIT_SYSTEM
    # + --reset simples passaria em silencio e o do_extract extrairia o flavor
    # novo POR CIMA da arvore antiga (estado 'mixed' que esta guarda existe
    # para impedir). Extracao interrompida (sentinela presente) fica de fora:
    # re-extrair por cima e o caminho legitimo de recuperacao, e o flavor de
    # uma arvore parcial nao e confiavel.
    if [[ -z "$marked" && -e "$TARGET_ROOT/etc/gentoo-release" && ! -e "$EXTRACT_STARTED" ]]; then
        detected="$(detect_flavor)"
        if [[ "$detected" != "$INIT_SYSTEM" ]]; then
            die "a arvore ja extraida em $TARGET_ROOT parece ser '$detected', mas INIT_SYSTEM agora e '$INIT_SYSTEM' (marker ausente — --reset?). Trocar de init no meio da instalacao NAO e suportado: rode ./install.sh --reset --repartition (apaga o state e o disco) ou volte INIT_SYSTEM para '$detected'."
        fi
    fi
}

# recover_extract_marker: cobre a perda do marker (ex.: ./install.sh --reset)
# SEM re-extrair por cima de um sistema possivelmente ja avancado — o tar
# sobrescreveria /etc/passwd, /etc/shadow, /etc/fstab, make.conf e faria
# downgrade de glibc/bash. Se a arvore existe, o flavor detectado bate com
# INIT_SYSTEM e NAO ha sentinela de extracao interrompida, regrava o marker
# com o flavor (mantendo o valor que check_flavor_mismatch exige). Chamada
# fora do probe para o probe continuar sem efeitos colaterais.
recover_extract_marker() {
    step_done 01-extract && return 0
    [[ -e "$EXTRACT_STARTED" ]] && return 0
    [[ -e "$TARGET_ROOT/etc/gentoo-release" ]] || return 0
    [[ "$(detect_flavor)" == "$INIT_SYSTEM" ]] || return 0
    log_warn "arvore do stage3 ($INIT_SYSTEM) ja presente em $TARGET_ROOT sem marker — regravando marker 01-extract em vez de re-extrair por cima"
    mark_done 01-extract "$INIT_SYSTEM"
}

probe_extract() {
    # Evidencia de extracao INTERROMPIDA -> re-extrai por cima (tar sobrescreve
    # a arvore parcial); e o UNICO caso em que re-extrair e seguro.
    [[ -e "$EXTRACT_STARTED" ]] && return 1
    # Estado real: a arvore do stage3 existe no alvo...
    [[ -e "$TARGET_ROOT/etc/gentoo-release" ]] || return 1
    # ...e o flavor DETECTADO na arvore bate com o INIT_SYSTEM corrente
    # (funcional-primeiro: nao depende do marker, que --reset apaga).
    [[ "$(detect_flavor)" == "$INIT_SYSTEM" ]]
}

do_extract() {
    log_info "extraindo $(basename "$TARBALL") em $TARGET_ROOT (leva alguns minutos)..."
    # Sentinela ANTES do tar: se a extracao for interrompida, o proximo run a
    # encontra e re-extrai por cima com seguranca.
    : > "$EXTRACT_STARTED"
    # Flags do Handbook: p preserva permissoes; --xattrs-include='*.*' preserva
    # xattrs/capabilities; --numeric-owner ignora o passwd do live ISO.
    tar xpf "$TARBALL" --xattrs-include='*.*' --numeric-owner -C "$TARGET_ROOT"
    rm -f "$EXTRACT_STARTED"
    # Marker com valor: registra o flavor extraido (openrc|systemd).
    mark_done 01-extract "$INIT_SYSTEM"
}

# ===========================================================================
# Execucao
# ===========================================================================

check_flavor_mismatch

# Marker perdido (--reset) com arvore ja extraida e flavor correto: regrava o
# marker em vez de deixar o do_extract re-extrair por cima do sistema.
recover_extract_marker

# Handbook "Removing tarballs" (Finalizing): a limpeza final do install.sh pode
# remover o WORKDIR (tarball ~300MB, .asc, .sha256, keyring) depois que a
# instalacao termina. Arvore ja extraida e integra => pular gpg-key/download/
# verify por inteiro: um resume pos-limpeza nao re-baixa nada, e o tarball ja
# consumido pela extracao nao precisa ser re-verificado.
if probe_extract; then
    log_info "[01-extract] arvore do stage3 ($INIT_SYSTEM) ja presente em $TARGET_ROOT — pulando download/verificacao/extracao"
else
    # Relogio confere ANTES de qualquer rede/GPG (Handbook "Setting the date
    # and time"); so importa no caminho que baixa/verifica.
    check_clock

    run_step 01-gpg-key  probe_gpg_key  do_gpg_key
    run_step 01-download probe_download do_download

    # O probe/do_fn do 01-download preencheu as globais via load_stage3_info
    # (executam no shell corrente); sanity check antes de seguir.
    [[ -n "$TARBALL" && -n "$STAGE3_SIZE" ]] \
        || die "estado interno inconsistente: info do stage3 nao carregada apos 01-download"

    run_step 01-verify   probe_verify   do_verify
    run_step 01-extract  probe_extract  do_extract
    log_info "stage3 $INIT_SYSTEM ($(basename "$TARBALL")) verificado e extraido em $TARGET_ROOT"
fi

attach_log_to_target
log_info "01-stage3 concluido: stage3 $INIT_SYSTEM pronto em $TARGET_ROOT"
