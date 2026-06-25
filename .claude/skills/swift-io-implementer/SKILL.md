---
name: swift-io-implementer
description: >
  Implementa a camada `Sources/social-care-s/IO/` — Controllers Vapor, DTOs,
  SQLKit repositories + migrations, EventBus (Outbox), Middleware (JWT, RBAC,
  AppError), Extensions, Bootstrap (ServiceContainer), HTTP clients outbound
  (PeopleContext com Bearer forwarding). Ativa quando o usuário menciona:
  Controller, Vapor, route, DTO, RequestDTO, ResponseDTO, StandardResponse,
  middleware, JWTAuthMiddleware, RoleGuardMiddleware, AppErrorMiddleware,
  SQLKit, migration, Repository implementation, Outbox, Bearer forwarding,
  ServiceContainer, configure.swift.
---

# Swift IO Implementer — social-care

Especialista em adapters de IO. Escreve em `Sources/social-care-s/IO/` (e
`shared/Ports/` quando criando contratos). **Nunca toca** Domain (modelos)
nem Application (handlers).

## Escopo

```
IO/HTTP/
  Bootstrap/
    ServiceContainer.swift         — composition root
    configure.swift                — setup de DB, JWT, middlewares, rotas
    OIDCJWTPayloadBootstrap.swift  — registra validators (defense-in-depth)
  Controllers/
    PatientController.swift, AssessmentController.swift, CareController.swift,
    HealthController.swift, LookupController.swift, ProtectionController.swift
  DTOs/
    RequestDTOs/
    ResponseDTOs/
  Auth/
    OIDCJWTPayload.swift, AuthenticatedUser.swift
  Middleware/
    JWTAuthMiddleware.swift, RoleGuardMiddleware.swift, AppErrorMiddleware.swift
  Validation/
    CrossValidator.swift, MetadataValidator.swift
  Extensions/
    Request+ActorId.swift (extractActorId via JWT.sub)

IO/Persistence/SQLKit/
  Migrations/                      — forward + rollback
  Mappers/                         — DTO ↔ Patient/Aggregate
  Repositories/                    — SQLKitPatientRepository etc
  Outbox/                          — OutboxEventBus, OutboxRelay

IO/EventBus/
  OutboxEventBus.swift
  ExternalEvents/                  — payload schemas externos

IO/PeopleContext/
  PeopleContextClient.swift        — HTTP outbound com Bearer forwarding
```

## Princípios não negociáveis

1. **Controller fino** — parse DTO → resolve handler → response. Zero lógica.
2. **`AppErrorMiddleware`** captura erros e renderiza JSON padronizado.
3. **Multi-issuer OIDC** — `OIDC_JWKS_URLS`, `OIDC_ISSUERS`, `OIDC_AUDIENCES` em CSV.
4. **Defense-in-depth no JWT** — `OIDCJWTPayloadBootstrap` registra validators globalmente.
5. **Audit trail via `JWT.sub`** — `req.extractActorId()`, nunca header custom.
6. **`db.transaction { }` em writes multi-tabela (G1)**.
7. **Outbox na mesma TX do agregado** (Transactional Outbox).
8. **Migration sempre com rollback** (até G17 fechar runner control).
9. **Adapter HTTP outbound encaminha `Authorization: Bearer <jwt>`** — `actorId` deriva do JWT validado.
10. **DTOs separados de Commands** — DTO é forma de fronteira; Command é forma de domínio.

## Template de Controller

```swift
import Vapor

public struct PatientController: RouteCollection {
    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        let patients = routes
            .grouped("patients")
            .grouped(JWTAuthMiddleware())
            .grouped(RoleGuardMiddleware(["social_worker", "admin", "superadmin"]))

        patients.post(use: register)
        patients.get(":id", use: getProfile)
        patients.post(":id", "social-identity", use: updateSocialIdentity)
    }

    @Sendable
    private func register(req: Request) async throws -> Response {
        let dto = try req.content.decode(RegisterPatientRequest.self)
        try RegisterPatientRequest.validate(content: req)

        let actorId = try req.extractActorId()
        let command = try dto.toCommand(actorId: actorId)
        let handler = await req.services.registerPatientHandler

        let patientId = try await handler.handle(command)

        let body = StandardResponse(data: ["patient_id": patientId])
        return try await body.encodeResponse(status: .created, for: req)
    }

    @Sendable
    private func getProfile(req: Request) async throws -> Response {
        guard let raw = req.parameters.get("id"),
              let uuid = UUID(uuidString: raw) else {
            throw AppError.badRequest(code: "PAT-400", message: "invalid patient id")
        }

        let query = GetUnifiedPatientProfileQuery(patientId: PatientId(uuid))
        let handler = req.services.getUnifiedProfileHandler
        let profile = try await handler.handle(query)

        let body = StandardResponse(data: profile)
        return try await body.encodeResponse(status: .ok, for: req)
    }
}
```

