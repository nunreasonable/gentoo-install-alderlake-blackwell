# Modulo de desktop — niri + Wayland + NVIDIA

Modulo **aditivo** ao instalador base (`00-06`). Instala e configura um desktop
Wayland com o compositor **niri** sobre **OpenRC**, num sistema Gentoo que ja foi
instalado pelo instalador deste repositorio e que **ja esta bootado do disco**.

O modulo vive inteiramente em `desktop/`. Ele **nao modifica** nenhum arquivo do
instalador base (`install.sh`, `lib.sh`, `vars.sh`, `00-06`,
`kernel-fragment.config`): faz `source` do `lib.sh` e reaproveita
`run_step`/logging/`die`/`svc_enable` sem alterar uma linha.

---

## ESTADO DE VALIDACAO — leia isto primeiro

**NADA deste modulo foi executado. Nem em QEMU, nem em bare metal.**

Nao existe "validado" neste documento porque nao existe execucao. O que foi feito
foi verificacao **estatica**:

- asercoes em `tests/test-desktop.sh` e `tests/test-desktop-dryrun.sh`
  (total da suite: 444, 0 falhas);
- `bash -n` em todos os arquivos de `desktop/`;
- ShellCheck reduzido a 5 `SC1091` inevitaveis (o linter nao segue `source` de
  `../lib.sh`);
- o teste novo foi conferido com 14 mutacoes deliberadas, que expuseram 2 falsos
  negativos no proprio teste — ambos corrigidos.

Tudo isso verifica **forma e logica em stubs**. Nada disso toca o Portage, e
nenhuma linha do modulo rodou contra um sistema real.

### O que a verificacao estatica nao pode provar

- **Nenhum atom, USE flag, keyword ou versao foi confrontado com o Portage
  real.** O host de desenvolvimento e Fedora e a regra de seguranca do projeto
  proibe rodar `emerge`/`portageq`. Os testes verificam a *forma* do atom
  (categoria/nome, categoria existente) e **nunca a existencia**. A primeira
  execucao no hardware e que revela se algum atom nao resolve — e o portao
  `10-atoms-resolvable` existe exatamente para isso, falhando cedo e nomeando o
  culpado.
- **A sessao grafica nunca subiu.** Uma VM sem passthrough PCI **nao valida**
  sessao Wayland com driver NVIDIA proprietario: nao ha GPU, nao ha EGL/GBM, nao
  ha DRM master. O risco central deste modulo e precisamente esse, e ele e
  estruturalmente invalidavel em QEMU.
- **O fluxo `install-desktop.sh` -> scripts numerados nunca foi exercitado.**
  Foram validados sintaxe, resolucao de simbolos, `--list` e a recusa
  fail-closed da guarda de ambiente. A execucao encadeada so pode ser testada no
  Gentoo bootado.

### Herdado do instalador base

O `nvidia-drivers` foi **compilado** durante a instalacao, mas o runtime **nunca
foi validado** — o QEMU nao tem GPU. Este modulo e a primeira vez que esse driver
roda de verdade, numa Blackwell/GB206 recem-lancada. Trate qualquer sucesso de
compilacao como **nao-prova de funcionamento**.

---

## Quando rodar

Todas as condicoes abaixo, simultaneamente:

1. o instalador base `00-06` **terminou** (os markers `06-users` e `06-services`
   existem em `/var/lib/gentoo-install/state`);
2. a maquina **reiniciou** e esta rodando o Gentoo **a partir do disco**;
3. voce esta logado como **root** (ou via `sudo`);
4. `INIT_SYSTEM=openrc` (ver a secao OpenRC adiante).

O modulo **recusa** rodar em live ISO e dentro do chroot da instalacao. A guarda
`require_booted_system()` (`lib-desktop.sh`) e **fail-closed por deteccao
positiva**: em vez de procurar sinais de live ISO (lista aberta, sempre
incompleta), ela **prova** oito condicoes:

| # | Condicao verificada |
|---|---|
| (a) | `/` deste shell tem o mesmo device:inode que `/proc/1/root/.` (nao ha chroot) |
| (b) | `/proc/1/comm` e `init`, `openrc-init` ou `systemd` |
| (c) | `/` vive num disco real (`_host_is_installed_system` do `lib.sh`, com lsblk exigindo `TYPE=disk`) |
| (d) | o filesystem de `/` nao e `squashfs`/`tmpfs`/`overlay`/`ramfs`/`rootfs`/`iso9660` |
| (e) | a sentinela `/etc/gentoo-install/.inside-chroot` **nao** existe |
| (f) | `/mnt/gentoo` **nao** esta montado |
| (g) | os markers `06-users` e `06-services` existem |
| (h) | o init esta de pe (`/run/openrc/softlevel`, ou `/run/systemd/system`) |

