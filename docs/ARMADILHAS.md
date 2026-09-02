# ARMADILHAS — manual de operacao

Este documento e um **tutorial pratico**: para cada armadilha conhecida, o que
pode dar errado, **como verificar ANTES** (comando exato + saida esperada) e o
que fazer quando der errado.

Le-se na ordem. As secoes 1–4 sao **antes de rodar o instalador**, as 5–7 sao
**antes do primeiro reboot**, as 8–12 sao **no primeiro boot**, as 13–15 sao
**recuperacao e limpeza** (retomar apos falha, hashes de senha que sobram,
retomar com outra versao do instalador) e a 16 e especifica de **btrfs**.

> **Regra de ouro deste projeto:** nada aqui foi executado em hardware real.
> Mantenha SEMPRE um live USB gravado e testado ao alcance, e **nao apague a
> instalacao anterior** ate um boot completo ter sucesso.

---

## 1. Disco com mais de um mountpoint (o que o `lsblk` esconde)

**O que pode dar errado:** voce aponta `TARGET_DISK` para um disco que parece
livre, mas que sustenta o `/` ou o `/home` do sistema em execucao. O instalador
apaga o disco debaixo do sistema vivo.

**Por que o `lsblk` engana:** a coluna `MOUNTPOINT` (singular) do `lsblk -nr`
mostra **um** mountpoint por dispositivo. Um filesystem btrfs com subvolumes —
ou qualquer bind mount — tem varios. O `lsblk` mostra so o primeiro, e a guarda
te deixa passar.

**Verifique ANTES** (o `findmnt` enumera TODAS as linhas):

```sh
findmnt -rno TARGET --source /dev/nvme0n1
```

Saida esperada para um disco **realmente livre**: **vazio** (nenhuma linha).

Saida perigosa — este e o caso real do host onde este projeto foi escrito:

```
/
/home
```

Compare com o que o `lsblk` mostraria do mesmo disco (revela so `/home`, e voce
concluiria que da para apagar):

```sh
lsblk -nrpo NAME,MOUNTPOINT /dev/nvme0n1
```

Confira tambem se ha **swap ativa** no disco alvo:

```sh
cat /proc/swaps
```

Saida esperada: so o cabecalho `Filename Type Size Used Priority`, ou nenhuma
linha referente ao disco alvo.

**Se der errado:** disco errado. Reveja `TARGET_DISK` no `vars.sh`. **Nao**
tente desmontar o `/` do sistema em execucao. Se o alvo for mesmo um segundo
disco e o instalador reclamar, e porque o alvo escolhido nao e o que voce pensa.

> O instalador ja usa `findmnt` como fonte de verdade (correcao P0-1) e aborta
> sozinho. Esta checagem manual existe para voce **saber qual disco escolher**
> antes de editar o `vars.sh`, nao para substituir a guarda.

---

## 2. Conferir o disco alvo antes do ERASE

**O que pode dar errado:** nomes de kernel (`/dev/nvme0n1`, `/dev/sda`) sao
**volateis entre boots**. O `nvme0n1` do live ISO de hoje pode ser o `nvme1n1`
de amanha. Voce digita `ERASE` no disco certo pelo nome e errado pelo conteudo.

**Verifique ANTES:**

```sh
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,PARTLABEL
```

Note o `MOUNTPOINTS` no **plural** — esta coluna, ao contrario de `MOUNTPOINT`,
lista todos. Saida esperada num alvo pronto para instalar (disco de dados sem
nada montado):

```
NAME        SIZE TYPE MOUNTPOINTS PARTLABEL
nvme0n1     1,8T disk
├─nvme0n1p1   1G part             gentoo-esp
├─nvme0n1p2  16G part             gentoo-swap
└─nvme0n1p3  1,8T part            gentoo-root
```

Se as `PARTLABEL` `gentoo-esp`/`gentoo-swap`/`gentoo-root` ja aparecem, este
disco **ja foi particionado por este instalador** — voce esta retomando, nao
comecando. Se aparecem outras labels e mountpoints preenchidos, **pare**.

