import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import Logging

/// Protocolo para publicação de eventos de domínio no NATS.
/// Permite injeção de dependência e teste com doubles.
public protocol NATSPublishing: Sendable {
    /// Publica um evento no NATS.
    ///
    /// - Parameters:
    ///   - event: Evento de domínio.
    ///   - typeName: Nome canônico do tipo do evento (usado no subject NATS).
    ///   - messageId: ID único da mensagem do outbox para deduplicação
    ///     no JetStream via header `Nats-Msg-Id` (ADR-013). Quando informado,
    ///     o JetStream descarta republicações dentro da janela de dedup
    ///     (default 2 min). Pode ser `nil` para publicações não-Outbox.
    func publish(_ event: any DomainEvent, typeName: String, messageId: UUID?) async throws

    func disconnect() async
}

/// Erros de comunicação com o NATS.
public enum NATSError: Error, Sendable {
    case connectionFailed(String)
    case notConnected
}

/// Publicador de eventos de domínio via NATS Core usando SwiftNIO.
///
/// ADR-016: substituiu implementação half-duplex (write-only com `readInbound`
/// fake) por handler bidirecional. Antes, NATS server enviava `PING\r\n` a cada
/// ~2min e a conexão morria silenciosamente porque o cliente ignorava.
///
/// Pipeline atual:
/// 1. TCP connect com `NATSPublisherInboundHandler` instalado no pipeline.
/// 2. Handler responde `PING` com `PONG` (keepalive). Loga `INFO`, `+OK`, `-ERR`.
/// 3. Cliente envia `CONNECT {…}\r\n` após o pipeline aceitar.
/// 4. `publish()` envia `PUB`/`HPUB` via `writeAndFlush`.
///
/// O JetStream stream `SOCIAL_CARE_EVENTS` (configurado no servidor com
/// subject filter `social-care.events.>`) captura automaticamente as mensagens.
public actor NATSEventPublisher: NATSPublishing {
    private let host: String
    private let port: Int
    private let encoder: JSONEncoder
    private let logger: Logger
    private var channel: Channel?

    public init(url: String = "nats://nats:4222") {
        let parsed = Self.parseURL(url)
        self.host = parsed.host
        self.port = parsed.port
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        self.logger = Logger(label: "nats-publisher")
    }

    /// Conecta ao servidor NATS via TCP e instala o inbound handler.
    private func ensureConnected() async throws {
        if let ch = channel, ch.isActive { return }

        let group = MultiThreadedEventLoopGroup.singleton
        let log = self.logger
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let handler = NATSPublisherInboundHandler(logger: log)
                return channel.pipeline.addHandler(handler)
            }

        do {
            let ch = try await bootstrap.connect(host: host, port: port).get()
            self.channel = ch

            // Envia CONNECT. `headers:true` é OBRIGATÓRIO: o publish usa frames
            // HPUB (header `Nats-Msg-Id` p/ dedup do JetStream, ADR-013). Sem
            // negociar headers no CONNECT, o servidor DESCARTA o HPUB
            // silenciosamente — o `writeAndFlush` "tem sucesso" no socket, o relay
            // marca `processed_at`, mas a mensagem NUNCA entra no stream (bug
            // observado no deploy BV: outbox publicado mas SOCIAL_CARE_EVENTS vazio).
            var connectBuffer = ch.allocator.buffer(capacity: 80)
            connectBuffer.writeString("CONNECT {\"verbose\":false,\"pedantic\":false,\"headers\":true}\r\n")
            try await ch.writeAndFlush(connectBuffer)

            logger.info("Connected to NATS at \(host):\(port)")
        } catch {
            // ADR-017: nunca interpolar `error` direto — pode vazar payload
            // (PSQLError, URLError, NIO errors podem incluir contexto sensível).
            logger.error("Failed to connect to NATS", metadata: LogSanitizer.metadata(for: error))
            throw NATSError.connectionFailed("\(host):\(port) — \(LogSanitizer.summary(for: error))")
        }
    }

    /// Publica um evento de domínio no subject `social-care.events.<typeName>`.
    ///
    /// ADR-013: quando `messageId` é informado, envia frame `HPUB` com header
    /// `Nats-Msg-Id: <uuid>` — JetStream usa para deduplicação dentro da
    /// janela do stream. Sem `messageId`, usa frame `PUB` tradicional.
    public func publish(_ event: any DomainEvent, typeName: String, messageId: UUID?) async throws {
        try await ensureConnected()

        guard let channel, channel.isActive else {
            throw NATSError.notConnected
        }

        let sanitizedName = typeName.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        let subject = "social-care.events.\(sanitizedName)"

        let payload: Data
        if let encodable = event as? any (DomainEvent & Encodable) {
            payload = try encoder.encode(AnyEncodableEvent(wrapped: encodable))
        } else {
            let fallback: [String: String] = [
                "id": event.id.uuidString,
                "occurredAt": ISO8601DateFormatter().string(from: event.occurredAt)
            ]
            payload = try JSONSerialization.data(withJSONObject: fallback)
        }

        if let messageId {
            // ADR-013: HPUB <subject> <#hdr-bytes> <#total-bytes>\r\n
            //   NATS/1.0\r\nNats-Msg-Id: <uuid>\r\n\r\n<payload>\r\n
            let header = "NATS/1.0\r\nNats-Msg-Id: \(messageId.uuidString)\r\n\r\n"
            let headerBytes = header.utf8.count
            let totalBytes = headerBytes + payload.count
            let pubLine = "HPUB \(subject) \(headerBytes) \(totalBytes)\r\n"
            var buffer = channel.allocator.buffer(capacity: pubLine.utf8.count + totalBytes + 2)
            buffer.writeString(pubLine)
            buffer.writeString(header)
            buffer.writeBytes(payload)
            buffer.writeString("\r\n")
            try await channel.writeAndFlush(buffer)
        } else {
            // Protocolo NATS: PUB <subject> <#bytes>\r\n<payload>\r\n
            let pubLine = "PUB \(subject) \(payload.count)\r\n"
            var buffer = channel.allocator.buffer(capacity: pubLine.utf8.count + payload.count + 2)
            buffer.writeString(pubLine)
            buffer.writeBytes(payload)
            buffer.writeString("\r\n")
            try await channel.writeAndFlush(buffer)
        }
    }

    public func disconnect() async {
        try? await channel?.close()
        channel = nil
        logger.info("Disconnected from NATS")
    }

    private static func parseURL(_ url: String) -> (host: String, port: Int) {
        var str = url
        if str.hasPrefix("nats://") {
            str = String(str.dropFirst("nats://".count))
        }
        let parts = str.split(separator: ":")
        let host = String(parts.first ?? "nats")
        let port = parts.count > 1 ? Int(parts[1]) ?? 4222 : 4222
        return (host, port)
    }
}

