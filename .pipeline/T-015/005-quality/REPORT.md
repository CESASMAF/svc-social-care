# T-015 — W3 Quality Gates

**Data:** 2026-05-14
**Achado:** S-C10 (Senior Code Review — `audit_trail.id` reusa `outbox.id` → batch dies on duplicate)

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 49.30s, 0 warnings novos |
| Full test suite | ✅ **379/379** passam, 0.121s |
| Regression suite | ✅ 75 testes em 14 suites (+5 do T-015) |
| Testes T-015 | ✅ **5/5** passam (lints estruturais) |
| ADR-015 | ✅ |
| DECISIONS.md index | próximo ID = **016** | ✅ |
| Skill `swift-io-implementer` | entrada 8 em "Lições Aprendidas" | ✅ |

## Arquivos criados

**Migrations:**
- `Sources/.../IO/Persistence/SQLKit/Migrations/2026_05_14_AuditTrailDistinctId.swift` — aplica `DEFAULT gen_random_uuid()` em `audit_trail.id`, ADD `outbox_message_id UUID NOT NULL`, CREATE INDEX em `outbox_message_id`. `revert()` simétrico.

**Testes:**
- `Tests/.../Regression/EventPublication/AuditTrailDistinctIdRegressionTests.swift` — 5 testes estruturais

**Handbook + skill:**
- `handbook/architecture/DECISIONS/ADR-015-audit-trail-distinct-id-from-outbox.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-015 indexado; próximo ID = **016**
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 8

## Arquivos modificados

**Sources:**
- `IO/Persistence/SQLKit/Models/PatientDatabaseModels.swift` — `AuditTrailModel` ganha `outbox_message_id: UUID`
- `IO/Persistence/SQLKit/Outbox/SQLKitOutboxRelay.swift` — construtor: `id: UUID()`, `outbox_message_id: message.id` (era `id: message.id`)
- `IO/HTTP/Bootstrap/configure.swift` — registra `AuditTrailDistinctId()` na lista de migrations

**Tests:**
- `Tests/.../IO/AuditTrailTests.swift` — dois call sites do `AuditTrailModel(...)` ganham `outbox_message_id: UUID()`

## Decisões arquiteturais

1. **PK separada + coluna de rastreio** (vs `ON CONFLICT DO NOTHING`) — preserva auditoria como fato observável; re-processamento adiciona row em vez de mascarar.
2. **Sem FK formal `outbox_message_id → outbox_messages.id`** — `outbox_messages` é purgável (retention ~30 dias); audit deve sobreviver à purga. Trade-off documentado no ADR.
3. **`DEFAULT gen_random_uuid()` no schema** — reduz surface de bug do call site (esquecer `UUID()` no construtor não vira PK conflict, vira UUID auto-gerado válido).
4. **Index `idx_audit_trail_outbox_message_id`** — query forense `WHERE outbox_message_id = ?` lista todas as vezes que aquela message foi processada.
5. **Construtor exige `outbox_message_id`** — compilador é primeira linha de defesa contra "esqueci de amarrar a origem".

## Antes vs depois

```diff
 // SQLKitOutboxRelay.swift
 auditEntries.append(AuditTrailModel(
-    id: message.id,                       // ← reusava PK do outbox
+    id: UUID(),                           // ← identidade própria
+    outbox_message_id: message.id,        // ← rastreio explícito
     aggregate_type: "Patient",
     aggregate_id: aggregateId,
     event_type: message.event_type,
     actor_id: parsed.actorId,
     payload: message.payload,
     occurred_at: message.occurred_at,
     recorded_at: now
 ))
```

```sql
-- Migration 2026_05_14_AuditTrailDistinctId
ALTER TABLE audit_trail ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE audit_trail ADD COLUMN outbox_message_id UUID NOT NULL;
CREATE INDEX idx_audit_trail_outbox_message_id ON audit_trail (outbox_message_id);
```

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-014 (já reportados) | 13 fechados | 14 ADRs | 70 testes |
| T-015 | S-C10 | ADR-015 | 5 |
| **Total** | **14 fechados** | **15 ADRs** | **75 regression tests** |

## Próximos tickets sugeridos

- **T-017** — NATS cliente oficial (S-C9, CRITICAL — substitui custom TCP frágil)
- **T-018** — Sanitização de logs LGPD (S-H-IO5, HIGH)
- **T-019** — `AnyJSON` enum Sendable (S-H-IO6, HIGH — strict concurrency)
- **T-020-T-024** (Phase 4) — Decompor god aggregate Patient
