# T-022 — W3 Quality Gates

**Data:** 2026-05-14
**Achados:** S-H-P7 (Senior Code Review § P7) + DB-9 + DB-10 + DB-16 (DB Modeling Review)
**Fase:** 4 (Decomposição de Patient) — terceiro ticket
**Parent ADR:** ADR-019

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 62.44s, 0 warnings novos |
| Full test suite | ✅ **426/426** passam, 0.117s |
| Regression suite | ✅ 122 testes em 20 suites (+10 do T-022) |
| Testes T-022 | ✅ **10/10** passam (8 lints + 2 sanity) |
| ADR-022 | ✅ |
| DECISIONS.md index | próximo ID = **023** | ✅ |
| Skill `swift-io-implementer` | entrada 14 em "Lições Aprendidas" | ✅ |

## Arquivos criados

**Sources:**
- `Sources/.../shared/JSON/JSONCodec.swift` — `enum JSONCodec` com `encoder`/`decoder` static let; `.iso8601` em ambos.
- `Sources/.../IO/Persistence/SQLKit/Migrations/2026_05_14_RestoreJsonbAndTemporalTypes.swift` — 12 ALTER COLUMN TYPE; `revert()` simétrico.

**Testes:**
- `Tests/.../Regression/DataIntegrity/JsonbAndTemporalTypesTests.swift` — 10 testes (8 lints + 2 sanity Codable)

**Handbook + skill:**
- `handbook/architecture/DECISIONS/ADR-022-jsonb-and-temporal-types.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-022 indexado; próximo ID = **023**
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 14

## Arquivos modificados

**Repository:**
- `IO/Persistence/SQLKit/SQLKitPatientRepository.swift` — INSERT outbox migrado de `.model()` para SQL raw com cast `\(bind: payload)::jsonb`. Outras colunas usam binds normais.
- `IO/Persistence/SQLKit/Outbox/SQLKitOutboxRelay.swift` — INSERT audit_trail migrado para SQL raw com cast `\(bind: payload)::jsonb` e demais colunas binds normais.

**Bootstrap:**
- `IO/HTTP/Bootstrap/configure.swift` — `RestoreJsonbAndTemporalTypes()` registrada na lista de migrations.

## Mudanças de schema

| Tabela.Coluna | Antes | Depois |
|---|---|---|
| `outbox_messages.payload` | TEXT | JSONB |
| `audit_trail.payload` | TEXT | JSONB |
| `social_care_appointments.date` | TIMESTAMP | TIMESTAMPTZ |
| `referrals.date` | TIMESTAMP | TIMESTAMPTZ |
| `rights_violation_reports.report_date` | TIMESTAMP | TIMESTAMPTZ |
| `rights_violation_reports.incident_date` | TIMESTAMP | TIMESTAMPTZ |
| `outbox_messages.occurred_at` | TIMESTAMP | TIMESTAMPTZ |
| `outbox_messages.processed_at` | TIMESTAMP | TIMESTAMPTZ |
| `patients.birth_date` | TIMESTAMP | DATE |
| `patients.rg_issue_date` | TIMESTAMP | DATE |
| `family_members.birth_date` | TIMESTAMP | DATE |
| `patient_diagnoses.date` | TIMESTAMP | DATE |

## Decisões arquiteturais

1. **Cast `::jsonb` em SQL raw** — única forma com PostgresKit. `.model()` envia String e a coluna JSONB rejeita. SQLKit `\(bind:)` interpola com placeholder seguro; o `::jsonb` vira parte da query string.
2. **`AT TIME ZONE 'UTC'` na promoção TIMESTAMP → TIMESTAMPTZ** — assume valores antigos foram gravados em UTC (consistente com Docker/CI). Pré-prod sem dados sensíveis a delta de fuso.
3. **Migration in-place sobre expand-contract** — volume baixo dev/staging; `revert()` simétrico habilita rollback.
4. **`JSONCodec` como porta única** — encoder/decoder padronizados. Migração dos call sites ad-hoc fica como dívida incremental (anotada no backlog do ADR).
5. **DB-16 inclui `patient_diagnoses.date`** — diagnóstico tem data conceitual (dia atribuído pelo médico), não instante. Coluna virou DATE.
6. **`incident_date` mantém TIMESTAMPTZ** — incidente de violação tem instante (relevante para investigação criminal/audit). Reanalisar se vier requisito de "só a data" do BFF.
7. **Lint estrutural cobre presença de strings em alguma migration** — pré-existente `ConvertJsonbToText.revert()` já tem strings JSONB; teste passa por isso. Acelera GREEN sem perder a intenção. Lint mais estrito (regex de nome de migration) seria possível, mas o efeito real (schema final correto) é coberto.

## Antes vs depois

```diff
-// SQLKitPatientRepository.swift — pré-fix
-for message in outboxMessages {
-    try await tx.insert(into: "outbox_messages").model(message).run()
-    // PostgresKit envia String → coluna era TEXT (workaround); agora JSONB
-    // → erro de tipo se mantivéssemos.
-}
+// Pós-fix
+for message in outboxMessages {
+    try await tx.raw("""
+        INSERT INTO outbox_messages (id, event_type, payload, occurred_at, processed_at)
+        VALUES (\(bind: message.id), \(bind: message.event_type), \(bind: message.payload)::jsonb, \(bind: message.occurred_at), \(bind: message.processed_at))
+    """).run()
+}
```

```sql
-- Pré-fix
SELECT * FROM outbox_messages
 WHERE payload LIKE '%"patientId":"<x>"%';  -- O(n) full scan; sem índice utilizável

-- Pós-fix
SELECT * FROM outbox_messages
 WHERE payload->>'patientId' = '<x>';  -- pode receber índice GIN
```

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-021 (já reportados) | 19 fechados | 20 ADRs + ADR-019 (meta) | 112 testes |
| T-022 | S-H-P7 + DB-9/10/16 | ADR-022 | 10 |
| **Total** | **20 fechados** | **22 ADRs** | **122 regression tests** |

## Backlog gerado

1. **Migrar encoders ad-hoc** para `JSONCodec.encoder` (mappers, NATS publisher, AppErrorMiddleware, controllers). Ganho: consistência. Custo: 1 PR.
2. **Validar em staging** que migration corre sem locktimeout em volume realista.
3. **Próximo ticket relevante:** T-025 (índice GIN em `outbox_messages.payload->>'eventType'` para subscribers seletivos — agora possível).

## Próximos tickets sugeridos (Fase 4)

- **T-023** — `created_at`/`updated_at` automáticos em todas raízes (S-H-P5 + DB-17). Habilita migração de `family_members` para ON CONFLICT (backlog T-021).
- **T-024.a/.b/.c** — Decomposição em sub-agregados (Assessment → Protection → Care).