Qualquer condicao que **nao possa ser provada** — comando ausente, erro de
leitura, saida vazia — resulta em `die`. Na duvida, recusa.

A guarda roda uma vez no orquestrador **e** no topo de cada script numerado,
porque os scripts do projeto rodam standalone para debug.

---

## O alvo e OpenRC

O projeto inteiro assume `INIT_SYSTEM=openrc`, que e o default do instalador. O
branch **systemd existe no instalador mas nunca foi executado**.

- O `13-services.sh` **so implementa o caminho OpenRC** e morre com mensagem
  explicita se `INIT_SYSTEM` for outra coisa. Todos os comandos que ele usa
  (`rc-update`, `rc-service`, `rc-update add -U`, runlevel `boot` do elogind) sao
  especificos de OpenRC.
- O `install-desktop.sh` **avisa** (nao morre) quando `INIT_SYSTEM != openrc`, e
  deixa claro o que muda: com systemd o `niri-session` passa a ser valido, e o
  `-systemd` deixa de ser a USE flag correta em varios pacotes.

**O comando de arranque da sessao em OpenRC e:**

```
dbus-run-session niri --session
```

**NUNCA use `niri-session` em OpenRC.** Esse script upstream procura
`systemctl`/`dinitctl`, nao encontra nenhum dos dois, imprime
`No systemd or dinit detected` e **sai na hora** — a sessao morre sem mensagem
visivel. Quem cria o barramento de sessao e o `dbus-run-session`.

O modulo trata isso na causa, nao no sintoma: o `12-niri-stack.sh` **verifica o
`Exec=` do `.desktop` instalado** e falha se estiver com `niri-session`,
apontando que o niri foi construido com `USE=systemd`. Ele **nao edita** o
arquivo a mao — ele pertence ao ebuild e seria sobrescrito no proximo emerge.

---

## O que o modulo instala

Os pacotes efetivos dependem das escolhas em `vars-desktop.sh`. Com os defaults:

**Compositor e sessao**
- `gui-wm/niri` (overlay GURU, `~amd64`) com `dbus screencast -systemd`
- `sys-auth/seatd` com `builtin server` (rota default) — e `DEPEND` direto do niri
- `sys-apps/dbus`
- `gui-apps/xwayland-satellite` (GURU) + `x11-base/xwayland`

**Interface**
- `gui-apps/foot` (terminal default — ver justificativa abaixo)
- `gui-apps/fuzzel` (launcher, GURU)
- `gui-apps/waybar` com `USE=niri`
- `gui-apps/mako` (notificacoes)

**Portais e audio**
- `sys-apps/xdg-desktop-portal` + `sys-apps/xdg-desktop-portal-gnome`
- `media-video/pipewire` + `media-video/wireplumber`

**Grafico**
- `x11-drivers/nvidia-drivers` **reconstruido com `USE=wayland`**

**Aparencia** (etapa 14)
- fontes, `gnome-base/gsettings-desktop-schemas`, `gnome-base/dconf`, tema de
  icones e cursor

**Ferramentas**
- `app-eselect/eselect-repository` (habilita o GURU)
- `app-portage/cpuid2cpuflags` (gera `CPU_FLAGS_X86` na maquina real)

Por que **foot** e o terminal default: ele renderiza em CPU via pixman e **nao
abre contexto EGL/GL**. Ou seja, nao depende do subsistema que este projeto nunca
validou. O terminal e a ferramenta de *recuperacao* — ele nao pode depender de
exatamente aquilo que estamos testando. `alacritty` e `kitty` sao
GPU-accelerated e sao os primeiros a falhar se o EGL estiver errado.

### Arquivos que o modulo escreve

Em `/etc` (sempre em arquivos **proprios**, nunca reescrevendo os do instalador):

