# AGENTS.md — instruções para agentes de código neste repositório

Leia isto **antes** de tocar em qualquer arquivo.

---

## ⚠️ PRIMEIRO: estes scripts apagam discos

Este repositório é um **instalador de sistema operacional**. Os scripts fazem
`sgdisk --zap-all`, `wipefs` e `mkfs` num disco inteiro.

**Você provavelmente está rodando NA MÁQUINA que estes scripts destruiriam.**

Regras absolutas para você, agente:

- **NUNCA execute** `install.sh`, `00-partition.sh`..`06-users-services.sh`,
  nem nada em `desktop/`. Nem "só para testar", nem com `--dry-run`, nem em
  parte.
- **NUNCA execute** `sgdisk`, `parted`, `mkfs.*`, `mkswap`, `wipefs`, `dd`,
  `mount`, `umount`, `chroot`, `emerge`, `swapon`.
- **Permitido:** ler arquivos, `bash -n`, ShellCheck, `./tests/run-tests.sh`,
  e leituras inofensivas (`lsblk`, `findmnt`, `blkid`, `lspci`).
- Precisa testar lógica de shell? Use um sandbox em `/tmp`. Nunca no repositório.

Se o usuário pedir para executar o instalador, **pare e confirme** em qual
máquina, em qual disco, e se há backup.

---

## O que é este projeto

Instalador de Gentoo **hardware-targeted de propósito** — não é genérico e não
pretende ser. Alvo único:

ASUS TUF GAMING B760M-E D4 (UEFI) · i5-12600K (Alder Lake, 6P+4E) ·
RTX 5060 Ti 16GB (Blackwell) · 32 GiB · NVMe · **kernel sem initramfs**

| Diretório | O quê |
|---|---|
| raiz | Instalador base, etapas `00`–`06` + `install.sh` + `lib.sh` + `vars.sh` |
| `desktop/` | Módulo **pós-instalação** (niri/Wayland), etapas `10`–`15` |
| `tests/` | Suíte do host, 432+ asserções. Nada aqui executa o instalador |
| `docs/` | `VALIDACAO.md` (o que rodou), `ARMADILHAS.md` (manual de operação), `PROXIMOS-PASSOS.md` (estado atual) |

---

## Invariantes — não os quebre

1. **PROBE É AUTORIDADE, MARKER É CACHE.** Toda ação vive em
   `run_step <nome> <probe_fn> <do_fn>`. O probe inspeciona o **sistema real**.
   Marker sem respaldo funcional é bug. Exceções precisam de comentário
   justificando.
2. **Sem initramfs.** Todo driver do caminho até a raiz é `=y`, nunca `=m`.
   Um driver de filesystem raiz como módulo = sistema que não boota, sem shell
   de recuperação. O `verify_kconfig` (etapa 04) é o portão que cobra isso
   **antes** de compilar.
3. **Operação destrutiva exige validação independente.** As guardas existem
   porque o instalador é **dono do disco inteiro**.
4. **`TARGET_DISK` é sempre explícito.** Nunca autodetecte disco. Nunca
   implemente fallback "se X não existe, usa Y".
5. **Resume tem que ser seguro e barato.** Idempotente; rodar duas vezes não
   duplica nada; `emerge --noreplace` quando a intenção é "garantir instalado".
6. **Verificar antes de construir; verificar de novo depois de instalar.**

---

## Como validar (sempre, antes de entregar)

```sh
./tests/run-tests.sh          # bash -n + ShellCheck + testes. Deve sair 0.
```

ShellCheck roda em container com o repo montado read-only. Se `podman` não
existir, o runner avisa e pula — não invente que passou.

**Nunca adicione `# shellcheck disable=` sem um comentário explicando o motivo.**

---

## Estilo

- `#!/usr/bin/env bash` + `set -euo pipefail`
- Comentários em **português do Brasil**, explicando o **porquê**, não o quê
- Nomes de função e variável em inglês
- Mensagem de erro **acionável**: o que aconteceu, por quê, e o que fazer
- Menor correção robusta. Se cabe em 10 linhas, não escreva 200

---

## As armadilhas que já morderam este projeto

Nove bugs reais foram encontrados **executando** o instalador. `bash -n`,
ShellCheck e uma auditoria adversarial de 13 dimensões passaram por cima de
**todos os nove**. Registro completo em `docs/VALIDACAO.md`.

Os padrões que se repetem — desconfie deles em qualquer código novo:

**1. Seu grep casa o seu próprio comentário.** Aconteceu três vezes.
`probe_default_grub` exigia "nenhum `root=`" e greppava o arquivo inteiro — o
comentário que explicava por que não havia `root=` continha a string. A
varredura de `kernel-open` quase repetiu o erro. **Exclua linhas de comentário
antes de grepar por configuração.**

**2. Comando que sai com 0 e mente.** `make install` sem
`sys-kernel/installkernel` grava `/boot/vmlinuz` sem versão, imprime
"Cannot find LILO." e **retorna sucesso**. Sempre verifique o **artefato**, não
o exit code.

**3. Substituição de processo esconde falha.** `done < <(cmd)` não propaga o
exit code do `cmd`. Um `lsblk` inválido devolveu vazio, o laço de `umount` não
rodou, e a guarda falhou **aberta** — o pior modo para código destrutivo.
**Capture em variável** (`x="$(cmd)" || die`), não em `<(...)`.

**4. `grep` sem match mata o script.** Com `set -euo pipefail`,
`x="$(cmd | grep ...)"` aborta quando o grep não casa. Use `|| true` quando
"não achou" é resultado legítimo.

**5. Variável não definida sob `set -u`.** `$ROOT_PART` sem
`compute_partitions`; `${BASH_SOURCE[1]}` num `bash -c`. Uma guarda que morre é
pior que guarda nenhuma — falha justamente quando deveria proteger.

**6. Duas implementações do mesmo conceito.** A enumeração de partições existia
em `lib.sh` (correta) e copiada em `00-partition.sh` (quebrada). Antes de
escrever um helper, procure se já existe.

---

## Não faça

- Não reescreva a arquitetura `00`–`06` nem o modelo de probes
- Não altere o default `TARGET_DISK=/dev/nvme0n1` do `vars.sh`
- Não use `--autounmask-write` nem `ACCEPT_LICENSE="*"`
- Não instale suporte a "instalar numa partição existente" — o instalador é
  dono do disco inteiro, e é dessa premissa que saem todas as guardas
- Não declare nada como "validado" sem execução real. Teste estático que passa
  significa que a propriedade afirmada continua verdadeira **no código** —
  não que o sistema boota
- Não faça commit sem o usuário pedir

---

## Estado da validação

| | |
|---|---|
| Instalador `00`–`06`, ext4, OpenRC | **2 ciclos completos em QEMU + boot** |
| btrfs | implementado, **nunca executado** |
| `desktop/` (niri) | escrito, **nunca executado** |
| Bare metal, runtime NVIDIA, systemd | **nunca** |

`docs/PROXIMOS-PASSOS.md` tem o estado operacional e o próximo passo.

---

## Commits

Mensagem explica a **causa raiz**, não o sintoma. O histórico deste repositório
é documentação de engenharia — cada commit conta por que o bug existia e o que
o impede de voltar. Mantenha esse padrão.

Rodapé: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
