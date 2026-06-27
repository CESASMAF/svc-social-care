---
name: swift-domain-modeler
description: >
  Implementa a camada `Sources/social-care-s/Domain/` — Value Objects, Agregados,
  Entidades, Analytics Services, Repository contracts (`protocol`), errors
  enum implementando `AppErrorConvertible`. Ativa quando o usuário menciona:
  Value Object, VO, agregado, aggregate, entidade, domain event, analytics
  service, lookup id, CPF, NIS, CEP, kernel, Registry, Assessment, Care,
  Protection.
---

# Swift Domain Modeler — social-care

Especialista em modelagem de domínio Swift seguindo Clean Architecture + DDD
do `social-care`. Escreve em `Sources/social-care-s/Domain/`. **Nunca toca**
Application, IO, nem testes.

## Escopo

| Sub-pasta | Conteúdo |
|---|---|
| `Domain/Kernel/` | 10 VOs cross-cutting: CPF, NIS, CEP, PersonId, ProfessionalId, LookupId, RGDocument, Address, TimeStamp, ICDCode |
| `Domain/Registry/` | Agregado `Patient` + entidade `FamilyMember` + VOs (`PatientId`, `PersonalData`, `SocialIdentity`, `CivilDocuments`) + `FamilyAnalytics` |
| `Domain/Assessment/` | VOs de avaliação (`HousingCondition`, `HealthStatus`, `EducationalStatus`, `SocioEconomicSituation`, `WorkAndIncome`, `SocialBenefit*`, `CommunitySupportNetwork`, `SocialHealthSummary`) + analytics (`Education`, `Financial`, `Housing`) |
| `Domain/Care/` | Agregado `SocialCareAppointment`, VOs (`Diagnosis`, `ICDCode`, `AppointmentId`, `IngressInfo`) |
| `Domain/Protection/` | Agregados `Referral` e `RightsViolationReport`, entidade `PlacementHistory`, VOs (`ReferralId`, `ViolationReportId`) |
| `Domain/Configuration/` | Contratos de lookup (`LookupValidating`, `LookupId`) |

## Princípios não negociáveis

1. **Zero deps externas** — só `Foundation` (e nada de Vapor, SQLKit, JWT).
2. **`struct` por padrão** — `class` somente se houver justificativa documentada (não há caso atual).
3. **VO imutável com validação no init** — `let value: String`, `init(_:) throws`.
4. **Erro como `enum`** implementando `AppErrorConvertible`.
5. **Repository contract aqui** — `protocol` em `<BC>/Repository/`. Impl mora em IO.
6. **Inteligência no Domínio** — todo cálculo (renda per capita, densidade, vulnerabilidade) vive em Analytics Service.
7. **CRU (No Delete)** — agregados nunca expõem método `delete`. Use flag de inativação.
8. **Lookup Primeiro** — `LookupId` em vez de `String` para campos com tabela `dominio_*`.

## Template de Value Object

```swift
import Foundation

/// Cadastro de Pessoa Física (CPF) brasileiro com dígitos verificadores validados.
public struct CPF: Codable, Equatable, Hashable, Sendable {
    public let value: String

    /// Instancia um CPF a partir de string crua (aceita `123.456.789-09` ou `12345678909`).
    /// - Parameter rawValue: CPF em qualquer formato suportado.
    /// - Throws: `CPFError` se vazio, com caracteres inválidos, comprimento errado, dígitos repetidos ou check digits inválidos.
    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CPFError.empty }
        let sanitized = trimmed.filter(\.isNumber)
        guard sanitized.count == 11 else {
            throw CPFError.invalidLength(value: sanitized, expected: 11)
        }
        guard Set(sanitized).count > 1 else {
            throw CPFError.repeatedDigits(value: sanitized)
        }
        guard Self.hasValidCheckDigits(sanitized) else {
            throw CPFError.invalidCheckDigits(value: sanitized)
        }
        self.value = sanitized
    }

    public var formatted: String { /* derivado de value */ }

    private static func hasValidCheckDigits(_ value: String) -> Bool { /* ... */ }
}
```

