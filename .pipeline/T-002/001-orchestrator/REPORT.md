# T-002 — Orchestrator Plan

**Data:** 2026-05-14
**Skill rota:** — (manual / documental, sem código Swift)
**Tipo:** meta-ADR / governance

## Escopo confirmado

Conforme `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-002:

1. Atualizar `handbook/architecture/DECISIONS/ADR-TEMPLATE.md` com duas seções obrigatórias:
   - `## Teste de regressão`
   - `## Better Pattern para skills`
2. Adicionar nota no template explicando regra `Proposto → Aceito`
3. Criar **ADR-003 — ADR carrega obrigatoriamente teste de regressão e Better Pattern**
4. Atualizar `DECISIONS.md` com regra explícita de promoção
5. Validar que ADR-002 (criado antes deste meta-ADR) já segue o novo formato

## Ordem de execução

W0 não aplicável (puro doc / governance). Não há código Swift; o "teste" é cobertura
visual via `grep "^## "` que confirma headings consistentes nos 3 documentos:

```
1. Ler ADR-TEMPLATE.md atual (estrutura base já sólida em T-001)
2. Adicionar bloco `> **Promoção Proposto → Aceito (ADR-003):** ...` antes de "## Contexto"
3. Adicionar `## Teste de regressão` antes de "## Referências"
4. Adicionar `## Better Pattern para skills` antes de "## Referências"
5. Criar ADR-003 documentando a regra
6. Atualizar DECISIONS.md (índice + seção "Regra de promoção")
7. Validar consistência: grep "^## " em ADR-002, ADR-003, TEMPLATE → headings idênticos
```

## Dependências

- T-001 (concluído) — ADR-002 foi criado em T-001 já com as 2 seções novas, antecipando T-002.
  Portanto T-002 formaliza o que T-001 implicitamente estabeleceu.

## Bloqueia

- T-004 a T-038 — todos os próximos ADRs (37 esperados) devem seguir o template atualizado.
- T-038 (futuro) cria `scripts/check_adr_completeness.sh` que automatiza o enforcement em CI.
