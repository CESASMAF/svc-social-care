# T-018 — W3 Quality Gates

**Data:** 2026-05-14
**Achado:** S-H-IO5 (Senior Code Review) + S-H-P6 (DB Modeling Review) — log de erro vazava PII em camadas IO/HTTP/EventBus/Persistence

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 45.36s, 0 warnings novos |
| Full test suite | ✅ **393/393** passam, 0.071s |
| Regression suite | ✅ 89 testes em 16 suites (+9 do T-018) |
| Testes T-018 | ✅ **9/9** passam (lints estruturais + sanity) |
| ADR-017 | ✅ |
| DECISIONS.md index | próximo ID = **018** | ✅ |
| Skill `swift-io-implementer` | entrada 10 em "Lições Aprendidas" | ✅ |

## Arquivos criados

**Sources:**
- `Sources/.../shared/Error/LogSanitizer.swift` — porta única de sanitização. Enum com `metadata(for:)`, `summary(for:)`, neutralização de control chars, truncamento em 200 chars.

**Testes:**
- `Tests/.../Regression/Security/NoPiiInLogTests.swift` — 9 testes (2 sanity do sanitizer + 7 lints estruturais por camada)

**Handbook + skill:**
- `handbook/architecture/DECISIONS/ADR-017-log-sanitizer-no-pii-in-logs.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-017 indexado; próximo ID = **018**
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 10

## Arquivos modificados

**Sources (6 arquivos, 8 ocorrências):**

| Arquivo | Antes | Depois |
|---|---|---|
| `IO/Persistence/SQLKit/Outbox/SQLKitOutboxRelay.swift` (×2) | `metadata: ["error": "\(error)"]` | `metadata: LogSanitizer.metadata(for: error)` |
| `IO/HTTP/Middleware/JWTAuthMiddleware.swift` | `"JWT verify falhou: \(error)"` | `"JWT verify falhou", metadata: LogSanitizer.metadata(for: error)` |
| `IO/HTTP/Middleware/AppErrorMiddleware.swift` | `"Unhandled error: \(error)"` | `"Unhandled error", metadata: LogSanitizer.metadata(for: error)` |
| `IO/HTTP/Controllers/HealthController.swift` | `"Readiness check failed: \(error)"` | `"Readiness check failed", metadata: LogSanitizer.metadata(for: error)` |
| `IO/EventBus/NATSEventPublisher.swift` (×3) | `"Failed to connect: \(error)"` / `throw NATSError.connectionFailed("...\(error)")` / `"channel error: \(error)"` | `metadata: LogSanitizer.metadata(for: error)` / `LogSanitizer.summary(for: error)` |
| `IO/EventBus/NATSEventSubscriber.swift` (×2) | `"NATS subscriber error: \(error) — reconnecting"` / `"Channel error: \(error)"` | `metadata: LogSanitizer.metadata(for: error)` |

## Decisões arquiteturais

1. **Helper explícito vs wrapper logger global** — escolhi `LogSanitizer.metadata(for:)` porque é grep-friendly, testável, sem magic. Wrapper global teria sido mais hard de auditar.
2. **Truncamento em 200 chars + control char neutralization** — defense em camadas. Tipos NIO podem retornar buffer errors gigantes; control chars permitem log injection.
3. **`String(reflecting:)` como fonte canônica do tipo** — qualified type name (ex.: `Foundation.DecodingError`) facilita grep no Loki e tendências por tipo.
4. **Camadas Bootstrap isentas** — startup time, sem PII fluindo. Decisão consciente, documentada no ADR.
5. **Lint estrutural em testes** (não macro/Diagnostic) — Swift 6.3 não tem hook compile-time prático para isso; lint via grep cobre 95% dos casos com zero overhead.
6. **Cobre interpolação tanto em metadata quanto em mensagem** — bug original aparecia nos dois formatos. Lint precisa cobrir os dois para evitar contornar via "vou pôr na mensagem".

## Antes vs depois (Loki)

```jsonc
// Pré-fix
{
  "msg": "Outbox relay poll failed",
  "error": "DecodingError(...payload com CPF=12345678900, nome='Fulano de Tal', endereco='Rua...')"
}

// Pós-fix
{
  "msg": "Outbox relay poll failed",
  "errorType": "Foundation.DecodingError",
  "errorDescription": "The data couldn't be read because it isn't in the correct format."
}
```

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-017 (já reportados) | 15 fechados | 16 ADRs | 80 testes |
| T-018 | S-H-IO5 + S-H-P6 | ADR-017 | 9 |
| **Total** | **16 fechados** | **17 ADRs** | **89 regression tests** |

## Backlog gerado

1. **Runbook de debug local** — como reproduzir payload de erro em staging sem expor em prod (TODO em `handbook/runbook/`).
2. **Dashboard Grafana** — filtro por `errorType` para tendências (PSQLError vs DecodingError vs URLError).

## Próximos tickets sugeridos

- **T-019** — `AnyJSON` enum Sendable (S-H-IO6, HIGH — strict concurrency Swift 6.3)
- **T-020-T-024** (Phase 4) — Decompor god aggregate Patient
- **T-025-T-031** (Phase 5) — UoW + polish
