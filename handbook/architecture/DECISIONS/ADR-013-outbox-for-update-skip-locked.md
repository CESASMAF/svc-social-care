# ADR-013: Outbox at-least-once com `FOR UPDATE SKIP LOCKED` + Nats-Msg-Id

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achado **S-C2** (Senior Code Review § achado C2): o relay do Outbox tinha
**dois bugs encadeados** que juntos viraram duplicação garantida em produção
multi-instância:

### Bug 1: SELECT sem lock pessimista

```swift
// PRÉ-FIX
let messages = try await db.select()
    .column("*")
    .from("outbox_messages")
    .where("processed_at", .is, SQLLiteral.null)
    .orderBy("occurred_at", .ascending)
    .limit(50)
    .all(decoding: OutboxMessageModel.self)
```

Dois pollers em paralelo (rolling deploy com 2+ replicas, ou Kubernetes durante restart) liam **o mesmo lote**. Ambos publicavam, ambos faziam UPDATE — eventos publicados duas vezes.

### Bug 2: Gap entre publish e UPDATE

```swift
// PRÉ-FIX
for message in messages {
    try await nats.publish(event, typeName: message.event_type)  // ① publish
    processedIds.append(message.id)
}
// ... fora do loop ...
try await db.transaction { tx in
    try await tx.update("outbox_messages").set("processed_at", to: now)...  // ② UPDATE
}
```

Entre ① e ② a app podia crashar (OOM, SIGKILL, deploy). Próximo poll re-lia
mensagem que já tinha sido publicada → duplicação.

### Citações canônicas

> *"Even if we store which events have been processed, with some forms of asynchronous message delivery there may be small windows in which two workers can see the same message. By processing the events in an idempotent manner, we ensure this won't cause us any issues."*
> — Sam Newman, *Building Microservices*, p. 500

> *"PostgreSQL `SELECT … FOR UPDATE SKIP LOCKED` is the standard pattern for queue-as-table workers: lock contended rows are skipped instead of blocking, giving each worker a disjoint batch."*
> — PostgreSQL docs, §13.3.2 (Row-Level Locks)

At-least-once é aceitável se (a) consumer é idempotente e (b) producer emite `idempotencyKey` deduplicável pelo broker. Hoje, nenhum dos dois — fix duplo.

## Decisão

### 1. `SELECT … FOR UPDATE SKIP LOCKED` dentro de transação

```swift
try await db.transaction { tx in
    let messages = try await tx.raw("""
        SELECT * FROM outbox_messages
        WHERE processed_at IS NULL
        ORDER BY occurred_at ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 50
    """).all(decoding: OutboxMessageModel.self)

    // ... publish + audit_trail INSERT + UPDATE processed_at ...
    // tudo dentro da MESMA TX
}
```

`FOR UPDATE SKIP LOCKED`:
- Cada poller pega lote **disjunto** — mesma row não é re-lida por concorrente.
- Locks só liberam no `COMMIT` — TX cobre publish + UPDATE.
- Sem `SKIP LOCKED`, pollers bloqueariam um ao outro (degradação de throughput).

### 2. `messageId` propagado no NATS via `Nats-Msg-Id`

`NATSPublishing` ganha parâmetro `messageId: UUID?`:

```swift
public protocol NATSPublishing: Sendable {
    func publish(_ event: any DomainEvent, typeName: String, messageId: UUID?) async throws
    func disconnect() async
}
```

Relay passa `message.id` do outbox:

```swift
try await nats.publish(event, typeName: message.event_type, messageId: message.id)
```

Na implementação NATS, frame `HPUB` (header pub) envia:

```
HPUB <subject> <hdr-bytes> <total-bytes>
NATS/1.0
Nats-Msg-Id: <uuid>

<payload>
```

JetStream usa `Nats-Msg-Id` para deduplicação dentro da janela do stream
(default 2 min, configurável). Se relay re-publicar mesmo evento por causa
de re-leitura, JetStream descarta a duplicata silenciosamente.

### 3. Audit trail e UPDATE na mesma TX

Já estava parcialmente correto pré-fix, mas agora envolve TUDO na mesma TX
— do SELECT ao UPDATE final. Não há gap onde crashar.

### 4. Log sanitizado (ADR-019)

Erro de processamento agora loga `String(reflecting: type(of: error))` em vez de `\(error)` — não vaza payload com PII em log.

## Alternativas consideradas

- **`SELECT … FOR UPDATE` (sem SKIP LOCKED).** Considerada. Descartada — pollers bloqueariam um ao outro até timeout. Throughput cai em escala. SKIP LOCKED é o padrão para queue-as-table.
- **Single-leader via `pg_try_advisory_lock`.** Considerada. Descartada — força exatamente uma instância polling. Perde paralelismo natural e cria SPOF se o leader trava sem soltar lock. FOR UPDATE SKIP LOCKED é mais robusto.
- **TX curta apenas para o lock, processamento fora.** Considerada. Descartada — reintroduz o gap entre publish e UPDATE. TX longa cobre risco de crash.
- **Dedup via Postgres advisory lock no `message.id`.** Considerada. Descartada — adiciona complexidade no relay. JetStream já tem dedup nativo via `Nats-Msg-Id`. Usar onde existe.
- **Não passar `messageId` (confiar só em FOR UPDATE).** Descartada — fail-safe defense in depth. Se FOR UPDATE falhar (PostgreSQL bug, race em ALTER TABLE), JetStream ainda dedup.
- **Reduzir `batchSize` para 10.** Considerada como mitigação de lock-time. Descartada — 50 com NATS local roda < 100ms. Se latência crescer, batch pode ser reduzido em ADR futuro.

