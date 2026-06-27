# Regression / Concurrency

Previne **race conditions** que aparecem sob carga real ou multi-instância.

## Classe de bugs prevenidos

- **Lost update** — dois writes concorrentes ao mesmo agregado sobrescrevem-se silenciosamente (`save` sem optimistic lock).
- **Outbox duplication** — dois pods do relay leem o mesmo batch sem `FOR UPDATE SKIP LOCKED`.
- **Actor reentrância** — `await` no meio de uma operação libera a fila do actor e permite estado inconsistente.
- **TOCTOU** — `exists(...)` checagem seguida de `save` com janela entre eles.

## Tickets que adicionam testes aqui

| Ticket | Teste | Achado |
|---|---|---|
| T-005 | `OptimisticLockTest` | S-C3 + DB-2 |
| T-012 | `OutboxNoDuplicationTest` | S-C2 |

## Como reproduzir um bug de concorrência em teste

Usar `withTaskGroup` ou `async let` para forçar paralelismo:

```swift
@Test
func test_S_C2_two_relay_workers_dont_pick_same_message() async throws {
    let relay1 = RegressionFixture.relay(id: "r1")
    let relay2 = RegressionFixture.relay(id: "r2")

    async let a = relay1.pollAndDistribute()
    async let b = relay2.pollAndDistribute()
    _ = await (a, b)

    let publishedIds = await natsMock.publishedMessages.map(\.id)
    #expect(Set(publishedIds).count == publishedIds.count)
}
```

> **Atenção:** testes de concorrência podem ser flaky se não bem desenhados. Sempre use `RegressionFixture` para fixar determinismo (clock, IDs, ordering).