Confirme a identidade fisica pelo modelo e serial, que **nao** mudam entre
boots:

```sh
lsblk -ndo NAME,MODEL,SERIAL,SIZE /dev/nvme0n1
```

Prefira apontar o `vars.sh` para o symlink estavel em vez do nome de kernel:

```sh
ls -l /dev/disk/by-id/ | grep nvme
# depois, no vars.sh:  TARGET_DISK=/dev/disk/by-id/nvme-Modelo_SERIAL
```

O instalador canonicaliza o symlink para o nome de kernel e mostra o nome
canonico nos prompts e logs.

**Se der errado:** o prompt exige digitar literalmente `ERASE <disco>`. Se o
modelo/serial exibidos no prompt nao forem os do disco que voce quer apagar,
**digite qualquer outra coisa** para abortar. Nada foi escrito ate esse ponto.

### 2.1. Holders no disco alvo (LVM, LUKS, MD)

**O que pode dar errado:** o disco alvo e membro de um volume group, um device
mapper ou um array MD. O reparticionamento com holders ativos corrompe.

**Verifique ANTES:**

```sh
lsblk -no NAME,TYPE /dev/nvme0n1
ls /sys/block/nvme0n1/*/holders/ 2>/dev/null
```

Saida esperada: apenas `disk` e `part` na primeira, e **nada** na segunda.

**Se der errado**, desative os holders antes de rodar o instalador:

```sh
vgchange -an              # desativa volume groups LVM
cryptsetup close <nome>   # fecha mapeamentos LUKS abertos
mdadm --stop /dev/mdX     # para arrays MD
```

---

## 3. `-march=native` em VM sem `-cpu host`

**O que pode dar errado:** `CFLAGS_ARCH=native` (default) faz o gcc compilar
para a CPU **onde ele esta rodando**. Numa VM sem `-cpu host`, essa CPU e a
falsa emulada pelo QEMU. Voce compila o sistema inteiro — horas — e os binarios
**nao rodam no bare metal**, ou rodam com `SIGILL`.

O inverso tambem e armadilha: **com** `-cpu host` numa maquina de
desenvolvimento diferente da alvo, o build so serve se o bare metal tiver a
**mesma** CPU.

**Verifique ANTES, dentro da VM:**

```sh
grep -m1 'model name' /proc/cpuinfo
```

Saida **boa** (CPU repassada, `-cpu host` funcionando):

```
model name	: 12th Gen Intel(R) Core(TM) i5-12600K
```

Saida **ruim** (CPU emulada — `-march=native` vai gerar lixo):

```
model name	: QEMU Virtual CPU version 2.5+
```

ou `Common KVM processor`.

**Se der errado**, escolha uma das tres:

```sh
# a) corrija a VM: adicione -cpu host ao qemu-system-x86_64 (exige -enable-kvm)
# b) compile generico (portavel, um pouco mais lento):
CFLAGS_ARCH=x86-64-v3 ./install.sh
# c) para Alder Lake explicitamente, sem depender de deteccao:
CFLAGS_ARCH=alderlake ./install.sh
```

O preflight ja **aborta** com `CFLAGS_ARCH=native` numa CPU emulada generica, e
**avisa** com `-cpu host` numa VM (o build so serve na mesma CPU).

---

## 4. Gentoo News: por que ler antes de continuar

**O que pode dar errado:** news items do Portage carregam **migracoes
obrigatorias** — mudanca de perfil, troca de provider padrao, mudanca de USE
global, deprecacao de pacote. Ignorar um news relevante quebra as etapas 04/05/06
horas depois, com um erro que nao menciona o news em lugar nenhum.

**Verifique ANTES de deixar o instalador seguir**, ja dentro do chroot, depois
do sync:

```sh
eselect news count new
```

Saida esperada: `0`.

Se for diferente de zero, **leia antes de prosseguir**:

```sh
eselect news list
eselect news read new
```

**Comportamento do instalador:** a etapa 03 imprime o conteudo integral dos news
no log (`eselect news read --quiet new` — exibe **sem** marcar como lido) e, com
o default `READ_NEWS=no`, **deixa-os nao lidos de proposito**. Ele nao para para
voce ler, mas o Portage vai continuar avisando a cada `emerge` ate voce le-los —
esse aviso persistente e justamente a rede de seguranca.

