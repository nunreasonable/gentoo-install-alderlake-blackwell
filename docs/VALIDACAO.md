# VALIDACAO — registro completo dos testes e das correcoes

Este documento e o **historico factual** do que foi executado, o que quebrou e
o que foi corrigido. Ele existe para responder a uma pergunta especifica:
*"em que evidencia este instalador se apoia?"*

Regra deste arquivo: **so entra o que foi executado.** Nada aqui e inferido de
leitura de codigo.

---

## Resumo

| | |
|---|---|
| Ciclos completos em QEMU/OVMF | **3** (instalacao ponta a ponta + boot) — 2 em ext4, 1 em btrfs |
| Instalacoes em **bare metal** | **1 completa + boot** (2026-09-02), seguida do modulo `desktop/` e da etapa 16 (2026-09-03) |
| Bugs encontrados por execucao | **35** (34 no codigo, 1 de ergonomia) |
| Bugs encontrados por analise estatica | **0** dos 35 acima |
| Suite de testes do host | 13 grupos, **642 asercoes** |
| Validado em hardware fisico | Base + `desktop/` + etapa 16, **uma execucao cada**, com intervencao manual em 20 pontos |

O numero que mais importa esta na terceira linha. `bash -n`, ShellCheck e uma
auditoria adversarial multi-agente de 13 dimensoes passaram por cima de **todos
os trinta e cinco**. Cada um exigiu executar o codigo.

Duas ressalvas sobre a linha da suite, para ela nao virar promessa:

- O grupo **ShellCheck** so roda se `shellcheck` ou `podman` existirem. Na
  maquina onde estes numeros foram medidos (o proprio alvo instalado) **nenhum
  dos dois existe**, e o runner pulou o grupo anunciando `SKIP`.
- O grupo **test-desktop-dryrun** reprova neste host com
  `dry-run criou arquivo REAL fora do sandbox: /etc/portage/package.use/desktop-niri`.
  E falso positivo, e o proprio teste avisa: *"estes caminhos existiam antes? se
  sim, o teste e inconclusivo neste host"*. O arquivo e da instalacao real, de
  2026-09-03. **A suite so fecha em exit 0 num host que nao seja o alvo
  instalado** — vale dizer isso em vez de repetir "exit 0" sem qualificacao.

---

## Ciclo 1 — primeira instalacao completa (2026-09-01)

**Ambiente:** QEMU/OVMF, 6 vCPUs, disco **virtio** (`/dev/vda`) **em branco**,
`AUTO_CONFIRM=yes`, `NVIDIA_MODE=force`, OpenRC.

Resultado: instalacao completa e **boot do sistema instalado**. Cinco problemas
no caminho.

### 1.1 — Guarda de disco funcionando (nao era bug)

**Sintoma:** `TARGET_DISK=/dev/nvme0n1 nao existe ou nao pode ser resolvido`.

**Diagnostico:** a VM usa virtio (`/dev/vda`); o default de producao e NVMe. O
instalador **recusou adivinhar** o disco. Comportamento correto.

**Acao:** nada no instalador. O *workflow de teste* e que estava em prosa no
README, dependendo de o operador digitar a variavel. Criado
[`tests/qemu-profile.env`](../tests/qemu-profile.env) (fonte unica, fixa
`TARGET_DISK=/dev/vda`) e `tests/run-in-qemu-guest.sh`, que se recusa a rodar
fora de uma VM porque carrega `AUTO_CONFIRM=yes`.

**Commit:** `382457f` · **Testes:** `test-qemu-profile.sh`,
`test-target-disk-required.sh`

### 1.2 — `preflight_hardware` morria sem GPU NVIDIA

**Sintoma:** a tabela do preflight parava entre `placa` e `gpu`, com
`falha (exit 1) na sub-etapa '(fora de run_step)'`.

**Causa:** `lspci -d 10de: | grep ... | _pf_first_line`. Sem GPU NVIDIA no
barramento — o caso normal numa VM sem passthrough — o `grep` nao casa e sai
com 1, o `pipefail` propaga para a atribuicao e o `set -e` mata o preflight.
Ironia: tres linhas abaixo o codigo trata "sem NVIDIA" como aviso.

**Correcao:** `|| true` em quatro pipelines (`nv_line`, `nvme_ctrl`, `net_ctrl`,
`audio_ctrl`). Numa VM, tres deles disparariam em sequencia.

**Commit:** `b320368`

### 1.3 — `make install` gravava `/boot/vmlinuz` sem versao

**Sintoma:** `Cannot find LILO.` seguido de
`make install concluido mas /boot/vmlinuz-6.18.48-gentoo nao existe`.

**Causa:** faltava `sys-kernel/installkernel`. Sem `/sbin/installkernel`, o
fallback do proprio kernel copia o bzImage para `/boot/vmlinuz` **sem sufixo de
versao**, tenta o LILO, e **sai com 0**. O `make install` mentiu.

**Quem pegou:** a verificacao pos-instalacao (`[[ -f /boot/vmlinuz-$kver ]]`).
Sem ela o `05` teria gerado um `grub.cfg` apontando para um kernel inexistente,
e a falha apareceria como `grub rescue` no primeiro boot.

**Correcao:** emerge do `sys-kernel/installkernel` com **todos** os nove
backends desligados em `package.use` (`dracut`, `ugrd`, `uki`, `ukify`,
`systemd`, `systemd-boot`, `grub`, `refind`, `efistub`) — varios geram
initramfs ou UKI, incompativeis com o design sem initramfs. Como nome de USE
flag muda entre versoes, a garantia real e uma checagem pos-`make install` que
falha se qualquer `initramfs-*`/`initrd-*` aparecer em `/boot`.

**Commits:** `9a4dfcf`, `59bf66d`

### 1.4 — `probe_default_grub` reprovava o proprio arquivo

**Sintoma:** `[05-default-grub] do_fn terminou mas o probe ainda reporta
nao-feito — sub-etapa inconsistente`.

**Causa:** o probe exige "nenhum `root=` ativo" (quem emite e o `10_linux`), mas
greppava o arquivo **inteiro**. O comentario que o proprio `do_fn` escreve,
explicando por que nao ha `root=`, contem a string quatro vezes.

**Correcao:** excluir linhas de comentario antes do teste.

**Commit:** `b5015f2`

### 1.5 — Resume caro

**Sintoma:** um resume que reprovava por faltar **um** pacote pequeno remergia o
`linux-firmware` inteiro (~2 GB).

**Causa:** `emerge <pacote>` re-mergeia o que ja esta instalado; pular exige
`--noreplace`.

**Commit:** `b5015f2`

### 1.6 — Login impossivel apos o boot (ergonomia)

**Sintoma:** sistema bootou; `root` e `gentoo` recusavam a senha.

**Causa:** o layout do teclado tinha sido trocado no live ISO, e o console
instalado carrega `KEYMAP=br-abnt2`. Simbolos saem em teclas diferentes.

**Correcao:** aviso de layout movido para **antes de cada prompt de senha** (era
so no resumo final, tarde demais), com recomendacao de usar letras e numeros e
trocar depois. O bloco final lista as contas criadas e o procedimento de
recuperacao via GRUB (`rw init=/bin/bash`).

**Commit:** `a4a0e5b`

> Este e o unico item da lista que nao e bug de codigo. Custou o mesmo tempo que
> os outros: um sistema que boota perfeitamente e tranca o operador do lado de
> fora falhou do mesmo jeito.

---

## Rodada de auditoria — sem execucao (commit `07743d4`)

Correcao dos achados P1/P2 de uma auditoria do estado do repositorio. **Nao
validada em execucao** naquele momento; validada no Ciclo 2.

| Problema | Correcao |
|---|---|
| Hashes de senha persistidos no `vars.sh` do sistema instalado | `secrets.env` separado, modo `0600`, removido no fim |
| State sem identidade do installer | `.installer` com `schema=`/`commit=`; commit diferente avisa, schema diferente aborta |
| `ROOT_FS` como autoridade unica (03 e 06 podiam discordar) | `root_fs_actual()` compartilhada, com `blkid` como fato |
| Perfil detectado por `NR==2` da saida do `eselect` | `readlink -f /etc/portage/make.profile` (fonte canonica) |
| Sync probe, `NVIDIA_MODE=skip` | Auditados, **corretos**, nao reescritos — so testes |

**Regressao introduzida e capturada antes do commit:** ao ligar o `06` ao
filesystem real, ele passou a usar `$ROOT_PART` sem chamar
`compute_partitions` — `unbound variable` sob `set -u`. Corrigida e imunizada
por um teste que varre todos os `0[0-6]-*.sh`.

Suite: 17 → **131** asercoes.

---

## Ciclo 2 — reinstalacao sobre disco usado

**Ambiente:** o mesmo, mas o disco **ja continha a instalacao do Ciclo 1**. Esse
caminho de codigo — reparticionar por cima — nunca tinha sido exercitado.

Resultado: instalacao completa, boot, e `nvidia-drivers` **compilado**. Tres
problemas no caminho.

