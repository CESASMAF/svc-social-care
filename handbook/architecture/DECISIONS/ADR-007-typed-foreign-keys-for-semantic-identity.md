# ADR-007: Colunas que carregam identidade semântica usam tipo nativo + FK

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** um ADR só pode ficar `Aceito`
> quando **todas** as seções abaixo estão preenchidas — incluindo `Teste de
> regressão` e `Better Pattern para skills`. ADR sem essas duas seções fica
> `Proposto` até completar.

## Contexto

Achado confirmado por duas lentes independentes:

- **DB-4** (Database Modeling Review § Achado 4) — Ramakrishnan, Cap. 3.1 (Column Domain): "Each attribute has a name and a domain, which is a set of allowed values. The domain restricts what values can appear in that attribute." Declarar `relationship TEXT` quando o valor real é UUID semântico que aponta para `dominio_parentesco.id` é declarar o tipo errado. Banco aceita qualquer string — `"cônjuge"`, `"foo bar"`, UUID malformado.
- **S-H-D5** (Senior Code Review § Primitive Obsession) — Fowler, *Refactoring* p. 68: "Strings are particularly common petri dishes for this kind of odor. […] Representing such types as strings is such a common stench that people call them 'stringly typed' variables." `family_members.relationship` é exatamente esse caso.

Cenário do bug:

```sql
-- Schema atual (pré-fix): aceita silenciosamente
INSERT INTO family_members (patient_id, person_id, relationship, ...)
VALUES ('uuid1', 'uuid2', 'cônjuge', ...);  -- ✅ aceito
INSERT INTO family_members (patient_id, person_id, relationship, ...)
VALUES ('uuid1', 'uuid3', 'foo bar', ...);  -- ✅ aceito (sem FK)
```

O domínio (`Mapper.loadAggregate`) faz `try LookupId(m.relationship)` na decodificação — quebra no read. Em produção, descobre-se o problema só quando alguém tenta ler aquele paciente. Em ETL/replicação, dados sujos passam silenciosamente.

Conexão com outros achados:

- **DB-3** (FKs lookups não declaradas) — a coluna deveria ter FK para `dominio_parentesco(id)`. Sem FK, soft-delete de item de lookup não rastreia uso futuro; renomeação de lookup torna refs órfãs.
- **T-013** (futuro) — FK composta `(patient_id, member_id) → family_members(patient_id, person_id)` precisa que `family_members` tenha PK composta (ADR-006). T-007 segue T-006 na cadeia.

## Decisão

Migração **expand-contract** (não-destrutiva) tipifica a coluna:

1. **Add** nova coluna `relationship_id UUID NULL`
2. **Pré-flight**: detectar valores `relationship` que não são UUID canônico (regex Postgres `^[0-9a-f]{8}-...$`). Se houver, abortar com mensagem útil + cleanup manual (princípio CRU/No Delete — não deletamos).
3. **Backfill**: `UPDATE family_members SET relationship_id = relationship::UUID`
4. **SET NOT NULL** + **ADD FOREIGN KEY** → `dominio_parentesco(id) ON DELETE RESTRICT`
5. **DROP COLUMN** `relationship` antiga (contract phase)

Política `ON DELETE RESTRICT` para lookup tables: nunca CASCADE ou SET NULL — soft-delete via `ativo: false` é a forma correta de "retirar" um item de lookup sem quebrar refs históricas.

`FamilyMemberModel.relationship_id: UUID` substitui `relationship: String` no Codable do mapper. Decoder lê UUID nativo (não string interpolada).

## Alternativas consideradas

- **Manter `relationship TEXT` + CHECK constraint que valida formato UUID via regex.** Descartada — CHECK protege formato mas não amarra a existência do alvo. Sem FK, lookup deletado quebra refs silenciosamente.
- **Coluna `relationship_id` + manter `relationship TEXT` como redundância de debug.** Descartada — duplicação custosa, fonte de inconsistência. Schema enxuto vale mais.
- **DROP TABLE + recreate via migration "destrutiva".** Descartada — viola CRU/No Delete + custosa em produção. Expand-contract é o padrão Postgres.
- **Esperar T-027 (naming PT/EN universal) para fazer junto.** Descartada — T-027 é cosmético; T-007 corrige bug real. Renomeação cosmética não merge no mesmo PR de fix estrutural.
- **Adiar até T-024 (decomposição de god aggregate).** Descartada — T-007 desbloqueia T-013 (FK composta) e T-008 (FKs de lookups). Mantém a pipeline fluindo.

## Consequências

### Positivas

