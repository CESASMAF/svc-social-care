# ADR-025: `PatientAssessment` — estágio DUAL-WRITE da decomposição da Fase 4

**Data:** 2026-05-14
**Status:** Aceito (estágio (b) DUAL-WRITE)
**Supersedes:** —
**Parent:** [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md), [ADR-024](ADR-024-patient-assessment-aggregate-expand.md)

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Continuação do expand-contract da decomposição de `Patient` em
`PatientAssessment`. ADR-024 entregou o estágio **(a) EXPAND** — infra
nova criada (Domain + Repository + Schema + backfill idempotente) sem
remover o estado antigo. Os 7 handlers de assessment (`UpdateHousing*`,
`UpdateSES*`, `UpdateWAI*`, `UpdateES*`, `UpdateHS*`, `UpdateCSN*`,
`UpdateSHS*`) continuavam escrevendo **só** em `Patient.<modulo>?`.

Este ADR materializa **(b) DUAL-WRITE**: cada handler de assessment,
após o save primário em `PatientRepository`, executa um upsert
secundário em `PatientAssessmentRepository`. Estado real passa a viver
em **ambos** os lados durante a fase de transição.

### Estado expand-contract — em qual estágio estamos

```
(a) EXPAND     ✅ ADR-024 (T-024.a) — concluído.
(b) DUAL-WRITE ← ESTE ADR. Handlers escrevem nos dois lados.
(c) CUTOVER    ⏳ release N+2 — leitura migra para o novo.
(d) CONTRACT   ⏳ release N+3 — drop colunas em patients.
```

### Por que escrita secundária SEM lock?

`PatientRepository.save` continua sendo a **escrita primária** com
optimistic lock real (ADR-005). Ele garante consistência do estado
canônico durante a fase DUAL-WRITE. O `PatientAssessment` é apenas
**shadow** — sua única finalidade durante a transição é validar que a
infra de save (incluindo serialização JSONB, cast `::jsonb`, trigger
`updated_at`, FK CASCADE) funciona em produção sob carga real.

Aplicar lock no shadow seria contraprodutivo:
- Falha de lock no shadow desfaria o save primário, criando
  inconsistência reversa.
- Race entre dois handlers concorrentes editando módulos diferentes
  (atualmente possível porque ambos escrevem em `patient.version`
  primário) replicaria a contention no shadow.

UPSERT idempotente sem lock — `INSERT ... ON CONFLICT (patient_id) DO
UPDATE SET excluded.*` — é o trade-off correto para esta fase.

### Citações canônicas

> *"In the dual-write phase, the new side is shadow. Inconsistencies
> are recorded for monitoring, not enforced. The old side remains the
> source of truth until cutover."*
> — Pramod Sadalage & Scott Ambler, *Refactoring Databases*, cap. 5

> *"Don't add cross-aggregate transactional locking to dual-write
> phase. You'll just propagate the original aggregate's contention to
> the new one."*
> — Vaughn Vernon, *Implementing DDD*, cap. 10

## Decisão

### 1. Domain — protocol ganha `dualWriteUpsert(_:)`

```swift
public protocol PatientAssessmentRepository: Sendable {
    func save(_ assessment: PatientAssessment) async throws
    func find(byPatientId patientId: PatientId) async throws -> PatientAssessment?

    /// **Estágio (b) DUAL-WRITE.** UPSERT sem optimistic lock; sem
    /// publicação de eventos. Será removido em CUTOVER + CONTRACT.
    func dualWriteUpsert(_ assessment: PatientAssessment) async throws
}
```

### 2. Persistence — `SQLKitPatientAssessmentRepository.dualWriteUpsert`

```swift
func dualWriteUpsert(_ assessment: PatientAssessment) async throws {
    let patientId = UUID(uuidString: assessment.patientId.description)!
    let encoder = JSONCodec.encoder
    func jsonString<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8)
    }
    let hcJson = try jsonString(assessment.housingCondition)
    // ... 6 outros módulos ...

    try await db.raw("""
        INSERT INTO patient_assessments (
            patient_id, version,
            housing_condition, socioeconomic_situation, work_and_income,
            educational_status, health_status, community_support_network,
            social_health_summary
        ) VALUES (
            \(bind: patientId), \(bind: assessment.version),
            \(bind: hcJson)::jsonb, \(bind: sesJson)::jsonb, \(bind: waiJson)::jsonb,
            \(bind: esJson)::jsonb, \(bind: hsJson)::jsonb, \(bind: csnJson)::jsonb,
            \(bind: shsJson)::jsonb
        )
        ON CONFLICT (patient_id) DO UPDATE SET
            version                   = excluded.version,
            housing_condition         = excluded.housing_condition,
            ...
    """).run()
}
```

