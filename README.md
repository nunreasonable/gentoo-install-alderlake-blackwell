# gentoo-install — instalacao automatizada do Gentoo (AMD64, UEFI)

Scripts bash para instalar o Gentoo seguindo o Handbook AMD64, numerados por
etapa, idempotentes e retomaveis. Alvo primario: i5-12600K (Alder Lake,
6P+4E), RTX 5060 Ti 16GB (Blackwell/GB206), 32GB RAM, UEFI, chipset
Z690/B760, boot **sem initramfs**. Testavel primeiro em VM QEMU/libvirt
(OVMF) e depois no bare metal — o mesmo kernel boota nos dois (virtio
built-in no fragmento).

> ## AVISO IMPORTANTE — VM nao valida o runtime NVIDIA
>
> Uma VM **sem passthrough PCI** valida a instalacao inteira **EXCETO o
> runtime do driver NVIDIA**. Com `NVIDIA_MODE=auto` (default), a etapa
> nvidia do `04-kernel.sh` detecta que nao ha GPU (`lspci -d 10de:`), emite
> um aviso gritante e **pula sozinha**, gravando o marker `skipped-no-gpu`.
> Esse marker so vale **enquanto nao houver GPU visivel**: ao rodar os mesmos
> scripts no bare metal, a etapa reativa automaticamente.
>
> Com `NVIDIA_MODE=force` a VM compila e instala o pacote mesmo sem GPU —
> isso valida o **build** (inclusive o CONFIG_CHECK do ebuild contra o nosso
> kernel), mas **carga do modulo, firmware GSP, modeset e display so validam
> no bare metal**.

## Ordem de execucao

1. **Boote o minimal install ISO** do Gentoo (amd64) na maquina alvo
   (ou na VM — receita QEMU abaixo). Confirme que esta em modo UEFI:
   `ls /sys/firmware/efi` deve existir.
2. **Copie este diretorio** para o live system, por exemplo:
   ```sh
   # de outra maquina, com sshd ativo no live ISO (passwd + rc-service sshd start):
   scp -r gentoo-install/ root@IP-DO-LIVE:/root/
   # ou de um pendrive:
   mount /dev/sdX1 /mnt/usb && cp -r /mnt/usb/gentoo-install /root/
   ```
3. **Edite `vars.sh`** — no minimo confira `TARGET_DISK` (bare metal NVMe:
   `/dev/nvme0n1`; VM virtio: `/dev/vda`). Symlinks estaveis
   (`/dev/disk/by-id/...`, `by-path/...`) tambem sao aceitos: a validacao
   canonicaliza o caminho para o nome de kernel, e prompts/logs mostram o nome
   canonico. Toda variavel tambem aceita override por ambiente:
   `TARGET_DISK=/dev/vda ./install.sh`.
4. **Rode `./install.sh`**. Ele executa 00→02 no live, monta proc/sys/dev/run,
   copia os scripts para dentro do alvo, entra no chroot e roda 03→06.
   Ao final imprime as instrucoes de `umount -R` + reboot (**nao** reboota
   sozinho).

Antes de qualquer acao destrutiva o `00-partition.sh` mostra `lsblk` +
`sgdisk -p` do disco e exige digitar literalmente `ERASE <disco>` — a
confirmacao so aparece quando o layout real do disco **nao** bate com o
esperado (re-execucoes num disco ja particionado passam direto). A mesma
confirmacao e re-exigida quando um `mkfs` vai destruir um filesystem
existente sem que o particionamento tenha rodado nesta execucao (caso
tipico: trocar `ROOT_FS` sobre um layout GPT ja valido).

Guardas anti-host: rodar a fase live a partir de um sistema **instalado**
(nao live ISO) aborta cedo na validacao — o override explicito
`ALLOW_INSTALLED_HOST=yes` existe para quem deliberadamente instala num
segundo disco a partir da distro atual. `AUTO_CONFIRM=yes` pula o prompt
`ERASE` **somente** em live ISO/VM: num sistema instalado ele e ignorado e a
confirmacao interativa continua obrigatoria (protecao contra um `export`
esquecido no ambiente). Swap alheia ativa no disco alvo tambem bloqueia a
validacao.

Cada script `NN-*.sh` tambem roda standalone (para debug), com guarda de
fase: 00–02 so na fase live, 03–06 so dentro do chroot.

## Arquivos