/// Wrapper para codificar eventos via existential opening.
private struct AnyEncodableEvent: Encodable, Sendable {
    let wrapped: any (DomainEvent & Encodable)

    func encode(to encoder: Encoder) throws {
        try wrapped.encode(to: encoder)
    }
}

// MARK: - Inbound Handler (ADR-016)

/// Parseia frames vindos do servidor NATS e mantém a conexão viva.
///
/// Responsabilidades:
/// - Responder `PING\r\n` com `PONG\r\n` (keepalive — sem isso, server fecha
///   a conexão após ~2min de inatividade).
/// - Logar `INFO …\r\n` recebido na conexão (diagnóstico).
/// - Logar `+OK\r\n` (ack do servidor — opcional).
/// - Logar `-ERR …\r\n` (errors do servidor — auth fail, slow consumer, etc).
/// - Ignorar frames de mensagem (`MSG`/`HMSG`) — publisher não subscreve.
///
/// `@unchecked Sendable` justification: NIO `ChannelInboundHandler` exige
/// classe. Toda mutação acontece dentro do `EventLoop` do channel (single
/// threaded por design NIO). `_buffer` protegido por `NIOLockedValueBox` por
/// segurança extra. `logger` é imutável após init.
private final class NATSPublisherInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let logger: Logger
    private let _buffer = NIOLockedValueBox<String>("")

    init(logger: Logger) {
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        guard let str = buf.readString(length: buf.readableBytes) else { return }
        _buffer.withLockedValue { $0.append(str) }
        processBuffer(context: context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("NATS publisher channel error", metadata: LogSanitizer.metadata(for: error))
        context.close(promise: nil)
    }

    private func processBuffer(context: ChannelHandlerContext) {
        _buffer.withLockedValue { buffer in
            while true {
                // Keepalive: server envia PING a cada ~2min.
                if buffer.hasPrefix("PING\r\n") {
                    buffer = String(buffer.dropFirst("PING\r\n".count))
                    var pong = context.channel.allocator.buffer(capacity: 8)
                    pong.writeString("PONG\r\n")
                    context.writeAndFlush(NIOAny(pong), promise: nil)
                    continue
                }

                // Server ack após PING do cliente (não emitimos atualmente,
                // mas processamos por completude).
                if buffer.hasPrefix("PONG\r\n") {
                    buffer = String(buffer.dropFirst("PONG\r\n".count))
                    continue
                }

                // Procura próxima linha completa (\r\n).
                guard let lineEnd = buffer.range(of: "\r\n") else { break }
                let line = String(buffer[buffer.startIndex..<lineEnd.lowerBound])
                let advanced = String(buffer[lineEnd.upperBound...])

                if line.hasPrefix("INFO ") {
                    logger.info("NATS server INFO received")
                    buffer = advanced
                } else if line.hasPrefix("+OK") {
                    // Server ack — silencioso para não poluir log em modo verbose.
                    buffer = advanced
                } else if line.hasPrefix("-ERR") {
                    // -ERR é diagnostic-grade: auth fail, slow consumer, etc.
                    // Logar para alertar operação. Mensagem do servidor já vem
                    // entre aspas: -ERR 'Authorization Violation'
                    logger.error("NATS server error: \(line)")
                    buffer = advanced
                } else if line.hasPrefix("MSG ") || line.hasPrefix("HMSG ") {
                    // Publisher não subscreve. Se chegar MSG/HMSG, é configuração
                    // estranha — descarta linha + tenta avançar o payload conhecido.
                    let parts = line.split(separator: " ")
                    let byteCount: Int
                    if line.hasPrefix("HMSG "), parts.count >= 5 {
                        byteCount = Int(parts[4]) ?? 0
                    } else if parts.count >= 4 {
                        byteCount = Int(parts[3]) ?? 0
                    } else {
                        byteCount = 0
                    }
                    let needed = byteCount + 2 // payload + \r\n
                    if advanced.utf8.count >= needed {
                        let dropIdx = advanced.utf8.index(advanced.startIndex, offsetBy: needed)
                        buffer = String(advanced[dropIdx...])
                    } else {
                        // Aguarda mais dados.
                        break
                    }
                } else if line.isEmpty {
                    buffer = advanced
                } else {
                    // Linha desconhecida — descarta para não travar o parser.
                    buffer = advanced
                }
            }
        }
    }
}