- Cast `::jsonb` no bind explícito (ADR-022) — PostgresKit envia
  String, coluna espera JSONB.
- `JSONCodec.encoder` (ADR-022) — `.iso8601`.
- Sem optimistic lock; sem outbox events.

### 3. Application — helper `PatientAssessmentBuilder`

```swift
public enum PatientAssessmentBuilder {
    public static func from(_ patient: Patient) -> PatientAssessment {
        PatientAssessment(
            patientId: patient.id,
            version: 0,  // sem lock no DUAL-WRITE
            housingCondition: patient.housingCondition,
            socioeconomicSituation: patient.socioeconomicSituation,
            workAndIncome: patient.workAndIncome,
            educationalStatus: patient.educationalStatus,
            healthStatus: patient.healthStatus,
            communitySupportNetwork: patient.communitySupportNetwork,
            socialHealthSummary: patient.socialHealthSummary
        )
    }
}
```

Localizado em `Application/Assessment/Shared/` — composição cross-BC
(Registry → Assessment) é responsabilidade da Application, não do
Domain.

### 4. Application — 7 handlers refatorados

Padrão idêntico aplicado a todos:

```swift
public actor Update<X>CommandHandler {
    private let repository: any PatientRepository
    private let assessmentRepository: any PatientAssessmentRepository
    // (lookupValidator quando aplicável)

    public init(
        repository: any PatientRepository,
        assessmentRepository: any PatientAssessmentRepository
        // (lookupValidator quando aplicável)
    ) { ... }

    public func handle(_ command: ...) async throws {
        do {
            // ... parse + fetch + domain ...
            try await repository.save(patient)
            // ADR-025 DUAL-WRITE.
            try await assessmentRepository.dualWriteUpsert(
                PatientAssessmentBuilder.from(patient)
            )
        } catch { throw mapError(error, ...) }
    }
}
```

7 handlers tocados:
- `UpdateHousingConditionCommandHandler`
- `UpdateSocioEconomicSituationCommandHandler`
- `UpdateWorkAndIncomeCommandHandler`
- `UpdateEducationalStatusCommandHandler`
- `UpdateHealthStatusCommandHandler`
- `UpdateCommunitySupportNetworkCommandHandler`
- `UpdateSocialHealthSummaryCommandHandler`

### 5. Bootstrap — `ServiceContainer` injeta o novo repo

```swift
let assessmentRepo: any PatientAssessmentRepository =
    SQLKitPatientAssessmentRepository(db: db)
// ...
self.updateHousingCondition = UpdateHousingConditionCommandHandler(
    repository: repository, assessmentRepository: assessmentRepo
)
// ... 6 outros handlers ...
```

### 6. Tests — `InMemoryPatientAssessmentRepository`

```swift
actor InMemoryPatientAssessmentRepository: PatientAssessmentRepository {
    private var store: [PatientId: PatientAssessment] = [:]
    private(set) var dualWriteCalls: [PatientAssessment] = []
    // ... save com lock simulado, dualWriteUpsert idempotente ...
}
```

Mantém histórico `dualWriteCalls` para asserts em testes futuros que
queiram validar que o handler chamou o dual-write.

### Antes vs depois (handler típico)

```diff
 public actor UpdateHousingConditionCommandHandler {
     private let repository: any PatientRepository
+    private let assessmentRepository: any PatientAssessmentRepository

-    public init(repository: any PatientRepository) {
+    public init(
+        repository: any PatientRepository,
+        assessmentRepository: any PatientAssessmentRepository
+    ) {
         self.repository = repository
+        self.assessmentRepository = assessmentRepository
     }

     public func handle(_ command: ...) async throws {
         // ... domain ...
         try await repository.save(patient)
+        // ADR-025 DUAL-WRITE.
+        try await assessmentRepository.dualWriteUpsert(
+            PatientAssessmentBuilder.from(patient)
+        )
     }
 }
```

