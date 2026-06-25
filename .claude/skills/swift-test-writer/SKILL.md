---
name: swift-test-writer
description: >
  Implementa testes em `Tests/social-care-sTests/` usando `swift-testing`
  (não XCTest). Cobre Domain (VOs, agregados, analytics), Application
  (command/query handlers com fakes), IO (audit trail, middleware, mappers).
  Mantém fakes em `TestDoubles/`. Ativa quando o usuário menciona: teste,
  test, swift-testing, @Test, #expect, #require, fake, fixture, cobertura,
  coverage, TDD, RED, InMemoryRepository.
---

# Swift Test Writer — social-care

Especialista em testes. Escreve em `Tests/social-care-sTests/`. **Nunca toca**
código de produção em `Sources/`.

## Framework: swift-testing (não XCTest)

```swift
import Testing
@testable import social_care_s

@Suite("RegisterPatientCommandHandler")
struct RegisterPatientCommandHandlerTests {

    @Test("Happy path — persists patient and publishes PatientRegistered")
    func happyPath() async throws {
        // Arrange
        let sut = makeSUT()
        let command = RegisterPatientCommand.fixture()

        // Act
        let patientId = try await sut.handler.handle(command)

        // Assert
        #expect(!patientId.isEmpty)
        #expect(try await sut.repository.exists(byPersonId: PersonId(command.personId)))
        let events = await sut.bus.publishedEvents
        #expect(events.contains { $0 is PatientRegistered })
    }
}
```

**API base:**

| API | Uso |
|---|---|
| `@Suite("Nome")` | Agrupa testes relacionados |
| `@Test("descrição")` | Marca função como teste |
| `#expect(condition)` | Asserção que continua mesmo se falhar |
| `#require(value)` | Asserção que aborta se falhar (use para `Optional` → unwrap) |
| `#expect(throws: ErrorType.self) { ... }` | Espera que o bloco lance erro do tipo |
| `@Test(arguments: [...])` | Parametrized test |

> **Aprofundamento do framework:** para traits/tags, paralelismo e `.serialized`
> (testes de Postgres), `confirmation`, tabela `#expect` vs `#require`, e migração
> de XCTest, consulte a skill horizontal **`swift-testing`**. Esta skill
> (`swift-test-writer`) é a execução — *o que/onde* testar no `social-care`.

## Estrutura

```
Tests/social-care-sTests/
  Application/
    Registry/RegisterPatientTests.swift, AddFamilyMemberTests.swift, ...
    Assessment/UpdateHealthStatusTests.swift, ...
    Care/RegisterAppointmentTests.swift, ...
    Protection/CreateReferralTests.swift, ...
    Query/GetUnifiedProfileTests.swift
    TestDoubles/
      InMemoryPatientRepository.swift
      InMemoryEventBus.swift
      InMemoryLookupValidator.swift
      InMemoryPersonExistenceValidator.swift
      PatientFixture.swift
      CommandFixtures.swift
  Domain/v2/
    Kernel/CPFTests.swift, NISTests.swift, CEPTests.swift, ...
    Registry/PatientTests.swift, FamilyAggregateTests.swift, ...
    Assessment/Analytics/FinancialAnalyticsTests.swift, ...
  IO/
    HTTP/AuditTrailTests.swift, JWTAuthMiddlewareTests.swift, ...
    Persistence/SQLKitPatientRepositoryTests.swift (integration)
```

## Princípios não negociáveis

1. **Fakes em vez de mocks** — Use `InMemory*` na pasta `TestDoubles/`.
2. **AAA (Arrange-Act-Assert)** explicit nos comentários.
3. **UUID fixtures válidos** — não gere strings aleatórias para campos com formato.
4. **`Date` injetável** — testes passam `now: Date(timeIntervalSince1970: 0)` para determinismo.
5. **Test states**: sucesso, erro de domínio, conflito (`uniqueViolation`), falha de adapter.
6. **PII mascarada** em fixture (`***`) — nunca commit CPF/NIS real no repo.
7. **Cobertura ≥ 95% no CI** (`scripts/check_coverage.sh`).
8. **Sem rede real** em unit tests — apenas integration tests em pasta separada.

## Template de Fake (TestDoubles)

