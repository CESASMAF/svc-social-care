# T-006 — W3 Quality Gates

**Data:** 2026-05-14
**Achado:** DB-1 (Database Modeling Review)
**Tipo:** Migration de schema (sem alteração de runtime do Swift)

## Gates

| Gate | Comando | Resultado |
|---|---|---|
| Build debug | `swift build --target social-care-s` | ✅ exit 0 |
| Build release zero warnings | `make build-release` | ✅ exit 0, **9.66s**, 0 warnings novos |
| Full test suite verde | `make test` | ✅ **335/335** passam, 0.038s |
| Regression suite verde | `make regression` | ✅ 31 testes em 5 suites |
| Testes de regressão T-006 | `swift test --filter AggregateTableHasPK` | ✅ **4/4** passam, 0.009s |
| ADR-006 criado | `handbook/architecture/DECISIONS/ADR-006-*.md` | ✅ |
| DECISIONS.md index atualizado | próximo ID = 007 | ✅ |
| Skill `swift-io-implementer` atualizada | "Padrão Migration de PK com pré-flight" + Lições Aprendidas (linha 2) | ✅ |
| Regra "suite verde" honrada | sem testes vermelhos durante o ticket | ✅ |

## Arquivos criados

- `Sources/.../IO/Persistence/SQLKit/Migrations/2026_05_14_AddPrimaryKeysForFamilyMembersAndDiagnoses.swift` — **NOVO**
- `Tests/.../Regression/DataIntegrity/AggregateTableHasPKRegressionTests.swift` — **NOVO** (4 testes estruturais)
- `handbook/architecture/DECISIONS/ADR-006-primary-keys-for-aggregate-tables.md` — **NOVO**
- `.pipeline/T-006/005-quality/REPORT.md` (este)

## Arquivos modificados

- `Sources/.../IO/Persistence/SQLKit/Models/PatientDatabaseModels.swift` — `DiagnosisModel.id: UUID` adicionado
- `Sources/.../IO/Persistence/SQLKit/Mappers/PatientDatabaseMapper.swift` — gera `UUID()` por Diagnosis no `toDatabase`
- `Sources/.../IO/HTTP/Bootstrap/configure.swift` — registra `AddPrimaryKeysForFamilyMembersAndDiagnoses()` na lista de migrations
- `handbook/architecture/DECISIONS.md` — ADR-006 indexado; próximo ID = **007**
- `.claude/skills/swift-io-implementer/SKILL.md` — nova seção "Padrão Migration de PK" + entrada 2 em "Lições Aprendidas"

## Pontos arquiteturais decididos

1. **PK natural composta em `family_members`** — `(patient_id, person_id)`. Reflete o `==` do domínio (FamilyMember é identificado por personId). Habilita FK composta de filhas para T-013.
2. **PK surrogate em `patient_diagnoses`** — `id UUID DEFAULT gen_random_uuid()`. Surrogate facilita FK enxuta (1 coluna) para tabelas que referenciem um diagnóstico no futuro. UNIQUE natural `(patient_id, icd_code, date)` preserva o invariante de domínio "um diagnóstico por CID/data por paciente".
3. **Fail-safe pré-flight** — migration aborta com mensagem útil se houver duplicatas pré-existentes. Não faz DELETE automático (princípio CRU/No Delete + histórico social é sagrado). Operador recebe SELECT pronto para diagnosticar.
4. **Teste estrutural** — sem Postgres em CI, o teste de regressão inspeciona arquivos `.swift` de Migrations/ buscando declarações esperadas. Limitação documentada: não testa runtime real, mas pega regressão de "alguém apagou a migration" no PR review. Complementação completa virá em T-033 (schema snapshot).

## Limites conhecidos

- **DiagnosisModel.id é gerado no mapper como `UUID()` novo a cada save** — significa que o caminho `deleteAndInsert` atual (que apaga e re-insere a cada save) continua produzindo IDs diferentes para o mesmo diagnóstico de domínio. Isto **será corrigido em T-021** (diff-based upsert), que precisa do domínio `Diagnosis` carregar `id: UUID` estável. Este ticket faz o schema aceitar PK — T-021 faz o domínio respeitar identidade.
- **Migration não foi aplicada em produção** — registro no `configure.swift` garante que será aplicada no próximo boot. Em staging com data existente, possibilidade de pré-flight detectar duplicatas (raro mas precisa monitoramento durante deploy).
- **Sem teste de integração Postgres real** — fora do escopo desta camada. T-033 (schema snapshot) é o complemento planejado.

## Falha colateral?

**Zero.** 335/335 verde antes E depois da mudança. A mudança em `DiagnosisModel` (adicionar `id`) não quebrou nenhum teste porque os testes usam `InMemoryPatientRepository` que não decodifica `DiagnosisModel`. O mapper foi atualizado conservadoramente — UUID novo a cada save preserva semântica até T-021 mover identidade para o domínio.

## Próximos tickets liberados

Com T-006 fechado:
- **T-007** (relationship_id UUID + FK em `family_members`) — pode rodar agora; FK composta natural `(patient_id, person_id)` já existe.
- **T-008** (FKs para `dominio_*`) — fica liberado.
- **T-013** (FK composta `member_id` → `family_members`) — fica liberado quando T-024 quebrar god aggregate.
- **T-021** (diff-based upsert) — precisa do domínio carregar ID estável; este ticket habilita o schema, T-021 finaliza o caminho.

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001 | Foundations | ADR-002 | 5 sentinels |
| T-002 | Estrutura ADR | ADR-003 | meta |
| T-004 | S-C7 | ADR-004 | 2 |
| T-005 | S-C3 + DB-2 | ADR-005 | 4 |
| T-006 | DB-1 | ADR-006 | 4 |
| **Total** | 5 CRITICAL/HIGH fechados | **6 ADRs** | **15 regression tests** |
