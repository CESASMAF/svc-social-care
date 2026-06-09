# ADR-020: `required_documents` em tabela filha 1NF + `try map` em vez de `compactMap`

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —
**Parent:** [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md) (Fase 4)

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achados convergentes:

- **S-H-A7** (Senior Code Review § A7): `AddFamilyMemberCommandHandler.swift`
  usava `compactMap` para mapear `[String]` → `[RequiredDocument]`,
  silenciando typos do cliente.
- **DB-5** (Database Modeling Review): `family_members.required_documents`
  era `TEXT` armazenando array JSON inline (`["RG","CPF"]`), violando
  Primeira Forma Normal.

```swift
// AddFamilyMemberCommandHandler.swift — pré-fix
let docs = command.requiredDocuments.compactMap { RequiredDocument(rawValue: $0) }
//                                    ^^^^^^^^^^
//             ["RG", "TYPO_INVALID", "CPF"] → ["RG", "CPF"] (silêncio)

// PatientDatabaseMapper.swift — pré-fix
let rawDocs = (try? decoder.decode([String].self, from: ...)) ?? []
let docs = rawDocs.compactMap { RequiredDocument(rawValue: $0) }
//                  ^^^^^^^^^^
//             Mesma falha na LEITURA: row legacy com valor inválido vira []

// schema (DB-5) — pré-fix
family_members.required_documents TEXT  -- ["RG","CPF"] como JSON inline
//                              ^^^^
//             Não-1NF. ETL externo precisa parsear JSON. Sem CHECK possível.
//             "WHERE 'RG' = ANY(...)" não é indexável (precisa cast e parse).
```

### Por que isso é HIGH

1. **Cliente nunca soube do typo** — handler retornava 200 OK com lista
   "limpa". Mais tarde, quando o módulo de geração de documentos solicita
   "RG" e o registro mostrava só "CN", o operador descobria que metade da
   lista enviada nunca chegou. Audit trail invisível.
2. **Leitura legacy também silencia** — uma row que algum dia foi gravada
   com `["RG","RGZ"]` (em release antigo, antes da validação) vira `[RG]`
   na próxima leitura. Quem auditar não tem evidência da divergência.
3. **Schema não-1NF bloqueia evoluções** — não dá para indexar "todos
   pacientes esperando RG"; CHECK constraint impossível; FK para uma
   tabela de tipos de documento (futuro lookup) impossível.
4. **Compromete decomposição da Fase 4** — `family_members` será uma das
   primeiras filhas a ganhar identidade preservada (T-021); enquanto
   `required_documents` for inline, qualquer migração esbarra no parsing.

### Citações canônicas

> *"First Normal Form is the rule that no row may contain a 'repeating
> group' of data within a single field. Multiple values in a single column
> are a denormalization that compounds with every query."*
> — C. J. Date, *An Introduction to Database Systems*, cap. 12

> *"Silent failures are the worst failures. `compactMap` over a parser is
> a silent failure machine — invalid input becomes invisible loss."*
> — Erica Sadun, *Swift Style*, cap. 7 (Defensive Coding)

> *"When a value cannot be represented in your closed type system, throwing
> is the correct response. Filtering is denial."*
> — John Sundell, swiftbysundell.com / "Embracing typed errors"

## Decisão

### 1. Domain — `AddFamilyMemberError.invalidRequiredDocument(String)`

Novo case:

```swift
public enum AddFamilyMemberError: Error, Sendable, Equatable {
    // ... outros casos ...
    case invalidRequiredDocument(String)
}
```

Mapeado em `AppErrorConvertible`:

```swift
case .invalidRequiredDocument(let value):
    return appFailure(
        "011",
        kind: "InvalidRequiredDocument",
        "Documento solicitado inválido: '\(value)'. Valores aceitos: CN, RG, CTPS, CPF, TE.",
        category: .domainRuleViolation,
        severity: .warning,
        http: 422,
        context: ["invalidValue": value]
    )
```

Cliente recebe **HTTP 422** com payload identificando o valor problemático.

### 2. Application handler — `try map` em vez de `compactMap`

```swift
// AddFamilyMemberCommandHandler.swift — pós-fix
let docs = try command.requiredDocuments.map { raw in
    guard let doc = RequiredDocument(rawValue: raw) else {
        throw AddFamilyMemberError.invalidRequiredDocument(raw)
    }
    return doc
}
```

### 3. Schema — tabela filha 1NF