| Arquivo | Fase | O que faz |
|---|---|---|
| `vars.sh` | — | Somente variaveis editaveis com defaults e comentarios (sourced, nunca executado) |
| `lib.sh` | — | Funcoes compartilhadas: logging, state/markers, `run_step`, guardas de fase, particoes, mounts, `confirm_destruction`, `svc_enable` |
| `00-partition.sh` | live | GPT via sgdisk (ESP 1GiB `/efi` + swap + root, partlabels `gentoo-esp/swap/root`), mkfs (vfat/swap/ext4-ou-xfs), mount em `/mnt/gentoo` |
| `01-stage3.sh` | live | Confere o relogio (NTP automatico se atrasado), importa chave releng (fingerprint conferido), baixa pointer + stage3 do flavor `$INIT_SYSTEM`, verifica GPG + sha256 + tamanho, extrai. Arvore ja extraida e integra pula download/verificacao por inteiro |
| `02-portage-config.sh` | live | `make.conf` (`-march=native -O2 -pipe`, `MAKEOPTS`, `VIDEO_CARDS=nvidia`, `ACCEPT_LICENSE=@FREE`) + dirs `package.*` + licenca da NVIDIA por pacote |
| `03-chroot-setup.sh` | chroot | `emerge-webrsync` + sync, news items do Portage (impressos no log e marcados como lidos), perfil eselect 23.0, timezone, locales, fstab por UUID real, `@world` opcional (`UPDATE_WORLD`) |
| `04-kernel.sh` | chroot | gentoo-sources + linux-firmware + intel-microcode; `defconfig` + merge do fragmento + `olddefconfig` + gate `verify_kconfig`; build/install; nvidia-drivers (auto/force/skip) |
| `05-bootloader.sh` | chroot | GRUB UEFI: `/etc/default/grub` com `root=PARTUUID=...` + `intel_iommu=on`, `grub-install --efi-directory=/efi`, `grub-mkconfig` |
| `06-users-services.sh` | chroot | Hostname (`/etc/hostname`; no OpenRC tambem `/etc/conf.d/hostname`), `/etc/hosts` (hostname nas linhas de loopback, que sao reescritas), keymap, senhas (hash ou `passwd` interativo), usuario + grupos, dhcpcd/sysklogd/cronie, `svc_enable` sshd/dhcpcd; no systemd: machine-id + firstboot + `preset-all` enable-only |
| `install.sh` | ambas | Orquestrador: 00→02 no live, mounts do chroot, re-entrada com `--chroot`, 03→06 dentro do alvo |
| `kernel-fragment.config` | — | Fragmento Kconfig comentado por bloco (Alder Lake, Z690/B760, NVMe built-in, handoff NVIDIA, IOMMU, EFI, virtio para a VM) |
| `README.md` | — | Este arquivo |

## Flags do install.sh

| Flag | Efeito |
|---|---|
| *(sem args)* | Fluxo completo da fase corrente: live = 00→02 + chroot automatico com 03→06; dentro do chroot = 03→06 |
| `--chroot` | Uso interno (re-entrada dentro do chroot); pode ser usado manualmente para retomar so a fase chroot |
| `--from N` | Comeca no script `N` e segue ate a **06**, atravessando as duas fases (na fase live, apos as etapas live ele entra no chroot e continua; ex.: `--from 04` retoma do kernel) |
| `--only N` | Roda somente o script `N` |
| `--reset` | Apaga **somente** o state dir (`/var/lib/gentoo-install/state` no alvo) — os probes funcionais passam a decidir tudo do zero; nao toca no disco |
| `--reset --repartition` | Alem do state, forca o 00 a tratar o layout existente como nao-feito: re-exige a confirmacao `ERASE <disco>` e reparticiona/reformata. Necessario para trocar `INIT_SYSTEM` no meio |

## Semantica de resume e --reset

- **Tudo e retomavel.** Cada script e uma sequencia de sub-etapas
  `run_step <nome> <probe> <do>`. O **probe e a autoridade**: se o estado
  real do sistema ja esta correto (particao com o type/label certo, arquivo
  com o hash certo, pacote no VDB, kernel em `/boot`...), a sub-etapa e
  pulada — **mesmo sem marker**. Se o probe reprova, a sub-etapa roda de
  novo — **mesmo com marker** (marker obsoleto e apagado).
- Crash ou `Ctrl-C` no meio: rode `./install.sh` de novo e ele retoma na
  sub-etapa exata que faltou. Isso vale inclusive apos **reboot do live
  ISO**: o state dir vive no filesystem alvo
  (`$TARGET_ROOT/var/lib/gentoo-install/state`), e a sub-etapa de mount e
  sempre re-executada para restaura-lo.
- Nenhuma acao destrutiva decide com base em marker — so no estado real
  (`sgdisk -i`, `blkid`, mounts). Por isso `--reset` e barato e seguro:
  apaga so os markers; o que ja esta certo continua sendo detectado como
  certo pelos probes, e so o que diverge e refeito. Excecao conhecida: apos
  `--reset`, o nvidia-drivers e reinstalado mesmo integro (o probe dele
  depende do marker — custo de minutos, nao horas).
