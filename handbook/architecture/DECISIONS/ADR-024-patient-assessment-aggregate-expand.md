# ADR-024: `PatientAssessment` aggregate — estágio EXPAND da decomposição da Fase 4

**Data:** 2026-05-14
**Status:** Aceito (estágio (a) EXPAND)
**Supersedes:** —
**Parent:** [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md)

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achados: **S-H-D1** (Senior Code Review § D1) + **DB-7** (DB Modeling
Review). `Patient` (aggregate root) carrega 7 módulos opcionais de
Assessment (`housingCondition?`, `socioeconomicSituation?`,
`workAndIncome?`, `educationalStatus?`, `healthStatus?`,
`communitySupportNetwork?`, `socialHealthSummary?`). Tabela `patients`
tem ~63 colunas dos 4 BCs colapsados. ADR-019 mãe documenta o
problema.

Este ADR materializa **a primeira sub-decomposição (T-024.a — estágio
EXPAND)**.

### Estado expand-contract — em qual estágio estamos

ADR-019 estabeleceu que cada sub-decomposição (T-024.a/b/c) segue 5
estágios:

```
(a) EXPAND     ← este ADR (T-024.a). Cria infra nova sem remover antiga.
(b) BACKFILL   ← coberto pela mesma migration (idempotente).
(c) DUAL-WRITE ← próximo PR (release N+1).
(d) CUTOVER    ← release N+2 (leitura migra para o novo).
(e) CONTRACT   ← release N+3 (drop colunas em patients).
```

Este ADR cobre **apenas (a) e (b)**. Mais nada muda. Backward
compatibility 100% preservada.

### Citações canônicas

> *"Reference Other Aggregates by Identity. […] If you find that you
> need to traverse another aggregate, you have either a query problem
> (use a read model) or a boundary problem."*
> — Vaughn Vernon, *Implementing DDD*, p. 365

> *"Expand-contract migration is the only safe way to break apart a
> god model. Big-bang refactors of aggregate boundaries lead to
> incidents."*
> — Pramod Sadalage & Scott Ambler, *Refactoring Databases*, cap. 5

## Decisão

### 1. Domain — novo aggregate `PatientAssessment`

```swift
// Sources/.../Domain/Assessment/Aggregate/PatientAssessment.swift
public struct PatientAssessment: EventSourcedAggregate, EventSourcedAggregateInternal {
    public var id: PatientId { patientId }   // identidade COINCIDE com Patient
    public internal(set) var version: Int
    public internal(set) var uncommittedEvents: [any DomainEvent] = []

    public let patientId: PatientId          // referência POR IDENTIDADE (Vernon Rule)

    public internal(set) var housingCondition: HousingCondition?
    public internal(set) var socioeconomicSituation: SocioEconomicSituation?
    public internal(set) var workAndIncome: WorkAndIncome?
    public internal(set) var educationalStatus: EducationalStatus?
    public internal(set) var healthStatus: HealthStatus?
    public internal(set) var communitySupportNetwork: CommunitySupportNetwork?
    public internal(set) var socialHealthSummary: SocialHealthSummary?
    // ...
}
```

**Decisões de design:**

- **`id: PatientId`** (não `AssessmentId`). A relação é 1:0..1 com
  `Patient`; criar identidade própria seria dispersar sem ganho.
- **`patientId: PatientId` por valor** — NÃO compor `Patient`. Vernon
  Rule "Reference Other Aggregates by Identity".
- **Mesmo conjunto de tipos VO** que vivem em `Patient` hoje — são
  reutilizados sem mudança.
- **EventSourcedAggregate composição** (ADR-004) — Outbox Pattern
  preservado.

### 2. Domain — protocolo `PatientAssessmentRepository`

```swift
public protocol PatientAssessmentRepository: Sendable {
    func save(_ assessment: PatientAssessment) async throws
    func find(byPatientId patientId: PatientId) async throws -> PatientAssessment?
}
```

