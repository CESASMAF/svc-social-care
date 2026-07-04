# T-002 — W1 Implementation Report

**Data:** 2026-05-14
**Skill executora:** edits manuais (governance / documental)

## Arquivos criados

- `handbook/architecture/DECISIONS/ADR-003-adr-structure-enforces-test-and-pattern.md` — meta-ADR formalizando a regra
- `.pipeline/T-002/001-orchestrator/REPORT.md`
- `.pipeline/T-002/003-impl/REPORT.md` (este)
- `.pipeline/T-002/005-quality/REPORT.md`

## Arquivos modificados

### `handbook/architecture/DECISIONS/ADR-TEMPLATE.md`

Mudanças:

1. **Bloco de promoção** adicionado logo após o `**Status:**` e antes de `## Contexto`:

   ```markdown
   > **Promoção Proposto → Aceito (ADR-003):** um ADR só pode ficar `Aceito`
   > quando **todas** as seções abaixo estão preenchidas — incluindo `Teste de
   > regressão` e `Better Pattern para skills`. ADR sem essas duas seções fica
   > `Proposto` até completar.
   ```

2. **Seção `## Teste de regressão`** adicionada entre `## Como reverter` e `## Referências`:
   - Pede identificador do teste com `file::test_<ACHADO_ID>_…`
   - Inclui exemplos de testes da pipeline (T-005, T-011)
   - Aceita lint test/schema snapshot como mecanismo alternativo
   - Pede justificativa explícita quando teste não é aplicável

3. **Seção `## Better Pattern para skills`** adicionada após `## Teste de regressão`:
   - Pede `.claude/skills/swift-*/SKILL.md` atualizada
   - Pede `handbook/tooling/swift/<area>/` (opcional)
   - Pede regra resumida em 1-3 linhas
   - Inclui exemplo extraído de ADR-002

### `handbook/architecture/DECISIONS.md`

Mudanças:

1. Linha do índice adicionada: `| [003] | ADR carrega obrigatoriamente teste de regressão e Better Pattern | Aceito | 2026-05-14 | — |`
2. Próximo ID: **003 → 004**
3. Nova seção `## Regra de promoção Proposto → Aceito (ADR-003)` com:
   - Lista das 2 seções obrigatórias
   - Política "em review, ADR Aceito incompleto é rebaixado para Proposto mecanicamente"
   - Exceção para ADRs puramente documentais (com justificativa)

## Validação de consistência

`grep "^## " ` em `ADR-002`, `ADR-003`, e `ADR-TEMPLATE.md` retorna **headings idênticos** nos 3:

```
## Contexto
## Decisão
## Alternativas consideradas
## Consequências
## Plano de adoção
## Como reverter
## Teste de regressão
## Better Pattern para skills
## Referências
```

ADR-002 (criado em T-001 antes deste meta-ADR) **já estava conforme** — antecipou o padrão. Sem retrofit necessário.

## Issues encontrados durante implementação

Nenhum. Ticket é puramente documental, sem build/compilação.

Decisão de design não-óbvia tomada durante implementação:

- **ADRs documentais sem teste aplicável** (raros) — ADR-003 não tem teste de código (é meta-ADR sobre estrutura). A seção `## Teste de regressão` do ADR-003 cita o mecanismo equivalente: code review + futuro `scripts/check_adr_completeness.sh` (T-038). Essa exceção fica explícita no template como "justificar por que".
