# PRÓXIMOS PASSOS — estado operacional

Escrito para ser lido **do telefone**, quando a máquina de trabalho não existir
mais. Diz onde as coisas pararam, o que fazer a seguir e como sair do buraco.

Última atualização: 2026-09-02 — após o Ciclo 3 (btrfs instalou, não bootou).

---

## Onde paramos

| | |
|---|---|
| Instalador `00`–`06` (ext4) | **Duas instalações completas em QEMU + boot** (OpenRC) |
| `ROOT_FS=btrfs` | **Instalou, não bootou** — `block-group-tree`. Corrigido; **aguardando reexecução** |
| Módulo `desktop/` (niri) | Escrito, **nunca executado** |
| Bare metal | **Nunca** |
| WiFi (`iwd`) no sistema instalado | Implementado, **nunca executado** |

Suíte do host: `./tests/run-tests.sh` → 466 asserções. Testes estáticos não
provam boot.

---

## O plano

**1. btrfs na VM — REEXECUCAO** (o disco atual tem a raiz quebrada)

```sh
cd ~/gentoo-install-alderlake-blackwell && git pull
ROOT_FS=btrfs ./tests/run-in-qemu-guest.sh --reset --repartition
```

O `--reset --repartition` e necessario: a raiz atual foi criada **com**
`block-group-tree`, e o portao novo do `05` vai reprova-la — corretamente. Ela
precisa ser recriada pelo `00`, que agora passa `-O ^block-group-tree`.

O `ROOT_FS` do ambiente atravessa: o perfil da VM nao o define. O sinal de que
pegou e o prompt pedindo `REFORMAT /dev/vda3` — que **nao** e pulado por
`AUTO_CONFIRM=yes`, de proposito.

**O que observar**, na ordem em que aparece:

| Momento | O que confirma |
|---|---|
| `00` | `mkfs.btrfs -f -O ^block-group-tree` na linha de comando do log |
| `04` | `verify_kconfig` aprovando, com `BTRFS_FS` no array required |
| `05` | a linha `raiz btrfs sem block-group-tree — legivel pelo GRUB` |
| boot | nao cair em `grub rescue` |

Se cair em `grub rescue` de novo: `set` e `ls (hd0,gpt3)/` no proprio prompt.
Foi o que resolveu da ultima vez — cada saida elimina uma hipotese.

**2. Bare metal** — só depois que a VM fechar com boot.

**3. `desktop/`** — só depois do bare metal bootar. Ele instala um compositor
Wayland com NVIDIA proprietário, que é o pedaço que nenhuma VM valida.

---

## Os discos desta máquina

Verificado em 2026-09-01:

```
nvme1n1  931.5G   ← FEDORA
├─p1       600M   vfat    /boot/efi
├─p2         2G   ext4    /boot
└─p3     928.9G   btrfs   /  e  /home     (dois subvolumes, mesmo device)

nvme0n1  465.8G   ← DADOS
└─p1     465.8G   xfs     /mnt/data
```

`TARGET_DISK` no `vars.sh` está em **`/dev/nvme0n1`** (o de dados). Não foi
alterado — a decisão de qual disco apagar ficou em aberto.

**Antes de digitar `ERASE`, sempre:**

```sh
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
findmnt -rno TARGET --source /dev/nvme1n1p3
```

O segundo mostra o que o `lsblk` esconde: a coluna `MOUNTPOINT` (singular)
reporta **um** mountpoint por device, e `nvme1n1p3` tem dois (`/` e `/home`).
Foi o bug `critical` que a auditoria achou.

---

## Antes de apagar o Fedora

- [ ] Backup do `/home` — o `/mnt/data` (`nvme0n1`) sobrevive se você só apagar
      o `nvme1n1`
- [ ] Live USB gravado **e testado** (boot de verdade, não só gravado)
- [ ] Não apagar a entrada de boot do Fedora até o Gentoo bootar completo
- [ ] Salvar o transcript desta conversa, se quiser:
      `cp ~/.claude/projects/-home-daeese/8b73f7de-*.jsonl /mnt/data/`

---

## Quando der errado

**Onde estão os logs** — um por etapa, no alvo:

```sh
ls /mnt/gentoo/var/log/gentoo-install/
tail -60 /mnt/gentoo/var/log/gentoo-install/04-kernel.log
```

Depois do boot: `/var/log/gentoo-install/`.

**Retomar:** `./install.sh` de novo. O probe reexamina o disco e pula o que já
está feito — inclusive depois de reiniciar o live ISO.

**Retomando com `ROOT_FS=btrfs`, repita a variável:** ela não fica gravada em
lugar nenhum, e o `vars.sh` cai no default `ext4`. Sem ela o `00` vê btrfs no
disco, conclui que falta formatar e propõe destruir a instalação pronta:

```sh
ROOT_FS=btrfs ./install.sh
```

O instalador diagnostica esse caso e aborta com o comando certo, mas repetir a
variável é mais barato do que ler o diagnóstico.

**Senha não entra no primeiro login:** layout de teclado. No GRUB tecle `e`,
acrescente `rw init=/bin/bash` na linha `linux`, `Ctrl+X`, e rode `passwd`.
Não precisa do live USB.

**Tela preta depois do GRUB:** não é necessariamente falha de boot. Espere um
minuto, tente `Ctrl+Alt+F2`, veja se o SSH sobe. Procedimento completo e
ordenado em [ARMADILHAS.md](ARMADILHAS.md), seção 8.

**Contas criadas:** `root` e o `USERNAME` do `vars.sh` (default `gentoo`).

---

## O que ainda não tem evidência

- Bare metal, em qualquer forma
- Runtime do NVIDIA na Blackwell — o QEMU validou o **build**, não a carga do
  módulo, o firmware GSP nem o modeset
- btrfs, em qualquer forma
- O módulo `desktop/` inteiro
- Segunda instalação limpa com o código atual, sem intervenção
- Branch `INIT_SYSTEM=systemd`

Registro completo do que **foi** executado: [VALIDACAO.md](VALIDACAO.md).