- `/etc/portage/repos.conf/` — via `eselect repository enable guru`
- `/etc/portage/package.accept_keywords/desktop-niri`
- `/etc/portage/package.use/desktop-niri`
- `/etc/portage/package.use/desktop-nvidia-wayland` — **arquivo separado**, de
  proposito: `package.use/nvidia-drivers` e territorio do `04-kernel.sh`, cujo
  conteudo muda por ramo de driver e que **aborta** se encontrar `kernel-open`
  quando o ramo for `>=595`. Reescrever aquele arquivo sabotaria o instalador
  validado.
- `/etc/portage/package.use/00cpu-flags` — saida do `cpuid2cpuflags`
- `/etc/pam.d/system-login`, `/etc/pam.d/elogind-user` — apenas na rota elogind
- `/etc/local.d/create-runuser.start` — apenas na rota seatd, para `XDG_RUNTIME_DIR`
- `/etc/default/grub` — **somente** no ramo 580 e **somente** se o modeset estiver
  desligado; com backup em `.bak-desktop` e edicao idempotente

Em `$HOME` do usuario alvo (escrito como o usuario, via `run_as_user`, nunca como
root):

- `~/.config/niri/config.kdl`
- `~/.config/fontconfig/fonts.conf`
- `~/.config/gtk-3.0/settings.ini`, `~/.config/gtk-4.0/settings.ini`
- `~/.config/waybar/`, `~/.config/foot/foot.ini` (ou alacritty/kitty)
- `~/.config/qt6ct/qt6ct.conf`

Servicos e grupos:

- `rc-update add seatd default` (ou `elogind` no runlevel **boot**)
- `rc-update add dbus default`
- grupos **aditivos** via `gpasswd -a`: `video`, `input`, `seat` (rota seatd) ou
  `pipewire`

---

## O que o modulo NAO faz

- **Nao formata, nao reparticiona, nao remove pacote do usuario.** Nunca.
- **Nao remove grupos.** Usa `gpasswd -a`, nunca `usermod -G` (que substituiria a
  lista inteira). Se voce esta no grupo `audio` e o wiki do PipeWire recomenda o
  contrario, o modulo **avisa** e diz o comando — ele nao executa.
- **Nao reescreve `/etc/modprobe.d/nvidia.conf`.** Esse arquivo pertence ao
  ebuild e contem as opcoes de suspend corretas do seu ramo. Se precisar mudar
  algo, o modulo usa `/etc/modprobe.d/zz-nvidia-desktop.conf`, que ordena depois.
- **Nao edita `/usr/share/wayland-sessions/niri.desktop`.** Pertence ao ebuild.
- **Nao sobrescreve config do usuario.** `write_config_if_absent` preserva o que
  ja existe. Se voce ja tem um `config.kdl`, ele fica intacto.
- **Nao troca o perfil nem roda `emerge -uDN @world`** — a menos que voce peca
  explicitamente com `--with-profile-world` (etapa 10a, opt-in).
- **Nao reinicia a maquina.** Nunca, em hipotese alguma.
- **Nao instala display manager** por default (`DESKTOP_GREETER=none`). Valida-se
  a sessao do TTY primeiro; um DM antes disso mistura sintoma de DM com sintoma
  de compositor.

---

## Ordem de execucao

```
./desktop/install-desktop.sh
```

Roda, nesta ordem: **10 -> 11 -> 12 -> 13 -> 15 -> 14**.

| Etapa | Script | O que faz |
|---|---|---|
| 10 | `10-portage-desktop.sh` | overlay GURU, `package.accept_keywords`, `package.use`, `CPU_FLAGS_X86`, **portao de atoms** |
| 10a | `10a-profile-world.sh` | *(opt-in)* perfil `23.0/desktop` + `emerge -uDN @world` |
| 11 | `11-nvidia-wayland.sh` | `USE=wayland` no `nvidia-drivers`, libs EGL, prova de modeset |
| 12 | `12-niri-stack.sh` | niri, terminal, launcher, xwayland, barra, portais, audio |
| 13 | `13-services.sh` | seatd/dbus, grupos, PAM, `XDG_RUNTIME_DIR`, servicos de audio |
| 15 | `15-validate.sh` | **validacao pre-reboot** — portao |
| 14 | `14-dotfiles.sh` | dotfiles e aparencia |

**A ordem nao e numerica, e isso e deliberado:**

- **15 antes de 14** porque validar que a sessao sobe e mais urgente que estetica.
  A 15 e um **portao**: se ela falha, sai com 1, a cadeia para e a 14 nao roda.
  Escrever tema num sistema onde o compositor nao inicia e desperdicio *e* ainda
  envenena o diagnostico, misturando sintoma de tema com sintoma de compositor.
