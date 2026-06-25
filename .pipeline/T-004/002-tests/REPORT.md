# T-004 — W0 RED Report

**Data:** 2026-05-14
**Skill executora:** `swift-test-writer`

## Arquivo criado

`Tests/social-care-sTests/Regression/EventPublication/RecordEventSilentNoopRegressionTests.swift`

## Conteúdo

```swift
@Suite("Regression: Event Publication — S-C7 recordEvent silent no-op")
struct RecordEventSilentNoopRegressionTests {

    struct TestEvent: DomainEvent {
        let id: UUID = UUID()
        let occurredAt: Date = RegressionFixture.frozenTimestamp().date
    }

    struct TestAggregate: EventSourcedAggregate {
        // pré-fix: SEM addEvent/clearEvents — protocolo permitia
        // pós-fix: addEvent + clearEvents agora obrigatórios por composição
        ...
    }

    @Test("S-C7 — recordEvent armazena evento (não é mais no-op silencioso)")
    @Test("S-C7 — Patient conforma EventSourcedAggregateInternal por composição do protocolo")
}
```

## Validação RED (pré-fix)

```
✘ Test "S-C7 — recordEvent armazena evento (não é mais no-op silencioso)"
    Expectation failed: (agg.uncommittedEvents.count → 0) == 2
✔ Test "S-C7 — Patient conforma EventSourcedAggregateInternal por composição do protocolo"
```

Resultado:
- ✘ `recordEvent_actually_appends` — **falha como esperado** (count == 0 → bug C7 demonstrado)
- ✔ `patient_conforms_internal` — passa porque `Patient` já implementa Internal explicitamente

## Validação GREEN (pós-fix)

```
✔ Test "S-C7 — Patient conforma EventSourcedAggregateInternal por composição do protocolo" passed
✔ Test "S-C7 — recordEvent armazena evento (não é mais no-op silencioso)" passed
✔ Test run with 2 tests in 1 suite passed after 0.004 seconds.
```

## Padrão seguido (ADR-002)

- [x] Vive em `Tests/.../Regression/EventPublication/`
- [x] Struct nome `RecordEventSilentNoopRegressionTests` contém "Regression"
- [x] Testes nomeados `test_S_C7_…` com ID do achado
- [x] Comentário do arquivo cita ticket `T-004` e ADR-004
- [x] Usa `RegressionFixture` (frozenTimestamp, uuid)
- [x] Aparece em `make regression`
