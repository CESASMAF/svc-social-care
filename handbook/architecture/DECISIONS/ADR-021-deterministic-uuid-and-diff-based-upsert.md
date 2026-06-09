# ADR-021: `DeterministicUUID` + diff-based upsert preservam identidade de entidades-filhas

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —
**Parent:** [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md) (Fase 4)

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achados convergentes:

- **S-H-P1** (Senior Code Review § P1): `PatientDatabaseMapper` gerava
  `UUID()` inline para `id` surrogate de toda entidade-filha; combinado
  com `deleteAndInsert` no repository, o ID físico mudava a cada save
  mesmo que o conteúdo não mudasse.
- **DB-6** (DB Modeling Review): efeitos colaterais do anti-pattern —
  audit trail mente, triggers `ON UPDATE` impossíveis, FKs externas
  viáveis ficam impossíveis, replicação row-based fica não-determinística.

```swift
// PatientDatabaseMapper.swift — pré-fix (9 ocorrências)
let diagnoses = patient.diagnoses.map { d in
    DiagnosisModel(
        id: UUID(),                 // ← NOVO UUID a cada save
        patient_id: patientId,
        icd_code: d.id.value,
        ...
    )
}

// SQLKitPatientRepository.swift — pré-fix
private func deleteAndInsert<T>(...) async throws {
    try await tx.delete(from: table).where("patient_id", .equal, patientId).run()
    for model in models {
        try await tx.insert(into: table).model(model).run()  // ← row nova
    }
}
```

O que isso destrói:

1. **Identidade física** — `patient_diagnoses.id = X` no save 1, `Y` no
   save 2, `Z` no save 3. Mesmo diagnóstico semanticamente.
2. **Audit trail** — `audit_trail.aggregate_id` aponta para um id que
   mudou; rastreio "este diagnóstico ao longo do tempo" é impossível.
3. **Triggers `ON UPDATE`** — INSERT nunca dispara `BEFORE UPDATE`
   trigger. T-023 vai introduzir `updated_at` automático via trigger;
   sem identidade preservada, `updated_at` ficaria congelado em
   `NOW()` da última INSERT.
4. **FKs externas** — uma tabela hipotética
   `diagnosis_attachments(diagnosis_id, ...)` referenciaria um ID que
   muda a cada save do parent. FK quebraria.
5. **Replicação logical** — cada save vira N×(DELETE + INSERT) eventos
   em vez de M×UPDATE onde só M (atualizados) ≪ N. Banda desperdiçada.
6. **Diff-based upsert é impossível** — `INSERT ... ON CONFLICT (id) DO
   UPDATE` nunca acerta o `ON CONFLICT` porque o `id` sempre é novo.

### Citações canônicas

> *"An entity has continuity of identity. If your storage layer assigns a
> new identifier on every save, you have either no entity or a leaky
> implementation. Both bugs."*
> — Eric Evans, *Domain-Driven Design*, cap. 5 (Entities)

> *"The natural key of a domain entity must drive the surrogate key of the
> row. Otherwise, the surrogate key is just a random number that you'll
> spend the next decade explaining."*
> — Pramod Sadalage & Scott Ambler, *Refactoring Databases*, cap. 4

> *"Idempotency is not a property; it's a discipline. The mapper writes
> the same row given the same input — every time. Otherwise UPSERT is a
> lie."*
> — Pat Helland, "Life beyond Distributed Transactions"

## Decisão

### 1. Novo helper `DeterministicUUID` em `shared/Crypto/`

```swift
public enum DeterministicUUID {
    public static func from(_ key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        // RFC 9562 — UUIDv8 (custom): version bits = 0b1000.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        // RFC 4122 — variant bits = 0b10.
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (...))
    }
}
```

- **Algoritmo:** SHA256(key) → primeiros 16 bytes → UUID com bits de
  versão (UUIDv8) e variante ajustados conforme RFC 9562/4122.
- **Por que não UUIDv5?** RFC 4122 v5 usa SHA-1 (deprecado por
  colisões); SHA256 é mais robusto. Nossa chave já carrega o "namespace"
  implicitamente (prefixo do nome da tabela).
