import Vapor

protocol TokenIntrospecting: Sendable {
    func introspect(token: String, client: Client) async throws -> Set<String>
}

/// Introspecção RFC 7662 — fallback para service accounts sem claim de role.
///
/// Renomeado de `ZitadelTokenIntrospector` (2026-08-06): o endpoint é padrão
/// RFC, não específico de fornecedor, e o nome antigo indicava um IdP que este
/// serviço não usa há duas migrações (Zitadel → Authentik → Ory).
struct OIDCTokenIntrospector: TokenIntrospecting {
    let introspectURL: String
    let clientId: String
    let clientSecret: String

    func introspect(token: String, client: Client) async throws -> Set<String> {
        let credentials = Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()

        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Basic \(credentials)")
        headers.add(name: .contentType, value: "application/x-www-form-urlencoded")

        let response = try await client.post(URI(string: introspectURL), headers: headers) { req in
            try req.content.encode(["token": token], as: .urlEncodedForm)
        }

        guard let body = response.body else {
            throw Abort(.internalServerError, reason: "Empty introspection response.")
        }

        let result = try JSONDecoder().decode(IntrospectionResponse.self, from: body)

        guard result.active else {
            throw Abort(.unauthorized, reason: "Token is not active.")
        }

        guard let projectRoles = result.projectRoles else { return [] }
        return Set(projectRoles.keys)
    }
}

private struct IntrospectionResponse: Decodable {
    let active: Bool
    let projectRoles: [String: [String: String]]?

    enum CodingKeys: String, CodingKey {
        case active
        case projectRoles = "urn:zitadel:iam:org:project:roles"
    }
}

struct TokenIntrospectorKey: StorageKey {
    typealias Value = any TokenIntrospecting
}

struct AllowedServiceAccountsKey: StorageKey {
    typealias Value = Set<String>
}

extension Application {
    var tokenIntrospector: (any TokenIntrospecting)? {
        get { storage[TokenIntrospectorKey.self] }
        set { storage[TokenIntrospectorKey.self] = newValue }
    }

    var allowedServiceAccounts: Set<String> {
        get { storage[AllowedServiceAccountsKey.self] ?? [] }
        set { storage[AllowedServiceAccountsKey.self] = newValue }
    }
}