### 2.1 — `lsblk` invalido fazia o umount pre-zap falhar em silencio

**Sintoma:** `lsblk: options --raw and --list cannot be combined`, e depois
`o kernel nao releu a tabela de particoes nova de /dev/vda`.

**Causa:** `lsblk -nrpo NAME --list` — `-r` **ja e** `--raw`, e o util-linux
recusa combinar os dois. O `lsblk` saia com 1, a substituicao de processo
devolvia **vazio**, o `while read` nao iterava, e o laco de `umount` que solta o
disco antes do zap **nao fazia nada**. Em silencio: `done < <(cmd)` nao propaga
exit code, e o trap `ERR` disparou dentro do subshell da substituicao.

O `sgdisk` seguiu com as particoes antigas montadas e o `BLKRRPART` falhou — o
segundo erro era so o sintoma.

**Gravidade:** a guarda falhava **aberta**. Para codigo destrutivo e o pior modo
de falha possivel.

**Correcao:** usar `_target_disk_parts` do `lib.sh` — a **mesma** funcao que o
`validate_vars` usa. Havia duas implementacoes do mesmo conceito, e a copia
estava quebrada. Resultado capturado em **variavel**, nao em substituicao de
processo: atribuicao propaga falha, `<(...)` esconde.

**Commit:** `03dda46` · **Teste novo:** extrai toda combinacao de flags de
`lsblk`/`findmnt` dos scripts (ignorando comentarios) e **executa** cada uma
contra um disco real do host. Ambos sao read-only.

### 2.2 — `nvidia-drivers[tools]` puxava a arvore do GTK

**Sintoma:** o emerge parava pedindo `--autounmask-write`, com esta cadeia:

```
nvidia-drivers[tools] -> nvidia-settings -> adwaita-icon-theme
  -> librsvg -> gtk+ -> cairo[X], freetype[harfbuzz]
```

**Causa:** `tools` vem **enabled by default** (conferido em
`packages.gentoo.org`) e instala o `nvidia-settings`. Num sistema base nenhum
desses USE esta ligado.

**Correcao:** `-tools` fixado em todos os ramos. Este instalador entrega um
sistema **base bootavel**, nao um desktop: o modulo de kernel e as bibliotecas
do driver bastam.

**Decisao deliberada:** **nao** usar `--autounmask-write`. Ele reescreve
`package.use`/`package.accept_keywords` sozinho, e essa decisao — que pode
desmascarar pacote instavel — e do operador. Ha teste garantindo a ausencia da
flag.

**Bug secundario, encontrado ao escrever o primeiro:** a varredura que procura
`kernel-open` perdido em `package.use/` greppava comentarios — e o arquivo que o
script gera agora **menciona** `kernel-open` ao documentar por que nao o usa.
Acusaria o arquivo que acabou de escrever: a mesma auto-sabotagem do item 1.4.
Corrigida junto.

**Commit:** `49e2a62`

### 2.3 — `libglvnd[X]`

**Sintoma:** depois do `-tools`, restou **uma** mudanca de USE:
`>=media-libs/libglvnd-1.7.0 X`, exigida por `nvidia-drivers[X]`.

**Correcao:** declarar `media-libs/libglvnd X`. Mantivemos `X` no driver em vez
de desligar: a maquina alvo tem uma RTX 5060 Ti e vai rodar ambiente grafico, e
o `make.conf` ja declara `VIDEO_CARDS="nvidia"` — instalar sem `X` significaria
recompilar o driver depois. O arquivo gerado documenta como inverter num sistema
headless.

**Commit:** `3e364f4` · **Teste:** coerencia entre o `X` do driver e o do
`libglvnd` (um nao pode existir sem o outro).

### Estado final do Ciclo 2

```
OS: Gentoo Linux x86_64          Kernel: Linux 6.18.48-gentoo
Host: KVM/QEMU (Q35 + ICH9)      Packages: 342 (emerge)
CPU: 6 x i5-12600K               Disk (/): 8.80 GiB / 42.02 GiB - ext4
GPU: QXL paravirtual             Local IP (enp1s0): 192.168.122.118/24
Swap: 0 B / 16.00 GiB            Locale: pt_BR.utf8
```

Boot sem initramfs, raiz por `root=PARTUUID`, rede por DHCP, locale e keymap
aplicados, swap ativa, login funcionando.

---

## O que os dois ciclos provaram

| Propriedade | Estado |
|---|---|
| Instalacao ponta a ponta em disco **em branco** | Executada (Ciclo 1) |
| Instalacao ponta a ponta em disco **ja usado** | Executada (Ciclo 2) |
| Boot do sistema instalado, **sem initramfs** | Executado (2x) |
| `root=PARTUUID` resolvido pelo kernel | Executado (2x) |
| GRUB UEFI + entrada de NVRAM no OVMF | Executado (2x) |
| `fsck.vfat` na ESP no primeiro boot | Executado (2x) |
| Resume apos falha real de sub-etapa | Executado (~9 vezes, involuntariamente) |
| **Build** do `nvidia-drivers` contra o kernel gerado | Executado (Ciclo 2) |
| `passwd` interativo atraves do chroot | Executado (2x) |
| Rede (DHCP), locale, keymap, swap | Executados |

**Reprodutibilidade:** dois ciclos completos, mas **nao** a mesma versao do
codigo — cada ciclo corrigiu bugs no meio. Uma instalacao limpa do zero, com o
codigo atual e sem intervencao, **ainda nao foi feita**.

---

## Ciclo 4 — bare metal (2026-09-02): primeira execucao em hardware real

ASUS TUF GAMING B760M-E D4 · i5-12600K · RTX 5060 Ti (Blackwell) · 32 GiB ·
`ROOT_FS=btrfs`.

### 4.1 — `06-sudo` falhou: `/etc/sudoers.d` nao existia

```
install: cannot create regular file '/etc/sudoers.d/10-wheel': No such file or directory
[ERRO] falha ao publicar /etc/sudoers.d/10-wheel
[ERRO] etapa 06-users-services.sh falhou
[ERRO] fase chroot falhou
```

Os tres `[ERRO]` sao cascata de uma causa unica: `emerge app-admin/sudo` **nao
cria** `/etc/sudoers.d`. O `@includedir /etc/sudoers.d` no `/etc/sudoers` existe
e aponta para um diretorio inexistente — para o sudo isso **nao e erro**, ele
simplesmente ignora o include. Logo `_sudoers_includes_dir` passou (a linha
estava la) e o `install` morreu logo depois.

**Correcao:** `install -d -m 0750 -o root -g root /etc/sudoers.d` antes de
publicar (0750 root:root e o modo do upstream do sudo). Uma asercao nova cobra
que a criacao venha **antes** da publicacao.

**Por que os testes nao pegaram:** as asercoes do `06-sudo` cobriam ordem
(`visudo` antes do `install`), modo (`0440`), semantica de `ENABLE_SUDO=no` e o
regex do `includedir` — tudo sobre o *conteudo* e a *sequencia*, nada sobre o
*ambiente* em que a etapa roda. Nenhum teste de host pode observar que o ebuild
do sudo nao cria um diretorio; isso so aparece executando.

> A etapa estava documentada como "nunca executada" no commit que a introduziu.
> Falhou na primeira execucao. O registro estava correto, e essa e a unica razao
> pela qual a falha nao foi surpresa.

### Observacao: sudo puxa um MTA

O `emerge` trouxe `mail-mta/nullmailer` junto (`acct-user/nullmail`,
`acct-group/nullmail`). E o USE `sendmail` do sudo, ligado por default, que puxa
`virtual/mta` — o sudo o usa para mandar email ao admin em tentativa negada.
Nada e habilitado no boot, entao o MTA fica inerte. `app-admin/sudo -sendmail`
evitaria a dependencia; **nao alterado** sem decisao do operador.

### 4.2 — `ROOT_FS` esquecido de novo, agora numa instalacao limpa

A instalacao do bare metal foi ate o `06` com **ext4**, nao btrfs: a variavel
nao estava no ambiente. Terceira vez na mesma semana.

O guard `_assert_root_fs_not_forgotten` (3.3) **nao se aplica** aqui, e
corretamente: ele compara o filesystem existente com o declarado, e num disco
em branco nao ha filesystem para comparar. Ele protege retomadas, nao a
primeira execucao.

A causa real e outra: o prompt do `ERASE` mostrava so o que seria **destruido**
(`lsblk` + `sgdisk -p`). O que seria **criado** vivia apenas no `vars.sh`. O
unico momento em que o operador para e le nao dizia qual filesystem ia sair
dali.

**Correcoes, duas:**

1. `confirm_destruction` passa a imprimir o plano — as tres particoes com
   tamanhos, o `ROOT_FS`, o usuario e seus grupos — antes do prompt.
2. O default do `vars.sh` virou `ROOT_FS=btrfs`, com a instrucao de **editar o
   arquivo** em vez de exportar a variavel. Um default correto elimina a classe
   inteira do erro; a variavel de ambiente continua funcionando como override
   pontual.

