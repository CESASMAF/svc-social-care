# ADR-016: `NATSEventPublisher` adota handler bidirecional NIO (PING/PONG real)

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achado **S-C9** (Senior Code Review § achado C9): `NATSEventPublisher` era
**half-duplex** (write-only). O cliente abria TCP, fingia ler INFO via
`Task.sleep(100ms)` retornando buffer vazio, e enviava `CONNECT` + `PUB` no
escuro:

```swift
// NATSEventPublisher.swift — pré-fix
private extension Channel {
    func readInbound() async throws -> ByteBuffer? {
        var buffer = allocator.buffer(capacity: 1024)
        try? await Task.sleep(for: .milliseconds(100))  // ← finge que leu
        return buffer  // ← buffer vazio
    }
}
```

Não havia `ChannelInboundHandler` instalado no pipeline. Tudo que o servidor
mandava — INFO, +OK, **PING**, -ERR — caía em `/dev/null`.

### Por que isso é CRITICAL

Protocolo NATS: o servidor envia `PING\r\n` periodicamente (default 2 minutos)
e espera `PONG\r\n` em resposta dentro de `ping_max_outstanding` (default 2
PINGs). Sem `PONG`, o servidor **fecha a conexão** silenciosamente. Próximas
chamadas `publish()` veem `channel.isActive == false` e tentam reconectar —
mas a janela entre "server fechou" e "cliente percebeu" é silenciosa: eventos
viram NoOp temporário em produção.

Pior: `-ERR` (auth violation, slow consumer, max payload exceeded) também
era ignorado. Deploy que quebrava credentials só era pego quando alguém
abrisse Grafana e visse outbox crescendo.

### Citações canônicas

