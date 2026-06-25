# T-021 — W3 Quality Gates

**Data:** 2026-05-14
**Achados:** S-H-P1 (Senior Code Review § P1) + DB-6 (DB Modeling Review) — `UUID()` inline no mapper + delete-and-insert no repository = identidade física quebrada a cada save
**Fase:** 4 (Decomposição de Patient) — segundo ticket
**Parent ADR:** ADR-019

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 61.87s, 0 warnings novos |
| Full test suite | ✅ **416/416** passam, 0.096s |
| Regression suite | ✅ 112 testes em 19 suites (+7 do T-021) |
| Testes T-021 | ✅ **7/7** passam (5 lints + 2 runtime sanity) |
| ADR-021 | ✅ |
| DECISIONS.md index | próximo ID = **022** | ✅ |
| Skill `swift-io-implementer` | entrada 13 em "Lições Aprendidas" | ✅ |

## Arquivos criados

**Sources:**
- `Sources/.../shared/Crypto/DeterministicUUID.swift` — `enum DeterministicUUID` com `static func from(_ key: String) -> UUID`. SHA256 + RFC 9562 (UUIDv8) + RFC 4122 (variant).

**Testes:**
- `Tests/.../Regression/DomainInvariants/ChildIdentityPreservedTests.swift` — 7 testes (5 lints + 2 runtime)

**Handbook + skill:**
- `handbook/architecture/DECISIONS/ADR-021-deterministic-uuid-and-diff-based-upsert.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-021 indexado; próximo ID = **022**
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 13

## Arquivos modificados

**Mapper:**
- `IO/Persistence/SQLKit/Mappers/PatientDatabaseMapper.swift` — 9 ocorrências de `id: UUID()` substituídas por `DeterministicUUID.from("<table>|<chave-natural>")`:
  - `DiagnosisModel` — chave `(patient_id, icd_code, date)`
  - `MemberIncomeModel` — chave `(patient_id, member_id)`
  - `SocialBenefitModel` × 2 (SES, WI) — chave `(source, patient_id, beneficiary_id, benefit_name)`
  - `MemberEducationalProfileModel` — chave `(patient_id, member_id)`
  - `ProgramOccurrenceModel` — chave `(patient_id, member_id, date, effect_id)`
  - `MemberDeficiencyModel` — chave `(patient_id, member_id, deficiency_type_id)`
  - `GestatingMemberModel` — chave `(patient_id, member_id)`
  - `IngressLinkedProgramModel` — chave `(patient_id, program_id)`

**Repository:**
- `IO/Persistence/SQLKit/SQLKitPatientRepository.swift`:
  - Novo helper `upsertChildren<T>(...)` que faz diff (SELECT existing IDs → toRemove = existing - desired → DELETE removed → INSERT cada model com ON CONFLICT (id) DO UPDATE SET excluded.*).
  - Mirror reflection extrai colunas do primeiro model do batch para construir o SET excluded.
  - 12 call sites migrados de `deleteAndInsert` para `upsertChildren`.
  - Tabelas com PK composta natural (`family_members`, `family_member_required_documents`) mantêm `deleteAndInsert` por ora — semanticamente equivalente até triggers ON UPDATE serem introduzidos (T-023).
  - Novo helper privado `ExistingIdRow: Codable { let id: UUID }` definido no escopo do arquivo (Swift 6.3 não permite tipos aninhados em função genérica).

## Decisões arquiteturais

1. **SHA256 sobre UUIDv5 (SHA-1)** — SHA-1 deprecado por colisões; SHA256 mais robusto. Bits ajustados para UUIDv8 (RFC 9562).
2. **Convenção de chave `<table>|<chave-natural>`** — prefixo do nome da tabela como defesa em profundidade contra colisão entre tabelas que possam compartilhar chave natural.
3. **Mirror reflection para extrair colunas** — evita boilerplate `static let allColumns: [String]` em 12 models. Custo runtime é desprezível (1× por batch, não em loop apertado).
4. **`family_members` mantém `deleteAndInsert`** — tradeoff documentado. PK composta natural (tupla é a identidade); delete-and-insert recria com mesma PK. Migração para ON CONFLICT em chave composta fica para T-023 (quando triggers ON UPDATE forem introduzidos).
5. **`ExistingIdRow` fora do método genérico** — Swift 6.3 não permite tipos aninhados em função genérica.
6. **Lint estrutural conta ocorrências em vez de regex complicado** — `source.components(separatedBy: "id: UUID(),").count - 1` é simples e robusto. Mapper não tem outros usos legítimos do padrão `id: UUID(),` (identidades vêm do domínio via `UUID(uuidString: ...)`).

## Antes vs depois

```diff
 // mapper (9 sites)
-DiagnosisModel(id: UUID(), patient_id: patientId, icd_code: d.id.value, ...)
+DiagnosisModel(id: DeterministicUUID.from("patient_diagnoses|\(patientId.uuidString)|\(d.id.value)|\(d.date.date.timeIntervalSince1970)"), patient_id: patientId, icd_code: d.id.value, ...)

 // repository (12 sites)
-try await deleteAndInsert(tx, table: "patient_diagnoses", patientId: patientId, models: data.diagnoses)
+try await upsertChildren(tx, table: "patient_diagnoses", patientId: patientId, models: data.diagnoses, idExtractor: \.id)
```

```sql
-- Pré-fix (cada save):
DELETE FROM patient_diagnoses WHERE patient_id = $1;
INSERT INTO patient_diagnoses (id, ...) VALUES ($random, ...);  -- id novo a cada save

-- Pós-fix (cada save):
SELECT id FROM patient_diagnoses WHERE patient_id = $1;
-- (calcula diff)
DELETE FROM patient_diagnoses WHERE id IN (...);  -- só removidos
INSERT INTO patient_diagnoses (id, ...) VALUES ($deterministic, ...)
    ON CONFLICT (id) DO UPDATE SET patient_id = excluded.patient_id, ...;
```

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-020 (já reportados) | 18 fechados | 19 ADRs + ADR-019 (meta) | 105 testes |
| T-021 | S-H-P1 + DB-6 | ADR-021 | 7 |
| **Total** | **19 fechados** | **21 ADRs** | **112 regression tests** |

## Backlog gerado

1. **Migrar `family_members` e `family_member_required_documents` para ON CONFLICT em PK composta** quando T-023 introduzir triggers `ON UPDATE`. Por ora, delete-and-insert é semanticamente equivalente.
2. **Validar em staging** que migration de PKs (T-006) cobre todas as tabelas que fazem upsert via ON CONFLICT — sem PK não há conflict possível.

## Próximos tickets sugeridos (Fase 4)

- **T-022** — JSONB + TIMESTAMPTZ + DATE corretos (S-H-P7 + DB-9 + DB-10 + DB-16).
- **T-023** — `created_at`/`updated_at` automáticos em todas raízes (S-H-P5 + DB-17). **Habilita** migração de `family_members` para ON CONFLICT (item 1 do backlog acima).
- **T-024.a/.b/.c** — Decomposição em sub-agregados (Assessment → Protection → Care).