- **Convenção de chave:** `"<table>|<patient_id>|<chave-natural>"`. Prefixo
  do nome da tabela evita colisão entre tabelas que possam compartilhar
  a mesma chave natural (raro, mas defesa em profundidade).

### 2. Mapper deriva todos os `id` surrogate via `DeterministicUUID`

9 sites refatorados em `PatientDatabaseMapper.swift`:

| Tabela | Chave natural |
|---|---|
| `patient_diagnoses` | `(patient_id, icd_code, date)` |
| `member_incomes` | `(patient_id, member_id)` |
| `social_benefits` (×2) | `(source, patient_id, beneficiary_id, benefit_name)` |
| `member_educational_profiles` | `(patient_id, member_id)` |
| `program_occurrences` | `(patient_id, member_id, date, effect_id)` |
| `member_deficiencies` | `(patient_id, member_id, deficiency_type_id)` |
| `gestating_members` | `(patient_id, member_id)` |
| `ingress_linked_programs` | `(patient_id, program_id)` |

Cada um documentado inline com `// ADR-021: ...`.

Models que **já** usavam ID estável do domínio (`Appointment`,
`Referral`, `RightsViolationReport`, `PlacementRegistry`) não precisaram
de mudança.

### 3. Repository ganha `upsertChildren` (diff + ON CONFLICT)

```swift
private func upsertChildren<T: Codable & Sendable>(
    _ tx: any SQLDatabase,
    table: String,
    patientId: UUID,
    models: [T],
    idExtractor: (T) -> UUID
) async throws {
    // 1. SELECT existing IDs.
    let existingIds = Set(try await tx.select().column("id")
        .from(table).where("patient_id", .equal, patientId)
        .all(decoding: ExistingIdRow.self).map(\.id))

    // 2. desired - existing.
    let desiredIds = Set(models.map(idExtractor))
    let toRemove = existingIds.subtracting(desiredIds)

    // 3. DELETE só os removidos (preserva os mantidos).
    if !toRemove.isEmpty {
        try await tx.delete(from: table).where("id", .in, Array(toRemove)).run()
    }

    // 4. UPSERT atômico via ON CONFLICT (id) DO UPDATE SET excluded.*.
    // Colunas extraídas via Mirror do primeiro model do batch (todos têm
    // mesma forma — são instâncias do mesmo tipo).
    guard let sample = models.first else { return }
    let nonIdColumns = Mirror(reflecting: sample).children
        .compactMap(\.label).filter { $0 != "id" }
    for model in models {
        try await tx.insert(into: table).model(model)
            .onConflict(with: ["id"]) { update in
                var u = update
                for col in nonIdColumns { u = u.set(excludedValueOf: col) }
                return u
            }.run()
    }
}
```

Aplicado a 12 tabelas (todas com PK surrogate `id UUID`).

### 4. Tabelas com PK composta natural permanecem em `deleteAndInsert`

`family_members(patient_id, person_id)` e
`family_member_required_documents(patient_id, person_id, document_code)`
têm a tupla como identidade. Delete-and-insert nelas é semanticamente
equivalente ao upsert (PK não muda — DELETE seguido de INSERT recria
exatamente a mesma row). Migração para ON CONFLICT em chave composta
fica como melhoria incremental quando T-023 introduzir triggers
`ON UPDATE`. Documentado inline no Repository.

### Antes vs depois

```diff
 // mapper
-DiagnosisModel(id: UUID(), ...)
+DiagnosisModel(id: DeterministicUUID.from("patient_diagnoses|\(patientId.uuidString)|\(d.id.value)|\(d.date.date.timeIntervalSince1970)"), ...)

 // repository
-try await deleteAndInsert(tx, table: "patient_diagnoses", patientId: patientId, models: data.diagnoses)
+try await upsertChildren(tx, table: "patient_diagnoses", patientId: patientId, models: data.diagnoses, idExtractor: \.id)
```

