import Vapor

/// Guarda de autorização via Cerbos (PDP), espelhando o `RoleGuardMiddleware`
/// com política versionada e auditável (decision logs).
///
/// Desenho (defense-in-depth): roda EM CONJUNTO com o `RoleGuardMiddleware` no
/// mesmo grupo de rotas — a decisão é a mesma; o Cerbos adiciona trilha de
/// auditoria e uma segunda verificação independente. Não substitui o RoleGuard.
///
/// Feature-flag por `CERBOS_URL`:
///   • não configurado (`app.cerbos == nil`) → pass-through (defere ao RoleGuard);
///   • ALLOW → segue;  DENY → 403;
///   • Cerbos indisponível (nil) → loga e DEFERE ao RoleGuard (fail-open, sem outage).
struct CerbosGuardMiddleware: AsyncMiddleware {
    let resource: String
    let action: String

    init(resource: String, action: String) {
        self.resource = resource
        self.action = action
    }

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let cerbos = request.application.cerbos else {
            return try await next.respond(to: request)  // Cerbos off → RoleGuard decide
        }

        let user = try request.requireAuthenticatedUser()
        let decision = await cerbos.check(
            request.client,
            principalId: user.userId,
            roles: user.roles,
            resource: resource,
            action: action
        )

        switch decision {
        case .some(true):
            return try await next.respond(to: request)
        case .some(false):
            throw Abort(.forbidden, reason: "Insufficient permissions.")
        case .none:
            request.logger.warning(
                "Cerbos indisponível (resource=\(resource) action=\(action)) — deferindo ao RoleGuard"
            )
            return try await next.respond(to: request)
        }
    }
}