Depois de ler e aplicar o que for necessario, marque manualmente:

```sh
eselect news read new
```

Com `READ_NEWS=yes` em `vars.sh` o instalador marca como lidos ao final da etapa
03. **So use isso em VM descartavel**: num sistema que voce vai manter, silenciar
o aviso antes de ler e a maneira mais facil de perder uma migracao obrigatoria.

Se `eselect news count new` falhar ou devolver saida nao-numerica, o script
emite `log_warn` e segue — ele nunca afirma "zero news" sem ter tido exit 0 e
saida numerica igual a zero. Ou seja: **a responsabilidade de ler e sua**, e a
fonte e o log da etapa 03.

Para reler depois, no sistema instalado:

```sh
eselect news list
eselect news read all
```

---

## 5. O que a VM QEMU **NAO** valida

Rodar a receita QEMU do README e util e recomendado — mas entenda com precisao
o que ela prova e o que ela **nao** prova.

| Item | VM valida? |
|---|---|
| Particionamento, mkfs, mount | Sim |
| Download + GPG + sha256 do stage3 | Sim |
| make.conf, perfil, locales, fstab | Sim |
| Build do kernel + `verify_kconfig` | Sim |
| Boot sem initramfs **em virtio** | Sim |
| GRUB UEFI + NVRAM **do OVMF** | Parcial — firmware diferente |
| **Build** do nvidia-drivers (`NVIDIA_MODE=force`) | Sim |
| **Carga do modulo nvidia** | **NAO** |
| **Firmware GSP da Blackwell** | **NAO** |
| **`nvidia_drm.modeset`, saida de video** | **NAO** |
| **NVRAM do firmware ASUS 1836** | **NAO** |
| **NVMe real, `BLKRRPART`, timing do udev** | **NAO** |
| **Alder Lake: ITMT, HFI, intel_pstate, intel_idle** | **NAO** |
| **Suspend/resume** | **NAO** |
| **Rede/audio da B760M-E, HDMI audio da GPU** | **NAO** |

Uma VM **sem passthrough PCI** nao tem GPU NVIDIA no barramento. Com
`NVIDIA_MODE=auto` (default) a etapa nvidia detecta isso e se pula sozinha; com
`NVIDIA_MODE=force` ela compila e instala o pacote, o que valida o **build** e o
`CONFIG_CHECK` do ebuild contra o nosso kernel — **nada alem disso**.

Nenhuma leitura de codigo e nenhum QEMU prova inicializacao de GPU Blackwell.
As secoes 8–12 sao a validacao que resta, e ela e **empirica, no hardware**.

---

## 6. Boot sem initramfs — a cadeia completa, sem rede de seguranca

**O que pode dar errado:** este e o invariante mais fragil do projeto. **Nao ha
initramfs e nao ha shell de recuperacao.** Qualquer driver necessario que nao
esteja **built-in** (`=y`, nao `=m`) resulta em maquina que nao boota. A cadeia
inteira precisa estar no vmlinuz: controlador NVMe → filesystem da raiz →
resolucao do `root=PARTUUID=` → teclado USB (para um eventual prompt de fsck ou
senha) → console.

**Verifique ANTES do primeiro reboot**, ja dentro do chroot:

```sh
kver=$(cat /usr/src/linux/include/config/kernel.release)
for s in BLK_DEV_NVME EXT4_FS VIRTIO_BLK HID_GENERIC USB_HID FW_LOADER \
         DRM_SIMPLEDRM SYSFB_SIMPLEFB FRAMEBUFFER_CONSOLE INTEL_IDLE \
         NLS_CODEPAGE_437 NLS_ISO8859_1; do
  grep -qx "CONFIG_$s=y" /usr/src/linux/.config \
    && echo "OK   $s" || echo "FALTA $s"
done
```

Saida esperada: **`OK` em todas as linhas**. Qualquer `FALTA` numa das que sao
`=y` no fragmento e motivo para nao rebootar ainda.

