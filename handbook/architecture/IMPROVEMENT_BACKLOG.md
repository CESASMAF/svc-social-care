# Improvement Backlog — social-care

> **Origem:** avaliação crítica do handbook `melhorias/` do projeto
> `script_test_intern/ia_orquestration/` (orquestrador IA baseado em
> JSONL+kqueue). Boa parte das propostas é específica daquele domínio
> (event stream local em disco) e **não se aplica** a um microserviço HTTP
> com PostgreSQL/Outbox como o `social-care`. As que sobreviveram ao filtro
> estão promovidas a "proposta" aqui.
>
> Data: 2026-05-14. Revisitar quando G1-G17 do `IMPLEMENTATION_PLAN.md`
> fecharem.

---

## Resumo executivo (13 propostas avaliadas)

| # | Proposta original | Veredito | Motivo |
|---:|---|:-:|---|
| 01 | Persist offset entre runs | ⚠️ adaptar | Análogo é Outbox `processed_at` (G16). Conceito relevante mas semantics diferente. |
| 02 | Backpressure AsyncStream | ❌ skip | Projeto é HTTP request/response, não streaming producer/consumer. |
| 03 | Replay desde início | ❌ skip | Não há tail de file; replay de eventos sai do banco quando virar relevante (read-side CQRS). |
| 04 | Rotação de JSONL | ❌ skip | Persistência é PostgreSQL — rotação é responsabilidade do banco (partitioning, retention). |
| 05 | Schema versioning de Event | ✅ **adotar** | `DomainEvent` precisa de `v: Int` antes do primeiro consumer externo do Outbox. Custo XS, ganho alto. |
| 06 | Payload size validation (PIPE_BUF) | ❌ skip | `PIPE_BUF` é específico de pipe POSIX. Vapor já cobre via `routes.defaultMaxBodySize`. |
| 07 | Linux port | ❌ N/A | Serviço já roda Linux (Docker `swift:6.3-jammy`). |
| 08 | Polling fallback FS | ❌ N/A | Não há watcher de filesystem. |
| 09 | Library target separado | ✅ **adotar (preventivo)** | Útil quando `people-context`, `analysis-bi` etc. nascerem e quiserem reusar `Domain/Kernel/` (CPF, NIS, AppError). Custo XS. |
| 10 | Encryption at rest (LGPD) | ⚠️ delegar / ADR pendente | Em geral fica com o managed Postgres (cloud-side AES-256). Coluna a coluna para CPF/NIS exige decisão dedicada — criar ADR antes do PROD. |
| 11 | Métricas Prometheus | ✅ **adotar** | Microserviço HTTP em Kubernetes precisa de `/metrics`. Combina com swift-metrics + swift-prometheus exporter. Casa com gap G12 (request logging). |
| 12 | Retry + DLQ | ✅ **adotar (encaixa em G2)** | OutboxRelay (G2 aberto) já precisa retry policy e DLQ. Adotar a ideia ao implementar G2. |
| 13 | Memória física cross-IA | ❌ skip | Conceito específico de orquestrador IA, não de backend transacional. |

**Promovidas:** 05, 09, 11, 12 (+ 01 e 10 com semantics adaptada).
**Skipped:** 02, 03, 04, 06, 07, 08, 13.

---

## Promovidas — detalhe

### #05 — Schema versioning de `DomainEvent`

**Status:** proposta | **Prioridade:** alta | **Esforço:** XS (~1h)

#### Problema

`DomainEvent` em `shared/Domain/DomainProtocols.swift` declara só `id: UUID`
e `occurredAt: Date`. Cada evento concreto (`PatientRegistered`,
`SocialIdentityUpdated`, etc.) define payload livre. Quando o payload mudar
(campo renomeado, removido), consumers externos do Outbox e replays
históricos quebram silenciosamente.

#### Proposta

Adicionar `var schemaVersion: Int { get }` em `DomainEvent`. Eventos
concretos declaram `let schemaVersion: Int = 1`. Outbox grava como coluna
ao lado do payload. Consumers decodificam por versão.