- Banco rejeita inserções malformadas ou órfãs no momento da escrita (DB enforcement).
- Soft-delete de item `dominio_parentesco` bloqueado se há uso → operador trata explicitamente.
- Renomeação de item de lookup: UUID estável; só `descricao` muda; refs continuam válidas.
- Primitive Obsession eliminado nessa coluna específica.
- Pipeline T-013 desbloqueada (FK composta de filhas precisa que `family_members` tenha PK composta + tipos coerentes).

### Negativas / custos

- Migração custosa em produção: `ALTER TABLE` + `UPDATE` em todas as linhas de `family_members`. Tempo proporcional ao tamanho da tabela. Mitigação: aplicar fora do horário de pico; com poucos milhares de linhas, < 1s.
- Pré-flight pode encontrar dados sujos em dev/staging — cleanup manual é exigido (não fazemos DELETE automático).
- Schema fica em estado transitório se a migração for interrompida no meio. Mitigação: SQLKitMigrationRunner já trata como transação por migration (atomicidade).

### Ações requeridas

- [x] Migration `2026_05_14_TypeRelationshipAsUUID.swift` criada (expand-contract)
- [x] `FamilyMemberModel.relationship_id: UUID` substitui `relationship: String`
- [x] Mapper popula UUID nativo (`UUID(uuidString: m.relationshipId.description)!`)
- [x] Mapper decodifica para `LookupId` via `m.relationship_id.uuidString`
- [x] Registrado em `configure.swift`
- [x] Teste de regressão estrutural (5 testes)
- [x] Skill `swift-io-implementer` atualizada
- [ ] **T-008 (próximo Fase 1):** declarar FKs ausentes para outras 7 colunas `*_id` → `dominio_*`
- [ ] **T-013 (Fase 5):** FK composta de filhas → `family_members(patient_id, person_id)`

## Plano de adoção

1. **Imediato (T-007 — este ticket):** migration registrada + teste + ADR. Build + suite 340/340 verde.
2. **Dev local:** `make dev` aplica a migration. Em dev limpo (DB fresh), zero linhas — operação instantânea. Com dados pré-existentes válidos, backfill é trivial.
3. **Staging:** rodar migration antes do deploy do binário. Pré-flight detecta dados sujos (se houver) → cleanup manual + re-run.
4. **Produção:** fora do horário de pico. Tabela hoje pequena (< 10k linhas em produção piloto), portanto migration < 1s.
5. **Próximos tickets:** T-008 (FKs lookups restantes) é o próximo CRITICAL DB.

## Como reverter

Reverter ADR-007 reintroduz o anti-pattern Primitive Obsession + falta de FK.

Caminho técnico:

1. Rodar `revert`: recria `relationship TEXT`, backfilla `relationship_id::text`, drop FK + coluna nova.
2. Reverter mudanças em `FamilyMemberModel` + mapper.
3. Marcar este ADR como `Deprecado`.

Não recomendado.

## Teste de regressão

`Tests/social-care-sTests/Regression/DataIntegrity/RelationshipIdIsTypedRegressionTests.swift`:

1. **`test_DB_4_relationship_id_column_declared`** — busca declaração de `ADD COLUMN relationship_id UUID` em alguma migration.
2. **`test_DB_4_relationship_id_has_FK`** — busca `FOREIGN KEY relationship_id REFERENCES dominio_parentesco ON DELETE`.
3. **`test_DB_4_backfill_has_preflight`** — busca `UPDATE … SET relationship_id …` (presença do backfill).
4. **`test_DB_4_old_text_column_dropped`** — busca `DROP COLUMN relationship`.
5. **`test_DB_4_migration_has_revert`** — busca `func revert` simétrico.

5/5 passam após este patch. Falhavam todos antes (RED válido).

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` — entrada 3 em "Lições Aprendidas" + integração no padrão "Migration de PK" para incluir "tipos nativos + FK".
- **Regra resumida:** coluna que carrega identidade semântica (UUID, código de lookup, FK lógica) declara **tipo nativo + FK**, nunca `TEXT`. Migração que tipifica usa **expand-contract** (add nova → backfill → drop antiga) com pré-flight contra valores malformados. FK para lookup table usa `ON DELETE RESTRICT` (nunca CASCADE/SET NULL — soft-delete via flag `ativo`).

## Referências

- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § Achado 4 — origem DB
- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § H-D5 — origem Senior
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-007 — especificação
- [ADR-006](ADR-006-primary-keys-for-aggregate-tables.md) — pré-requisito (PK composta de `family_members`)
- [ADR-002](ADR-002-regression-test-policy.md) — política de testes de regressão
- Ramakrishnan & Gehrke, *Database Management Systems*, Cap. 3.1 (Column Domain) e Cap. 3.3 (Foreign Keys)
- Fowler, *Refactoring* 2ª ed., p. 68 — Primitive Obsession
