import Logging
import Testing
import Vapor

@testable import social_care_s

/// TICKET `anonymous-401-observability` / W0 (RED).
///
/// O fix de ruído de log (PR #3) rebaixou o registro de requisição anônima de
/// `error` para `debug`. Como `debug` é desligado em produção, o efeito líquido
/// foi trocar "ERROR demais" por "evidência nenhuma" — o serviço deixou de ter
/// como responder "estamos sob varredura?".
///
/// OWASP Logging Cheat Sheet lista "Authentication successes and failures" entre
/// os eventos que devem ser registrados, porque falhas de autenticação são
/// indicador precoce de brute-force/credential-stuffing (ASVS 7.1.1) — e, no
/// mesmo documento, alerta que log não pode virar vetor de exaustão de recurso.
///
/// Os dois lados são atendidos por **contagem** + **log por marco** (potências de
/// 2), em vez de uma linha por requisição: o sinal sobrevive em produção e o
/// volume cresce logaritmicamente.
@Suite("Acesso anônimo — observabilidade sem ruído (PR #3 review)", .serialized)
struct AnonymousAccessObservabilityTests {

    // MARK: - Helpers

    private func withApp(_ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        app.oidcValidators = OIDCJWTValidators(allowedIssuers: ["i"], allowedAudiences: ["a"])
        do {
            try await body(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    /// Request sem `Authorization`, com um logger que acumula tudo que for emitido.
    private func anonymousRequest(on app: Application, collector: LogCollector) -> Request {
        Request(
            application: app,
            method: .GET,
            url: "/patients",
            logger: Logger(label: "test") { _ in CollectingLogHandler(collector: collector) },
            on: app.eventLoopGroup.next()
        )
    }

    // MARK: - Comportamento (o que já valia antes)

    @Test("sem Bearer: responde 401")
    func anonymousRequestIsUnauthorized() async throws {
        try await withApp { app in
            let request = anonymousRequest(on: app, collector: LogCollector())
            await #expect(throws: (any Error).self) {
                _ = try await JWTAuthMiddleware().respond(to: request, chainingTo: PassthroughResponder())
            }
        }
    }

    // MARK: - A intenção do PR #3 (o que não estava fixado por teste)

    @Test("sem Bearer: NÃO emite log de nível error — é a razão de existir do fix")
    func anonymousRequestEmitsNoErrorLevelLog() async throws {
        try await withApp { app in
            AnonymousAccessMonitor.shared.reset()
            let collector = LogCollector()
            let request = anonymousRequest(on: app, collector: collector)

            _ = try? await JWTAuthMiddleware().respond(to: request, chainingTo: PassthroughResponder())

            let loud = collector.entries.filter { $0.level >= .error }
            #expect(
                loud.isEmpty,
                "requisição anônima é evento esperado, não erro operacional — emitiu: \(loud.map(\.message))"
            )
        }
    }

    // MARK: - Observabilidade (o que o review pediu)

    @Test("sem Bearer: incrementa o contador de acessos anônimos")
    func anonymousRequestIsCounted() async throws {
        try await withApp { app in
            AnonymousAccessMonitor.shared.reset()
            let request = anonymousRequest(on: app, collector: LogCollector())

            _ = try? await JWTAuthMiddleware().respond(to: request, chainingTo: PassthroughResponder())

            #expect(AnonymousAccessMonitor.shared.count == 1)
        }
    }

    @Test("o registro sai em marcos (1, 2, 4, 8…), não uma linha por requisição")
    func anonymousAccessLogsOnMilestonesOnly() async throws {
        AnonymousAccessMonitor.shared.reset()

        // 1ª, 2ª e 4ª ocorrências são marcos; 3ª, 5ª, 6ª e 7ª não.
        let milestones = (1...8).map { _ in AnonymousAccessMonitor.shared.record().isMilestone }

        #expect(milestones == [true, true, false, true, false, false, false, true])
        #expect(AnonymousAccessMonitor.shared.count == 8)
    }

    @Test("o marco carrega o total acumulado, não apenas o evento isolado")
    func milestoneCarriesRunningTotal() async throws {
        AnonymousAccessMonitor.shared.reset()
        _ = AnonymousAccessMonitor.shared.record()
        _ = AnonymousAccessMonitor.shared.record()
        let third = AnonymousAccessMonitor.shared.record()

        #expect(third.total == 3, "o total precisa acompanhar o registro para o alerta ser acionável")
    }

    @Test("reset zera o contador (isolamento entre execuções)")
    func resetClearsCounter() async throws {
        _ = AnonymousAccessMonitor.shared.record()
        AnonymousAccessMonitor.shared.reset()
        #expect(AnonymousAccessMonitor.shared.count == 0)
    }
}

// MARK: - Test doubles

/// Acumula os registros emitidos por um `Logger` para que o teste possa afirmar
/// sobre o **nível** do que foi logado — não só sobre o status code.
final class LogCollector: @unchecked Sendable {
    struct Entry {
        let level: Logger.Level
        let message: String
    }

    private let lock = NSLock()
    private var _entries: [Entry] = []

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    func append(level: Logger.Level, message: String) {
        lock.lock()
        defer { lock.unlock() }
        _entries.append(Entry(level: level, message: message))
    }
}

/// `LogHandler` mínimo que despeja tudo num `LogCollector`. `logLevel` fica em
/// `.trace` para que nada seja filtrado antes de o teste inspecionar.
struct CollectingLogHandler: LogHandler {
    let collector: LogCollector
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata _: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        collector.append(level: level, message: message.description)
    }
}

/// Responder que devolve 200 — representa "a rota foi alcançada", ou seja, o
/// middleware deixou passar.
struct PassthroughResponder: AsyncResponder {
    func respond(to request: Request) async throws -> Response {
        Response(status: .ok)
    }
}