Tres asercoes cobram que o prompt nomeie o filesystem e o usuario, e que o
plano venha antes da confirmacao.

> As duas correcoes de `ROOT_FS` deste ciclo atacam pontas diferentes: 3.3
> impede o estrago numa retomada, 4.2 impede o erro na origem. Nenhuma das duas
> sozinha teria evitado as tres ocorrencias.

---

## Ciclo 5 — modulo `desktop/` no bare metal (2026-09-02)

ASUS TUF GAMING B760M-E D4 (firmware 1836) · i5-12600K · RTX 5060 Ti 16GB
(Blackwell/GB206) · NVMe · OpenRC · `ROOT_FS=btrfs`.

Sistema base ja instalado e bootado. Esta sessao executou o `desktop/` de ponta
a ponta, etapas `10`→`15`, e terminou com **niri 26.04 rodando sob Wayland na
GPU Blackwell**: modulo NVIDIA carregado, handoff `simpledrm` → `nvidia-drm` sem
tela preta, `/dev/dri/renderD128` aberto pelo compositor.

**Nove defeitos** no percurso. Cinco deles na etapa `12`, todos na mesma cadeia
de dependencias — ver 5.6.

> **A execucao NAO foi limpa.** Houve intervencao manual em oito pontos, e as
> correcoes abaixo foram escritas *durante* a instalacao. O que este ciclo prova
> e que o caminho existe e termina numa sessao grafica funcionando **uma vez**,
> nao que o codigo atual o percorre sozinho. Isso ainda nao foi tentado.

### 5.1 — `iwd` nao inicia: simbolos de cripto ausentes no kernel

**Sintoma:** `rc-service iwd status` → `crashed`. Sem Wi-Fi, `wlan0` em
`NO-CARRIER`, `ping` falhando com "Temporary failure in name resolution". O log
do servico nao dizia nada util.

**Diagnostico:** rodar o daemon em foreground imprimiu a lista exata:

```sh
/usr/libexec/iwd -d
```

**Causa raiz:** quem exige os simbolos e o `dev-libs/ell` (dependencia do iwd),
que abre sockets `AF_ALG` do kernel. O fragmento nao habilitava
`KEY_DH_OPERATIONS`, `CRYPTO_CBC` nem `CRYPTO_DES`. Sem eles o `ell` falha na
inicializacao e o iwd se recusa a subir.

O gate `verify_kconfig` nao pegou porque validava a cadeia de **boot** e os
simbolos de cripto que o iwd usa em *build* — nao os que ele cobra em
**runtime**. Nenhuma falha de compilacao acontece; o problema so existe depois
do primeiro boot.

**Delta real no repositorio** (registrado porque diverge do relato inicial): dos
cinco simbolos citados no diagnostico, **dois ja estavam** no fragmento e no
gate — `CRYPTO_USER_API_SKCIPHER` e `CRYPTO_ECB`. A saida do `iwd -d` lista o
requisito completo, nao so o que falta. Foram acrescentados **quatro**:
`KEY_DH_OPERATIONS`, `CRYPTO_CBC`, `CRYPTO_DES` e `CRYPTO_DES3_EDE_X86_64`
(este ultimo e otimizacao assembly, nao requisito).

**Correcao:** os quatro no `kernel-fragment.config`, e os tres obrigatorios
tambem no array `required` do `verify_kconfig`.

**Gravidade: alta.** Numa maquina so-Wi-Fi isso e um sistema sem rede logo apos
o primeiro boot — e sem rede nao da nem para emergir o conserto.

**Teste:** 10 asercoes cobram os cinco simbolos no fragmento **e** no gate.

### 5.2 — `00cpu-flags` gerado em formato invalido (`:` em vez de `=`)

**Sintoma:** `[10-cpu-flags] do_fn terminou mas o probe ainda reporta nao-feito
— sub-etapa inconsistente`.

**Causa raiz:** o `cpuid2cpuflags` imprime para humano —
`CPU_FLAGS_X86: aes avx ...`, com dois-pontos. O `package.use` exige a sintaxe
de variavel: `*/* CPU_FLAGS_X86="aes avx ..."`. O `do_fn` gravava a saida crua;
o probe procurava `CPU_FLAGS_X86=` e nunca achava.

**Correcao:**

```sh
cpuid2cpuflags | sed 's/^CPU_FLAGS_X86: /*\/* CPU_FLAGS_X86="/; s/$/"/'
```

Mais um `die` se a conversao nao produzir a forma esperada — falhar na hora e
melhor que gravar um arquivo que o Portage ignora em silencio.

**Mesmo padrao do 1.3:** o verificador estava certo, o gerador estava errado. La
o `make install` gravava `/boot/vmlinuz` sem versao e a checagem pos-instalacao
pegou; aqui o gerador escreve o formato errado e o probe pega. Nos dois casos o
instinto de "consertar o teste que reclama" seria o movimento exatamente errado.

**Teste:** 3 asercoes, incluindo uma **funcional** que roda o `sed` sobre uma
saida real e compara com a linha esperada byte a byte.

### 5.3 — USE transitivas da cadeia GTK/GNOME ausentes

**Sintoma:** a etapa `12` aborta no autounmask exigindo `x11-libs/cairo X` e
`>=media-libs/freetype-2.14.3 harfbuzz`.

**Causa raiz:** nenhuma das duas e exigida pelo niri. Elas vem de:

```
niri[screencast] -> xdg-desktop-portal-gnome -> libadwaita ->
  appstream -> appstream-glib -> pango
```

O portal entra porque `niri[screencast]` precisa de um. O `have_use_flag` valida
IUSE corretamente, mas nao tem como saber de dependencias de USE **entre**
pacotes — ele responde "este flag existe?", nao "esta arvore de dependencias
fecha?".

**Correcao:** as duas no `gen_package_use()`.

### 5.4 — kitty com backend X num sistema Wayland puro

**Sintoma:** a etapa `12` aborta exigindo `>=x11-libs/libxkbcommon-1.13.2 X`,
mais uma dependencia circular do `dev-lang/go`.

**Causa raiz:** o `12-niri-stack.sh` escolhe **qual** pacote emergir via
`DESKTOP_TERMINAL`, mas nunca declarava USE flags para ele. O kitty veio com o
default do perfil (`USE="X -wayland"`) e arrastou a stack X11 inteira.

**Correcao:** `_use_line x11-terms/kitty wayland -X` no `gen_package_use()`,
guardado por `have_atom` e pelo valor de `DESKTOP_TERMINAL` — foot e alacritty
sao Wayland-nativos e nao precisam de linha. A circular do Go some junto.

### 5.5 — `have_use_flag` validava contra o slot errado

**Sintoma:** `o USE flag 'wayland' NAO existe no IUSE de 'dev-cpp/gtkmm' nesta
versao da arvore` — sobre um flag que existe.

**Causa raiz:** `portageq best_visible / dev-cpp/gtkmm` resolve para o slot
**4.0** (IUSE: `gtk-doc test`). O waybar precisa do **3.0** (IUSE inclui
`wayland`). Sem slot no atom, a validacao consultava o pacote errado e reprovava
com uma mensagem que parece dizer o oposto do que acontece.

**Correcao, duas partes:**

1. Atom com slot (`dev-cpp/gtkmm:3.0`) no `_use_line`.
2. O `have_use_flag` passa a **avisar** quando o atom nao declara SLOT e o slot
   resolvido nao e o default `0`. Heuristica, nao prova — mas cobre o caso real
   e transforma um erro enganoso num aviso que aponta para a causa. Aviso e nao
   erro porque quem quer o slot que o Portage escolheu esta certo.

A mensagem do `die` do `_use_line` tambem passou a mencionar slots.

### 5.6 — cadeia waybar: quatro USE faltando + colisao de slot no cairo

**Sintoma:** sequencia de falhas de autounmask, culminando em
`Multiple package instances within a single package slot ... slot conflict:
x11-libs/cairo:0`.

**Causa raiz:** tres sub-cadeias distintas do `gui-apps/waybar`:

| Puxa | Exige |
|---|---|
| `gtk-layer-shell` | `gtk+[wayland,-X]` |
| `libayatana-appindicator` (via `waybar[tray]`) | `libdbusmenu[gtk3]` |
| `cairomm -> pangomm -> gtkmm:3.0` | `mesa[wayland]`, `cairo[-X]` |

O ultimo colide de frente com o `cairo[X]` que a cadeia do portal GNOME (5.3)
exige. Duas cadeias, dois requisitos opostos, mesmo slot.

**Correcao:** `x11-libs/gtk+ wayland -X`, `dev-libs/libdbusmenu gtk3`,
`media-libs/mesa wayland`, `dev-cpp/cairomm X`, e `x11-libs/cairo X aqua` — o
`aqua` e a saida que o proprio Portage sugere para a colisao.

**Uma linha, nunca duas.** Declarar `cairo X` e `cairo -X` separadamente
reproduziria o conflito por escrito. Ha uma asercao contando as ocorrencias.