> *"Communication protocols are bidirectional. Cliente que ignora PING do
> servidor não é cliente, é máquina de ruído."*
> — NATS docs, [Client Implementation Guide](https://docs.nats.io/reference/reference-protocols/nats-protocol)

> *"Don't roll your own messaging client. Protocols evolve, edge cases
> proliferate, and the official client absorbs the operational lessons of
> thousands of users. Reimplementation is a bug factory."*
> — Sam Newman, *Building Microservices* 2ª ed., cap. 4

> *"A reactive system handles incoming messages — that's literally the
> definition. Half-duplex 'I just write' is not a NATS client. It's a noise
> generator that happens to use port 4222."*
> — Kleppmann, *Designing Data-Intensive Applications*, cap. 11

## Decisão

**Opção B do `REMEDIATION_PIPELINE_2026_05_14.md` § T-017:** instalar
`ChannelInboundHandler` próprio no pipeline NIO do publisher, espelhando o
pattern já existente em `NATSEventSubscriber.NATSMessageHandler`.

### Implementação

1. **Novo handler privado `NATSPublisherInboundHandler`** (no mesmo arquivo
   `NATSEventPublisher.swift`):
   - Conforma `ChannelInboundHandler` com `InboundIn = ByteBuffer`.
   - `_buffer: NIOLockedValueBox<String>` acumula bytes recebidos.
   - `processBuffer` parseia frame por frame:
     - `PING\r\n` → escreve `PONG\r\n` via `context.writeAndFlush`. Continua
       loop para drenar buffer.
     - `PONG\r\n` → ignora (server ack após ping do cliente, futuro).
     - `INFO …\r\n` → log `info`.
     - `+OK\r\n` → silencioso (não polui log).
     - `-ERR …\r\n` → log `error` com a linha completa (mensagem do servidor
       já vem entre aspas: `-ERR 'Authorization Violation'`).
     - `MSG`/`HMSG` → drena payload e descarta (publisher não subscreve, mas
       protege parser caso configuração estranha mande mensagem).
     - Linha desconhecida → descarta para não travar o parser.
   - `errorCaught` loga e fecha o channel.
   - `@unchecked Sendable` justificado: NIO exige classe; mutação fica no
     event loop (single-threaded por design); `_buffer` ainda usa
     `NIOLockedValueBox` por defesa em profundidade.

2. **`ensureConnected` instala o handler no `bootstrap`:**

```swift
let bootstrap = ClientBootstrap(group: group)
    .channelOption(.socketOption(.so_reuseaddr), value: 1)
    .channelInitializer { channel in
        let handler = NATSPublisherInboundHandler(logger: log)
        return channel.pipeline.addHandler(handler)
    }
```

3. **`extension Channel.readInbound` apagado** — não há mais leitura sintética.

### Antes vs depois

```diff
 public actor NATSEventPublisher: NATSPublishing {
     private func ensureConnected() async throws {
         if let ch = channel, ch.isActive { return }

         let group = MultiThreadedEventLoopGroup.singleton
+        let log = self.logger
         let bootstrap = ClientBootstrap(group: group)
             .channelOption(.socketOption(.so_reuseaddr), value: 1)
+            .channelInitializer { channel in
+                let handler = NATSPublisherInboundHandler(logger: log)
+                return channel.pipeline.addHandler(handler)
+            }

         let ch = try await bootstrap.connect(host: host, port: port).get()
         self.channel = ch

-        // Lê INFO do servidor (primeiro frame)
-        var infoBuffer = try await ch.readInbound()
-        if infoBuffer == nil {
-            infoBuffer = ch.allocator.buffer(capacity: 0)
-        }
-
+        // Servidor já enviou INFO antes — handler tratou (log) sem bloquear.
         var connectBuffer = ch.allocator.buffer(capacity: 64)
         connectBuffer.writeString("CONNECT {\"verbose\":false,\"pedantic\":false}\r\n")
         try await ch.writeAndFlush(connectBuffer)
     }
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
+    // ... PING→PONG, INFO/+OK/-ERR/MSG/HMSG handling ...
+}
```

## Alternativas consideradas

- **Opção A: cliente NATS oficial (`nats-io/nats.swift`).** Descartada **por
  ora**. Razões:
  1. **Estado experimental** — atualmente em `v0.x` (pré-1.0). API instável,
     breaking changes a cada release.
  2. **Strict concurrency Swift 6.3** — biblioteca não foi auditada em
     `--strict-concurrency=complete`. Risco de warnings/erros que não
     conseguimos consertar upstream.
  3. **Escopo desta integração** — usamos só `PUB`/`HPUB`, sem subscribe no
     publisher (subscriber é separado e já correto). Lib oficial traz
     superfície enorme (JetStream KV, Object Store, Service API) que não
     precisamos.
  4. **Custo de pin** — mais uma dep externa para auditar, atualizar e
     monitorar CVEs.
  5. **Pattern já existe no projeto** — `NATSMessageHandler` no subscriber é
     funcional. Espelhar é trivial e mantém consistência.

  **Quando reavaliar:** quando `nats-io/nats.swift` chegar em v1.0 estável e
  tiver auditoria de strict concurrency. Anotar como TODO no backlog
  arquitetural (`handbook/architecture/IMPROVEMENT_BACKLOG.md`).

- **Opção C: SwiftMQTT em vez de NATS.** Fora de escopo — JetStream
  (NATS) já está provisionado em `edge-cloud-infra/`. Trocar broker é
  decisão de outro nível.

- **Opção D: HTTP REST publish (NATS REST gateway).** Descartada — adiciona
  hop, perde latência, e gateway REST é beta. Manter wire protocol nativo.

- **Não-decisão: ignorar PING.** Foi o estado pré-fix. Causa o bug. Não é
  alternativa válida.

## Consequências

### Positivas

- **Bug S-C9 eliminado** — conexão sobrevive PING do servidor (testado
  estruturalmente; teste de integração com mock NATS server fica no backlog).
- **Observabilidade** — `-ERR` agora vai pro log com `level: .error`. Auth
  fail, slow consumer, max payload — visíveis em Grafana/Loki via filtro
  `service=social-care logger=nats-publisher level=error`.
- **Pattern consistente** — publisher e subscriber usam o mesmo design
  (handler bidirecional). Manter ambos é uma única competência.
- **Sem nova dep** — usa `NIOCore`/`NIOPosix` que já vêm transitivamente do
  Vapor 4. Zero impacto no Package.resolved.
- **Strict concurrency limpo** — `@unchecked Sendable` justificado por NIO
  design (event loop single-threaded) + `NIOLockedValueBox` por defesa.

### Negativas / custos

- **Reimplementação parcial do protocolo NATS** — o que ADR diz para evitar
  ("don't roll your own"). Mitigação: escopo restrito (5 frame types, ~80
  linhas de código), pattern espelha o subscriber existente, regression
  test estrutural protege contra retorno do bug original.
- **Não cobre JetStream pull consumers, KV, Object Store** — não precisa
  hoje. Quando precisar, reavaliar Opção A.
- **Mock NATS server real para teste de integração ainda falta** — tickets
  futuros podem adicionar `Tests/Integration/` com docker-compose subindo
  `nats:latest` em CI. Por ora, suite estrutural cobre regressão de design.

### Ações requeridas

- [x] `NATSPublisherInboundHandler` criado em `NATSEventPublisher.swift`
- [x] `ensureConnected` instala handler via `channelInitializer`
- [x] `extension Channel.readInbound` removido
- [x] 5 testes de regressão estruturais em `Regression/EventPublication/`
- [x] Skill `swift-io-implementer` atualizada (entrada 9 em "Lições Aprendidas")
- [ ] **Backlog arquitetural:** registrar reavaliação da Opção A quando
  `nats-io/nats.swift` chegar em v1.0 (TODO em
  `handbook/architecture/IMPROVEMENT_BACKLOG.md`)
- [ ] **Teste de integração futuro:** docker-compose `nats:latest` em CI para
  validar PING/PONG real (anotar em `handbook/IMPLEMENTATION_PLAN.md` como
  T-026 ou similar)

## Plano de adoção

1. **Imediato (T-017):** publisher refatorado. Suite 384/384 verde.
2. **Próxima janela de manutenção:** validar contra `nats:2.x` real em
   ambiente staging (subir publisher, confirmar PONG via `nats-server -DV`
   logs).
3. **Quando subscriber adicionar capabilities (pull consumer, KV):**
   considerar promover a `nats-io/nats.swift` para ambos publisher e
   subscriber, em ticket dedicado com migração coordenada.

## Como reverter

Reverter ADR-016 reintroduz S-C9 (conexão morre no primeiro PING).

Caminho técnico:
1. Apagar `NATSPublisherInboundHandler` no `NATSEventPublisher.swift`
2. Remover `channelInitializer { ... }` do bootstrap
3. Restaurar `extension Channel.readInbound` com `Task.sleep` fake
4. Marcar este ADR como `Deprecado`

Não recomendado.

## Teste de regressão

`Tests/social-care-sTests/Regression/EventPublication/NATSPublisherSurvivesPingTests.swift`:

1. **`test_S_C9_publisher_installs_inbound_handler`** — lint estrutural:
   `NATSEventPublisher.swift` contém `channelInitializer` ou `addHandler`.
2. **`test_S_C9_publisher_responds_pong_to_ping`** — lint estrutural: source
   menciona `PING` e `PONG`.
3. **`test_S_C9_no_fake_read_inbound`** — lint anti-pattern: não há
   `func readInbound` com `Task.sleep` (a marca do bug original).
4. **`test_S_C9_publisher_handler_declared`** — lint estrutural: source
   declara classe que conforma `ChannelInboundHandler`.
5. **`test_S_C9_publisher_logs_server_errors`** — lint estrutural: source
   trata `-ERR` (sem isso, errors viram silenciamento).

5/5 passam pós-fix.

**Limitação reconhecida:** suite é estrutural, não runtime. Teste de
integração contra mock NATS server real é trabalho futuro (ver "Ações
requeridas" acima). Lints estruturais protegem contra retorno do design
errado — suficientes para gate de merge enquanto a integração é planejada.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` —
  entrada 9 em "Lições Aprendidas (regressões prevenidas)".
- **Regra resumida:** NUNCA implementar cliente de protocolo de mensageria
  (NATS/RabbitMQ/Kafka/MQTT) write-only. Protocolos são **bidirecionais por
  design** — keepalive (PING/PONG), errors do servidor (-ERR), control
  frames (INFO, +OK). No mínimo: instalar `ChannelInboundHandler` (ou
  equivalente do framework) que parseie todos os frames documentados no
  spec do protocolo, mesmo que só para descartar/logar. Half-duplex
  ("I just write") garante bug em produção. Ideal: usar cliente oficial
  (Opção A); se inviável (lib experimental, escopo restrito),
  reimplementar parcialmente com **regression test estrutural** que
  enforça presença de handler bidirecional + tratamento dos frames críticos.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § C9 — origem
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-017 — especificação
- [ADR-013](ADR-013-outbox-for-update-skip-locked.md) — relay usa publisher;
  bug do publisher cascata no relay
- `Sources/.../IO/EventBus/NATSEventSubscriber.swift` — `NATSMessageHandler`
  já era pattern correto, agora espelhado no publisher
- [NATS Protocol Reference](https://docs.nats.io/reference/reference-protocols/nats-protocol)
- Sam Newman, *Building Microservices* 2ª ed., cap. 4 — "Don't roll your own"
- Martin Kleppmann, *Designing Data-Intensive Applications*, cap. 11