- **Artefatos funcionais que sobrevivem ao `--reset`:** o hash do fragmento
  do kernel tambem e gravado em `/boot/kernel-fragment.sha256-<kver>` junto
  do vmlinuz — **nao apague esse arquivo a mao**: e ele que permite ao probe
  reconhecer um kernel ja correto sem marker (sem ele, `--reset` forcaria
  horas de recompilacao). A arvore do stage3 e reconhecida pelo flavor
  detectado nela mesma.
- **Invalidacao automatica:** editar `kernel-fragment.config` muda o hash e
  forca rebuild do kernel; rebuild do kernel invalida nvidia (modulo por
  versao de kernel) e grub.cfg (probe procura o vmlinuz da release atual);
  reparticionar invalida o fstab e o `root=PARTUUID` do GRUB.
- **Trocar `INIT_SYSTEM` depois do stage3 extraido e fatal** por design: o
  01 detecta o mismatch de flavor e manda rodar
  `./install.sh --reset --repartition`.
- Logs: tudo vai para a tela **e** para
  `/var/log/gentoo-install/<script>.log` no filesystem alvo (o log do 00
  comeca em `/tmp` e e anexado ao alvo apos o mount).
- Ao final do fluxo completo com sucesso, o `install.sh` remove o workdir do
  stage3 (`/var/tmp/gentoo-install/stage3` no sistema instalado: tarball
  ~300MB, `.asc`/`.sha256` e keyring). Um resume posterior **nao** re-baixa
  nada: com a arvore extraida e integra, o 01 pula download/verificacao por
  inteiro. Se a instalacao nunca chegou ao fim, o residuo pode ser removido a
  mao com seguranca apos o primeiro boot.

## Receita QEMU/libvirt (teste antes do bare metal)

Requisitos **obrigatorios**:

- **OVMF (UEFI)** — os scripts assumem UEFI (ESP, grub `x86_64-efi`,
  `EFI_STUB`). Sem OVMF a VM boota em BIOS legado e o 05 falha.
  No Fedora: `sudo dnf install edk2-ovmf`.
- **`-cpu host`** (com KVM) — `CFLAGS_ARCH=native` compila para a CPU onde o
  gcc roda. Sem `-cpu host`, `-march=native` mira a CPU **falsa** emulada
  pelo QEMU e os binarios podem nem rodar no bare metal depois.
- Disco **virtio** ⇒ ajuste `TARGET_DISK=/dev/vda` no `vars.sh` (ou por env).
- `AUTO_CONFIRM=yes` para automacao (pula o prompt `ERASE /dev/vda`).
  **Jamais** use fora de VM.

```sh
# 1) Imagem de disco e firmware UEFI (VARS precisa de copia gravavel)
qemu-img create -f qcow2 gentoo-test.qcow2 60G
cp /usr/share/edk2/ovmf/OVMF_VARS.fd ./OVMF_VARS-gentoo.fd

# 2) Baixe o minimal install ISO amd64 em https://www.gentoo.org/downloads/
#    (ex.: install-amd64-minimal-*.iso)

# 3) Boot da VM — copie e cole:
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
# rede ja vem via DHCP no live ISO; habilite ssh para copiar os scripts:
passwd                      # defina uma senha temporaria de root
rc-service sshd start
# do host: scp -P 2222 -r gentoo-install/ root@localhost:/root/

cd /root/gentoo-install
TARGET_DISK=/dev/vda AUTO_CONFIRM=yes NVIDIA_MODE=force ./install.sh
```

Notas:

- `NVIDIA_MODE=force` e opcional: valida o **build** do driver na VM (veja o
  aviso no topo). Com o default `auto` a etapa e pulada com aviso.
- `MAKEOPTS` default e `-j17`; se der menos vCPUs a VM (`-smp 12` acima),
  passe `MAKEOPTS=-j13` junto para nao sobrecarregar.
- No **primeiro boot do sistema instalado**, remova o ISO (`-boot order=d` →
  tire a linha `-cdrom`/`-boot`) e reutilize o **mesmo** `OVMF_VARS-gentoo.fd`
  (e nele que o grub-install grava a entrada de NVRAM). Alternativa robusta
  para firmware que perde a entrada: `GRUB_REMOVABLE=yes` instala tambem em
  `EFI/BOOT/BOOTX64.EFI`.
- libvirt/virt-manager: equivale a firmware = "UEFI x86_64 (OVMF)", CPU =
  "host-passthrough", disco virtio. `virt-install --boot uefi --cpu host-passthrough --disk ...,bus=virtio`.

## Troubleshooting

