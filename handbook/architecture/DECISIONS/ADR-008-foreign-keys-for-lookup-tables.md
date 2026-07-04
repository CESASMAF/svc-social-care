# ADR-008: FK declarada para toda coluna `*_id` que aponta para lookup table

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** um ADR só pode ficar `Aceito`
> quando **todas** as seções abaixo estão preenchidas — incluindo `Teste de
> regressão` e `Better Pattern para skills`. ADR sem essas duas seções fica
> `Proposto` até completar.

## Contexto

Achado **DB-3** (Database Modeling Review § Achado 3): 7 colunas `*_id`
apontam **conceitualmente** para `dominio_*(id)` mas **não têm `REFERENCES`**:

| Coluna | Tabela | Lookup target |
|---|---|---|
| `social_identity_type_id` | `patients` | `dominio_tipo_identidade` |
| `ii_ingress_type_id` | `patients` | `dominio_tipo_ingresso` |
| `occupation_id` | `member_incomes` | `dominio_condicao_ocupacao` |
| `education_level_id` | `member_educational_profiles` | `dominio_escolaridade` |
| `effect_id` | `program_occurrences` | `dominio_efeito_condicionalidade` |
| `deficiency_type_id` | `member_deficiencies` | `dominio_tipo_deficiencia` |
| `program_id` | `ingress_linked_programs` | `dominio_programa_social` |

Validação na Application via porta `LookupValidating` (`Application/Services/LookupValidating.swift`) garante que o caso de uso canônico rejeita IDs inventados. Mas:

> *"All foreign key constraints must be declared in the schema. They express semantic relationships that the DBMS will enforce on every insert, update, and delete."* — Ramakrishnan & Gehrke, Cap. 3.3

ETL direto, fix manual via SQL, replicação, ou outra réplica que não passa pela Application **bypassam silenciosamente**. Cenários reais:

1. **ETL importando dados de planilha** — operador errou um UUID, banco aceita, paciente fica órfão de relacionamento.
2. **Fix manual em produção** — DBA corrige campo errado, esquece de validar contra lookup, silently corrupted.
3. **Soft-delete de item de lookup** — `UPDATE dominio_X SET ativo=false WHERE id=Y`. Todos os pacientes referenciando `Y` continuam ativos sem indicação. Com FK `ON DELETE RESTRICT`, tentativa de DELETE explícito é bloqueada — sinal claro.
4. **Renomeação de item** — sem FK, nada amarra os UUIDs históricos a uma cadeia coerente.

## Decisão

Migration `2026_05_14_DeclareLookupFKs` adiciona as 7 FKs em uma operação:

```swift
ALTER TABLE patients
ADD CONSTRAINT fk_patients_social_identity_type
FOREIGN KEY (social_identity_type_id)
REFERENCES dominio_tipo_identidade(id)
ON DELETE RESTRICT;
-- ... 6 outras
```

Pré-flight para cada FK: detectar **órfãos** (linhas com `*_id` não-NULL que não têm alvo correspondente no lookup) ANTES de aplicar a constraint. Aborta com mensagem útil — cleanup manual exigido.

Política universal:

- **`ON DELETE RESTRICT`** para toda FK que aponta para lookup table (`dominio_*`). NUNCA `CASCADE` — destrói histórico. NUNCA `SET NULL` — silencia o problema.
- **Soft-delete via flag `ativo: false`** é o único caminho válido para "retirar" um item de lookup.
- **Coluna nullable** (`social_identity_type_id`, `ii_ingress_type_id`) mantém FK — banco rejeita só valores não-NULL órfãos. Permitir NULL é decisão de domínio (campo opcional).

## Alternativas consideradas

- **Confiar 100% na validação na Application.** Descartada — só vale para via canônica. ETL bypassa. Como Codd articulou: schema é o contrato estável, aplicação é o que muda. Onde dá pra mover invariante para schema, deve.
- **CHECK constraint que valida formato UUID.** Descartada — rejeita formato malformado mas não amarra a existência do alvo. Sem FK, lookup deletado não é detectado.
- **Adicionar FK por migration separada para cada coluna.** Descartada — 7 migrations para um achado conceitualmente único. Menos legível, mais ruído no histórico. Uma migration única com `for spec in specs` é DRY.
- **`ON DELETE CASCADE`** para coluna `social_benefits.benefit_name` (futuro) — descartada como princípio universal: lookup tables nunca cascatam. Se um benefício for "removido", o histórico de pacientes que receberam esse benefício deve ser preservado.
- **Adiar para T-013 (FK composta member_id).** Descartada — T-013 é cross-tabela; T-008 é cross-lookup. Categorias separadas, podem rodar em paralelo. Pipeline ganha velocidade.