Confirme que o kernel foi realmente instalado com a release esperada:

```sh
ls -l /boot/vmlinuz-*
cat /usr/src/linux/include/config/kernel.release
```

Os dois devem concordar. E confirme que o `root=` do grub.cfg aponta para o
PARTUUID real do disco:

```sh
grep -o 'root=[^ ]*' /boot/grub/grub.cfg
blkid -s PARTUUID -o value /dev/nvme0n1p3
```

Saida esperada: o mesmo UUID nos dois — e **exatamente uma** ocorrencia de
`root=` por linha `linux`.

**Antes de rebootar:** valide a imagem em QEMU com a receita do README (o
fragmento traz `VIRTIO_PCI`/`VIRTIO_BLK` como built-in justamente para a **mesma**
imagem servir VM e bare metal).

**Se der errado no boot real** (`VFS: unable to mount root fs`): boote o live
USB, remonte o alvo e corrija a partir do chroot. Nao ha atalho — sem initramfs
nao ha prompt de recuperacao.

---

## 7. NVRAM do firmware ASUS 1836 nao retem a entrada de boot

**O que pode dar errado:** o firmware ASUS tem historico de **perder ou
reordenar** entradas de boot gravadas via `efivarfs`. O `grub-install` reporta
sucesso, e na proxima vez a maquina cai no shell UEFI.

**Verifique ANTES do primeiro reboot**, apos o `grub-install`:

```sh
efibootmgr -v
```

Saida esperada — a entrada `Gentoo` existe **e** aparece na `BootOrder`:

```
BootCurrent: 0001
BootOrder: 0002,0001
Boot0002* Gentoo	HD(1,GPT,...)/File(\EFI\gentoo\grubx64.efi)
```

Confirme a rede de seguranca do caminho removable, que o instalador grava
incondicionalmente:

```sh
ls -l /efi/EFI/BOOT/BOOTX64.EFI
```

Saida esperada: o arquivo existe.

**Depois do primeiro reboot, reconfira:**

```sh
efibootmgr -v
```

**Se a entrada sumiu:** reinstale com `GRUB_REMOVABLE=yes` e passe a depender do
caminho removable (`EFI/BOOT/BOOTX64.EFI`), que nao precisa de NVRAM:

```sh
GRUB_REMOVABLE=yes ./install.sh --only 05
```

No shell UEFI da para lancar manualmente enquanto isso:

```
FS0:\EFI\gentoo\grubx64.efi
```

**Nao apague o sistema anterior antes desse segundo boot.**

---

## 8. Primeiro boot: tela preta (DRM/KMS NVIDIA)

**O que pode dar errado:** o console pre-driver usa `SYSFB_SIMPLEFB` +
`DRM_SIMPLEDRM` no framebuffer que a UEFI/GOP deixou. Em alguns setups o
simpledrm **nao solta** o framebuffer para o `nvidia-drm`, e a tela apaga quando
o modulo nvidia carrega. Isso e comportamento de runtime de video: **nenhum teste
estatico revela**.

**Prepare-se ANTES:** boote a primeira vez com o monitor ligado **tambem** na
saida de video da placa-mae (iGPU do i5-12600K), alem da GPU — ou deixe acesso
por SSH pronto (`ENABLE_SSHD=yes` e senha de root definida). Assim voce nao
perde o console se a tela apagar.

**Verifique no primeiro boot:**

```sh
cat /sys/class/vtconsole/vtcon*/name
dmesg | grep -i simpledrm
```

Saida esperada: uma das linhas de `vtcon` diz `frame buffer device`, e o `dmesg`
mostra o simpledrm registrando o framebuffer.

**Se a tela ficar preta apos o carregamento do nvidia**, tente nesta ordem:

```sh
# 1) habilite o modeset do nvidia-drm (via SSH ou console da iGPU)
echo 'options nvidia_drm modeset=1' > /etc/modprobe.d/nvidia-drm.conf
```

Se nao resolver, tire o simpledrm do caminho pela cmdline, em
`/etc/default/grub`, na linha `GRUB_CMDLINE_LINUX`:

