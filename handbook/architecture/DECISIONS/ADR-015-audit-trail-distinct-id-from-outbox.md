# ADR-015: `audit_trail.id` distinto de `outbox.id` + `outbox_message_id` para rastreio

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achado **S-C10** (Senior Code Review § achado C10 + DB Modeling Review § audit
trail): `SQLKitOutboxRelay` reusava `message.id` como `audit_trail.id` na hora
de inserir o entry de auditoria:

```swift
// SQLKitOutboxRelay.swift — pré-fix
auditEntries.append(AuditTrailModel(
    id: message.id,                      // ← reusa PK do outbox
    aggregate_type: "Patient",
    aggregate_id: aggregateId,
    event_type: message.event_type,
    actor_id: parsed.actorId,
    payload: message.payload,
    occurred_at: message.occurred_at,
    recorded_at: now
))
```

`audit_trail.id` é PK. Se a mesma mensagem do outbox for re-processada (e em
ambiente real isso **vai** acontecer — relay reinicia depois de crash, ADR-013
explica que dois pollers podem competir no janela antes do COMMIT), a INSERT
resulta em **PK conflict**. Pré-T-012 essa condição era frequente; mesmo
pós-ADR-013 (FOR UPDATE SKIP LOCKED), uma falha catastrófica do pod com lock
preso até timeout pode reentregar a mesma message.

### O efeito é pior que parece

`SQLKitOutboxRelay.pollAndDistribute` insere `auditEntries` em **batch** dentro
da transação:

```swift
for entry in auditEntries {
    try await tx.insert(into: "audit_trail").model(entry).run()
}
```

Se uma das inserts dispara duplicate-key, o `throws` aborta a TX inteira — **o
batch inteiro de 50 messages é revertido**. Próxima poll lê os mesmos 50,
processa, tenta insert, dispara novamente. Loop infinito de batch dies.

Sintomas: relay nunca avança, `processed_at IS NULL` para sempre, NATS recebe
re-publicação contínua (mitigado por `Nats-Msg-Id` mas adiciona ruído na
JetStream). Pior cenário: outage silencioso de auditoria.

### Citações canônicas

> *"Generated keys should not be reused. […] Conflating natural keys with
> surrogate keys creates implicit coupling that becomes painful at scale."*
> — Pramod Sadalage & Martin Fowler, *NoSQL Distilled*, cap. 3

> *"If you need to relate two records, use a foreign key. Do not pretend that
> two records share an identity just because their meanings are correlated."*
> — Bill Karwin, *SQL Antipatterns*, cap. 5 (Keyless Entry)

A invariante "audit é uma cópia eterna do que aconteceu" exige que o audit
tenha **identidade própria**. O relacionamento com o outbox é um **fato** (este
audit veio daquela message), não uma identidade.

## Decisão

1. **Schema:**
   - `audit_trail.id UUID NOT NULL DEFAULT gen_random_uuid()` (PK).
   - Nova coluna `audit_trail.outbox_message_id UUID NOT NULL` que rastreia a
     origem (não tem FK formal porque `outbox_messages` é purgável; `audit_trail`
     deve sobreviver à purga do outbox).
   - Index em `outbox_message_id` para suportar query forense
     (`WHERE outbox_message_id = ?`).

2. **Model:**
   - `AuditTrailModel` ganha campo `outbox_message_id: UUID`.
   - Construtor exige o campo — quem cria audit precisa amarrar a origem.

3. **Relay:**
   - `SQLKitOutboxRelay.pollAndDistribute` popula `id: UUID()` (novo a cada call)
     e `outbox_message_id: message.id` (rastreia origem).
   - Re-processamento adiciona N rows distintos em vez de travar batch.

4. **Migration:**
   - `2026_05_14_AuditTrailDistinctId.swift` aplica:
     - `ALTER TABLE audit_trail ALTER COLUMN id SET DEFAULT gen_random_uuid()`
     - `ALTER TABLE audit_trail ADD COLUMN outbox_message_id UUID NOT NULL`
     - `CREATE INDEX idx_audit_trail_outbox_message_id ON audit_trail (outbox_message_id)`

### Antes vs depois (relay)