```swift
import Foundation
@testable import social_care_s

public actor InMemoryPatientRepository: PatientRepository {
    private(set) var stored: [PatientId: Patient] = [:]

    public init(seed: [Patient] = []) {
        for patient in seed { stored[patient.id] = patient }
    }

    public func save(_ patient: Patient) async throws {
        if let existing = stored[patient.id], existing.version >= patient.version {
            throw PersistenceConflictError.uniqueViolation(constraint: "patient.version")
        }
        stored[patient.id] = patient
    }

    public func fetchById(_ id: PatientId) async throws -> Patient {
        guard let patient = stored[id] else {
            throw PersistenceConflictError.notFound(id: id.description)
        }
        return patient
    }

    public func exists(byPersonId id: PersonId) async throws -> Bool {
        stored.values.contains(where: { $0.personId == id })
    }

    public func exists(byCpf cpf: CPF) async throws -> Bool {
        stored.values.contains(where: { $0.civilDocuments?.cpf == cpf })
    }
}
```

```swift
public actor InMemoryEventBus: EventBus {
    public private(set) var publishedEvents: [any DomainEvent] = []

    public init() {}

    public func publish(_ events: [any DomainEvent]) async throws {
        publishedEvents.append(contentsOf: events)
    }

    public func reset() {
        publishedEvents.removeAll()
    }
}
```

```swift
public actor InMemoryLookupValidator: LookupValidating {
    private var registry: [String: Set<LookupId>]

    public init(registry: [String: Set<LookupId>] = [:]) {
        self.registry = registry
    }

    public static func withValidParentesco() -> InMemoryLookupValidator {
        let titular = try! LookupId(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!.uuidString)
        return InMemoryLookupValidator(registry: [
            "dominio_parentesco": [titular]
        ])
    }

    public static func empty() -> InMemoryLookupValidator {
        InMemoryLookupValidator()
    }

    public func exists(id: LookupId, in table: String) async throws -> Bool {
        registry[table]?.contains(id) ?? false
    }
}
```

## Template de Fixture

```swift
@testable import social_care_s
import Foundation

extension RegisterPatientCommand {

    static func fixture(
        personId: String = UUID().uuidString,
        prRelationshipId: String = "00000000-0000-0000-0000-000000000001",
        actorId: String = "actor-test",
        diagnoses: [DiagnosisDraft] = [
            .init(icdCode: "C00.0", date: Date(timeIntervalSince1970: 0), description: "test")
        ]
    ) -> RegisterPatientCommand {
        RegisterPatientCommand(
            personId: personId,
            initialDiagnoses: diagnoses,
            prRelationshipId: prRelationshipId,
            actorId: actorId
        )
    }
}

enum PatientFixture {

    static func valid(now: Date = Date(timeIntervalSince1970: 0)) -> Patient {
        try! Patient(
            id: PatientId(),
            personId: try! PersonId(UUID().uuidString),
            personalData: nil,
            civilDocuments: nil,
            address: nil,
            diagnoses: [],
            familyMembers: [],
            prRelationshipId: try! LookupId(UUID().uuidString),
            actorId: "actor-test"
        )
    }
}
```

**Regras:**
- Fixture é factory com defaults sensatos + override via parâmetros.
- `try!` aceito em fixtures (fail-fast no setup).
- UUIDs determinísticos para asserts cross-test.

## Template de Test (Domain — VO)

```swift
import Testing
@testable import social_care_s

@Suite("CPF")
struct CPFTests {

    @Test("Accepts valid CPF with formatting")
    func validFormatted() throws {
        let cpf = try CPF("123.456.789-09")
        #expect(cpf.value == "12345678909")
        #expect(cpf.formatted == "123.456.789-09")
    }

    @Test("Accepts valid CPF without formatting")
    func validUnformatted() throws {
        let cpf = try CPF("12345678909")
        #expect(cpf.value == "12345678909")
    }

    @Test("Throws empty for whitespace-only string")
    func emptyThrows() {
        #expect(throws: CPFError.self) {
            _ = try CPF("   ")
        }
    }

    @Test("Throws repeatedDigits for all-same-digit strings",
          arguments: ["11111111111", "22222222222", "00000000000"])
    func repeatedDigits(input: String) {
        #expect(throws: CPFError.self) {
            _ = try CPF(input)
        }
    }

    @Test("Throws invalidCheckDigits for known-bad CPF")
    func invalidCheckDigits() {
        #expect(throws: CPFError.invalidCheckDigits(value: "12345678900")) {
            _ = try CPF("12345678900")
        }
    }

    @Test("AppErrorConvertible — maps to KER/cpf code")
    func appErrorMapping() {
        let error = CPFError.invalidCheckDigits(value: "12345678900")
        let appError = error.asAppError
        #expect(appError.code == "CPF-005")
        #expect(appError.bc == "kernel")
        #expect(appError.module == "cpf")
        #expect(appError.observability.category == .domainRuleViolation)
        #expect(appError.http == 422)
    }
}
```

