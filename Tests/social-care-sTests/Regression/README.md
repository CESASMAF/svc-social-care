# Regression Suite — `social-care`

> **Tipo:** suite de testes permanentes. Cada teste aqui corresponde a um achado documentado em `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` e impede reintrodução do bug.
> **Criado em:** 2026-05-14 (ticket T-001).
> **Política:** ADR-002.

## Como rodar

```bash
make regression                       # todos os subsuites
swift test --filter "Regression:"     # equivalente direto
swift test --filter "Regression: Concurrency"   # apenas um tema
```

`make regression` deve passar em < 5s. Se demorar mais, o suite cresceu demais para o gate de PR rápido — quebrar por subpasta com tag de CI.

## Subpastas (uma por classe de bug)

| Subpasta | Classe de bug que previne |
|---|---|
| `Concurrency/` | Race conditions: lost updates, outbox duplication, actor reentrância |
| `DataIntegrity/` | PK/FK/types ausentes ou incorretos no schema; 1NF violado; UF inválida |
| `EventPublication/` | Eventos publicados antes do save, no-op silencioso, audit trail corrompido |
| `Security/` | Fail-open em adapters, headers ausentes, PII em log, JWT bypass |
| `DomainInvariants/` | VO aceitando estado inválido, agregado sem invariantes, identidade perdida |
| `ErrorMapping/` | `PersistenceConflictError` não mapeado, erro genérico vazando para fronteira |

## Convenções de nomenclatura

Cada teste **DEVE** carregar o ID do achado original no nome:

```swift
@Suite("Regression: Concurrency")
struct OptimisticLockRegressionTests {
    @Test("S-C3 / DB-2 — save rejects stale version")
    func test_S_C3_DB_2_lost_update_is_rejected() async throws { ... }
}
```

Por quê: um teste chamado `testConcurrentSaveFails()` perde valor em 6 meses. Com o ID, basta `grep S_C3` para achar o report original e o ADR correspondente.

## Como adicionar um teste

1. Identificar o achado (ex: `S-C3` em `SENIOR_CODE_REVIEW_2026_05_14.md`)
2. Escolher a subpasta correspondente
3. Criar arquivo `<Tema>RegressionTests.swift` se ainda não existe
4. Nome do teste: `test_<ACHADO_ID>_<descrição_curta>()`
5. Documentação do `@Test`: descrever o invariante garantido em uma frase
6. Usar `RegressionFixture` (em `Application/TestDoubles/RegressionFixture.swift`) para isolamento determinístico
7. Referenciar o ticket de remediação no comentário do arquivo (`// ticket: T-005`)

## Anatomia de teste de regressão

Um teste de regressão tem 3 partes obrigatórias (ver `handbook/tooling/swift/testing/regression-pattern.md`):

1. **Reproduzir o bug original** (assert que o estado inválido era aceito antes)
2. **Assert do invariante** que a fix garante
3. **Nome documentado** com ID do achado

```swift
@Test("S-C3 / DB-2 — concurrent save rejects stale version")
func test_S_C3_DB_2_lost_update_is_rejected() async throws {
    // 1. Reproduce: dois processos lêem version=1
    let a = try await repo.find(byId: id)!
    let b = try await repo.find(byId: id)!

    // 2. Assert do invariante: B falha porque A já mudou para version=2
    try await repo.save(a.mutated())
    await #expect(throws: PersistenceConflictError.self) {
        try await repo.save(b.mutated())
    }
}
```

## Não duplicar com testes unitários

Este suite **não substitui** testes unitários de happy path. Testes aqui cobrem:
- Bugs que já aconteceram (documentados em report)
- Invariantes de integridade que dependem de configuração específica (schema, concorrência, segurança)

Tests unitários cobrem comportamento normal. Tests de regressão cobrem o que **já deu errado** ou **pode dar errado** sob condições específicas.