```
initcall_blacklist=simpledrm_platform_driver_init
```

e regenere:

```sh
grub-mkconfig -o /boot/grub/grub.cfg
```

Efeito colateral: **sem console grafico ate o nvidia-drm assumir** — a tela fica
preta no inicio do boot por design. Isso e esperado, nao e falha.

### Ultimo recurso: a iGPU como saida de emergencia

Se nada acima devolver imagem, existe um caminho independente do NVIDIA. O
kernel do projeto traz **`CONFIG_DRM_I915=m`** de proposito — a iGPU do
i5-12600K (UHD 770).

Na maquina de referencia a iGPU esta **desligada na UEFI**, entao esse modulo
normalmente nem carrega. Ele existe exatamente para esta hora:

1. Desligue a maquina e entre na UEFI (`Del` no POST, na ASUS).
2. Habilite a iGPU. Na TUF B760M-E costuma estar em
   **Advanced → System Agent (SA) Configuration → Graphics Configuration**,
   como `iGPU Multi-Monitor` (Enabled) ou `Primary Display` (IGFX/Auto).
3. **Mova o cabo do monitor** para a saida de video da PLACA-MAE (HDMI ou
   DisplayPort da placa, nao da GPU). Este passo e o mais esquecido: habilitar a
   iGPU sem trocar o cabo continua dando tela preta, e voce conclui que nao
   funcionou.
4. Bote. O `i915` carrega apos a raiz montar e assume o video.

Voce entra num sistema **funcionando**, com rede e terminal, para diagnosticar o
NVIDIA com calma:

```sh
lsmod | grep -E 'nvidia|i915'
dmesg | grep -iE 'nvidia|nvrm|gsp|drm' | tail -40
modinfo nvidia | grep ^version
ls /lib/firmware/nvidia/*/gsp_*.bin
```

Sem essa rede de seguranca, o mesmo resgate exigiria **recompilar o kernel** —
pela tela preta que voce esta tentando consertar, ou de dentro de um chroot no
live USB. Por isso o `i915` esta la mesmo sem nunca ser usado no dia a dia.

Depois de resolver, desligue a iGPU de novo (ou nao — ela nao atrapalha; so
consome alguns MB de RAM de sistema e um pouco de tempo de boot).

**Nao conclua que a instalacao falhou por causa de tela preta** antes de testar
o acesso por SSH: o sistema pode estar rodando perfeitamente sem video.

---

## 9. Primeiro boot: runtime da RTX 5060 Ti e firmware GSP

**O que pode dar errado:** a Blackwell (GB206) **exige** o firmware GSP. Se o
blob nao estiver presente, ou sua versao nao bater com a do modulo, o driver nao
inicializa.

**Verifique no primeiro boot, ANTES de confiar na instalacao:**

```sh
lsmod | grep nvidia
modinfo nvidia | grep ^version
ls /lib/firmware/nvidia/*/gsp_*.bin
dmesg | grep -i gsp
```

Saida esperada: o modulo `nvidia` carregado, e a versao do `modinfo` **igual** ao
diretorio sob `/lib/firmware/nvidia/`. Exemplo coerente:

```
version:        580.173.02
/lib/firmware/nvidia/580.173.02/gsp_ga10x.bin
```

Se as versoes **divergirem**, o firmware nao vai carregar — e o sintoma no
`dmesg` e claro:

```sh
dmesg | grep -i 'failed to load firmware'
```

**Se o modulo nao carregar:** cheque o `dmesg` por `Failed to load firmware`
**antes de reinstalar qualquer coisa**. Reinstalar sem ler o erro geralmente
reproduz o mesmo estado. Confirme que `CONFIG_FW_LOADER=y` esta no kernel (secao
6) — sem ele o kernel nao busca blobs de firmware.

---

## 10. Primeiro boot: Alder Lake (hibrido, energia, cpuidle)

**O que pode dar errado:** o driver de idle cai para `acpi_idle` em vez de
`intel_idle`, e o consumo e a temperatura em idle ficam mais altos. O
`CONFIG_INTEL_IDLE` e `bool` **sem `default`** no Kconfig — se nao for pedido
explicitamente, o `olddefconfig` o fixa em `n` **em silencio**.

