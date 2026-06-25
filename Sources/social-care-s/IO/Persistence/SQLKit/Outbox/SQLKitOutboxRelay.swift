import Foundation
import SQLKit
import Logging

/// Um Actor que gerencia a leitura e distribuição de eventos do Outbox.
/// Garante que apenas um processo de polling ocorra por vez e distribui
/// os eventos via AsyncStream para processamento paralelo.
public actor SQLKitOutboxRelay: Sendable {
    private let db: any SQLDatabase
    private var isPolling = false
    private let pollInterval: Duration
    private let natsPublisher: (any NATSPublishing)?
    private let logger: Logger

    // Armazena as continuações dos streams ativos
    private var continuations: [UUID: AsyncStream<any DomainEvent>.Continuation] = [:]

    public init(db: any SQLDatabase, natsPublisher: (any NATSPublishing)? = nil, pollInterval: Duration = .seconds(1)) {
        self.db = db
        self.natsPublisher = natsPublisher
        self.pollInterval = pollInterval
        self.logger = Logger(label: "outbox-relay")
    }
    
    /// Cria um novo stream de eventos do Outbox.
    /// Múltiplos consumidores podem chamar este método para receber eventos.
    public func events() -> AsyncStream<any DomainEvent> {
        let streamId = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { @Sendable _ in
                Task { [streamId, weak relay = self] in
                    await relay?.removeContinuation(id: streamId)
                }
            }
            
            // Usamos um Task para interagir com o estado do actor
            Task { [streamId, weak relay = self] in
                await relay?.addContinuation(continuation, withId: streamId)
            }
        }
    }
    
    private func addContinuation(_ continuation: AsyncStream<any DomainEvent>.Continuation, withId id: UUID) {
        self.continuations[id] = continuation
        if !isPolling {
            Task { await self.startPolling() }
        }
    }
    
    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
    
    /// Inicia o polling em modo standalone (sem consumers in-process).
    /// Usado quando o relay tem um NATSPublisher configurado e precisa
    /// rodar continuamente independente de ter consumers via `events()`.
    public func startContinuousPolling() async {
        guard !isPolling else { return }
        isPolling = true

        while !Task.isCancelled {
            do {
                try await pollAndDistribute()
            } catch {
                logger.error("Outbox relay poll failed", metadata: LogSanitizer.metadata(for: error))
            }

            try? await Task.sleep(for: pollInterval)
        }

        isPolling = false
    }

    private func startPolling() async {
        guard !isPolling else { return }
        isPolling = true

        while !continuations.isEmpty {
            do {
                try await pollAndDistribute()
            } catch {
                logger.error("Outbox relay poll failed", metadata: LogSanitizer.metadata(for: error))
            }

            try? await Task.sleep(for: pollInterval)
        }

        isPolling = false
    }
    
    private func pollAndDistribute() async throws {
        // ADR-013: SELECT FOR UPDATE SKIP LOCKED + processamento + UPDATE
        // dentro da MESMA transação.
        //
        // Pré-ADR-013: dois pollers liam o mesmo lote, publicavam duplicado,
        // depois faziam UPDATE concorrente. Janela entre publish e UPDATE
        // permitia re-publicação em crash.
        //
        // Pós-ADR-013: FOR UPDATE SKIP LOCKED faz com que cada poller pegue
        // lote disjunto (locks ignorados pelo SKIP LOCKED). Locks só são
        // liberados no COMMIT — não há janela entre publish e UPDATE.
        //
        // Trade-off: NATS publish dentro da TX segura o lock por ~5s no pior
        // caso. Aceitável para batch de 50. Se latência NATS crescer,
        // reduzir batchSize.

        // Snapshot das continuations antes da TX para respeitar actor isolation.
        let snapshot = self.continuations
        let publisher = self.natsPublisher
        let log = self.logger

        try await db.transaction { tx in
            // 1. SELECT FOR UPDATE SKIP LOCKED — pollers paralelos se serializam.
            let messages = try await tx.raw("""
                SELECT * FROM outbox_messages
                WHERE processed_at IS NULL
                ORDER BY occurred_at ASC
                FOR UPDATE SKIP LOCKED
                LIMIT 50
            """).all(decoding: OutboxMessageModel.self)

            guard !messages.isEmpty else { return }

            var processedIds: [UUID] = []
            var auditEntries: [AuditTrailModel] = []
            let now = Date()

            for message in messages {
                do {
                    // 2. Decode
                    let event = try await DomainEventRegistry.shared.decode(
                        typeName: message.event_type,
                        data: Data(message.payload.utf8)
                    )

                    // 3. Publish NATS — ADR-013: messageId propagado para Nats-Msg-Id.
                    // JetStream deduplica re-publicações em janela default (2min).
                    if let nats = publisher {
                        try await nats.publish(
                            event,
                            typeName: message.event_type,
                            messageId: message.id
                        )
                    }

                    // 4. Distribui para streams in-process
                    for continuation in snapshot.values {
                        continuation.yield(event)
                    }

                    // 5. Prepara entrada no audit trail (ADR-015).
                    // `id` é UUID novo (não reusa message.id) — re-processamento
                    // adiciona N entries em vez de travar com PK conflict.
                    // `outbox_message_id` rastreia a origem.
                    let parsed = Self.extractFields(from: message.payload)
                    let aggregateId = parsed.aggregateId ?? message.id
                    auditEntries.append(AuditTrailModel(
                        id: UUID(),
                        outbox_message_id: message.id,
                        aggregate_type: "Patient",
                        aggregate_id: aggregateId,
                        event_type: message.event_type,
                        actor_id: parsed.actorId,
                        payload: message.payload,
                        occurred_at: message.occurred_at,
                        recorded_at: now
                    ))

                    processedIds.append(message.id)
                } catch {
                    // ADR-019: NÃO logar payload bruto — preserva PII LGPD.
                    log.warning("Failed to process outbox event", metadata: [
                        "eventId": "\(message.id)",
                        "eventType": .string(message.event_type),
                        "errorType": .string(String(reflecting: type(of: error)))
                    ])
                    // Só marca como processed se foi erro de decode (não de NATS).
                    // NATS falha → não adiciona ao processedIds → retry próxima poll
                    // (proteção dupla com Nats-Msg-Id no caminho feliz).
                    if (error as? DomainEventError) != nil {
                        processedIds.append(message.id)
                    }
                }
            }

            // 6. Persiste audit trail + marca outbox como processado (mesma TX).
            // ADR-022: payload é JSONB — bind via SQL raw com cast `::jsonb`
            // explícito. `.model()` daria erro de tipo.
            if !processedIds.isEmpty {
                for entry in auditEntries {
                    try await tx.raw("""
                        INSERT INTO audit_trail (id, outbox_message_id, aggregate_type, aggregate_id, event_type, actor_id, payload, occurred_at, recorded_at)
                        VALUES (\(bind: entry.id), \(bind: entry.outbox_message_id), \(bind: entry.aggregate_type), \(bind: entry.aggregate_id), \(bind: entry.event_type), \(bind: entry.actor_id), \(bind: entry.payload)::jsonb, \(bind: entry.occurred_at), \(bind: entry.recorded_at))
                    """).run()
                }
                try await tx.update("outbox_messages")
                    .set("processed_at", to: now)
                    .where("id", .in, processedIds)
                    .run()
            }
        }
    }

    private static func extractFields(from payload: String) -> (aggregateId: UUID?, actorId: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return (nil, nil)
        }
        let aggregateId = (json["patientId"] as? String).flatMap { UUID(uuidString: $0) }
        let actorId = json["actorId"] as? String
        return (aggregateId, actorId)
    }
}
