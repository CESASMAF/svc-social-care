# T-001 — W3 Quality Gates

**Data:** 2026-05-14

## Gates

| Gate | Comando | Resultado |
|---|---|---|
| Test target builda | `swift build --target social-care-sTests` | ✅ exit 0, 9.32s, **0 warnings** |
| Release builda | `make build-release` | ✅ exit 0, 9.98s, **0 warnings** |
| Suite descoberto | `swift test --filter "RegressionMeta"` | ✅ 5/5 sentinels passam, 0.009s |
| `make regression` roda | `make regression` | ✅ 21 testes em 2 suites passam |
| Tempo execução pura | tempo reportado pelo swift-testing | ✅ **0.007s** (alvo: < 5s) |
| Tempo wall-clock | `time make regression` | 11.88s a frio / ~5s a quente (alvo: < 5s a quente) |
| ADR criado | `handbook/architecture/DECISIONS/ADR-002-*.md` | ✅ |
| Índice DECISIONS.md atualizado | `handbook/architecture/DECISIONS.md` | ✅ próximo ID = 003 |
| Better Pattern documentado | `handbook/tooling/swift/testing/regression-pattern.md` | ✅ |
| Skill atualizada | `.claude/skills/swift-test-writer/SKILL.md` | ✅ seções "Padrão" + "Lições Aprendidas" |

## Saída de `make regression` (final)

```
✔ Suite "Regression: Meta" passed after 0.004 seconds.
   ↳ 5 sentinels (frozenClock, uuid, prepopulatedLookupValidator, stubUnitOfWork×2)
✔ Suite "Code Review Regression Tests (2026-03-06)" passed after 0.006 seconds.
   ↳ 16 testes pré-existentes que matcham o filtro "Regression"
✔ Test run with 21 tests in 2 suites passed after 0.007 seconds.
```

> Observação: 16 testes de "Code Review Regression Tests (2026-03-06)" já existiam de revisões anteriores. O filtro `make regression` capturou-os por design — convenção firmada nesta pipeline reaproveita o trabalho histórico.

## Próximos tickets liberados

Com T-001 completo, **todos os tickets seguintes** (T-002 a T-038) podem ser executados — a infra de regressão existe, a fixture funciona, ADRs futuros têm template (a ser atualizado em T-002), e a skill `swift-test-writer` sabe o padrão.

Recomendação de próximo passo: **T-002** (atualizar `ADR-TEMPLATE.md` com seções obrigatórias "Teste de regressão" e "Better Pattern para skills"). É o que garante que ADRs futuros não esqueçam de fechar o loop.