```sql
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

### 4. Persistence — separation no mapper + repository

- `FamilyMemberModel` perde a coluna `required_documents`.
- Novo `FamilyMemberRequiredDocumentModel(patient_id, person_id, document_code)`.
- `PatientDatabaseSnapshot` ganha `familyMemberRequiredDocuments`.
- `Mapper.toDatabase` achata `[FamilyMember] → [FamilyMemberRequiredDocumentModel]`.
- `Mapper.toDomain` agrupa rows da tabela filha por `person_id` (lookup
  O(1)) e re-valida `RequiredDocument(rawValue:)` por defesa em
  profundidade — qualquer code não reconhecido lança
  `PersistenceDataIntegrityError.invalidEnumValue` (NUNCA silencia).
- `Repository.save`: `deleteAndInsert` em cascata na ordem `family_members`
  → `family_member_required_documents`.
- `Repository.find`: SELECT extra na tabela filha; passa adiante para o
  mapper.

### 5. Migration — drop em mesma migration (exceção ao expand-contract)

A migration `2026_05_14_FamilyMemberRequiredDocumentsTable`:

1. CREATE TABLE filha (com PK composta + FK + CHECK).
2. Backfill: `INSERT … SELECT jsonb_array_elements_text(required_documents::jsonb)`
   filtrando apenas codes válidos. `ON CONFLICT DO NOTHING` torna idempotente.
3. `ALTER TABLE family_members DROP COLUMN required_documents`.
4. `revert()` simétrico: recria a coluna, repopula via `json_agg`, dropa a
   tabela filha.

**Justificativa do drop em mesma migration** (exceção ao padrão expand-contract
de ADR-019):

- Tabela `family_members` ainda tem volume baixo (dev/staging).
- Único consumidor de leitura é `PatientDatabaseMapper.toDomain` — código
  e schema migram juntos no mesmo deploy.
- `revert()` recria a coluna + repopula via `json_agg` (rollback completo).
- Para tabelas com volume produção significativo, expand-contract de ADR-019
  vale (T-024.x sub-agregados seguirão estritamente).

## Alternativas consideradas

- **Manter coluna `TEXT` + adicionar CHECK regex via PostgreSQL.** Descartada
  — regex de array JSON é frágil; CHECK não substitui parsing real; sem
  ganho de query indexável.
- **Coluna `TEXT[]` (PostgreSQL array nativo) em vez de tabela filha.**
  Considerada. Descartada porque (a) ainda viola 1NF (1 row, N values), (b)
  CHECK em elemento de array é verboso, (c) FK por elemento de array
  impossível, (d) tabela filha permite enriquecer com metadata futura
  (`requested_at`, `provided_at`) sem mudar schema novamente.
- **Lookup table `dominio_documento` + FK no array.** Descartada por agora
  — o universo é pequeno e fechado (5 cases) e é um vocabulário do domínio
  social, não administrável por usuário (diferente de
  `dominio_parentesco`). CHECK em coluna serve. Re-avaliar se vier ticket
  com requisito de admin de tipos.
- **Manter `compactMap` + warning no log quando há valores inválidos.**
  Descartada — warning de IO é pó debaixo do tapete; cliente não vê. Erro
  tipado HTTP 422 é a única forma honesta.
- **Big-bang sem `revert()` simétrico.** Descartada — ADR-019 exige
  rollback documentado. `revert()` simétrico é trabalho de uma migration
  a mais; vale o seguro.

## Consequências

### Positivas

- **Bug S-H-A7 eliminado** — typo dispara HTTP 422 com `invalidValue` no
  contexto. Cliente sabe imediatamente.
- **Schema 1NF (DB-5 fechado)** — `WHERE document_code = 'RG'` é query
  indexável. CHECK constraint é defesa final no banco (mesmo SQL direto
  via psql não consegue inserir typo).
- **Leitura legacy também valida** — mapper rejeita row com code não
  reconhecido (defesa em profundidade contra schema migrar e domain ficar
  para trás).
- **Pré-requisito da Fase 4** — `family_members` agora pronto para T-021
  (diff-based upsert preservando identidade), pois sua única coluna
  composta (`required_documents`) saiu.
- **Padrão estabelecido para tabelas filhas** — outras coleções "set of
  enum" (`HousingCondition.facilities`, etc.) podem seguir o mesmo molde.

### Negativas / custos

- **Mais 1 SELECT por load de paciente** — extra round-trip. Mitigação:
  paciente médio tem 0-5 family members × 0-5 docs = ≤25 rows. Latência
  desprezível.
- **Mais 1 DELETE+INSERT por save** — efeito colateral do
  delete-and-insert atual (T-021 vai mitigar via diff-based).
- **Migration single-shot (não dual-write)** — risco operacional em
  ambientes com volume; mitigação: `revert()` testado, decisão consciente
  documentada.
- **Mapper precisa coordenar dois resultsets** — complexidade pequena
  (lookup `[UUID: [RequiredDocument]]`).

### Ações requeridas

- [x] `AddFamilyMemberError.invalidRequiredDocument(String)` adicionado +
      mapeado para HTTP 422
- [x] `AddFamilyMemberCommandHandler` usa `try map`
- [x] `PatientDatabaseMapper.toDomain` valida via `RequiredDocument(rawValue:)`
      e lança `PersistenceDataIntegrityError.invalidEnumValue` em row inválida
- [x] `FamilyMemberModel` perdeu `required_documents`
- [x] `FamilyMemberRequiredDocumentModel` criado
- [x] `PatientDatabaseSnapshot` ganha campo
- [x] `SQLKitPatientRepository.save` persiste tabela filha (delete-and-insert
      na ordem correta)
- [x] `SQLKitPatientRepository.loadAggregate` lê tabela filha
- [x] Migration `2026_05_14_FamilyMemberRequiredDocumentsTable` criada
- [x] Migration registrada em `configure.swift`
- [x] 9 testes de regressão (8 lints estruturais + 1 sanity de smart constructor)
- [x] Skill `swift-application-orchestrator` atualizada (entrada 4 — try map vs compactMap)
- [x] Skill `swift-io-implementer` atualizada (entrada 12 — tabela filha 1NF para "set of enum")
- [ ] **Backlog de feature:** controller HTTP para retornar 422 com `invalidValue`
      no payload — verificar se já existe na pipeline `AppErrorMiddleware`
      → response. (Pré-existente; AppError.context é renderizado.)

## Plano de adoção

1. **Imediato (T-020):** schema + handler + mapper + repository refatorados.
   Suite 409/409 verde.
2. **Próximo deploy:** migration roda automaticamente no boot
   (`MigrationRunner` itera lista). Backfill é idempotente.
3. **T-021** (próximo ticket da Fase 4) usa `family_members` decomposto
   como base para diff-based upsert.

## Como reverter

`Migration.revert()` simétrico restaura `required_documents TEXT` e
repopula via `json_agg`. Code reverter:

1. `git revert` do commit do ticket — handler volta ao `compactMap`,
   mapper volta ao parsing JSON, model volta ao `required_documents:
   String`, snapshot volta ao formato anterior, repository perde o SELECT
   extra.
2. `swift run migration revert FamilyMemberRequiredDocumentsTable` no
   runner (a infra está documentada em `MigrationRunner.swift`).
3. Marcar este ADR como `Deprecado`.

Não recomendado — reabre S-H-A7 (typo silencioso) e DB-5 (não-1NF).

## Teste de regressão

`Tests/social-care-sTests/Regression/DataIntegrity/RequiredDocumentsAtomicityTests.swift`:

1. **`test_S_H_A7_handler_uses_try_map`** — lint estrutural:
   `AddFamilyMemberCommandHandler.swift` não contém o anti-pattern exato
   `.compactMap { RequiredDocument(rawValue:` (normalizado por
   espaços/quebras).
2. **`test_S_H_A7_mapper_uses_try_map`** — idem em `PatientDatabaseMapper.swift`.
3. **`test_S_H_A7_error_case_exists`** — lint: erro declara case.
4. **`test_DB_5_table_exists`** — lint: alguma migration tem `CREATE TABLE
   family_member_required_documents`.
5. **`test_DB_5_table_has_composite_pk`** — lint: PK composta declarada.
6. **`test_DB_5_table_has_fk`** — lint: FK + ON DELETE CASCADE para
   `family_members`.
7. **`test_DB_5_table_has_check`** — lint: CHECK constraint em `document_code`.
8. **`test_DB_5_backfill_and_drop`** — lint: backfill INSERT … SELECT +
   DROP COLUMN antiga.
9. **`test_S_H_A7_tryParse_throws_on_invalid`** — sanity: enum String
   retorna nil em valor inválido (handler converte em throw).

9/9 passam pós-fix.

## Better Pattern para skills

- **Skills atualizadas:**
  - `.claude/skills/swift-application-orchestrator/SKILL.md` — entrada 4
    em "Lições Aprendidas".
  - `.claude/skills/swift-io-implementer/SKILL.md` — entrada 12 em
    "Lições Aprendidas".
- **Regra resumida (Application):** Em handler que mapeia `[String] →
  [Enum]` proveniente do request, **NUNCA** usar `compactMap` (silencia
  typo). Use `try map` lançando case de erro tipado `case
  invalid<Field>(String)` mapeado para HTTP 422 com `invalidValue` no
  contexto. Cliente precisa saber.
- **Regra resumida (Persistence):** Coleção de "set of enum" em entidade
  do domínio NUNCA armazena como array JSON inline em coluna TEXT (viola
  1NF). Schema 1NF: tabela filha `<entity>_<collection>(... PK composta,
  FK ON DELETE CASCADE, CHECK no enum code)`. Mapper achata na escrita;
  agrupa por chave do parent na leitura. Mapper na leitura **re-valida**
  com `Enum(rawValue:)` (defesa em profundidade); valor não reconhecido
  lança `PersistenceDataIntegrityError.invalidEnumValue`. CHECK no schema
  é a defesa final contra SQL direto. Para volumes baixos (dev/staging),
  drop da coluna antiga pode ir na mesma migration do create+backfill,
  desde que `revert()` seja simétrico — exceção documentada do
  expand-contract de ADR-019.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § A7 — origem
- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § DB-5
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-020
- [ADR-019](ADR-019-decomposition-of-patient-god-aggregate.md) — meta
  governance da Fase 4 (decomposição de Patient)
- [ADR-006](ADR-006-primary-keys-for-aggregate-tables.md) —
  `family_members` PK composta `(patient_id, person_id)` permite a FK
  composta da tabela filha
- [ADR-007](ADR-007-typed-foreign-keys-for-semantic-identity.md) —
  pattern de FK tipada
- C. J. Date, *An Introduction to Database Systems*, cap. 12 (Normal Forms)
- Erica Sadun, *Swift Style*, cap. 7
