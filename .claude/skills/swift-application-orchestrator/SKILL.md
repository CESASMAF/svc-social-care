---
name: swift-application-orchestrator
description: >
  Implementa a camada `Sources/social-care-s/Application/` — Commands, Queries,
  Handlers (`actor` para write, `struct` para read), error mapping,
  Services protocols (`LookupValidating`, `PersonExistenceValidating`).
  Orquestra Domain + Ports. Ativa quando o usuário menciona: use case,
  command handler, query handler, CommandHandling, ResultCommandHandling,
  QueryHandling, parse → validate → domain → persist → publish, mapError.
---

# Swift Application Orchestrator — social-care

Especialista em casos de uso CQRS. Escreve em `Sources/social-care-s/Application/`.
**Nunca toca** Domain models, IO adapters, nem testes.

## Escopo

| Sub-pasta | Conteúdo |
|---|---|
| `Application/Registry/` | 9 use cases — RegisterPatient, AddFamilyMember, RemoveFamilyMember, AssignPrimaryCaregiver, UpdateSocialIdentity, AdmitPatient, ReadmitPatient, DischargePatient, WithdrawFromWaitlist, LinkPersonId |
| `Application/Assessment/` | 8 use cases — UpdateHealthStatus, UpdateHousingCondition, UpdateEducationalStatus, UpdateSocioEconomicSituation, UpdateWorkAndIncome, UpdateSocialBenefits, UpdateCommunitySupportNetwork, UpdateSocialHealthSummary |
| `Application/Care/` | 2 use cases — RegisterAppointment, RegisterIntakeInfo |
| `Application/Protection/` | 3 use cases — CreateReferral, ReportRightsViolation, UpdatePlacementHistory |
| `Application/Configuration/` | LookupAdmin, LookupRequest |
| `Application/Query/` | Query handlers + DTOs de leitura (PatientQueries, PatientRegistration) |

## Estrutura por use case

```
Application/<BC>/<UseCase>/
  Command/<UseCase>Command.swift          — payload struct
  UseCase/<UseCase>UseCase.swift          — protocol typealias (CommandHandling)
  Services/<UseCase>CommandHandler.swift  — actor com handle()
  Services/<UseCase>MapError.swift        — mapeia Error → AppError
  Error/<UseCase>Error.swift              — enum AppErrorConvertible
  Error/<UseCase>MapperError.swift        — erros de mapping (DTO ↔ domain)
```

## Princípios não negociáveis

1. **Sem `Vapor` import nesta camada** — Application não conhece HTTP.
2. **Sequência obrigatória dentro do handler:**
   ```
   parse VOs → validate (lookup, existence, business) → domain logic → persist → publish events
   ```
3. **Handler é `actor`** (write) ou `struct` (read).
4. **Dependências `private let`** injetadas via `init` — tipos `any P` (PoP).
5. **`do/catch` no topo + `throw mapError(error, ...)` no final.**
6. **Eventos publicados APÓS `repository.save`** — nunca antes.
7. **`actorId: String` obrigatório no Command** — derivado de `JWT.sub`.
8. **Erros enum implementam `AppErrorConvertible`** com `code` único.

## Template de Command

```swift
import Foundation

/// Payload de entrada para o registro de um novo paciente.
public struct RegisterPatientCommand: ResultCommand {
    public typealias Result = String  // ID do paciente criado

    public struct DiagnosisDraft: Sendable {
        public let icdCode: String
        public let date: Date
        public let description: String

        public init(icdCode: String, date: Date, description: String) {
            self.icdCode = icdCode
            self.date = date
            self.description = description
        }
    }

    // ... outras drafts

    public let personId: String
    public let initialDiagnoses: [DiagnosisDraft]
    public let personalData: PersonalDataDraft?
    public let civilDocuments: CivilDocumentsDraft?
    public let address: AddressDraft?
    public let socialIdentity: SocialIdentityDraft?
    public let prRelationshipId: String
    public let actorId: String

    public init(
        personId: String,
        initialDiagnoses: [DiagnosisDraft],
        personalData: PersonalDataDraft? = nil,
        civilDocuments: CivilDocumentsDraft? = nil,
        address: AddressDraft? = nil,
        socialIdentity: SocialIdentityDraft? = nil,
        prRelationshipId: String,
        actorId: String
    ) {
        // ...
    }
}
```

