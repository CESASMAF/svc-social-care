# T-001 — W1 Implementation Report

**Data:** 2026-05-14
**Skill executora:** `swift-test-writer` (test infra) + edits manuais (handbook/skills/Makefile)

## Arquivos criados

### Infra de testes
- `Tests/social-care-sTests/Regression/README.md` — índice do suite (convenções, anatomia, subpastas)
- `Tests/social-care-sTests/Regression/Concurrency/README.md`
- `Tests/social-care-sTests/Regression/DataIntegrity/README.md`
- `Tests/social-care-sTests/Regression/EventPublication/README.md`
- `Tests/social-care-sTests/Regression/Security/README.md`
- `Tests/social-care-sTests/Regression/DomainInvariants/README.md`
- `Tests/social-care-sTests/Regression/ErrorMapping/README.md`
- `Tests/social-care-sTests/Regression/RegressionMeta.swift` — `@Suite("Regression: Meta")` com 5 sentinels
- `Tests/social-care-sTests/Application/TestDoubles/RegressionFixture.swift` — helper central

### ADR e handbook
- `handbook/architecture/DECISIONS/ADR-002-regression-test-policy.md`
- `handbook/tooling/swift/testing/regression-pattern.md`

## Arquivos modificados

- `Makefile` — `.PHONY` atualizado + target `regression: swift test --filter "Regression"`
- `handbook/architecture/DECISIONS.md` — índice ADR-002 adicionado; próximo ID atualizado para **003**
- `.claude/skills/swift-test-writer/SKILL.md` — adicionada seção "Padrão de Teste de Regressão (ADR-002)" + "Lições Aprendidas (regressões prevenidas)" tabela (1ª linha)

## API de RegressionFixture (final)

```swift
enum RegressionFixture {
    static func frozenClock(at iso: String = "2026-05-14T12:00:00Z") -> @Sendable () -> TimeStamp
    static func frozenTimestamp(at iso: String = "2026-05-14T12:00:00Z") -> TimeStamp
    static func prepopulatedLookupValidator(_ entries: [String: [LookupId]] = [:]) async -> InMemoryLookupValidator
    static func permissiveLookupValidator() -> AllowAllLookupValidator
    static func stubUnitOfWork() -> StubUnitOfWork
    static func uuid(seed: UInt64) -> UUID
}
```

Todos os helpers `internal` (test doubles são internal — não atravessam target boundary).

## Convenções estabelecidas

| Convenção | Mecanismo de enforcement |
|---|---|
| Struct contém `Regression` no nome | `make regression` filtra via `--filter "Regression"` |
| Teste nome `test_<ACHADO_ID>_<descrição>` | Convenção documentada em README + handbook |
| Vive em `Regression/<subpasta>/` | 6 subpastas pré-criadas |
| Usa `RegressionFixture` para tempo/UUID/lookups | Fixture única, anti-pattern manual documentado |

## Issues encontrados durante implementação

1. **`public` em método com retorno `internal`** — `RegressionFixture.permissiveLookupValidator() -> AllowAllLookupValidator` quebrou compilação porque `AllowAllLookupValidator` é internal. **Fix:** rebaixar todo `RegressionFixture` para internal. Razão: test doubles vivem dentro do test target — `public` é supérfluo.
2. **Filtro `swift test --filter "Regression:"` retorna 0** — swift-testing filtra por nome qualificado (struct + função), não por `@Suite("Regression: Meta")` string. **Fix:** usar `--filter "Regression"` (substring match) — convenção é nome do struct conter "Regression".

Ambos resolvidos antes do PR.

## Validação build

- `swift build --target social-care-sTests` → exit 0, 9.32s
- `swift build -c release --product social-care-s` → ver `.pipeline/T-001/005-quality/REPORT.md`
- `make regression` → 21 testes em 2 suites, **0.007s execução pura** (wall-clock ~5s a frio incluindo SwiftPM)