```diff
 auditEntries.append(AuditTrailModel(
-    id: message.id,                       // ← reusa PK do outbox
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

## Alternativas consideradas

- **Manter `id: message.id` + `INSERT ... ON CONFLICT DO NOTHING`.** Descartada.
  Esconde o sintoma sem fixar a invariante. Re-processamentos legítimos viram
  rows perdidos — auditoria deixa de registrar fatos. Pior: oculta bugs do
  relay (re-leitura indevida vira comportamento "ok").
- **`UNIQUE (outbox_message_id)` em vez de PK separada.** Descartada. Mantém o
  problema: re-processamento dispara duplicate-key na constraint UNIQUE; batch
  ainda morre.
- **Nova tabela `audit_trail_v2` com schema correto + dual-write durante
  migração.** Descartada (overkill). Migration in-place com ADD COLUMN é
  segura — `audit_trail` ainda tem volume baixo (<100k rows nesta fase do
  projeto). Re-avaliar quando crescer para milhões.
- **`outbox_message_id` como FK formal para `outbox_messages.id`.** Descartada.
  `outbox_messages` é purgável (ADR-013 indica retention de 30 dias); FK
  bloqueia purga ou exige `ON DELETE CASCADE` que apaga audit. Audit deve
  sobreviver à purga do outbox — coluna sem FK é o trade-off correto.

## Consequências

### Positivas

- **Bug S-C10 eliminado** — re-processamento adiciona rows em vez de travar
  batch. Auditoria registra re-processamentos como fato observável.
- **Identidade semântica clara** — `id` identifica o registro de auditoria;
  `outbox_message_id` rastreia a origem. Sem coupling implícito.
- **Forense viável** — query `WHERE outbox_message_id = ?` lista todas as
  vezes que aquela message foi processada (com index suporta volume).
- **Defense-in-depth com ADR-013** — mesmo que FOR UPDATE SKIP LOCKED falhe em
  cenário extremo (crash com lock preso), audit trail aceita as duas inserts
  e o batch continua.

### Negativas / custos

- **Migration online** — ADD COLUMN NOT NULL exige DEFAULT temporário ou
  backfill. Como nesta fase do projeto a tabela tem volume baixo, a migration
  pode setar o NOT NULL direto após backfill com `gen_random_uuid()` placeholder
  para rows legacy. Em produção com volume alto, executar em duas migrations:
  (a) ADD COLUMN nullable, (b) backfill, (c) ALTER COLUMN SET NOT NULL.
- **Audit cresce 16 bytes/row** (UUID extra). Aceitável — audit já tem JSON
  payload muito maior; overhead < 1%.
- **Code reviewer precisa lembrar do invariante** — handler novo que insere em
  audit deve passar `outbox_message_id`. Mitigação: construtor exige o campo
  (compilador enforça). Skill `swift-io-implementer` documenta.

### Ações requeridas

- [x] Migration `2026_05_14_AuditTrailDistinctId.swift` criada
- [x] Migration registrada em `configure.swift`
- [x] `AuditTrailModel` ganha `outbox_message_id: UUID`
- [x] `SQLKitOutboxRelay.pollAndDistribute` usa `id: UUID()` + `outbox_message_id: message.id`
- [x] `Tests/.../IO/AuditTrailTests.swift` ajustado para o novo construtor
- [x] 5 testes de regressão estruturais em `Regression/EventPublication/`
- [x] Skill `swift-io-implementer` atualizada (entrada 8 de Lições Aprendidas)
- [ ] **Documentação operacional:** runbook do relay precisa mencionar que
  re-processamentos viram audit duplicado (esperado, não bug). TODO em
  `handbook/runbook/outbox-relay.md` quando criado.

## Plano de adoção

1. **Imediato (T-015):** schema + model + relay refatorados. Suite 379/379 verde.
2. **Próximo agregado novo (T-024):** `PatientAssessment`, `Care` etc. seguem o
   mesmo padrão se tiverem audit trail próprio. Skill carrega a lição.
3. **Quando audit crescer (>1M rows):** considerar particionamento por
   `recorded_at` (mensal). Manter o invariante "id próprio + outbox_message_id"
   intacto.

## Como reverter

Reverter ADR-015 reintroduz S-C10 (batch dies on duplicate).

Caminho técnico:
1. Reverter `SQLKitOutboxRelay`: `id: message.id`
2. Drop coluna `outbox_message_id` (nova migration)
3. Drop default `gen_random_uuid()` no `audit_trail.id` (nova migration)
4. Marcar este ADR como `Deprecado`

Não recomendado.

## Teste de regressão

`Tests/social-care-sTests/Regression/EventPublication/AuditTrailDistinctIdRegressionTests.swift`:

1. **`test_S_C10_AuditTrailModel_declares_outbox_message_id`** — lint estrutural:
   `AuditTrailModel.swift` declara `let outbox_message_id: UUID`.
2. **`test_S_C10_relay_uses_distinct_id`** — lint estrutural:
   `SQLKitOutboxRelay.swift` constrói `AuditTrailModel(id: UUID(), outbox_message_id: ...)`.
3. **`test_S_C10_some_migration_declares_outbox_message_id_column`** — lint
   estrutural: alguma migration aplica `ADD COLUMN outbox_message_id`.
4. **`test_S_C10_some_migration_applies_default_gen_random_uuid_on_id`** — lint
   estrutural: alguma migration aplica `DEFAULT gen_random_uuid()` em
   `audit_trail.id`.
5. **`test_S_C10_some_migration_creates_index_on_outbox_message_id`** — lint
   estrutural: alguma migration cria index em `outbox_message_id`.

5/5 passam pós-fix.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` — entrada
  8 em "Lições Aprendidas (regressões prevenidas)".
- **Regra resumida:** Tabela de auditoria/log NUNCA reusa PK de outra tabela
  como sua própria PK. PK é identidade do registro; rastreio para origem é
  coluna separada (`<source>_message_id`, sem FK formal se source for purgável).
  Construtor do model deve exigir o campo de rastreio — compilador é a primeira
  linha de defesa contra "esqueci de amarrar a origem". Em batch de inserts,
  duplicate-key trava o batch inteiro (TX abortada) — schema deve aceitar
  N rows pela mesma origem como fato observável, não como erro.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § C10 — origem do achado
- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` — confirmou pelo
  modelo de dados
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-015 — especificação
- [ADR-013](ADR-013-outbox-for-update-skip-locked.md) — defense-in-depth: relay
  é at-least-once por design
- [ADR-014](ADR-014-outbox-events-via-repository.md) — repository.save grava
  outbox + agregado em mesma TX
- Bill Karwin, *SQL Antipatterns*, cap. 5 (Keyless Entry)
- Pramod Sadalage & Martin Fowler, *NoSQL Distilled*, cap. 3
- Chris Richardson — *Microservices Patterns*, Transactional Outbox
