# PRÓXIMOS PASSOS — estado operacional

Escrito para ser lido **do telefone**, quando a máquina de trabalho não existir
mais. Diz onde as coisas pararam, o que fazer a seguir e como sair do buraco.

Última atualização: 2026-09-04 — após a etapa 16 (Clavis Shell) rodar no bare
metal e ter as doze correções levadas de volta para o repositório.

---

## Onde paramos

| | |
|---|---|
| Instalador `00`–`06` | 3 ciclos QEMU + boot, e **1 no bare metal** + boot (btrfs) |
| `ROOT_FS=btrfs` | **Instalou e bootou** (2026-09-02, após corrigir `block-group-tree`) |
| Módulo `desktop/` (niri) | **Executado no bare metal**, 9 bugs corrigidos, sessão niri rodando. Nunca rodou limpo |
| Etapa 16 (Clavis Shell) | **Executada** (2026-09-03), 12 bugs corrigidos. A shell sobe (`qs -c clavis`). Nunca rodou limpa |
| Bare metal | **Feito** (2026-09-02) — com intervenção manual em 20 pontos ao todo |
| WiFi (`iwd`) no sistema instalado | **Funcionando**, após corrigir 4 símbolos de cripto no kernel |
| Áudio | **Funcionando** — PipeWire 1.6.8 + WirePlumber respondem ao `wpctl status` |

Suíte do host: `./tests/run-tests.sh` → 659 asserções em 13 grupos (658 passam aqui; a que falha é o falso positivo abaixo). Testes estáticos não
provam boot.

Duas ressalvas medidas nesta máquina: o grupo **ShellCheck** é pulado (nem
`shellcheck` nem `podman` estão instalados aqui), e o **test-desktop-dryrun**
reprova **sempre** — ele acusa `/etc/portage/package.use/desktop-niri` como
"criado pelo dry-run" quando o arquivo é da instalação real. **A suíte só fecha
limpa fora da máquina alvo.**

Não trate isso como ruído inofensivo: a mesma linha que produz o falso positivo
produz um **falso negativo**. Neste host, um dry-run que de fato escrevesse
naquele caminho daria a mesma saída da falha conhecida — indistinguível. Ou
seja, a checagem que existe para provar que o dry-run não toca em produção
deixou de provar isso justamente aqui. Mecanismo, risco e a correção pendente
em [VALIDACAO.md](VALIDACAO.md), seção "A falha permanente do
`test-desktop-dryrun` nesta máquina".

---

## O plano

**1. Uma execução limpa, do zero, com o código atual.** É o único teste que
falta e o mais importante: nada neste projeto jamais rodou sem intervenção
manual no meio. Os 9 bugs do ciclo bare metal e os 12 da etapa 16 estão
corrigidos no repo, e **nenhum dos 21 foi reexecutado** — toda correção foi
escrita durante a instalação, com o script rodando.

```sh
cd ~/gentoo-install-alderlake-blackwell && git pull
./install.sh --reset --repartition       # base
sudo ./desktop/install-desktop.sh        # desktop, após bootar
```

Se essa passar sem intervenção, o projeto vira reprodutível. Se não passar, o
que quebrar é a próxima coisa a corrigir.

**2. Validar as USE da etapa 16 antes de compilar.** Sete dos doze bugs do
Ciclo 6 foram USE flags e keywords não declaradas, descobertas uma a uma quando
o emerge parava — com compilação de Qt inteiro entre uma descoberta e a
seguinte. A mesma classe já tinha aparecido no Ciclo 5 (item 5.6). Uma
sub-etapa que rode `emerge -pq --autounmask=y` sobre a lista completa **antes**
do emerge real, e leia a saída, troca horas de CPU por segundos de relatório.
Detalhes em [VALIDACAO.md](VALIDACAO.md), seção "A mesma classe, pela segunda
vez".

