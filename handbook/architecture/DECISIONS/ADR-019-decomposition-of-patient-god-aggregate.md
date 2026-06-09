# ADR-019: Decomposição estrutural do god aggregate `Patient` — plano de adoção da Fase 4

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`. Este ADR é **meta-governance** da Fase 4 — a
> seção `Teste de regressão` justifica a isenção (não há teste isolado; o
> conjunto de regression tests T-020..T-024 é o teste do plano).

## Contexto

Achados convergentes do `SENIOR_CODE_REVIEW_2026_05_14.md` (S-H-D1, S-H-A7,
S-H-P1) e `DATABASE_MODELING_REVIEW_2026_05_14.md` (DB-5, DB-6, DB-7, DB-9,
DB-10, DB-16, DB-17): o agregado `Patient` em
`Sources/.../Domain/Registry/Aggregates/Patient/` carrega 4 bounded contexts
colapsados em uma única struct + repositório.

### Estado atual — Patient como god aggregate

```
Patient (struct, EventSourcedAggregate)
├─ Core Identity (Registry BC)
│  ├─ id, version, personId
│  ├─ personalData?
│  ├─ civilDocuments?
│  ├─ address?
│  ├─ familyMembers: [FamilyMember]      ← N:N entidade-filha
│  └─ socialIdentity?
├─ Analytics & Assessment (Assessment BC) — 8 módulos opcionais
│  ├─ housingCondition?
│  ├─ socioeconomicSituation?
│  ├─ workAndIncome?
│  ├─ educationalStatus?
│  ├─ healthStatus?
│  ├─ communitySupportNetwork?
│  ├─ socialHealthSummary?
│  └─ (mais campos derivados em PatientAssessments.swift, 116 LOC)
├─ Interventions & History (Care + Protection BCs)
│  ├─ appointments: [SocialCareAppointment]   ← N (Care)
│  ├─ referrals: [Referral]                   ← N (Protection)
│  ├─ violationReports: [RightsViolationReport] ← N (Protection)
│  ├─ placementHistory?                       ← (Protection)
│  └─ intakeInfo?                             ← (Care)
├─ Lifecycle (Registry)
│  ├─ status, dischargeInfo?, withdrawInfo?
└─ Clinical (Care)
   └─ diagnoses: [Diagnosis]                  ← N
```

Patient.swift + PatientAssessments.swift + PatientInterventions.swift = 414
LOC. 17 use cases em 4 BCs todos passam por `repository.save(patient)` —
cada update de housing força save do agregado inteiro.

### Por que isso é HIGH (S-H-D1) e contamina o schema (DB-7)

1. **Concorrência:** dois profissionais editando o mesmo `Patient` em
   módulos diferentes (um atualiza `housingCondition`, outro registra
   `appointment`) competem pelo `version` do agregado inteiro. Optimistic
   lock falha em um deles **mesmo sem conflito real**.
2. **Save infla custo:** cada update salva o agregado inteiro — ~30 colunas
   + N tabelas filhas (delete-and-insert em `family_members`,
   `patient_diagnoses`, `appointments`, ...). Mesmo update de 1 campo
   reescreve tudo.
3. **Outbox infla:** cada save gera N eventos do agregado inteiro. Subscribers
   filtram por `event_type` mas o payload carrega o estado completo.
4. **Identidade de entidades-filhas é destruída** (S-H-P1 + DB-6) — mapper
   atual faz delete-and-insert; cada save de Patient apaga e recria
   `family_members` com novo UUID. Audit trail mente.
5. **Schema reflete o god aggregate** (DB-7) — `patients` tem ~30 colunas
   acumulando state de 4 BCs. `required_documents` armazenado como TEXT
   composto (DB-5) viola 1NF.
6. **Tests do core de Patient são frágeis** — alterar algo em Care quebra
   teste de Registry porque o fixture compartilha o Patient inteiro.

### Citações canônicas

> *"Aggregates should be small. […] When you find yourself adding more and
> more invariants to an aggregate, that's a smell that you have multiple
> aggregates conflated."*
> — Vaughn Vernon, *Implementing DDD*, p. 357 (Rule: Design Small Aggregates)

> *"Reference other aggregates by identity only. […] If you find that you
> need to traverse another aggregate, you have either a query problem (use
> a read model) or a boundary problem (the aggregates were poorly drawn)."*
> — Vernon, p. 365 (Rule: Reference Other Aggregates by Identity)

> *"One aggregate per transaction. […] Two aggregates updated in a single
> transaction means you guessed wrong on the boundary."*
> — Vernon, p. 386

> *"A god aggregate is the OO version of the god class. Same problem,
> bigger blast radius."*
> — Eric Evans, DDD Europe 2018 keynote (paraphrased)

## Decisão

### Princípios

**P1 — Vernon Rule: Small Aggregates.** Cada bounded context com state
opcional próprio vira agregado próprio. `Patient` mantém só o **núcleo de
identidade civil** (Registry).

**P2 — ID-based references entre agregados.** Sub-agregados referenciam
`patientId: PatientId` por valor. NUNCA composição direta (`Patient` não
"contém" `PatientAssessment` mais — coexistem por id).

**P3 — Uma transação por agregado.** `repository.save(assessment)` não toca
`patients`. `repository.save(patient)` não toca `patient_assessments`.
Atomicidade cross-aggregate é responsabilidade da Application via UoW
(decisão futura — Phase 5).

**P4 — Read model separado para join.** Quando um caller (BFF, dashboard)
precisa de "Patient + Assessment + Care + Protection" em uma resposta, a
**Query layer** monta via JOIN seletivo (read-only, fora do contrato dos
agregados). O write side fica decomposto.

**P5 — Migração expand-contract**, nunca big-bang. Cada migração:
(a) expand: adiciona o novo schema/aggregate sem remover o antigo;
(b) backfill: copia dados;
(c) dual-write: período de transição onde Application escreve nos dois;
(d) cutover: leitura migra para o novo;
(e) contract: drop do antigo.

### Estado alvo — agregados decompostos

```
PatientCore (Registry BC)            ← era Patient
├─ id (PatientId)
├─ version
├─ personId
├─ personalData?, civilDocuments?, address?
├─ familyMembers: [FamilyMember]     ← entidade-filha de PatientCore
├─ socialIdentity?
├─ status, dischargeInfo?, withdrawInfo?
└─ (sem outros módulos)

