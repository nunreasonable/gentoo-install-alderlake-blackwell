# Auditoria adversarial — achados brutos

Estes JSONs são a **saída crua** de uma revisão multi-agente feita sobre os scripts
deste repositório antes do primeiro commit. São publicados como documentação honesta
do processo: o que foi procurado, o que foi encontrado, e o que foi feito a respeito.

> **Leia isto antes de citar qualquer achado:** todo problema descrito aqui **já está
> corrigido** no código deste repositório. Os arquivos descrevem o estado do primeiro
> rascunho, não o estado atual. Vários achados descrevem em detalhe caminhos em que os
> scripts destruiriam o disco errado — esses caminhos estão fechados. Se você chegou
> aqui procurando entender o comportamento atual, leia o [README principal](../../README.md)
> e o código, não estes arquivos.

## Como foi feito

Sete revisores independentes, um por dimensão, cada um lendo apenas os arquivos do seu
escopo e sem ver os achados dos outros:

| Dimensão | O que procurou |
|---|---|
| `handbook` | conformidade passo a passo com o Handbook AMD64 atual |
| `idempotencia` | probes funcionais vs. markers; resume após crash; re-execução |
| `destrutivo` | todo caminho em que `sgdisk`/`mkfs`/`wipefs` atinge o disco errado |
| `bash` | quoting, `set -euo pipefail`, exit codes engolidos, heredocs, portabilidade no ISO |
| `kernel` | símbolos do `kernel-fragment.config` contra o Kconfig real do 6.18 |
| `consistencia` | contratos entre arquivos: assinaturas, variáveis, nomes de etapa, doc vs. código |
| `nvidia` | comparação de versão, `kernel-open` no ramo 580.x, licença, marker `skipped-no-gpu` |

Cada achado `critical`/`high` foi então submetido a **dois céticos independentes** com
lentes distintas (corretude do código citado; impacto real e risco de regressão da
correção proposta), instruídos a refutar em caso de dúvida. Um achado só era aceito se
**nenhuma** das duas lentes o refutasse.

## Resultado

- **31 achados** no total: 1 `critical`, 8 `high`, 22 `medium`/`low`
- **1 refutado** pelos céticos por impacto (`do_gpt` não verificava a releitura da tabela
  de partições — tecnicamente correto, mas o wait-loop existente cobria o caso na prática).
  Aplicado mesmo assim depois, com guarda de holders LVM/LUKS/RAID, por precaução.
- **1 duplicata** entre dimensões (`probe_extract`, achado por `idempotencia` e por
  `consistencia` de ângulos diferentes)
- **todos os demais corrigidos**, mais 4 problemas que a própria auditoria introduziu ou
  revelou e que só apareceram na reconciliação cross-file final

Os três achados mais graves, para quem quiser calibrar o quanto uma revisão dessas vale:

1. **`kernel.json`, `critical`** — `DRM_BOCHS` deixou de selecionar `DRM_TTM_HELPER` no
   6.18, e o `CONFIG_CHECK` do ebuild do `nvidia-drivers` é fatal. Falharia *depois* de
   horas compilando o kernel.
2. **`destrutivo.json`, `high`** — `findmnt -rno SOURCE /` retorna `/dev/nvme1n1p3[/root]`
   quando `/` é subvolume btrfs (o padrão do Fedora). O sufixo faz o teste `[[ -b ]]`
   falhar e a guarda "o disco alvo não pode ser o do sistema vivo" vira no-op silencioso.
3. **`destrutivo.json`, `medium`** — um host normal e instalado era tratado como fase
   live; com `AUTO_CONFIRM=yes` herdado do ambiente, o disco seria zapado sem prompt
   nenhum. Severidade subestimada pelo revisor.

## Formato

Cada arquivo é `{"findings": [...]}`, e cada achado tem `file`, `location` (com o código
citado literalmente), `severity`, `title`, `detail` e `fix`.
