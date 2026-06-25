# T-007 — W3 Quality Gates

**Data:** 2026-05-14
**Achados:** DB-4 + S-H-D5 (confirmação dupla — Primitive Obsession + tipo errado no schema)

## Gates

| Gate | Comando | Resultado |
|---|---|---|
| Build debug | `swift build --target social-care-s` | ✅ exit 0 |
| Build release zero warnings | `make build-release` | ✅ exit 0, 41.23s, 0 warnings novos |
| Full test suite | `make test` | ✅ **340/340** passam, 0.045s |
| Regression suite | `make regression` | ✅ 36 testes em 6 suites |
| Testes T-007 | `swift test --filter RelationshipIdIsTyped` | ✅ **5/5** passam, 0.014s |
| ADR-007 criado | `DECISIONS/ADR-007-*.md` | ✅ |
| DECISIONS.md index | próximo ID = 008 | ✅ |
| Skill atualizada | entrada 3 em "Lições Aprendidas" | ✅ |

## Arquivos criados

- `Sources/.../Migrations/2026_05_14_TypeRelationshipAsUUID.swift` — **NOVO** (expand-contract com pré-flight)
- `Tests/.../Regression/DataIntegrity/RelationshipIdIsTypedRegressionTests.swift` — **NOVO** (5 testes estruturais)
- `handbook/architecture/DECISIONS/ADR-007-typed-foreign-keys-for-semantic-identity.md` — **NOVO**

## Arquivos modificados

- `Models/PatientDatabaseModels.swift` — `relationship_id: UUID` substitui `relationship: String`
- `Mappers/PatientDatabaseMapper.swift` — encode/decode usa `UUID` nativo
- `IO/HTTP/Bootstrap/configure.swift` — registra `TypeRelationshipAsUUID()`
- `handbook/architecture/DECISIONS.md` — ADR-007 indexado; próximo ID = **008**
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 3

## Decisões arquiteturais

1. **Expand-contract sequencial** (não destrutivo): add col nova → pré-flight + backfill → SET NOT NULL → FK → drop antiga. Único caminho seguro em migration de tipo.
2. **Pré-flight com regex Postgres** detecta UUIDs malformados antes do backfill — fail-safe com cleanup manual exigido (CRU/No Delete).
3. **`ON DELETE RESTRICT`** para FK em lookup table — soft-delete via flag `ativo` é o caminho correto; CASCADE/SET NULL seriam catastróficos.
4. **Mapper usa `UUID(uuidString:)!`** mantido nesta camada porque `LookupId` (no domínio) garante UUID válido. Refactor de `UUID(uuidString:)!` em todo o mapper é o T-035 (Fase 6 — separado).

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001 | Foundations | ADR-002 | 5 |
| T-002 | Estrutura ADR | ADR-003 | meta |
| T-004 | S-C7 | ADR-004 | 2 |
| T-005 | S-C3 + DB-2 | ADR-005 | 4 |
| T-006 | DB-1 | ADR-006 | 4 |
| T-007 | DB-4 + S-H-D5 | ADR-007 | 5 |
| **Total** | 6 fechados | **7 ADRs** | **20 regression tests** |

## Próximos tickets liberados

- **T-008** (FKs ausentes para 7 colunas `*_id` → `dominio_*`) — natural sequência de T-007. CRITICAL DB-3.
- **T-013** (FK composta `member_id` → `family_members`) — agora viável.