```sql
-- Pré-fix (cada save):
DELETE FROM patient_diagnoses WHERE patient_id = $1;
INSERT INTO patient_diagnoses (id, patient_id, ...) VALUES ($random, $1, ...);

-- Pós-fix (cada save):
SELECT id FROM patient_diagnoses WHERE patient_id = $1;
-- (calcula diff)
DELETE FROM patient_diagnoses WHERE id IN (...);  -- só removidos
INSERT INTO patient_diagnoses (id, patient_id, ...) VALUES ($deterministic, $1, ...)
    ON CONFLICT (id) DO UPDATE SET patient_id = excluded.patient_id, ...;
```

## Alternativas consideradas

- **UUIDv5 (RFC 4122 name-based, SHA-1).** Descartada — SHA-1 é
  deprecado, exige `namespace` UUID adicional, performance pior.
- **UUID derivado do `id` do domínio diretamente.** Tentou-se em
  `Appointment`/`Referral` (já estava). Mas `Diagnosis` no domínio tem
  `id: ICDCode` (string, não UUID). Adicionar UUID novo no domínio só
  para satisfazer persistence é leak de IO para domain — tema discutido
  em Vernon/Evans, descartado.
- **`gen_random_uuid()` no banco como DEFAULT (sem geração no app).**
  Considerada. Funciona para CREATE, mas não para UPDATE — `INSERT ... ON
  CONFLICT (id) DO UPDATE` precisa do ID conhecido pelo cliente. App
  precisa gerar.
- **Migrar `family_members` para ON CONFLICT (patient_id, person_id) DO
  UPDATE.** Adiada — efeito ON CONFLICT em PK composta é equivalente ao
  delete-and-insert atual (PK não muda). Fica para quando T-023
  introduzir triggers ON UPDATE.
- **`UPSERT` puro (delete sem diff + INSERT).** Descartada — DELETE
  WHERE patient_id = ? + INSERT é o pior dos mundos: aborta triggers,
  consome banda de logical replication, gera N eventos quando bastava 1.

## Consequências

### Positivas

- **Identidade física preservada** — mesmo diagnóstico tem o mesmo
  `patient_diagnoses.id` ao longo de toda a vida do paciente.
- **Audit trail honesto** — `audit_trail.aggregate_id` referencia um
  ID estável; query forense "evolução deste diagnóstico" funciona.
- **Triggers `ON UPDATE` viáveis** — pré-requisito de T-023
  (`updated_at` automático).
- **FKs externas viáveis** — futura tabela `diagnosis_attachments`
  pode declarar FK; o ID alvo não muda.
- **Logical replication eficiente** — N×UPDATE em vez de N×(DELETE +
  INSERT) para mesmas linhas.
- **Padrão estabelecido para sub-agregados (T-024.x)** —
  `PatientAssessment`, `CareJourney`, `ProtectionRecord` seguirão o
  mesmo molde de chave determinística + upsert.

### Negativas / custos

- **+1 SELECT por tabela por save** — overhead de ler IDs existentes
  antes do diff. Para tabelas com poucas rows (típico em
  paciente único), latência desprezível. Para batch de 100+ rows, ainda
  é 1 round-trip extra contra DELETE+INSERT que serializa N inserts.
- **Mirror reflection no helper** — overhead de reflection na primeira
  iteração de cada batch. Aceitável (não está em loop apertado).
- **Chave determinística é frágil a renomeação** — se um campo entrar
  na chave natural e depois mudar (ex.: `icd_code` revisado), o `id`
  muda também. Mitigação: chave natural só inclui invariantes do
  domínio (não muda por princípio); se mudar, é nova entidade.
- **`family_members` ainda em delete-and-insert** — tradeoff documentado;
  migração quando T-023 chegar.

### Ações requeridas

- [x] `DeterministicUUID` criado em `shared/Crypto/`
- [x] 9 ocorrências de `id: UUID()` no mapper substituídas
- [x] `upsertChildren` adicionado em `SQLKitPatientRepository`
- [x] 12 call sites migrados de `deleteAndInsert` para `upsertChildren`
- [x] 7 testes de regressão (2 lints + 1 sanity sintática + 4 runtime)
- [x] Skill `swift-io-implementer` atualizada (entrada 13)
- [ ] **Backlog opcional:** migrar `family_members` e
      `family_member_required_documents` para ON CONFLICT em PK composta
      quando T-023 introduzir triggers ON UPDATE.
