import Foundation
import Testing
import Vapor
@testable import social_care_s

// ticket: T-014 — achado S-C5 (Senior Code Review)
// ADR: ADR-012 — Security headers obrigatórios e body size limit no boot

/// Regressão para o achado **S-C5**: o boot do social-care registrava apenas
/// `AppErrorMiddleware` + `JWTAuthMiddleware`. **Faltavam** headers de
/// defesa-em-profundidade:
///
/// - `Strict-Transport-Security` — força HTTPS em browsers
/// - `X-Content-Type-Options: nosniff` — bloqueia MIME sniffing
/// - `X-Frame-Options: DENY` — bloqueia clickjacking
/// - `Referrer-Policy: no-referrer` — não vaza URL via Referer
/// - `Cache-Control: no-store` em `/api/*` — não cacheia payloads sensíveis
///
/// Adicionalmente: `app.routes.defaultMaxBodySize` ficava no default Vapor
/// (16 KB form, sem limite explícito para JSON), permitindo abuso por
/// payloads grandes — vetor de DoS.
///
/// Este suite garante:
/// 1. **Unit:** `SecurityHeadersMiddleware.apply(to:)` insere os 4 headers
///    universais + `Cache-Control` em rotas `/api/*`.
/// 2. **Estrutural:** `configure.swift` registra o middleware ANTES do
///    `AppErrorMiddleware` e configura `defaultMaxBodySize`.
@Suite("Regression: Security — S-C5 Security headers + body size limit")
struct SecurityHeadersRegressionTests {

    // MARK: - File discovery (lint estrutural)

    private func configurePath(file: StaticString = #filePath) -> URL {
        let thisFile = URL(fileURLWithPath: "\(file)")
        let projectRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return projectRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("social-care-s")
            .appendingPathComponent("IO")
            .appendingPathComponent("HTTP")
            .appendingPathComponent("Bootstrap")
            .appendingPathComponent("configure.swift")
    }

    private func configureSource() -> String {
        (try? String(contentsOf: configurePath(), encoding: .utf8)) ?? ""
    }

    // MARK: - Unit tests

    @Test("S-C5 — middleware insere HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy")
    func test_S_C5_universal_headers_applied() {
        let res = Response(status: .ok)
        SecurityHeadersMiddleware.apply(headers: &res.headers, requestPath: "/health")

        #expect(res.headers.first(name: "Strict-Transport-Security") == "max-age=63072000; includeSubDomains; preload")
        #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
        #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
        #expect(res.headers.first(name: "Referrer-Policy") == "no-referrer")
    }

    @Test("S-C5 — Cache-Control: no-store é adicionado em rotas /api/*")
    func test_S_C5_cache_control_in_api_routes() {
        let res = Response(status: .ok)
        SecurityHeadersMiddleware.apply(headers: &res.headers, requestPath: "/api/v1/patients/abc")
        #expect(res.headers.first(name: "Cache-Control") == "no-store")
    }

    @Test("S-C5 — Cache-Control não é adicionado em /health e /ready (são públicas, cacheáveis)")
    func test_S_C5_no_cache_control_on_health() {
        let resHealth = Response(status: .ok)
        SecurityHeadersMiddleware.apply(headers: &resHealth.headers, requestPath: "/health")
        #expect(resHealth.headers.first(name: "Cache-Control") == nil)

        let resReady = Response(status: .ok)
        SecurityHeadersMiddleware.apply(headers: &resReady.headers, requestPath: "/ready")
        #expect(resReady.headers.first(name: "Cache-Control") == nil)
    }

    // MARK: - Structural tests

    @Test("S-C5 — configure.swift registra SecurityHeadersMiddleware")
    func test_S_C5_configure_registers_middleware() {
        let source = configureSource()
        #expect(source.contains("SecurityHeadersMiddleware"),
                "S-C5: configure.swift NÃO registra SecurityHeadersMiddleware. Headers de defesa em profundidade ausentes.")
    }

    @Test("S-C5 — configure.swift configura defaultMaxBodySize")
    func test_S_C5_configure_sets_body_size_limit() {
        let source = configureSource()
        #expect(source.contains("defaultMaxBodySize"),
                "S-C5: configure.swift NÃO configura app.routes.defaultMaxBodySize. Payloads grandes podem ser usados como vetor DoS.")
    }

    @Test("S-C5 — SecurityHeadersMiddleware é registrado ANTES de AppErrorMiddleware")
    func test_S_C5_security_headers_runs_first() {
        let source = configureSource()
        guard let securityRange = source.range(of: "SecurityHeadersMiddleware"),
              let appErrorRange = source.range(of: "AppErrorMiddleware") else {
            Issue.record("S-C5: não foi possível localizar middlewares para validar ordem")
            return
        }
        #expect(securityRange.lowerBound < appErrorRange.lowerBound,
                "S-C5: SecurityHeadersMiddleware DEVE ser registrado ANTES de AppErrorMiddleware — caso contrário, response de erro não recebe headers.")
    }
}
