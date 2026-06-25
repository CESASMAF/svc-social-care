import Vapor

/// Insere headers de defesa-em-profundidade em toda resposta HTTP (ADR-012).
///
/// Headers aplicados:
///
/// - **`Strict-Transport-Security`** (HSTS): força HTTPS em browsers
///   compatíveis. `max-age=63072000` (2 anos) + `includeSubDomains` + `preload`
///   alinha com listagem HSTS Preload do Chrome/Firefox/Edge.
/// - **`X-Content-Type-Options: nosniff`**: bloqueia MIME sniffing — browser
///   não tenta "adivinhar" tipo de conteúdo.
/// - **`X-Frame-Options: DENY`**: bloqueia clickjacking — página não pode
///   ser renderizada em `<iframe>` mesmo same-origin.
/// - **`Referrer-Policy: no-referrer`**: não envia URL do social-care em
///   navegação para outras origens (evita vazamento de paths sensíveis).
/// - **`Cache-Control: no-store`** em rotas `/api/*`: payloads autenticados
///   (dados de paciente) não devem ser cacheados por proxies/browser.
///   Rotas públicas (`/health`, `/ready`) **não** recebem esse header — são
///   cacheáveis por monitoramento.
///
/// **Ordem no middleware chain:** registrar como PRIMEIRO middleware no
/// `configure.swift`. Caso contrário, response de erro do `AppErrorMiddleware`
/// não recebe headers — vazamento parcial em error path.
///
/// Implementação `apply(headers:requestPath:)` exposta como `static` para
/// permitir teste unitário direto sem subir Application.
public struct SecurityHeadersMiddleware: AsyncMiddleware {

    public init() {}

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        Self.apply(headers: &response.headers, requestPath: request.url.path)
        return response
    }

    /// Aplica os headers de segurança no `HTTPHeaders` informado.
    ///
    /// Exposto como `static` para teste unitário direto.
    ///
    /// - Parameters:
    ///   - headers: Headers da response (mutado in-place).
    ///   - requestPath: Path da request original — determina se `Cache-Control: no-store` se aplica.
    public static func apply(headers: inout HTTPHeaders, requestPath: String) {
        headers.replaceOrAdd(name: "Strict-Transport-Security",
                             value: "max-age=63072000; includeSubDomains; preload")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")

        // Rotas autenticadas (/api/*) não devem ser cacheadas.
        // Rotas públicas (/health, /ready) ficam cacheáveis para monitoramento.
        if requestPath.hasPrefix("/api/") {
            headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        }
    }
}
