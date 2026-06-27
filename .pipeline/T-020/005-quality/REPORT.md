# T-020 — W3 Quality Gates

**Data:** 2026-05-14
**Achados:** S-H-A7 (Senior Code Review § A7 — `compactMap` silencia typo) + DB-5 (DB Modeling Review — `required_documents` viola 1NF)
**Fase:** 4 (Decomposição de Patient) — primeiro ticket
**Parent ADR:** ADR-019 (plano de adoção da Fase 4)

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 48.36s, 0 warnings novos |
| Full test suite | ✅ **409/409** passam, 0.083s |
| Regression suite | ✅ 105 testes em 18 suites (+9 do T-020) |
| Testes T-020 | ✅ **9/9** passam (8 lints estruturais + 1 sanity) |
| ADR-020 | ✅ |
| DECISIONS.md index | próximo ID = **021** | ✅ |
| Skill `swift-application-orchestrator` | entrada 4 em "Lições Aprendidas" | ✅ |
| Skill `swift-io-implementer` | entrada 12 em "Lições Aprendidas" | ✅ |

## Arquivos criados

**Sources:**
- `IO/Persistence/SQLKit/Migrations/2026_05_14_FamilyMemberRequiredDocumentsTable.swift` — CREATE TABLE 1NF + backfill via `jsonb_array_elements_text` + DROP COLUMN antiga; `revert()` simétrico via `json_agg`.

**Testes:**
- `Tests/.../Regression/DataIntegrity/RequiredDocumentsAtomicityTests.swift` — 9 testes (8 lints + 1 sanity)

**Handbook + skills:**
- `handbook/architecture/DECISIONS/ADR-020-required-documents-1nf-and-try-map.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-020 indexado; próximo ID = **021**
- `.claude/skills/swift-application-orchestrator/SKILL.md` — Lições Aprendidas entrada 4
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 12

## Arquivos modificados

**Domain (sem mudança):**
- `Domain/Registry/Entities/FamilyMember/RequiredDocument.swift` — enum String com 5 cases (CN/RG/CTPS/CPF/TE) já estava correto; só ganhou `CaseIterable` (já tinha) que mapper usa para `expected:` no erro.

**Application:**
- `Application/Registry/AddFamilyMember/Error/AddFamilyMemberErrors.swift` — novo case `invalidRequiredDocument(String)` mapeado para HTTP 422 com `invalidValue` em context.
- `Application/Registry/AddFamilyMember/Services/AddFamilyMemberCommandHandler.swift` — `compactMap` substituído por `try map` lançando o erro tipado.

**IO/Persistence:**
- `IO/Persistence/SQLKit/Models/PatientDatabaseModels.swift` — `FamilyMemberModel.required_documents` removido; novo `FamilyMemberRequiredDocumentModel(patient_id, person_id, document_code)`.
- `IO/Persistence/SQLKit/Mappers/PatientDatabaseMapper.swift`:
  - `toDatabase`: `flatMap` para gerar 1 row da tabela filha por documento de cada membro.
  - `toDomain`: agrupa rows por `person_id` (lookup `[UUID: [RequiredDocument]]`); valida `RequiredDocument(rawValue:)` por defesa em profundidade — code inválido lança `PersistenceDataIntegrityError.invalidEnumValue`.
  - `PatientDatabaseSnapshot` ganha `familyMemberRequiredDocuments`.
- `IO/Persistence/SQLKit/SQLKitPatientRepository.swift`:
  - `save`: `deleteAndInsert` em cascata na ordem `family_members` → `family_member_required_documents`.
  - `loadAggregate`: SELECT extra na tabela filha; passa adiante para o mapper.
- `IO/HTTP/Bootstrap/configure.swift` — `FamilyMemberRequiredDocumentsTable()` registrada na lista de migrations.

## Decisões arquiteturais

1. **Tabela filha 1NF (Opção A) sobre `TEXT[]` PostgreSQL ou regex CHECK** — preserva indexação, CHECK constraint claro, FK por elemento possível, espaço para metadata futura sem nova migration.
2. **Drop em mesma migration (exceção ao expand-contract de ADR-019)** — justificada por (a) volume baixo dev/staging, (b) único leitor é o mapper que migra junto, (c) `revert()` simétrico recria a coluna + repopula via `json_agg`. Documentado em ADR-020 e referenciado como exceção válida.
3. **Mapper na leitura re-valida via `RequiredDocument(rawValue:)`** — defesa em profundidade. CHECK no schema bloqueia SQL direto; mapper bloqueia row plantada por bug futuro. Erro lançado é `PersistenceDataIntegrityError.invalidEnumValue` (já existente — não criou novo erro IO).
4. **Erro de IO usado no mapper** (não erro de Application) — preserva direção de dependência (IO não importa Application).
5. **Lint normalizado por espaços/quebras** — primeira versão do lint pegou falso positivo (`compactMap` em outro contexto + `RequiredDocument` em contexto separado). Refinado para casar a expressão exata `.compactMap{RequiredDocument(rawValue:` (após `replacingOccurrences`).
6. **Ordem `family_members` → `family_member_required_documents` no save** — FK exige parent existir antes do filho. Documentado inline.

## Antes vs depois

```diff
 // AddFamilyMemberCommandHandler.swift
-let docs = command.requiredDocuments.compactMap { RequiredDocument(rawValue: $0) }
+let docs = try command.requiredDocuments.map { raw in
+    guard let doc = RequiredDocument(rawValue: raw) else {
+        throw AddFamilyMemberError.invalidRequiredDocument(raw)
+    }
+    return doc
+}

 // PatientDatabaseMapper.swift toDomain
-let rawDocs = (try? decoder.decode([String].self, from: Data(m.required_documents.utf8))) ?? []
-let docs = rawDocs.compactMap { RequiredDocument(rawValue: $0) }
+var docsByMember: [UUID: [RequiredDocument]] = [:]
+for row in familyMemberRequiredDocuments {
+    guard let doc = RequiredDocument(rawValue: row.document_code) else {
+        throw PersistenceDataIntegrityError.invalidEnumValue(...)
+    }
+    docsByMember[row.person_id, default: []].append(doc)
+}
+let docs = docsByMember[m.person_id] ?? []
```

```sql
-- Pré
family_members.required_documents TEXT  -- ["RG","CPF"] inline

-- Pós
CREATE TABLE family_member_required_documents (
    patient_id    UUID NOT NULL,
    person_id     UUID NOT NULL,
    document_code TEXT NOT NULL,
    PRIMARY KEY (patient_id, person_id, document_code),
    FOREIGN KEY (patient_id, person_id)
        REFERENCES family_members(patient_id, person_id)
        ON DELETE CASCADE,
    CONSTRAINT chk_family_member_required_document_code
        CHECK (document_code IN ('CN','RG','CTPS','CPF','TE'))
);
```

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-019 (já reportados) | 17 fechados | 18 ADRs + ADR-019 (meta) | 96 testes |
| T-020 | S-H-A7 + DB-5 | ADR-020 | 9 |
| **Total** | **18 fechados** | **20 ADRs** | **105 regression tests** |

## Próximos tickets sugeridos (Fase 4)

- **T-021** — Diff-based upsert preserva identidade de entidades-filhas (S-H-P1 + DB-6). `family_members` agora pronto para isso (única coluna composta saiu).
- **T-022** — JSONB + TIMESTAMPTZ + DATE corretos.
- **T-023** — `created_at`/`updated_at` automáticos em todas raízes.
- **T-024.a/.b/.c** — Decomposição em sub-agregados (Assessment → Protection → Care).