## Template de Test (Application — Handler com Fakes)

```swift
@Suite("RegisterPatientCommandHandler")
struct RegisterPatientCommandHandlerTests {

    struct SUT {
        let handler: RegisterPatientCommandHandler
        let repository: InMemoryPatientRepository
        let bus: InMemoryEventBus
        let lookup: InMemoryLookupValidator
    }

    static func makeSUT(
        seed: [Patient] = [],
        lookup: InMemoryLookupValidator = .withValidParentesco()
    ) -> SUT {
        let repo = InMemoryPatientRepository(seed: seed)
        let bus = InMemoryEventBus()
        let handler = RegisterPatientCommandHandler(
            repository: repo,
            eventBus: bus,
            lookupValidator: lookup
        )
        return SUT(handler: handler, repository: repo, bus: bus, lookup: lookup)
    }

    @Test("Happy path — saves and publishes PatientRegistered")
    func happyPath() async throws {
        let sut = Self.makeSUT()
        let command = RegisterPatientCommand.fixture()

        let id = try await sut.handler.handle(command)

        #expect(!id.isEmpty)
        let personId = try PersonId(command.personId)
        #expect(try await sut.repository.exists(byPersonId: personId))
        let events = await sut.bus.publishedEvents
        #expect(events.count == 1)
        #expect(events.first is PatientRegistered)
    }

    @Test("Throws when PR relationship lookup is invalid")
    func invalidLookup() async throws {
        let sut = Self.makeSUT(lookup: .empty())
        let command = RegisterPatientCommand.fixture()

        await #expect(throws: AppError.self) {
            _ = try await sut.handler.handle(command)
        }
        let events = await sut.bus.publishedEvents
        #expect(events.isEmpty)  // não publicou nada porque falhou antes
    }

    @Test("Throws personIdAlreadyExists when patient with personId is already stored")
    func duplicatePersonId() async throws {
        let existing = PatientFixture.valid()
        let sut = Self.makeSUT(seed: [existing])
        let command = RegisterPatientCommand.fixture(personId: existing.personId.description)

        await #expect(throws: AppError.self) {
            _ = try await sut.handler.handle(command)
        }
    }

    @Test("Eventos publicados APÓS save — não publica se save falha")
    func eventsAfterPersistence() async throws {
        // ... constrói repo que falha no save
        // ... verifica que publishedEvents está vazio
    }
}
```

## Template de Test (IO — Audit Trail)

```swift
@Suite("Audit Trail — extractActorId")
struct AuditTrailTests {

    @Test("Returns JWT.sub as actorId when authenticated")
    func extractsSubFromJWT() async throws {
        let app = try await Application.testApp()
        let token = try JWTFixture.valid(sub: "user-123")

        try await app.test(.POST, "/patients", headers: ["Authorization": "Bearer \(token)"]) { res in
            #expect(res.status == .created)
            // assert downstream que command.actorId == "user-123"
        }
    }

    @Test("Throws AUTH-002 when no bearer token")
    func missingBearer() async throws {
        let app = try await Application.testApp()
        try await app.test(.POST, "/patients") { res in
            #expect(res.status == .unauthorized)
            let body = try res.content.decode(ErrorResponse.self)
            #expect(body.error.code == "AUTH-001")
        }
    }
}
```

## Comandos

```bash
make test                              # roda todos
swift test --filter CPFTests           # roda só CPF
swift test --filter RegisterPatient    # roda tudo de RegisterPatient
make coverage                          # gera report local
make coverage-report                   # relatório detalhado
```

## REPORT.md (output)

```markdown
# Test Layer — <ticket>

## Suites adicionadas
- @Suite RegisterPatientCommandHandler (8 tests)
  - happy path
  - invalidLookup
  - duplicatePersonId
  - duplicateCPF
  - personIdNotFoundInPeopleContext
  - invalidSex
  - eventos publicados após save
  - invariantes de PR única

## TestDoubles novos/atualizados
- InMemoryPatientRepository (já existia — sem mudança)
- InMemoryPersonExistenceValidator (NOVO)

## Fixtures
- RegisterPatientCommand.fixture(...)
- PatientFixture.valid(now:)

## Cobertura
- Domain/Kernel: 98%
- Domain/Registry: 96%
- Application/Registry/RegisterPatient: 100%
- Local gate: PASSED (>= 30%)
- Aguardando CI gate (>= 95%)
```