**Verifique no primeiro boot:**

```sh
cat /sys/devices/system/cpu/cpuidle/current_driver
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
cat /proc/sys/kernel/sched_itmt_enabled
nproc
```

Saida esperada:

```
intel_idle
intel_pstate
1
16
```

**Se `current_driver` disser `acpi_idle`:** recompile com
`CONFIG_INTEL_IDLE=y` antes de considerar a maquina pronta. O fragmento ja pede
esse simbolo e o `verify_kconfig` ja o exige — se mesmo assim caiu em
`acpi_idle`, a causa e outra (ver `dmesg | grep -i idle`).

---

## 11. Primeiro boot: rede e audio

**O que pode dar errado:** o driver de rede da B760M-E nao esta no kernel novo,
e voce fica sem rede **e** sem SSH — justamente o acesso alternativo da secao 8.

**Verifique ANTES do primeiro reboot**, ainda no live ISO, e **anote**:

```sh
lspci -k | grep -A3 -i ethernet
```

Saida tipica na B760M-E (2.5GbE Intel):

```
Kernel driver in use: igc
```

Realtek usa `r8169`. Ambos sao `=m` no fragmento.

**No primeiro boot, se nao houver rede**, distinga os dois casos:

```sh
ip link
```

- A interface **existe** (ex.: `enp4s0`) mas esta `DOWN` → e so DHCP: confirme
  `ENABLE_DHCP=yes` e suba o servico.
- A interface **nao existe** → driver faltando no kernel novo. Compare com o
  `lspci -k` que voce anotou no live ISO.

Mantenha `ENABLE_SSHD=yes` e uma senha de root definida, para ter acesso
alternativo caso o console grafico falhe.

---

## 12. Suspend/resume com o driver NVIDIA proprietario

**O que pode dar errado:** historicamente o caminho mais fragil da combinacao
NVIDIA proprietario + DRM. **Zero cobertura neste repositorio.**

**Nao conte com suspend ate testa-lo explicitamente.** Para habilitar:

```sh
echo 'options nvidia NVreg_PreserveVideoMemoryAllocations=1' \
  > /etc/modprobe.d/nvidia-suspend.conf
systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service
```

(No OpenRC, os equivalentes vem no proprio pacote `nvidia-drivers`.)

**Teste com todo o trabalho salvo**, num console TTY **sem sessao grafica
aberta**, para que uma falha nao derrube trabalho real:

```sh
systemctl suspend
```

---

## 13. Recuperacao: retomar apos falha

### O que o `--reset` faz e o que **nao** faz

```sh
./install.sh --reset
```

- **Faz:** apaga **somente** o diretorio de state (markers) em
  `/var/lib/gentoo-install/state` no filesystem alvo.
- **NAO faz:** nao toca no disco, nao apaga particoes, nao apaga o sistema
  instalado, nao re-baixa o stage3.

Depois do `--reset`, os **probes funcionais** decidem tudo do zero: o que ja
esta correto no sistema real (particao com o type/label certo, arquivo com o
hash certo, pacote no VDB, kernel em `/boot`) continua sendo detectado como
correto e e pulado. Por isso o `--reset` e barato e seguro.

Para tambem invalidar o layout do disco:

```sh
./install.sh --reset --repartition
```

Isso re-exige a confirmacao `ERASE <disco>` e **reparticiona/reformata**. E o
caminho obrigatorio para trocar `INIT_SYSTEM` no meio da instalacao.

### Retomar apos crash, Ctrl-C ou reboot do live ISO

```sh
./install.sh
```

O state dir vive **no filesystem alvo**, e a sub-etapa de mount e sempre
re-executada para restaura-lo. Retoma na sub-etapa exata que faltou.

Retomar so a partir de uma etapa:

```sh
./install.sh --from 04     # retoma do kernel, segue ate a 06
./install.sh --only 05     # roda somente o bootloader
```

### Onde interromper com seguranca