> **A licao estrutural.** O item da auditoria do Ciclo 2 ja tinha visto
> `cairo[X]` entrar por outra cadeia — `nvidia-drivers[tools]` →
> `gtk+` → `librsvg` → `cairo`. Agora ela entrou por duas cadeias novas. Cacar
> cadeia por cadeia nao escala: cada combinacao de `DESKTOP_*` produz um
> conjunto diferente, e o unico jeito de descobrir e compilando.
>
> **Recomendacao (nao implementada):** uma sub-etapa de validacao que rode
> `emerge -pq --autounmask=y` sobre a lista completa **antes** do emerge real e
> parseie a saida. Ela transformaria horas de compilacao interrompida em
> segundos de relatorio, e nao dependeria de alguem prever a arvore. Fica
> registrada como divida.

### 5.7 — `13-audio-user-services`: probe cobrando um init script impossivel

**Sintoma:** `'/etc/init.d/pipewire' nao existe - pulando`, seguido de
`do_fn terminou mas o probe ainda reporta nao-feito`.

**Causa raiz:** com OpenRC ≥ 0.60 o `do_fn` tomava a rota "servicos de usuario"
e rodava `rc-update add -U pipewire`. Mas o modulo define
`media-video/pipewire ... -system-service` — e esta **certo** em faze-lo: o
proprio ebuild marca `system-service` como "Not recommended", e em OpenRC o
PipeWire e servico de usuario. So que com essa flag o ebuild **nao instala init
script nenhum**, nem de sistema nem de usuario.

As duas premissas do script colidiam: *"OpenRC ≥ 0.60 ⇒ servicos de usuario
disponiveis"* e falso quando nao ha init script para habilitar.

**Correcao, duas partes:**

1. `probe_audio_user_services()` ganha um terceiro caminho: sem init script, a
   rota so pode ser o launcher — reporta feito **se** o marker ja disser
   `launcher`, e nao-feito se ainda nao disser. Exigir o marker importa: e ele
   que faz o `14` declarar o `spawn-at-startup` no `config.kdl`.
2. `do_audio_user_services()` passa a exigir as **duas** condicoes
   (`openrc_version_ge 0.60 && svc_script_exists pipewire`) e cai no launcher
   caso contrario, reportando qual das duas faltou — a acao corretiva difere.

As duas rotas sao mutuamente exclusivas: declarar ambas faria o PipeWire subir
duas vezes.

> O cabecalho do proprio `13-services.sh` (linhas 35-37) ja documentava que nao
> existe servico de sistema para o PipeWire. **A logica do `do_fn` nao seguia o
> proprio comentario do arquivo.**

### 5.8 — `gsettings` sem sessao D-Bus: backend em memoria

**Sintoma:** `o valor de 'color-scheme' foi gravado mas a releitura devolveu
'default' em vez de 'prefer-dark'`.

**Causa raiz:** `run_as_user gsettings set/get` roda a partir de um shell de root
**sem barramento de sessao**. Sem D-Bus o dconf cai num backend em memoria: o
comando sai com 0 e o valor evapora ao fim do processo.

O `gsettings_set_checked()` ja detectava isso — foi por isso que o erro apareceu
em vez de virar uma configuracao silenciosamente perdida. **O verificador
funcionou como projetado; o que faltava era a sessao.**

**Correcao:** `run_as_user dbus-run-session gsettings ...` nas duas helpers.

**Segundo defeito, descoberto ao aplicar o primeiro:** com `dbus-run-session`, o
`dbus-daemon` emite linhas proprias que contaminam a captura, e a comparacao
passa a falhar com `''prefer-dark'' != 'prefer-dark'` — aspas duplicadas, o que
parece bug de formato e nao e. Correcao: `| tail -1` no `gsettings_get`.

### 5.9 — `XDG_RUNTIME_DIR` no `.bash_profile`, mas o shell do usuario e zsh

**Sintoma:** o niri morre com

```
panicked at src/niri.rs: called `Result::unwrap()` on an `Err` value: RuntimeDirNotSet
```

Exportando a variavel a mao, o erro vira `Unable to set up transient service
directory: XDG_RUNTIME_DIR "/run/user/1000" not available: No such file or
directory`.

**Causa raiz:** o `13-xdg-runtime-dir` acrescenta um bloco **bem construido**
(export + verificacao de dono/permissao + `mkdir`/`chmod 0700`) ao
`~/.bash_profile`. O `/etc/local.d/create-runuser.start` cria corretamente so o
diretorio **pai** (`/run/user`, sticky 1777) — por design, e o trecho no perfil
do usuario que cria `/run/user/$UID`.

Mas o `14-dotfiles.sh` configura **zsh** como shell do usuario, e o zsh nao le
`.bash_profile`. O diretorio nunca era criado no login, e a sessao grafica nao
subia.

**As duas etapas discordavam sobre qual shell o usuario tem — e a `13` roda
antes da `14`.** Consultar o shell atual no momento da `13` tambem nao resolve:
naquele instante o shell ainda e o bash.

**Correcao:** `_xdg_profile_files()` devolve os arquivos de perfil do shell
**efetivo de agora** (`getent passwd`) **e** do que a `14` vai configurar
(`DESKTOP_SHELL`) — `.zprofile` para zsh, `.bash_profile` para bash, `.profile`
como fallback. Quando coincidem, e um arquivo so. O trecho e idempotente, entao
estar em dois arquivos nao causa dano, e apenas um e lido por login.

**Gravidade: alta.** E a diferenca entre a sessao grafica subir e nao subir, e o
sintoma — um panic de Rust — nao aponta para o shell em lugar nenhum.

**Teste:** 4 asercoes, incluindo a coerencia entre o shell que a `14` configura
e o perfil que a `13` escreve.

---

### O que NAO da para guardar com teste estatico

Quatro dos nove defeitos deste ciclo nao tem asercao, e o motivo importa mais
que o numero:

| Defeito | Por que nenhum teste de host o pegaria |
|---|---|
| Colisao de slot do cairo (5.6) | So existe no grafo de dependencias que o Portage resolve **com a arvore instalada**. Um teste pode conferir que escrevemos **uma** linha de cairo — e confere — mas nao que o conjunto de flags fecha. Isso exige `emerge -p` numa maquina Gentoo real |
| Backend em memoria do dconf (5.8) | Depende da presenca de um barramento D-Bus em runtime. Um teste estatico ve `dbus-run-session` no codigo — e ve — mas nao que o dconf persiste |
| Init script ausente por USE flag (5.7) | Qual arquivo um ebuild instala e funcao das USE flags **e** da versao do ebuild na arvore. So o emerge sabe |
| `iwd` em `crashed` (5.1) | O teste confere que os simbolos estao no fragmento. Que **esses** sejam os simbolos certos veio de rodar `iwd -d` no hardware |

Em todos, a asercao que existe guarda a **forma** da correcao, nao o
comportamento. E o teto do que analise estatica alcanca, e vale enunciar: um
teste verde aqui significa "a correcao continua escrita", nunca "o problema
continua resolvido".

---

## Ciclo 6 — etapa 16 (Clavis Shell) no bare metal (2026-09-03)

Primeira execucao da etapa `16-clavis.sh` em qualquer ambiente. Ela e opt-in
(`DESKTOP_CLAVIS=yes`) e instala o Clavis Shell: quickshell + key-cli + keytop.

**A etapa NAO rodou limpa.** Ela chegou ao fim, mas com intervencao manual em
doze pontos, cada um exigindo editar o script no meio da instalacao. O Clavis
compila, instala e sobe — `qs -c clavis` roda na sessao — e nada disso foi
obtido com o codigo como estava escrito.

Sete dos doze defeitos sao a mesma classe: USE flag ou keyword nao declarada,
descoberta uma a uma pelo autounmask. Dois sao de escrita a mao em arquivo
gerado. Um e de glob. Um e de variavel de ambiente que nao existia em lugar
nenhum do repositorio.

### 6.1 — `qtdeclarative[vulkan]`: conflito de USE com o qtbase

**Sintoma:**

```
emerge: there are no ebuilds built with USE flags to satisfy
"dev-qt/qtbase-6.11.1:6[accessibility=,gui,network=,opengl=,sql?,ssl?,vulkan=,widgets=]"
- dev-qt/qtbase-6.11.1 (Change USE: -vulkan)
- dev-qt/qtdeclarative-6.11.1-r1 (Change USE: +vulkan)
```

**Causa raiz:** o atom usa `vulkan=`, que obriga qtbase e qtdeclarative a terem
o **mesmo valor** da flag. O script declarava `dev-qt/qtbase:6 dbus vulkan`
porque o quickshell exige, e nao declarava nada para o qtdeclarative. As duas
sugestoes do Portage sao mutuamente exclusivas, e so uma preserva o requisito
do quickshell.

**Correcao:** `_use_line_clavis dev-qt/qtdeclarative:6 vulkan`.

**Teste:** asercao conferindo `dev-qt/qtdeclarative:6 .*vulkan` em
`gen_clavis_use`.

### 6.2 — `libxkbcommon[X]`

**Sintoma:** `>=x11-libs/libxkbcommon-1.13.2 X`, exigido pela cadeia do
`qtbase[X]`.