- **10 primeiro e absoluto** porque `gui-wm/niri`, `gui-apps/fuzzel` e
  `gui-apps/xwayland-satellite` **nao existem no `::gentoo`** (HTTP 404
  confirmado para os tres). Sem o overlay, o primeiro emerge falha com
  "no ebuilds to satisfy". A etapa termina no portao `require_atoms`, que prova
  em **segundos** que todo atom resolve — em vez de descobrir um nome de pacote
  errado na hora 3 de compilacao.
- **11 antes do compositor** porque `USE=wayland` no `nvidia-drivers` **nao e
  default-on** e o instalador base nao a liga em lugar nenhum. Sem ela nao ha
  `egl-gbm`/`egl-wayland` e o niri nao inicia. O modo de falha e cruel: o driver
  **compila normalmente** e so quebra em runtime, com tela preta.
- **10a logo depois da 10**, quando pedida, porque trocar para o perfil desktop
  liga `USE=wayland` **globalmente** e o `-uDN @world` ja reconstroi o
  `nvidia-drivers`. Rodar a 10a depois da 11 recompilaria o driver **duas vezes**.
- **12 instala compositor + terminal + launcher juntos**, de proposito: entrar no
  niri sem terminal e sem launcher deixa o usuario numa tela vazia sem forma de
  abrir nada e sem saber como sair.
- **13 depois dos pacotes** porque so da para habilitar servico de pacote
  instalado. E indispensavel: o instalador base **nao configura** seatd, elogind
  nem dbus (confirmado por grep, zero ocorrencias nos `00-06`). Um modulo que so
  faz `emerge niri` produz um sistema onde o niri instala e **nunca inicia**.

---

## Flags

```
./desktop/install-desktop.sh [OPCOES]
```

| Flag | Efeito |
|---|---|
| `--list` | lista as etapas na ordem e sai (funciona em qualquer maquina) |
| `--only <etapa>` | roda somente a etapa indicada (ex.: `--only 11`) |
| `--from <etapa>` | comeca na etapa indicada e segue ate o fim |
| `--with-profile-world` | **inclui a etapa 10a** (troca de perfil + `emerge -uDN @world`). Demora horas |
| `--dry-run` | imprime o plano de cada etapa e **nao altera nada** — ver secao abaixo |
| `--reset [marker]` | sem argumento, **lista** os markers; com argumento, remove **um** |
| `-h`, `--help` | ajuda (sai antes de qualquer guarda) |

`--from` e `--only` sao mutuamente exclusivos. `--from 10a` e recusado (a 10a e
opt-in e nao tem posicao fixa na sequencia); use `--only 10a`.

### `--dry-run`

O orquestrador repassa `DESKTOP_DRY_RUN=yes` por ambiente. Cada script numerado
chama `dry_run_guard` **antes do primeiro `run_step`**: ela imprime o plano de
sub-etapas, sai com **0**, e nada depois dela executa. Como todo efeito do modulo
mora dentro de `run_step`, nenhum emerge roda, nenhuma config e escrita e nenhum
servico e habilitado.

> **Correcao de documentacao (2026-09-02).** Uma versao anterior deste README
> dizia que a flag **nao era enforcada** e mandava nao confiar nela. Isso
> descrevia um estado antigo — os guards foram adicionados depois daquele texto,
> e o README nao acompanhou. A auditoria confirmou que os sete numerados
> consomem a variavel; o `10a`, que era a excecao (usava `die` no meio em vez do
> guard no topo, saindo com codigo != 0 e abortando a cadeia), foi alinhado.

**O que esta provado, e por qual teste** (`tests/test-desktop-dryrun.sh`):

| Afirmacao | Como e provada |
|---|---|
| `dry_run_guard` sai com 0 e **impede o codigo seguinte de executar** | Teste unitario, chamando a funcao direto |
| Sem `--dry-run` a guarda e transparente | Teste unitario |
| Todos os numerados consultam `DESKTOP_DRY_RUN` | Asercao estatica |
| A guarda vem **antes** do primeiro `run_step` de cada script | Asercao estatica (`test-desktop.sh`) |
| Nenhuma mutacao de nivel superior escapa antes da guarda | Auditoria + snapshot |