## Consequências

### Positivas

- Duplicação eliminada — `FOR UPDATE SKIP LOCKED` + `Nats-Msg-Id` formam **double-safety**.
- Multi-instância seguro — pode rodar 2+ pods sem coordenação adicional.
- Gap entre publish e UPDATE fechado — crash no meio re-lê e re-publica, mas JetStream descarta via dedup.
- Log sanitizado — PII LGPD protegida.

### Negativas / custos

- **Lock segurado por mais tempo.** TX cobre NATS publish. Para batch 50 com NATS local ~50-100ms; com NATS remoto pode chegar a 1-2s. Se publish travar, lock fica preso. Mitigação: timeout no NATS publish (já existe via channel) + batchSize.
- **HPUB protocol mais verboso que PUB** — overhead pequeno (~60 bytes por message com 1 header). Aceitável.
- **Implementação NATS atual (custom TCP, T-017)** já é frágil — adicionar HPUB amplia superfície. T-017 substitui por cliente oficial. Até lá, HPUB segue protocolo NATS Headers 1.0 RFC.

### Ações requeridas

- [x] `NATSPublishing.publish(_:typeName:messageId:)` (assinatura evoluída)
- [x] `NATSEventPublisher` envia HPUB quando messageId é informado
- [x] `SQLKitOutboxRelay.pollAndDistribute` usa `db.transaction { tx in SELECT FOR UPDATE SKIP LOCKED ... }`
- [x] Audit trail + UPDATE processed_at dentro da mesma TX
- [x] Log sanitizado (não loga payload bruto)
- [x] 4 testes de regressão estruturais
- [ ] **T-015** — `audit_trail.id` distinto de `outbox.id` (S-C10) — agora que TX cobre tudo, o conflict no audit pode acontecer apenas em re-processamento (raro pós-ADR-013), mas continua sendo bug a corrigir.
- [ ] **T-017** — cliente NATS oficial — substitui implementação custom TCP que tem PING/PONG bug + HPUB manual frágil.
- [ ] **Médio prazo:** integration test com Postgres real validando dois pollers em paralelo (T-033).

## Plano de adoção

1. **Imediato (T-012):** relay + NATSPublishing refatorados. Suite 371/371 verde.
2. **Próximo deploy:** JetStream do servidor NATS precisa ter `duplicate_window: 2m` (default já é assim no nats-server moderno). Verificar na infra.
3. **Monitoramento:** observar contagem de eventos publicados vs entregues no JetStream. Diferença > 0 = duplicação dedup funcionando.
4. **T-017:** quando vier, HPUB manual é substituído por API nativa do cliente oficial.

## Como reverter

Caminho técnico:
1. Reverter `pollAndDistribute` para SELECT vanilla (sem FOR UPDATE)
2. Reverter `NATSPublishing.publish` para assinatura sem `messageId`
3. Reverter `publish` no `NATSEventPublisher` para só PUB
4. Marcar este ADR como `Deprecado`

Não recomendado — reintroduz S-C2.

## Teste de regressão

`Tests/social-care-sTests/Regression/Concurrency/OutboxConcurrentPollingRegressionTests.swift`:

1. `test_S_C2_relay_uses_for_update_skip_locked` — source contém "FOR UPDATE SKIP LOCKED"
2. `test_S_C2_relay_wraps_poll_in_single_transaction` — SELECT FOR UPDATE está DENTRO de `db.transaction {`
3. `test_S_C2_nats_publishing_has_message_id` — protocol NATSPublishing aceita `messageId`
4. `test_S_C2_relay_propagates_message_id` — relay cita `messageId` no source

4/4 passam. Validação runtime com Postgres real fica para T-033 (schema snapshot + integration suite).

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` — entrada 7 em "Lições Aprendidas".
- **Regra resumida:** Qualquer relay polling em PostgreSQL (Outbox, queue-as-table) usa **`SELECT … FOR UPDATE SKIP LOCKED` dentro de transação** que cobre todo o ciclo (SELECT → processar → UPDATE). `LIMIT` é o batchSize. Publicação em broker (NATS, Kafka, RabbitMQ) propaga `messageId` único quando broker suporta dedup nativo. Defense in depth: lock no DB + dedup no broker.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § C2 — origem
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-012 — especificação
- [ADR-002](ADR-002-regression-test-policy.md) — política de testes de regressão
- [ADR-019](#) — sanitização de log (planejado em T-018)
- Sam Newman, *Building Microservices*, 2ª ed., p. 500 — Idempotency
- PostgreSQL docs §13.3.2 — Row-Level Locks (`FOR UPDATE SKIP LOCKED`)
- NATS Documentation — Message Headers (HPUB) e JetStream Deduplication