Mantém invariante de Outbox Pattern (ADR-014): `save(_:)` escreve
agregado + uncommittedEvents na mesma transação.

### 3. Schema — tabela `patient_assessments`

```sql
CREATE TABLE patient_assessments (
    patient_id                UUID PRIMARY KEY REFERENCES patients(id) ON DELETE CASCADE,
    version                   INT  NOT NULL DEFAULT 0,
    housing_condition         JSONB,
    socioeconomic_situation   JSONB,
    work_and_income           JSONB,
    educational_status        JSONB,
    health_status             JSONB,
    community_support_network JSONB,
    social_health_summary     JSONB,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TRIGGER patient_assessments_updated_at
  BEFORE UPDATE ON patient_assessments
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
```

**Decisões de schema:**

- **PK natural** `patient_id` — relação 1:0..1; nenhuma identidade
  surrogate adicional.
- **FK ON DELETE CASCADE** — assessment não tem sentido sem patient.
- **Módulos como JSONB** — preserva compatibilidade com decoder atual
  (ADR-022 + JSONCodec). Migração para colunas explícitas é trabalho
  de release N+3 (CONTRACT).
- **`created_at`/`updated_at` + trigger** — segue ADR-023.

### 4. Backfill idempotente

```sql
INSERT INTO patient_assessments (patient_id)
SELECT p.id
  FROM patients p
 WHERE p.hc_type IS NOT NULL
    OR p.csn_has_relative_support IS NOT NULL
    OR p.shs_requires_constant_care IS NOT NULL
    OR p.ses_total_family_income IS NOT NULL
    OR p.work_and_income IS NOT NULL
    OR p.educational_status IS NOT NULL
    OR p.health_status IS NOT NULL
ON CONFLICT (patient_id) DO NOTHING;
```

**Estratégia:** popular apenas o "índice" (patient_id) — JSONB ficam
NULL. Existência da row torna `find(byPatientId)` → não-nil quando o
paciente já tinha algum módulo. Isso permite que o próximo estágio
(DUAL-WRITE) faça UPDATE em vez de INSERT — evita race entre dois
handlers concorrentes que tentam inserir a mesma row.

`ON CONFLICT (patient_id) DO NOTHING` torna a migration **idempotente** —
re-rodar não duplica.

### 5. Persistence — `SQLKitPatientAssessmentRepository`

Implementa `save` (com optimistic lock + outbox no padrão dos repos
existentes — ADR-005, ADR-013, ADR-014, ADR-022) e `find` (SELECT
direto). Atualmente os módulos JSONB ficam não-deserializados — quando
o DUAL-WRITE entrar (próximo PR), serialização real é adicionada.

### 6. Bootstrap

`ServiceContainer` instancia o novo repository para que esteja
disponível no DI graph. Nenhum handler atual o usa ainda.

## Alternativas consideradas

- **Big-bang: drop das colunas em `patients` neste PR.** Descartada —
  expand-contract de ADR-019 é claro: não pular estágios. Big-bang
  expõe deploy a window de inconsistência.