## Template de Error de Domínio

```swift
public enum CPFError: Error, Equatable, Sendable, AppErrorConvertible {
    case empty
    case invalidCharacters(value: String)
    case invalidLength(value: String, expected: Int)
    case repeatedDigits(value: String)
    case invalidCheckDigits(value: String)

    public var asAppError: AppError {
        AppError(
            code: code,
            message: humanMessage,
            bc: "kernel",
            module: "cpf",
            kind: "\(self)",
            context: ["raw": AnySendable(rawContext)],
            safeContext: [:],  // nunca expor o valor cru com PII
            observability: .init(
                category: .domainRuleViolation,
                severity: .warning,
                fingerprint: [code],
                tags: [:]
            ),
            http: 422
        )
    }

    private var code: String {
        switch self {
        case .empty: "CPF-001"
        case .invalidCharacters: "CPF-002"
        case .invalidLength: "CPF-003"
        case .repeatedDigits: "CPF-004"
        case .invalidCheckDigits: "CPF-005"
        }
    }

    private var humanMessage: String { /* ... */ }
    private var rawContext: Any { /* ... */ }
}
```

**Regras:**
- `code` por caso, formato `<MODULE>-<NNN>` (3 dígitos)
- `context` traz dados brutos para debug interno
- `safeContext` traz versão sanitizada para logs externos (sem PII)
- `http` aponta status sugerido (422 para validação, 404 para not found, 409 para conflito)
- `category` deve ser `domainRuleViolation` em VOs/agregados

## Template de Agregado

```swift
public struct Patient: EventSourcedAggregate, Sendable {
    public let id: PatientId
    public let personId: PersonId

    public private(set) var personalData: PersonalData?
    public private(set) var civilDocuments: CivilDocuments?
    public private(set) var address: Address?
    public private(set) var diagnoses: [Diagnosis]
    public private(set) var familyMembers: [FamilyMember]
    public private(set) var prRelationshipId: LookupId
    public private(set) var socialIdentity: SocialIdentity?
    public private(set) var version: Int
    public private(set) var uncommittedEvents: [any DomainEvent]

    public init(
        id: PatientId,
        personId: PersonId,
        personalData: PersonalData?,
        // ...
        familyMembers: [FamilyMember],
        prRelationshipId: LookupId,
        actorId: String
    ) throws {
        // valida invariantes — ex.: exatamente 1 PR, idade coerente com diagnóstico
        try Self.validateSinglePR(familyMembers)

        self.id = id
        // ...
        self.version = 1
        self.uncommittedEvents = [
            PatientRegistered(
                id: UUID(),
                occurredAt: .now,
                patientId: id,
                actorId: actorId
            )
        ]
    }

    public mutating func updateSocialIdentity(_ identity: SocialIdentity, actorId: String) throws {
        // valida
        self.socialIdentity = identity
        self.version += 1
        self.uncommittedEvents.append(
            SocialIdentityUpdated(
                id: UUID(),
                occurredAt: .now,
                patientId: id,
                identity: identity,
                actorId: actorId
            )
        )
    }
}
```

**Regras:**
- Conforma `EventSourcedAggregate` (`id`, `version`, `uncommittedEvents`)
- Props mutáveis com `public private(set) var` — leitura aberta, escrita interna
- `init` valida todas invariantes e emite evento inicial
- Métodos `mutating` para mudanças de estado — validam invariantes, mutam, incrementam version, append evento
- Eventos no passado: `PatientRegistered`, `FamilyMemberAdded`, `SocialIdentityUpdated`

## Template de Domain Event

```swift
public struct PatientRegistered: DomainEvent, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public let patientId: PatientId
    public let actorId: String
    // payload mínimo — não duplique o agregado inteiro
}
```

**Regras:**
- Sufixo no passado (`Registered`, `Updated`, `Added`, `Removed`).
- `id: UUID` e `occurredAt: Date` obrigatórios (do `DomainEvent`).
- Payload mínimo para reconstruir o fato; consumidores recompõem o resto via repo.
- Registrar em `shared/Domain/DomainEventRegistry.swift` se ainda não estiver.

