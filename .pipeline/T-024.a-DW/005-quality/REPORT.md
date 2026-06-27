# T-024.a-DW — W3 Quality Gates

**Data:** 2026-05-14
**Achados:** S-H-D1 + DB-7 (estágio (b) DUAL-WRITE da decomposição de Patient — sub-aggregate `PatientAssessment`)
**Fase:** 4 (Decomposição de Patient) — sexto ticket; **estágio (b) DUAL-WRITE** do expand-contract
**Parent ADR:** ADR-019, ADR-024

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 55.31s, 0 warnings novos |
| Full test suite | ✅ **450/450** passam, 0.105s |
| Regression suite | ✅ 146 testes em 23 suites (+6 do T-024.a-DW) |
| Testes T-024.a-DW | ✅ **6/6** passam (lints estruturais) |
| ADR-025 | ✅ |
| DECISIONS.md index | próximo ID = **026** | ✅ |
| Skill `swift-application-orchestrator` | entrada 5 em "Lições Aprendidas" | ✅ |
| Backward compatibility | ✅ Patient ainda é fonte da verdade |

## Arquivos criados

**Application (helper cross-BC):**
- `Sources/.../Application/Assessment/Shared/PatientAssessmentBuilder.swift` — `PatientAssessmentBuilder.from(_:)` constrói snapshot a partir do `Patient`. Localizado em Application porque composição cross-BC (Registry → Assessment) é responsabilidade da Application, não do Domain.

**Tests:**
- `Tests/.../Application/TestDoubles/InMemoryPatientAssessmentRepository.swift` — actor com `save` (lock simulado), `dualWriteUpsert` (idempotente), `find`, e `dualWriteCalls` para asserts.
- `Tests/.../Regression/DomainInvariants/DualWriteAssessmentTests.swift` — 6 lints estruturais.

**Handbook + skill:**
- `handbook/architecture/DECISIONS/ADR-025-patient-assessment-dual-write.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-025 indexado; próximo ID = **026**
- `.claude/skills/swift-application-orchestrator/SKILL.md` — Lições Aprendidas entrada 5

## Arquivos modificados

**Domain:**
- `Sources/.../Domain/Assessment/Repository/PatientAssessmentRepository.swift` — protocol ganha `dualWriteUpsert(_:)` documentado como API temporária da fase DUAL-WRITE.

**Persistence:**
- `Sources/.../IO/Persistence/SQLKit/SQLKitPatientAssessmentRepository.swift` — `dualWriteUpsert(_:)` implementado: serializa cada módulo via `JSONCodec.encoder` + INSERT ... ON CONFLICT (patient_id) DO UPDATE SET excluded.* + cast `::jsonb` em todos os 7 binds JSONB. Mapeamento PSQLError 23505 (ADR-010).

**Application — 7 handlers refatorados:**
- `UpdateHousingConditionCommandHandler` — init + chamada após save.
- `UpdateSocioEconomicSituationCommandHandler` — idem.
- `UpdateWorkAndIncomeCommandHandler` — idem.
- `UpdateEducationalStatusCommandHandler` — idem.
- `UpdateHealthStatusCommandHandler` — idem.
- `UpdateCommunitySupportNetworkCommandHandler` — idem.
- `UpdateSocialHealthSummaryCommandHandler` — idem.

**Bootstrap:**
- `IO/HTTP/Bootstrap/ServiceContainer.swift` — instancia `SQLKitPatientAssessmentRepository(db:)`; passa `assessmentRepository:` em cada um dos 7 handler inits.

**Tests existentes ajustados (7 arquivos):**
- `UpdateHousingConditionTests.swift`, `UpdateSocioEconomicSituationTests.swift`, `UpdateWorkAndIncomeTests.swift`, `UpdateEducationalStatusTests.swift`, `UpdateHealthStatusTests.swift`, `UpdateCommunitySupportNetworkTests.swift`, `UpdateSocialHealthSummaryTests.swift` — passam `InMemoryPatientAssessmentRepository()` inline em cada handler init via `replace_all`.

## Estado expand-contract após este PR

```
T-024.a — PatientAssessment:
  (a) EXPAND     ✅ ADR-024 (T-024.a) — concluído
  (b) DUAL-WRITE ✅ ESTE PR — handlers escrevem nos dois lados
  (c) CUTOVER    ⏳ release N+2 — leitura migra
  (d) CONTRACT   ⏳ release N+3 — drop colunas em patients