```swift
public protocol DomainEvent: Sendable {
    var id: UUID { get }
    var occurredAt: Date { get }
    var schemaVersion: Int { get }   // novo — default via extension
}

extension DomainEvent {
    public var schemaVersion: Int { 1 }
}

public struct PatientRegistered: DomainEvent {
    public let id: UUID
    public let occurredAt: Date
    public let patientId: PatientId
    public let actorId: String
    public let schemaVersion: Int = 1
}
```

#### Trade-offs

- **+ Forward compat barato** — futuras mudanças sem quebrar consumer.
- **+ Decode early-fail** — versão desconhecida vira erro explícito, não
  partial decode silencioso.
- **− Disciplina** — quem mudar payload precisa bumpar versão. Cobrir com
  code review checklist + lint custom se virar fricção.

#### Quando faz sentido

**Agora** — antes de qualquer consumer externo real do Outbox (G2). Custo
é mínimo e fechar a porta depois custa muito mais.

#### Plano

1. Adicionar `schemaVersion` em `DomainEvent` + default `1` via extension.
2. Migrar coluna `outbox_events` para incluir `schema_version: int not null
   default 1`.
3. Doc em `handbook/architecture/README.md` §3 (Camadas) — Event schema
   é contrato externo.
4. Teste: decode com versão desconhecida → throws `EventDecodeError.unsupportedVersion(99)`.

---

### #09 — Library target separado

**Status:** proposta | **Prioridade:** média | **Esforço:** XS (~1h)

#### Problema

`Package.swift` tem só `executableTarget(name: "social-care-s")`. Quando os
serviços irmãos (`people-context`, `analysis-bi`, `form-conversions`,
`queue-manager`) começarem a existir, vão querer reusar:

- `Domain/Kernel/` — CPF, NIS, CEP, RGDocument, LookupId, etc.
- `shared/Error/AppError.swift` — contrato de erro padronizado
- `shared/Domain/DomainProtocols.swift` — `Command`, `Query`, `DomainEvent`

Hoje, sem library target, qualquer reuso obriga a importar o executable
inteiro (impossível na prática).

#### Proposta

Separar em dois targets:

```swift
.target(
    name: "ACDGKit",
    path: "Sources/ACDGKit"
),
.executableTarget(
    name: "social-care-s",
    dependencies: ["ACDGKit", ...],
    path: "Sources/social-care-s"
),
```

Mover para `ACDGKit/`:

- `shared/Error/AppError.swift`
- `shared/Domain/DomainProtocols.swift`
- `shared/Error/PersistenceConflictError.swift`
- `Domain/Kernel/` (10 VOs)

Manter no executable:

- `Domain/Registry/`, `Domain/Assessment/`, `Domain/Care/`, `Domain/Protection/`
  (são domain-specific do social-care)
- Toda a Application/
- Toda a IO/

#### Trade-offs

- **+ Preventivo** — quando o primeiro irmão nascer, custo já está pago.
- **+ Clean boundary** — `ACDGKit` é a "linguagem comum" da plataforma.
- **− Repo split eventual** — se `ACDGKit` virar repo próprio, isso é o
  primeiro passo natural.
- **− Pouca fricção real hoje** — adia até primeiro caso de uso se preferir.

#### Quando faz sentido

- Antes do primeiro irmão consumir VOs ou `AppError`.
- **Recomendação:** adotar quando começar o `people-context` (parecido com
  ADR-022 do frontend, que reorganizou em kernel/infra/apps preventivamente).

---

### #11 — Métricas Prometheus em `/metrics`

**Status:** proposta | **Prioridade:** média | **Esforço:** S (~half day)

#### Problema

Hoje a única observabilidade é log via `req.logger`. Em produção
Kubernetes (Flux CD em `edge-cloud-infra/`):

