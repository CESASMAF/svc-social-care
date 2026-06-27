---
name: swift-testing
description: >
  Aprofundamento técnico (horizontal) do framework `swift-testing` para o
  backend `social-care` (Swift 6.3, não XCTest). Funde 3 skills genéricas
  (fundamentals + advanced traits/parallelization + code-review) e
  re-contextualiza para os padrões do projeto: fakes `InMemory*` em
  `TestDoubles/`, AAA, `Date` injetável, cobertura 95% no CI, padrão de
  regressão (ADR-002) e a regra inviolável de suite verde. Use para dúvidas
  factuais de `@Test`/`@Suite`/`#expect`/`#require`, traits & tags,
  parameterized, paralelismo/`.serialized`, `confirmation`, e migração de
  XCTest. Para "escreva os testes desta feature do social-care", use a
  vertical `swift-test-writer`; esta skill é o aprofundamento por trás dela.
---
# Swift Testing — aprofundamento técnico (social-care)

> **Contexto deste serviço (leia antes de aplicar):** os testes do `social-care`
> vivem em `Tests/social-care-sTests/` e usam **`swift-testing` (não XCTest)`**.
> O que vale neste repo:
>
> - **Framework:** `import Testing` · `@Suite`, `@Test`, `#expect`, `#require`. XCTest só aparece em migração.
> - **Fakes, não mocks ad-hoc:** `InMemoryPatientRepository`, `InMemoryEventBus`, `InMemoryLookupValidator`, `PatientFixture` em `Tests/social-care-sTests/Application/TestDoubles/`. (No social-care os fakes ficam no **test target**, em `TestDoubles/` — não junto à interface com `#if DEBUG`. Onde a doc genérica abaixo disser "near the interface", leia "em `TestDoubles/`".)
> - **AAA explícito**, `Date` injetável (`now: Date = .now` / `Date(timeIntervalSince1970: 0)`), UUID fixtures válidos, **PII mascarada** (`***`) — nunca CPF/NIS real no repo.
> - **Cobertura ≥ 95% no CI** (`scripts/check_coverage.sh`); 30% gate local.
> - **Regressão (ADR-002):** fix de bug HIGH/CRITICAL ganha teste em `Tests/.../Regression/<tema>/` (`Concurrency/`, `DataIntegrity/`, `EventPublication/`, `Security/`, `DomainInvariants/`, `ErrorMapping/`), struct contém `Regression`, teste `test_<ACHADO_ID>_…`, determinismo via `RegressionFixture`.
> - **Regra inviolável:** suite inteira verde antes de fechar — falha colateral é responsabilidade de quem está no comando.
>
> **Esta skill é horizontal** — fundiu `swift-testing` + `-expert` + `-pro`.
> A vertical `swift-test-writer` decide *o que/onde* testar no projeto; aqui
> está a *profundidade do framework*. Em conflito, **handbook e ADRs prevalecem**.

## Agent Behavior Contract

1. Use `swift-testing` (`@Test`, `#expect`, `#require`, `@Suite`) para todo teste novo — nunca XCTest.
2. Estruture com **Arrange-Act-Assert** explícito.
3. F.I.R.S.T.: Fast, Isolated, Repeatable, Self-Validating, Timely.
4. **Fakes em `TestDoubles/`** (taxonomia Fowler: Dummy/Fake/Stub/Spy/SpyingStub/Mock — o que o projeto chama de `InMemory*` é tipicamente um SpyingStub: estado + captura, ex.: `InMemoryEventBus.publishedEvents`).
5. `#expect` para asserção soft (continua); `#require` para hard (aborta — use para unwrap de `Optional`).
6. Prefira verificação de **estado** a verificação de comportamento.
7. Teste os states do handler: sucesso, erro de domínio, conflito (`uniqueViolation`), falha de adapter, **e que eventos NÃO são publicados quando o save falha**.

## Core Syntax (estado do projeto)

```swift
import Testing
@testable import social_care_s

@Suite("RegisterPatientCommandHandler")
struct RegisterPatientCommandHandlerTests {
    @Test("Happy path — persists patient and publishes PatientRegistered")
    func happyPath() async throws {
        // Arrange
        let sut = Self.makeSUT()
        let command = RegisterPatientCommand.fixture()
        // Act
        let id = try await sut.handler.handle(command)
        // Assert
        #expect(!id.isEmpty)
        #expect(try await sut.repository.exists(byPersonId: PersonId(command.personId)))
        let events = await sut.bus.publishedEvents
        #expect(events.contains { $0 is PatientRegistered })
    }
}
```

### `#expect` vs `#require`