## Alternativas consideradas

- **Adicionar `assessmentRepository.save(_:)` (com lock) em vez de
  `dualWriteUpsert`.** Descartada — propagaria contention do `Patient`
  para o shadow. Lock só faz sentido no CUTOVER quando o shadow vira
  source of truth.
- **Async/background dispatch para o dual-write.** Descartada —
  inconsistência cresce com latência. Síncrono garante que o DB
  shadow está consistente com cada save primário em até 1 round-trip.
- **Helper static no Domain (extensão de `PatientAssessment`).**
  Descartada — composição cross-BC é da Application, não do Domain.
  `PatientAssessmentBuilder` em `Application/Assessment/Shared/` é o
  lugar correto.
- **Saga / outbox para dual-write eventual.** Considerada para release
  futuro com volume produção alto. Descartada por agora — síncrono
  cobre o caso pré-prod com complexidade mínima.
- **Migrar 1 handler por PR (7 PRs).** Descartada — proliferação de
  PRs sem ganho. Pattern é idêntico nos 7; um PR cobre tudo.

## Consequências

### Positivas

- **Estado real fluindo nos dois lados** — `patient_assessments`
  começa a se popular com dados reais. Próximo CUTOVER pode validar
  que JOIN entre `patients` e `patient_assessments` retorna
  exatamente o mesmo estado que a leitura via `Patient.<modulo>?`.
- **Validação da serialização JSONB** — encoder + cast funcionam em
  produção sob carga real. Identifica problemas (campos novos,
  encoding edge cases) antes do CUTOVER.
- **Trigger `updated_at` exercitado** — cada UPSERT no shadow gera
  UPDATE; trigger atualiza `updated_at`. Validação operacional.
- **Pattern claro para T-024.b/.c** — `ProtectionRecord` e
  `CareJourney` seguem o mesmo molde DUAL-WRITE.

### Negativas / custos

- **Latência por save +1 round-trip** — handler agora faz 2 escritas
  em vez de 1. Aceitável (UPSERT é rápido; mesmo tempo de uma INSERT
  típica).
- **Inconsistência transitória possível** — se o save primário
  sucesso e o dual-write falha (network, disk full, FK violation),
  shadow fica desatualizado para esse paciente até o próximo update
  (que faz UPSERT idempotente). Mitigação: monitorar `patient_assessments`
  vs `patients` regularmente; CUTOVER só após 1 sprint de monitoring
  estável.
- **Erro do dual-write é fatal** — handler `throws`. Pode ser
  reconsiderado para `try?` (best-effort log-and-continue) se
  produção mostrar instabilidade. Por agora, mantemos rigor para
  detectar problemas cedo.
- **Mais boilerplate nos testes** — cada teste de assessment instancia
  `InMemoryPatientAssessmentRepository()` no construtor do handler.
  Inline elimina verbosidade.
- **`assessmentRepository: any PatientAssessmentRepository`** em 7
  handlers — sinal antecipado de UoW cross-aggregate (T-031). Por
  agora aceito como custo da decomposição.

### Ações requeridas

- [x] `PatientAssessmentRepository.dualWriteUpsert(_:)` declarado no protocol
- [x] `SQLKitPatientAssessmentRepository.dualWriteUpsert` implementado
- [x] `PatientAssessmentBuilder.from(_:)` criado em `Application/Assessment/Shared/`
- [x] 7 handlers de assessment refatorados (init + chamada após save)
- [x] `ServiceContainer` instancia `SQLKitPatientAssessmentRepository` e injeta nos 7 handlers
- [x] `InMemoryPatientAssessmentRepository` criado em TestDoubles
- [x] 7 testes existentes ajustados para passar `InMemoryPatientAssessmentRepository()` inline
- [x] 6 testes de regressão (lints estruturais)
- [x] Skill `swift-application-orchestrator` atualizada (entrada nova)
- [ ] **Backlog operacional:** dashboard Grafana comparando `patients.<col>`
  vs `patient_assessments.<col>` para detectar inconsistências durante o
  período DUAL-WRITE.
- [ ] **CUTOVER PR (release N+2):**
  - `GetFullPatientProfileQuery` faz JOIN entre `patients` e
    `patient_assessments`.
  - `PatientController.show(_:)` consome a query nova.
  - Handlers param de chamar `PatientRepository.save` para módulos de
    assessment (cutover de escrita também).