**O limite honesto.** O teste de snapshot roda os numerados num sandbox e compara
hashes de conteudo, dono e modo. Mas **fora de um Gentoo alvo eles param na
guarda de fase** (*"so roda no sistema instalado e bootado"*), que vem antes da
de dry-run. Entao o snapshot prova *"num host que nao e o alvo, nada muta"* — o
que valida a guarda de fase como fail-closed, e **nao** e o mesmo que provar o
dry-run num Gentoo real. Alcancar a guarda de dry-run exigiria uma porta para
pular a de fase, e criar essa porta seria pior que a lacuna que fecharia. Por
isso o mecanismo tem teste unitario proprio.

Traduzindo: **o dry-run e enforcado por construcao e testado no mecanismo**, mas
o caminho completo num Gentoo instalado ainda nao foi observado — como nada
neste modulo foi.

### Variaveis uteis

Todas em `vars-desktop.sh`, sobrescritiveis pelo ambiente:

```sh
DESKTOP_USER=rodrigo          # dono da sessao grafica (detectado se vazio)
DESKTOP_SEAT_PROVIDER=seatd   # seatd | elogind
DESKTOP_TERMINAL=foot         # foot | alacritty | kitty
DESKTOP_BAR=waybar            # waybar | none
DESKTOP_NOTIFY=mako           # mako | none | swaync
DESKTOP_ENABLE_SCREENCAST=yes
DESKTOP_ENABLE_XWAYLAND=yes
DESKTOP_ASSUME_YES=no         # yes pula os prompts das acoes caras
```

As duas acoes da etapa 10a tem **precedencia do ambiente sobre a flag**, o que
permite pedir so uma das duas:

```sh
# atualiza o @world, mas NAO troca o perfil
DESKTOP_SWITCH_PROFILE=no ./desktop/install-desktop.sh --with-profile-world
```

`DESKTOP_USER` tem default **vazio** de proposito. O modulo detecta em runtime:
le o marker do 06, ou procura o unico usuario com UID >= 1000. Se encontrar zero
ou mais de um, **morre** pedindo o valor explicito — escrever dotfiles no `$HOME`
errado seria uma falha silenciosa e cara de diagnosticar.

---

## Como retomar apos falha

O modulo e **idempotente e retomavel**, herdando o modelo do instalador base:

> **O PROBE e a autoridade. O MARKER e so cache.**

Cada sub-etapa passa por `run_step <nome> <probe_fn> <do_fn>`. O probe inspeciona
o **sistema real** — `portageq get_repo_path / guru`,
`rc-update show default | grep seatd`, `ls /usr/lib64/libnvidia-egl-gbm.so*`,
`cat /sys/module/nvidia_drm/parameters/modeset` — e nao apenas a existencia de um
arquivo de marker.

**Quando algo falha:**

1. Leia a mensagem de erro. Toda falha traz o comando exato de correcao.
2. Corrija o problema.
3. Rode **o mesmo comando de novo**:
   ```
   ./desktop/install-desktop.sh
   ```
   As sub-etapas ja concluidas sao puladas (o probe confirma que continuam
   feitas) e a execucao retoma de onde parou.

**Para forcar a re-execucao de uma sub-etapa:**

```sh
./desktop/install-desktop.sh --reset                 # LISTA os markers
./desktop/install-desktop.sh --reset 11-nvidia-rebuild
```

`--reset` sem argumento nunca apaga nada — ele lista. Com argumento, remove
**apenas um marker**, e nunca um pacote. Markers do instalador base (`00-06`) sao
recusados: eles sao a evidencia de que a instalacao terminou, e apagar um deles
faria a propria guarda de ambiente recusar a proxima execucao.

Como o probe e a autoridade, apagar o marker de algo que **continua feito** no
sistema real apenas faz o `run_step` re-confirmar e regravar o marker — nada e
refeito de verdade.

**Para rodar uma etapa isolada** (para debug, ou depois de corrigir algo
especifico):

```sh
./desktop/install-desktop.sh --only 11
./desktop/install-desktop.sh --from 13
```

Cada script numerado tambem roda standalone (`./desktop/11-nvidia-wayland.sh`),
com a mesma guarda de ambiente no topo.

**Log completo:** `/var/log/gentoo-install/install-desktop.log`, mais um arquivo
por script numerado no mesmo diretorio. O `tee -a` acumula re-execucoes no mesmo
arquivo.

---

## TELA PRETA ao iniciar o niri

Este e o **cenario de falha mais provavel** e o risco central do modulo. Leia
antes de reiniciar.