**Correcao:** `_use_line_clavis x11-libs/libxkbcommon X`.

**Teste:** nenhum especifico — coberto pela asercao geral de que toda linha
passa por `have_use_flag`.

### 6.3 — `cpptrace` mascarado por keyword

**Sintoma:**

```
All ebuilds that could satisfy "dev-cpp/cpptrace[unwind]" have been masked.
- dev-cpp/cpptrace-1.0.4-r1::gentoo (masked by: ~amd64 keyword)
(dependency required by "gui-apps/quickshell-0.3.0-r1::guru[crash-handler]")
```

**Causa raiz:** `crash-handler` e flag **default** do quickshell e puxa o
cpptrace, que so existe em `~amd64`. O `gen_clavis_keywords()` listava dois
atoms: `gui-apps/quickshell` e `>=media-sound/libcava-1.0.0`.

**Correcao:** `dev-cpp/cpptrace ~amd64` no gerador de keywords.

### 6.4 — cascata: `cpptrace[unwind]` puxa `libdwarf`, tambem mascarado

**Sintoma:** destravado o cpptrace, veio `>=dev-cpp/cpptrace-1.0.4-r1 unwind`;
e o `cpptrace[unwind]` puxou `dev-libs/libdwarf:=`, com 2.3.1, 2.3.0 e 2.2.0
todas mascaradas.

**Causa raiz:** o efeito cascata de trazer um pacote de testing. **Cada
dependencia nova traz a propria exigencia**, e a cascata so termina quando o
emerge para de reclamar — nao da para ler o ebuild e prever onde acaba.

**Correcao:** `dev-libs/libdwarf ~amd64` nas keywords e
`_use_line_clavis dev-cpp/cpptrace unwind` nas USE.

**Alternativa considerada e rejeitada:** `quickshell[-crash-handler]` cortaria
cpptrace e libdwarf de uma vez. Foi rejeitada porque o Clavis e um componente
novo, e perder stack trace justamente no que ainda vai quebrar e o pior
momento para economizar dois pacotes.

**Teste:** asercao exigindo cpptrace **e** libdwarf juntos em
`gen_clavis_keywords` — declarar so o topo da cascata para o emerge no degrau
seguinte.

### 6.5 — `qtbase[opengl,wayland]`

**Sintoma:** `>=dev-qt/qtbase-6.11.1 opengl wayland`, exigido por
`dev-qt/qtwayland-6.11.1`, que entra por `quickshell[wayland]`.

**Correcao:** `_use_line_clavis dev-qt/qtbase:6 opengl wayland`.

**Teste:** asercao dedicada.

### 6.6 — o NetworkManager puxando `wpa_supplicant` num sistema `iwd`

**Sintoma:** `>=net-wireless/wpa_supplicant-2.11-r4 dbus`, exigido por
`net-misc/networkmanager-1.56.0[wifi,-iwd]`, que entra por
`quickshell[networkmanager]`.

**Causa raiz:** este sistema usa **iwd** como backend de Wi-Fi, configurado nas
etapas base. O NetworkManager com `-iwd` traz o wpa_supplicant como backend, e
passariam a existir dois gerenciadores disputando a mesma interface. Nao e erro
de compilacao: e um defeito de runtime que so apareceria depois, no Wi-Fi.

**Correcao:** `_use_line_clavis net-misc/networkmanager iwd`. Com a flag, o
wpa_supplicant sai da arvore de dependencias.

**Alternativa considerada e rejeitada:** `quickshell[-networkmanager]`, que
cortaria o widget de rede da shell.

**Teste:** asercao dedicada — este e o defeito deste ciclo com maior custo se
reintroduzido, porque nao falha na instalacao.

### 6.7 — `qtdeclarative[opengl]`

**Sintoma:** `>=dev-qt/qtdeclarative-6.11.1-r1 opengl`, exigido por
`gui-apps/quickshell::guru`. Mesma cadeia do 6.5.

**Correcao:** `_use_line_clavis dev-qt/qtdeclarative:6 opengl`.

### 6.8 — `qttools[widgets]` contra o `REQUIRED_USE` do qtbase

**Sintoma:** contradicao direta, os dois lados simultaneos:

```
# required by dev-qt/qttools-6.11.1::gentoo[widgets]
>=dev-qt/qtbase-6.11.1 -opengl
```

```
The following REQUIRED_USE flag constraints are unsatisfied:
    wayland? ( opengl )
```

**Causa raiz:** `qttools[widgets]` exige `qtbase[-opengl]`; `qtbase[wayland]`
exige `opengl`. O script declarava so `dev-qt/qttools:6 linguist` — o Clavis
usa o componente Qt6 LinguistTools, que fornece o `lrelease` — e deixava
`widgets` no default ligado.

**A primeira tentativa nao bastou.** Desligar so `widgets` produziu um segundo
erro, agora do REQUIRED_USE do proprio qttools: `assistant? ( widgets )`.

**Correcao:** a linha existente virou
`_use_line_clavis dev-qt/qttools:6 linguist -widgets -assistant`.

**Teste:** asercao exigindo os **dois** negativos. Guardar so `-widgets`
deixaria passar exatamente a tentativa que falhou.

### 6.9 — check de artefato com glob raso; o Qt6 instala em subdiretorios

**Sintoma:** o build foi ate `[261/262]` com sucesso, e mesmo assim:

```
a compilacao terminou mas nenhum .so apareceu em
'/home/daeese/src/clavis-shell/build/qml/Clavis'.
```

O `find` confirmava os artefatos, cada um num subdiretorio:

```
build/qml/Clavis/DesktopCards/libClavisDesktopCards.so
build/qml/Clavis/Weather/libClavisWeather.so
build/qml/Clavis/Niri/libClavisNiri.so
build/qml/Clavis/Cava/libClavisCava.so
```

**Causa raiz:** o Qt6 instala modulos QML em **um subdiretorio por modulo**
(`qml/Clavis/<Modulo>/`), e os tres checks usavam `compgen -G ".../*.so"`, que
so olha um nivel.

**O check estava certo, o teste e que era estreito.** Ele protege contra uma
falha silenciosa real: o `cmake --install` deste upstream copia da build-tree
(nao ha `install(TARGETS)`), entao instalar sem artefato produziria um
diretorio vazio **saindo com 0**. A ideia continua necessaria; o alcance do
glob e que estava errado.

**Correcao:** os tres lugares — `do_clavis_build`, `probe_clavis_build` e
`probe_clavis_build_artifacts_or_die` — passaram a usar
`find "$dir" -name '*.so' -print -quit`.

> **Erro cometido durante a propria correcao.** A primeira tentativa omitiu a
> aspa dupla de fechamento depois de `Clavis/`, e o `bash -n` acusou erro de
> sintaxe perto de `}` procurando o `)` correspondente, na linha 386 — o
> parentese de `$(` nunca fechava. A regra do `AGENTS.md` de rodar `bash -n`
> depois de qualquer edicao ja existia; ela foi violada e cobrou o preco na
> hora. Fica registrado porque uma regra so vale depois de doer.

**Teste:** duas asercoes — nenhuma ocorrencia de `compgen -G` em check de
artefato QML, e **tres** ocorrencias de `find ... -print -quit`. A contagem
importa: corrigir dois dos tres lugares deixaria o probe reprovando um build
bom.

### 6.10 — `qt5compat` ausente, e depois presente com a flag QML desligada

**Sintoma:** build e install passaram; `quickshell -c clavis` falhou:

```
ERROR: Failed to load configuration
ERROR:   caused by @shell.qml[8:5]: Type AppShell unavailable
...
ERROR:   caused by @Modules/SystemCards/SystemBatteryTank.qml[4:1]:
         module "Qt5Compat.GraphicalEffects" is not installed
```

**Causa raiz, em duas partes.** A primeira: `dev-qt/qt5compat` nao estava na
lista `CLAVIS_DEPS` da sub-etapa `16-clavis-deps`. A segunda, mais traicoeira:
instalado a mao, ele veio com `USE="gui -custom-cflags -icu -qml -test"`. A
flag `qml` **nao e default**, e e ela que instala o modulo QML. Sem ela, so a
lib C++ (`libQt6Core5Compat.so`) e instalada.

**A licao.** No Gentoo os plugins QML do Qt6 ficam atras de USE flags. Um
`module "X" is not installed` do QML significa **tanto** "pacote ausente"
**quanto** "pacote presente com a flag QML desligada" — e os dois produzem
exatamente a mesma mensagem. Diagnosticar pelo texto do erro leva ao lugar
errado metade das vezes.

**Correcao:** `dev-qt/qt5compat:6` em `CLAVIS_DEPS` e
`_use_line_clavis dev-qt/qt5compat:6 qml` nas USE.

**Teste:** duas asercoes — o pacote em `CLAVIS_DEPS` e a flag em
`gen_clavis_use`. As duas, porque cada uma sozinha reproduz um dos dois casos.

### 6.11 — correcoes escritas a mao no arquivo GERADO

