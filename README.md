# gentoo-install — instalacao automatizada do Gentoo (AMD64, UEFI)

Scripts bash para instalar o Gentoo seguindo o Handbook AMD64, numerados por
etapa, idempotentes e retomaveis.

Este projeto e **hardware-targeted de proposito**. Ele **nao** e um instalador
generico de Gentoo e nao pretende ser. Alvo unico:

| Componente | Modelo |
|---|---|
| Placa-mae | ASUS TUF GAMING B760M-E D4 (firmware 1836, UEFI) |
| CPU | Intel i5-12600K (Alder Lake, 6P+4E, 16 threads) |
| GPU | NVIDIA RTX 5060 Ti 16GB (Blackwell/GB206) |
| RAM | 32 GiB DDR4 |
| Disco | NVMe |
| Boot | UEFI, GPT, **sem initramfs** |

Em hardware incompativel o objetivo e **falhar limpo** (ver
[Preflight de hardware](#preflight-de-hardware)), nao funcionar por acidente.

---

## ESTADO DE VALIDACAO — leia antes de usar

Esta secao e a informacao mais importante do repositorio. Ela e literal.

### Analise estatica

| Verificacao | Estado |
|---|---|
| `bash -n` (sintaxe) em todos os scripts | **Passou** |
| ShellCheck (container, repo montado read-only) | **Passou** |
| Auditoria adversarial multi-agente (44 problemas encontrados) | **Feita**; os corrigiveis em codigo foram corrigidos |
| Suite de testes do host (`tests/run-tests.sh`) | **Passou** — 466 asercoes em 10 grupos |

### Execucao em QEMU/OVMF — **dois ciclos completos, com boot** (2026-09-01)

Duas instalacoes inteiras executadas, ambas com o sistema resultante **bootando**.
VM: OVMF/UEFI, 6 vCPUs, disco **virtio** (`/dev/vda`), `NVIDIA_MODE=force`, OpenRC.

- **Ciclo 1** — disco em branco. Encontrou 5 problemas.
- **Ciclo 2** — **reinstalacao sobre o disco ja usado** (caminho de codigo que
  nunca tinha sido exercitado). Encontrou mais 3, e concluiu com o
  `nvidia-drivers` **compilado** contra o kernel gerado.

> **[docs/VALIDACAO.md](docs/VALIDACAO.md)** tem o registro completo: cada bug,
> sintoma, causa raiz, correcao, commit e o teste que o guarda.

A tabela abaixo descreve as etapas; todas passaram nos dois ciclos.

| Etapa | Estado | O que ficou provado |
|---|---|---|
| `preflight_hardware` | **Passou** | Classificou VM (qemu), vendor Intel, modelo repassado por `-cpu host`, UEFI ativo com efivars montado |
| `00-partition` | **Passou** | GPT, ESP/swap/raiz, `mkfs`, mount — num disco virtio |
| `01-stage3` | **Passou** | Import da chave releng + conferencia de fingerprint, pointer assinado, download, `gpg --verify` do `.asc`, `sha256sum --check`, extracao. `stage3.identity` gravado com o sha256 real |
| `02-portage-config` | **Passou** | `make.conf` e `package.license` escritos de fora do chroot |
| `03-chroot-setup` | **Passou** | `emerge-webrsync` + sync, perfil `23.0`, locale, `fstab` por UUID (ESP em `/efi` `umask=0077` passno 2, raiz passno 1, swap). News reportadas e **nao** marcadas como lidas (`count new` = 1) |
| `04-kernel` | **Passou** | `eselect kernel` por versao, `merge_config` + `olddefconfig`, **`verify_kconfig` aprovou**, kernel 6.18.48 compilado, `modules_install`, `depmod`, e `make install` gravando `vmlinuz-6.18.48-gentoo` |
| `05-bootloader` | **Passou** | `grub-install` UEFI, entrada de NVRAM criada no OVMF (`Boot0002* gentoo`), `grub-mkconfig` validado com `grub-script-check` |
| `06-users-services` | **Passou** | Hostname, `/etc/hosts`, keymap, **`passwd` interativo atraves do chroot**, usuario + grupos, `dosfstools`, servicos no runlevel |
| **Boot do sistema instalado** | **Passou** | GRUB → kernel **sem initramfs** → raiz montada por `root=PARTUUID` → console → OpenRC runlevel 3 → `sshd`/`dhcpcd`/`cronie`/`syslogd` de pe |

Verificacoes feitas antes do reboot: o `root=PARTUUID` do `grub.cfg` **bate
exatamente** com o `blkid` da particao raiz; `/boot` tem o kernel versionado; a
NVRAM registrou a entrada. No boot, `fsck.fat` rodou na ESP com sucesso — o que
so e possivel porque a etapa `06` instala `sys-fs/dosfstools` (a ESP tem
`passno 2` no fstab; sem `fsck.vfat` o `localmount` do OpenRC nao subiria).

**Nove bugs reais encontrados pelos dois ciclos**, todos corrigidos. Os cinco do
Ciclo 1:

1. **Guarda de disco funcionando** — a VM usa `/dev/vda` e o `TARGET_DISK`
   default e `/dev/nvme0n1`. O instalador **abortou** em vez de adivinhar
   disco. Nao era bug: e a guarda fazendo o trabalho dela. Motivou o
   [`tests/qemu-profile.env`](tests/qemu-profile.env), que fixa o disco
   explicitamente para o ambiente de teste.
2. **`preflight_hardware` morria sem GPU NVIDIA** — `lspci | grep` sem match
   sai com 1, o `pipefail` propagava e o `set -e` matava o preflight
   exatamente no caso que o codigo tratava como aviso.
3. **`make install` gravava `/boot/vmlinuz` sem versao** — faltava
   `sys-kernel/installkernel`; o fallback do kernel copia sem sufixo de versao,
   tenta o LILO e **sai com 0**. Pego pela verificacao pos-instalacao; sem ela
   o `05` teria gerado um `grub.cfg` apontando para um kernel inexistente.
4. **`probe_default_grub` reprovava o arquivo que o `do_fn` acabara de
   escrever** — o probe exige "nenhum `root=` ativo" mas varria o arquivo
   inteiro, e o comentario que explica por que nao ha `root=` contem a string
   quatro vezes. Sintoma: *"do_fn terminou mas o probe ainda reporta
   nao-feito"*.
5. **Resume caro** — `emerge <pacote>` re-mergeia o que ja esta instalado. Um
   resume que reprovava por faltar **um** pacote pequeno remergia o
   `linux-firmware` inteiro (~2GB). Corrigido com `--noreplace`.

O **Ciclo 2** (reinstalacao sobre disco usado) encontrou mais tres, resumidos:

6. **`lsblk -nrpo NAME --list` e invalido** (`-r` ja e `--raw`). O comando saia
   com 1, a substituicao de processo devolvia vazio, e o laco de `umount` que
   solta o disco antes do zap **nao rodava — em silencio**. A guarda falhava
   **aberta**, e o `BLKRRPART` falhava depois.
7. **`nvidia-drivers[tools]`** puxava `nvidia-settings` → GTK → `cairo[X]`,
   travando o emerge no autounmask.
8. **`libglvnd[X]`**, ultima dependencia de `nvidia-drivers[X]`.

**Nenhum dos nove e detectavel por analise estatica.** Uns exigem executar
comandos externos, outros observar o *efeito* de um comando que sai com 0, um
exige medir o **custo** de um resume, e um exige um humano tentando fazer login.
A auditoria adversarial de 13 dimensoes, o `bash -n` e o ShellCheck passaram por
cima de **todos**.

### O que continua **NAO** validado

| Verificacao | Estado |
|---|---|
| Boot em **bare metal** | **NUNCA** |
| **Runtime** NVIDIA (modulo, GSP, modeset, Blackwell) | **Impossivel em QEMU** — o Ciclo 2 validou o **build**, nao o funcionamento |
| NVRAM do firmware **ASUS 1836** (o OVMF nao e ele) | **NUNCA** |
| Alder Lake real: ITMT, Thread Director, `intel_pstate`/`intel_idle` | **NUNCA** |
| NVMe fisico, rede e audio da B760M-E | **NUNCA** |
| Suspend/resume | **NUNCA** |
| Re-execucao / resume apos falha real | **Executado ~9x** (involuntariamente, a cada bug) |
| Reinstalacao sobre disco ja usado | **Executada** (Ciclo 2) |
| Instalacao limpa com o codigo ATUAL, sem intervencao | **NUNCA** — cada ciclo corrigiu bugs no meio |
| `ROOT_FS=btrfs` | **Instalou, mas NAO bootou** no Ciclo 3 (`block-group-tree`). Corrigido; a correcao ainda nao foi reexecutada |
| Branch `INIT_SYSTEM=systemd` | **NUNCA** executado |

### Traduzindo

A instalacao roda de ponta a ponta e o sistema resultante **boota**, numa VM,
com OpenRC — em disco limpo e tambem por cima de uma instalacao anterior. Isso
foi provado duas vezes, em 2026-09-01, e o `nvidia-drivers` **compilou** contra
o kernel gerado.

Isso ainda **nao** e reprodutibilidade: cada ciclo corrigiu bugs no meio, entao
nenhuma instalacao completa foi feita com o codigo exatamente como esta hoje.
E **nao** e o hardware alvo — QEMU nao e uma B760M-E com uma RTX 5060 Ti.

A parte do projeto que mais pode dar errado — o driver NVIDIA proprietario
**carregando** numa GPU Blackwell fisica, com o firmware GSP e o handoff de
KMS — e justamente a que uma VM sem passthrough PCI nunca vai tocar. O Ciclo 2
provou que o driver **compila**; nao que ele funciona.

O branch `INIT_SYSTEM=systemd` continua sem nenhuma execucao.

Antes de rodar isto num disco com dados, leia a secao **[SO BARE METAL]**
abaixo e **[docs/ARMADILHAS.md](docs/ARMADILHAS.md)** — manual de operacao com
o comando exato de verificacao para cada armadilha conhecida, a saida esperada
e o que fazer quando der errado.

### Legenda usada no restante deste README

| Marca | Significado |
|---|---|
| **[SUPORTADO]** | Implementado no codigo e revisado por leitura |
| **[QEMU-OK]** | Executado com sucesso na VM QEMU/OVMF — ver tabela acima |
| **[QEMU-ABLE]** | *Poderia* ser validado em QEMU — **ainda nao foi** |
| **[SO BARE METAL]** | Impossivel validar em QEMU; exige o hardware fisico |
| **[NAO VALIDADO]** | Sem execucao de nenhum tipo |

**[QEMU-OK]** significa "isto rodou ate o fim numa VM, **uma vez**". Nao
significa que e reproduzivel, nem que funciona no hardware de referencia. Uma
VM QEMU e um conjunto de dispositivos virtio com um firmware OVMF — nao e uma
B760M-E com uma RTX 5060 Ti.

Nao ha nada marcado **VALIDADO FISICAMENTE** neste documento, porque nao ha
nada nesse estado.

---

## Limitacoes conhecidas

### O que uma VM QEMU nunca vai validar **[SO BARE METAL]**

Mesmo depois de rodar a receita QEMU abaixo com sucesso, tudo isto continua sem
validacao:

- **Runtime da RTX 5060 Ti** — carga real do modulo `nvidia`, presenca efetiva
  de `/lib/firmware/nvidia/<ver>/gsp_*.bin` na mesma versao do modulo,
  comportamento do ramo 580.x + `kernel-open` vs >= 595. Uma VM sem passthrough
  PCI nao tem GPU NVIDIA no barramento.
- **DRM/KMS e console pre-driver** — a transicao
  `SYSFB_SIMPLEFB`/`DRM_SIMPLEDRM` → `nvidia` so se observa no monitor fisico
  ligado a GPU real. Risco de tela preta.
- **NVRAM do firmware ASUS 1836** — o OVMF da VM nao e o firmware da ASUS, que
  tem historico de perder/reordenar entradas de boot. O codigo cria o fallback
  `EFI/BOOT/BOOTX64.EFI`, mas nao pode provar que o firmware o respeita.
- **NVMe real e geometria pos-reparticionamento** — se o `BLKRRPART` do
  `sgdisk` pega, se os device nodes reaparecem com a geometria nova, e o timing
  do udev.
- **Alder Lake** — se `SCHED_MC_PRIO` (ITMT) e `INTEL_HFI_THERMAL` (Thread
  Director) funcionam sob o kernel gerado, e se o `intel_pstate`/`intel_idle`
  assumem.
- **Suspend/resume (S3/s2idle)** com o driver proprietario — **zero cobertura
  no repositorio**.
- **Rede e audio da B760M-E**, e HDMI audio da GPU.

### Boot sem initramfs **[QEMU-OK]** **[SO BARE METAL: nao validado]**

Decisao de design deliberada, e o invariante mais fragil do projeto.

**Nao ha initramfs e nao ha shell de recuperacao.** Todo driver da cadeia ate a
raiz precisa ser **built-in** (`=y`): controlador NVMe → filesystem da raiz →
resolucao do `root=PARTUUID=` → teclado USB (para um eventual prompt de fsck ou
senha) → console. Qualquer um faltando produz uma maquina que **nao boota**, sem
prompt para consertar.

O gate `verify_kconfig` (etapa 04) exige explicitamente os simbolos criticos —
`BLK_DEV_NVME`, `VIRTIO_BLK`, `HID`/`USB_HID`/`HID_GENERIC`, `FW_LOADER`, `EFI`,
`DEVTMPFS`, o grupo de console (`DRM`, `SYSFB_SIMPLEFB`, `DRM_SIMPLEDRM`,
`DRM_FBDEV_EMULATION`, `FRAMEBUFFER_CONSOLE`), `INTEL_IDLE` e as NLS. Isso
**reduz** o risco; **nao substitui** um boot real.

Mantenha SEMPRE um live USB gravado e testado ao alcance, e **nao remova a
entrada de boot da distro anterior** ate um boot completo ter sucesso.

### Idempotencia e resume **[NAO VALIDADO]**

Toda a analise de probes e markers foi **estatica**. Nenhuma re-execucao foi
observada. Defeitos de resume so se manifestam em execucoes repetidas **com
interrupcoes** — exatamente o que nao foi exercitado.

Evite `Ctrl-C` durante o `emerge-webrsync` e durante o build do kernel. Ver
[docs/ARMADILHAS.md](docs/ARMADILHAS.md), secao 13.

### Inits suportados **[SUPORTADO]**

`INIT_SYSTEM=openrc` (default) e `INIT_SYSTEM=systemd`. A variavel deriva
**tudo**: stage3 baixado, perfil eselect 23.0, arquivos de hostname/keymap,
`svc_enable` e pacotes extras.

Trocar `INIT_SYSTEM` **depois** do stage3 extraido e **fatal por design**: a
etapa 01 detecta o mismatch de flavor e manda rodar
`./install.sh --reset --repartition`.

Nenhum dos dois foi executado. O caminho systemd tem uma diferenca estrutural:
`machine-id`, `firstboot` e `preset-all` (enable-only), este ultimo chamado
incondicionalmente, fora de `run_step`.

### Gentoo News **[SUPORTADO]**

A etapa 03 conta os news items novos e **imprime o conteudo integral no log**
(`eselect news read --quiet new`, que exibe **sem** marcar como lido). Ela
**nao para** para voce ler.

Por padrao (`READ_NEWS=no`) as news continuam **NAO LIDAS**: o Portage segue
avisando a cada `emerge` ate voce le-las de fato. E deliberado — news carregam
migracoes obrigatorias (perfil 23.0, merged-usr, mudanca de USE) que quebram as
etapas 04/05/06 horas depois, e marcar como lido automaticamente transforma uma
instrucao de migracao numa falha misteriosa de build.

Com `READ_NEWS=yes` a etapa 03 marca como lidas ao final, silenciando o aviso.
Use so em instalacao automatizada/descartavel onde voce ja conhece o conteudo.

O relato distingue tres estados: falha na consulta (`log_warn` com o exit code),
saida nao-numerica (`log_warn` de saida inesperada) e zero real. A afirmacao
"nenhum news item novo" so aparece com exit 0 **e** saida numerica igual a zero
— ela nunca e impressa por engano.

**A responsabilidade de ler e sua**, e a fonte e o log da etapa 03.

---

## Preflight de hardware **[SUPORTADO]** **[NAO VALIDADO]**

Antes de qualquer operacao destrutiva, `preflight_hardware()` imprime uma tabela
com um veredicto por item e aborta se algo for comprovadamente incompativel.

Roda em `install.sh:512`, no inicio de `main_live()` — depois de
`compute_partitions()`, **antes** de `do_reset`, `repartition_prep` e da etapa
00. Tambem e chamado por `confirm_destruction()`, idempotente via guard
`PREFLIGHT_DONE`.

### Aborta (FALHA)

Apenas os itens confiaveis de detectar **e** realmente fatais:

- **Firmware sem UEFI** (`/sys/firmware/efi` ausente) — a etapa 05 instala GRUB
  `x86_64-efi` e o layout tem ESP; o sistema instalado nao daria boot.
- **CPU nao-Intel** (`vendor_id != GenuineIntel`) — CFLAGS/USE, perfil e o
  fragmento (`INTEL_IDLE`/`INTEL_PSTATE`) sao Intel-especificos.
- **`TARGET_DISK` nao e um block device** — nao existe, nao ha onde instalar.
- **`TARGET_DISK` nao e um disco inteiro** (`lsblk TYPE != disk`) — e uma
  particao.
- **`CFLAGS_ARCH=native` numa CPU emulada generica** — geraria binarios
  invalidos em silencio.
- **`HW_PREFLIGHT_STRICT=yes` com >= 1 aviso.**

### So avisa (AVISO)

Modelo de CPU diferente de i5-12600K; `nproc != 16`; CPU nao-hibrida; plataforma
desconhecida; `vendor_id` ilegivel (ausencia de dado nao e prova de AMD); UEFI
ativo mas efivars nao montado; placa diferente da B760M-E D4 ou DMI ilegivel;
GPU NVIDIA presente mas nao identificada como Blackwell; **nenhuma GPU NVIDIA no
barramento** (explicitamente **nao** fatal — a VM precisa passar, e o 04 decide
via `NVIDIA_MODE`); barramento PCI nao enumeravel; sem controlador NVMe em bare
metal; RAM < 30 GiB; `MAKEOPTS -jN` > `nproc+1` ou < 1 GiB de RAM por job;
`CFLAGS_ARCH=native` em VM com `-cpu host`; nenhum controlador de rede visto
pelo `lspci`.

Nenhum match exato de modelo (placa, GPU, VRAM) e obrigatorio.

### Variaveis

| Var | Default | Efeito |
|---|---|---|
| `SKIP_HW_PREFLIGHT` | `no` | Pula o preflight **inteiro**, inclusive os gates fatais. Escape hatch de risco assumido |
| `HW_PREFLIGHT_STRICT` | `no` | Promove **todo** aviso a falha (modo CI/producao) |

---

## Ordem de execucao

1. **Boote o minimal install ISO** do Gentoo (amd64) na maquina alvo (ou na VM).
   Confirme o modo UEFI: `ls /sys/firmware/efi` deve existir.
2. **Copie este diretorio** para o live system:
   ```sh
   # de outra maquina, com sshd ativo no live ISO (passwd + rc-service sshd start):
   scp -r gentoo-install/ root@IP-DO-LIVE:/root/
   # ou de um pendrive:
   mount /dev/sdX1 /mnt/usb && cp -r /mnt/usb/gentoo-install /root/
   ```
3. **Leia [docs/ARMADILHAS.md](docs/ARMADILHAS.md)**, secoes 1 e 2, e confirme
   qual e o disco alvo:
   ```sh
   lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,PARTLABEL
   findmnt -rno TARGET --source /dev/nvme0n1   # deve sair VAZIO
   ```
4. **Edite `vars.sh`** — no minimo confira `TARGET_DISK` (bare metal NVMe:
   `/dev/nvme0n1`; VM virtio: `/dev/vda`). Symlinks estaveis
   (`/dev/disk/by-id/...`) sao aceitos e recomendados: a validacao canonicaliza
   o caminho e prompts/logs mostram o nome canonico. Toda variavel aceita
   override por ambiente: `TARGET_DISK=/dev/vda ./install.sh`.
5. **Rode `./install.sh`**. Executa 00→02 no live, monta proc/sys/dev/run, copia
   os scripts para dentro do alvo, entra no chroot e roda 03→06. Ao final
   imprime as instrucoes de `umount -R` + reboot (**nao** reboota sozinho).

### Guardas destrutivas **[SUPORTADO]**

O `00-partition.sh` mostra `lsblk` + `sgdisk -p` do disco, exibe **modelo,
serial e tamanho** (o nome de kernel e volatil entre boots) e exige digitar
literalmente `ERASE <disco>`. A confirmacao so aparece quando o layout real
**nao** bate com o esperado — re-execucoes num disco ja particionado passam
direto.

Uma confirmacao **independente**, `REFORMAT <device>`, e exigida quando um
`mkfs` vai destruir um filesystem existente sem que o particionamento tenha
rodado nesta execucao (caso tipico: trocar `ROOT_FS`). Esse prompt **ignora
`AUTO_CONFIRM`** e le de `/dev/tty`; sem tty, aborta.

Guardas anti-host: rodar a fase live a partir de um sistema **instalado** aborta
cedo na validacao — `ALLOW_INSTALLED_HOST=yes` existe para quem deliberadamente
instala num segundo disco. `AUTO_CONFIRM=yes` pula o prompt `ERASE` **somente**
em live ISO/VM: num sistema instalado e **ignorado**. Swap alheia ativa no disco
alvo bloqueia a validacao, e a swap so e reconhecida como nossa por
**`PARTLABEL`**, nunca por posicao no disco.

Cada script `NN-*.sh` roda standalone (para debug), com guarda de fase: 00–02 so
na fase live, 03–06 so dentro do chroot.

---

## Arquivos

| Arquivo | Fase | O que faz |
|---|---|---|
| `vars.sh` | — | Somente variaveis editaveis com defaults e comentarios (sourced, nunca executado) |
| `lib.sh` | — | Funcoes compartilhadas: logging, state/markers, `run_step`, guardas de fase, particoes, mounts, `confirm_destruction`, `preflight_hardware`, `svc_enable` |
| `00-partition.sh` | live | GPT via sgdisk (ESP 1GiB `/efi` + swap + root, partlabels `gentoo-esp/swap/root`), mkfs (vfat/swap/ext4-ou-xfs), mount em `/mnt/gentoo` |
| `01-stage3.sh` | live | Confere o relogio (NTP automatico se atrasado, com limite superior pela expiracao da chave), importa a chave releng num keyring de chave **unica**, baixa pointer + stage3 do flavor `$INIT_SYSTEM`, verifica GPG + sha256 + tamanho, extrai |
| `02-portage-config.sh` | live | `make.conf` (`-march=native -O2 -pipe`, `MAKEOPTS`, `VIDEO_CARDS=nvidia`, `ACCEPT_LICENSE=@FREE`) + dirs `package.*` + licenca `NVIDIA-2025` |
| `03-chroot-setup.sh` | chroot | `emerge-webrsync` + sync, news items, perfil eselect 23.0, timezone, locales, fstab por UUID real, `@world` opcional (`UPDATE_WORLD`) |
| `04-kernel.sh` | chroot | gentoo-sources + linux-firmware + intel-microcode; `defconfig` + merge do fragmento + `olddefconfig` + gate `verify_kconfig`; build/install; nvidia-drivers (auto/force/skip) |
| `05-bootloader.sh` | chroot | GRUB UEFI: `/etc/default/grub` (`intel_iommu=on`; o `root=PARTUUID=` vem do `10_linux`, nao e escrito a mao), `grub-install --efi-directory=/efi`, `grub-mkconfig` validado com `grub-script-check` e publicado atomicamente |
| `06-users-services.sh` | chroot | Hostname, `/etc/hosts`, keymap, senhas, usuario + grupos, dhcpcd/sysklogd/cronie, `svc_enable` sshd/dhcpcd; no systemd: machine-id + firstboot + `preset-all` enable-only |
| `install.sh` | ambas | Orquestrador: preflight, 00→02 no live, mounts do chroot, re-entrada com `--chroot`, 03→06 dentro do alvo |
| `kernel-fragment.config` | — | Fragmento Kconfig comentado por bloco (Alder Lake, B760, NVMe built-in, handoff NVIDIA, IOMMU, EFI, virtio para a VM) |
| `docs/ARMADILHAS.md` | — | **Manual de operacao**: como nao cair nas armadilhas conhecidas |
| `docs/VALIDACAO.md` | — | **Registro factual** dos ciclos executados: cada bug, causa raiz, correcao, commit e teste que o guarda |
| `docs/PROXIMOS-PASSOS.md` | — | **Estado operacional**: onde paramos, o proximo passo, os discos desta maquina e como sair do buraco. Escrito para ser lido do telefone |
| `docs/audit/` | — | Achados brutos da auditoria adversarial multi-agente |
| `README.md` | — | Este arquivo |
| `tests/run-tests.sh` | host | Roda `bash -n`, ShellCheck e os testes unitarios. **Nao executa o instalador** |
| `tests/qemu-profile.env` | VM | Perfil do ambiente de teste: `TARGET_DISK=/dev/vda` explicito, `AUTO_CONFIRM=yes`, `NVIDIA_MODE=force` |
| `tests/run-in-qemu-guest.sh` | VM | Roda o instalador dentro da VM com o perfil acima; recusa rodar se nao detectar virtualizacao |
| `tests/test-qemu-profile.sh` | host | Prova que o perfil usa `/dev/vda`, que o default de producao segue NVMe e que nao ha autodeteccao nem fallback de disco |
| `tests/test-target-disk-required.sh` | host | Prova que `TARGET_DISK` ausente/invalido causa falha dura, sem eleger outro disco |
| `tests/test-safety.sh` | host | `TARGET_ROOT` canonicalizado, `AUTO_CONFIRM` nao bypassa o REFORMAT, preflight antes de tudo que destroi, guardas de mount por `findmnt` |
| `tests/test-secrets.sh` | host | Hashes de senha nao ficam no `vars.sh` persistente; `secrets.env` 0600, removido ao final |
| `tests/test-state-version.sh` | host | Identidade do state (schema + commit): mesmo commit, commit diferente, schema incompativel, state corrompido/ausente |
| `tests/test-root-fs.sh` | host | Filesystem REAL da raiz manda sobre `ROOT_FS`; 03 e 06 usam a mesma autoridade |
| `tests/test-profile-detection.sh` | host | Perfil vem do symlink canonico, nao da posicao das linhas do `eselect` |
| `tests/test-all-vars.sh` | host | Toda variavel de `vars.sh` atravessa para o chroot (`ALL_VARS` + `SECRET_VARS`) |
| `tests/test-steps-invariants.sh` | host | Flags de resume, sentinela do sync, `NVIDIA_MODE=skip` como omissao, branch systemd |

A suite do host cobre **configuracao, guardas de disco e invariantes de
estado** — nao comportamento de runtime. Nenhum teste particiona, monta, baixa
ou compila coisa alguma. Um teste estatico que passa **nao** significa que a
etapa correspondente foi validada; significa que a propriedade que ele afirma
continua verdadeira no codigo.

### Senhas e material sensivel

Os hashes de `ROOT_PASSWORD_HASH`/`USER_PASSWORD_HASH` **nao** ficam no
`vars.sh` que sobra em `/root/gentoo-install/` do sistema instalado. Eles vao
para um `secrets.env` ao lado, com modo `0600`, que o `vars.sh` gerado carrega
quando existe — e que e **removido ao final da instalacao**.

Consequencias praticas:

- Uma instalacao interrompida **mantem** o `secrets.env` (o resume
  nao-interativo continua funcionando). Ele so e removido no caminho de
  sucesso do fluxo completo.
- Se voce abortar de vez uma instalacao com hashes configurados, remova o
  arquivo a mao: `rm -f /mnt/gentoo/root/gentoo-install/secrets.env`.
- Sem `secrets.env`, o `vars.sh` continua sourceavel e as etapas caem no
  `passwd` interativo — que e o comportamento padrao do projeto.
- O `vars.sh` do **seu** diretorio de trabalho e seu: se voce escreveu hashes
  ali, eles continuam ali. O instalador so cuida do que ele proprio escreve no
  alvo.

---

## Flags do install.sh

| Flag | Efeito |
|---|---|
| *(sem args)* | Fluxo completo da fase corrente: live = 00→02 + chroot automatico com 03→06; dentro do chroot = 03→06 |
| `--chroot` | Uso interno (re-entrada no chroot); pode ser usado manualmente para retomar so a fase chroot |
| `--from N` | Comeca no script `N` e segue ate a **06**, atravessando as duas fases |
| `--only N` | Roda somente o script `N` |
| `--reset` | Apaga **somente** o state dir (markers) no alvo; nao toca no disco |
| `--reset --repartition` | Alem do state, forca o 00 a tratar o layout como nao-feito: re-exige `ERASE` e reparticiona. Necessario para trocar `INIT_SYSTEM` no meio |

---

## Semantica de resume e `--reset` **[NAO VALIDADO]**

> Descreve o **design**. Nenhuma re-execucao real foi observada — ver
> [Limitacoes conhecidas](#idempotencia-e-resume-nao-validado).

- **Tudo e retomavel por design.** Cada script e uma sequencia de sub-etapas
  `run_step <nome> <probe> <do>`. O **probe e a autoridade**: se o estado real
  do sistema ja esta correto, a sub-etapa e pulada — **mesmo sem marker**. Se o
  probe reprova, a sub-etapa roda de novo — **mesmo com marker**.
- Crash ou `Ctrl-C`: rode `./install.sh` de novo. Vale inclusive apos **reboot
  do live ISO** — o state dir vive no filesystem alvo
  (`$TARGET_ROOT/var/lib/gentoo-install/state`) e a sub-etapa de mount e sempre
  re-executada.
- Nenhuma acao destrutiva decide com base em marker — so no estado real
  (`sgdisk -i`, `blkid`, mounts). Por isso `--reset` e barato: apaga so os
  markers.
- **Artefato funcional que sobrevive ao `--reset`:** o hash do fragmento e do
  vmlinuz em `/boot/gentoo-install.kernel-sha256-<kver>` (dois campos). **Nao apague
  esse arquivo a mao** — sem ele, `--reset` forca horas de recompilacao.
- **Invalidacao automatica:** editar `kernel-fragment.config` muda o hash e
  forca rebuild; rebuild invalida nvidia e grub.cfg; reparticionar invalida o
  fstab e o `root=PARTUUID`.
- **Identidade do state.** O state guarda quem o produziu, em
  `.../state/.installer` (`schema=` + `commit=`). Ao retomar:

  | Situacao | O que acontece |
  |---|---|
  | Mesmo commit | Silencio, resume normal |
  | Commit diferente, mesmo schema | **Aviso** citando os dois commits; resume continua |
  | Schema diferente | **Aborta** — o formato do state mudou e retomar seria adivinhacao |
  | `.installer` corrompido ou sem `schema=` | **Aborta** (fail-closed) |

  Nenhum desses caminhos apaga state. Se voce precisar comecar limpo, remova o
  diretorio de state a mao: os probes reexaminam o disco, entao nada que ja
  esta feito e refeito. Fora de um checkout git (o caso dentro do chroot) o
  commit e registrado como `nao-versionado` — o instalador nunca inventa um SHA.
- Logs: tela **e** `/var/log/gentoo-install/<script>.log` no alvo (o log do 00
  comeca em `/tmp` e e anexado apos o mount).
- Ao final do fluxo completo com sucesso, o workdir do stage3 e removido. Um
  resume posterior **nao** re-baixa nada.

---

## Receita QEMU/libvirt **[QEMU-OK — instalacao completa + boot]**

> Esta receita **nunca foi rodada**. Ela e o plano de validacao, nao um relato
> de validacao. Mesmo se passar por inteiro, ela nao valida nada da lista
> [SO BARE METAL] acima.

Requisitos **obrigatorios**:

- **OVMF (UEFI)** — os scripts assumem UEFI (ESP, grub `x86_64-efi`). Sem OVMF
  a VM boota em BIOS legado e o preflight aborta. No Fedora:
  `sudo dnf install edk2-ovmf`.
- **`-cpu host`** (com KVM) — `CFLAGS_ARCH=native` compila para a CPU onde o gcc
  roda. Sem `-cpu host`, `-march=native` mira a CPU **falsa** emulada e os
  binarios podem nao rodar no bare metal. O preflight aborta nesse caso.
- Disco **virtio** ⇒ `TARGET_DISK=/dev/vda`.
- `AUTO_CONFIRM=yes` para automacao. **Jamais** use fora de VM.

```sh
# 1) Imagem de disco e firmware UEFI (VARS precisa de copia gravavel)
qemu-img create -f qcow2 gentoo-test.qcow2 60G
cp /usr/share/edk2/ovmf/OVMF_VARS.fd ./OVMF_VARS-gentoo.fd

# 2) Baixe o minimal install ISO amd64 em https://www.gentoo.org/downloads/

# 3) Boot da VM
qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -smp 12 \
  -m 16G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=./OVMF_VARS-gentoo.fd \
  -drive file=gentoo-test.qcow2,if=virtio,format=qcow2 \
  -cdrom install-amd64-minimal-*.iso \
  -boot order=d \
  -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 \
  -display gtk
```

Dentro do live da VM:

```sh
passwd                      # senha temporaria de root
rc-service sshd start
# do host: scp -P 2222 -r gentoo-install/ root@localhost:/root/

cd /root/gentoo-install
./tests/run-in-qemu-guest.sh
```

`run-in-qemu-guest.sh` le o perfil da VM de
[`tests/qemu-profile.env`](tests/qemu-profile.env), que fixa
**`TARGET_DISK=/dev/vda`** (o disco virtio do QEMU), `AUTO_CONFIRM=yes`,
`NVIDIA_MODE=force`, e deriva `MAKEOPTS` das vCPUs da VM. Ele existe para o
disco alvo **nao** depender de voce lembrar de digitar a variavel: esquecer
faz o instalador abortar com `TARGET_DISK=/dev/nvme0n1 nao existe` — que e o
comportamento **correto** (ele nunca adivinha disco), mas o teste nao roda.

O runner **nao afrouxa nenhuma guarda**: ele delega para o `install.sh`, que
segue rodando `validate_vars`, `preflight_hardware` e `confirm_destruction`.
Ele **adiciona** uma guarda propria — recusa rodar se nao detectar
virtualizacao, porque o perfil carrega `AUTO_CONFIRM=yes`.

Flags sao repassadas: `./tests/run-in-qemu-guest.sh --only 0`.

Equivalente manual, se preferir explicito na linha de comando:

```sh
TARGET_DISK=/dev/vda AUTO_CONFIRM=yes NVIDIA_MODE=force MAKEOPTS=-j13 ./install.sh
```

Notas:

- `NVIDIA_MODE=force` valida o **build** do driver (inclusive o `CONFIG_CHECK`
  do ebuild contra o nosso kernel). Com o default `auto` a etapa e pulada com
  aviso, e reativa sozinha no bare metal.
- `MAKEOPTS` default e `-j17` (16 threads + 1). Com `-smp 12`, passe `-j13`.
- No **primeiro boot do sistema instalado**, remova o ISO e reutilize o
  **mesmo** `OVMF_VARS-gentoo.fd` (e nele que o grub-install grava a NVRAM).
- libvirt: firmware = "UEFI x86_64 (OVMF)", CPU = "host-passthrough", disco
  virtio.

---

## Troubleshooting

Para verificacao **preventiva** com comandos e saidas esperadas, use
**[docs/ARMADILHAS.md](docs/ARMADILHAS.md)**. Abaixo, so os erros do instalador.

- **Preflight aborta:** a tabela diz qual item reprovou e o que fazer. Os
  fatais sao UEFI ausente, CPU nao-Intel, `TARGET_DISK` invalido e
  `native` em CPU emulada. `SKIP_HW_PREFLIGHT=yes` pula **tudo**, por sua conta
  e risco.
- **`validate_vars` morre com "TARGET_DISK ... sustenta o /":** voce apontou o
  alvo para o disco do sistema em execucao. Ver ARMADILHAS secao 1.
- **01 morre com "relogio do sistema esta antes de ...":** o live ISO subiu com
  data absurda e TLS + GPG falhariam com erros cripticos. O script tenta
  sincronizar sozinho (`chronyd -q`/`ntpd -q -g`, timeout 60s). Ha tambem um
  limite **superior**: relogio adiantado alem de 2028-07-01 avisa que a chave
  releng "expirada" e provavelmente relogio errado.
- **01 falha na verificacao GPG:** cheque rede/DNS
  (`ping distfiles.gentoo.org`). O import tenta `hkps://keys.gentoo.org` e cai
  para `/usr/share/openpgp-keys/gentoo-release.asc`. O fallback extrai
  **somente** a chave do fingerprint esperado, via keyring temporario. Falha de
  verificacao deleta o tarball — basta rodar de novo. Fingerprint divergente =
  **NAO prossiga**.
- **01 morre com mismatch de flavor:** voce trocou `INIT_SYSTEM` depois do
  extract. Rode `./install.sh --reset --repartition` ou volte o valor antigo.
- **04 morre em `verify_kconfig`:** um simbolo critico nao vingou no `.config`
  final. A mensagem diz qual. Ajuste `kernel-fragment.config` (os blocos
  comentam o motivo de cada simbolo) e rode de novo — o hash muda e o rebuild e
  automatico.
- **04/nvidia morre por versao insuficiente:** o script tenta `~amd64` sozinho;
  se ainda assim nao ha versao >= `NVIDIA_MIN_VER` (580.173.02, minimo para
  Blackwell), o mirror/arvore esta velho — `emerge --sync` e repita.
- **04/nvidia aborta por `kernel-open` no ramo >= 595:** o script varre
  `/etc/portage/package.use` e o `USE=` do `make.conf` e lista cada arquivo
  ofensor. Isso e **fail-closed antes do emerge**, para nao falhar apos horas de
  compilacao.
- **VM nao boota apos instalar (cai no shell UEFI):** firmware perdeu a NVRAM —
  reuse o mesmo `OVMF_VARS` ou reinstale com `GRUB_REMOVABLE=yes`. No shell
  UEFI: `FS0:\EFI\gentoo\grubx64.efi`.
- **Kernel nao acha a raiz (`VFS: unable to mount root`):** ver ARMADILHAS
  secao 6. Sem initramfs **nao ha prompt de recuperacao** — boote o live USB.
- **Tela preta quando o nvidia carrega:** ver ARMADILHAS secao 8
  (`nvidia_drm.modeset=1`, depois
  `initcall_blacklist=simpledrm_platform_driver_init`).
- **Sem rede no primeiro boot:** ver ARMADILHAS secao 11 (`ip link` distingue
  driver faltando de DHCP que nao subiu).
- **Onde olhar quando algo falha:** o trap de erro imprime sub-etapa, arquivo,
  linha e o caminho do log (`/var/log/gentoo-install/*.log` no alvo). O state
  fica em `/var/lib/gentoo-install/state`.