### Antes de tudo: como voltar para um TTY

```
Ctrl+Alt+F1  ...  Ctrl+Alt+F6
```

Se o TTY responder, voce tem console e o diagnostico e tranquilo. Continue na
proxima secao.

**Se nem o `Ctrl+Alt+F2` devolver um TTY**, o suspeito e o handoff
`simpledrm -> nvidia-drm`. Va direto para a secao "Escape hatch" abaixo.

### Diagnostico, nesta ordem

A partir de um TTY, **como o usuario** (nao como root):

```sh
rc-service seatd status                      # o seat provider esta de pe?
id -nG $USER                                 # os grupos entraram NESTA sessao?
echo $XDG_RUNTIME_DIR                        # deve imprimir /run/user/<uid>
cat /sys/module/nvidia_drm/parameters/modeset  # deve imprimir Y
ls /usr/lib64/libnvidia-egl-gbm.so*          # tem de existir
niri --session 2>&1 | tail -40               # a mensagem REAL do compositor
```

A ultima linha e a mais util: rodar `niri --session` **sem** o `dbus-run-session`
na frente mostra a mensagem de erro do compositor sem o wrapper no meio.

**Causas mais comuns, em ordem de probabilidade:**

| Sintoma | Causa provavel | Correcao |
|---|---|---|
| `libnvidia-egl-gbm` ausente | driver sem `USE=wayland` | `./desktop/install-desktop.sh --only 11` |
| `modeset` imprime `N` | modesetting desligado explicitamente | procure `nvidia-drm.modeset=0` em `/etc/default/grub` e `options nvidia-drm modeset=0` em `/etc/modprobe.d/*.conf` |
| falha ao abrir o seat | grupos nao aplicados, ou seatd parado | **logout/login** e `rc-service seatd status` |
| `XDG_RUNTIME_DIR` vazio | sessao antiga | **logout/login** |
| sessao morre sem mensagem | usou `niri-session` | use `dbus-run-session niri --session` |

**Faca logout/login (ou reinicie) antes de concluir qualquer coisa.** Dois
efeitos da etapa 13 so valem em sessoes **novas**: a lista de grupos e fixada no
login, e o `XDG_RUNTIME_DIR` nasce no login. Ignorar isso leva a um diagnostico
errado — voce veria a falha e concluiria que a validacao mentiu.

### Escape hatch: `nvidia-drm fbdev=0`

Se a tela ficou preta no boot, ou o console parou de responder ao trocar de TTY:

```sh
# descomente esta linha, que JA EXISTE no arquivo:
#   options nvidia-drm fbdev=0
$EDITOR /etc/modprobe.d/nvidia.conf
```

O driver vem com `fbdev` **ligado** por default e assume o console, sobrepondo o
`simpledrm`. O `fbdev=0` desfaz exatamente esse comportamento, e o proprio
comentario do arquivo reconhece que isso causa problema em alguns setups.

**Descomente a linha que ja esta la. Nao reescreva o arquivo do zero** — ele
pertence ao ebuild e contem as opcoes de suspend/resume corretas do seu ramo de
driver.

### Variaveis de ambiente: NAO adicione por reflexo

**Teste primeiro sem nenhuma variavel.**

Estas sao **folclore obsoleto** em driver moderno e nao devem ser adicionadas
"por seguranca":

- `GBM_BACKEND=nvidia-drm`
- `__GLX_VENDOR_LIBRARY_NAME=nvidia` — ha relato documentado de que esta
  **quebra** o login em sessao Wayland do KDE
- `WLR_NO_HARDWARE_CURSORS`, `WLR_DRM_NO_ATOMIC` — workarounds de wlroots antigo;
  o niri nem usa wlroots

Variavel global e dificil de desfazer e **envenena o diagnostico**. As unicas com
justificativa upstream atual sao para aceleracao de video no navegador
(`LIBVA_DRIVER_NAME=nvidia`, `NVD_BACKEND=direct`), que e outro assunto.

### Outros sintomas esperados

**VRAM em ~1 GiB.** O niri deveria usar por volta de 100 MiB. Se o `nvtop` ou o
`nvidia-smi` mostrar ~1 GiB, e o bug de heap do driver (ele nao devolve os
buffers ao pool). A correcao e um application profile com
`GLVidHeapReuseRatio=0` para o processo `niri`, em
`/etc/nvidia/nvidia-application-profiles-rc.d/`. **Inspecione o diretorio
antes**: drivers recentes ja embarcam esse profile com o valor correto, e
sobrescrever as cegas pode conflitar com o arquivo do proprio driver.