**Sintoma:** nenhum, e e esse o problema. Descoberto auditando a maquina
instalada um dia depois, comparando o `/etc/portage/package.use/clavis` real
com o que o gerador do repositorio produz.

**Causa raiz:** parte das correcoes foi aplicada direto no arquivo gerado, em
vez de no `gen_clavis_use()` que o produz. Tres consequencias:

1. **`dev-qt/qt5-compat qml`** — atom que **nao existe**; o nome do pacote e
   `qt5compat`, sem hifen. Ficou no arquivo como no-op silencioso, ao lado da
   linha correta. Escrita pelo gerador, essa linha nunca teria passado: o
   `have_atom` do `_use_line_clavis` morreria com mensagem nomeando o atom.
   **A validacao existia e foi contornada por escrever fora dela.**
2. **`app-misc/brightnessctl`** (USE `udev` e keyword `~amd64`) entrou pelo
   mesmo caminho, e o pacote esta instalado. Nao estava em `CLAVIS_DEPS` nem
   nos geradores.
3. **Tudo isso seria apagado.** O `write_managed_file` reescreve o arquivo
   inteiro quando o gerador muda, e o `probe_clavis_use` compara byte a byte
   com a saida de `gen_clavis_use`. A proxima execucao da etapa 16 apagaria as
   correcoes e o shell voltaria a nao subir — **sem erro nenhum na instalacao**,
   porque o defeito so aparece quando o QML carrega.

**Correcao:** tudo migrado para os geradores; `dev-qt/qt5compat:6` com slot
(verificado: o SLOT real e `6/6.11.1`, e `portageq best_visible / dev-qt/qt5compat:6`
resolve — nao e o caso do qtkeychain, que e `0/1`).

**Teste:** asercao recusando a string `qt5-compat` em qualquer lugar do script.

### 6.12 — `QT_QPA_PLATFORM` nao existia em lugar nenhum do repositorio

**Sintoma:** com tudo compilado e instalado, `quickshell -c clavis` falhava com

```
This application failed to start because no Qt platform plug-in could be
initialized. Reinstalling the application may fix this problem.
```

**O que foi descartado por inspecao:** `/usr/lib64/qt6/plugins/platforms/`
contem `libqwayland.so` e `libqxcb.so`; `wayland-shell-integration/` contem
`libxdg-shell.so`, `libqt-shell.so` e outros tres. Os plugins **estao todos
instalados**. As hipoteses de integracao xdg-shell ausente e de inconsistencia
entre qtbase e qtwayland apos os varios rebuilds estao eliminadas.

**Causa raiz:** o `QT_QPA_PLATFORM=wayland` nao e declarado em nenhum ponto do
instalador — `grep -rn QT_QPA_PLATFORM` no repositorio inteiro so encontra uma
mencao a `QT_QPA_PLATFORMTHEME`, dentro de um comentario. O `niri_config_content()`
da etapa 14 nao gerava bloco `environment`.

**O mecanismo exato nao foi isolado.** A suspeita e o Qt eleger o backend `xcb`
por causa do `DISPLAY` que o `xwayland-satellite` exporta, mas isso **nao foi
comprovado**. O que esta registrado e o efeito: com a variavel declarada, a
shell sobe.

**Correcao:** bloco `environment { QT_QPA_PLATFORM "wayland" }` no
`niri_config_content()` da `14-dotfiles.sh` — nao na 16, porque a variavel
serve todo aplicativo Qt da sessao e a etapa 16 e opt-in. A 14 roda antes da 16.

**Teste:** asercao conferindo a linha no `niri_config_content`. Ela guarda a
**forma**; que o Qt inicialize, so a sessao real diz.

### Observacao: duas sub-etapas de rede falharam por DNS (nao e bug)

`16-key-cli` e `16-keytop` falharam na mesma execucao, pela mesma causa:

```
fatal: unable to access 'https://github.com/StatIndet/keytop/':
Could not resolve host: github.com (Timeout while contacting DNS servers)
```

O DNS do roteador engasgou. Nao ha defeito de codigo: as duas sub-etapas fazem
rede (`pip install` de URL git e `git fetch`) e nao sao idempotentes contra
falha de resolucao. O re-run passou. Procedimento e fallback de DNS em
[ARMADILHAS.md](ARMADILHAS.md), secao 21.

O `16-keytop` se comportou **exatamente como projetado**: a falha nao derrubou
a etapa, o marker gravou `skipped` e o operador foi avisado. Como o
`probe_keytop` trata `skipped` como terminal, ele nao insiste — o `keytop`
desta maquina foi instalado a mao depois, em `/usr/local/bin/keytop`, e o marker
continua dizendo `skipped`. Marker e reality divergem, e nesse caso sem
consequencia: o probe reporta feito nos dois ramos. Fica registrado como
observacao, nao como defeito.

### A mesma classe, pela segunda vez

Sete dos doze defeitos deste ciclo (6.1 a 6.8, tirando o 6.3/6.4 que sao um so
em duas etapas) sao USE flags e keywords nao declaradas, cada uma descoberta
quando o emerge parou e sugeriu `--autounmask-write`. Isso ja tinha acontecido
no Ciclo 5, item 5.6, e la ficou registrada a recomendacao:

> uma sub-etapa de validacao que rode `emerge -pq --autounmask=y` sobre a lista
> completa **antes** do emerge real e parseie a saida.

O Ciclo 6 e a segunda ocorrencia, agora com um agravante: entre uma parada do
emerge e a seguinte houve compilacao de Qt inteiro. O custo nao e so de tempo
de quem opera — e de horas de CPU jogadas fora entre descobertas que um
`emerge -p` daria em segundos.

**A recomendacao deixa de ser divida registrada e passa a ser o proximo item de
trabalho da etapa 16.** Ela nao depende de prever a arvore, que e justamente o
que nao funciona: as duas tentativas de prever falharam do mesmo jeito.

### O que NAO da para guardar com teste estatico — Ciclo 6

| Defeito | Por que nenhum teste de host o pegaria |
|---|---|
| `REQUIRED_USE` entre qtbase e qttools (6.8) | A contradicao so existe no grafo que o Portage resolve **com a arvore instalada**. Um teste confere que escrevemos `-widgets -assistant` — e confere — nao que o conjunto fecha |
| Cascata de keywords cpptrace → libdwarf (6.4) | Cada dependencia nova de um pacote em testing traz a propria exigencia. Onde a cascata termina e funcao da arvore no dia; so o `emerge` sabe |
| "pacote ausente" vs "flag QML desligada" (6.10) | As duas situacoes produzem a **mesma** mensagem de erro do QML. Distinguir exige inspecionar o que o ebuild instalou, com as USE daquela maquina |
| `QT_QPA_PLATFORM` (6.12) | A asercao confere que a linha esta escrita. Que o Qt inicialize o plugin depende do ambiente da sessao em runtime |

O padrao se repete e vale reafirmar: a asercao guarda a **forma** da correcao,
nunca o comportamento. Verde aqui significa "a correcao continua escrita".

---

## O que continua sem validacao

Esta tabela estava desatualizada: ela listava "boot em bare metal", "runtime do
NVIDIA" e "Alder Lake real" como nunca executados, coisas que os Ciclos 3, 4 e 5
ja tinham feito. Corrigida em 2026-09-04 contra os artefatos da propria maquina
instalada — `/var/lib/gentoo-install/state/`, os logs em
`/var/log/gentoo-install/` e o sistema em execucao.

| | Por que |
|---|---|
| Instalacao limpa com o codigo atual, sem intervencao | Nunca executada. **Continua sendo o teste que falta**, e agora com uma divida a mais: as doze correcoes do Ciclo 6 foram escritas durante a instalacao e nenhuma foi reexecutada |
| Etapa 16 rodando **limpa** | Nunca. Ela chegou ao fim, com intervencao manual em doze pontos |
| Etapa `06-sudo` | Primeira execucao no bare metal falhou e foi corrigida (ver Ciclo 4); a versao corrigida ainda **nao rodou** |
| `keytop` instalado **pela etapa 16** | A sub-etapa falhou por DNS e gravou `skipped`. O binario existe em `/usr/local/bin/keytop`, instalado a mao depois — fora do modelo do instalador |
| NVRAM do firmware **ASUS 1836** | Comportamento de retencao da entrada de boot ao longo do tempo; ver ARMADILHAS secao 7 |
| Suspend/resume | Nunca executado |
| Branch `INIT_SYSTEM=systemd` | Nunca executado |
| Reinstalacao sobre esta instalacao | O disco de dados segue intacto e a decisao de reparticionar continua em aberto |

O que **deixou** de estar nesta lista, e com que evidencia:

| Antes listado como nao validado | Evidencia que o tirou daqui |
|---|---|
| Boot em bare metal | Ciclos 3 e 4, com boot confirmado. A maquina onde este texto foi escrito e ela |
| Runtime do NVIDIA (modulo, GSP, modeset) | Sub-etapas `11-modeset-check` e `11-egl-libs-check` marcadas no state; sessao Wayland com o driver 595.91.07 na RTX 5060 Ti, e Vulkan em uso por aplicacao real |
| Alder Lake real, NVMe fisico | O sistema roda no i5-12600K e no NVMe desde 2026-09-02 |
| Audio da B760M-E | PipeWire 1.6.8 com WirePlumber respondendo ao `wpctl status`, com clientes conectados |