- não há `/metrics` para Prometheus scraping
- não dá pra alertar sobre throughput, latência, taxa de erro 5xx, latência
  de Outbox
- Grafana dashboard fica sem dados

Gap G11/G12 do `IMPLEMENTATION_PLAN.md` já menciona "graceful shutdown"
e "request logging" — métricas é a peça paralela.

#### Proposta

Adotar `swift-metrics` (apple/swift-metrics — abstração canônica, já é
transitive dep via NIO) + `swift-prometheus` (exporter):

```swift
import Metrics
import Prometheus

// configure.swift
let registry = PrometheusCollectorRegistry()
MetricsSystem.bootstrap(PrometheusMetricsFactory(registry: registry))
app.get("metrics") { req -> Response in
    var buffer = ByteBuffer()
    try registry.emit(into: &buffer)
    return Response(status: .ok, body: .init(buffer: buffer))
}
```

Métricas mínimas:

- `http_requests_total{method,route,status}` — counter
- `http_request_duration_seconds{method,route}` — histogram
- `outbox_pending_events` — gauge
- `outbox_relay_attempts_total{outcome}` — counter
- `domain_validation_errors_total{bc,kind}` — counter (alimenta de AppError)

#### Trade-offs

- **+ Operável em K8s** — Prometheus scraping é padrão de mercado.
- **+ Sem novo runtime** — usa o próprio Vapor.
- **− Dep nova** — `swift-prometheus` (Apple-maintained, ~1k stars).
  Aceitável.

#### Quando faz sentido

Antes de o serviço sair de dev local. Casa com gap G6 (health check) e
G12 (request logging).

---

### #12 — Retry policy + Dead Letter Queue (encaixa em G2)

**Status:** proposta | **Prioridade:** alta | **Esforço:** M (~1-2 days)

#### Problema

Gap **G2** do `IMPLEMENTATION_PLAN.md` é "outbox relay real" — hoje o
`OutboxEventBus` em `IO/EventBus/` só persiste; o relay que publica para
fora ainda não existe ou é stub. Quando implementar, precisa decidir:

- O que faz quando o consumer externo (HTTP, broker) retorna 5xx?
- O que faz após N falhas consecutivas?
- Como o operador (humano) inspeciona eventos que falharam permanentemente?

#### Proposta

Implementar o relay com **retry + DLQ embutido**:

**Schema `outbox_events`:**

```sql
ALTER TABLE outbox_events ADD COLUMN attempts INT NOT NULL DEFAULT 0;
ALTER TABLE outbox_events ADD COLUMN max_attempts INT NOT NULL DEFAULT 5;
ALTER TABLE outbox_events ADD COLUMN next_attempt_at TIMESTAMP;
ALTER TABLE outbox_events ADD COLUMN last_error TEXT;
ALTER TABLE outbox_events ADD COLUMN processed_at TIMESTAMP;  -- G16
ALTER TABLE outbox_events ADD COLUMN dlq_at TIMESTAMP;
```

**Loop do relay:**

```swift
1. SELECT * FROM outbox_events
   WHERE processed_at IS NULL
     AND dlq_at IS NULL
     AND (next_attempt_at IS NULL OR next_attempt_at <= now())
   ORDER BY occurred_at
   LIMIT batch_size
   FOR UPDATE SKIP LOCKED;

2. para cada evento:
   try publish externo
   ok → UPDATE SET processed_at = now()
   fail → attempts += 1
          if attempts >= max_attempts:
              UPDATE SET dlq_at = now(), last_error = ...
          else:
              UPDATE SET next_attempt_at = now() + backoff(attempts),
                         last_error = ...
              # backoff exponencial: 1s, 5s, 30s, 2min, 10min
```

**View `dlq_events`** para operador inspecionar; endpoint admin
`POST /admin/outbox/:id/retry` para re-enfileirar manualmente (resetando
`attempts = 0`, `dlq_at = NULL`).

#### Trade-offs