**Regras:**
- `RouteCollection` + `boot(routes:)`.
- Middleware chain: `JWTAuthMiddleware()` → `RoleGuardMiddleware([roles])` → handler.
- Handler resolvido via `req.services.<name>` — propriedade computed no ServiceContainer.
- DTO → Command via `dto.toCommand(actorId:)`.
- Response sempre `StandardResponse<T>`.
- Sem `try!`. Erro vira `AppError` via `AppErrorMiddleware`.

## Template de DTO

```swift
import Vapor

public struct RegisterPatientRequest: Content, Validatable {
    public let personId: String
    public let prRelationshipId: String
    public let initialDiagnoses: [DiagnosisDraftDTO]
    public let personalData: PersonalDataDTO?
    public let civilDocuments: CivilDocumentsDTO?
    public let address: AddressDTO?
    public let socialIdentity: SocialIdentityDTO?

    public static func validations(_ validations: inout Validations) {
        validations.add("personId", as: String.self, is: !.empty)
        validations.add("prRelationshipId", as: String.self, is: !.empty)
        validations.add("initialDiagnoses", as: [DiagnosisDraftDTO].self, is: !.empty)
    }

    public func toCommand(actorId: String) throws -> RegisterPatientCommand {
        RegisterPatientCommand(
            personId: personId,
            initialDiagnoses: initialDiagnoses.map { $0.toDraft() },
            personalData: personalData?.toDraft(),
            civilDocuments: civilDocuments?.toDraft(),
            address: address?.toDraft(),
            socialIdentity: socialIdentity?.toDraft(),
            prRelationshipId: prRelationshipId,
            actorId: actorId
        )
    }
}

public struct DiagnosisDraftDTO: Content {
    public let icdCode: String
    public let date: Date
    public let description: String

    func toDraft() -> RegisterPatientCommand.DiagnosisDraft {
        .init(icdCode: icdCode, date: date, description: description)
    }
}
```

**Regras:**
- DTO conforma `Content` (Vapor) — auto Codable.
- `Validatable` para validação superficial pré-handler (não-vazio, formato básico).
- Nested DTOs para drafts opcionais.
- `toDraft()` / `toCommand(actorId:)` extension converte para tipos de Application.
- Validação semântica fica no handler (lookup, existência) — DTO só valida estrutura.

## Template de StandardResponse

```swift
public struct StandardResponse<T: Content>: Content {
    public let data: T
    public let meta: Meta

    public init(data: T, meta: Meta = .init()) {
        self.data = data
        self.meta = meta
    }

    public struct Meta: Content {
        public let timestamp: Date

        public init(timestamp: Date = .now) {
            self.timestamp = timestamp
        }
    }
}
```

## Template de SQLKit Repository

```swift
import Foundation
import SQLKit

public final class SQLKitPatientRepository: PatientRepository {
    private let db: any SQLDatabase
    private let mapper: PatientRowMapper

    public init(db: any SQLDatabase, mapper: PatientRowMapper = .init()) {
        self.db = db
        self.mapper = mapper
    }

    public func save(_ patient: Patient) async throws {
        try await db.transaction { tx in
            // 1. upsert patient
            try await tx.insert(into: "patients")
                .columns("id", "person_id", "pr_relationship_id", "version", "updated_at")
                .values(SQLBind(patient.id.description),
                        SQLBind(patient.personId.description),
                        SQLBind(patient.prRelationshipId.description),
                        SQLBind(patient.version),
                        SQLBind(Date.now))
                .onConflict(with: ["id"]) { update in
                    update.set("version", to: SQLBind(patient.version))
                          .set("updated_at", to: SQLBind(Date.now))
                }
                .run()

            // 2. sync family members
            try await syncFamily(patient.id, members: patient.familyMembers, tx: tx)

            // 3. insert outbox events (mesma TX — Transactional Outbox)
            for event in patient.uncommittedEvents {
                try await insertOutbox(event, tx: tx)
            }
        }
    }

    public func exists(byPersonId id: PersonId) async throws -> Bool {
        let row = try await db.select()
            .column(SQLLiteral.numeric("1"))
            .from("patients")
            .where("person_id", .equal, SQLBind(id.description))
            .limit(1)
            .first()
        return row != nil
    }

    // ...
}
```