## Template de Analytics Service

```swift
public struct FinancialAnalyticsService: Sendable {

    /// Calcula renda total da família somando contribuições individuais e benefícios.
    /// - Parameter family: composição familiar do agregado.
    /// - Returns: Renda total em reais.
    public func totalIncome(_ family: [FamilyMember]) -> Decimal {
        family.compactMap(\.workAndIncome?.monthlyIncome).reduce(0, +)
    }

    /// Renda per capita = renda total / membros residentes com o paciente.
    public func perCapita(_ family: [FamilyMember]) -> Decimal {
        let total = totalIncome(family)
        let residents = family.count(where: \.residesWithPatient)
        guard residents > 0 else { return 0 }
        return total / Decimal(residents)
    }
}
```

**Regras:**
- `struct Sendable` pura (sem deps).
- Recebe agregado/entidades como parâmetro — **não** consulta repo.
- Doc Markdown obrigatório.
- Métodos não-mutating com sufixo nominal (`totalIncome`, `perCapita`, `densityRatio`).

## Template de Repository Contract

```swift
public protocol PatientRepository: Sendable {
    func save(_ patient: Patient) async throws
    func fetchById(_ id: PatientId) async throws -> Patient
    func exists(byPersonId: PersonId) async throws -> Bool
    func exists(byCpf: CPF) async throws -> Bool
    func find(byPersonId: PersonId) async throws -> Patient?
}
```

Localização: `Domain/<BC>/Repository/<Aggregate>Repository.swift`.

**Regras:**
- Protocol `Sendable`
- Métodos `async throws` — assíncrono sempre
- Returns: agregado completo ou `Bool`/`Optional` para queries simples
- **Não** retorne DTO daqui — DTOs vivem em IO

## Padrão de naming (Swift API Design Guidelines)

| Caso | Padrão | Exemplo |
|---|---|---|
| Protocolo "o que é" | substantivo | `Command`, `Query`, `DomainEvent`, `EventSourcedAggregate` |
| Protocolo de capacidade | `-able`/`-ible`/`-ing` | `LookupValidating`, `AppErrorConvertible`, `Sendable` |
| Bool computed | `is*`/`has*` | `isPrimaryCaregiver`, `hasValidCheckDigits` |
| Mutating method | verbo imperativo | `updateSocialIdentity`, `appendDiagnosis` |
| Non-mutating | `-ed`/`-ing` ou substantivo | `perCapita(_:)`, `densityRatio(_:)` |
| Error case | snake do estado | `personIdAlreadyExists`, `invalidLookupId(table:id:)` |

## REPORT.md (output)

Ao terminar, escrever `.pipeline/<ticket>/001-contracts/REPORT.md`:

```markdown
# Domain Layer — <ticket>

## Public API
- VOs: `CPF`, `LookupId.parentesco`, `PersonalData.Sex`
- Aggregates: `Patient` (modified — added `socialIdentity`)
- Events: `SocialIdentityUpdated`
- Ports: `PatientRepository.exists(byPersonId:)` (new)
- Analytics: `FinancialAnalyticsService.perCapita(_:)` (new)

## Errors
- `RegisterPatientError.invalidLookupId` → 422
- `RegisterPatientError.personIdAlreadyExists` → 409

## Invariantes adicionadas
- Patient deve ter exatamente 1 PR (Pessoa de Referência).
- Diagnóstico exige `birthDate` para validação de idade.

## Próxima skill
- `swift-application-orchestrator` para wire dos handlers.
```

## Padrão Aggregate Root (pós-ADR-004)

Template canônico de aggregate root:

```swift
public struct Order: EventSourcedAggregate {
    public typealias ID = OrderId

    // EventSourcedAggregate
    public let id: OrderId
    public internal(set) var version: Int
    public internal(set) var uncommittedEvents: [any DomainEvent] = []

    // EventSourcedAggregateInternal (herdado de EventSourcedAggregate por composição)
    public mutating func addEvent(_ event: any DomainEvent) {
        uncommittedEvents.append(event)
        version += 1
    }

    public mutating func clearEvents() {
        uncommittedEvents.removeAll()
    }

    // Mutating funcs do agregado usam recordEvent (não addEvent direto):
    public mutating func ship(by actor: ActorId, now: TimeStamp = .now) throws {
        try requireActive()
        // ... transição de estado ...
        self.recordEvent(OrderShippedEvent(id: id, shippedAt: now, actorId: actor))
    }
}
```

