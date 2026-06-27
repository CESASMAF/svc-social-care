# T-002 — W3 Quality Gates

**Data:** 2026-05-14

## Gates

| Gate | Comando / Critério | Resultado |
|---|---|---|
| Template tem 9 headings | `grep "^## " ADR-TEMPLATE.md \| wc -l` | ✅ 9 |
| ADR-002 conforme template | `diff <(grep "^## " ADR-002) <(grep "^## " ADR-TEMPLATE)` | ✅ idêntico |
| ADR-003 conforme template | `diff <(grep "^## " ADR-003) <(grep "^## " ADR-TEMPLATE)` | ✅ idêntico |
| ADR-003 tem seções obrigatórias preenchidas | leitura manual | ✅ Teste + Better Pattern presentes |
| DECISIONS.md lista ADR-003 | `grep "003" DECISIONS.md` | ✅ |
| DECISIONS.md tem regra de promoção | `grep "Regra de promoção" DECISIONS.md` | ✅ |
| Próximo ID atualizado | `grep "Próximo ID" DECISIONS.md` | ✅ 004 |
| Nenhum arquivo Swift tocado | `git diff --name-only` Sources/Tests | ✅ vazio |
| ADR-002 não precisou retrofit | `grep "Teste de regressão" ADR-002` | ✅ já existia |

## Saída de auditoria (consistência)

```bash
$ grep -E "^## " handbook/architecture/DECISIONS/ADR-002*.md handbook/architecture/DECISIONS/ADR-003*.md handbook/architecture/DECISIONS/ADR-TEMPLATE.md | sort | uniq -c
   3 ## Alternativas consideradas
   3 ## Better Pattern para skills
   3 ## Como reverter
   3 ## Consequências
   3 ## Contexto
   3 ## Decisão
   3 ## Plano de adoção
   3 ## Referências
   3 ## Teste de regressão
```

Cada heading aparece exatamente 3 vezes — 1 por ADR + 1 no template. Estrutura 100% consistente.

## Enforcement futuro

Este ticket estabeleceu a **regra**. O **enforcement automatizado** vem em T-038:

- `scripts/check_adr_completeness.sh` — falha em CI se algum ADR com status `Aceito` não tem as 2 seções obrigatórias preenchidas.

Até T-038 fechar, enforcement é manual em code review (referenciar este ADR-003 na descrição do PR que cria ADR novo).

## Próximos tickets liberados

T-002 não bloqueia tickets de código diretamente, mas estabelece **disciplina** que todos os 37 ADRs seguintes vão seguir. O próximo passo natural é entrar na **Fase 1** da pipeline (T-004 ou T-005).

Recomendação:

- **T-004** (`EventSourcedAggregate` ⊇ `EventSourcedAggregateInternal`) — pequeno, isolado em `shared/Domain/`, alto impacto (mata categoria de bug "evento engolido silenciosamente"), e exercita a nova convenção de ADR-004 seguindo o template ADR-003.

Ou **T-005** (Optimistic locking) se preferir atacar o maior CRITICAL primeiro — mas T-005 toca Domain + IO, é maior em escopo.