PatientAssessment (Assessment BC)
├─ patientId: PatientId              ← referência por identidade
├─ version
├─ housingCondition?, socioeconomicSituation?
├─ workAndIncome?, educationalStatus?
├─ healthStatus?, communitySupportNetwork?
└─ socialHealthSummary?

CareJourney (Care BC)
├─ patientId: PatientId
├─ version
├─ intakeInfo?
├─ appointments: [SocialCareAppointment]
└─ diagnoses: [Diagnosis]            ← clinical é Care

ProtectionRecord (Protection BC)
├─ patientId: PatientId
├─ version
├─ referrals: [Referral]
├─ violationReports: [RightsViolationReport]
└─ placementHistory?
```

Cada um tem seu repository (`PatientCoreRepository`, `PatientAssessmentRepository`,
`CareJourneyRepository`, `ProtectionRecordRepository`) e tabela 1:0..1 com
`patient_id PK FK`.

### Plano de adoção por ticket

A Fase 4 entrega via 5 tickets sequenciais (alguns paralelos seguros):

| Ticket | O que entrega | Dependências | Risco | Sub-ticket? |
|---|---|---|---|---|
| **T-020** | `required_documents` vira tabela filha (1NF) | T-006 (PKs) | BAIXO | — |
| **T-021** | Mappers fazem diff-based upsert (preserva identidade) | T-006 | MÉDIO | — |
| **T-022** | JSONB + TIMESTAMPTZ + DATE corretos | T-001 | BAIXO | — |
| **T-023** | `created_at`/`updated_at` automáticos em todas raízes | T-006 | BAIXO | — |
| **T-024** | Decompor em sub-agregados (Assessment, Protection, Care) | T-005, T-006, T-008, T-020, T-021 | **ALTO** | **SIM**: T-024.a (Assessment), T-024.b (Protection), T-024.c (Care) — cada um PR independente |

### Ordem recomendada e racional

```
T-020 (required_documents 1NF)
   ↓
T-021 (diff-based upsert)
   ↓
T-022 (JSONB + types) ─── paralela com T-021 (não conflita)
   ↓
T-023 (created/updated_at)
   ↓
T-024.a (PatientAssessment — extrai 8 módulos opcionais)
   ↓
T-024.b (ProtectionRecord — extrai referrals + violationReports + placementHistory)
   ↓
