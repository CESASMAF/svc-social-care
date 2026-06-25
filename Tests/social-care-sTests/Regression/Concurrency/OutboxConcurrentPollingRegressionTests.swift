import Foundation
import Testing
@testable import social_care_s

// ticket: T-012 — achado S-C2 (Senior Code Review)
// ADR: ADR-013 — Outbox at-least-once com dedup via Nats-Msg-Id; concorrência via FOR UPDATE SKIP LOCKED

/// Regressão para o achado **S-C2**: o `SQLKitOutboxRelay.pollAndDistribute`
/// lia com um `SELECT * FROM outbox_messages WHERE processed_at IS NULL LIMIT 50`
/// **sem lock pessimista**, publicava no NATS, e *depois* fazia UPDATE para
/// marcar como processado. Dois pods rodando em paralelo pegavam o mesmo
/// lote — duplicação garantida. Pior: o gap entre `nats.publish` e o
/// `UPDATE processed_at` permitia re-publicação se a app crashar no meio.
///
/// Citação (Newman, *Building Microservices*, p. 500):
///
/// > *"Even if we store which events have been processed, with some forms
/// > of asynchronous message delivery there may be small windows in which
/// > two workers can see the same message. By processing the events in an
/// > idempotent manner, we ensure this won't cause us any issues."*
///
/// O at-least-once é aceitável **se** (a) consumer for idempotente e
/// (b) producer emitir `idempotencyKey` deduplicável pelo broker. Hoje
/// nenhum dos dois — fix duplo:
///
/// 1. `SELECT … FOR UPDATE SKIP LOCKED` dentro de transação curta:
///    dois pollers paralelos serializam — cada um pega lote disjunto.
/// 2. `messageId` propagado no publish via header `Nats-Msg-Id`
///    (JetStream deduplica por 2min default).
///
/// Este suite é **estrutural** — inspeciona o source do relay e da porta
/// NATS para garantir os padrões. Test runtime com Postgres real fica para
/// T-033 (schema snapshot + integration suite).
@Suite("Regression: Concurrency — S-C2 Outbox dedup via SELECT FOR UPDATE + Nats-Msg-Id")
struct OutboxConcurrentPollingRegressionTests {

    // MARK: - File discovery

    private func relayPath(file: StaticString = #filePath) -> URL {
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
            .appendingPathComponent("Persistence")
            .appendingPathComponent("SQLKit")
            .appendingPathComponent("Outbox")
            .appendingPathComponent("SQLKitOutboxRelay.swift")
    }

    private func natsPublishingPath(file: StaticString = #filePath) -> URL {
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
            .appendingPathComponent("EventBus")
            .appendingPathComponent("NATSEventPublisher.swift")
    }

    private func relaySource() -> String {
        (try? String(contentsOf: relayPath(), encoding: .utf8)) ?? ""
    }

    private func natsPublisherSource() -> String {
        (try? String(contentsOf: natsPublishingPath(), encoding: .utf8)) ?? ""
    }

    // MARK: - Tests

    @Test("S-C2 — SQLKitOutboxRelay usa FOR UPDATE SKIP LOCKED na consulta de mensagens não processadas")
    func test_S_C2_relay_uses_for_update_skip_locked() {
        let source = relaySource()
        let lower = source.lowercased()
        #expect(lower.contains("for update skip locked"),
                "S-C2: SQLKitOutboxRelay não usa SELECT … FOR UPDATE SKIP LOCKED. Dois pods em paralelo pegam o mesmo lote — duplicação garantida.")
    }

    @Test("S-C2 — leitura, publish e UPDATE acontecem na MESMA transação (gap eliminado)")
    func test_S_C2_relay_wraps_poll_in_single_transaction() {
        let source = relaySource()
        // Sinal: a chamada que faz o SELECT raw FOR UPDATE deve estar DENTRO
        // de um `db.transaction { tx in` (ou similar). Buscamos a co-ocorrência.
        let lower = source.lowercased()
        guard let txStart = lower.range(of: "db.transaction") else {
            Issue.record("S-C2: SQLKitOutboxRelay não envolve poll em db.transaction.")
            return
        }
        let afterTx = lower[txStart.upperBound...]
        #expect(afterTx.contains("for update skip locked"),
                "S-C2: o SELECT FOR UPDATE SKIP LOCKED DEVE estar dentro do bloco db.transaction. Sem isso, lock pessimista não cobre o publish + UPDATE.")
    }

    @Test("S-C2 — NATSPublishing.publish aceita messageId para dedup downstream")
    func test_S_C2_nats_publishing_has_message_id() {
        let source = natsPublisherSource()
        let lower = source.lowercased()
        #expect(lower.contains("messageid"),
                "S-C2: protocolo NATSPublishing não aceita messageId. Sem isso, JetStream não consegue deduplicar por Nats-Msg-Id em re-publicação.")
    }

    @Test("S-C2 — relay propaga messageId no publish (preparação JetStream dedup)")
    func test_S_C2_relay_propagates_message_id() {
        let source = relaySource()
        let lower = source.lowercased()
        // O relay deve chamar nats.publish com messageId nomeado.
        #expect(lower.contains("messageid"),
                "S-C2: SQLKitOutboxRelay não passa messageId ao chamar nats.publish. Sem propagação, header Nats-Msg-Id fica vazio.")
    }
}
