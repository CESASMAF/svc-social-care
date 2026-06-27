import Vapor

/// Identidade autenticada extraida do JWT.
///
/// ADR-023: `userId` E SEMPRE o `sub` claim do JWT (actorId canonico do
/// audit trail). NAO usar `legacySub` como actorId — ele e apenas metadado
/// de correlacao para queries historicas durante a janela de migracao
/// Zitadel → Authentik (ADR-031).
struct AuthenticatedUser: Sendable {
    let userId: String
    let roles: Set<String>

    // Claims ACDG (ADR-031) — preenchidos a partir da property mapping
    // `acdg-roles` do Authentik. Nulos antes da migracao ou quando o
    // token nao carrega esses claims.
    let orgId: String?
    let personId: String?
    let legacySub: String?

    init(
        userId: String,
        roles: Set<String>,
        orgId: String? = nil,
        personId: String? = nil,
        legacySub: String? = nil
    ) {
        self.userId = userId
        self.roles = roles
        self.orgId = orgId
        self.personId = personId
        self.legacySub = legacySub
    }

    /// "superadmin" bypasses all role checks.
    var isSuperAdmin: Bool {
        roles.contains("superadmin")
    }

    func hasRole(_ role: String) -> Bool {
        if isSuperAdmin { return true }
        // Supports composite keys: "social-care:worker" satisfies "worker"
        return roles.contains(role) || roles.contains(where: { $0.hasSuffix(":\(role)") })
    }

    func hasAnyRole(_ required: Set<String>) -> Bool {
        if isSuperAdmin { return true }
        return required.contains(where: { hasRole($0) })
    }
}

private struct AuthenticatedUserKey: StorageKey {
    typealias Value = AuthenticatedUser
}

extension Request {
    var authenticatedUser: AuthenticatedUser? {
        get { storage[AuthenticatedUserKey.self] }
        set { storage[AuthenticatedUserKey.self] = newValue }
    }

    func requireAuthenticatedUser() throws -> AuthenticatedUser {
        guard let user = authenticatedUser else {
            throw Abort(.unauthorized, reason: "Authentication required.")
        }
        return user
    }
}