Nenhuma dessas linhas afirma que a **etapa** que as configura roda limpa — so
que o resultado existe nesta maquina. A distincao e a mesma do resto do
documento: o sistema funcionar nao prova que o codigo que o produziu esta certo,
porque houve intervencao manual no caminho.

---

## Suite de testes do host

`./tests/run-tests.sh` — **642 asercoes**. Nenhum teste particiona, monta,
baixa ou compila.

O numero estava defasado neste documento: dizia 596 quando a suite ja media 630,
antes das 12 asercoes do Ciclo 6. Contagem escrita a mao envelhece sem avisar —
a de agora foi medida somando as linhas `-> N pass` do runner.

| Grupo | Asercoes | Cobre |
|---|---|---|
| `bash -n` | 22 | sintaxe de todos os scripts e testes |
| ShellCheck | — | container, repo montado read-only |
| `test-safety` | 32 | `TARGET_ROOT` canonicalizado, `AUTO_CONFIRM` nao bypassa REFORMAT, preflight antes do destrutivo, flags de `lsblk`/`findmnt` **executadas**, globais de particao |
| `test-steps-invariants` | 35 | flags de resume, sentinela do sync, `NVIDIA_MODE=skip`, USE do nvidia, branch systemd |
| `test-state-version` | 15 | schema/commit: igual, diferente, incompativel, corrompido, ausente |
| `test-root-fs` | 13 | matriz `ROOT_FS` x filesystem real |
| `test-secrets` | 13 | hashes fora do `vars.sh`, modo `0600`, remocao |
| `test-profile-detection` | 10 | symlink canonico, com `eselect` hostil e sem `eselect` |
| `test-qemu-profile` | 9 | `/dev/vda` explicito, default NVMe intacto, sem autodeteccao |
| `test-target-disk-required` | 8 | disco ausente/invalido aborta sem eleger substituto |
| `test-all-vars` | 5 | toda variavel de `vars.sh` atravessa para o chroot |

### Por que a suite nao substitui a execucao

Dos nove bugs encontrados, **zero** eram detectaveis estaticamente:

- 1.2, 2.2, 2.3 exigiam executar comandos externos (`lspci`, `emerge`)
- 1.3, 1.4, 2.1 exigiam observar o **efeito** de um comando que sai com 0 ou
  falha em silencio
- 1.5 exigia observar o **custo** de um resume
- 1.6 exigia um humano tentando fazer login

Os testes existem para impedir **reintroducao**, e cada um dos nove tem um
teste que o guarda. Eles nao encontram a proxima classe de bug — cada condicao
inicial nova (disco limpo, disco usado, hardware real) revela outra camada.

---

## Rodada de hardening — auditoria, sem execucao (2026-09-02)

Auditoria dos dois componentes com criterios separados. **Nenhuma instalacao foi
executada nesta rodada** — e uma revisao de codigo com testes, nao um ciclo.

### Base `00`–`06`

**Zero P0, zero P1.** As protecoes auditadas continuam corretas e nao foram
tocadas. Dois P2, ambos introduzidos nas 24h anteriores (o codigo menos
validado do repositorio):

| Achado | Correcao |
|---|---|
| `CONFIG_CFG80211_CRDA_SUPPORT=n` adicionado especulativamente, com sintaxe divergente do resto do arquivo e sem beneficio demonstrado | Removido |
| `fstab` escrevia `passno 1` para a raiz independente do tipo; com btrfs isso faz o boot depender do `btrfs-progs` so para rodar um stub que sai 0 | `passno` derivado do tipo real: 0 para btrfs, 1 para ext4/xfs |

Verificacao que **nao** gerou mudanca: os simbolos de cripto do `iwd` que
entraram no array `required` do `verify_kconfig` exigem `=y` estrito — se algum
nao tivesse prompt, o portao bloquearia a instalacao com falha falsa. Conferidos
no Kconfig do upstream: todos `tristate` com prompt, dependencias presentes no
fragmento. **Correto como esta.**

### Desktop `10`–`15`

**Zero P0, zero P1. Um P2.**

A premissa de que o `--dry-run` nao era enforcado **nao se confirmou**. Auditoria
de mutacoes em nivel superior antes da guarda, em todos os numerados: a unica
ocorrencia era uma *definicao de funcao*. As etapas 10-15 ja eram seguras.

O problema real era o `10a`, que usava `die` inline em vez do guard no topo:
seguro (nada mutava), mas saia com codigo != 0 e **abortava a cadeia** — um
`--dry-run --with-profile-world` nunca chegava a mostrar 11-15. Alinhado.

**Documentacao contradizia o codigo, na direcao perigosa:** o `desktop/README.md`
afirmava que a flag **nao era enforcada** e mandava nao confiar nela. Descrevia
um estado antigo — os guards foram adicionados depois daquele texto e o README
nao acompanhou. Corrigido, com a tabela do que cada teste prova.

`tests/test-desktop-dryrun.sh` (novo, 12 asercoes): snapshot de conteudo, dono e
modo antes/depois, stubs que registram invocacao de comando mutavel, e teste
unitario do proprio `dry_run_guard`.

**Limite declarado no teste e no README:** fora de um Gentoo alvo os scripts
param na guarda de fase, que vem antes da de dry-run. O snapshot prova "num host
que nao e o alvo, nada muta" — valida a guarda de fase, nao o dry-run num Gentoo
real. Alcancar a de dry-run exigiria uma porta para pular a de fase, e criar essa
porta seria pior que a lacuna. Dai o teste unitario do mecanismo.

### Nao auditado nesta rodada

Os itens B2-B8 do escopo pedido — etapas 10-15 em profundidade, NVIDIA/Wayland,
perfil, GURU, servicos, configs de usuario e validacao grafica. Nao estao
reportados como auditados porque nao foram.

---

## Ciclo 3 — btrfs (2026-09-02): **fechado com boot**, apos tres correcoes

**Ambiente:** o mesmo QEMU/OVMF, `ROOT_FS=btrfs`, sobre o disco do Ciclo 2.

O `_confirm_reformat` disparou como projetado (pediu `REFORMAT /dev/vda3`, sem
bypass por `AUTO_CONFIRM`) — primeira vez que esse caminho rodou. A instalacao
completou. O primeiro boot caiu em:

```
error: ...grub_fs_probe:122:unknown filesystem.
Entering rescue mode...
grub rescue>
```

### 3.1 — `block-group-tree` torna a raiz ilegivel para o GRUB

**Diagnostico, do `grub rescue>` para tras:**

| Evidencia | O que descartou |
|---|---|
| `prefix='(hd0,gpt3)/boot/grub'`, `root='hd0,gpt3'` | o `grub-install` acertou o enderecamento |
| `ls` mostra `(hd0,gpt1) (hd0,gpt2) (hd0,gpt3)` | o GRUB enxerga as particoes |
| `/usr/lib/grub/x86_64-efi/btrfs.mod` existe (32 KB) | o modulo esta instalado |
| `grub-probe --target=fs /boot/grub` → `btrfs` | a deteccao do `grub-install` funcionou |

Sobrou uma causa: o GRUB nao consegue **abrir** o filesystem. As flags disseram
qual:

```
compat_ro_flags   0xb    = FREE_SPACE_TREE + _VALID + BLOCK_GROUP_TREE
incompat_flags    0x361  = MIXED_BACKREF + BIG_METADATA + EXTENDED_IREF
                           + SKINNY_METADATA + NO_HOLES
```

Os `incompat` sao todos antigos e suportados. O culpado e o bit 3 do
`compat_ro`: **`BLOCK_GROUP_TREE`** (`include/uapi/linux/btrfs.h` do kernel).
O `mkfs.btrfs` moderno o liga **por default**, e o `grub-core/fs/btrfs.c` nao
tem **uma unica referencia** ao simbolo nem checa `compat_ro` — ele tenta ler os
block groups do jeito antigo, falha, e o probe generico reporta
"unknown filesystem".

**Correcao:** `mkfs.btrfs -f -O ^block-group-tree` no `00-partition.sh`.
`--modules=btrfs` no `grub-install` **nao** resolveria: o modulo ja estava la.

**A lacuna que isto expos:** o `05` verificava o **conteudo** dos arquivos —
`grub.cfg` existe, referencia o kernel corrente, `PARTUUID` bate. Nenhuma
verificacao perguntava se o GRUB consegue **abrir o filesystem em que eles
estao**. Todas passaram num sistema que nao boota.

Novo portao `assert_boot_fs_readable_by_grub` no `05`, antes do `grub-install`:
com raiz btrfs, le `compat_ro_flags` e morre com mensagem acionavel se o bit 3
estiver ligado. Cobre o caso de a raiz vir de outro lugar — `mkfs` a mao, disco
reaproveitado, ou mudanca de default do btrfs-progs.