**3. Áudio sob carga.** O básico responde (`wpctl status` lista dispositivos e
clientes), mas nunca foi exercitado de verdade. O PipeWire está na rota `launcher`
(`spawn-at-startup` no `config.kdl`), então:

```sh
pactl info                    # tem de responder, não dar erro de conexão
wpctl status                  # tem de listar dispositivos
speaker-test -c2 -twav        # o teste que importa
```

**4. Suspend/resume, carga, térmica.** Nada disso foi exercitado.

---

## Os discos desta máquina

Verificado em 2026-09-09, com o Gentoo já instalado e em execução:

```
nvme0n1  465.8G   ← GENTOO (este sistema) — foi o disco escolhido
├─p1         1G   vfat    /efi        ESP
├─p2        16G   swap    [SWAP]
└─p3     448.8G   btrfs   /           (volume único, sem subvolumes)

nvme1n1  931.5G   ← FEDORA 44 — não tocar
├─p1       600M   vfat                ESP própria (\EFI\fedora\shimx64.efi)
├─p2         2G   ext4                /boot do Fedora
└─p3     928.9G   btrfs               /  e  /home (subvolumes, mesmo device)

sda      931.5G   ← DADOS
└─sda1   931.5G   ext4    /mnt/HDD
```

`TARGET_DISK` no `vars.sh` está em **`/dev/nvme0n1`**, que é o disco desta
instalação. A decisão foi tomada: o Gentoo ficou no NVMe de 465.8G.

O `nvme1n1` é o **Fedora de socorro** e não entra em nenhum plano de
reparticionamento, formatação ou realocação de swap. Ele tem ESP própria
(`nvme1n1p1`, separada da nossa), e é por ele que se volta a ter máquina
utilizável se este Gentoo quebrar. O `os-prober` da etapa 05 monta as partições
dele **somente-leitura** para gerar o menuentry — ver ARMADILHAS seção 18.

O disco de dados mudou de lugar em relação à nota anterior: não é mais uma
partição xfs no `nvme0n1`, é o `sda1` ext4 montado em `/mnt/HDD`.

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

**O default do `vars.sh` é `btrfs`** desde 2026-09-02. Se você instalou em
**ext4**, é essa a variável que precisa repetir em toda retomada — sem ela o
`00` vê ext4 no disco, compara com o btrfs declarado e propõe destruir a
instalação pronta:

```sh
ROOT_FS=ext4 ./install.sh
```

O instalador diagnostica esse caso e aborta com o comando certo, mas repetir a
variável é mais barato do que ler o diagnóstico.

**Senha não entra no primeiro login:** layout de teclado. No GRUB tecle `e`,
acrescente `rw init=/bin/bash` na linha `linux`, `Ctrl+X`, e rode `passwd`.
Não precisa do live USB.

**Tela preta depois do GRUB:** não é necessariamente falha de boot. Espere um
minuto, tente `Ctrl+Alt+F2`, veja se o SSH sobe. Procedimento completo e
ordenado em [ARMADILHAS.md](ARMADILHAS.md), seção 8.

**Contas criadas:** `root` e o `USERNAME` do `vars.sh` (default `daeese`), que
nasce no grupo `wheel` e portanto com `sudo` (senha propria, sem NOPASSWD).

---

## O que ainda não tem evidência

- Uma execução limpa, do zero, com o código atual e sem intervenção — **o
  buraco principal**, e agora com 21 correções nunca reexecutadas dentro dele
- Etapa 16 rodando limpa — ela **foi** executada (2026-09-03) e a shell sobe,
  mas com intervenção manual em doze pontos
- `keytop` instalado *pela etapa 16* — a sub-etapa falhou por DNS e gravou
  `skipped`; o binário foi instalado à mão, fora do modelo do instalador
- Suspend/resume
- Branch `INIT_SYSTEM=systemd`

Registro completo do que **foi** executado: [VALIDACAO.md](VALIDACAO.md).