- **+ At-least-once delivery** garantida (idempotência fica com consumer).
- **+ Audit trail** — eventos que falharam permanecem visíveis em DLQ.
- **− Workers idempotentes vira requisito** documentado.
- **− Latência cresce** para eventos com retry.

#### Quando faz sentido

**Adotar ao fechar G2.** Não fazer o relay sem isso — relay sem retry é
"best-effort delivery" silencioso, que é pior do que não ter relay.

---

## Adaptadas (semantics diferente, conceito mantido)

### #01 — Persist offset → Outbox `processed_at` (G16 do plano)

A proposta original endereça crash-recovery de um observer de arquivo. No
social-care, o equivalente é **garantir que o OutboxRelay sabe o que já
publicou** mesmo após crash:

- `processed_at` em `outbox_events` (G16 já no plano)
- `FOR UPDATE SKIP LOCKED` no SELECT do relay garante exclusão mútua entre
  réplicas paralelas
- Combinar com #12 (retry/DLQ) acima

**Não precisa de arquivo sidecar** — Postgres + transação é a forma
canônica. Anotar em G16 que o conceito vem desta proposta.

---

### #10 — Encryption at rest → ADR pendente (LGPD)

Conceito vale, mas a solução é diferente:

- **Disk-level:** managed Postgres (AWS RDS, GCP Cloud SQL, etc.) já oferece
  encryption at rest por default. Confirmar com `edge-cloud-infra/` quando
  decidir o cloud provider.
- **Coluna a coluna (PII sensível — CPF, NIS, RG):** pgcrypto + chave em
  KMS do provider. Custa indexação (CPF criptografado não é searchable em
  igualdade simples sem coluna deterministic) — precisa decisão dedicada.
- **Aplicação:** CryptoKit/swift-crypto se for blob (improvável aqui).

**Ação:** criar `ADR-001-encryption-at-rest.md` em `handbook/architecture/`
**antes** do primeiro deploy em ambiente que toque dado real de paciente.
Hoje (dev local + staging) não bloqueia.

---

## Rejeitadas — justificativa explícita

### #02 — Backpressure AsyncStream

Não há `AsyncStream` no servidor entre producer/consumer in-process.
Backpressure HTTP é via TCP + Vapor request limiting. Skip.

### #03 — Replay desde início

Nenhum consumer atual lê histórico de file. Quando read-side CQRS exigir
projeções rebuild, o caminho é "rebuild from event store" (Postgres) —
não "tail JSONL from beginning". Skip por enquanto.

### #04 — Rotação de JSONL

Persistência é PostgreSQL — partitioning + retention é decisão do banco.
JSONL não existe. Skip.

### #06 — Payload size validation (PIPE_BUF)

`PIPE_BUF` é semântica de pipe POSIX (4096 bytes para escrita atomic em
arquivos abertos com `O_APPEND`). Não se aplica a HTTP body / Postgres
column. Vapor expõe `app.routes.defaultMaxBodySize` para limit de body.
Para colunas JSONB no Postgres, não há limite prático (1GB teórico). Skip.

### #07, #08 — Linux port, polling fallback

Serviço já roda Linux (Docker `swift:6.3-jammy`); não há watcher de FS. N/A.

### #13 — Memória física cross-IA

Conceito específico de orquestrador multi-IA. Backend transacional não
tem essa necessidade — estado durável é Postgres. Skip.

---

## Critério de promoção

Uma proposta vira "aceita" quando:

1. Issue/ticket aberto referenciando este documento.
2. Encaixe em um gap (G1-G17) ou ADR aberto.
3. Trade-offs aceitos pelo dono do código.
4. Custo de oportunidade comparado com o que está no plano atual.

## Histórico de revisão

- **2026-05-14** — criação. Avaliação inicial das 13 propostas vindas de
  `ia_orquestration/handbook/melhorias/`. 4 promovidas (05, 09, 11, 12),
  2 adaptadas (01→G16, 10→ADR pendente), 7 rejeitadas.
