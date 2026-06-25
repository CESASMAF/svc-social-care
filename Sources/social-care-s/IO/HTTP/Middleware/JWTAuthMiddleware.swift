import Vapor
import JWT

struct JWTAuthMiddleware: AsyncMiddleware {
    private static let publicPaths: Set<String> = ["/health", "/ready"]
    private static let unauthorizedReason = "Unauthorized."

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if Self.publicPaths.contains(request.url.path) {
            return try await next.respond(to: request)
        }

        // AppSec HIGH-B: mensagens 401 sao genericas — detalhes vao para o
        // logger (interno) mas o response body NUNCA expoe oracle de runtime
        // (config missing, service account specifics, etc.).
        guard request.application.oidcValidators != nil else {
            request.logger.error("OIDC validators not configured — bug de bootstrap, falhando fechado")
            throw Abort(.unauthorized, reason: Self.unauthorizedReason)
        }

        let payload: OIDCJWTPayload
        do {
            // Vapor JWT executa verify(using:) que ja valida iss/aud/exp/nbf
            // via OIDCJWTPayloadBootstrap (AppSec CRITICAL-1 — defense-in-depth).
            payload = try await request.jwt.verify(as: OIDCJWTPayload.self)
        } catch {
            request.logger.warning("JWT verify falhou", metadata: LogSanitizer.metadata(for: error))
            throw Abort(.unauthorized, reason: Self.unauthorizedReason)
        }

        var roles = payload.roleNames

        if roles.isEmpty, let introspector = request.application.tokenIntrospector {
            let allowedAccounts = request.application.allowedServiceAccounts
            guard allowedAccounts.contains(payload.sub.value) else {
                request.logger.warning("Service account \(payload.sub.value) nao autorizado")
                throw Abort(.forbidden, reason: "Forbidden.")
            }
            let token = request.bearerToken ?? ""
            let introspectedRoles = try await introspector.introspect(token: token, client: request.client)
            // AppSec HIGH-C: introspect fallback NAO pode escalar privilegios.
            // Service account introspection nunca deve carregar `superadmin`
            // ou claim sensivel — rejeitar se vier.
            let denied: Set<String> = ["superadmin"]
            let escalated = introspectedRoles.intersection(denied)
            guard escalated.isEmpty else {
                request.logger.error(
                    "Privilege escalation tentativa: SA \(payload.sub.value) recebeu roles \(escalated) via introspection"
                )
                throw Abort(.forbidden, reason: "Forbidden.")
            }
            roles = introspectedRoles
        }

        // ADR-023: userId E o sub do JWT (actorId canonico do audit trail).
        // ADR-031: claims adicionais (org_id, person_id, legacy_sub) sao
        // metadado — nao alteram identidade canonica.
        request.authenticatedUser = AuthenticatedUser(
            userId: payload.sub.value,
            roles: roles,
            orgId: payload.orgId,
            personId: payload.personId,
            legacySub: payload.legacySub
        )

        return try await next.respond(to: request)
    }
}

private extension Request {
    var bearerToken: String? {
        headers.bearerAuthorization?.token
    }
}