**Regras:**
- `final class` (precisa carregar `SQLDatabase` ref; também ajuda devirtualization).
- Conforma `Sendable` via `final class` + props `let` + `SQLDatabase` thread-safe.
- `try await db.transaction { tx in ... }` em qualquer write multi-tabela.
- Outbox insertions na **mesma TX** do agregado.
- Mapper separado (`PatientRowMapper`) — converte rows ↔ agregado.
- `onConflict` em vez de checar existência primeiro (idempotente).
- `PersistenceConflictError` (em `shared/`) lançado em conflitos detectados (`uniqueViolation`).

## Template de Migration

```swift
import SQLKit
import PostgresKit

public struct CreatePatientsTable: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        let sql = database as! any SQLDatabase
        try await sql.create(table: "patients")
            .column("id", type: .text, .primaryKey)
            .column("person_id", type: .text, .notNull, .unique)
            .column("pr_relationship_id", type: .text, .notNull)
            .column("version", type: .int, .notNull)
            .column("created_at", type: .timestamp, .notNull)
            .column("updated_at", type: .timestamp, .notNull)
            .run()

        try await sql.raw(
            "CREATE INDEX idx_patients_person_id ON patients(person_id)"
        ).run()
    }

    public func revert(on database: any Database) async throws {
        let sql = database as! any SQLDatabase
        try await sql.drop(table: "patients").run()
    }
}
```

**Regras:**
- `AsyncMigration` (Vapor 4 + Fluent ou SQLKit raw).
- **Sempre `revert`** implementado.
- Numeração: `M<NN>_<descricao>.swift` (M07, M08, ...).
- Naming snake_case nas tabelas/colunas.

## Template de JWTAuthMiddleware + Audit Trail

```swift
public struct JWTAuthMiddleware: AsyncMiddleware {

    public func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let bearer = req.headers.bearerAuthorization else {
            throw AppError.unauthorized(code: "AUTH-001", message: "missing bearer token")
        }

        // ADR-027: multi-issuer — tenta cada JWKS configurado
        let payload: OIDCJWTPayload = try await req.jwt.verify(
            bearer.token, as: OIDCJWTPayload.self
        )
        // verify(using:) revalida iss/aud/exp/nbf via Bootstrap (defense-in-depth)

        let user = AuthenticatedUser(
            userId: payload.sub.value,         // ← actorId vem daqui
            roles: payload.resolvedRoles,      // precedência: roles → groups → urn:zitadel:...
            issuer: payload.iss.value
        )
        req.auth.login(user)
        return try await next.respond(to: req)
    }
}
```

```swift
public extension Request {
    func extractActorId() throws -> String {
        try requireAuthenticatedUser().userId
    }

    func requireAuthenticatedUser() throws -> AuthenticatedUser {
        guard let user = auth.get(AuthenticatedUser.self) else {
            throw AppError.unauthorized(code: "AUTH-002", message: "not authenticated")
        }
        return user
    }
}
```

## Template de AppErrorMiddleware

```swift
public struct AppErrorMiddleware: AsyncMiddleware {

    public func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: req)
        } catch {
            return try await render(error, for: req)
        }
    }

    private func render(_ error: any Error, for req: Request) async throws -> Response {
        let appError: AppError
        switch error {
        case let e as AppError:
            appError = e
        case let e as any AppErrorConvertible:
            appError = e.asAppError
        default:
            appError = AppError.unexpected(error)
        }

        req.logger.error("\(appError.code) \(appError.message)", metadata: [
            "bc": .string(appError.bc),
            "module": .string(appError.module),
            "id": .string(appError.id),
        ])

        let status = HTTPResponseStatus(statusCode: appError.http ?? 500)
        let body = ["error": appError.toPublicJSON()]
        return try await body.encodeResponse(status: status, for: req)
    }
}
```

## Template de PeopleContextClient (Bearer Forwarding)

> **Referência:** ADR-023 do handbook do frontend
> (`frontend/handbook/architecture/DECISIONS/ADR-023-bff-adapter-bearer-forwarding.md`).
> Backend extrai `actorId` do JWT validado — adapter outbound DEVE encaminhar
> `Authorization: Bearer <jwt>`.

```swift
public final class PeopleContextClient: PersonExistenceValidating {
    private let client: any Client
    private let baseURL: String

    public init(client: any Client, baseURL: String) {
        self.client = client
        self.baseURL = baseURL
    }

    public func exists(personId: PersonId, bearer: String) async throws -> Bool {
        let response = try await client.get(
            URI(string: "\(baseURL)/persons/\(personId.description)/exists")
        ) { req in
            req.headers.bearerAuthorization = .init(token: bearer)
        }
        return response.status == .ok
    }
}
```

