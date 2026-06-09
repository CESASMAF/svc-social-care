# ADR-022: JSONB para payloads, TIMESTAMPTZ para operacionais, DATE para conceituais; encoder/decoder JSON padronizado

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** parcialmente `2026_03_13_ConvertJsonbToText` (que demoteu JSONB → TEXT como workaround)
**Parent:** [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md) (Fase 4)

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achados convergentes:

- **DB-9** (DB Modeling Review): `outbox_messages.payload` e
  `audit_trail.payload` foram convertidos para `TEXT` em
  `ConvertJsonbToText` (2026-03-13) para contornar mismatch de bind do
  PostgresKit (`.model()` envia String). Custo: queries
  `WHERE payload->>'eventType' = 'X'` deixam de ser indexáveis;
  operadores JSONB (`->`, `->>`, `@>`, `?`) não funcionam em TEXT.
- **DB-10** (DB Modeling Review): várias colunas operacionais usam
  `TIMESTAMP` (sem timezone). PostgreSQL armazena sem TZ assumindo o
  TZ do servidor — ambíguo em deploy multi-região (BRT staging vs UTC
  prod) e em migração entre ambientes.
- **DB-16** (DB Modeling Review): colunas que carregam **data
  conceitual** (sem hora) como `birth_date`, `rg_issue_date`,
  `patient_diagnoses.date` usam `TIMESTAMP`. Confunde o domínio: data
  de nascimento não tem hora; armazená-la como TIMESTAMP plant `00:00:00`
  espúrio (que vira "00:00 UTC" e exibe como "21:00 do dia anterior" em
  BRT).
- **S-H-P7** (Senior Code Review § P7): `JSONEncoder()` ad-hoc em vários
  sites (mappers, HTTP middlewares, NATS publisher, controllers) com
  `dateEncodingStrategy` default (`.deferredToDate` = Double desde
  2001). Audit trail e payloads do outbox acumularam Date em formatos
  distintos.

```swift
// Pré-fix — espalhamento de encoders
// PatientDatabaseMapper.swift
private static let encoder = JSONEncoder()  // ← .deferredToDate (Double)

// configure.swift (correto, mas isolado)
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601

// NATSEventPublisher.swift (correto, mas isolado)
let enc = JSONEncoder()
enc.dateEncodingStrategy = .iso8601

// AppErrorMiddleware.swift
JSONEncoder().encode(...)  // ← .deferredToDate
```

```sql
-- Pré-fix
outbox_messages.payload  TEXT       -- não-queryable como JSON
audit_trail.payload      TEXT       -- idem
patient_diagnoses.date   TIMESTAMP  -- "data" mas com hora 00:00 espúria
patients.birth_date      TIMESTAMP  -- idem
patients.rg_issue_date   TIMESTAMP  -- idem
social_care_appointments.date         TIMESTAMP  -- instante sem TZ
referrals.date                        TIMESTAMP
rights_violation_reports.report_date  TIMESTAMP
outbox_messages.occurred_at           TIMESTAMP
```

### Por que isso importa

1. **Queries forenses no audit trail ficam impossíveis** — operação
   "todas as alterações de housing_condition do paciente X" exige
   `WHERE event_type = 'HousingConditionUpdated' AND payload->>'patientId' = '<id>'`
   e isso é O(n) full scan em TEXT.
2. **Migração entre staging e prod expõe diferença de TZ** — TIMESTAMP
   sem TZ vira `2024-01-26 14:00:00` literal. Staging em BRT
   interpreta como BRT; prod em UTC interpreta como UTC; mesmo valor
   "literal", instantes diferentes.
3. **Date de nascimento muda no fuso horário do display** — `2000-05-14
   00:00:00` em UTC vira `1999-05-13 21:00:00` em BRT. Cálculo de
   idade fica wrong por 1 dia em pessoas nascidas no início do mês.
4. **Audit trail mente** — Date como Double `746409600.0` ilegível para
   humanos; `2024-01-26T12:00:00Z` legível. Investigação de incidente
   precisa decodificar.

### Citações canônicas

