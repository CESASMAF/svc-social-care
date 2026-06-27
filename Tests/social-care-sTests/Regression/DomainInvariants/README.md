# Regression / DomainInvariants

Previne bugs onde o **domínio aceita estado que viola invariante de negócio**.

## Classe de bugs prevenidos

- **VO sem `init throws`** — coleções aceitam duplicatas, idade aceita data futura, ranges inválidos passam.
- **Agregado sem invariante** — métodos CRUD-style sem defesa, god aggregate carrega 4 BCs.
- **Identidade destruída** — `deleteAndInsert` recria com IDs novos → audit trail confuso, FK quebra.
- **Money como Double** — soma de decimais não-exata, perda em round-trip.
- **`Date()` hardcoded** — handler não-testável deterministicamente.
- **Force-unwrap em VO** — `try!`/`!` quebram silenciosamente em refactor.
- **`@unchecked Sendable` com `Any`** — data race silencioso.

## Tickets que adicionam testes aqui

| Ticket | Teste | Achado |
|---|---|---|
| T-004 | `RecordEventSilentNoopTest` | S-C7 |
| T-009 | `MoneyIsExactTest` | DB-8 |
| T-019 | `SendableJSONTest` | S-H-IO6 + S-M-P2 |
| T-021 | `ChildIdentityPreservedTest` | S-H-P1 + DB-6 |
| T-024 | `AggregateDecompositionTest` (suite) | S-H-D1 + DB-7 |
| T-034 | `ClockInjectionTest` | S-H-A2 |
| T-035 | `ForceUnwrapAuditTest` | S-H-D4 + S-H-P3 |

## Padrão típico

```swift
@Test("DB-8 — summing decimals is exact, never lossy")
func test_DB_8_summing_decimals_is_exact() {
    let amounts = (1...100).map { _ in try! Money(centavos: 10, currency: "BRL") }
    let total = try amounts.reduce(Money.zero, +)
    #expect(total == Money(centavos: 1000, currency: "BRL"))
    // Antes (Double): 10.0 esperado, 9.999999999... real
}
```

## Invariantes universais

Para qualquer agregado raiz neste projeto:

1. `init(_:) throws` em todo VO (validação no construtor, nunca no chamador)
2. `Sendable, Equatable, Hashable` em VO (convenção handbook v2.0)
3. `var uncommittedEvents: [any DomainEvent]` em agregado raiz
4. Erros implementam `AppErrorConvertible`
5. `Date` injetável via parâmetro `now: TimeStamp = .now`
6. Zero `try!`/`!` em código de produção (test pode usar para fail-fast)
