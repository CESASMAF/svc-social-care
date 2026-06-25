# T-024.a — W3 Quality Gates

**Data:** 2026-05-14
**Achados:** S-H-D1 (Senior Code Review § D1) + DB-7 (DB Modeling Review)
**Fase:** 4 (Decomposição de Patient) — quinto ticket; **estágio (a) EXPAND** do expand-contract
**Parent ADR:** ADR-019

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 39.64s, 0 warnings novos |
| Full test suite | ✅ **444/444** passam, 0.235s |
| Regression suite | ✅ 140 testes em 22 suites (+12 do T-024.a) |
| Testes T-024.a | ✅ **12/12** passam (10 lints + 2 sanity runtime) |
| ADR-024 | ✅ |
| DECISIONS.md index | próximo ID = **025** | ✅ |
| Skill `swift-domain-modeler` | entrada 3 em "Lições Aprendidas" | ✅ |
| Skill `swift-io-implementer` | entrada 16 em "Lições Aprendidas" | ✅ |
| Backward compatibility | ✅ 100% (nada antigo removido) | ✅ |

## Arquivos criados

**Domain:**
- `Sources/.../Domain/Assessment/Aggregate/PatientAssessment.swift` — struct `PatientAssessment: EventSourcedAggregate`. Identidade `id: PatientId` coincide com `patientId` (relação 1:0..1). Carrega 7 módulos opcionais.
- `Sources/.../Domain/Assessment/Repository/PatientAssessmentRepository.swift` — `public protocol` com `save(_:)` e `find(byPatientId:)`.

**Persistence:**
- `Sources/.../IO/Persistence/SQLKit/SQLKitPatientAssessmentRepository.swift` — implementação real com optimistic lock (ADR-005), outbox events (ADR-014/022), mapeamento PSQLError 23505 (ADR-010).
- `Sources/.../IO/Persistence/SQLKit/Migrations/2026_05_14_CreatePatientAssessmentsTable.swift` — CREATE TABLE com PK natural + FK CASCADE + 7 colunas JSONB + version + created_at/updated_at + trigger reusando `touch_updated_at()`. Backfill idempotente via `INSERT ... SELECT ... ON CONFLICT (patient_id) DO NOTHING`. `revert()` simétrico.

**Testes:**
- `Tests/.../Regression/DomainInvariants/PatientAssessmentDecompositionTests.swift` — 12 testes (10 lints + 2 sanity)

**Handbook + skills:**
- `handbook/architecture/DECISIONS/ADR-024-patient-assessment-aggregate-expand.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-024 indexado; próximo ID = **025**
- `.claude/skills/swift-domain-modeler/SKILL.md` — entrada 3 (Aggregate Boundary Heuristic)
- `.claude/skills/swift-io-implementer/SKILL.md` — entrada 16 (Migration EXPAND phase)

## Arquivos modificados

**Bootstrap:**
- `IO/HTTP/Bootstrap/configure.swift` — `CreatePatientAssessmentsTable()` registrada na lista de migrations.

## Decisões arquiteturais

1. **Estágio EXPAND apenas** — não migrar handlers neste PR. Backward compat 100% preservada. Próximos estágios (DUAL-WRITE, CUTOVER, CONTRACT) virão em PRs separados.
2. **`id: PatientId` coincide com parent** — relação 1:0..1. Sem identidade surrogate adicional. Vernon Rule "exclusive 1:0..1 relationship".
3. **`patientId: PatientId` por valor** — não compor `Patient`. Vernon Rule "Reference Other Aggregates by Identity" (p. 365).
4. **Módulos como JSONB** — preserva compatibilidade com decoder atual. Migração para colunas explícitas é trabalho de release N+3 (CONTRACT) quando colunas em `patients` saírem (movimento conjunto).
5. **Backfill apenas do índice (patient_id)** — JSONB ficam NULL. Existência da row torna `find(byPatientId)` → não-nil quando paciente já tinha algum módulo. Permite que DUAL-WRITE faça UPDATE em vez de INSERT, evitando race entre handlers concorrentes.
6. **Trigger reusa `touch_updated_at()` global** (ADR-023) — sem duplicação de função.
7. **SQLKit repo já 100% funcional** (save + find), mas decodificação de JSONB fica como NULL até DUAL-WRITE — útil para validar a infra de save sem mexer no fluxo existente.
8. **Lint helper normaliza whitespace** — CREATE TABLE com colunas alinhadas tem padding visual; `normalizeWhitespace` colapsa runs de espaço/newline em 1 espaço para tolerar formatação.
9. **Lint "não compõe Patient" filtra comentários** — docstrings citam `Patient` legitimamente; lint só checa linhas de código (não-`//`).

## Estado expand-contract após este PR

```
T-024.a — PatientAssessment:
  (a) EXPAND     ✅ ESTE PR — infra criada, backfill idempotente rodou
  (b) DUAL-WRITE ⏳ próximo PR
  (c) CUTOVER    ⏳ release N+2
  (d) CONTRACT   ⏳ release N+3

T-024.b — ProtectionRecord: ainda não iniciado
T-024.c — CareJourney:      ainda não iniciado
```

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-023 (já reportados) | 21 fechados | 22 ADRs + ADR-019 (meta) | 128 testes |
| T-024.a | S-H-D1 + DB-7 (parcial — EXPAND only) | ADR-024 | 12 |
| **Total** | **22 fechados** | **24 ADRs** | **140 regression tests** |

> **Nota:** S-H-D1/DB-7 só serão **fechados completamente** quando T-024.a chegar ao CONTRACT (release N+3) E T-024.b/.c também concluírem suas próprias decomposições.

## Backlog gerado

1. **DUAL-WRITE PR (próximo)** — migrar handlers `UpdateHousingConditionCommandHandler`, `UpdateSocioEconomicSituationCommandHandler`, etc. para chamar `PatientAssessmentRepository.save` em paralelo a `PatientRepository.save`.
2. **`ServiceContainer`** — verificar instanciação real do `SQLKitPatientAssessmentRepository` no DI graph (criado mas pode não estar exposto ainda).
3. **CUTOVER PR (release N+2)** — `GetFullPatientProfileQuery` com JOIN; `PatientController.show(_:)` consome.
4. **CONTRACT PR (release N+3)** — drop colunas `hc_*`/`csn_*`/`shs_*`/`ses_*`/`work_and_income`/`educational_status`/`health_status` em `patients` + drop campos correspondentes no `Patient.swift`. Migração para colunas explícitas em `patient_assessments` (substituindo JSONB).
5. **T-024.b** — `ProtectionRecord` (referrals + violationReports + placementHistory).
6. **T-024.c** — `CareJourney` (intakeInfo + appointments + diagnoses).

## Próximos tickets sugeridos

- **T-024.a DUAL-WRITE** (continuação) — recomendado fazer antes de T-024.b/.c para validar o pattern.
- **T-024.b** — pode iniciar em paralelo se aceito risco de "duas decomposições simultâneas em curso".
- **Phase 5 (T-025+)** — UoW + lookups + polish, após Fase 4 completa.