Anti-pattern: implementar apenas `EventSourcedAggregate` sem os métodos de `Internal`. Pré-ADR-004 compilava e `recordEvent` virava no-op silencioso. Pós-ADR-004, **não compila** — defesa em compile-time.

## Lições Aprendidas (regressões prevenidas)

> Cada item aqui é um padrão que **a skill deve aplicar por default** porque já custou caro no passado. Sempre que um ADR aprovado introduzir um Better Pattern, ele é adicionado aqui com link ao ADR e ao teste de regressão.

| # | Padrão / Regra | ADR | Teste de regressão |
|---|---|---|---|
| 1 | Aggregate root é `struct: EventSourcedAggregate` (protocolo composto pós-ADR-004). Implementa `addEvent` + `clearEvents` obrigatoriamente. NUNCA usar cast dinâmico `as? any P` em extension default de protocolo quando comportamento muda silenciosamente — promova relação para o sistema de tipos. | [ADR-004](../../../handbook/architecture/DECISIONS/ADR-004-event-sourced-aggregate-composite-protocol.md) | `Tests/.../Regression/EventPublication/RecordEventSilentNoopRegressionTests.swift` |
| 2 | Valor monetário no Domain SEMPRE é `Money` (`centavos: Int64, currency: String`). NUNCA `Double`/`Float`/`Decimal`. Aritmética via operadores throws (currency-safe). Conversão para `Double` apenas no boundary HTTP/SQL via `valorReal`. Erros de "valor negativo" são impossíveis por construção — não modelar. | [ADR-009](../../../handbook/architecture/DECISIONS/ADR-009-money-vo-replaces-double.md) | `Tests/.../Regression/DomainInvariants/MoneyIsExactRegressionTests.swift` |
| 3 | **Aggregate Boundary Heuristic (Vernon Small Aggregates Rule):** quando aggregate root acumular módulos opcionais que representam BCs distintos preenchidos em momentos diferentes da jornada, decompor via **expand-contract** por sub-aggregate: (a) EXPAND — criar `<SubAggregate>: EventSourcedAggregate` com `id` que **coincide com o id do parent** quando relação 1:0..1 (NUNCA criar UUID surrogate adicional), referencia parent por **`parentId: ParentId` valor** (NUNCA compor parent), repository próprio, tabela própria com FK + trigger updated_at, backfill idempotente; (b) DUAL-WRITE — handlers chamam ambos repos; (c)+(d) CUTOVER — leitura migra para o novo via Query layer (JOIN); (e) CONTRACT — drop colunas antigas + campos no aggregate antigo. Cada estágio é PR independente. Citação Vernon p. 365 ("Reference Other Aggregates by Identity"). | [ADR-024](../../../handbook/architecture/DECISIONS/ADR-024-patient-assessment-aggregate-expand.md) | `Tests/.../Regression/DomainInvariants/PatientAssessmentDecompositionTests.swift` |

## Antes de fechar

- [ ] Doc Markdown em toda API pública
- [ ] VO conforma `Sendable, Equatable, Hashable`
- [ ] Error conforma `AppErrorConvertible` com `code` único
- [ ] Agregado expõe `uncommittedEvents` E implementa `addEvent`/`clearEvents` (ADR-004)
- [ ] Mutating funcs do agregado usam `self.recordEvent(...)` (não `addEvent` direto)
- [ ] Repository contract está em `Domain/`, não em Application
- [ ] Zero imports de Vapor/SQLKit/Foundation além do necessário
- [ ] `swift build -c release` sem warnings
- [ ] **Suite inteiro verde** (`make test` exit 0 — falha colateral é responsabilidade sua consertar)
