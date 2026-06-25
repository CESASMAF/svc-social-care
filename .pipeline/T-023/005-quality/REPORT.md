# T-023 — W3 Quality Gates

**Data:** 2026-05-14
**Achados:** S-H-P5 (Senior Code Review § P5) + DB-17 (DB Modeling Review)
**Fase:** 4 (Decomposição de Patient) — quarto ticket
**Parent ADR:** ADR-019

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 49.30s, 0 warnings novos |
| Full test suite | ✅ **432/432** passam, 0.140s |
| Regression suite | ✅ 128 testes em 21 suites (+6 do T-023) |
| Testes T-023 | ✅ **6/6** passam (5 lints + 1 sanity de design) |
| ADR-023 | ✅ |
| DECISIONS.md index | próximo ID = **024** | ✅ |
| Skill `swift-io-implementer` | entrada 15 em "Lições Aprendidas" | ✅ |

## Arquivos criados

**Sources:**
- `Sources/.../IO/Persistence/SQLKit/Migrations/2026_05_14_AddCreatedUpdatedAtToRootTables.swift` — declara função PL/pgSQL `touch_updated_at()` + adiciona `created_at`/`updated_at` + TRIGGER em 5 tabelas raiz; `revert()` simétrico.

**Testes:**
- `Tests/.../Regression/DataIntegrity/TemporalAuditTests.swift` — 6 testes (5 lints + 1 sanity de design)

**Handbook + skill:**
- `handbook/architecture/DECISIONS/ADR-023-created-updated-at-on-root-tables.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-023 indexado; próximo ID = **024**
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 15

## Arquivos modificados

**Bootstrap:**
- `IO/HTTP/Bootstrap/configure.swift` — `AddCreatedUpdatedAtToRootTables()` registrada na lista de migrations.

## Mudanças de schema

**Função única:**
```sql
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;
```

**Aplicado em 5 tabelas raiz (loop em `rootTables: [String]`):**
- `patients` — aggregate root
- `patient_diagnoses` — entidade-filha com PK surrogate
- `social_care_appointments` — idem
- `referrals` — idem
- `rights_violation_reports` — idem

Cada uma ganha:
- `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
- `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
- `TRIGGER <table>_updated_at BEFORE UPDATE EXECUTE FUNCTION touch_updated_at()`

## Decisões arquiteturais

1. **Função única reusada por todos os triggers** — `CREATE OR REPLACE` torna idempotente; complexidade baixa; manutenção centralizada.
2. **Trigger por tabela, não global** — evita ativação em tabelas que não têm `updated_at`. Trade-off: mais triggers; vale pela explicitude.
3. **Models Swift NÃO declaram essas colunas** — banco gerencia. `.model()` enviaria NULL e contraria `NOT NULL DEFAULT NOW()`; Mirror reflection do `upsertChildren` sobrescreveria via SET excluded.
4. **Apenas tabelas raiz (não filhas associativas)** — filhas regeneradas a cada save do parent não têm semântica útil para `created_at`. Operacionais com timestamps próprios (`outbox`, `audit_trail`) já cobertos.
5. **Loop em array `rootTables`** — adicionar tabela é trivial (1 linha no array). Lint estrutural verifica que cada raiz está no array.
6. **`audit_trail` continua existindo, é COMPLEMENTAR** — registra evento de domínio. `updated_at` cobre escrita não-aplicacional (SQL direto, ETL, restore).

## Antes vs depois

```sql
-- Pré-fix
SELECT MAX(occurred_at) FROM audit_trail
 WHERE aggregate_id = '<patient_id>'
   AND aggregate_type = 'Patient';
-- O(n) full scan + JOIN. Cobre só operações via app.

-- Pós-fix
SELECT updated_at FROM patients WHERE id = '<patient_id>';
-- O(1) via PK. Cobre TODA escrita (app, SQL, ETL, restore).
```

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-022 (já reportados) | 20 fechados | 21 ADRs + ADR-019 (meta) | 122 testes |
| T-023 | S-H-P5 + DB-17 | ADR-023 | 6 |
| **Total** | **21 fechados** | **23 ADRs** | **128 regression tests** |

## Backlog gerado / habilitado

1. **Habilitado:** migrar `family_members` e `family_member_required_documents` para ON CONFLICT em PK composta (item 1 do backlog T-021). Requer adicionar `updated_at` a `family_members` se for desejado audit operacional ali.
2. **Operacional:** dashboard Grafana com métricas baseadas em `updated_at` (rows modificadas nas últimas 24h, etc.).
3. **Opcional:** considerar inclusão de lookups (`dominio_*`, `lookup_requests`) na próxima janela.

## Próximos tickets sugeridos (Fase 4)

- **T-024.a** — Decomposição em `PatientAssessment` (8 módulos opcionais).
- **T-024.b** — Decomposição em `ProtectionRecord`.
- **T-024.c** — Decomposição em `CareJourney`.
- **T-025+ Fase 5** — UoW + lookups + polish.