> *"Always use TIMESTAMPTZ. Always. There are no good reasons to use
> TIMESTAMP. PostgreSQL TIMESTAMP without TZ is one of the most
> commonly misunderstood types in the database."*
> — Heikki Linnakangas, PostgreSQL committer
> ([archived blog](https://www.depesz.com/2014/04/04/dont-use-without-time-zone/))

> *"Use `DATE` for conceptual dates (birth, payment due, contract
> start). Use `TIMESTAMPTZ` for events. Never use `TIMESTAMP`. The
> middle ground is a trap."*
> — Markus Winand, *SQL Performance Explained*

> *"Standardize your JSON encoder. Otherwise, your API responses, your
> audit trail, and your message payloads will use three different
> formats — and at least one will be wrong."*
> — Sandi Metz / Sam Newman, *Building Microservices*

## Decisão

### 1. Migration `2026_05_14_RestoreJsonbAndTemporalTypes`

```sql
-- (a) Payload JSONB
ALTER TABLE outbox_messages ALTER COLUMN payload TYPE JSONB USING payload::jsonb;
ALTER TABLE audit_trail     ALTER COLUMN payload TYPE JSONB USING payload::jsonb;

-- (b) Operacionais TIMESTAMPTZ
ALTER TABLE social_care_appointments      ALTER COLUMN date          TYPE TIMESTAMPTZ USING date AT TIME ZONE 'UTC';
ALTER TABLE referrals                     ALTER COLUMN date          TYPE TIMESTAMPTZ USING date AT TIME ZONE 'UTC';
ALTER TABLE rights_violation_reports      ALTER COLUMN report_date   TYPE TIMESTAMPTZ USING report_date AT TIME ZONE 'UTC';
ALTER TABLE rights_violation_reports      ALTER COLUMN incident_date TYPE TIMESTAMPTZ USING incident_date AT TIME ZONE 'UTC';
ALTER TABLE outbox_messages               ALTER COLUMN occurred_at   TYPE TIMESTAMPTZ USING occurred_at AT TIME ZONE 'UTC';
ALTER TABLE outbox_messages               ALTER COLUMN processed_at  TYPE TIMESTAMPTZ USING processed_at AT TIME ZONE 'UTC';

-- (c) Conceituais DATE
ALTER TABLE patients          ALTER COLUMN birth_date    TYPE DATE USING birth_date::date;
ALTER TABLE patients          ALTER COLUMN rg_issue_date TYPE DATE USING rg_issue_date::date;
ALTER TABLE family_members    ALTER COLUMN birth_date    TYPE DATE USING birth_date::date;
ALTER TABLE patient_diagnoses ALTER COLUMN date          TYPE DATE USING date::date;
```

`revert()` simétrico restaura tipos antigos. Conversão é compatível
(banco aceita re-cast nos dois sentidos).

### 2. `shared/JSON/JSONCodec.swift` — porta única

```swift
public enum JSONCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return decoder
    }()
}
```

Toda camada IO/HTTP usa `JSONCodec.encoder` / `JSONCodec.decoder`.
Encoders ad-hoc viram dívida documentada (migração incremental).

### 3. Repository INSERT usa cast `::jsonb` explícito

```swift
// SQLKitPatientRepository — outbox
for message in outboxMessages {
    try await tx.raw("""
        INSERT INTO outbox_messages (id, event_type, payload, occurred_at, processed_at)
        VALUES (\(bind: message.id), \(bind: message.event_type), \(bind: message.payload)::jsonb, \(bind: message.occurred_at), \(bind: message.processed_at))
    """).run()
}

// SQLKitOutboxRelay — audit_trail
try await tx.raw("""
    INSERT INTO audit_trail (id, outbox_message_id, ..., payload, ...)
    VALUES (..., \(bind: entry.payload)::jsonb, ...)
""").run()
```

`.model()` daria erro de tipo (PostgresKit envia String; coluna espera
JSONB). SQL raw é a única forma de fazer o cast no bind.

### Antes vs depois

```sql
-- Pré-fix
outbox_messages.payload TEXT
SELECT * FROM outbox_messages WHERE payload LIKE '%"patientId":"<x>"%';
-- O(n) full scan; sem índice utilizável

-- Pós-fix
outbox_messages.payload JSONB
SELECT * FROM outbox_messages WHERE payload->>'patientId' = '<x>';
-- Pode receber índice GIN: CREATE INDEX ... USING GIN ((payload->>'patientId'))
```

```swift
// Pré-fix — encoders ad-hoc
private static let encoder = JSONEncoder()  // .deferredToDate

// Pós-fix — porta única
JSONCodec.encoder.encode(...)  // .iso8601 garantido
```

## Alternativas consideradas

- **Manter TEXT + parse no app.** Descartada — performance ruim
  (full scan em audit trail), perde operadores nativos JSONB
  (`@>` containment check, `?` key existence).
- **JSONB com bind `.model()` + custom encoder do PostgresKit.**
  PostgresKit não suporta cast automático para JSONB. Override seria
  trabalho de upstream. SQL raw com `::jsonb` é o caminho idiomático.
- **`JSONB` apenas em audit_trail (não em outbox).** Considerada;
  outbox tem padrão similar de query forense ("último evento publicado
  do tipo X"); migrar os dois ao mesmo tempo é mais barato.
- **TIMESTAMPTZ para `birth_date`.** Descartada — data de nascimento
  é conceito sem timezone. Brasileiro nascido às `23:00 BRT` em
  31/12/1999 não muda de ano por causa do fuso. `DATE` representa
  isso corretamente.
- **`TIMETZ`.** Não aplicável — não temos colunas só-hora.
- **Migrar todos os encoders ad-hoc no mesmo PR.** Adiada — escopo
  grande (~10 sites). `JSONCodec` está disponível; migração
  incremental segue.

## Consequências

### Positivas

- **DB-9 fechado** — payload é JSONB indexável; queries forenses no
  audit funcionam.
- **DB-10 fechado** — TIMESTAMPTZ universal em operacionais;
  ambiguidade de fuso some.
- **DB-16 fechado** — DATE em conceituais; cálculo de idade é correto
  por 24h, não 24h±3h.
- **S-H-P7 fechado** — `JSONCodec.encoder/decoder` é a porta
  única. Audit trail futuro fica consistente.
- **Operadores JSONB nativos disponíveis** — `payload->>'X'`,
  `payload @> '{"X":Y}'`, `payload ? 'X'`. Habilita índices GIN
  funcionais para subscribers seletivos (T-025).
- **NATS publisher pode parar de duplicar `dateEncodingStrategy =
  .iso8601`** — usar `JSONCodec.encoder` direto.

### Negativas / custos

- **Migração in-place ALTER COLUMN TYPE** adquire ACCESS EXCLUSIVE
  lock. Para volume produção significativo, considerar shadow column
  ou `pg_repack`. Decisão consciente: dev/staging volume baixo.
- **Cast `::jsonb` no INSERT é boilerplate** em SQL raw. Vale o
  trade-off — alternativa (JSONB type adapter no PostgresKit) é
  trabalho upstream caro.
- **Encoders ad-hoc legacy continuam** — migração incremental fica no
  backlog. Lint estrutural futuro pode enforçar `JSONCodec.encoder`
  obrigatório.
- **`AT TIME ZONE 'UTC'`** assume valores antigos foram gravados em
  UTC. Se algum deploy gravou em BRT (raro pré-prod), valor desloca
  ±3h. Aceitável em pré-prod.

### Ações requeridas

- [x] Migration `2026_05_14_RestoreJsonbAndTemporalTypes` criada
- [x] Migration registrada em `configure.swift`
- [x] `shared/JSON/JSONCodec.swift` criado
- [x] `SQLKitPatientRepository` faz INSERT outbox com cast `::jsonb`
- [x] `SQLKitOutboxRelay` faz INSERT audit_trail com cast `::jsonb`
- [x] 10 testes de regressão (8 lints + 2 sanity)
- [x] Skill `swift-io-implementer` atualizada (entrada 14)
- [ ] **Backlog incremental:** migrar encoders ad-hoc para
  `JSONCodec` (mappers, NATS publisher, AppErrorMiddleware,
  controllers). Ganho: consistência. Custo: 1 PR.
- [ ] **Backlog operacional:** validar em staging que migração corre
  sem locktimeout em volume realista.
- [ ] **Próximo ticket relevante:** T-025 (índice GIN em
  `outbox_messages.payload->>'eventType'` para subscribers seletivos
  agora possível).

## Plano de adoção

1. **Imediato (T-022):** schema migrado, helper criado, repository
   adaptado. Suite 426/426 verde.
2. **Próximo deploy:** migration roda automaticamente no boot
   (`MigrationRunner` itera lista). Conversão é compatível.
3. **T-025 (futuro):** índice GIN em `outbox_messages.payload`
   habilita subscribers seletivos eficientes.
4. **Migração incremental dos encoders:** em refactors futuros,
   substituir `JSONEncoder()` por `JSONCodec.encoder` ao tocar o
   arquivo.

## Como reverter

`Migration.revert()` simétrico volta todos os tipos. Code reverter:

1. `git revert` do commit do ticket — repository volta a `.model()`,
   helper sumiria.
2. `swift run migration revert RestoreJsonbAndTemporalTypes`.
3. Marcar este ADR como `Deprecado`.

Não recomendado — reabre todos os 4 achados.

## Teste de regressão

`Tests/social-care-sTests/Regression/DataIntegrity/JsonbAndTemporalTypesTests.swift`:

1. **`test_DB_9_outbox_payload_jsonb`** — lint: alguma migration tem
   `ALTER TABLE outbox_messages ALTER COLUMN payload TYPE JSONB`.
2. **`test_DB_9_audit_payload_jsonb`** — lint: idem para
   `audit_trail.payload`.
3. **`test_DB_10_timestamptz_migration_exists`** — lint: alguma
   migration usa `AT TIME ZONE` para promover TIMESTAMP → TIMESTAMPTZ.
4. **`test_DB_16_birth_date_to_date`** — lint: migration converte
   `birth_date` para DATE.
5. **`test_DB_16_rg_issue_date_to_date`** — idem `rg_issue_date`.
6. **`test_DB_16_diagnosis_date_to_date`** — idem
   `patient_diagnoses.date`.
7. **`test_S_H_P7_jsoncodec_exists`** — lint: `JSONCodec.swift` existe
   em `shared/JSON/`.
8. **`test_S_H_P7_jsoncodec_api`** — lint: declara `JSONCodec`, expõe
   `encoder`/`decoder`, força `.iso8601`.
9. **`test_S_H_P7_jsoncodec_iso8601_round_trip`** — runtime: encode
   produz string ISO 8601 (não Double); round-trip preserva valor.
10. **`test_DB_9_repo_inserts_jsonb_with_cast`** — lint: repository
    contém `::jsonb` (SQL raw com cast explícito).

10/10 passam pós-fix.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` —
  entrada 14 em "Lições Aprendidas".
- **Regra resumida — Padrão Temporal & Payload:**

  | Conceito | Tipo SQL | Swift |
  |---|---|---|
  | Instante operacional (timestamp evento, audit, outbox) | `TIMESTAMPTZ` | `Date` / `TimeStamp` |
  | Data conceitual sem hora (nascimento, vencimento, diagnóstico) | `DATE` | `Date` (componentes só dia) |
  | Payload estruturado (audit, outbox, JSON column) | `JSONB` | `String` (JSON serializado) bind via `::jsonb` |
  | Payload opaco/legado | NUNCA `TEXT` para JSON | — |

  - **TIMESTAMP sem TZ proibido.** `TIMESTAMPTZ` universal — banco
    armazena UTC, converte na apresentação. `AT TIME ZONE 'UTC'` na
    promoção (assume valores antigos em UTC).
  - **`JSONB` com bind exige cast `::jsonb`** — PostgresKit envia String;
    coluna espera JSONB. SQL raw com `\(bind: payload)::jsonb` é o
    caminho idiomático. `.model()` falha.
  - **Encoder JSON único:** `JSONCodec.encoder` /
    `JSONCodec.decoder` em `shared/JSON/` com `.iso8601` em ambos.
    Encoder ad-hoc gera dívida — migrar incrementalmente.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § P7
- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` §§ DB-9,
  DB-10, DB-16
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-022
- [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md) — Fase 4
- [ADR-013](ADR-013-outbox-for-update-skip-locked.md) — relay processa
  outbox; agora payload JSONB indexável
- [ADR-015](ADR-015-audit-trail-distinct-id-from-outbox.md) — audit
  trail; agora payload JSONB
- [ADR-017](ADR-017-log-sanitizer-no-pii-in-logs.md) — log sanitizer;
  ortogonal mas relacionado
- `2026_03_13_ConvertJsonbToText.swift` — migration revertida (mas
  preservada como histórico)
- Heikki Linnakangas — "Don't use TIMESTAMP without TIME ZONE"
  ([depesz blog](https://www.depesz.com/2014/04/04/dont-use-without-time-zone/))
- Markus Winand, *SQL Performance Explained*
- Sam Newman, *Building Microservices* 2ª ed.