**Testes:** `tests/test-root-fs.sh` ganhou 6 asercoes — o `mkfs` desliga a
feature, e o portao reprova `0xb` (o valor real da VM) e aprova `0x3`.

> Bug meu: adicionei `ROOT_FS=btrfs` cuidando do kernel (`BTRFS_FS=y`) e do
> `btrfs-progs`, e **nao verifiquei o GRUB**. Neste layout o `/boot` vive dentro
> da raiz, entao o bootloader tambem precisa ler o filesystem — uma terceira
> ponta que passou despercebida.

---

### 3.2 — a sentinela de resume virava uma entrada de boot falsa

Achado durante a **reexecucao** do Ciclo 3, lendo a saida do `grub-mkconfig` na
etapa `05`:

```
Found linux image: /boot/vmlinuz-6.18.48-gentoo
Found linux image: /boot/kernel-fragment.sha256-6.18.48-gentoo
```

A segunda linha e a sentinela de resume do kernel — 130 bytes de texto com dois
hashes, gravada por mim em `/boot` justamente para sobreviver ao `--reset`. O
`/etc/grub.d/10_linux` itera sobre `/boot/vmlinuz-* /boot/vmlinux-* /vmlinuz-*
/vmlinux-* /boot/kernel-*` e gera um menuentry por match, **sem olhar o
conteudo**. O nome casava com o ultimo glob.

Efeito: menu com uma entrada que nao boota. O sistema subia mesmo assim, porque
`GRUB_DEFAULT=0` pega a primeira entrada e essa era o kernel real — mas a ordem
vem de uma ordenacao por versao, nao de uma garantia.

**Severidade:** media. Nao impediu o boot, e teria sido invisivel em qualquer
teste automatizado que verificasse apenas "o grub.cfg menciona o kernel atual" —
o probe do `05` fazia exatamente isso e passava.

**Correcao:** sentinela renomeada para
`/boot/gentoo-install.kernel-sha256-<kver>`, que nao casa com nenhum dos cinco
globs. O `04` migra automaticamente o nome antigo que encontrar; o probe do
`05-grub-cfg` reprova um `grub.cfg` que ainda cite o nome velho, entao um
sistema ja instalado se corrige na proxima execucao sem recompilar o kernel.
Seis asercoes novas comparam a sentinela contra os cinco globs reais do GRUB.

> Segundo bug do Ciclo 3 com a mesma forma do primeiro: cuidei do que o
> **kernel** precisa e esqueci do que o **GRUB** faz. Os dois foram achados
> lendo a saida do instalador, nao por analise estatica.

### 3.3 — `./install.sh` sem `ROOT_FS` propunha reformatar a raiz pronta

Ao reexecutar o instalador sobre a instalacao btrfs recem-concluida, sem
`ROOT_FS=btrfs` no ambiente:

```
[AVISO] [00-mkfs-root] marker existia mas o probe reporta nao-feito — marker obsoleto removido, re-executando
[00-mkfs-root] executando...
[ERRO] particao /dev/vda3 esta montada em '/mnt/gentoo' — desmonte antes de reformatar
```

O `vars.sh` faz `: "${ROOT_FS:=ext4}"`. Sem a variavel no ambiente a execucao
declara `ext4`, o `probe_mkfs_root` compara com o `btrfs` real, reporta
nao-feito, e o `run_step` chama `do_mkfs_root`.

**Nada foi destruido.** Dois guards independentes barraram, na ordem: a
particao montada, e — se estivesse desmontada — o prompt `REFORMAT /dev/vda3`,
que por design **nao** e dispensado por `AUTO_CONFIRM=yes`. O comportamento
destrutivo estava corretamente contido.

O defeito era de **diagnostico**: nenhuma das mensagens dizia a causa, e
"desmonte antes de reformatar" instrui o operador a remover justamente o guard
que o salvou.

**Correcao:** `_assert_root_fs_not_forgotten`, chamada antes dos outros dois
guards. Quando a raiz ja contem um filesystem **suportado** diferente do
declarado e o layout GPT esta intacto (`do_gpt` nao rodou nesta execucao), ela
aborta nomeando os dois filesystems e imprimindo os dois comandos possiveis:
`ROOT_FS=<real> ./install.sh` para retomar, `--reset --repartition` para
realmente refazer. Filesystem nao suportado (ntfs, vfat de outro SO) nao cai
nesse caminho — esse e o caso legitimo de reaproveitar disco alheio, e segue
para o prompt `REFORMAT`.

Oito asercoes cobrem a matriz: caso real, disco em branco, tipos iguais, GPT
recriado e filesystem alheio.

**Confirmado em execucao** (2026-09-02, mesma sessao): a reexecucao seguinte,
novamente sem a variavel, abortou com a mensagem nova em vez da antiga:

```
[00-mkfs-root] executando...
[ERRO] a raiz /dev/vda3 ja contem um filesystem 'btrfs', mas esta execucao declara
ROOT_FS='ext4'. [...] Para RETOMAR a instalacao que esta no disco:
ROOT_FS=btrfs ./install.sh.
```

Este e um dos poucos itens deste documento cuja **correcao** — nao so o bug —
foi verificada rodando o instalador.

> Achado por **operacao**, nao por execucao do codigo de teste: a instrucao que
> eu mesmo dei ao operador omitia a variavel.

### 3.4 — Boot confirmado

Reexecucao com `ROOT_FS=btrfs`, sem `--repartition` (a raiz ja estava correta):
as etapas `00`–`03` passaram por probe, o `04` renomeou a sentinela **sem
recompilar** e o `05` regenerou o `grub.cfg`. Conferencia antes do reboot:

```sh
grep -n 'linux[[:space:]]*/boot/' /mnt/gentoo/boot/grub/grub.cfg
115:    linux /boot/vmlinuz-6.18.48-gentoo root=PARTUUID=383490be-... ro intel_iommu=on
127:      linux /boot/vmlinuz-6.18.48-gentoo root=PARTUUID=383490be-... ro intel_iommu=on
138:      linux /boot/vmlinuz-6.18.48-gentoo root=PARTUUID=383490be-... ro single intel_iommu=on
```

Tres entradas (principal, avancada, recovery), todas apontando para o kernel
real; nenhuma linha `initrd`, coerente com o design sem initramfs.

**Boot:** `This is gentoo (Linux x86_64 6.18.48-gentoo)`, login como usuario
normal, runlevel 3 completo — `syslogd`, `cronie`, `dbus`, `iwd`, `dhcpcd`,
`sshd`. Raiz btrfs montada e remontada read-write pelo OpenRC.

**Confirmacao pelo sistema em execucao** (`fastfetch`, apos `emerge` bem-sucedido
no proprio sistema instalado — o que tambem prova que o Portage funciona pos-boot):

```
OS: Gentoo Linux x86_64
Kernel: Linux 6.18.48-gentoo
Packages: 377 (emerge)
CPU: 6 x 12th Gen Intel(R) Core(TM) i5-12600K (6) @ 3.69 GHz
Swap: 0 B / 16.00 GiB (0%)
Disk (/): 8.98 GiB / 43.00 GiB (21%) - btrfs
Local IP (enp1s0): 192.168.122.61/24
Locale: pt_BR.utf8
```

A linha `Disk (/): ... btrfs` e a evidencia direta: o filesystem raiz declarado
foi o que o sistema em execucao reporta. Junto vem a confirmacao de quatro
coisas que as etapas anteriores prometeram e ninguem tinha visto funcionando ao
mesmo tempo: swap de 16 GiB ativa (`00`), locale `pt_BR.utf8` (`03`), rede por
DHCP (`06`) e o Portage operando no alvo.

> A CPU reportada e a **real** (i5-12600K), nao uma generica do QEMU: o `-cpu
> host` esta passando. Como o bare metal alvo tem essa mesma CPU, o aviso do
> preflight sobre `-march=native` ("o build so serve se o alvo tiver a MESMA
> CPU") esta satisfeito neste caso — coincidencia util, nao garantia.

Com isso o `ROOT_FS=btrfs` sai da lista de "sem validacao": ele tem **um** ciclo
completo com boot. O ext4 continua com dois.

**Pendencias observadas neste boot, nao investigadas:**

| Sintoma | Estado |
|---|---|
| `ERROR: user.<usuario> failed to start` no login | **Aberto** — servico de sessao do OpenRC; nao e criado por este instalador |
| `sysctl: net.core.default_qdisc ... Arquivo ou diretorio inexistente` | Cosmetico — a opcao de kernel correspondente nao esta no fragmento |
| `sudo: comando nao encontrado` | **Corrigido** na mesma sessao (etapa `06-sudo`), ainda **nao executado** |

---

### Confianca operacional

| | |
|---|---|
| Base | **Alta** — tres ciclos QEMU + boot e um bare metal + boot, 596 asercoes. Nenhuma execucao limpa com o codigo atual |
| Desktop | **Baixa, inalterada** — nunca executado. Esta rodada melhorou consistencia e cobertura de teste; nao substitui execucao |