**Regras:**
- `struct` `Sendable` — Swift sintetiza quando todas as props são `Sendable`.
- Tipos primitivos (`String`, `Date`, `Bool`) — VOs vão ser instanciados no handler.
- Nested `Draft` structs para payloads opcionais — Sendable + `init` explícito.
- Conforma `Command` (não retorna) ou `ResultCommand` (retorna `typealias Result`).

## Template de UseCase Protocol

```swift
public protocol RegisterPatientUseCase: Actor {
    func handle(_ command: RegisterPatientCommand) async throws -> String
}
```

**Regras:**
- Herda de `Actor` (não de `CommandHandling` diretamente — facilita o nome semântico).
- Um protocol por use case, declarado em `UseCase/<UseCase>UseCase.swift`.
- Application e IO dependem **deste protocolo**, não da implementação.

## Template de Command Handler

```swift
import Foundation

/// Implementação do serviço Maestro para registro de novos pacientes.
public actor RegisterPatientCommandHandler: RegisterPatientUseCase {
    private let repository: any PatientRepository
    private let eventBus: any EventBus
    private let lookupValidator: any LookupValidating
    private let personValidator: (any PersonExistenceValidating)?

    public init(
        repository: any PatientRepository,
        eventBus: any EventBus,
        lookupValidator: any LookupValidating,
        personValidator: (any PersonExistenceValidating)? = nil
    ) {
        self.repository = repository
        self.eventBus = eventBus
        self.lookupValidator = lookupValidator
        self.personValidator = personValidator
    }

    public func handle(_ command: RegisterPatientCommand) async throws -> String {
        do {
            // 1. Parse VOs
            let personId = try PersonId(command.personId)
            let prId = try LookupId(command.prRelationshipId)
            let diagnoses = try command.initialDiagnoses.map { draft in
                try Diagnosis(
                    id: try ICDCode(draft.icdCode),
                    date: try TimeStamp(draft.date),
                    description: draft.description,
                    now: .now
                )
            }
            let personalData = try command.personalData.map(parsePersonalData)
            // ... outros parses

            // 2. Cross-context validation (PeopleContext)
            if let validator = personValidator {
                let exists = try await validator.exists(personId: personId)
                guard exists else {
                    throw RegisterPatientError.personIdNotFoundInPeopleContext(command.personId)
                }
            }

            // 3. Lookup validation (Metadata-Driven)
            guard try await lookupValidator.exists(id: prId, in: "dominio_parentesco") else {
                throw RegisterPatientError.invalidLookupId(
                    table: "dominio_parentesco",
                    id: prId.description
                )
            }

            // 4. Existence checks
            if try await repository.exists(byPersonId: personId) {
                throw RegisterPatientError.personIdAlreadyExists
            }
            if let cpf = civilDocuments?.cpf, try await repository.exists(byCpf: cpf) {
                throw RegisterPatientError.cpfAlreadyExists("***")  // PII masked
            }

            // 5. Domain logic
            let holderAsMember = try FamilyMember(
                personId: personId,
                relationshipId: prId,
                isPrimaryCaregiver: true,
                residesWithPatient: true,
                birthDate: personalData?.birthDate ?? TimeStamp.now
            )
            var patient = try Patient(
                id: PatientId(),
                personId: personId,
                // ...
                familyMembers: [holderAsMember],
                prRelationshipId: prId,
                actorId: command.actorId
            )

            // 6. Persist + publish
            try await repository.save(patient)
            try await eventBus.publish(patient.uncommittedEvents)

            return patient.id.description
        } catch {
            throw mapError(error, patientId: command.personId)
        }
    }

    private func parsePersonalData(_ draft: RegisterPatientCommand.PersonalDataDraft) throws -> PersonalData {
        // ... parse de campos
    }
}
```

