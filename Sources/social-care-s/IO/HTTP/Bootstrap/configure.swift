import Foundation
import Vapor
import PostgresKit
import JWT

// MARK: - Secret resolution  (`<KEY>_FILE` → arquivo; senão `<KEY>` → env)
//
// POR QUÊ: secrets (a senha do banco) não devem vir de variável de ambiente — env
// aparece em `docker inspect`, em /proc/<pid>/environ e pode vazar em log. O padrão
// das imagens oficiais (postgres etc.) é o sufixo `_FILE`: o segredo é montado num
// arquivo (Docker secrets / OpenBao → /run/secrets) e o app lê DE LÁ. Antes, o
// compose contornava com um entrypoint-wrapper (`sh -c 'export DB_PASSWORD=$(cat …)'`),
// que (a) reexpunha o valor no env do processo e (b) não funciona em imagens
// distroless (sem shell). Lendo aqui, o wrapper foi removido do compose.
//
// COMO (importante p/ Linux): usa `FileManager.contents(atPath:)` (leitura via
// `Data`) e NÃO `String(contentsOfFile:)`. Este último tem bug conhecido no
// Foundation do Linux — TRAVA (hang) ao ler arquivos "especiais" (FIFO, /proc…).
// Para /run/secrets (arquivo normal) ambos funcionariam, mas a via-`Data` evita a
// armadilha. Ref.: https://forums.swift.org/t/is-this-a-bug-linux-string-contentsoffile-hangs-for-special-files/16910
//
// Mantém o env como FALLBACK (dev / compatibilidade).
private func resolveSecret(_ key: String) -> String? {
    if let path = Environment.get("\(key)_FILE"),
       let data = FileManager.default.contents(atPath: path),
       let value = String(data: data, encoding: .utf8) {
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return Environment.get(key)
}

func configure(_ app: Application) async throws {
    // MARK: - Database

    let isProduction = Environment.get("ENVIRONMENT") == "production"

    if isProduction {
        guard Environment.get("DB_HOST") != nil,
              Environment.get("DB_USER") != nil,
              resolveSecret("DB_PASSWORD") != nil,   // aceita DB_PASSWORD_FILE (preferido) ou DB_PASSWORD
              Environment.get("DB_NAME") != nil else {
            fatalError("Required DB_HOST, DB_USER, DB_PASSWORD(_FILE), DB_NAME environment variables are not set.")
        }
    }

    let postgresConfig = SQLPostgresConfiguration(
        hostname: Environment.get("DB_HOST") ?? "localhost",
        port: Environment.get("DB_PORT").flatMap(Int.init) ?? 5432,
        username: Environment.get("DB_USER") ?? "postgres",
        password: resolveSecret("DB_PASSWORD") ?? "postgres",   // arquivo (_FILE) → env → default
        database: Environment.get("DB_NAME") ?? "social_care",
        tls: isProduction ? .prefer(try .init(configuration: .clientDefault)) : .disable
    )

    let source = PostgresConnectionSource(sqlConfiguration: postgresConfig)
    let pool = EventLoopGroupConnectionPool(source: source, on: app.eventLoopGroup)

    app.lifecycle.use(PoolShutdownHandler(pool: pool))

    let sqlDb = pool.database(logger: app.logger).sql()

    // MARK: - Migrations

    let runner = SQLKitMigrationRunner(db: sqlDb)
    let migrations: [any Migration] = [
        CreateInitialSchema(),
        AddRegistrationFields(),
        CreateLookupTables(),
        AddV2AssessmentFields(),
        AddPerformanceIndexes(),
        NormalizeSchema(),
        CreateAuditTrail(),
        ConvertJsonbToText(),
        CreateLookupRequests(),
        AddCNSAndHomeless(),
        AddUniqueCpfConstraint(),
        AddPatientDischarge(),
        AddWaitlistSupport(),
        // Migrations 2026_05_14_* — ordem por dependência de schema E de dados:
        //  1. PKs primeiro: cria `patient_diagnoses.id` (destrava RegisterPatient)
        //     e a PK composta `family_members(patient_id, person_id)`.
        //  2/3/4 dependem dessa PK composta (FK composta / tipagem de relationship).
        //  5. cria a função `touch_updated_at()` usada pela trigger da 6.
        //  6. CreatePatientAssessmentsTable: trigger usa `touch_updated_at()`;
        //     backfill corrigido (usa colunas normalizadas reais, não as JSONB
        //     `work_and_income`/`educational_status`/`health_status` que
        //     NormalizeSchema 03_08 dropou).
        //  7/8. RestoreJsonbAndTemporalTypes e AuditTrailDistinctId são
        //     independentes das estruturais — aplicadas por último.
        AddPrimaryKeysForFamilyMembersAndDiagnoses(),
        TypeRelationshipAsUUID(),
        FamilyMemberRequiredDocumentsTable(),
        DeclareLookupFKs(),
        AddCreatedUpdatedAtToRootTables(),
        CreatePatientAssessmentsTable(),
        RestoreJsonbAndTemporalTypes(),
        AuditTrailDistinctId(),
    ]
    for attempt in 1...10 {
        do {
            try await runner.run(migrations)
            break
        } catch {
            app.logger.warning("Migration attempt \(attempt)/10 failed: \(error)")
            if attempt == 10 { throw error }
            try await Task.sleep(for: .seconds(min(attempt * 2, 30)))
        }
    }

    // MARK: - Domain Event Registry

    await DomainEventRegistry.shared.bootstrap()

    // MARK: - Outbox Relay + NATS

    let natsUrl = Environment.get("NATS_URL")

    let natsPublisher: NATSEventPublisher? = natsUrl.map {
        NATSEventPublisher(url: $0)
    }
    let relay = SQLKitOutboxRelay(db: sqlDb, natsPublisher: natsPublisher)
    Task { await relay.startContinuousPolling() }

    // MARK: - NATS Subscriber (people-context events)

    if let natsUrl {
        let patientRepo = SQLKitPatientRepository(db: sqlDb)
        let linkPersonId = LinkPersonIdCommandHandler(patientRepository: patientRepo)
        let anonymizePII = AnonymizePatientPIICommandHandler(patientRepository: patientRepo)
        let subscriber = NATSEventSubscriber(url: natsUrl)

        Task {
            await subscriber.subscribe(subject: "people.person.registered") { data in
                do {
                    let event = try JSONDecoder().decode(PersonRegisteredEvent.self, from: data)
                    guard let cpf = event.data.cpf else { return }
                    try await linkPersonId.handle(
                        LinkPersonIdCommand(
                            personId: event.data.personId,
                            cpf: cpf,
                            actorId: event.actorId
                        )
                    )
                } catch {
                    app.logger.error("Failed to process person.registered event: \(error)")
                }
            }

            // Erasure LGPD (ADR-039): ao receber a eliminação do titular no
            // people-context, anonimiza a PII direta do Patient correlato
            // (preserva registro clínico + audit). Idempotente (at-least-once).
            await subscriber.subscribe(subject: "people.person.deleted") { data in
                do {
                    let event = try JSONDecoder().decode(PersonDeletedEvent.self, from: data)
                    try await anonymizePII.handle(
                        AnonymizePatientPIICommand(
                            personId: event.data.personId,
                            actorId: event.actorId
                        )
                    )
                } catch {
                    app.logger.error("Failed to process person.deleted event: \(error)")
                }
            }

            await subscriber.start()
        }
    }

    // MARK: - Service Container

    let personValidator: (any PersonExistenceValidating)? = Environment.get("PEOPLE_API_URL").map {
        PeopleContextPersonValidator(baseURL: $0)
    }
    app.services = ServiceContainer(db: sqlDb, personValidator: personValidator)

    // MARK: - Server

    app.http.server.configuration.hostname = Environment.get("SERVER_HOST") ?? "0.0.0.0"
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080

    // MARK: - JWT OIDC (multi-issuer: Authentik atual + Zitadel legado)
    //
    // ADR-027 + ADR-031: durante Sprint 3-4 da migracao Zitadel → Authentik,
    // o social-care aceita tokens de AMBOS issuers em paralelo. Tokens sao
    // validados contra o JWKS correspondente ao `kid` no header. Apos Sprint 6
    // (cleanup), apenas o JWKS Authentik permanece configurado.
    //
    // Configuracao:
    //   - OIDC_JWKS_URLS (CSV): URLs dos JWKS endpoints (uma por issuer)
    //   - OIDC_ISSUERS (CSV):   issuers permitidos (validador)
    //   - OIDC_AUDIENCES (CSV): audiences permitidas (validador)
    //
    // Backward compat (Sprint 1-2 single-issuer):
    //   - Se OIDC_JWKS_URLS nao setada, usa JWKS_URL (legacy).
    //   - Se OIDC_ISSUERS nao setada, usa ZITADEL_ISSUER (legacy).
    //   - Se OIDC_AUDIENCES nao setada, usa ZITADEL_PROJECT_ID (legacy).

    // Code-review M1 (2026-05-14): hardcoded de producao APENAS em dev.
    // Em producao, ausencia de env e fail-fast — evita foot-gun onde dev
    // local sobe apontando para o IdP de producao.
    let jwksUrlsCsv: String = {
        if let env = Environment.get("OIDC_JWKS_URLS") { return env }
        if let legacy = Environment.get("JWKS_URL") {
            app.logger.warning("JWKS_URL (legacy) usado — migrar para OIDC_JWKS_URLS antes de Sprint 6 cleanup")
            return legacy
        }
        guard !isProduction else { return "" }
        return "https://auth.acdgbrasil.com.br/oauth/v2/keys"
    }()

    let jwksUrls = jwksUrlsCsv
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    guard !jwksUrls.isEmpty else {
        throw Abort(.internalServerError, reason: "OIDC_JWKS_URLS obrigatoria em producao")
    }

    // Code-review M2: carregar JWKS em PARALELO — pior caso reduzido de 180s
    // (sequencial) para ~90s (paralelo) com 2 IdPs ativos durante migracao.
    try await withThrowingTaskGroup(of: (String, String).self) { group in
        for jwksUrl in jwksUrls {
            group.addTask {
                for attempt in 1...10 {
                    do {
                        let jwksResponse = try await app.client.get(URI(string: jwksUrl))
                        guard let jwksData = jwksResponse.body else {
                            throw Abort(.internalServerError, reason: "Empty JWKS response from \(jwksUrl)")
                        }
                        let jwksJSON = String(buffer: jwksData)
                        guard jwksJSON.trimmingCharacters(in: .whitespaces).hasPrefix("{") else {
                            throw Abort(
                                .internalServerError,
                                reason: "JWKS response is not JSON from \(jwksUrl): \(jwksJSON.prefix(100))"
                            )
                        }
                        return (jwksUrl, jwksJSON)
                    } catch {
                        app.logger.warning("JWKS fetch attempt \(attempt)/10 failed for \(jwksUrl): \(error)")
                        if attempt < 10 {
                            try await Task.sleep(for: .seconds(min(attempt * 2, 30)))
                        }
                    }
                }
                throw Abort(.internalServerError, reason: "Failed to load JWKS after 10 attempts from \(jwksUrl)")
            }
        }

        for try await (jwksUrl, jwksJSON) in group {
            try await app.jwt.keys.add(jwksJSON: jwksJSON)
            app.logger.info("JWKS loaded from \(jwksUrl)")
        }
    }

    // Registrar validators OIDC (multi-issuer + multi-audience).
    // M1: hardcoded apenas em dev — em prod, env obrigatoria.
    let issuersCsv: String = {
        if let env = Environment.get("OIDC_ISSUERS") { return env }
        if let legacy = Environment.get("ZITADEL_ISSUER") { return legacy }
        guard !isProduction else { return "" }
        return "https://auth.acdgbrasil.com.br"
    }()
    let audiencesCsv: String = {
        if let env = Environment.get("OIDC_AUDIENCES") { return env }
        if let legacy = Environment.get("ZITADEL_PROJECT_ID") { return legacy }
        guard !isProduction else { return "" }
        return "363110312318140539"
    }()

    guard let validators = OIDCJWTValidators.fromValues(
        issuersCsv: issuersCsv,
        audiencesCsv: audiencesCsv
    ) else {
        throw Abort(
            .internalServerError,
            reason: "OIDC_ISSUERS / OIDC_AUDIENCES vazios — IdP misconfig (fail-fast no boot)."
        )
    }
    app.oidcValidators = validators
    // AppSec CRITICAL-1: registrar globalmente para que `OIDCJWTPayload.verify(using:)`
    // valide iss/aud/exp/nbf em TODO codepath — defense-in-depth.
    OIDCJWTPayloadBootstrap.shared.set(validators)
    app.logger.info(
        "OIDC validators: \(validators.allowedIssuers.count) issuers, \(validators.allowedAudiences.count) audiences"
    )

    // MARK: - Token Introspection (fallback for service accounts without role claims)

    if let introspectClientId = Environment.get("ZITADEL_INTROSPECT_CLIENT_ID"),
       let introspectClientSecret = Environment.get("ZITADEL_INTROSPECT_CLIENT_SECRET") {
        let issuer = Environment.get("ZITADEL_ISSUER") ?? "https://auth.acdgbrasil.com.br"
        app.tokenIntrospector = ZitadelTokenIntrospector(
            introspectURL: "\(issuer)/oauth/v2/introspect",
            clientId: introspectClientId,
            clientSecret: introspectClientSecret
        )

        if let allowedIds = Environment.get("ALLOWED_SERVICE_ACCOUNTS") {
            app.allowedServiceAccounts = Set(allowedIds.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }

    // MARK: - Middleware

    // Limita o corpo das requisições — payloads grandes são vetor de DoS
    // (S-C5 / ADR-012). Default Vapor é 16 KB form, sem teto explícito p/ JSON.
    app.routes.defaultMaxBodySize = "512kb"

    // Headers de defesa em profundidade (HSTS, nosniff, X-Frame-Options,
    // Referrer-Policy, Cache-Control). Registrado primeiro → fica mais externo,
    // então as responses de erro (tratadas adiante) também recebem os headers.
    app.middleware.use(SecurityHeadersMiddleware())
    app.middleware.use(AppErrorMiddleware())
    app.middleware.use(JWTAuthMiddleware())

    // MARK: - Content Configuration

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    // MARK: - Graceful Shutdown

    app.lifecycle.use(GracefulShutdownHandler(logger: app.logger))

    // MARK: - Routes

    try app.register(collection: HealthController())
    try app.register(collection: PatientController())
    try app.register(collection: AssessmentController())
    try app.register(collection: ProtectionController())
    try app.register(collection: CareController())
    try app.register(collection: LookupController())
}

// MARK: - Pool Lifecycle

/// @unchecked Sendable justification: Vapor LifecycleHandler requires Sendable.
/// EventLoopGroupConnectionPool is thread-safe by design (internally synchronized).
struct PoolShutdownHandler: LifecycleHandler, @unchecked Sendable {
    let pool: EventLoopGroupConnectionPool<PostgresConnectionSource>

    func shutdown(_ app: Application) {
        pool.shutdown()
    }
}

// MARK: - Graceful Shutdown

/// @unchecked Sendable justification: Vapor LifecycleHandler requires Sendable.
/// Logger is Sendable; struct has no mutable state.
struct GracefulShutdownHandler: LifecycleHandler, @unchecked Sendable {
    let logger: Logger

    func willBoot(_ app: Application) throws {
        logger.info("social-care service starting up")
    }

    func shutdown(_ app: Application) {
        logger.info("social-care service shutting down — draining connections")
    }
}
