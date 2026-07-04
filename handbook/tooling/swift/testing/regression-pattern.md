# Padrão de Teste de Regressão (Swift / swift-testing)

> **Quando aplicar:** sempre que corrigir bug documentado em `handbook/reports/` com severidade ≥ HIGH.
> **Política:** ADR-002.
> **Onde mora:** `Tests/social-care-sTests/Regression/<subpasta>/`.

## 1. Anatomia obrigatória

Um teste de regressão tem **3 partes**, nessa ordem:

```swift
@Suite("Regression: Concurrency")
struct OptimisticLockRegressionTests {

    @Test("S-C3 / DB-2 — concurrent save rejects stale version")
    func test_S_C3_DB_2_lost_update_is_rejected() async throws {
        // 1. ARRANGE — reproduz o estado que era aceito antes
        let clock = RegressionFixture.frozenClock()
        let repo = InMemoryPatientRepository()
        var patient = try PatientFixture.registered(clock: clock)
        try await repo.save(patient)

        let a = try await repo.find(byId: patient.id)!
        let b = try await repo.find(byId: patient.id)!

        // 2. ACT — primeiro update funciona
        var aMutated = a
        try aMutated.updateSocialIdentity(typeId: ..., actorId: "userA", now: clock())
        try await repo.save(aMutated)

        // 3. ASSERT — segundo update (com version stale) FALHA
        var bMutated = b
        try bMutated.updateSocialIdentity(typeId: ..., actorId: "userB", now: clock())
        await #expect(throws: PersistenceConflictError.optimisticLockFailed.self) {
            try await repo.save(bMutated)
        }
    }
}
```

### Parte 1 — Reproduz o bug original

Setup que recria a condição em que o bug se manifestava. Importante: o **arrange deve falhar** se a fix for revertida. Sem isto, o teste vira "happy path glorificado".

### Parte 2 — Assert do invariante

A asserção principal cobre o que a fix garante. Use `#expect(throws: ...)` quando o invariante é "rejeitar X", `#expect(value == ...)` quando é "produzir Y".

### Parte 3 — Documenta no nome

`test_<ACHADO_ID>_<descrição_curta>()` — sempre com underscore para separar partes, sempre com ID do achado. Razões:

- `grep S_C3 Tests/` localiza o teste em 1 segundo
- IA-gerada lê o nome do teste e entende o invariante sem ler implementação
- Em 6 meses, o "por que isto existe" continua óbvio

## 2. Convenções

| Convenção | Por quê |
|---|---|
| Nome do struct contém `Regression` | `make regression` filtra por `swift test --filter "Regression"` |
| Nome do teste começa com `test_<ID>_` | Discoverability via grep |
| `@Suite("Regression: <Tema>")` | Organiza output do test runner |
| Comentário do arquivo cita ticket de remediação (`// ticket: T-005`) | Rastreabilidade pipeline ↔ teste |
| Usa `RegressionFixture` para determinismo | Evita testes flaky |
| Vive em `Tests/.../Regression/<Tema>/` | Auditoria por classe de bug |

## 3. As 6 subpastas

| Subpasta | Classe de bug |
|---|---|
| `Concurrency/` | Race conditions, lost updates, outbox duplication, actor reentrância |
| `DataIntegrity/` | PK/FK/types/CHECK no schema; 1NF; UF inválida |
| `EventPublication/` | Outbox, publish-after-persist, recordEvent silent no-op |
| `Security/` | Fail-open, headers, PII em log, JWT bypass, cross-tenant |
| `DomainInvariants/` | VO state inválido, identidade, Money, force-unwrap |
| `ErrorMapping/` | PersistenceConflictError não mapeado, erro genérico vazando |

## 4. Anti-patterns (NÃO faça)

### Anti-pattern: nome genérico

```swift
// ❌ ruim — perde valor em 6 meses
@Test("save fails on conflict")
func testConcurrentSaveFails() { ... }

// ✅ bom — sobrevive
@Test("S-C3 / DB-2 — save rejects stale version (lost-update prevention)")
func test_S_C3_DB_2_lost_update_is_rejected() { ... }
```

### Anti-pattern: teste passa sem a fix

```swift
// ❌ ruim — `repo.save(stale)` apenas não acontece, teste passa por sorte
@Test
func test_S_C3_lost_update() async throws {
    let stale = ... // version errada
    _ = stale     // nem chama save → teste verde sem cobrir nada
}

// ✅ bom — explicita a chamada que era o problema
await #expect(throws: PersistenceConflictError.self) {
    try await repo.save(stale)
}
```

### Anti-pattern: depender de `.now`/`Date()`/`UUID()` direto

