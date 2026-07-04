import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import Logging

/// Subscribes to NATS subjects via TCP and dispatches decoded messages.
///
/// Protocol flow:
/// 1. TCP connect → receive INFO → send CONNECT
/// 2. SUB <subject> <sid>\r\n
/// 3. Server sends MSG <subject> <sid> <bytes>\r\n<payload>\r\n
/// 4. Respond to PING with PONG (keepalive)
public actor NATSEventSubscriber {
    private let host: String
    private let port: Int
    private let logger: Logger
    private var handlers: [String: @Sendable (Data) async -> Void] = [:]

    public init(url: String = "nats://nats:4222") {
        let parsed = Self.parseURL(url)
        self.host = parsed.host
        self.port = parsed.port
        self.logger = Logger(label: "nats-subscriber")
    }

    /// Register a handler for a NATS subject before calling start().
    public func subscribe(subject: String, handler: @escaping @Sendable (Data) async -> Void) {
        handlers[subject] = handler
    }

    /// Connect, subscribe, and start reading. Reconnects on failure.
    public func start() async {
        while true {
            do {
                try await connectAndListen()
            } catch {
                logger.error("NATS subscriber error — reconnecting in 5s", metadata: LogSanitizer.metadata(for: error))
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: - Connection lifecycle

    private func connectAndListen() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let messageHandler = NATSMessageHandler(handlers: handlers, logger: logger)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(messageHandler)
            }

        let channel = try await bootstrap.connect(host: host, port: port).get()
        logger.info("NATS subscriber connected to \(host):\(port)")

        // Wait for INFO, then send CONNECT
        try await Task.sleep(for: .milliseconds(200))
        var connectBuf = channel.allocator.buffer(capacity: 64)
        connectBuf.writeString("CONNECT {\"verbose\":false,\"pedantic\":false}\r\n")
        try await channel.writeAndFlush(connectBuf)

        // Send SUB for each subject
        var sid = 1
        for subject in handlers.keys {
            var subBuf = channel.allocator.buffer(capacity: 64)
            subBuf.writeString("SUB \(subject) \(sid)\r\n")
            try await channel.writeAndFlush(subBuf)
            logger.info("Subscribed to \(subject) (sid=\(sid))")
            sid += 1
        }

        // Block until channel closes
        try await channel.closeFuture.get()
        logger.warning("NATS connection closed")
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

// MARK: - NIO Channel Handler

/// Parses NATS protocol frames from the TCP stream and dispatches MSG payloads.
/// @unchecked Sendable justification: NIO ChannelInboundHandler requires a class.
/// All mutable state (`_buffer`) is protected by NIOLockedValueBox.
/// `handlers` and `logger` are immutable after init.
private final class NATSMessageHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let handlers: [String: @Sendable (Data) async -> Void]
    private let logger: Logger
    private let _buffer = NIOLockedValueBox<String>("")

    init(handlers: [String: @Sendable (Data) async -> Void], logger: Logger) {
        self.handlers = handlers
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        guard let str = buf.readString(length: buf.readableBytes) else { return }
        _buffer.withLockedValue { $0.append(str) }
        processBuffer(context: context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Channel error", metadata: LogSanitizer.metadata(for: error))
        context.close(promise: nil)
    }

    private func processBuffer(context: ChannelHandlerContext) {
        _buffer.withLockedValue { buffer in
            while true {
                // Handle PING
                if buffer.hasPrefix("PING\r\n") {
                    buffer = String(buffer.dropFirst("PING\r\n".count))
                    var pong = context.channel.allocator.buffer(capacity: 8)
                    pong.writeString("PONG\r\n")
                    context.writeAndFlush(NIOAny(pong), promise: nil)
                    continue
                }

                // Handle MSG <subject> <sid> <bytes>\r\n<payload>\r\n
                guard let headerEnd = buffer.range(of: "\r\n") else { break }
                let headerLine = String(buffer[buffer.startIndex..<headerEnd.lowerBound])

                if headerLine.hasPrefix("MSG ") {
                    let parts = headerLine.split(separator: " ")
                    guard parts.count >= 4, let byteCount = Int(parts[3]) else {
                        buffer = String(buffer[headerEnd.upperBound...])
                        continue
                    }

                    let afterHeader = buffer[headerEnd.upperBound...]
                    // Need <byteCount> bytes + \r\n
                    let needed = byteCount + 2
                    guard afterHeader.utf8.count >= needed else { break } // Wait for more data

                    let payloadStart = afterHeader.startIndex
                    let payloadEnd = afterHeader.utf8.index(payloadStart, offsetBy: byteCount)
                    let payload = String(afterHeader[payloadStart..<payloadEnd])
                    let subject = String(parts[1])

                    // Advance buffer past payload + \r\n
                    let frameEnd = afterHeader.utf8.index(payloadStart, offsetBy: needed)
                    buffer = String(afterHeader[frameEnd...])

                    // Dispatch to handler
                    if let handler = self.handlers[subject] {
                        let data = Data(payload.utf8)
                        Task { await handler(data) }
                    }
                } else if headerLine.hasPrefix("INFO ") || headerLine.hasPrefix("+OK") || headerLine.isEmpty {
                    // Skip INFO, +OK, empty lines
                    buffer = String(buffer[headerEnd.upperBound...])
                } else {
                    // Unknown line, skip
                    buffer = String(buffer[headerEnd.upperBound...])
                }
            }
        }
    }
}