**Evite `Ctrl-C` durante o `emerge-webrsync` e durante o build do kernel.** Sao
as duas janelas onde uma interrupcao deixa estado parcial. Se precisar
interromper, faca **entre etapas** — o log nomeia a sub-etapa corrente.

**Apos qualquer interrupcao:** confira o log da execucao anterior antes de
prosseguir, e prefira re-executar com `--reset` da etapa afetada em vez de
confiar no resume automatico.

### Onde olhar quando algo falha

```sh
ls -l /var/log/gentoo-install/          # um log por script, no alvo
ls -l /var/lib/gentoo-install/state/    # um arquivo por sub-etapa
```

O trap de erro imprime sub-etapa, arquivo, linha e o caminho do log. Alguns
markers carregam valor: flavor do stage3, hash do fragmento, versao do nvidia.

### Artefatos que **nao** devem ser apagados a mao

```
/boot/kernel-fragment.sha256-<kver>
```

E ele que permite ao probe reconhecer um kernel ja correto **sem marker**. Apagar
esse arquivo forca horas de recompilacao no proximo `--reset`.

### Reparticionou depois do 05?

O `root=PARTUUID=` do GRUB ficou obsoleto. Regrave:

```sh
./install.sh --only 05                 # do live ISO (entra no chroot sozinho)
./install.sh --chroot --only 5         # ja dentro do chroot
```

### Geometria pos-reparticionamento

Se o script abortar dizendo que **o kernel nao releu a tabela de particoes**,
**NAO force**. Reinicie o live ISO e re-execute. Insistir sobre a geometria
antiga corrompe dados.

---

## 14. Hashes de senha: o que sobra depois de uma instalacao abortada

**O que pode dar errado:** se voce configurou `ROOT_PASSWORD_HASH` ou
`USER_PASSWORD_HASH` em `vars.sh`, o instalador transporta esses hashes para o
alvo num arquivo separado, `secrets.env`, com modo `0600`. Ele e removido
automaticamente **no fim de uma instalacao completa e bem-sucedida**.

Numa instalacao que voce **abortou no meio**, o arquivo continua la — de
proposito, para o resume nao-interativo funcionar. Se voce desistiu de vez
daquele alvo, ele fica esquecido.

**Verifique** (do live ISO, com o alvo montado):

```sh
ls -l /mnt/gentoo/root/gentoo-install/secrets.env
```

Saida esperada numa instalacao concluida: `No such file or directory`.

Se existir e voce nao vai retomar, remova:

```sh
rm -f /mnt/gentoo/root/gentoo-install/secrets.env
```

**No sistema ja instalado e bootado**, confira que nada sensivel sobrou:

```sh
grep -l 'PASSWORD_HASH' /root/gentoo-install/* 2>/dev/null
ls -l /root/gentoo-install/secrets.env 2>/dev/null
```

Ambos devem sair vazios. O `vars.sh` que fica em `/root/gentoo-install/`
**nao** contem hashes — ele so declara os nomes com valor vazio.

**Nota:** o `vars.sh` do **seu** diretorio de trabalho (de onde voce rodou o
instalador) e seu. Se voce escreveu hashes ali, eles continuam ali; o
instalador so gerencia o que ele proprio escreve no alvo.

---

## 15. Retomar com uma versao diferente do instalador

**O que pode dar errado:** voce comeca a instalacao, faz `git pull` (ou troca de
branch), e retoma. O state no disco foi produzido por uma versao do codigo e
esta sendo consumido por outra.

O instalador detecta e reage conforme a gravidade — ele **nunca apaga o state
sozinho**.

**Commit diferente, mesmo formato de state** — voce vai ver:

```
[AVISO] State foi criado pelo installer commit abc123...; o installer atual e def456...
[AVISO] Schema 1 e o mesmo, entao o resume CONTINUA normalmente — mas se o
        comportamento das etapas mudou entre as duas versoes, o estado ja
        gravado reflete a versao antiga.
```

Isso e **informativo**. Na pratica e o caso normal deste projeto: voce puxa uma
correcao e retoma. Se a correcao mudou o comportamento de uma etapa **ja
marcada como feita**, considere forcar aquela etapa com `--only N`.