- **Tela preta / console some quando o modulo nvidia carrega (conflito
  simpledrm x nvidia):** o kernel usa `SYSFB_SIMPLEDRM` para o console
  pre-driver, e em alguns setups o simpledrm nao solta o framebuffer para o
  nvidia-drm. Workaround conhecido — adicione a cmdline do kernel (em
  `/etc/default/grub`, `GRUB_CMDLINE_LINUX`, e rode
  `grub-mkconfig -o /boot/grub/grub.cfg`):
  ```
  initcall_blacklist=simpledrm_platform_driver_init
  ```
  Efeito colateral: sem console grafico ate o nvidia-drm assumir.
- **`validate_vars` morre com "TARGET_DISK ... sustenta o /":** voce apontou
  `TARGET_DISK` para o proprio disco do live system/host. Confira com
  `lsblk` — na VM virtio o alvo e `/dev/vda`.
- **01 morre com "relogio do sistema esta antes de 2026-08-30":** o live ISO
  subiu com data absurda (bateria CMOS fraca/placa nova) e TLS + GPG
  falhariam com erros cripticos. O script ja tenta sincronizar sozinho
  (`chronyd -q`/`ntpd -q -g`, timeout 60s); se falhou, confira a rede e
  acerte a hora manualmente (`chronyd -q`, ou `date MMDDhhmmYYYY` como no
  Handbook) e rode de novo.
- **01 falha na verificacao GPG:** cheque rede/DNS no live
  (`ping distfiles.gentoo.org`). O import tenta `hkps://keys.gentoo.org` e
  cai para `/usr/share/openpgp-keys/gentoo-release.asc` (presente na midia
  oficial). Qualquer falha de verificacao deleta o tarball — basta rodar de
  novo. Fingerprint divergente = NAO prossiga; confira
  https://www.gentoo.org/downloads/signatures/.
- **01 morre com mismatch de flavor:** voce trocou `INIT_SYSTEM` depois do
  extract. Rode `./install.sh --reset --repartition` (apaga tudo) ou volte
  o valor antigo.
- **04 morre em `verify_kconfig`:** um simbolo critico nao vingou no
  `.config` final (dependencia ausente ou renomeado no kernel novo). A
  mensagem diz qual. Ajuste `kernel-fragment.config` (os blocos comentam o
  motivo de cada simbolo) e rode de novo — o hash muda e o rebuild e
  automatico.
- **04/nvidia morre por versao insuficiente:** o script ja tenta
  `~amd64` via `package.accept_keywords/nvidia-drivers` sozinho; se ainda
  assim nao ha versao >= `NVIDIA_MIN_VER` (580.173.02, minimo para
  Blackwell), o mirror/arvore esta velho — rode um `emerge --sync` e repita.
  O arquivo `package.accept_keywords/nvidia-drivers` e removido
  automaticamente quando o estavel da arvore ja atende o minimo — ele so
  persiste enquanto for necessario (nao deixa `~amd64` permanente poluindo
  os `emerge -uDN @world` futuros).
- **VM nao boota apos instalar (cai no shell UEFI):** firmware perdeu a
  entrada de NVRAM (VARS descartado) — reuse o mesmo arquivo OVMF_VARS ou
  reinstale com `GRUB_REMOVABLE=yes`. No shell UEFI, tambem da para lancar
  manualmente `FS0:\EFI\gentoo\grubx64.efi`.
- **Kernel nao acha a raiz (VFS: unable to mount root):** boot sem initramfs
  depende de driver de disco built-in (`BLK_DEV_NVME=y` bare metal,
  `VIRTIO_BLK=y` VM — ambos garantidos pelo `verify_kconfig`) e de
  `root=PARTUUID=` correto. Se reparticionou apos o 05, rode
  `./install.sh --only 05` do live ISO (ele entra no chroot sozinho) ou, ja
  dentro do chroot, `./install.sh --chroot --only 5`, para regravar o PARTUUID.
- **Sem rede no primeiro boot:** confirme `ENABLE_DHCP=yes` (instala e
  habilita dhcpcd). Placas 2.5GbE Intel I225/I226 usam `igc`, Realtek usa
  `r8169` — ambos =m no fragmento.
- **Retomar apos reboot do live ISO:** so rodar `./install.sh` de novo; o
  mount e re-executado e os probes pulam o que ja esta feito.
- **Onde olhar quando algo falha:** o trap de erro imprime sub-etapa,
  arquivo, linha e o caminho do log (`/var/log/gentoo-install/*.log` no
  alvo). O state fica em `/var/lib/gentoo-install/state` (um arquivo por
  sub-etapa; alguns carregam valor: flavor do stage3, hash do fragmento,
  versao do nvidia).