T-024.c (CareJourney — extrai intakeInfo + appointments + diagnoses)
```

**Por quê esta ordem:**
1. T-020 + T-021 + T-022 + T-023 são **pré-requisitos sem decomposição**.
   Reduzem dívida do schema sem mexer nas fronteiras lógicas.
2. T-024 só faz sentido quando filhas têm identidade preservada (T-021),
   PKs declaradas (T-006), tipos corretos (T-022), e `created_at`/`updated_at`
   automáticos (T-023). Tentar T-024 antes vira retrabalho.
3. T-024.a (Assessment) primeiro porque é **o módulo mais isolado** — 8
   campos opcionais sem N:N. Validar pattern antes de aplicar em Care
   (que tem appointments + diagnoses, mais complexo).

### Estratégia de migração de dados (expand-contract por T-024.x)

Para cada sub-agregado novo (T-024.a/.b/.c):

```sql
-- (a) EXPAND
CREATE TABLE patient_assessments (
    patient_id UUID PRIMARY KEY REFERENCES patients(id) ON DELETE RESTRICT,
    -- ... 8 colunas dos módulos opcionais ...
    version INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- (b) BACKFILL — uma migration separada, idempotente
INSERT INTO patient_assessments (patient_id, hc_*, csn_*, shs_*, ses_*, ...)
SELECT id, hc_*, csn_*, shs_*, ses_*, ...
FROM patients
WHERE hc_* IS NOT NULL OR csn_* IS NOT NULL OR ... -- algum módulo preenchido
ON CONFLICT (patient_id) DO NOTHING;

-- (c) DUAL-WRITE (release N) — Application grava em ambos:
--     PatientCoreRepository.save() escreve `patients` SEM os módulos opcionais (NULL)
--     PatientAssessmentRepository.save() escreve `patient_assessments`
--     Reads: leitura ainda usa `patients.hc_*` (não migrou)

-- (d) CUTOVER (release N+1) — leitura migra para `patient_assessments`
--     Query layer faz JOIN para BFF; uses cases de Assessment leem só `patient_assessments`

-- (e) CONTRACT (release N+2, depois de monitoring confirmar 0 reads)
ALTER TABLE patients DROP COLUMN hc_*;  -- repete por 8 módulos
```

Cada release é deployável independentemente. Rollback = parar no estágio
atual (não regredir).

### Compatibilidade backward — BFF e Query layer

O BFF (Flutter app via `social_care_bff` em `frontend/`) consome
`/v1/patients/{id}` esperando o JSON com TODOS os módulos. Para não quebrar:

1. **Application/Query** ganha um handler novo
   `GetFullPatientProfileQuery` que faz JOIN em todas as tabelas e monta o
   DTO completo. Fica em `Application/Query/PatientFullProfile/`.
2. **HTTP controller** `PatientController.show(_:)` muda para chamar a query
   nova em vez de `repository.find(byId:)`.
3. **Contract test** (em `contracts/services/social-care/`) garante o JSON de
   resposta idêntico antes e depois. Bumping de versão da API só se schema
   externo mudar — decomposição interna é invisível para o cliente.

### Eventos no outbox — manter ou refatorar?

Eventos atuais (`PatientRegisteredEvent`, `HousingConditionUpdatedEvent`,
`AppointmentRegisteredEvent`, ...) carregam `patientId`. Nenhum carrega
"snapshot do agregado inteiro" (verificar antes de cada T-024.x). Decisão:

- **Manter contratos de eventos atuais.** Subscribers externos (people-context,
  analytics, BI) seguem funcionando — payload externo continua igual.
- **Internamente,** evento agora vem de seu agregado natural
  (`HousingConditionUpdatedEvent` é emitido por `PatientAssessment` em vez
  de `Patient`). Mudança transparente para o subscriber.

### Critério de "pronto" para cada ticket

Cada T-020..T-024.x SÓ é considerado fechado quando:

- [ ] W0: regression test estrutural+runtime falha intencionalmente
- [ ] W1: implementação faz suite verde + build release sem warning novo
- [ ] W3: 100% dos testes existentes continuam verde (REGRA INVIOLÁVEL)
- [ ] ADR próprio criado em `DECISIONS/` referenciando este ADR-019 como mãe
- [ ] Skill apropriada (`swift-domain-modeler` / `swift-application-orchestrator`
      / `swift-io-implementer`) atualizada com entrada em "Lições Aprendidas"
- [ ] Quality report em `.pipeline/T-NNN/005-quality/REPORT.md`
- [ ] **T-024.x adicional:** dual-write período mínimo de 1 sprint antes do cutover

### Riscos catalogados

| # | Risco | Severidade | Mitigação |
|---|---|---|---|
| R1 | Migration de backfill perde dados em produção | CRÍTICA | Backfill é INSERT `ON CONFLICT DO NOTHING` (idempotente). Pré-validação: query `WHERE hc_* IS NOT NULL` mostra contagem antes/depois. Backup do schema completo antes da migration. |
| R2 | BFF/queries quebram após decomposição | ALTA | `GetFullPatientProfileQuery` mantém contrato externo. Contract test no CI. Dual-write período de 1 sprint. |
| R3 | Optimistic lock cross-aggregate (UoW ausente) | MÉDIA | Phase 5 (T-031) trata UoW. Por ora: order-of-operations explícito (Patient core primeiro, depois sub-agregados). Documentar no skill. |
| R4 | Eventos viram orfãos (publicados sem agregado correspondente em prod) | MÉDIA | Subscribers já idempotentes via `Nats-Msg-Id` (ADR-013). Cutover só após dual-write estabilizar. |
| R5 | Code reviewer não percebe mudança de boundary | BAIXA | Cada T-024.x tem ADR próprio referenciando este. PR template referencia ADR-019. |
| R6 | Patient.swift fica trivial (10 linhas) e gera "vamos juntar de volta" | BAIXA | Documentar no Patient.swift que decomposição é intencional, link para este ADR. |
| R7 | Migração trava em produção por dependência de FK ON DELETE RESTRICT | MÉDIA | Backfill garante row em `patient_assessments` para todo paciente com módulo preenchido. Tests de migration validam invariante. |

## Alternativas consideradas

- **Big-bang refactor (1 PR gigante).** Descartada — 414 LOC de domain +
  ~20 arquivos de Application + Persistence + Tests = PR gigante
  inrevisável. Decomposição em 5 tickets cada um deployable.
- **Não decompor — viver com o god aggregate.** Descartada — S-H-D1 é HIGH;
  custos atuais (lock contention, save infla, identidade quebrada)
  acumulam. Hoje é gerenciável (pequeno volume), em 6 meses é incidente.
- **Quebrar agregados mas manter 1 tabela `patients` com colunas dos 4
  BCs.** Descartada — schema é fonte secundária de design (DB-7). Manter
  schema misturado vai re-introduzir lock contention via row-level lock no
  PostgreSQL.
- **Mover Care + Protection para microserviços separados.** Considerada;
  descartada por agora (escopo). Decomposição interna é prerrequisito
  para extração futura — quando tiver razão de negócio (escala, time
  separado, ciclo de release independente), os agregados já estão
  desenhados.

## Consequências

### Positivas

- **Concorrência saudável** — dois profissionais editando módulos diferentes
  não competem pelo mesmo `version`.
- **Save proporcional ao update** — atualizar `housingCondition` toca só
  `patient_assessments`, não os 30 campos de `patients`.
- **Identidade de filhas preservada** (efeito colateral da fundação T-021).
- **Escala futura** — quando precisar separar Care/Protection em serviços
  próprios, fronteiras já estão alinhadas.
- **Testes mais isolados** — fixture de Care não precisa setar campos de
  Assessment.
- **Schema 1NF** (DB-5/DB-6/DB-7 fechados via T-020..T-024).

### Negativas / custos

- **Mais arquivos** — Domain ganha 3 novos agregados; Application/Persistence
  ganham respectivos use cases e repositories. Mas cada arquivo fica
  pequeno e focado.
- **UoW pendente** (Phase 5 T-031) — atomicidade cross-aggregate via
  Application. Por ora: order-of-operations explícito.
- **Migração de dados em produção** — risco operacional; mitigado por
  expand-contract por release.
- **Janela de 2-3 sprints** — cada T-024.x tem dual-write + cutover +
  contract = 3 releases mínimas.
- **Patient.swift fica menor** — pode tentar code reviewer "juntar de
  volta". Documentação inline + ADR link mitigam.

### Ações requeridas

- [x] ADR mãe criado e indexado em `DECISIONS.md`
- [ ] T-020 executado (próximo ticket)
- [ ] T-021 executado
- [ ] T-022 executado
- [ ] T-023 executado
- [ ] T-024.a (Assessment) executado
- [ ] T-024.b (Protection) executado
- [ ] T-024.c (Care) executado
- [ ] Skill `swift-domain-modeler` atualizada (Vernon Small Aggregates Rule)
- [ ] Skill `swift-application-orchestrator` atualizada (UoW pendente,
      ordering explícito)

### Plano de rollback

Cada ticket-filho tem rollback próprio. Para abandonar a Fase 4 inteira:

1. **T-024.x não cutover:** dropar tabelas novas, código novo fica dead.
   Patient continua god — sem regressão, só dívida acumulada.
2. **T-024.x pós-cutover:** recriar colunas em `patients`, copy back
   (custoso). Não recomendado.
3. **T-020..T-023:** independentes, cada um tem rollback próprio
   documentado em seu ADR.

Por isso a ordem importa: T-020..T-023 são reversíveis sem perda; T-024.x
expand-contract permite parar a qualquer momento entre estágios.

## Teste de regressão

Este ADR é **meta-governance** da Fase 4 — não há comportamento técnico
isolado para testar.

**Conformidade com ADR-003:** o conjunto de regression tests dos tickets
T-020..T-024.c é o teste deste ADR. Cada ticket-filho contribui:

- **T-020** → `Tests/.../Regression/DataIntegrity/RequiredDocumentsAtomicityTest.swift`
- **T-021** → `Tests/.../Regression/DomainInvariants/ChildIdentityPreservedTest.swift`
- **T-022** → `Tests/.../Regression/DataIntegrity/JSONBQueryableTest.swift` +
  `TemporalTypesTest.swift`
- **T-023** → `Tests/.../Regression/DataIntegrity/TemporalAuditTest.swift`
- **T-024.a/.b/.c** → `Tests/.../Regression/DomainInvariants/AggregateDecompositionTest.swift`
  (ou suites separadas por sub-agregado)

Quando todos passarem em CI, este ADR está cumprido. Antes disso, o
status fica `Aceito` (decisão fechada) mas implementação está em
andamento — rastreado por checkboxes em "Ações requeridas".

## Better Pattern para skills

- **Skill `swift-domain-modeler` ganha entrada nova:** Aggregate Boundary
  Heuristic (Vernon).
  - **Regra resumida:** Quando um aggregate root acumular módulos opcionais
    (campos `nullable` que representam BCs distintos preenchidos em
    momentos diferentes da jornada), aplicar Vernon Small Aggregates Rule
    — cada módulo vira agregado próprio, referenciado por identidade
    (`patientId: PatientId`). Sinais de god aggregate: (a) >5 propriedades
    opcionais agrupadas por contexto, (b) save infla em casos simples,
    (c) optimistic lock falha em editores concorrentes sem conflito real,
    (d) testes de um BC quebram ao alterar fixture de outro BC. Decomposição
    é expand-contract: nunca big-bang. Migração de dados via INSERT
    idempotente; dual-write 1 sprint mínimo; cutover precedido por contract
    test.
  - **Onde:** seção "Lições Aprendidas (regressões prevenidas)" da skill.

- **Skill `swift-application-orchestrator` ganha nota:** UoW cross-aggregate
  é Phase 5 (T-031). Até lá, ordering explícito — escrever PatientCore
  antes dos sub-agregados; falhas de sub-agregado não desfazem PatientCore
  (compensar em release subsequente).

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § D1 (god aggregate),
  § A7 (required_documents), § P1 (delete-and-insert)
- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § DB-5/6/7/9/10/16/17
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` Fase 4 (T-020..T-024)
- [ADR-003](ADR-003-adr-structure-enforces-test-and-pattern.md) — exigência
  de teste + Better Pattern (justifica isenção meta-ADR)
- [ADR-005](ADR-005-optimistic-locking-via-version.md) — lock por agregado;
  decomposição alivia contention
- [ADR-006](ADR-006-primary-keys-for-aggregate-tables.md) — pré-requisito
- [ADR-007](ADR-007-typed-foreign-keys-for-semantic-identity.md) — pré-requisito
- [ADR-014](ADR-014-outbox-events-via-repository.md) — events via repository
  permanece válido em sub-agregados
- [ADR-015](ADR-015-audit-trail-distinct-id-from-outbox.md) — audit trail
  ganha mais entries (1 por agregado tocado), schema já suporta
- Vaughn Vernon, *Implementing DDD*, cap. 10 (Aggregates) — pp. 351-396
- Eric Evans, *Domain-Driven Design*, cap. 6 (Lifecycle of a Domain Object)
- Pramod Sadalage & Martin Fowler, *Refactoring Databases*, cap. 5
  (expand-contract pattern)