**Schema diferente** — o instalador **aborta**:

```
[ERRO] state INCOMPATIVEL: foi criado com schema N e este installer usa schema M.
```

Aqui o formato do state mudou entre as versoes e retomar seria chute. Duas
saidas: use a versao que criou o state, ou remova o diretorio de state e
re-execute.

```sh
rm -rf /mnt/gentoo/var/lib/gentoo-install/state
```

Remover o state **nao** refaz nada que ja esta pronto: os probes reexaminam o
disco (particoes, filesystems, stage3 extraido, kernel em `/boot`) e pulam o que
ja existe. O unico custo real e o `nvidia-drivers`, que reinstala em minutos.

**State corrompido** (arquivo `.installer` ilegivel ou sem `schema=`) — aborta
tambem, pelo mesmo motivo e com a mesma saida.

Para ver quem produziu o state atual:

```sh
cat /mnt/gentoo/var/lib/gentoo-install/state/.installer
```

Dentro do chroot os scripts nao estao num checkout git, entao o commit aparece
como `nao-versionado`. Isso e esperado — o instalador nao inventa um SHA.

---

## 16. btrfs: `grub rescue> unknown filesystem` no primeiro boot

**O que pode dar errado:** a instalacao com `ROOT_FS=btrfs` completa, todas as
verificacoes passam — `grub.cfg` gerado e validado, kernel versionado em
`/boot`, `root=PARTUUID` correto — e o primeiro boot cai em:

```
error: ...grub_fs_probe:122:unknown filesystem.
Entering rescue mode...
grub rescue>
```

**Causa:** o `mkfs.btrfs` moderno liga a feature **`block-group-tree`** por
default, e o driver btrfs do GRUB **nao a suporta** — o `grub-core/fs/btrfs.c`
nao tem uma referencia sequer ao simbolo. O GRUB tenta ler os block groups do
jeito antigo, falha, e reporta o filesystem como desconhecido.

Importa neste projeto porque o `/boot` vive **dentro da raiz**: o GRUB precisa
ler btrfs para achar o proprio `grub.cfg`. Com `/boot` separado em ext4 a
feature seria irrelevante.

**Verifique ANTES do reboot**, com o alvo montado:

```sh
btrfs inspect-internal dump-super /dev/nvme0n1p3 | grep compat_ro_flags
```

Saida **boa** (sem a feature):

```
compat_ro_flags     0x3
```

Saida **ruim** — o bit 3 (`0x8`) ligado:

```
compat_ro_flags     0xb
```

`0xb` = `FREE_SPACE_TREE` + `FREE_SPACE_TREE_VALID` + **`BLOCK_GROUP_TREE`**.

> O `05-bootloader.sh` ja faz essa checagem sozinho e **aborta antes do
> `grub-install`** com mensagem explicita. Esta verificacao manual serve para
> quem quer conferir por conta, ou esta diagnosticando um sistema criado por
> outro caminho.

**Se der errado:** o filesystem precisa ser **recriado** — nao ha como desligar
`block-group-tree` num btrfs ja formatado. Do live ISO:

```sh
mkfs.btrfs -f -O '^block-group-tree' /dev/nvme0n1p3
```

E entao re-executar a instalacao. O `00-partition.sh` ja cria assim; este
comando serve para consertar um disco feito por fora.

**Alternativa:** `ROOT_FS=ext4`, que e o unico caminho com dois boots atras.

### Diagnostico a partir do `grub rescue>`

Se voce ja esta la, dois comandos identificam a causa sem chutar:

```
grub rescue> set
grub rescue> ls
```

O `set` mostra o `prefix` e o `root` que o `grub-install` gravou. Se estiverem
**corretos** (apontando para a particao raiz) e o `ls` **listar** as particoes,
entao o enderecamento esta bom e o problema e o GRUB nao conseguir ABRIR o
filesystem — que e exatamente este caso.

Se o `prefix` estiver errado ou vazio, o problema e outro: o `grub-install` nao
detectou o local do `/boot`, e a causa esta antes.