Como obter o bearer no chamador: o handler que recebe `req: Request` extrai
via `req.headers.bearerAuthorization?.token` e passa adiante; ou pelo
`ServiceContainer` factory pattern por request.

## Template de ServiceContainer

```swift
public final class ServiceContainer: @unchecked Sendable {
    public let registerPatientHandler: any RegisterPatientUseCase
    public let getUnifiedProfileHandler: GetUnifiedPatientProfileHandler
    // ...

    public init(app: Application) async throws {
        let sql = app.db as! any SQLDatabase
        let mapper = PatientRowMapper()
        let patientRepo = SQLKitPatientRepository(db: sql, mapper: mapper)
        let lookupRepo = SQLKitLookupRepository(db: sql)
        let outbox = OutboxEventBus(db: sql)

        self.registerPatientHandler = RegisterPatientCommandHandler(
            repository: patientRepo,
            eventBus: outbox,
            lookupValidator: lookupRepo
        )
        self.getUnifiedProfileHandler = GetUnifiedPatientProfileHandler(
            repository: patientRepo
        )
    }
}

public extension Request {
    var services: ServiceContainer {
        application.storage[ServiceContainerKey.self]!
    }
}

private struct ServiceContainerKey: StorageKey {
    typealias Value = ServiceContainer
}
```

**Regras:**
- Single composition root — toda wiring aqui.
- Disposto em `app.storage` no boot.
- Acessível via `req.services` ou `app.services`.
- `@unchecked Sendable` justificável: container só lê props imutáveis depois do boot.

## REPORT.md (output)

```markdown
# IO Layer — <ticket>

## Controllers/Routes
- POST /patients (register)
- GET /patients/:id (unified profile)
- POST /patients/:id/social-identity

## DTOs
- RegisterPatientRequest (Content + Validatable)
- UnifiedPatientProfileResponse

## SQLKit
- SQLKitPatientRepository.save (TX wrap, outbox)
- SQLKitPatientRepository.exists(byPersonId:) / exists(byCpf:)
- Migration M08_create_patients_table (forward + rollback)

## Middleware
- JWTAuthMiddleware (multi-issuer)
- RoleGuardMiddleware(["social_worker", "admin"])

## ServiceContainer
- registerPatientHandler wired
- getUnifiedProfileHandler wired

## Próxima skill
- `swift-test-writer` para suites HTTP + repo integration.
```

## Padrão Optimistic Lock em Repository (ADR-005)

Todo repository SQLKit que faça update de aggregate root **DEVE** usar
optimistic locking via coluna `version`. Sem isso, dois pods do social-care
podem ler `version=N`, ambos escrever `version=N+1`, e a segunda escrita
sobrescreve a primeira em silêncio (lost update — achados S-C3 + DB-2).

```swift
func save(_ patient: Patient) async throws {
    do {
        try await db.transaction { tx in
            let data = try PatientDatabaseMapper.toDatabase(patient)
            let patientId = data.patient.id

            // 1. SELECT FOR UPDATE para adquirir row-level lock e ler version atual
            let currentVersion: Int? = try await tx.raw("""
                SELECT version FROM patients WHERE id = \(bind: patientId) FOR UPDATE
            """).first()?.decode(column: "version", as: Int.self)

            if let dbVersion = currentVersion {
                // UPDATE path — agregado já existe
                let expected = patient.version - 1
                guard dbVersion == expected else {
                    throw PersistenceConflictError.optimisticLockFailed(
                        expectedVersion: expected,
                        actualVersion: dbVersion
                    )
                }
                try await tx.update("patients").set(model: data.patient)
                    .where("id", .equal, patientId).run()
            } else {
                // CREATE path — primeira save
                try await tx.insert(into: "patients").model(data.patient).run()
            }

            // 2. Child tables + outbox (segue dentro da mesma tx) ...
        }
    } catch let error as PSQLError where error.code == .server {
        // mapping de uniqueViolation segue igual
    }
}
```

**Espelhar na fake:** o `InMemory*Repository` correspondente deve aplicar a
mesma checagem. Sem isso, unit tests passam contra a fake mas o bug volta
em produção. ADR-005 cobre fake + SQLKit como par solidário.

**Não usar UPSERT para UPDATE path.** `INSERT … ON CONFLICT (id) DO UPDATE
SET excluded.*` sobrescreve sem checar version — exatamente o que ADR-005
proíbe. UPSERT só vale como atalho de CREATE quando a operação é idempotente
(raro em aggregate root).

