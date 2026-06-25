import Foundation
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Validates PersonId existence by calling the people-context REST API.
///
/// `GET /api/v1/people/:personId`
/// - **200** → `.exists`
/// - **404** → `.notFound`
/// - **outros** (4xx ≠ 404, 5xx, timeout, DNS) → `.unknown(reason:)`
///
/// ADR-011: implementação **fail-secure** (oposto do fail-open original).
/// Qualquer erro de upstream vira `.unknown` — handler decide bloquear
/// (HTTP 503). Pré-ADR-011 retornava `true` e permitia registro silencioso.
///
/// ADR-023: encaminha `Authorization: Bearer <jwt>` quando `bearer` é
/// informado. Necessário porque o people-context aplica JWT auth nos
/// endpoints de leitura.
///
/// URL construída via `URLComponents` (escape seguro de `personId`),
/// não via interpolação direta.
public struct PeopleContextPersonValidator: PersonExistenceValidating, Sendable {
    private let baseURL: String
    private let logger: Logger

    public init(baseURL: String) {
        self.baseURL = baseURL
        self.logger = Logger(label: "people-context-validator")
    }

    public func validate(personId: PersonId, bearer: String?) async -> PersonExistence {
        guard var components = URLComponents(string: baseURL) else {
            logger.error("PeopleContextPersonValidator: baseURL inválida — \(baseURL)")
            return .unknown(reason: "invalid_base_url")
        }
        // Append path safely (encoding automático).
        components.path += "/api/v1/people/\(personId.description)"
        guard let url = components.url else {
            logger.error("PeopleContextPersonValidator: falha ao montar URL para \(personId.description)")
            return .unknown(reason: "url_build_failed")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        // ADR-023: Bearer forwarding.
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("PeopleContextPersonValidator: resposta sem HTTPURLResponse para \(personId.description)")
                return .unknown(reason: "non_http_response")
            }

            switch httpResponse.statusCode {
            case 200:
                return .exists
            case 404:
                return .notFound
            case 401:
                // Bearer rejeitado pelo upstream — sinal claro que precisa de
                // re-autenticação. Não é fail-open.
                logger.error("PeopleContextPersonValidator: upstream rejeitou bearer (401) — registro bloqueado")
                return .unknown(reason: "upstream_unauthorized")
            default:
                logger.error("PeopleContextPersonValidator: upstream retornou \(httpResponse.statusCode) — registro bloqueado (fail-secure)")
                return .unknown(reason: "http_\(httpResponse.statusCode)")
            }
        } catch {
            // ADR-019: NÃO logar erro bruto (pode conter PII em headers/payload).
            // Log apenas tipo do erro.
            logger.error("PeopleContextPersonValidator: transporte falhou tipo=\(String(reflecting: type(of: error))) — registro bloqueado (fail-secure)")
            return .unknown(reason: "transport_\(String(reflecting: type(of: error)))")
        }
    }
}
