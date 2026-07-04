# T-001 — Orchestrator Plan

**Data:** 2026-05-14
**Skill rota:** `swift-test-writer` (W0/W1) + manual (DECISIONS/skills)
**Tipo:** meta-infra (sem W0 RED tradicional — não há teste-de-teste; sentinels da própria fixture cumprem o papel)

## Escopo confirmado

Conforme `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-001:

1. Criar `Tests/social-care-sTests/Regression/` com 6 subpastas + README por subpasta
2. Criar `Tests/social-care-sTests/Application/TestDoubles/RegressionFixture.swift` com helpers determinísticos
3. Adicionar target `make regression` ao Makefile (alvo < 5s)
4. Criar **ADR-002 — Política de testes de regressão**
5. Criar Better Pattern em `handbook/tooling/swift/testing/regression-pattern.md`
6. Atualizar skill `.claude/skills/swift-test-writer/SKILL.md` com seção "Lições Aprendidas (regressões prevenidas)"

## Ordem de execução

W0 não aplicável (meta-infra). Sequência foi:

```
1. Criar 6 subpastas com README (Concurrency/, DataIntegrity/, EventPublication/, Security/, DomainInvariants/, ErrorMapping/)
2. Criar RegressionFixture.swift em TestDoubles/
3. Criar RegressionMeta.swift com 5 @Test sentinels validando a fixture
4. Validar build (swift build --target social-care-sTests)
   → 1ª iteração: erro `public` em método que retorna tipo internal
   → fix: rebaixar todo RegressionFixture para internal
   → 2ª iteração: build OK, exit 0
5. Atualizar Makefile com `make regression`
   → 1ª iteração: filtro "Regression:" falhou (0 testes)
   → ajuste: filtro "Regression" (substring) → 21 testes em 2 suites
6. Criar ADR-002 + atualizar DECISIONS.md index
7. Criar handbook/tooling/swift/testing/regression-pattern.md
8. Atualizar swift-test-writer/SKILL.md
9. Validar make build-release + make regression final
```

## Dependências

Nenhuma. Este é o primeiro ticket da pipeline.

## Bloqueia

T-004 a T-038 — todos os tickets seguintes assumem que `Regression/` existe e `RegressionFixture` está disponível.
