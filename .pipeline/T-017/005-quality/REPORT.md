# T-017 — W3 Quality Gates

**Data:** 2026-05-14
**Achado:** S-C9 (Senior Code Review — `NATSEventPublisher` half-duplex, conexão morre no primeiro PING do servidor)

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 57.31s, 0 warnings novos |
| Full test suite | ✅ **384/384** passam, 0.095s |
| Regression suite | ✅ 80 testes em 15 suites (+5 do T-017) |
| Testes T-017 | ✅ **5/5** passam (lints estruturais) |
| ADR-016 | ✅ |
| DECISIONS.md index | próximo ID = **017** | ✅ |
| Skill `swift-io-implementer` | entrada 9 em "Lições Aprendidas" | ✅ |

## Arquivos criados

**Testes:**
- `Tests/.../Regression/EventPublication/NATSPublisherSurvivesPingTests.swift` — 5 testes estruturais

**Handbook + skill:**
- `handbook/architecture/DECISIONS/ADR-016-nats-publisher-bidirectional-handler.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-016 indexado; próximo ID = **017**
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 9

## Arquivos modificados

**Sources (1 arquivo, refator significativo):**
- `IO/EventBus/NATSEventPublisher.swift`:
  - Apagada `extension Channel { func readInbound }` (era `Task.sleep(100ms)` + buffer vazio).
  - `ensureConnected` agora instala `NATSPublisherInboundHandler` no pipeline NIO via `channelInitializer`.
  - Nova classe privada `NATSPublisherInboundHandler: ChannelInboundHandler, @unchecked Sendable`:
    - `PING\r\n` → `PONG\r\n` automático (keepalive).
    - `PONG\r\n` → ignora (server ack).
    - `INFO …\r\n` → log info.
    - `+OK\r\n` → silencioso.
    - `-ERR …\r\n` → log error com a mensagem do servidor.
    - `MSG`/`HMSG` → drena payload e descarta (publisher não subscreve).
    - Linha desconhecida → descarta para não travar parser.

## Decisões arquiteturais

1. **Opção B (handler próprio NIO) sobre Opção A (`nats-io/nats.swift` oficial)** — lib oficial em estado experimental (v0.x), API instável, não auditada para Swift 6.3 strict concurrency, e nosso escopo é restrito (PUB/HPUB no publisher). Decisão documentada com critério de re-avaliação: quando upstream chegar em v1.0 estável.
2. **Pattern espelha `NATSEventSubscriber.NATSMessageHandler`** — manter consistência. Uma única competência cobre publisher e subscriber.
3. **`@unchecked Sendable` justificado**: NIO `ChannelInboundHandler` exige classe; mutação fica no event loop (single-threaded); `_buffer` ainda usa `NIOLockedValueBox` por defesa em profundidade.
4. **Suite estrutural cobre regressão de design**, não runtime — teste de integração contra mock NATS server real fica no backlog (anotado em ADR-016 como ação requerida).

## Antes vs depois

```diff
 private func ensureConnected() async throws {
     if let ch = channel, ch.isActive { return }

     let group = MultiThreadedEventLoopGroup.singleton
+    let log = self.logger
     let bootstrap = ClientBootstrap(group: group)
         .channelOption(.socketOption(.so_reuseaddr), value: 1)
+        .channelInitializer { channel in
+            let handler = NATSPublisherInboundHandler(logger: log)
+            return channel.pipeline.addHandler(handler)
+        }

     let ch = try await bootstrap.connect(host: host, port: port).get()
     self.channel = ch

-    // Lê INFO do servidor (primeiro frame)
-    var infoBuffer = try await ch.readInbound()
-    if infoBuffer == nil {
-        infoBuffer = ch.allocator.buffer(capacity: 0)
-    }
-
+    // Servidor já enviou INFO antes — handler tratou (log) sem bloquear.
     var connectBuffer = ch.allocator.buffer(capacity: 64)
     connectBuffer.writeString("CONNECT {\"verbose\":false,\"pedantic\":false}\r\n")
     try await ch.writeAndFlush(connectBuffer)
 }

-private extension Channel {
-    func readInbound() async throws -> ByteBuffer? {
-        var buffer = allocator.buffer(capacity: 1024)
-        try? await Task.sleep(for: .milliseconds(100))
-        return buffer
-    }
-}

+private final class NATSPublisherInboundHandler: ChannelInboundHandler, @unchecked Sendable {
+    typealias InboundIn = ByteBuffer
+    // PING→PONG, INFO/+OK/-ERR/MSG/HMSG handling ~80 LOC
+}
```

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-015 (já reportados) | 14 fechados | 15 ADRs | 75 testes |
| T-017 | S-C9 | ADR-016 | 5 |
| **Total** | **15 fechados** | **16 ADRs** | **80 regression tests** |

## Backlog gerado por este ticket

1. **Reavaliar Opção A (`nats-io/nats.swift` oficial)** quando lib chegar em v1.0 estável + auditada para Swift 6.3 strict concurrency. Anotar em `handbook/architecture/IMPROVEMENT_BACKLOG.md` em uma janela futura.
2. **Teste de integração contra mock NATS server real** — `docker-compose nats:latest` em CI para validar PING/PONG runtime. Candidato a T-026 ou similar.

## Próximos tickets sugeridos

- **T-018** — Sanitização de logs LGPD (S-H-IO5, HIGH — não logar payload bruto que possa conter PII)
- **T-019** — `AnyJSON` enum Sendable (S-H-IO6, HIGH — strict concurrency)
- **T-020-T-024** (Phase 4) — Decompor god aggregate Patient
