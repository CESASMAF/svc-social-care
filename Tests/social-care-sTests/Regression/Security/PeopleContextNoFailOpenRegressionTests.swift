import Foundation
import Testing
@testable import social_care_s

// ticket: T-011 — achado S-C1 (Senior Code Review)
// ADR: ADR-011 — PeopleContext fail-secure tri-state com Bearer forwarding

/// Regressão para o achado **S-C1** (mais grave da Senior Review): o
/// `PeopleContextPersonValidator` original **fail-open** — qualquer erro
/// (4xx ≠ 404, 5xx, timeout, DNS) retornava `true`. Atacante que derrubar o
/// people-context (ou só esperar uma janela de instabilidade) consegue
/// registrar pacientes com `personId` arbitrário — quebra a invariante
/// "Patient existe ⇒ Person existe" sem deixar rastro de segurança.
///
/// Adicionalmente: o validator ignorava o token JWT do request — viola o
/// ADR-023 (BFFs e gateways DEVEM encaminhar `Authorization: Bearer <jwt>`
/// em outbound). Endpoint do people-context que aplique JWT auth respondia
/// 401, e o fail-open silenciava.
///
/// Este suite garante:
/// 1. **Tri-state contratual:** porta retorna `.exists/.notFound/.unknown(reason:)`.
/// 2. **Handler bloqueia em `.unknown`:** lança `personValidationUnavailable` (HTTP 503).
/// 3. **Validator recebe bearer:** Command carrega bearer, handler propaga.
@Suite("Regression: Security — S-C1 PeopleContext fail-secure + Bearer forwarding")
struct PeopleContextNoFailOpenRegressionTests {

    // MARK: - Command fixture local (pós-ADR-011: Command carrega bearer)

    private static func makeCommand(bearer: String? = nil) -> RegisterPatientCommand {
        RegisterPatientCommand(
            personId: "770e8400-e29b-41d4-a716-446655440099",
            initialDiagnoses: [
                .init(icdCode: "B201", date: Date(), description: "Diagnóstico teste S-C1")
            ],
            prRelationshipId: UUID().uuidString,
            actorId: "actor-test-s-c1",
            bearer: bearer
        )
    }

    // MARK: - Validator fakes

    /// Fake que sempre retorna `.unknown` para simular upstream caído.
    struct UnreachableValidator: PersonExistenceValidating {
        func validate(personId: PersonId, bearer: String?) async -> PersonExistence {
            .unknown(reason: "test_unreachable")
        }
    }

    /// Fake que sempre retorna `.notFound` — personId não cadastrado upstream.
    struct NotFoundValidator: PersonExistenceValidating {
        func validate(personId: PersonId, bearer: String?) async -> PersonExistence {
            .notFound
        }
    }

    /// Fake que captura o bearer recebido para validar forwarding.
    actor CapturingBearerValidator: PersonExistenceValidating {
        private(set) var capturedBearer: String?
        func validate(personId: PersonId, bearer: String?) async -> PersonExistence {
            capturedBearer = bearer
            return .exists
        }
    }

    // MARK: - Tests

    @Test("S-C1 — porta PersonExistenceValidating retorna tri-state, não Bool")
    func test_S_C1_port_is_tri_state() {
        // Test estrutural: a porta declara enum PersonExistence (não Bool).
        let exists: PersonExistence = .exists
        let notFound: PersonExistence = .notFound
        let unknown: PersonExistence = .unknown(reason: "x")

        if case .exists = exists, case .notFound = notFound, case .unknown = unknown {
            #expect(Bool(true))
        } else {
            Issue.record("Pattern matching on PersonExistence variants failed")
        }
    }

    @Test("S-C1 — handler RegisterPatient bloqueia com upstream unknown (não passa silencioso)")
    func test_S_C1_handler_blocks_on_unknown_upstream() async throws {
        let repo = InMemoryPatientRepository()
        let lookup = AllowAllLookupValidator()
        let validator = UnreachableValidator()

        let handler = RegisterPatientCommandHandler(
            repository: repo,
            lookupValidator: lookup,
            personValidator: validator
        )

        let command = Self.makeCommand()

        // Pré-fix (fail-open): retornava .exists → handler prosseguia → save com personId não-verificado.
        // Pós-fix (tri-state): retorna .unknown → handler bloqueia com personValidationUnavailable.
        await #expect(throws: RegisterPatientError.self) {
            _ = try await handler.handle(command)
        }

        // Confirma fail-secure: nada persistido, nenhum evento publicado.
        let stored = await repo.allPatients
        #expect(stored.isEmpty, "S-C1: nenhum paciente deve ser registrado quando upstream está unknown.")
        // ADR-014: events ficam no repository.publishedEvents, não em bus.
        let events = await repo.publishedEvents
        #expect(events.isEmpty, "S-C1: nenhum evento publicado quando upstream está unknown.")
    }

    @Test("S-C1 — handler RegisterPatient bloqueia com personId notFound (comportamento mantido)")
    func test_S_C1_handler_blocks_on_not_found() async throws {
        let repo = InMemoryPatientRepository()
        let lookup = AllowAllLookupValidator()
        let validator = NotFoundValidator()

        let handler = RegisterPatientCommandHandler(
            repository: repo,
            lookupValidator: lookup,
            personValidator: validator
        )

        let command = Self.makeCommand()

        await #expect(throws: RegisterPatientError.self) {
            _ = try await handler.handle(command)
        }
    }

    @Test("S-C1 / ADR-023 — bearer do Command é encaminhado ao validator")
    func test_S_C1_bearer_is_forwarded_to_validator() async throws {
        let repo = InMemoryPatientRepository()
        let lookup = AllowAllLookupValidator()
        let validator = CapturingBearerValidator()

        let handler = RegisterPatientCommandHandler(
            repository: repo,
            lookupValidator: lookup,
            personValidator: validator
        )

        let command = Self.makeCommand(bearer: "test.jwt.token.xyz")
        _ = try await handler.handle(command)

        let captured = await validator.capturedBearer
        #expect(captured == "test.jwt.token.xyz",
                "S-C1 / ADR-023: bearer do Command DEVE ser encaminhado ao validator outbound.")
    }
}