| Macro | Semântica | Uso típico no projeto |
|---|---|---|
| `#expect(_)` | soft — continua após falhar | maioria das asserções de estado |
| `#require(_)` | hard — aborta o teste | unwrap de `Optional` antes de prosseguir; pré-condição que invalida o resto |
| `#expect(throws: E.self) { }` | espera erro do tipo | erros de domínio / `AppError` (`await #expect(throws:)` em async) |

Detalhe e tabela de decisão: `references/expectations.md`.

## Three sections

### Fundamentals
Organização de suites, AAA, F.I.R.S.T., test doubles, fixtures, integração, pirâmide de teste. Refs: `fundamentals.md`, `test-organization.md`, `test-doubles.md`, `fixtures.md`, `integration-testing.md`, `parameterized-tests.md` / `parameterized-testing.md`.

```swift
// Parameterized — varre múltiplos inputs (ex.: CPFs all-same-digit)
@Test("Throws repeatedDigits for all-same-digit strings",
      arguments: ["11111111111", "22222222222", "00000000000"])
func repeatedDigits(input: String) {
    #expect(throws: CPFError.self) { _ = try CPF(input) }
}
```

### Advanced
Traits & tags (filtragem em CI: `make regression`), paralelismo e `.serialized` (testes de Postgres de integração precisam de isolamento), `confirmation` para async/eventos, prevenção de flakiness, time limits. Refs: `traits-and-tags.md`, `parallelization-and-isolation.md`, `async-testing.md` / `async-testing-and-waiting.md` / `async-tests.md`, `performance-and-best-practices.md`.

> **Paralelismo + Postgres:** unit tests com fakes `InMemory*` rodam em paralelo sem dor. Integração com `docker compose up postgres` exige `.serialized` no suite e cleanup de fixtures — senão dão flaky por estado compartilhado no banco.

### Code Review
Checklist de qualidade de teste, regras núcleo, recursos novos, anti-flakiness. Refs: `core-rules.md`, `writing-better-tests.md`, `new-features.md`.

## Regressão (ADR-002) — padrão obrigatório do projeto

```swift
@Suite("Regression: Concurrency")
struct OptimisticLockRegressionTests {
    @Test("S-C3 / DB-2 — concurrent save rejects stale version")
    func test_S_C3_DB_2_lost_update_is_rejected() async throws {
        let clock = RegressionFixture.frozenClock()   // determinismo, nunca Date()/UUID() direto
        // Arrange estado inválido aceito antes da fix → Act → Assert #expect(throws:)
    }
}
```

`make regression` filtra structs com `Regression` e roda em < 5s. Detalhe em `handbook/tooling/swift/testing/regression-pattern.md` e na vertical `swift-test-writer`.

## Migração de XCTest

Há três referências de migração herdadas das skills fundidas — todas mapeiam `XCTAssert*` → `#expect`/`#require`, `setUp/tearDown` → `init`/`deinit`, `XCTestExpectation` → `confirmation`. Use `migration-xctest.md` como principal; `migration-from-xctest.md` e `migrating-from-xctest.md` são ângulos complementares.

## Reference Router

Índice completo e por-problema em `references/_index.md`.

- **Fundamentals:** `fundamentals.md`, `test-organization.md`, `test-doubles.md`, `fixtures.md`, `integration-testing.md`, `parameterized-tests.md`, `parameterized-testing.md`, `snapshot-testing.md`, `dump-snapshot-testing.md`
- **Advanced:** `traits-and-tags.md`, `parallelization-and-isolation.md`, `expectations.md`, `async-testing.md`, `async-testing-and-waiting.md`, `async-tests.md`, `performance-and-best-practices.md`
- **Code Review:** `core-rules.md`, `writing-better-tests.md`, `new-features.md`
- **Migração / tooling:** `migration-xctest.md`, `migration-from-xctest.md`, `migrating-from-xctest.md`, `xcode-workflows.md`
- *(`snapshot-testing.md` é orientado a UI — neste backend prefira `dump-snapshot-testing.md` para snapshots textuais de agregados/eventos.)*

## Verification Checklist (ao escrever testes)

- AAA explícito; nomes descrevem comportamento, não implementação.
- Fakes em `TestDoubles/` (não inline); `InMemory*` espelha invariantes do repo real (ex.: optimistic lock).
- Fixtures com defaults sensatos, UUID válido, **PII mascarada** (`***`).
- `Date` injetável — nenhum teste depende de `.now` real.
- Erros testados via `#expect(throws:)`; estado pós-falha verificado (eventos não publicados).
- Sem rede real em unit tests; integração de Postgres em pasta separada + `.serialized`.
- **`make test` exit 0 — suite inteira verde** (não só os testes do seu ticket).
