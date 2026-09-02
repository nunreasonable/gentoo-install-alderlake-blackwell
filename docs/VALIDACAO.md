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
| Ciclos completos em QEMU/OVMF | **2** (instalacao ponta a ponta + boot) |
| Bugs encontrados por execucao | **9** (8 no codigo, 1 de ergonomia) |
| Bugs encontrados por analise estatica | **0** dos 9 acima |
| Suite de testes do host | 10 grupos, **466 asercoes**, exit 0 |
| Validado em hardware fisico | **nada** |

O numero que mais importa esta na terceira linha. `bash -n`, ShellCheck e uma
auditoria adversarial multi-agente de 13 dimensoes passaram por cima de **todos
os nove**. Cada um exigiu executar o codigo.

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

## O que continua sem validacao

| | Por que |
|---|---|
| Boot em **bare metal** | Nunca executado |
| **Runtime** do NVIDIA (carga do modulo, firmware GSP, modeset) | QEMU sem passthrough PCI nao tem GPU NVIDIA. O Ciclo 2 validou o **build**, nao o funcionamento |
| NVRAM do firmware **ASUS 1836** | OVMF nao e o firmware da ASUS |
| Alder Lake real (ITMT, Thread Director, `intel_pstate`/`intel_idle`) | A VM expoe 6 vCPUs homogeneas, nao 6P+4E |
| NVMe fisico, rede e audio da B760M-E | Dispositivos virtio na VM |
| Suspend/resume | Nunca executado |
| Instalacao limpa com o codigo atual, sem intervencao | Nunca executada |
| Branch `INIT_SYSTEM=systemd` | Nunca executado |

---

## Suite de testes do host

`./tests/run-tests.sh` — **140 asercoes**, exit 0. Nenhum teste particiona,
monta, baixa ou compila.

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

## Ciclo 3 — btrfs (2026-09-02): instalacao completa, **boot falhou**

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

---

### Confianca operacional

| | |
|---|---|
| Base | **Alta** — dois ciclos completos + boot, dez bugs corrigidos, 466 asercoes. Nao validada em bare metal nem com btrfs |
| Desktop | **Baixa, inalterada** — nunca executado. Esta rodada melhorou consistencia e cobertura de teste; nao substitui execucao |