## Consequências

### Positivas

- DB enforcement universal: 7 categorias inteiras de bug eliminadas em todas as vias de acesso.
- Soft-delete de item de lookup precisa de tratamento explícito (FK RESTRICT bloqueia DELETE).
- ETL futuro tem garantia automática de integridade.
- `LookupValidating` na Application continua existindo para mensagens de erro bonitas (HTTP 422 com hint), mas agora é defesa em camada — não é a única.
- T-013 (FK composta) ganha base sólida.

### Negativas / custos

- Pré-flight pode encontrar dados sujos pré-existentes em ambientes de longa data. Mitigação: mensagem útil + cleanup manual exigido. Não fazemos UPDATE/DELETE automático.
- 7 ALTER TABLE em produção = um lock breve por tabela. Mitigação: aplicar fora do horário de pico.
- Operador desavisado pode tentar `DELETE FROM dominio_X WHERE id=Y` e ver erro inesperado. Mitigação: docs no handbook + mensagem do erro Postgres é descritiva (`update or delete on table "dominio_X" violates foreign key constraint`).

### Ações requeridas

- [x] Migration `DeclareLookupFKs` com 7 FKs + pré-flight
- [x] Registrada em `configure.swift`
- [x] 8 testes de regressão (1 por FK + 1 de revert)
- [x] Skill `swift-io-implementer` atualizada
- [ ] **Médio prazo (T-013):** FK composta `(patient_id, member_id) → family_members(patient_id, person_id)` — usa o mesmo padrão.
- [ ] **Auditoria de outras lookup-like** (`social_benefits.benefit_name`, `rights_violation_reports.violation_type` — DB Achado 9 / H-P9): se virarem FK no futuro, adotar mesmo padrão (FK + RESTRICT).

## Plano de adoção

1. **Imediato (T-008 — este ticket):** migration registrada, suite 348/348 verde.
2. **Dev local:** próximo `make dev` aplica. Em DB fresh, instantâneo. Com dados existentes válidos, pré-flight passa direto.
3. **Staging:** rodar antes do deploy. Pré-flight detecta + aborta se houver órfãos pré-existentes (improvável em staging ativo, mas possível em snapshots antigos).
4. **Produção:** aplicar fora do horário de pico. Suite de testes garante que código novo respeita as FKs.

## Como reverter

`migration.revert()` faz DROP CONSTRAINT em ordem inversa, IF EXISTS para idempotência. Não recomendado salvo em emergência operacional.

## Teste de regressão

`Tests/social-care-sTests/Regression/DataIntegrity/LookupFKsRegressionTests.swift`:

- 7 testes individuais — `test_DB_3_<column>_has_FK` — busca declaração `<column>` + `references` + `<lookup_table>` + `on delete restrict` em alguma migration.
- 1 teste — `test_DB_3_lookup_fks_migration_has_revert` — busca `func revert` simétrico (DROP CONSTRAINT).

8/8 passam após este patch. Falhavam todos antes.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` — entrada 4 em "Lições Aprendidas".
- **Regra resumida:** toda coluna `*_id` que aponta para lookup table tem FK declarada + `ON DELETE RESTRICT`. Migration que adiciona FKs em massa faz pré-flight de órfãos por FK. Validação na Application (`LookupValidating`) coexiste para HTTP 422 friendly, mas o banco é a fonte de enforcement universal.

## Referências

- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § Achado 3 — origem
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-008 — especificação
- [ADR-006](ADR-006-primary-keys-for-aggregate-tables.md) — pré-requisito (PKs)
- [ADR-007](ADR-007-typed-foreign-keys-for-semantic-identity.md) — FK semântica para `relationship_id` (caso especial coberto antes)
- Ramakrishnan & Gehrke, *Database Management Systems*, Cap. 3.3 (Foreign Keys)
- C.J. Date — princípio "schema é o contrato estável"
- PostgreSQL Reference Manual — `FOREIGN KEY`, `ON DELETE RESTRICT`