- [ ] **CONTRACT PR (release N+3):**
  - Drop colunas `hc_*`/`csn_*`/`shs_*`/`ses_*`/`work_and_income`/
    `educational_status`/`health_status` em `patients`.
  - Drop campos correspondentes em `Patient.swift`.
  - Migrar JSONB para colunas explícitas em `patient_assessments` (ou
    manter JSONB como decisão consciente).
  - **Remover `dualWriteUpsert` do protocol e da impl.**

## Plano de adoção

1. **Imediato (este PR):** dual-write ligado. Suite 450/450 verde.
2. **Próximo deploy:** todos os updates de assessment passam a
   popular `patient_assessments`. Dashboards monitoram divergência.
3. **Período de observação (mínimo 1 sprint):** validar que JSONB
   serializado fielmente reflete estado de `Patient.<modulo>?`.
4. **CUTOVER (release N+2):** leitura migra. Handlers param de
   escrever no `Patient.<modulo>?`.
5. **CONTRACT (release N+3):** drop colunas e campos. `dualWriteUpsert`
   sai do protocol.

## Como reverter

`git revert` do commit T-024.a-DW remove a chamada de
`dualWriteUpsert` dos 7 handlers; `assessmentRepository` ainda
existe mas não é usado. Patient continua intacto.

Caminho técnico:
1. Reverter o commit.
2. Marcar este ADR como `Deprecado`.
3. EXPAND (ADR-024) permanece em vigor.

Risco zero — Patient ainda é fonte da verdade.

## Teste de regressão

`Tests/social-care-sTests/Regression/DomainInvariants/DualWriteAssessmentTests.swift`:

1. **`test_protocol_declares_dual_write_upsert`** — lint: protocol
   declara método.
2. **`test_sqlkit_repo_implements_dual_write`** — lint: impl tem
   `dualWriteUpsert`, `ON CONFLICT`, `::jsonb`.
3. **`test_handlers_call_dual_write`** — lint: 7 handlers chamam
   `assessmentRepository.dualWriteUpsert(`.
4. **`test_handlers_inject_assessment_repository`** — lint: 7 handlers
   recebem `assessmentRepository: any PatientAssessmentRepository` no init.
5. **`test_service_container_wires_assessment_repo`** — lint:
   ServiceContainer instancia `SQLKitPatientAssessmentRepository` e
   passa `assessmentRepository:` em cada um dos 7 handler inits.
6. **`test_in_memory_assessment_repo_exists`** — lint: TestDouble existe.

6/6 passam pós-fix.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-application-orchestrator/SKILL.md` —
  entrada 5 em "Lições Aprendidas".
- **Regra resumida — DUAL-WRITE phase:** Durante o estágio (b)
  expand-contract de decomposição de aggregate, handler executa
  **escrita primária com lock** no agregado antigo + **escrita
  secundária sem lock** (`dualWriteUpsert`) no shadow novo. Helper
  `<NewAggregate>Builder` em `Application/<NewBC>/Shared/` faz
  composição cross-BC (Domain não compõe outros agregados — só
  identidade). Repository do shadow expõe `dualWriteUpsert(_:)`
  separado do `save(_:)` — UPSERT idempotente, sem outbox events
  (eventos saem pelo lock primário). Métodos `dualWriteUpsert` são
  **deprecados na CONTRACT** quando handlers migram para o novo repo.
  TestDouble do shadow expõe `dualWriteCalls: [Aggregate]` para
  asserts em testes que queiram validar dual-write. Aplicar
  inline `InMemory<X>Repository()` em testes elimina boilerplate.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § D1
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-024
- [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md) — Fase 4
- [ADR-024](ADR-024-patient-assessment-aggregate-expand.md) — EXPAND
- [ADR-022](ADR-022-jsonb-and-temporal-types.md) — JSONB cast e
  JSONCodec
- [ADR-014](ADR-014-outbox-events-via-repository.md) — outbox via
  primary repository (events ainda saem por lá durante DUAL-WRITE)
- Pramod Sadalage & Scott Ambler, *Refactoring Databases*, cap. 5
- Vaughn Vernon, *Implementing DDD*, cap. 10