## Template de Map Error

```swift
extension RegisterPatientCommandHandler {

    func mapError(_ error: any Error, patientId: String) -> any Error {
        switch error {
        case let appError as AppError:
            return appError

        case let convertible as any AppErrorConvertible:
            return convertible.asAppError

        case let conflict as PersistenceConflictError:
            // Repository lança PersistenceConflictError genérico
            // Aqui mapeamos para o erro de negócio específico
            switch conflict {
            case .uniqueViolation(let constraint):
                if constraint.contains("person_id") {
                    return RegisterPatientError.personIdAlreadyExists.asAppError
                }
                if constraint.contains("cpf") {
                    return RegisterPatientError.cpfAlreadyExists("***").asAppError
                }
                return AppError(/* fallback */)
            }

        default:
            return AppError(
                code: "PAT-999",
                message: "Erro inesperado ao registrar paciente",
                bc: "registry",
                module: "register_patient",
                kind: "unexpected",
                context: ["patientId": AnySendable(patientId), "underlying": AnySendable("\(error)")],
                safeContext: [:],
                observability: .init(
                    category: .unexpectedSystemState,
                    severity: .error,
                    fingerprint: ["PAT-999"],
                    tags: ["bc": "registry"]
                ),
                http: 500,
                cause: error
            )
        }
    }
}
```

**Regras:**
- `AppError` passa direto.
- Erros que conformam `AppErrorConvertible` → `.asAppError`.
- `PersistenceConflictError.uniqueViolation` mapeado para o erro de negócio específico (ex: `personIdAlreadyExists`).
- Catch-all com `code` numérico alto (`-999`), `severity: .error`, `cause` preservado.

## Template de Query Handler

```swift
public struct GetUnifiedPatientProfileHandler: QueryHandling {
    public typealias Q = GetUnifiedPatientProfileQuery

    private let repository: any PatientRepository
    private let financial: FinancialAnalyticsService
    private let housing: HousingAnalyticsService
    private let education: EducationAnalyticsService

    public init(
        repository: any PatientRepository,
        financial: FinancialAnalyticsService = .init(),
        housing: HousingAnalyticsService = .init(),
        education: EducationAnalyticsService = .init()
    ) {
        self.repository = repository
        self.financial = financial
        self.housing = housing
        self.education = education
    }

    public func handle(_ query: GetUnifiedPatientProfileQuery) async throws -> UnifiedPatientProfile {
        let patient = try await repository.fetchById(query.patientId)
        return UnifiedPatientProfile(
            composicao: .init(
                membros: patient.familyMembers,
                perfilEtario: patient.calculateAgeProfile()
            ),
            analiseEconomica: .init(
                rendaTotal: financial.totalIncome(patient.familyMembers),
                perCapita: financial.perCapita(patient.familyMembers)
            ),
            vulnerabilidades: .init(
                habitacional: housing.densityRisk(patient.address, patient.familyMembers),
                educacional: education.dropoutByAgeRange(patient.familyMembers)
            )
        )
    }
}
```

**Regras:**
- `struct` puro — sem mutação compartilhada, dispensa `actor`.
- Cálculos sempre via Analytics Service do Domain — Query nunca calcula.
- Read model é DTO local (`UnifiedPatientProfile`), não o agregado interno.

## Services / Validators (Ports)

Quando o handler precisa de uma capacidade externa (ex: validar PersonId no
PeopleContext), declare como `protocol` em `Services/`:

```swift
public protocol PersonExistenceValidating: Sendable {
    func exists(personId: PersonId) async throws -> Bool
}
```

A impl real vive em `IO/PeopleContext/PeopleContextClient.swift` — sem
Application importar.

## REPORT.md (output)

