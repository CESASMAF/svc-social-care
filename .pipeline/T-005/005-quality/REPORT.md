# T-005 — W3 Quality Gates

**Data:** 2026-05-14
**Achados:** S-C3 (Senior Review) + DB-2 (Database Review) — confirmação dupla

## Gates

| Gate | Comando | Resultado |
|---|---|---|
| Test target compila | `swift build --target social-care-sTests` | ✅ exit 0 |
| Release build zero warnings | `make build-release` | ✅ exit 0, **0 warnings novos** (apenas o resource warning pré-existente) |
| Full test suite verde | `make test` | ✅ **331/331** passam, 0.043s |
| Regression suite verde | `make regression` | ✅ **27 testes em 4 suites** |
| Testes de regressão T-005 | `swift test --filter OptimisticLock` | ✅ **4/4** passam, 0.009s |
| ADR-005 criado | `handbook/architecture/DECISIONS/ADR-005-*.md` | ✅ |
| DECISIONS.md index atualizado | próximo ID = 006 | ✅ |
| Skill `swift-io-implementer` atualizada | seção "Padrão Optimistic Lock" + "Lições Aprendidas" | ✅ |

## Saída de `make regression` (final)

```
✔ Suite "Regression: Concurrency — S-C3/DB-2 optimistic lock" passed
  ↳ 4 tests novos do T-005
✔ Suite "Regression: Event Publication — S-C7 recordEvent silent no-op" passed
  ↳ 2 tests do T-004
✔ Suite "Regression: Meta" passed
  ↳ 5 sentinels do T-001
✔ Suite "Code Review Regression Tests (2026-03-06)" passed
  ↳ 16 testes históricos
✔ Test run with 27 tests in 4 suites passed after 0.007 seconds.
```

## Mudanças aplicadas

### Sources (produção)

- `Sources/.../shared/Error/PersistenceConflictError.swift` — nova variante `optimisticLockFailed(expectedVersion:, actualVersion:)`
- `Sources/.../IO/Persistence/SQLKit/SQLKitPatientRepository.swift` — `save` refatorado:
  - `SELECT version FROM patients WHERE id = ? FOR UPDATE` (row lock)
  - Path CREATE (row inexistente) vs UPDATE (row existe + version match)
  - `optimisticLockFailed` quando version não bate
  - UPSERT removido (foi a fonte do bug)

### Tests

- `Tests/.../Application/TestDoubles/InMemoryPatientRepository.swift` — fake espelha invariante:
  - `save` rejeita quando `existing.version != patient.version - 1`
  - Acesso `find(byId:)`/`find(byPersonId:)` inalterado
- `Tests/.../Regression/Concurrency/OptimisticLockRegressionTests.swift` — **NOVO**:
  - 4 testes cobrindo: lost update rejeitado, diagnóstico no erro, sequência normal, CREATE path
  - Usa `InMemoryPatientRepository` (fake) + `PatientFixture.createMinimalActive()`

### Handbook

- `handbook/architecture/DECISIONS/ADR-005-optimistic-locking-via-version.md` — **NOVO**, justificativa completa + plano + Better Pattern
- `handbook/architecture/DECISIONS.md` — ADR-005 indexado, próximo ID = 006

### Skill

- `.claude/skills/swift-io-implementer/SKILL.md`:
  - Nova seção "Padrão Optimistic Lock em Repository (ADR-005)" com snippet
  - Tabela "Lições Aprendidas" ganha entrada 1
  - Checklist "Antes de fechar" inclui optimistic lock + suite verde

## Pontos arquiteturais decididos

1. **`SELECT FOR UPDATE` em vez de `INSERT ... ON CONFLICT WHERE`** — SQLKit não tem ergonomia boa para ON CONFLICT WHERE, e o SELECT explícito deixa o invariante visível no código. Custo: 1 query extra por save (~1ms em local).
2. **Path explícito CREATE vs UPDATE** — `SELECT` retorna `nil` → INSERT; row existe → UPDATE condicional. Mais legível que UPSERT condicional.
3. **Fake espelha SQLKit** — `InMemoryPatientRepository.save` aplica o mesmo invariante para que unit tests cubram o cenário sem precisar de Postgres real. Princípio: fake **DEVE** ter os mesmos invariantes do real, senão testes mentem.
4. **Mapeamento `optimisticLockFailed` → HTTP 409 fica para T-010** — ticket dedicado de error mapping universal vai cobrir `optimisticLockFailed` junto com `uniqueViolation` em todos os 21 handlers.

## Próximos tickets liberados

T-005 fecha o invariante "lost update impossível" sob qualquer carga. Próximos tickets que tocam repositórios (T-024 decomposição, T-031 LookupBatchValidator) já nascem corretos.

Recomendação seguinte:
- **T-006** — Adicionar PK em `family_members` e `patient_diagnoses` (DB-1). Bloqueia T-007 (FKs lookups) e T-021 (diff-based upsert).
- **T-010** — `mapUniqueViolation` + `mapOptimisticLock` em todos os 21 handlers. Fecha o loop de error mapping (S-C6).

## Falha colateral?

Nenhuma desta vez. `make test` rodou 331/331 verde antes E depois do refactor SQLKit. A fake já espelhava o invariante (W1b) antes do W1c — disciplina paga.

A regra inviolável "suite verde é responsabilidade de quem está no comando" continuou observada — sem testes vermelhos, ticket fechado com confiança.
