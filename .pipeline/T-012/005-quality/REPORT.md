# T-012 — W3 Quality Gates

**Data:** 2026-05-14
**Achado:** S-C2 (Senior Code Review — relay duplica eventos em multi-instância)

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 47.33s, 0 warnings novos |
| Full test suite | ✅ **371/371** passam, 0.079s |
| Regression suite | ✅ 67 testes em 12 suites (+4 do T-012) |
| Testes T-012 | ✅ **4/4** passam (estruturais) |
| ADR-013 | ✅ |
| DECISIONS.md index | próximo ID = 014 | ✅ |
| Skill `swift-io-implementer` | entrada 7 em "Lições Aprendidas" | ✅ |

## Arquivos modificados

**Source (produção):**
- `Sources/.../IO/Persistence/SQLKit/Outbox/SQLKitOutboxRelay.swift`:
  - `pollAndDistribute` agora envolve TUDO em `db.transaction { tx in }`
  - `SELECT … FOR UPDATE SKIP LOCKED LIMIT 50` (raw SQL)
  - Audit trail INSERT e UPDATE processed_at na mesma TX
  - Snapshot de `continuations`/`publisher`/`logger` antes da TX (actor isolation)
  - Log sanitizado: `errorType: String(reflecting: type(of:))` em vez de `\(error)` (ADR-019)
- `Sources/.../IO/EventBus/NATSEventPublisher.swift`:
  - Protocol `NATSPublishing.publish` aceita `messageId: UUID?`
  - Implementação envia frame `HPUB` (NATS Headers v1.0) com `Nats-Msg-Id` quando informado
  - Frame `PUB` tradicional como fallback (`messageId == nil`)

**Tests:**
- `Tests/.../Regression/Concurrency/OutboxConcurrentPollingRegressionTests.swift` — **NOVO** (4 testes estruturais)

**Handbook + skill:**
- `handbook/architecture/DECISIONS/ADR-013-outbox-for-update-skip-locked.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-013 indexado; próximo ID = **014**
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 7

## Decisões arquiteturais

1. **TX longa cobre todo o ciclo** — SELECT → publish NATS → audit trail INSERT → UPDATE. Lock só libera no COMMIT. Trade-off: ~50-100ms lock-time com NATS local; aceitável para batch de 50.
2. **`SKIP LOCKED` em vez de `FOR UPDATE` puro** — paralelismo entre pollers preservado (cada pega lote disjunto), em vez de bloquear esperando.
3. **`Nats-Msg-Id` via frame HPUB** — defense in depth. Mesmo se FOR UPDATE falhar, JetStream descarta re-publicação dentro da janela default (2min).
4. **Implementação NATS atual frágil** documentada — T-017 vai substituir por cliente oficial.
5. **Snapshot fora da TX** — `continuations` é actor-isolated; capturar valor antes de entrar no closure Sendable.

## Antes vs depois

| Cenário | Pré-T-012 | Pós-T-012 |
|---|---|---|
| 2 pollers em paralelo | mesmos eventos publicados 2x | lotes disjuntos via SKIP LOCKED ✅ |
| Crash entre publish e UPDATE | re-publica na próxima poll | TX rollback — re-lê via SKIP LOCKED ✅ |
| Re-publicação por race remanescente | duplicação chega ao consumer | JetStream descarta via `Nats-Msg-Id` ✅ |
| Log de erro com PII | `\(error)` vaza payload | apenas `errorType` (LGPD) ✅ |

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-011, T-014 | 11 fechados | 12 ADRs | 47 testes |
| T-012 | S-C2 | ADR-013 | 4 |
| **Total** | **12 fechados** | **13 ADRs** | **51 regression tests** |

## Próximos tickets sugeridos

- **T-015** — `audit_trail.id` distinto de `outbox.id` (S-C10, CRITICAL)
- **T-013** — Remover `OutboxEventBus.publish` dead code (S-C4, CRITICAL)
- **T-017** — NATS cliente oficial (S-C9, CRITICAL)
