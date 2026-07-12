import Vapor

/// Cliente do Cerbos (PDP — Policy Decision Point).
///
/// Externaliza a decisão de RBAC que hoje vive hardcoded no `RoleGuardMiddleware`
/// para políticas versionadas e auditáveis (cells/idp/config/cerbos/policies). O
/// `principal.roles` são os grupos do JWT (`<system>:<role>` + `superadmin`) — as
/// mesmas strings que o `AuthenticatedUser.roles` carrega —, então a decisão do
/// Cerbos ESPELHA o suffix-match/bypass do middleware, agora com decision logs.
struct CerbosClient: Sendable {
    /// Base do Cerbos HTTP, ex.: `http://cerbos:3592`.
    let baseURL: String

    /// Consulta `POST /api/check/resources`. Retorna a decisão (`true`/`false`) ou
    /// `nil` quando o Cerbos está indisponível/responde erro — nesse caso o caller
    /// decide (fail-open p/ o RoleGuard, sem outage).
    func check(
        _ client: any Client,
        principalId: String,
        roles: Set<String>,
        resource: String,
        action: String
    ) async -> Bool? {
        let payload = CheckRequest(
            principal: .init(
                id: principalId.isEmpty ? "anonymous" : principalId,
                roles: roles.sorted()
            ),
            resources: [
                .init(
                    resource: .init(kind: resource, id: "*", policyVersion: "default"),
                    actions: [action]
                )
            ]
        )
        do {
            let response = try await client.post(URI(string: "\(baseURL)/api/check/resources")) { req in
                try req.content.encode(payload, as: .json)
            }
            guard response.status == .ok else { return nil }
            let decoded = try response.content.decode(CheckResponse.self)
            guard let effect = decoded.results.first?.actions[action] else { return nil }
            return effect == "EFFECT_ALLOW"
        } catch {
            return nil
        }
    }
}

// MARK: - DTOs (Cerbos Check Resources API)

private struct CheckRequest: Content {
    struct Principal: Content {
        let id: String
        let roles: [String]
    }
    struct Resource: Content {
        let kind: String
        let id: String
        let policyVersion: String
    }
    struct ResourceEntry: Content {
        let resource: Resource
        let actions: [String]
    }
    let principal: Principal
    let resources: [ResourceEntry]
}

private struct CheckResponse: Content {
    struct Result: Content {
        let actions: [String: String]  // action → "EFFECT_ALLOW" | "EFFECT_DENY"
    }
    let results: [Result]
}

// MARK: - Application storage

extension Application {
    private struct CerbosKey: StorageKey {
        typealias Value = CerbosClient
    }

    /// Cliente Cerbos configurado (via `CERBOS_URL`). `nil` = Cerbos desligado →
    /// o `CerbosGuardMiddleware` vira pass-through (RBAC só via RoleGuard).
    var cerbos: CerbosClient? {
        get { storage[CerbosKey.self] }
        set { storage[CerbosKey.self] = newValue }
    }
}