**Apps X11 nao abrem.** Instalar o `xwayland-satellite` **nao basta**. O niri nao
o integra sozinho — e preciso a linha `spawn-at-startup "xwayland-satellite"` no
`config.kdl`, que a etapa 14 escreve.

**Barra sem workspaces.** `waybar` construida sem `USE=niri`. A barra sobe e
funciona, mas nao le os workspaces — o sintoma parece "barra quebrada".

**Screenshare / dialogo de arquivo nao funciona.** Portais sob OpenRC — ver a
lista de nao-confirmados abaixo. **Nao tente resolver trocando para
`niri-session`**: aquele script nao funciona em OpenRC.

---

## Nao-confirmado — itens nomeados

A pesquisa que embasou este modulo deixou os itens abaixo **explicitamente sem
confirmacao**. Eles estao aqui nomeados, e nao escondidos, porque cada um deles
pode mudar o comportamento no hardware real.

### Bloqueadores potenciais

1. **Ramo do driver NVIDIA e suporte a Blackwell/GB206.** Nao se sabe qual ramo o
   `04-kernel.sh` resolveu nesta maquina sem consultar em runtime. A bifurcacao e
   grande e incompativel: no ramo **580** o `USE=kernel-open` ainda existe e e
   obrigatorio para Blackwell, o `nvidia.conf` poe `modeset=1` e nao ha
   `egl-wayland2`; no ramo **>=595** o `kernel-open` **foi removido** (declara-lo
   quebra o emerge), o `modeset=1` virou default e ha dependencia de
   `egl-wayland` **e** `egl-wayland2`. A funcao `nvidia_branch()` bifurca em
   runtime, mas o valor real so aparece no hardware. Ha afirmacao de fonte
   primaria da NVIDIA de que Blackwell so e suportado pelos modulos de kernel
   **abertos**.

2. **Handoff `DRM_SIMPLEDRM -> nvidia-drm` num kernel sem initramfs.** O maior
   risco nao validado do projeto. O modulo nvidia carrega **tarde**, e a janela de
   transicao ficou exposta. Ninguem testou esta combinacao exata (kernel sem
   initramfs + simpledrm + Blackwell/GB206). Nenhum teste estatico pode provar
   que a sessao sobe.

3. **Existencia real dos atoms.** Nenhum atom, USE flag, keyword ou versao foi
   confrontado com o Portage. O portao `10-atoms-resolvable` e quem descobre, e
   ele falha nomeando o culpado.

### Divergencias nao resolvidas entre fontes

4. **`sys-auth/elogind` tem versao estavel amd64?** As frentes de pesquisa se
   **contradizem** (uma reporta 255.24 como estavel, outra reporta todas as
   versoes como `~amd64`). O modulo escolhe o lado seguro do erro: destrava
   `~amd64` quando elogind e escolhido (keyword a mais num pacote estavel e
   inofensiva; a menos e emerge que falha). So `portageq best_visible` na maquina
   alvo resolve.

5. **Portais sob OpenRC.** O wiki do Gentoo afirma que os portals exigem o script
   `niri-session`; o autor do niri afirma que `niri --session` ja sobe os servicos
   D-Bus dele, incluindo o portal de screencast. Em OpenRC nao existe systemd user
   unit — os portais sao ativados por D-Bus. **Validacao pendente no hardware.**

6. **`rc-update -U show default`** (leitura do runlevel de **usuario**, usada no
   probe de audio do 13) nao foi confirmada como forma suportada. O wiki confirma
   a *escrita* (`rc-update add -U`). Se nao for suportada, o probe apenas reprova
   e a etapa re-executa sem dano — mas nunca marcaria como concluida.

### Nomes cosmeticos nao verificaveis sem o sistema

7. **A familia de fonte real** instalada por `media-fonts/symbols-nerd-font` — pode
   ser `Symbols Nerd Font Mono`. Confira com `fc-list | grep -i 'symbols nerd'`.
8. **O nome do diretorio do tema** Papirus em `/usr/share/icons/`. Confira com
   `ls /usr/share/icons/ | grep -i papirus`.

A etapa 14 avisa sobre os dois e ensina os comandos. Nenhum impede a sessao.

### Outros itens abertos

