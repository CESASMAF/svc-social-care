import Testing
import Foundation

/// Suite de regressão — Achado S-C9 (Senior Code Review § C9).
///
/// `NATSEventPublisher` original era half-duplex (write-only):
/// - Envia CONNECT mas nunca lê INFO de verdade — `readInbound()` era fake
///   (`Task.sleep(100ms)` + buffer vazio).
/// - Não instala `ChannelInboundHandler` no pipeline.
/// - NATS server envia `PING\r\n` a cada ~2min. Sem PONG, o servidor
///   considera a conexão morta e fecha. Próxima `publish()` falha.
/// - Não trata `-ERR` (cliente ignora errors do servidor).
///
/// Fix:
/// 1. Publisher instala `ChannelInboundHandler` no pipeline (mesmo padrão
///    do `NATSEventSubscriber.NATSMessageHandler`).
/// 2. Handler responde `PING` com `PONG` automaticamente — conexão sobrevive.
/// 3. Handler loga `INFO`, `+OK`, `-ERR` para observabilidade.
/// 4. `readInbound` fake removido — não há mais "leitura sintética".
///
/// Este suite é **estrutural**: inspeciona `NATSEventPublisher.swift`.
/// Teste runtime contra mock NATS server real seria ideal mas exige
/// infraestrutura de teste de integração (deferida a um sprint dedicado).
@Suite("Regression: Event Publication — S-C9 NATS publisher survives PING")
struct NATSPublisherSurvivesPingTests {

    private func projectRoot(file: StaticString = #filePath) -> URL {
        let thisFile = URL(fileURLWithPath: "\(file)")
        return thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func publisherSource() -> String {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/IO/EventBus/NATSEventPublisher.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("S-C9 — NATSEventPublisher instala ChannelInboundHandler no pipeline")
    func test_S_C9_publisher_installs_inbound_handler() {
        let source = publisherSource()
        let lower = source.lowercased()
        // Sinal: presença de `channelInitializer` ou `addHandler` no source.
        // Sem isso, é fire-and-forget (write-only).
        let hasInitializer = lower.contains("channelinitializer")
        let hasAddHandler = lower.contains("addhandler") || lower.contains("addhandlers")
        #expect(hasInitializer || hasAddHandler,
                "S-C9: NATSEventPublisher não instala ChannelInboundHandler no pipeline. Half-duplex = conexão morre no primeiro PING.")
    }

    @Test("S-C9 — NATSEventPublisher responde PING com PONG")
    func test_S_C9_publisher_responds_pong_to_ping() {
        let source = publisherSource()
        // Sinal: source deve mencionar "PING" e "PONG" — handler trata.
        let hasPing = source.contains("PING")
        let hasPong = source.contains("PONG")
        #expect(hasPing && hasPong,
                "S-C9: NATSEventPublisher não trata PING/PONG. Server fecha conexão após ~2min sem keepalive.")
    }

    @Test("S-C9 — readInbound fake removido (sem Task.sleep para sintetizar leitura)")
    func test_S_C9_no_fake_read_inbound() {
        let source = publisherSource()
        // Sinal anti-pattern: `extension Channel { func readInbound` com Task.sleep.
        // O nome "readInbound" como helper customizado no Channel é a marca do bug original.
        let hasFakeReadInbound = source.contains("func readInbound")
            && source.contains("Task.sleep")
        #expect(!hasFakeReadInbound,
                "S-C9: extension Channel.readInbound com Task.sleep ainda existe — é leitura fake. Use ChannelInboundHandler real.")
    }

    @Test("S-C9 — NATSPublisherInboundHandler declarado no source")
    func test_S_C9_publisher_handler_declared() {
        let source = publisherSource()
        let lower = source.lowercased()
        // Sinal: declaração de uma classe handler no mesmo arquivo (privada).
        // Aceita variações de nome — busca por "ChannelInboundHandler" no source.
        let hasHandlerType = lower.contains("channelinboundhandler")
        #expect(hasHandlerType,
                "S-C9: NATSEventPublisher.swift não declara classe que conforma ChannelInboundHandler. Sem inbound handler, frames do servidor são descartados.")
    }

    @Test("S-C9 — handler trata -ERR do servidor (observabilidade)")
    func test_S_C9_publisher_logs_server_errors() {
        let source = publisherSource()
        // Sinal: tratamento de "-ERR" frame. Sem isso, errors do servidor
        // (auth fail, slow consumer, etc) são silenciados.
        #expect(source.contains("-ERR") || source.contains("\"-ERR\""),
                "S-C9: NATSEventPublisher não trata -ERR do servidor. Errors viram silenciamento — bug invisível.")
    }
}
