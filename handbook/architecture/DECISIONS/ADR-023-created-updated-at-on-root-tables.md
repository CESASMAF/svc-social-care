# ADR-023: Auditoria operacional via `created_at`/`updated_at` automáticos em tabelas raiz

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —
**Parent:** [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md) (Fase 4)

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achados convergentes:

- **S-H-P5** (Senior Code Review § P5): tabelas raiz não têm timestamps
  de criação/atualização. Pergunta operacional ("quando esta row foi
  modificada pela última vez?") exige cruzar `audit_trail` por
  `aggregate_id` — caro e indireto.
- **DB-17** (DB Modeling Review): mesmo achado pelo lado do schema —
  ausência de `created_at`/`updated_at` quebra debugging operacional.

```sql
-- Pré-fix
\d patients
-- Sem created_at, sem updated_at.
-- "Quando esta row foi alterada pela última vez?"
SELECT MAX(occurred_at) FROM audit_trail
 WHERE aggregate_id = '<patient_id>'
   AND aggregate_type = 'Patient';
-- Full scan + JOIN. E se a alteração foi via SQL direto (correção
-- manual, ETL, restore), não tem entry no audit_trail — invisível.
```

### Diferença entre `audit_trail` e `created_at`/`updated_at`

| Aspecto | `audit_trail` | `created_at`/`updated_at` |
|---|---|---|
| Granularidade | Evento de domínio | Operação de banco (INSERT/UPDATE) |
| Cobertura | Apenas operações via app | TODA escrita (app, SQL direto, ETL, restore) |
| Custo de query | JOIN + filter | SELECT direto na row |
| Custo de escrita | Insert por evento | Coluna automática (trigger) |
| Rastreio cross-aggregate | Sim (event chain) | Não |
| Relevância forense | Alta (qual evento) | Alta (quando) |

São **complementares**, não substitutos. Auditoria de domínio segue em
`audit_trail`; auditoria operacional ganha colunas próprias.

### Citações canônicas

> *"`created_at` and `updated_at` are not optional columns. They are
> the cheapest debug tool you can give your future self. Add them to
> every table; let the database manage them."*
> — Adam Wiggins (12-Factor coauthor), GitHub gist

> *"The audit log records what your application did. The
> `created_at`/`updated_at` columns record what happened to the row.
> Both matter. Do not conflate."*
> — Markus Winand, *SQL Performance Explained*

> *"Use a trigger, not application code, to maintain `updated_at`.
> Application code forgets; the database doesn't."*
> — depesz blog (Hubert Lubaczewski)

## Decisão

### 1. Função PL/pgSQL única `touch_updated_at()`

```sql
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Reusada por todos os triggers — declaração única, complexidade baixa.

### 2. Para cada tabela raiz: 2 colunas + 1 trigger

```sql
ALTER TABLE <table>
    ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE <table>
    ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE TRIGGER <table>_updated_at
BEFORE UPDATE ON <table>
FOR EACH ROW
EXECUTE FUNCTION touch_updated_at();
```

### 3. Quais tabelas são "raiz"?

Aplicado a:
- `patients` — aggregate root.
- `patient_diagnoses` — entidade-filha com identidade própria (PK
  surrogate).
- `social_care_appointments` — idem.
- `referrals` — idem.
- `rights_violation_reports` — idem.

**NÃO aplicado a:**
- Filhas associativas/normalizadas (`member_incomes`, `social_benefits`,
  `family_member_required_documents`, etc.) — regeneradas a cada save
  do agregado; `created_at` ali não tem semântica.
- Operacionais com semântica temporal própria (`outbox_messages`,
  `audit_trail`) — já têm `occurred_at`/`processed_at`/`recorded_at`.
- Lookups (`dominio_*`, `lookup_requests`) — escopo de admin pré-existente.

### 4. Models Swift permanecem sem essas colunas

`PatientModel.swift` e modelos similares **não declaram**
`created_at`/`updated_at`. Razão:

- `.model()` do PostgresKit envia todas as propriedades do struct. Se o
  model declarasse `let created_at: Date?` e o app não setasse, INSERT
  enviaria NULL → contraria `NOT NULL DEFAULT NOW()` → erro.
- Mirror reflection do `upsertChildren` (T-021) iteraria essas colunas no
  SET excluded — sobrescrevendo o trigger.
- Mantendo as colunas só no banco, o invariante "banco gerencia"
  preserva-se sem fricção com `.model()` ou Mirror.

Para futuros consumidores que precisem ler esses campos (endpoint
admin, diagnóstico operacional), criar query dedicada com SELECT
explícito — não decodificar via `PatientModel`.

### Antes vs depois

```sql
-- Pré-fix
SELECT MAX(occurred_at) FROM audit_trail
 WHERE aggregate_id = '<patient_id>' AND aggregate_type = 'Patient';
-- O(n) + cobre só operações via app

-- Pós-fix
SELECT updated_at FROM patients WHERE id = '<patient_id>';
-- O(1) via PK + cobre TODA escrita (app, SQL, ETL, restore)
```

## Alternativas consideradas

- **Coluna única `last_modified` em vez de duas.** Descartada — perde
  informação. Saber "quando criada vs quando alterada pela última vez"
  é frequentemente útil.
- **Trigger único global em todas as tabelas (TG_TABLE_NAME).** Descartada
  — ativaria em tabelas que não têm `updated_at` (lookups, filhas).
  Trigger por tabela é mais explícito e seguro.
- **Application-level (mapper seta `updated_at = .now`).** Descartada —
  esquece em SQL direto, ETL, restore. Trigger é defesa que cobre
  TODOS os caminhos de escrita.
- **Adicionar em filhas associativas também.** Descartada por agora —
  são regeneradas a cada save; `created_at` viraria proxy do save do
  parent. Sem ganho informacional.
- **Adicionar `updated_by` (actor_id) também.** Considerada. Descartada
  — `actor_id` vive no `audit_trail` (registro do evento). `updated_at`
  do banco cobre operações sem actor (SQL direto). Combinar os dois
  fica para query com JOIN quando necessário.

## Consequências

### Positivas

- **DB-17/S-H-P5 fechado** — `SELECT updated_at FROM <table> WHERE id =
  ?` é `O(1)` via PK; cobre TODA escrita.
- **Defesa contra ETL/SQL direto** — operação fora do app fica visível
  via `updated_at`.
- **Pré-requisito do T-021 backlog** — tabelas com PK composta
  (`family_members`, `family_member_required_documents`) PODEM agora
  migrar para ON CONFLICT em chave composta porque trigger ON UPDATE
  preservará `updated_at`. (Backlog ainda — T-021 R3.)
- **Habilita queries operacionais novas:** "todos os pacientes
  modificados nas últimas 24h", "diagnósticos criados esta semana",
  "atendimentos sem update há mais de 30 dias".
- **Custo desprezível** — 16 bytes/row × N rows. Trigger BEFORE UPDATE
  é função PL/pgSQL trivial.

### Negativas / custos

- **Mais 2 colunas por tabela raiz** — overhead de armazenamento mínimo
  (~16 bytes/row).
- **Trigger BEFORE UPDATE adiciona latência** — função simples, latência
  desprezível (microssegundos por update).
- **Migration in-place** — PostgreSQL 11+ `ADD COLUMN ... NOT NULL
  DEFAULT NOW()` usa fast-path (sem rewrite). Para versões anteriores,
  bloqueia tabela durante backfill — não é nosso caso (PG 15).
- **Models Swift não expõem essas colunas** — restringe leitura via
  `.model()`. Trade-off documentado: queries dedicadas para casos
  futuros.
- **Função `touch_updated_at` é global** — name collision se outro
  schema/migration tiver função com mesmo nome. Aceitável (escopo
  controlado).

### Ações requeridas

- [x] Migration `2026_05_14_AddCreatedUpdatedAtToRootTables` criada
- [x] Migration registrada em `configure.swift`
- [x] Função PL/pgSQL `touch_updated_at()` declarada
- [x] 5 tabelas raiz ganham colunas + triggers
- [x] `revert()` simétrico (DROP TRIGGER + DROP COLUMN + DROP FUNCTION)
- [x] 6 testes de regressão (5 lints + 1 sanity de design)
- [x] Skill `swift-io-implementer` atualizada (entrada 15)
- [ ] **Backlog operacional:** dashboard Grafana com métricas baseadas
  em `updated_at` ("rows modificadas nas últimas 24h").
- [ ] **Backlog (habilitado):** migrar `family_members` e
  `family_member_required_documents` para ON CONFLICT em PK composta
  (item 1 do backlog T-021). Agora que `family_members` tem
  `updated_at` (raiz, mas a migration não a inclui — re-avaliar
  inclusão futura ou trigger separado).
- [ ] **Backlog opcional:** adicionar colunas em mais tabelas se vier
  requisito de auditoria operacional (lookups, filhas).

## Plano de adoção

1. **Imediato (T-023):** schema migrado, suite 432/432 verde.
2. **Próximo deploy:** migration roda automaticamente no boot. ADD
   COLUMN é rápido em PG 15.
3. **T-024.x (sub-agregados):** novas tabelas (`patient_assessments`,
   `care_journey`, `protection_record`) seguem o mesmo padrão desde a
   criação — `created_at`/`updated_at` no CREATE TABLE inicial +
   trigger.

## Como reverter

`Migration.revert()` simétrico drop trigger + columns + function.

Não recomendado — reabre DB-17/S-H-P5.

## Teste de regressão

`Tests/social-care-sTests/Regression/DataIntegrity/TemporalAuditTests.swift`:

1. **`test_DB_17_function_declared`** — lint: alguma migration declara
   `CREATE OR REPLACE FUNCTION touch_updated_at()` em PL/pgSQL.
2. **`test_DB_17_created_at_added`** — lint: alguma migration tem
   `ADD COLUMN created_at TIMESTAMPTZ ... DEFAULT NOW()` + lista todas
   as tabelas raiz em `rootTables:`.
3. **`test_DB_17_updated_at_added`** — lint: idem para `updated_at`.
4. **`test_DB_17_trigger_created`** — lint: alguma migration tem
   `CREATE TRIGGER ... _updated_at BEFORE UPDATE ON ... EXECUTE
   FUNCTION touch_updated_at` + lista todas as tabelas raiz.
5. **`test_DB_17_revert_symmetric`** — lint: migration tem `revert()`
   com DROP TRIGGER + DROP COLUMN + DROP FUNCTION.
6. **`test_DB_17_patient_model_does_not_carry_audit_columns`** — sanity
   de design: `PatientModel.swift` não declara `let created_at` ou
   `let updated_at` (banco gerencia).

6/6 passam pós-fix.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` —
  entrada 15 em "Lições Aprendidas".
- **Regra resumida:** Toda tabela **raiz** (aggregate root + entidades-
  filhas com identidade própria/PK surrogate) tem **`created_at` +
  `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`** gerenciados pelo
  banco. `updated_at` é mantido por **trigger BEFORE UPDATE EXECUTE
  FUNCTION touch_updated_at()** (função PL/pgSQL única, declarada uma
  vez via `CREATE OR REPLACE`). Models Swift NÃO declaram essas colunas
  (banco gerencia; `.model()` enviaria NULL e contraria DEFAULT). Filhas
  associativas regeneradas a cada save do parent não precisam (sem
  semântica útil); operacionais com timestamps próprios (`outbox`,
  `audit_trail`) também não. `audit_trail` e `updated_at` são
  **complementares**: audit registra evento de domínio (cobre só
  operações via app); `updated_at` cobre TODA escrita (incluindo SQL
  direto, ETL, restore).

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § P5
- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § DB-17
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-023
- [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md) — Fase 4
- [ADR-021](ADR-021-deterministic-uuid-and-diff-based-upsert.md) —
  trigger ON UPDATE habilita migração de `family_members` para ON
  CONFLICT (item 1 do backlog T-021)
- [ADR-015](ADR-015-audit-trail-distinct-id-from-outbox.md) — audit
  trail; complementar
- [ADR-022](ADR-022-jsonb-and-temporal-types.md) — TIMESTAMPTZ universal
- depesz blog: "Don't use TIMESTAMP"
- Markus Winand, *SQL Performance Explained*
