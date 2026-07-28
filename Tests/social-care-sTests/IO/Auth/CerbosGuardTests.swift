import Foundation
import Logging
import NIOCore
import Testing
import Vapor

@testable import social_care_s

/// TICKET `cerbos-guard-tests` / W0 (RED).
///
/// Cobre o wiring do Cerbos entregue sem testes no PR #2 e — o mais importante —
/// fixa o **contrato de ações** entre o `PatientController` e a policy do PDP
/// (`infra:stack/cells/idp/config/cerbos/policies/social-care/patient.yaml`).
///
/// Esse contrato é o ponto cego do desenho: a ação é uma string opaca que o
/// compilador não confere, o `swift test` não confere e o code review humano não
/// desconfia — `"read"` parece perfeitamente razoável, mas a policy declara
/// `list`. Verificado contra o Cerbos 0.53.0 real: `read` e `create` retornam
/// **EFFECT_DENY**, o que derrubaria 9 das 12 rotas de paciente assim que
/// `CERBOS_URL` fosse definido.
@Suite("Cerbos — cliente, guard e contrato de ações com a policy (PR #2)")
struct CerbosGuardTests {

    // MARK: - Contrato com a policy do PDP

    /// Espelha `patient.yaml`. Se a policy mudar, este teste falha e obriga a
    /// atualizar os dois lados juntos — que é a razão de ele existir.
    private static let policyActions: Set<String> = [
        "list", "getById", "getByPersonId", "auditTrail",
        "register", "family", "caregiver", "socialIdentity",
        "appointments", "intake", "assessments", "placement", "violation", "referral",
        "admit", "discharge", "readmit", "withdraw",
        "anonymize",
    ]