```markdown
# Application Layer — <ticket>

## Handlers entregues
- `RegisterPatientCommandHandler` (actor) — `RegisterPatientUseCase`
- `GetUnifiedPatientProfileHandler` (struct) — `QueryHandling`

## Commands / Queries
- `RegisterPatientCommand: ResultCommand` (Result = String)
- `GetUnifiedPatientProfileQuery: Query` (Result = UnifiedPatientProfile)

## Ports dependentes
- `any PatientRepository` (Domain)
- `any EventBus` (shared)
- `any LookupValidating` (Domain/Configuration)
- `any PersonExistenceValidating` (opcional — feature flag)

## Erros mapeados (AppError codes)
- PAT-001 personIdAlreadyExists (409)
- PAT-002 cpfAlreadyExists (409)
- PAT-003 invalidLookupId (422)
- PAT-004 personIdNotFoundInPeopleContext (404)
- PAT-999 unexpected (500)

## Próxima skill
- `swift-io-implementer` para Controller + SQLKit repo + DTO.
```

## Padrão mapError com PersistenceConflictError (ADR-010)

TODO `*MapperError.swift` que serve handler com `repository.save` ou outra
operação de persistência DEVE incluir bloco padronizado:

```swift
extension XCommandHandler {
    public func mapError(_ error: Error, ...) -> XError {
        if let e = error as? XError { return e }

        // ADR-010: PersistenceConflictError universal.
        if let conflict = error as? PersistenceConflictError {
            // Mapping específico de constraints conhecidos:
            if let mapped: XError = conflict.mapUniqueViolation({ constraint in
                switch constraint {
                case "uq_meu_constraint": return .meuErroDeNegocio(...)
                default: return nil
                }
            }) { return mapped }

            // Fallback preserva detail no erro genérico.
            return .persistenceMappingFailure(issues: [String(describing: conflict)])
        }

        // ... outros mappings de domínio
    }
}
```

Para handlers de **lifecycle** (Discharge/Admit/Readmit/Withdraw — assinatura
`-> any Error`), o tratamento é simplesmente:

```swift
if error is PersistenceConflictError { return error }
```

Sem mapping específico — propaga para Controller decidir.

**Helper companheiro:** `mapOptimisticLockFailed { exp, act in ... }` para
ADR-005 (Optimistic Locking).

## Lições Aprendidas (regressões prevenidas)

> Cada item aqui é um padrão que **a skill deve aplicar por default** porque já custou caro no passado. Sempre que um ADR aprovado introduzir um Better Pattern, ele é adicionado aqui com link ao ADR e ao teste de regressão.