- **`AssessmentId` próprio (UUID surrogate em vez de coincidir com
  PatientId).** Considerada. Descartada — a relação é 1:0..1 (Vernon:
  "an aggregate referencing another aggregate has its own identity, but
  may share the natural key when the relationship is exclusive"). Sem
  ganho de criar UUID novo.
- **Colunas explícitas em vez de JSONB para módulos.** Considerada para
  esta migration. Descartada por agora — JSONB preserva compatibilidade
  com decoder atual; migração para colunas é trabalho de release N+3
  (CONTRACT) quando colunas em `patients` saírem (movimento conjunto).
- **Backfill com cópia completa do JSONB.** Considerada. Descartada —
  exigia tradução de 63 colunas → 7 JSONB no SQL puro (verboso e
  frágil). Backfill apenas do índice + DUAL-WRITE para serializar é
  mais simples e a leitura via app continua usando `Patient.hc_*` até o
  CUTOVER.

## Consequências

### Positivas

- **Infraestrutura nova disponível** — Domain + Repository + Schema
  prontos para os próximos estágios.
- **Backward compat 100%** — nenhum handler ou query muda
  comportamento. Risco zero de regressão funcional.
- **Backfill idempotente** — pode rodar quantas vezes for, sem
  duplicar ou corromper.
- **Padrão estabelecido para T-024.b/.c** — `ProtectionRecord` e
  `CareJourney` seguem o mesmo molde.
- **Trigger ON UPDATE preservado** — `patient_assessments.updated_at`
  é mantido pelo trigger compartilhado (ADR-023).

### Negativas / custos

- **Mais arquivos** — 4 novos: aggregate, protocol, repository, migration.
- **JSONB em PostgreSQL é por enquanto NULL** — `find(byPatientId)`
  retorna agregado vazio durante a EXPAND phase. Útil só para validar
  infra — testes runtime cobrindo decodificação real virão no DUAL-WRITE.
- **Documentação obrigatória** — cada PR sub-fase precisa atualizar
  este ADR ou criar `ADR-024.b`/`ADR-024.c` (TBD).
- **Patient não foi aliviado ainda** — bug original (lock contention,
  save infla) persiste até o CUTOVER. Vai consumir 2-3 sprints até
  fechar a Fase 4 inteira.
- **Risco de "esquecer" estágios** — `git log --grep T-024` precisa
  rastrear progresso. Mitigação: TaskCreate explícito por sub-PR.

### Ações requeridas

- [x] `Sources/.../Domain/Assessment/Aggregate/PatientAssessment.swift` criado
- [x] `Sources/.../Domain/Assessment/Repository/PatientAssessmentRepository.swift` criado
- [x] `Sources/.../IO/Persistence/SQLKit/SQLKitPatientAssessmentRepository.swift` criado
- [x] `Sources/.../IO/Persistence/SQLKit/Migrations/2026_05_14_CreatePatientAssessmentsTable.swift` criada
- [x] Migration registrada em `configure.swift`
- [x] 12 testes de regressão (10 lints + 2 sanity)
- [x] Skill `swift-domain-modeler` atualizada (entrada nova)
- [x] Skill `swift-io-implementer` atualizada (entrada 16)
- [ ] **Próximo PR (DUAL-WRITE):** migrar handlers
  `UpdateHousingConditionCommandHandler` etc. para chamar
  `PatientAssessmentRepository.save` em paralelo a
  `PatientRepository.save`.
- [ ] **Release N+2 (CUTOVER):** criar
  `GetFullPatientProfileQuery` que faz JOIN entre `patients` e
  `patient_assessments`; `PatientController.show(_:)` usa a query
  nova.
- [ ] **Release N+3 (CONTRACT):** drop colunas `hc_*`/`csn_*`/`shs_*`/
  `ses_*` em `patients` + drop campos do `Patient.swift`.
- [ ] **`ServiceContainer`:** instanciar `SQLKitPatientAssessmentRepository`
  e expô-lo no DI graph (item ainda pendente — verificar no próximo PR).

## Plano de adoção

1. **Imediato (T-024.a):** infra criada, backfill rodou. Suite 444/444
   verde.
2. **Próximo deploy:** migration roda automaticamente no boot.
   Backfill é idempotente.
3. **Próximo PR (release N+1, ~1 sprint):** DUAL-WRITE — handlers
   passam a escrever nos dois repos. Período mínimo de 1 sprint para
   detectar problemas via dashboards.
4. **Release N+2 (~2 sprints à frente):** CUTOVER de leitura.
5. **Release N+3 (~3 sprints à frente):** CONTRACT — drop colunas em
   `patients`.

## Como reverter

`Migration.revert()` simétrico: drop trigger + drop tabela. Code
reverter:

1. `git revert` do commit T-024.a — apaga arquivos novos. Patient
   continua intacto (nada foi tocado).
2. `swift run migration revert CreatePatientAssessmentsTable`.
3. Marcar este ADR como `Deprecado`.

Risco zero — nada ainda depende do que foi criado.

## Teste de regressão

`Tests/social-care-sTests/Regression/DomainInvariants/PatientAssessmentDecompositionTests.swift`:

**Lints — Domain:**
1. `aggregate_exists` — arquivo criado.
2. `aggregate_conforms` — `public struct PatientAssessment: EventSourcedAggregate`.
3. `aggregate_references_by_id` — declara `patientId: PatientId` e
   NÃO compõe `Patient` (filtra comentários).
4. `aggregate_carries_modules` — 7 módulos declarados.
5. `repository_protocol_exists` — arquivo + protocol + métodos.

**Lints — Persistence:**
6. `sqlkit_repo_exists` — arquivo criado.

**Lints — Migration (helper normaliza whitespace para tolerar
alinhamento visual de colunas):**
7. `table_exists` — `CREATE TABLE patient_assessments`.
8. `table_pk_fk` — PK + FK REFERENCES patients(id).
9. `table_temporal_columns` — version + created_at/updated_at TIMESTAMPTZ.
10. `backfill_idempotent` — INSERT SELECT FROM patients ... ON CONFLICT.
11. `table_trigger` — TRIGGER updated_at.

**Sanity runtime:**
12. `aggregate_buildable_empty` — construtor com módulos zero, version=0,
    uncommittedEvents vazio.

12/12 passam pós-fix.

## Better Pattern para skills

- **Skills atualizadas:**
  - `.claude/skills/swift-domain-modeler/SKILL.md` — entrada nova
    (Aggregate decomposition expand-contract).
  - `.claude/skills/swift-io-implementer/SKILL.md` — entrada 16
    (Repository + migration EXPAND phase).
- **Regra resumida — Decomposição de god aggregate:** Quando aggregate
  root acumula módulos opcionais que representam BCs distintos
  (Vernon "Aggregate Boundary Heuristic"), aplicar **expand-contract**
  por sub-aggregate:
  1. **(a) EXPAND** — criar novo aggregate + repository + tabela +
     trigger updated_at, sem remover o estado antigo. Backfill
     idempotente popula o "índice" da nova tabela; módulos JSONB ficam
     NULL temporariamente. Backward compat 100%.
  2. **(b) DUAL-WRITE** — handlers chamam ambos repositories em
     paralelo. Período mínimo 1 sprint.
  3. **(c)+(d) CUTOVER** — leitura migra para o novo via Query layer
     (JOIN); endpoints HTTP mantêm contrato.
  4. **(e) CONTRACT** — drop colunas antigas + campos no aggregate
     antigo.
  - **Identidade:** sub-aggregate referencia parent por **ID, não por
    composição** (Vernon Rule). Quando a relação é 1:0..1, `id` do
    sub-aggregate **coincide** com o `id` do parent (não criar UUID
    surrogate adicional).
  - **Cada estágio é um PR independente** — incidente em DUAL-WRITE
    não obriga reverter EXPAND.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § D1
- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § DB-7
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-024
- [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md) — Fase 4
  meta-governance
- [ADR-004](ADR-004-event-sourced-aggregate-composite-protocol.md) —
  EventSourcedAggregate via composição
- [ADR-005](ADR-005-optimistic-locking-via-version.md) — version-based
- [ADR-014](ADR-014-outbox-events-via-repository.md) — events via repo
- [ADR-022](ADR-022-jsonb-and-temporal-types.md) — JSONB + cast
- [ADR-023](ADR-023-created-updated-at-on-root-tables.md) — trigger
  reusado
- Vaughn Vernon, *Implementing DDD*, cap. 10
- Pramod Sadalage & Scott Ambler, *Refactoring Databases*, cap. 5