## Padrão de Teste de Regressão (ADR-002)

Quando o ticket atende um achado documentado em `handbook/reports/` com severidade ≥ HIGH, o teste **DEVE** seguir o padrão de regressão descrito em `handbook/tooling/swift/testing/regression-pattern.md`. Resumo:

1. **Onde:** `Tests/social-care-sTests/Regression/<subpasta>/<NomeRegressionTests>.swift` — 6 subpastas: `Concurrency/`, `DataIntegrity/`, `EventPublication/`, `Security/`, `DomainInvariants/`, `ErrorMapping/`.
2. **Nome do struct:** contém `Regression` (para `make regression` filtrar).
3. **Nome do teste:** `test_<ACHADO_ID>_<descrição>()` — ex: `test_S_C3_DB_2_lost_update_is_rejected()`.
4. **Anatomia:** Arrange reproduz o estado inválido aceito antes da fix → Act executa a operação → Assert garante que o invariante da fix é respeitado (geralmente `#expect(throws: ...)`).
5. **Determinismo:** SEMPRE via `RegressionFixture` (em `Application/TestDoubles/RegressionFixture.swift`) — `frozenClock`, `uuid(seed:)`, `prepopulatedLookupValidator`, `stubUnitOfWork`. NUNCA `Date()`, `UUID()`, `.now` direto.
6. **Validar:** `make regression` roda em < 5s (wall-clock) e o teste novo aparece no output.

```swift
@Suite("Regression: Concurrency")
struct OptimisticLockRegressionTests {
    @Test("S-C3 / DB-2 — concurrent save rejects stale version")
    func test_S_C3_DB_2_lost_update_is_rejected() async throws {
        let clock = RegressionFixture.frozenClock()
        // ...arrange/act/assert...
    }
}
```

## Lições Aprendidas (regressões prevenidas)

> Cada item aqui é um padrão que **a skill deve aplicar por default** porque já custou caro no passado. Sempre que um ADR aprovado introduzir um Better Pattern, ele é adicionado aqui com link ao ADR e ao teste de regressão.

| # | Padrão / Regra | ADR | Teste de regressão |
|---|---|---|---|
| 1 | Toda fix de bug HIGH/CRITICAL ganha teste em `Tests/.../Regression/<tema>/` com nome `test_<ACHADO_ID>_…`. Usa `RegressionFixture` para determinismo. | [ADR-002](../../../handbook/architecture/DECISIONS/ADR-002-regression-test-policy.md) | `Regression/RegressionMeta.swift` (sentinels da infra) |

> Conforme a `REMEDIATION_PIPELINE_2026_05_14.md` avança, novas linhas entram aqui. Cada nova lição cita: regra, ADR, teste que enforça.

## ⚠️ REGRA INVIOLÁVEL — Suite verde é responsabilidade de QUEM ESTÁ NO COMANDO

Se durante seu trabalho um teste falhar — **qualquer teste**, em qualquer arquivo, mesmo que não tenha sido tocado pelo seu ticket — você **DEVE** consertar antes de fechar.

- ❌ Errado: "esse teste já falhava antes, está fora do escopo do meu ticket"
- ❌ Errado: documentar como pré-existente no REPORT.md e marcar ticket completo
- ✅ Certo: parar, investigar (`swift test --filter <NomeDoTeste>`), consertar, validar suite verde, então fechar

Conduzir falhas colaterais é parte da disciplina de regressão (ADR-002). Falha colateral é sintoma de instabilidade — deixar correr corrói o suite.

Quando o conserto exige mudança fora do escopo do ticket:
1. Criar sub-ticket (ex: `T-004.fix-oidc-exp`)
2. Consertar como W0/W1 mínimo
3. Voltar ao ticket original
4. Reportar ambos no REPORT.md

## Antes de fechar

- [ ] **Suite inteiro verde** (`make test` exit 0 — não só os testes do meu ticket)
- [ ] Suites usam `@Suite`/`@Test`, não XCTest
- [ ] Fakes em `TestDoubles/`, não inline
- [ ] AAA explícito
- [ ] UUID fixtures válidos
- [ ] PII mascarada (`***`)
- [ ] Cobertura local ≥ 30%; CI gate aguardado
- [ ] Nenhum teste depende de `Date.now` real (injetar)
- [ ] Erros testados via `#expect(throws:)`
- [ ] Estado pós-falha verificado (eventos não publicados, etc)