```swift
// ❌ ruim — flaky, ordem de execução afeta
let id = UUID()
let now = Date()

// ✅ bom — determinístico
let id = RegressionFixture.uuid(seed: 1)
let now = RegressionFixture.frozenTimestamp()
```

### Anti-pattern: mock manual em vez de InMemory fake

```swift
// ❌ ruim — mock ad-hoc duplicado em cada teste
class FakeRepo: PatientRepository {
    var calls = 0
    func save(...) async throws { calls += 1 }
    // ...
}

// ✅ bom — fake compartilhada em TestDoubles/
let repo = InMemoryPatientRepository()
```

### Anti-pattern: teste sem assert do invariante

```swift
// ❌ ruim — só roda código
@Test
func test_S_C3() async throws {
    try await repo.save(patient)
}

// ✅ bom — afirma o que a fix garante
@Test
func test_S_C3_DB_2_lost_update_is_rejected() async throws {
    await #expect(throws: PersistenceConflictError.optimisticLockFailed.self) {
        try await repo.save(stalePatient)
    }
}
```

## 5. RegressionFixture (`Tests/.../Application/TestDoubles/RegressionFixture.swift`)

Helpers centrais para evitar flakiness:

| Helper | Uso |
|---|---|
| `RegressionFixture.frozenClock(at:)` | Closure `() -> TimeStamp` estável |
| `RegressionFixture.frozenTimestamp(at:)` | Valor `TimeStamp` direto |
| `RegressionFixture.prepopulatedLookupValidator(_:)` | `InMemoryLookupValidator` populado |
| `RegressionFixture.permissiveLookupValidator()` | `AllowAllLookupValidator` (uso restrito) |
| `RegressionFixture.stubUnitOfWork()` | Stub de UoW que executa o bloco (até T-030) |
| `RegressionFixture.uuid(seed:)` | UUID determinístico por seed numérica |

**Default ISO** das fixtures de clock: `2026-05-14T12:00:00Z` (data de criação da fixture pelo T-001). Mude apenas se o teste depender de instante específico.

## 6. Lint test associado (T-010)

Para cada classe de bug com `lint` na pipeline, criar teste-de-meta que **verifica que a regra é universalmente aplicada**:

```swift
@Test("Lint — all command handlers map PersistenceConflictError")
func test_lint_S_C6_all_handlers_map_persistence_conflict() {
    let mappers = HandlerMapperRegistry.allMappers
    for mapper in mappers {
        #expect(mapper.handlesPersistenceConflict,
                "\(mapper.handlerName) não mapeia PersistenceConflictError — regrede S-C6")
    }
}
```

Lint test é o **mecanismo de prevenção contínua**: novo handler escrito vai falhar em CI até cumprir o contrato.

## 7. Quando NÃO escrever teste de regressão

- Bugs **LOW** ou **Nitpick** sem impacto operacional (naming, comment style)
- Bugs que dependem de configuração externa não-replicável em CI (e.g. Authentik dev down)
- Bugs cobertos por testes unitários existentes que **falham** se o bug voltar (não duplicar)

Em dúvida, escreva o teste. Custo de teste extra < custo de bug em produção.

## 8. Workflow completo (relação com pipeline 4-Wave)

```
W0 RED → escreve teste em Regression/<tema>/<ArquivoRegressionTests>.swift
       → teste FALHA (porque a fix ainda não existe)
       → output: .pipeline/T-NNN/002-tests/REPORT.md

W1 GREEN → swift-{domain|application|io}-* implementa fix
        → teste passa
        → output: .pipeline/T-NNN/003-impl/REPORT.md

W2 REVIEW → maestro:code-reviewer audita
         → checa que teste de regressão obedece este pattern
         → output: .pipeline/T-NNN/004-code-review/REVIEW.md

W3 QUALITY → make ci (inclui make regression)
         → cobertura ≥ 95%
         → output: .pipeline/T-NNN/005-quality/REPORT.md

PÓS-MERGE → ADR criado em handbook/architecture/DECISIONS/
        → swift-test-writer/SKILL.md ganha entrada em "Lições Aprendidas"
        → IMPROVEMENT_BACKLOG.md marca ticket ✅
```

## 9. Referências

- `handbook/architecture/DECISIONS/ADR-002-regression-test-policy.md` — política
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` — pipeline T-001 a T-038
- `Tests/social-care-sTests/Regression/README.md` — índice operacional do suite
- `Tests/social-care-sTests/Application/TestDoubles/RegressionFixture.swift` — fixture central
- Fowler, *Refactoring* 2ª ed. — Self-Testing Code
- Martin, *Código Limpo*, cap. 9 — Testes Unitários (princípios FIRST)