| # | Padrão / Regra | ADR | Teste de regressão |
|---|---|---|---|
| 1 | Todo `*MapperError.swift` que serve handler com `repository.save` DEVE incluir bloco `if let conflict = error as? PersistenceConflictError { ... }` — usar `conflict.mapUniqueViolation { constraint in ... }` para constraints conhecidos. Fallback `persistenceMappingFailure(issues:)` preserva detail. Handlers `-> any Error` propagam direto via `if error is PersistenceConflictError { return error }`. | [ADR-010](../../../handbook/architecture/DECISIONS/ADR-010-universal-persistence-conflict-mapping.md) | `Tests/.../Regression/ErrorMapping/UniqueViolationMappingRegressionTests.swift` |
| 2 | Handler **NUNCA** recebe `EventBus` no init nem chama `eventBus.publish(...)`. `repository.save(aggregate)` é a porta única — escreve agregado + `uncommittedEvents` na mesma transação (Outbox Pattern). Sequência canônica final: `parse → validate → fetch → domain → persist`. Fakes `InMemory*Repository` espelham invariante via `publishedEvents` populado pelo save. | [ADR-014](../../../handbook/architecture/DECISIONS/ADR-014-outbox-events-via-repository.md) | `Tests/.../Regression/EventPublication/OutboxEventBusDeadCodeRegressionTests.swift` |
| 3 | `AppError.context`/`safeContext` são `[String: AnySendable]` e `AnySendable` é **enum fechado** (`.string/.int/.double/.bool/.array/.object/.null`), NUNCA `@unchecked Sendable` armazenando `Any`. Sendable verdadeiro — strict concurrency Swift 6.3 verifica recursivamente. Construtor `AnySendable($0)` aceitável (back-compat com `context.mapValues`); migração futura para construir cases explicitamente é melhoria opcional. NUNCA reintroduzir `@unchecked Sendable` em DTO/Error de fronteira — promessa que `Any` interno não pode cumprir. | [ADR-018](../../../handbook/architecture/DECISIONS/ADR-018-no-unchecked-sendable-on-boundary.md) | `Tests/.../Regression/Concurrency/SendableJSONTests.swift` |
| 4 | Em handler que mapeia `[String] → [Enum]` proveniente do request, **NUNCA** usar `compactMap` (silencia typo do cliente — `["RG","TYPO","CPF"]` vira `["RG","CPF"]` sem 422). Use **`try map`** lançando case de erro tipado `case invalid<Field>(String)` mapeado para HTTP 422 com `invalidValue` no contexto. Padrão: `let docs = try raw.map { v in guard let parsed = Enum(rawValue: v) else { throw .invalid<Field>(v) }; return parsed }`. Erros de parsing equivalentes em Persistence usam `PersistenceDataIntegrityError.invalidEnumValue`. | [ADR-020](../../../handbook/architecture/DECISIONS/ADR-020-required-documents-1nf-and-try-map.md) | `Tests/.../Regression/DataIntegrity/RequiredDocumentsAtomicityTests.swift` |
| 5 | **Estágio (b) DUAL-WRITE** da decomposição de aggregate (Fase 4): handler executa **escrita primária com optimistic lock** no agregado antigo (`PatientRepository.save`) + **escrita secundária sem lock** no shadow novo (`assessmentRepository.dualWriteUpsert(_:)`). Helper `<NewAggregate>Builder` em `Application/<NewBC>/Shared/` faz composição cross-BC (Domain não compõe outros agregados — só por identidade). Repository do shadow expõe `dualWriteUpsert(_:)` separado do `save(_:)` — UPSERT idempotente via `INSERT ... ON CONFLICT (id) DO UPDATE SET excluded.*`, sem outbox events (eventos saem pelo lock primário). Cast `::jsonb` no bind quando módulos são JSONB (ADR-022). Métodos `dualWriteUpsert` são **deprecados na CONTRACT** (release N+3) quando handlers migram para o novo repo. TestDouble do shadow expõe `dualWriteCalls: [Aggregate]` para asserts; pode ser passado inline `InMemory<X>Repository()` em testes para eliminar boilerplate. NUNCA propagar lock do agregado antigo para o shadow — replicaria contention sem ganho. | [ADR-025](../../../handbook/architecture/DECISIONS/ADR-025-patient-assessment-dual-write.md) | `Tests/.../Regression/DomainInvariants/DualWriteAssessmentTests.swift` |

## ⚠️ REGRA INVIOLÁVEL — Suite verde é responsabilidade de QUEM ESTÁ NO COMANDO

Se durante seu trabalho um teste falhar — **qualquer teste**, em qualquer arquivo, mesmo que não tenha sido tocado pelo seu ticket — você **DEVE** consertar antes de fechar. Falha colateral = sub-ticket prioritário. Nunca deixar para "próximo sprint".

## Antes de fechar

- [ ] Sequência canônica respeitada (parse → validate → domain → persist → publish)
- [ ] Eventos publicados APÓS save
- [ ] `actorId` propagado para agregado e eventos
- [ ] `mapError` cobre `AppError`, `AppErrorConvertible`, `PersistenceConflictError` (ADR-010), default
- [ ] Zero imports de Vapor/SQLKit
- [ ] Zero `try!`
- [ ] Handler é `actor` (write) ou `struct` (read)
- [ ] Doc Markdown nas APIs públicas
- [ ] **Suite inteiro verde** (`make test` exit 0)