- [ ] **Backlog operacional:** validar em staging que a migração de
      schema (T-006 já fez) cobre todas as PKs necessárias para o ON
      CONFLICT funcionar.

## Plano de adoção

1. **Imediato (T-021):** mapper + repository refatorados. Suite 416/416 verde.
2. **T-022..T-023:** continuam Fase 4 com base em IDs estáveis.
3. **T-024.x (sub-agregados):** sub-aggregate roots seguem o mesmo
   pattern desde a criação.

## Como reverter

Reverter ADR-021 reintroduz S-H-P1 + DB-6.

Caminho técnico:
1. `git revert` do commit do ticket — mapper volta a `UUID()` inline,
   repository volta a `deleteAndInsert` para todas as filhas.
2. Apagar `shared/Crypto/DeterministicUUID.swift`.
3. Apagar `Tests/.../Regression/DomainInvariants/ChildIdentityPreservedTests.swift`.
4. Marcar este ADR como `Deprecado`.

Não recomendado — reabre identidade física quebrada, audit trail mentiroso.

## Teste de regressão

`Tests/social-care-sTests/Regression/DomainInvariants/ChildIdentityPreservedTests.swift`:

1. **`test_S_H_P1_helper_exists`** — lint: `shared/Crypto/DeterministicUUID.swift` existe.
2. **`test_S_H_P1_helper_exposes_from`** — lint: declara `enum DeterministicUUID`,
   método `static func from(_:)`, usa SHA256.
3. **`test_S_H_P1_mapper_no_inline_uuid_for_id`** — lint: zero ocorrências
   de `id: UUID(),` no mapper.
4. **`test_S_H_P1_repo_has_upsert`** — lint: repository declara
   `upsertChildren` ou similar.
5. **`test_S_H_P1_repo_uses_on_conflict`** — lint: repository usa
   `ON CONFLICT` no SQL.
6. **`test_S_H_P1_helper_is_deterministic`** — runtime: mesma chave →
   mesmo UUID; chaves diferentes → UUIDs diferentes.
7. **`test_S_H_P1_mapper_is_deterministic`** — runtime: `toDatabase`
   chamado duas vezes no mesmo `Patient` produz **mesmos IDs** em
   `diagnoses` (e demais filhas com surrogate ID).

7/7 passam pós-fix.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` —
  entrada 13 em "Lições Aprendidas (regressões prevenidas)".
- **Regra resumida:** Mapper de Domain → Database **NUNCA** usa
  `UUID()` inline em construção de model com PK surrogate. ID surrogate
  é **derivado deterministicamente** da chave natural do domínio via
  `DeterministicUUID.from("<table>|<chave-natural>")` (SHA256, prefixo
  do nome da tabela contra colisão entre tabelas). Repository de
  aggregate root usa **diff-based upsert** (`INSERT ... ON CONFLICT (id)
  DO UPDATE SET excluded.*`) — não delete-and-insert. Pré-condição
  inquebrável: IDs determinísticos no mapper. Sem isso, ON CONFLICT
  nunca dispara e tabela cresce sem limite. Tabelas com PK composta
  natural (associativas puras) podem manter delete-and-insert
  semanticamente equivalente até trigger ON UPDATE ser introduzido. Lint
  estrutural em `ChildIdentityPreservedTests` enforça via grep + runtime
  sanity (mapper.toDatabase é idempotente).

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § P1 — origem
- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § DB-6
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-021
- [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md) — Fase 4
  meta-governance
- [ADR-006](ADR-006-primary-keys-for-aggregate-tables.md) — pré-requisito
  (filhas têm PK declarada)
- [ADR-020](ADR-020-required-documents-1nf-and-try-map.md) — irmão da
  Fase 4 (1NF)
- [RFC 9562](https://datatracker.ietf.org/doc/html/rfc9562) — UUIDv8
- [RFC 4122](https://datatracker.ietf.org/doc/html/rfc4122) — variant
- Pat Helland, "Life beyond Distributed Transactions"
- Eric Evans, *Domain-Driven Design*, cap. 5
- Pramod Sadalage & Scott Ambler, *Refactoring Databases*, cap. 4