9. **`nvidia_drm.fbdev=1`** — se e necessario ou apenas recomendado neste stack.
   Nao confirmado. Tratado como opcional.
10. **Sintaxe exata do bloco `cursor` do KDL** na versao do niri empacotada no
    GURU, e o esquema KDL completo da versao 26.04.
11. **Se o niri cria automaticamente um `config.kdl`** na primeira execucao ou se
    usa um default puramente embutido. Isso mudaria a logica de idempotencia do
    probe da 14.
12. **Mecanismo exato de propagacao do `DISPLAY`** do `xwayland-satellite` para os
    clientes nas versoes 0.8.x.
13. **Impacto real da troca para o perfil `/desktop`** sobre os pacotes ja
    instalados: quantos rebuilds e quanto tempo. **Nao ha estimativa honesta de
    duracao** — a etapa 10a roda `--pretend` e mostra a contagem **medida**, e nao
    um numero inventado.
14. **`NVD_BACKEND=direct` em Blackwell** especificamente. A recomendacao e geral
    para driver `>=525`; nao ha confirmacao de teste em GB206.

### ShellCheck do instalador base

O runner continua reportando achados **pre-existentes** no instalador base
(`SC2034` em `00-partition.sh` e `lib.sh`, `SC2012`/`SC2016` em `install.sh` e
`lib.sh`). Eles **nao foram tocados** — regra 1. Sao a razao de o runner imprimir
"reportou achados" mesmo com tudo passando; ele nao falha por isso, por decisao
do projeto.

---

## Arquivos do modulo

| Arquivo | Papel |
|---|---|
| `install-desktop.sh` | orquestrador. Nunca faz `emerge` direto — so chama os numerados |
| `lib-desktop.sh` | guarda de ambiente, helpers de Portage em runtime, escrita idempotente |
| `vars-desktop.sh` | variaveis editaveis, com a justificativa de cada default |
| `10-portage-desktop.sh` | overlay, keywords, `package.use`, portao de atoms |
| `10a-profile-world.sh` | *(opt-in)* perfil desktop + `@world` |
| `11-nvidia-wayland.sh` | `USE=wayland`, libs EGL, prova de modeset |
| `12-niri-stack.sh` | compositor e aplicativos |
| `13-services.sh` | servicos, grupos, PAM, `XDG_RUNTIME_DIR` |
| `14-dotfiles.sh` | dotfiles e aparencia |
| `15-validate.sh` | validacao pre-reboot (portao) |
| `../tests/test-desktop.sh` | 253 asercoes estaticas sobre este modulo |

### A armadilha central do `lib-desktop.sh`

Documentada no proprio arquivo, repetida aqui porque quebra silenciosamente se
alguem mexer:

`state_dir()` do `lib.sh` escolhe o caminho dos markers pela fase. No sistema
bootado a sentinela de chroot nao existe, entao `current_phase()` reporta `live`,
e `state_dir()` devolveria `$TARGET_ROOT/var/lib/gentoo-install/state`. Com o
default `/mnt/gentoo`, os markers iriam para um caminho **inexistente** e a
idempotencia do modulo seria **silenciosamente falsa**.

A solucao, sem tocar uma linha do `lib.sh`: exportar `TARGET_ROOT=""` **antes** do
source, e **reafirmar** depois (porque `vars.sh` usa `:=`, que sobrescreve
variavel definida-porem-vazia). Com a string vazia, o ramo `live` devolve
`/var/lib/gentoo-install/state`, que e o caminho correto.

Consequencia: o modulo **nunca** pode chamar `require_phase()` (mataria o script,
pois a fase reportada e `live`) nem `validate_vars()` (exige `TARGET_ROOT`
nao-vazio e valida disco/particoes irrelevantes aqui).

---

## Resumo honesto

Este modulo foi escrito com cuidado, tem 253 asercoes estaticas, falha cedo com
mensagens acionaveis e recusa rodar na fase errada. **Nada disso e o mesmo que
funcionar.**

A primeira execucao no hardware e o primeiro teste real. Espere encontrar
problemas — em especial no caminho EGL/GBM da NVIDIA e no handoff de console. O
modulo foi construido para que esses problemas aparecam **com o TTY ainda
funcionando e com uma mensagem que diz o que fazer**, em vez de uma tela preta
sem console.

Nao reinicie a maquina esperando que algo melhore sozinho. Rode a etapa 15
primeiro.
