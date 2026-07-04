# T-004 — W1 GREEN Report

**Data:** 2026-05-14
**Skill executora:** `swift-domain-modeler` (refator de protocolo composto)

## Arquivos modificados

### 1. `Sources/social-care-s/shared/Domain/DomainProtocols.swift`

Mudança principal: protocolo composto.

**Antes:**

```swift
public protocol EventSourcedAggregate: Sendable {
    associatedtype ID: Sendable & Equatable
    var id: ID { get }
    var version: Int { get }
    var uncommittedEvents: [any DomainEvent] { get }
}

extension EventSourcedAggregate {
    public mutating func recordEvent(_ event: any DomainEvent) {
        if var internalSelf = self as? any EventSourcedAggregateInternal {
            internalSelf.addEvent(event)
            if let back = internalSelf as? Self { self = back }
        }
    }
}

public protocol EventSourcedAggregateInternal {
    mutating func addEvent(_ event: any DomainEvent)
}
```

**Depois:**

```swift
public protocol EventSourcedAggregateInternal {
    mutating func addEvent(_ event: any DomainEvent)
    mutating func clearEvents()
}

public protocol EventSourcedAggregate: Sendable, EventSourcedAggregateInternal {
    associatedtype ID: Sendable & Equatable
    var id: ID { get }
    var version: Int { get }
    var uncommittedEvents: [any DomainEvent] { get }
}

extension EventSourcedAggregate {
    public mutating func recordEvent(_ event: any DomainEvent) {
        self.addEvent(event)
    }
}
```

Mudanças:
1. `EventSourcedAggregateInternal` movido para cima e exige `addEvent` E `clearEvents`
2. `EventSourcedAggregate` agora **herda** de `Internal` — qualquer struct novo precisa implementar `addEvent`/`clearEvents` ou não compila
3. Extension `recordEvent` simplificada — chamada direta `self.addEvent(event)`, **zero cast dinâmico**

### 2. `Tests/social-care-sTests/Regression/EventPublication/RecordEventSilentNoopRegressionTests.swift`

`TestAggregate` agora implementa `addEvent` + `clearEvents` (obrigatórios após fix).

## Arquivos NÃO modificados (mas afetados)

- `Sources/.../Domain/Registry/Aggregates/Patient/Patient.swift` — já conformava ambos os protocolos explicitamente. Após herança, a conformância `EventSourcedAggregateInternal` é redundante mas inofensiva (não removida para não tocar arquivo fora do escopo).
- 21 handlers em `Application/` — usam `eventBus.publish(patient.uncommittedEvents)`, nada relacionado a refactor.

## Validação

```bash
$ swift test --filter RecordEventSilentNoop
✔ Test "S-C7 — Patient conforma EventSourcedAggregateInternal por composição do protocolo" passed
✔ Test "S-C7 — recordEvent armazena evento (não é mais no-op silencioso)" passed
✔ Test run with 2 tests in 1 suite passed after 0.004 seconds.
```

## Compile-time guard

Confirmamos que, após a fix, o compilador rejeita agregado sem `addEvent`/`clearEvents`:

```
error: type 'TestAggregate' does not conform to protocol 'EventSourcedAggregateInternal'
note: protocol requires function 'addEvent' with type '(any DomainEvent) -> ()'
note: protocol requires function 'clearEvents()' with type '() -> ()'
```

Este é o **enforcement permanente** — sem teste runtime adicional, qualquer agregado futuro escrito sem os métodos não compila.

## Falha colateral consertada (T-004.fix)

Durante a validação `make test`, 1 teste OIDC falhou (`verifyRejectsExpiredToken`). **Não relacionado a T-004**, mas conforme regra inviolável (não existe teste vermelho), tratado como prioridade.

Arquivos modificados:

- `Tests/social-care-sTests/IO/Auth/OIDCJWTPayloadTests.swift`:
  - Helper `decode` agora usa `decoder.dateDecodingStrategy = .secondsSince1970` (alinha com `JWTKit/CustomizedJSONCoders.swift`).
  - `@Suite` recebe `.serialized` para serializar acesso ao singleton `OIDCJWTPayloadBootstrap.shared`.
- Comentários explicando ambas as decisões.

Razão:
1. Vanilla `JSONDecoder` interpreta `Date` numérico como segundos desde 2001 (`.deferredToDate`), não Unix epoch. Resultado: `exp = -3600s ago` virava ~31 anos no futuro, `verifyNotExpired()` passava.
2. 3 testes do suite mutam `OIDCJWTPayloadBootstrap.shared` (singleton global). Em execução paralela, race condition entre eles. `.serialized` força execução sequencial dentro do suite.

Sem fix em código de produção — só em testes (que estavam testando errado).