## Padrão Migration de PK com pré-flight (ADR-006)

Toda migration que adiciona PK a tabela existente:

1. **Pré-flight check**: detectar duplicatas pré-existentes ANTES de ALTER. Se houver, `throw MigrationError.duplicatesFound(...)` com mensagem útil e SELECT pronto para diagnóstico.
2. **NUNCA `DELETE` automático** — viola CRU/No Delete + destrói histórico sem aprovação humana.
3. **Adicionar PK + UNIQUE natural se aplicável** (a UNIQUE preserva invariantes de domínio que a PK surrogate não cobre).
4. **`revert` simétrico** — `DROP CONSTRAINT IF EXISTS` + `DROP COLUMN IF EXISTS`, na ordem inversa do prepare.

```swift
struct AddPrimaryKeysForFamilyMembersAndDiagnoses: Migration {
    func prepare(on db: any SQLDatabase) async throws {
        // 1. Pré-flight: aborta com mensagem útil se houver duplicatas
        if let dups = try await firstDuplicateInFamilyMembers(on: db) {
            throw MigrationError.duplicatesFound(table: "family_members", example: dups, hint: "…")
        }
        // 2. PK
        try await db.raw("ALTER TABLE family_members ADD CONSTRAINT … PRIMARY KEY (…)").run()
        // 3. PK surrogate + UNIQUE natural
        try await db.raw("ALTER TABLE patient_diagnoses ADD COLUMN id UUID NOT NULL DEFAULT gen_random_uuid()").run()
        try await db.raw("ALTER TABLE patient_diagnoses ADD CONSTRAINT … PRIMARY KEY (id)").run()
        try await db.raw("ALTER TABLE patient_diagnoses ADD CONSTRAINT uq_… UNIQUE (…)").run()
    }
    func revert(on db: any SQLDatabase) async throws {
        // Ordem inversa, IF EXISTS para idempotência
    }
}
```

**Migration nova que CRIA tabela** sempre declara PK no `db.create(table:)`. Sem PK, a tabela não é uma relação — apenas um multi-set permissivo (Ramakrishnan & Gehrke).

## Lições Aprendidas (regressões prevenidas)

> Cada item aqui é um padrão que **a skill deve aplicar por default** porque já custou caro no passado. Sempre que um ADR aprovado introduzir um Better Pattern, ele é adicionado aqui com link ao ADR e ao teste de regressão.

