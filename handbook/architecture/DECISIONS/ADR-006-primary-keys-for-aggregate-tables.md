# ADR-006: Toda tabela é uma relação com PK declarada

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** um ADR só pode ficar `Aceito`
> quando **todas** as seções abaixo estão preenchidas — incluindo `Teste de
> regressão` e `Better Pattern para skills`. ADR sem essas duas seções fica
> `Proposto` até completar.

## Contexto

A revisão teórica de modelagem de banco (`handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § Achado 1) identificou que duas tabelas-filhas do agregado `Patient` foram criadas em `2026_02_24_CreateInitialSchema` **sem chave primária**:

- `family_members` (`patient_id`, `person_id`, `relationship`, `is_primary_caregiver`, `resides_with_patient`, …)
- `patient_diagnoses` (`patient_id`, `icd_code`, `date`, `description`)

No modelo relacional formal (Ramakrishnan & Gehrke, *Database Management Systems*, Cap. 3):

> *"Each row in a relation represents a unique tuple. A relation has a primary key, which is a minimal subset of attributes that uniquely identifies each tuple."*

Sem PK, o que está na tabela **não é tecnicamente uma relação** — é um *multi-set*. SQL aceita por permissividade histórica; o modelo relacional não admite. Consequências práticas:

1. **Importação externa / ETL / fix manual via SQL** — nada impede dois diagnósticos idênticos para o mesmo paciente no mesmo dia.
2. **Replicação row-based** — sem PK explícita, replicadores não conseguem localizar a tupla a replicar de forma determinística.
3. **Referências futuras** — se algum dia uma tabela referenciar um `family_member` específico (caso de uso real: T-013 amarra `member_incomes.member_id` a `family_members`), não há alvo de FK.
4. **DELETE seletivo via SQL puro** — "deletar só o cônjuge" é impossível sem critério extra ou inspeção tupla a tupla.

O domínio já sabe que `FamilyMember` tem identidade por `personId` (`FamilyMember.swift:60-63` define `==` por `lhs.personId == rhs.personId`). O schema precisava refletir isso.

Por que o bug passou despercebido até agora:

- O repositório (`SQLKitPatientRepository.swift:256-266`) usa `deleteAndInsert` em todas as filhas a cada `save()` — apaga tudo e re-insere. "Esconde" a ausência de PK na via canônica.
- Em produção, ninguém estava fazendo ETL direto ou replicação — então o bug ficou latente.
- Achado só foi capturado quando a revisão teórica olhou o schema com a lente formal de Ramakrishnan.

## Decisão

Adicionar PK em ambas as tabelas via migration `2026_05_14_AddPrimaryKeysForFamilyMembersAndDiagnoses`:

### `family_members`: PK natural composta `(patient_id, person_id)`

```sql
ALTER TABLE family_members
ADD CONSTRAINT family_members_pkey PRIMARY KEY (patient_id, person_id);
```

Reflete exatamente o `==` do domínio. Permite FK composta de filhas (`member_incomes`, `member_educational_profiles`, …) → `family_members(patient_id, person_id)` quando T-013 chegar.

### `patient_diagnoses`: PK surrogate `id UUID` + UNIQUE natural

```sql
ALTER TABLE patient_diagnoses
ADD COLUMN id UUID NOT NULL DEFAULT gen_random_uuid();

ALTER TABLE patient_diagnoses
ADD CONSTRAINT patient_diagnoses_pkey PRIMARY KEY (id);

ALTER TABLE patient_diagnoses
ADD CONSTRAINT uq_patient_diagnosis UNIQUE (patient_id, icd_code, date);
```

Por que **surrogate** e não PK natural composta:
- Outras tabelas (futuro) podem precisar referenciar um diagnóstico específico (auditoria, anexos, mudança histórica). PK natural composta com 3 colunas é incômoda como FK.
- O domínio `Diagnosis` é imutável em seu instante — mas pode ser referenciado por outras entidades.
- UNIQUE natural `(patient_id, icd_code, date)` preserva o invariante "um diagnóstico por CID/data por paciente" — equivalente à PK natural.

### Pré-flight check: fail-safe

A migration **detecta duplicatas pré-existentes** antes de aplicar a PK e **aborta com mensagem útil** se encontrar. Não fazemos DELETE automático (princípio CRU/No Delete + histórico social é sagrado).

Operador recebe a duplicata específica (patient_id, person_id) e um SELECT pronto para diagnosticar. Cleanup manual é exigido antes de re-aplicar a migration.

## Alternativas consideradas

- **PK natural composta também em `patient_diagnoses` (`patient_id, icd_code, date`).** Descartada porque outras tabelas ficariam com FK composta de 3 colunas — fricção operacional crescente. Surrogate + UNIQUE preserva o invariante e mantém FK enxuta (1 coluna).
- **Apenas adicionar `id UUID` em ambas, sem natural unique.** Descartada — perderia o invariante "uma combinação por paciente" que o domínio assume. Importação externa quebraria semântica silenciosamente.
- **`DELETE` automático de duplicatas no `prepare`.** Descartada — viola CRU/No Delete e destrói histórico sem aprovação humana. Migration deve ser idempotente e segura, não destrutiva.
- **Adiar PK até T-021 (diff-based upsert).** Descartada — T-021 *depende* de PK estável. Sem PK, não há "diff" determinístico. T-006 é pré-requisito explícito de T-021 na pipeline.
- **PK por hash de colunas (md5/sha)** em `patient_diagnoses`. Descartada — exótico, não-portável, opaco para debug. Surrogate UUID é o padrão Postgres.

## Consequências

### Positivas

- `family_members` e `patient_diagnoses` viram relações no sentido formal.
- T-007 (FK `relationship_id`), T-008 (FKs lookups), T-013 (FK composta `member_id`), T-021 (diff-based upsert), T-024 (decomposição) ficam todos liberados.
- Importação ETL futura ganha enforcement automático contra duplicatas.
- Replicação row-based determinística.
- Schema fica auditável formalmente — `pg_dump` mostra constraint nominal explícita.

### Negativas / custos

- Pré-existentes dados sujos em dev/staging exigem cleanup manual antes da migration. Mitigação: mensagem de erro útil com SELECT pronto.
- Cada Diagnosis no domínio agora gera UUID novo no mapper. Quando T-021 chegar (diff-based upsert), o `id` precisa ser estável entre saves — o domínio `Diagnosis` precisará carregar `id: UUID` (não está no escopo deste ticket).
- Custo de migração em produção: `ALTER TABLE` em tabelas grandes pode lockar. Mitigação: aplicar fora do horário de pico OU usar `CREATE INDEX CONCURRENTLY` + `ALTER TABLE` em duas fases (futuro, se necessário).

### Ações requeridas

- [x] Criar migration `2026_05_14_AddPrimaryKeysForFamilyMembersAndDiagnoses.swift`
- [x] Adicionar coluna `id: UUID` em `DiagnosisModel`
- [x] Mapper popula UUID novo por Diagnosis (até T-021 — depois, ID estável do domínio)
- [x] Registrar migration em `configure.swift`
- [x] Teste de regressão estrutural em `Regression/DataIntegrity/`
- [x] Atualizar skill `swift-io-implementer` com padrão "Migration de PK + pré-flight"
- [ ] **T-007 (Fase 1):** trocar `family_members.relationship` (TEXT) por `relationship_id UUID + FK` — agora viável porque FK composta `(patient_id, person_id)` está disponível
- [ ] **T-013 (Fase 5):** FK composta de filhas → `family_members(patient_id, person_id)`
- [ ] **T-021 (Fase 4):** trocar delete-and-insert por diff-based upsert — precisa de ID estável no domínio `Diagnosis`

## Plano de adoção

1. **Imediato (T-006 — este ticket):** migration declarada + registrada. Teste de regressão estrutural passa. Build + suite 335/335 verde.
2. **Dev local:** próximo `make dev` aplica a migration. Se houver duplicatas em dev (improvável após reset frequente), aborta com mensagem útil.
3. **Staging:** rodar `make migrate` (ou equivalente) antes do deploy do binário com este patch. Se duplicatas detectadas, executar SELECTs de cleanup e re-rodar.
4. **Produção:** aplicar fora do horário de pico. ALTER TABLE em tabelas com poucos milhares de rows é instantâneo; com milhões, planejar.
5. **Próximos tickets que dependem disto:** T-007, T-013, T-021, T-024.

## Como reverter

Reverter ADR-006 reintroduz o bug DB-1.

Caminho técnico:

1. Rodar migration `revert`: `DROP CONSTRAINT` + `DROP COLUMN id`.
2. Reverter mudança em `DiagnosisModel` e Mapper.
3. Marcar este ADR como `Deprecado` com justificativa.

Não recomendado — perderia também T-007/T-013/T-021/T-024 que ficam liberados aqui.

## Teste de regressão

`Tests/social-care-sTests/Regression/DataIntegrity/AggregateTableHasPKRegressionTests.swift`:

1. **`test_DB_1_family_members_has_pk_declared`** — busca em todos os `.swift` de Migrations/ uma declaração contendo `family_members`, `primary key`, `patient_id`, `person_id`.
2. **`test_DB_1_patient_diagnoses_has_pk_id`** — busca declaração com `patient_diagnoses`, `add column`, `id`, `uuid`, `primary key`.
3. **`test_DB_1_patient_diagnoses_has_natural_unique`** — busca declaração de `UNIQUE (patient_id, icd_code, date)`.
4. **`test_DB_1_pk_migration_has_rollback`** — valida que a migration tem `func revert` + `drop constraint` (simétrico).

**Limitação documentada:** este teste é **estrutural** (inspeciona arquivo), não comportamental (não roda SQL). Se algum dia o suite ganhar Postgres em CI, complementar com teste de integração que aplica a migration, tenta INSERT duplicado, e espera `PersistenceConflictError.uniqueViolation` (planejado em T-033 como schema snapshot).

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` — entrada na tabela "Lições Aprendidas" + seção "Padrão Migration de PK com pré-flight".
- **Regra resumida:** toda nova migration que cria tabela DEVE declarar PK (natural ou surrogate). Migration que adiciona PK em tabela existente DEVE incluir pré-flight check de duplicatas + `revert` simétrico + nunca DELETE automático (princípio CRU/No Delete). Forward + rollback testados em fixture vazia ANTES do PR.

## Referências

- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § Achado 1 — origem do achado
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-006 — especificação
- [ADR-002](ADR-002-regression-test-policy.md) — política de testes de regressão
- [ADR-005](ADR-005-optimistic-locking-via-version.md) — outro caso de "invariante que o domínio assume mas o schema não enforça"
- Ramakrishnan & Gehrke, *Database Management Systems*, Cap. 3 (Relational Model) e Cap. 19 (Schema Refinement)
- C.J. Date, *An Introduction to Database Systems* — princípio formal de relação
- PostgreSQL Reference Manual — `ALTER TABLE ADD CONSTRAINT`, `gen_random_uuid()`