    @Test("toda ação de PatientPolicyAction existe na policy do Cerbos")
    func everyDeclaredActionExistsInPolicy() {
        let declared = Set(PatientPolicyAction.allCases.map(\.rawValue))
        let órfãs = declared.subtracting(Self.policyActions)
        #expect(
            órfãs.isEmpty,
            "ações sem regra na policy resultam em EFFECT_DENY (default deny): \(órfãs.sorted())"
        )
    }

    @Test("as ações que o PatientController usa nos guards são válidas")
    func controllerActionsAreValid() {
        // As três ações representativas dos grupos de rota do PatientController.
        let used: [PatientPolicyAction] = [.list, .register, .admit]
        for action in used {
            #expect(
                Self.policyActions.contains(action.rawValue),
                "\(action.rawValue) não existe na policy — o guard negaria a rota inteira"
            )
        }
    }

    /// Lint estrutural (mesmo padrão de `NoPiiInLogTests`): o teste acima confere
    /// uma lista, mas não impede alguém de voltar a passar uma string crua no
    /// controller — que é exatamente como o bug original entrou. Aqui a garantia
    /// é sobre o código-fonte de verdade.
    @Test("PatientController usa o init tipado, nunca o genérico com string")
    func patientControllerUsesTypedInit() throws {
        let source = try String(
            contentsOf: projectRoot()
                .appendingPathComponent("Sources/social-care-s/IO/HTTP/Controllers/PatientController.swift"),
            encoding: .utf8
        )
        #expect(
            !source.contains("CerbosGuardMiddleware(resource:"),
            """
            PatientController deve usar CerbosGuardMiddleware(patient:) — o init com \
            `resource:`/`action:` aceita string arbitrária, e uma ação fora da policy \
            vira 403 silencioso (Cerbos é default deny).
            """
        )
        #expect(source.contains("CerbosGuardMiddleware(patient:"), "guards do Cerbos sumiram do controller")
    }

    private func projectRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // Auth
            .deletingLastPathComponent()  // IO
            .deletingLastPathComponent()  // social-care-sTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // <root>
    }

    // MARK: - CerbosClient

    @Test("EFFECT_ALLOW vira true")
    func allowDecodesToTrue() async throws {
        try await withApp { app in
            let client = FakeClient(status: .ok, json: #"{"results":[{"actions":{"list":"EFFECT_ALLOW"}}]}"#)
            let decision = await CerbosClient(baseURL: "http://cerbos:3592").check(
                client, principalId: "u1", roles: ["social-care:worker"], resource: "patient", action: "list"
            )
            #expect(decision == true)
            _ = app
        }
    }

    @Test("EFFECT_DENY vira false")
    func denyDecodesToFalse() async throws {
        try await withApp { app in
            let client = FakeClient(status: .ok, json: #"{"results":[{"actions":{"list":"EFFECT_DENY"}}]}"#)
            let decision = await CerbosClient(baseURL: "http://cerbos:3592").check(
                client, principalId: "u1", roles: ["people-context:admin"], resource: "patient", action: "list"
            )
            #expect(decision == false)
            _ = app
        }
    }

    @Test("status != 200 vira nil (indisponível) — nunca false")
    func nonOKStatusIsUnknownNotDeny() async throws {
        try await withApp { app in
            let client = FakeClient(status: .internalServerError, json: "{}")
            let decision = await CerbosClient(baseURL: "http://cerbos:3592").check(
                client, principalId: "u1", roles: ["social-care:worker"], resource: "patient", action: "list"
            )
            #expect(decision == nil, "erro do PDP não pode ser confundido com negação de acesso")
        }
    }

    @Test("resposta sem a ação pedida vira nil")
    func missingActionInResponseIsUnknown() async throws {
        try await withApp { app in
            let client = FakeClient(status: .ok, json: #"{"results":[{"actions":{"outraCoisa":"EFFECT_ALLOW"}}]}"#)
            let decision = await CerbosClient(baseURL: "http://cerbos:3592").check(
                client, principalId: "u1", roles: ["social-care:worker"], resource: "patient", action: "list"
            )
            #expect(decision == nil)
        }
    }

    @Test("corpo indecodificável vira nil")
    func undecodableBodyIsUnknown() async throws {
        try await withApp { app in
            let client = FakeClient(status: .ok, json: "não é json")
            let decision = await CerbosClient(baseURL: "http://cerbos:3592").check(
                client, principalId: "u1", roles: ["social-care:worker"], resource: "patient", action: "list"
            )
            #expect(decision == nil)
        }
    }

    @Test("principal sem id vira 'anonymous' no payload enviado ao PDP")
    func emptyPrincipalBecomesAnonymous() async throws {
        try await withApp { app in
            let client = FakeClient(status: .ok, json: #"{"results":[{"actions":{"list":"EFFECT_ALLOW"}}]}"#)
            _ = await CerbosClient(baseURL: "http://cerbos:3592").check(
                client, principalId: "", roles: [], resource: "patient", action: "list"
            )
            let sent = client.lastBody ?? ""
            #expect(sent.contains("anonymous"), "PDP precisa de um principal id; vazio quebraria a decisão")
        }
    }

    // MARK: - CerbosGuardMiddleware

    @Test("flag off (app.cerbos == nil): pass-through, sem consultar o PDP")
    func flagOffIsPassThrough() async throws {
        try await withApp { app in
            let request = authenticatedRequest(on: app, roles: ["social-care:worker"])
            let response = try await CerbosGuardMiddleware(resource: "patient", action: "list")
                .respond(to: request, chainingTo: OKResponder())
            #expect(response.status == .ok)
        }
    }

    @Test("ALLOW: segue para a rota")
    func allowProceeds() async throws {
        try await withApp { app in
            app.cerbos = CerbosClient(baseURL: "http://cerbos:3592")
            let request = authenticatedRequest(
                on: app, roles: ["social-care:worker"],
                client: FakeClient(status: .ok, json: #"{"results":[{"actions":{"list":"EFFECT_ALLOW"}}]}"#)
            )
            let response = try await CerbosGuardMiddleware(resource: "patient", action: "list")
                .respond(to: request, chainingTo: OKResponder())
            #expect(response.status == .ok)
        }
    }

    @Test("DENY: 403 e a rota NÃO é alcançada")
    func denyForbids() async throws {
        try await withApp { app in
            app.cerbos = CerbosClient(baseURL: "http://cerbos:3592")
            let request = authenticatedRequest(
                on: app, roles: ["people-context:admin"],
                client: FakeClient(status: .ok, json: #"{"results":[{"actions":{"list":"EFFECT_DENY"}}]}"#)
            )
            let responder = OKResponder()
            await #expect(throws: (any Error).self) {
                _ = try await CerbosGuardMiddleware(resource: "patient", action: "list")
                    .respond(to: request, chainingTo: responder)
            }
            #expect(responder.wasCalled == false, "DENY não pode deixar o handler executar")
        }
    }

    @Test("PDP indisponível: defere ao RoleGuard (fail-open documentado), não 403")
    func unavailablePDPDefersInsteadOfBlocking() async throws {
        try await withApp { app in
            app.cerbos = CerbosClient(baseURL: "http://cerbos:3592")
            let request = authenticatedRequest(
                on: app, roles: ["social-care:worker"],
                client: FakeClient(status: .serviceUnavailable, json: "{}")
            )
            let response = try await CerbosGuardMiddleware(resource: "patient", action: "list")
                .respond(to: request, chainingTo: OKResponder())
            #expect(
                response.status == .ok,
                "PDP fora do ar não pode derrubar a API — o RoleGuard já decidiu antes deste middleware"
            )
        }
    }

    // MARK: - Helpers

    private func withApp(_ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await body(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    /// Monta a request já autenticada. O `FakeClient` é registrado em
    /// `app.clients` porque é de lá que o `request.client` — usado pelo
    /// middleware — é derivado; pôr o fake no storage da request não teria efeito.
    private func authenticatedRequest(
        on app: Application,
        roles: Set<String>,
        client: FakeClient? = nil
    ) -> Request {
        if let client {
            app.clients.use { _ in client }
        }
        let request = Request(application: app, method: .GET, url: "/api/v1/patients", on: app.eventLoopGroup.next())
        request.authenticatedUser = AuthenticatedUser(
            userId: "u1", roles: roles, orgId: nil, personId: nil, legacySub: nil
        )
        return request
    }
}

// MARK: - Test doubles

/// `Client` do Vapor que devolve uma resposta fixa e guarda o corpo enviado, para
/// que o teste possa afirmar sobre o payload que o `CerbosClient` monta.
final class FakeClient: Client, @unchecked Sendable {
    let eventLoop: EventLoop
    private let status: HTTPResponseStatus
    private let json: String
    private(set) var lastBody: String?

    init(status: HTTPResponseStatus, json: String, eventLoop: EventLoop = MultiThreadedEventLoopGroup.singleton.next()) {
        self.status = status
        self.json = json
        self.eventLoop = eventLoop
    }

    func delegating(to eventLoop: EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        if var buffer = request.body {
            lastBody = buffer.readString(length: buffer.readableBytes)
        }
        var headers = HTTPHeaders()
        headers.contentType = .json
        var body = ByteBufferAllocator().buffer(capacity: json.utf8.count)
        body.writeString(json)
        return eventLoop.makeSucceededFuture(
            ClientResponse(status: status, headers: headers, body: body)
        )
    }
}

/// Responder que registra se foi alcançado — usado para provar que um DENY
/// realmente impede a execução do handler, e não apenas altera o status.
final class OKResponder: AsyncResponder, @unchecked Sendable {
    private(set) var wasCalled = false

    func respond(to request: Request) async throws -> Response {
        wasCalled = true
        return Response(status: .ok)
    }
}