| # | Padrão / Regra | ADR | Teste de regressão |
|---|---|---|---|
| 1 | Repository de aggregate root usa **optimistic lock** via `SELECT version FOR UPDATE` + path explícito CREATE vs UPDATE. `INSERT … ON CONFLICT DO UPDATE SET excluded.*` é proibido para UPDATE (UPSERT só para CREATE). Fake `InMemory*Repository` espelha o invariante. | [ADR-005](../../../handbook/architecture/DECISIONS/ADR-005-optimistic-locking-via-version.md) | `Tests/.../Regression/Concurrency/OptimisticLockRegressionTests.swift` |
| 2 | Toda tabela tem **PK declarada** (natural ou surrogate). Migrations que adicionam PK a tabela existente fazem **pré-flight check de duplicatas** e abortam com mensagem útil — NUNCA `DELETE` automático. Forward + `revert` simétrico obrigatório. | [ADR-006](../../../handbook/architecture/DECISIONS/ADR-006-primary-keys-for-aggregate-tables.md) | `Tests/.../Regression/DataIntegrity/AggregateTableHasPKRegressionTests.swift` |
| 3 | Coluna que carrega identidade semântica (UUID, código de lookup, FK lógica) declara **tipo nativo + FK**, nunca `TEXT`. Migração que tipifica usa **expand-contract** (add nova → backfill → drop antiga) com pré-flight contra valores malformados. FK para lookup usa `ON DELETE RESTRICT`. | [ADR-007](../../../handbook/architecture/DECISIONS/ADR-007-typed-foreign-keys-for-semantic-identity.md) | `Tests/.../Regression/DataIntegrity/RelationshipIdIsTypedRegressionTests.swift` |
| 4 | Toda coluna `*_id` que aponta para lookup table (`dominio_*`) tem **FK declarada + `ON DELETE RESTRICT`**. Validação na Application (`LookupValidating`) coexiste para HTTP 422 friendly, mas o banco é a fonte de enforcement universal — ETL/replicação/fix manual passam pelo banco também. Migration que adiciona FKs em massa faz pré-flight de órfãos por FK. | [ADR-008](../../../handbook/architecture/DECISIONS/ADR-008-foreign-keys-for-lookup-tables.md) | `Tests/.../Regression/DataIntegrity/LookupFKsRegressionTests.swift` |
| 5 | TODO adapter outbound (HTTP client) retorna **tri-state explícito** (`.ok / .notFound / .unknown(reason:)`), NUNCA `Bool`. Falha de upstream NUNCA é fail-open. Bearer JWT é encaminhado quando o método aceita `bearer: String?` (ADR-023). Log de erro usa `String(reflecting: type(of:))` — nunca payload bruto (ADR-019). URL via `URLComponents`, nunca interpolação direta. | [ADR-011](../../../handbook/architecture/DECISIONS/ADR-011-people-context-fail-secure-and-bearer-forwarding.md) | `Tests/.../Regression/Security/PeopleContextNoFailOpenRegressionTests.swift` |
| 6 | `configure.swift` registra `SecurityHeadersMiddleware` como **PRIMEIRO** middleware (antes do AppError) + configura `app.routes.defaultMaxBodySize`. Headers universais: HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy. `Cache-Control: no-store` apenas em rotas autenticadas (`/api/*`). Middleware tem `static apply(headers:requestPath:)` para teste unitário direto. | [ADR-012](../../../handbook/architecture/DECISIONS/ADR-012-security-headers-and-body-size-limit.md) | `Tests/.../Regression/Security/SecurityHeadersRegressionTests.swift` |
| 7 | Qualquer relay polling em PostgreSQL (Outbox, queue-as-table) usa **`SELECT … FOR UPDATE SKIP LOCKED` dentro de transação** que cobre todo o ciclo (SELECT → processar → UPDATE). Publicação em broker propaga `messageId` único (header `Nats-Msg-Id` no NATS, equivalente em outros) para dedup nativo. Defense in depth: lock no DB + dedup no broker. | [ADR-013](../../../handbook/architecture/DECISIONS/ADR-013-outbox-for-update-skip-locked.md) | `Tests/.../Regression/Concurrency/OutboxConcurrentPollingRegressionTests.swift` |
| 8 | Tabela de auditoria/log NUNCA reusa PK de outra tabela como própria PK. **`audit_trail.id`** é `UUID DEFAULT gen_random_uuid()` próprio; rastreio para origem é coluna separada (**`outbox_message_id UUID NOT NULL`**, sem FK formal porque outbox é purgável). Construtor do model exige o campo de rastreio — compilador é a primeira defesa contra "esqueci de amarrar a origem". Re-processamento adiciona N rows distintos em vez de travar batch com PK conflict. | [ADR-015](../../../handbook/architecture/DECISIONS/ADR-015-audit-trail-distinct-id-from-outbox.md) | `Tests/.../Regression/EventPublication/AuditTrailDistinctIdRegressionTests.swift` |
| 9 | Cliente de protocolo de mensageria (NATS/RabbitMQ/Kafka/MQTT) **NUNCA** é write-only. Protocolos são bidirecionais por design — keepalive (PING/PONG), errors do servidor (-ERR), control frames (INFO/+OK). No mínimo: **instalar `ChannelInboundHandler`** (ou equivalente) que parseie TODOS os frames do spec, mesmo que só para descartar/logar. Half-duplex = conexão morre silenciosamente após primeiro PING ignorado. Ideal: usar cliente oficial; se inviável (lib experimental, escopo restrito), reimplementar parcialmente com regression test estrutural que enforça presença de handler bidirecional + tratamento dos frames críticos. | [ADR-016](../../../handbook/architecture/DECISIONS/ADR-016-nats-publisher-bidirectional-handler.md) | `Tests/.../Regression/EventPublication/NATSPublisherSurvivesPingTests.swift` |
| 10 | Em camada IO/HTTP/EventBus/Persistence, **NUNCA** interpolar `\(error)` direto em log — nem em metadata `["error": "\(error)"]`, nem em mensagem `"... \(error)"`. `DecodingError`/`PSQLError`/`URLError` incluem o payload no `description` por design — vaza PII LGPD. Use **`LogSanitizer.metadata(for: error)`** (porta única em `shared/Error/LogSanitizer.swift`). Sanitizer retorna `errorType` (qualified type via `String(reflecting:)`) + `errorDescription` (localizedDescription truncada e com control chars neutralizados contra log injection). Camadas Bootstrap ficam isentas (sem PII fluindo no startup); domínios com `AppError` usam `safeContext` próprio (ADR-010). Lint estrutural em `NoPiiInLogTests` enforça via grep. | [ADR-017](../../../handbook/architecture/DECISIONS/ADR-017-log-sanitizer-no-pii-in-logs.md) | `Tests/.../Regression/Security/NoPiiInLogTests.swift` |
| 11 | Qualquer DTO/Error/Event payload em fronteira (HTTP DTOs, AppError, audit response) que precise ser Sendable + carregue valor heterogêneo DEVE ser modelado como **enum fechado com cases tipados** (`.string(String)`, `.int(Int)`, `.array([Self])`, `.object([String: Self])`, `.null`), NUNCA `@unchecked Sendable` armazenando `Any`. `@unchecked` é promessa que `Any` interno não pode cumprir — pode armazenar classe mutável (NSMutableArray do JSONSerialization). Strict concurrency Swift 6.3 não pega data race em type-erased storage. Construtor `init(_ any: Any)` aceitável apenas como porta de back-compat com call sites legacy — storage interno fica fechado. Lint estrutural em `SendableJSONTests` enforça em `shared/` e `IO/HTTP/DTOs/`. | [ADR-018](../../../handbook/architecture/DECISIONS/ADR-018-no-unchecked-sendable-on-boundary.md) | `Tests/.../Regression/Concurrency/SendableJSONTests.swift` |
| 12 | Coleção "set of enum" em entidade do domínio (ex.: `family_members.required_documents`, `housing.facilities`) NUNCA é coluna TEXT/JSON inline (viola 1NF — não indexável, sem CHECK, sem FK). Schema 1NF: **tabela filha `<entity>_<collection>(... PK composta com chave do parent + code, FK ON DELETE CASCADE, CHECK no enum code)`**. Mapper achata na escrita (`flatMap`); agrupa por chave do parent na leitura (`[UUID: [Enum]]`). Mapper na leitura **re-valida** com `Enum(rawValue:)` por defesa em profundidade — code não reconhecido lança `PersistenceDataIntegrityError.invalidEnumValue` (NUNCA silencia). CHECK no schema é a defesa final contra SQL direto. Para volumes baixos (dev/staging), drop da coluna antiga pode ir na mesma migration do create+backfill desde que `revert()` simétrico (exceção documentada do expand-contract de ADR-019). | [ADR-020](../../../handbook/architecture/DECISIONS/ADR-020-required-documents-1nf-and-try-map.md) | `Tests/.../Regression/DataIntegrity/RequiredDocumentsAtomicityTests.swift` |
| 13 | Mapper Domain → Database **NUNCA** usa `id: UUID()` inline em model com PK surrogate. ID surrogate é **derivado deterministicamente** da chave natural do domínio via `DeterministicUUID.from("<table>\|<chave-natural>")` (SHA256, prefixo do nome da tabela contra colisão entre tabelas). Repository de aggregate root usa **diff-based upsert** (`INSERT ... ON CONFLICT (id) DO UPDATE SET excluded.*` via `.onConflict(with:["id"]) { ... .set(excludedValueOf: col) }`) em vez de delete-and-insert — preserva identidade física, audit trail honesto, triggers `ON UPDATE` viáveis, FKs externas viáveis. Pré-condição inquebrável: IDs determinísticos no mapper. Sem isso, ON CONFLICT nunca dispara e tabela cresce sem limite (tests fixam invariante via `mapper.toDatabase` chamado 2× produzir mesmos IDs). Tabelas com PK composta natural (associativas puras como `family_members`) podem manter delete-and-insert semanticamente equivalente até triggers ON UPDATE serem introduzidos. | [ADR-021](../../../handbook/architecture/DECISIONS/ADR-021-deterministic-uuid-and-diff-based-upsert.md) | `Tests/.../Regression/DomainInvariants/ChildIdentityPreservedTests.swift` |
| 14 | **Padrão Temporal & Payload no schema:** instante operacional → `TIMESTAMPTZ` (NUNCA `TIMESTAMP` sem TZ — ambíguo entre regiões); data conceitual sem hora (`birth_date`, `rg_issue_date`, `diagnosis.date`) → `DATE` (TIMESTAMP planta `00:00:00` espúrio que vira "21:00 do dia anterior" em BRT); payload estruturado → `JSONB` (NUNCA `TEXT` — perde operadores `->`/`->>`/`@>`/`?` indexáveis). Bind de String → JSONB exige **cast `::jsonb` explícito** em SQL raw (`tx.raw("INSERT ... VALUES (\(bind: payload)::jsonb)")`); `.model()` falha porque PostgresKit envia TEXT. Encoder JSON é porta única `JSONCodec.encoder` / `JSONCodec.decoder` em `shared/JSON/` com `.iso8601` em ambos — encoder default usa Double (`.deferredToDate`) que confunde audit trail. Promoção `TIMESTAMP → TIMESTAMPTZ` usa `AT TIME ZONE 'UTC'` (assume valores antigos em UTC). Migration in-place adquire ACCESS EXCLUSIVE lock — para volume produção, considerar shadow column ou `pg_repack`. | [ADR-022](../../../handbook/architecture/DECISIONS/ADR-022-jsonb-and-temporal-types.md) | `Tests/.../Regression/DataIntegrity/JsonbAndTemporalTypesTests.swift` |
| 15 | Toda tabela **raiz** (aggregate root + entidades-filhas com PK surrogate/identidade própria) tem **`created_at` + `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`** gerenciados pelo banco. `updated_at` é mantido por **trigger BEFORE UPDATE EXECUTE FUNCTION touch_updated_at()** (função PL/pgSQL única, declarada via `CREATE OR REPLACE`). Models Swift NÃO declaram essas colunas — banco gerencia; `.model()` mandaria NULL e contraria `NOT NULL DEFAULT`. Filhas associativas regeneradas a cada save do parent (`member_incomes`, `family_member_required_documents`) NÃO precisam (sem semântica útil); operacionais com timestamps próprios (`outbox_messages.occurred_at`, `audit_trail.recorded_at`) também não. `audit_trail` e `updated_at` são **complementares**: audit cobre evento de domínio (operações via app); `updated_at` cobre TODA escrita (incluindo SQL direto, ETL, restore). Trigger por tabela (não global) — evita ativação em tabelas sem coluna. | [ADR-023](../../../handbook/architecture/DECISIONS/ADR-023-created-updated-at-on-root-tables.md) | `Tests/.../Regression/DataIntegrity/TemporalAuditTests.swift` |
| 16 | Decomposição de god aggregate (Fase 4) usa **expand-contract** com migration por estágio. EXPAND cria nova tabela `<sub_aggregate>` com PK natural (`patient_id PRIMARY KEY REFERENCES patients(id) ON DELETE CASCADE`), version, módulos como JSONB, `created_at`/`updated_at` + trigger reusando função `touch_updated_at()` (ADR-023). Backfill idempotente: `INSERT INTO <table> (parent_id) SELECT p.id FROM <parent> p WHERE algum_módulo IS NOT NULL ON CONFLICT (parent_id) DO NOTHING` — popular apenas o índice (módulos JSONB ficam NULL); preenchimento real via DUAL-WRITE (próximo PR). SQLKit repository implementa save com optimistic lock + outbox em mesma TX (ADR-005/014/022) — INSERT do payload com cast `::jsonb`. Backward compat 100% durante EXPAND (nada antigo é removido). | [ADR-024](../../../handbook/architecture/DECISIONS/ADR-024-patient-assessment-aggregate-expand.md) | `Tests/.../Regression/DomainInvariants/PatientAssessmentDecompositionTests.swift` |