T-024.b — ProtectionRecord: ainda não iniciado
T-024.c — CareJourney:      ainda não iniciado
```

## Decisões arquiteturais

1. **`dualWriteUpsert(_:)` separado de `save(_:)`** — dois métodos refletem duas responsabilidades distintas. `save` é a porta canônica (com lock + outbox); `dualWriteUpsert` é shadow temporário (sem lock + sem outbox). Nomes distintos evitam ambiguidade e facilitam o REMOVE no CONTRACT.
2. **Sem optimistic lock no shadow** — propagaria contention do `Patient` (que ainda é primary). UPSERT idempotente via ON CONFLICT (patient_id) DO UPDATE.
3. **Sem outbox events no shadow** — eventos de domínio continuam saindo pelo `PatientRepository.save` (que já popula outbox dentro da TX). Shadow seria duplicação.
4. **Helper `PatientAssessmentBuilder` em Application/Shared** — composição cross-BC é responsabilidade da Application. Domain (Assessment) NÃO importa Patient (Registry).
5. **Síncrono, não async/background** — inconsistência cresce com latência. Síncrono garante shadow consistente em até 1 round-trip. Latência adicional desprezível para UPSERT.
6. **Erro do dual-write é fatal (`throws`)** — handler aborta se shadow falhar. Aceitável durante validação inicial; pode ser relaxado para `try?` (best-effort) se produção mostrar instabilidade. Decisão consciente para detectar problemas cedo.
7. **TestDouble inline em cada teste** (`InMemoryPatientAssessmentRepository()`) — elimina boilerplate de variáveis. Trade-off: testes não inspecionam `dualWriteCalls`; aceitável (lints estruturais cobrem o invariante "handler chama dual-write").
8. **`assessmentRepository.dualWriteUpsert(PatientAssessmentBuilder.from(patient))`** padrão idêntico nos 7 handlers — sinal antecipado de UoW cross-aggregate (T-031). Custo aceito.

## Antes vs depois

```diff
 // Application/Assessment/UpdateHousingCondition/Services/...
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

```sql
-- Pré-fix
UPDATE patients SET hc_type = 'casa', hc_wall_material = 'alvenaria', ...;
-- patient_assessments fica com housing_condition NULL

-- Pós-fix
UPDATE patients SET hc_type = 'casa', ...;  -- save primário
INSERT INTO patient_assessments (patient_id, version, housing_condition, ...)
VALUES ($1, 0, '{"type":"casa","wallMaterial":"alvenaria",...}'::jsonb, ...)
ON CONFLICT (patient_id) DO UPDATE SET
    version = excluded.version,
    housing_condition = excluded.housing_condition,
    ...;
-- patient_assessments espelha o estado real
```

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-024.a (já reportados) | 22 fechados (parcial S-H-D1/DB-7) | 23 ADRs + ADR-019 (meta) | 140 testes |
| T-024.a-DW | S-H-D1/DB-7 (estágio b) | ADR-025 | 6 |
| **Total** | **22 fechados (parcial)** | **25 ADRs** | **146 regression tests** |

> **Nota:** S-H-D1/DB-7 só serão **fechados completamente** quando T-024.a chegar ao CONTRACT (release N+3) E T-024.b/.c também concluírem suas decomposições.

## Backlog gerado

1. **Operacional:** dashboard Grafana comparando `patients.<col>` vs `patient_assessments.<col>` para detectar inconsistências durante o período DUAL-WRITE.
2. **Período de observação:** mínimo 1 sprint antes do CUTOVER.
3. **CUTOVER (release N+2):** `GetFullPatientProfileQuery` faz JOIN; `PatientController.show(_:)` consome a query nova; handlers param de escrever em `Patient.<modulo>?`.
4. **CONTRACT (release N+3):** drop colunas em `patients`; drop campos em `Patient.swift`; **remover `dualWriteUpsert` do protocol e da impl**.

## Próximos tickets sugeridos (Fase 4)

- **T-024.a CUTOVER** (release N+2) — quando dashboard de divergência confirmar estabilidade.
- **T-024.b** — `ProtectionRecord` (referrals + violationReports + placementHistory). Pode iniciar em paralelo se aceito risco de "duas decomposições simultâneas".
- **T-024.c** — `CareJourney` (intakeInfo + appointments + diagnoses).
- **Phase 5 (T-025+ originais)** — UoW + lookups + polish, após Fase 4 completa.
