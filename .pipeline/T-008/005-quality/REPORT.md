# T-008 — W3 Quality Gates

**Data:** 2026-05-14
**Achado:** DB-3 (Database Modeling Review — 7 colunas sem FK declarada)

## Gates

| Gate | Comando | Resultado |
|---|---|---|
| Build debug | `swift build --target social-care-s` | ✅ exit 0 |
| Build release | `make build-release` | ✅ exit 0, 40.16s, 0 warnings novos |
| Full test suite | `make test` | ✅ **348/348** passam |
| Regression suite | `make regression` | ✅ 44 testes em 7 suites |
| Testes T-008 | `swift test --filter LookupFKs` | ✅ **8/8** passam, 0.012s |
| ADR-008 criado | `DECISIONS/ADR-008-*.md` | ✅ |
| DECISIONS.md index | próximo ID = 009 | ✅ |
| Skill atualizada | entrada 4 em "Lições Aprendidas" | ✅ |

## Arquivos criados

- `Sources/.../Migrations/2026_05_14_DeclareLookupFKs.swift` — **NOVO** (7 FKs em uma migration com pré-flight)
- `Tests/.../Regression/DataIntegrity/LookupFKsRegressionTests.swift` — **NOVO** (8 testes estruturais)
- `handbook/architecture/DECISIONS/ADR-008-foreign-keys-for-lookup-tables.md` — **NOVO**

## Arquivos modificados

- `IO/HTTP/Bootstrap/configure.swift` — registra `DeclareLookupFKs()`
- `handbook/architecture/DECISIONS.md` — ADR-008 indexado; próximo ID = **009**
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 4

## 7 FKs declaradas

Todas com `ON DELETE RESTRICT` (nunca CASCADE em lookup table):

| FK | Source.column | Target |
|---|---|---|
| `fk_patients_social_identity_type` | `patients.social_identity_type_id` | `dominio_tipo_identidade(id)` |
| `fk_patients_ii_ingress_type` | `patients.ii_ingress_type_id` | `dominio_tipo_ingresso(id)` |
| `fk_member_incomes_occupation` | `member_incomes.occupation_id` | `dominio_condicao_ocupacao(id)` |
| `fk_member_educational_profiles_education_level` | `member_educational_profiles.education_level_id` | `dominio_escolaridade(id)` |
| `fk_program_occurrences_effect` | `program_occurrences.effect_id` | `dominio_efeito_condicionalidade(id)` |
| `fk_member_deficiencies_deficiency_type` | `member_deficiencies.deficiency_type_id` | `dominio_tipo_deficiencia(id)` |
| `fk_ingress_linked_programs_program` | `ingress_linked_programs.program_id` | `dominio_programa_social(id)` |

## Decisões arquiteturais

1. **`ON DELETE RESTRICT` universal** — lookup table nunca cascateia. Soft-delete via `ativo: false` é o caminho correto.
2. **Coluna nullable mantém FK** — Postgres rejeita só valores não-NULL órfãos. `social_identity_type_id` e `ii_ingress_type_id` continuam opcionais (decisão de domínio).
3. **Pré-flight em loop** — para cada FK, detecta primeiro órfão antes de aplicar. Mensagem útil + cleanup manual exigido.
4. **Migration única com `for spec in specs`** — DRY; uma migration cobre 7 FKs conceitualmente irmãs.
5. **`LookupValidating` na Application coexiste** — não removemos o validator existente. Ele continua oferecendo HTTP 422 com mensagens amigáveis. A FK é defesa em camada universal.

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001 | Foundations | ADR-002 | 5 |
| T-002 | Estrutura ADR | ADR-003 | meta |
| T-004 | S-C7 | ADR-004 | 2 |
| T-005 | S-C3 + DB-2 | ADR-005 | 4 |
| T-006 | DB-1 | ADR-006 | 4 |
| T-007 | DB-4 + S-H-D5 | ADR-007 | 5 |
| T-008 | DB-3 | ADR-008 | 8 |
| **Total** | 7 fechados | **8 ADRs** | **28 regression tests** |

## Próximos tickets liberados

- **T-009** (Money VO substituindo Double — DB-8). HIGH, pequeno escopo (Domain + Mapper), bom candidato para próximo.
- **T-010** (mapUniqueViolation universal nos 21 handlers — S-C6). CRITICAL, médio porte. Bom candidato após T-009.
- **T-011** (PeopleContext tri-state + Bearer — S-C1). CRITICAL de segurança.