## ⚠️ REGRA INVIOLÁVEL — Suite verde é responsabilidade de QUEM ESTÁ NO COMANDO

Se durante seu trabalho um teste falhar — **qualquer teste**, em qualquer arquivo, mesmo que não tenha sido tocado pelo seu ticket — você **DEVE** consertar antes de fechar. Falha colateral = sub-ticket prioritário (T-NNN.fix). Nunca deixar para "próximo sprint".

## Antes de fechar

- [ ] Controller fino (sem lógica de negócio)
- [ ] Middleware chain: JWT → RoleGuard → handler
- [ ] `extractActorId()` usado para `actorId`
- [ ] `db.transaction` em writes multi-tabela
- [ ] Outbox events na mesma TX do agregado
- [ ] Repository de aggregate root tem optimistic lock (ADR-005)
- [ ] Fake espelha invariante do repository real
- [ ] Migration com `revert` simétrico (ADR-006)
- [ ] Migration que cria tabela declara **PK** (natural ou surrogate)
- [ ] Migration que adiciona PK em tabela existente tem **pré-flight de duplicatas** (sem DELETE automático)
- [ ] Adapter outbound encaminha `Authorization: Bearer <jwt>`
- [ ] `StandardResponse<T>` na resposta
- [ ] `AppErrorMiddleware` registrado no `configure.swift`
- [ ] Zero `try!`, zero `print`
- [ ] `swift build -c release` zero warnings
- [ ] **Suite inteiro verde** (`make test` exit 0)
