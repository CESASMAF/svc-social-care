---
name: swift-concurrency
description: >
  Aprofundamento técnico (horizontal) de Swift Concurrency para o backend
  `social-care` (Swift 6.3 strict concurrency, server-side Vapor — sem UI).
  Funde 3 skills genéricas (foundations + Swift 6.2+ + code-review) e
  re-contextualiza para os padrões do projeto: `actor` handlers de command,
  `struct` query handlers, `Sendable` em VOs/Commands/Events, Transactional
  Outbox e `SELECT … FOR UPDATE [SKIP LOCKED]`. Use para dúvidas factuais de
  actors, Sendable, async/await, Task/cancelamento, async sequences, data
  races e diagnostics do compilador. Para "como modelar/implementar no
  social-care", use as verticais (`swift-expert`, `swift-application-orchestrator`,
  `swift-io-implementer`); esta skill é o aprofundamento por trás delas.
---
# Swift Concurrency — aprofundamento técnico (social-care)

> **Contexto deste serviço (leia antes de aplicar):** `social-care` é um
> microserviço **Swift 6.3 / Vapor 4 server-side**, strict concurrency com
> todas as checks habilitadas. **Não há UI** — `@MainActor` praticamente não
> aparece aqui (apareceria só em código de app Apple). Os padrões de
> concorrência que importam neste repo:
>
> - **`actor` em todo command handler** (`RegisterPatientCommandHandler`) — exclusão mútua entre invocações concorrentes.
> - **`struct` em query handler** — leitura não muta estado compartilhado, dispensa `actor`.
> - **`Sendable` em todo tipo que cruza boundary** — VOs (`CPF`), Commands, `DomainEvent`, Ports (`any PatientRepository`).
> - **`@unchecked Sendable` PROIBIDO na fronteira (ADR-018)** — payloads heterogêneos são `enum` fechado (`AnySendable`), nunca `Any` type-erased. Aceito só em wrappers internos justificados (ex.: `ServiceContainer` lê props imutáveis pós-boot).
> - **Concorrência no banco:** repos de aggregate root usam optimistic lock via `SELECT version … FOR UPDATE` (ADR-005); relay de Outbox usa `SELECT … FOR UPDATE SKIP LOCKED` (ADR-013).
>
> **Esta skill é horizontal** — fundiu `swift-concurrency` + `-expert` +
> `-pro`. As verticais decidem *o que/onde* codar; aqui está o *porquê técnico*.
> Em conflito, **handbook e ADRs do projeto prevalecem** sobre qualquer
> orientação genérica abaixo.

## Fast Path

Antes de propor um fix:

1. Confirme o modo da linguagem e nível de strict concurrency em `Package.swift` (este repo: Swift 6.3, strict total). Não suponha.
2. Capture o diagnóstico exato e o símbolo ofensor.
3. Determine a fronteira de isolamento: instância de `actor`, `nonisolated`, ou cruzamento de `Sendable`. (`@MainActor` é praticamente N/A aqui.)
4. Otimize para a **menor mudança segura** que preserva comportamento. Não refatore arquitetura não relacionada durante a correção.

Guardrails específicos do projeto:

- **Não** recomende `@MainActor` como fix genérico — neste backend quase nunca é a resposta. Estado mutável compartilhado vai para `actor`.
- Prefira concorrência estruturada (`async let`, `withTaskGroup`) a `Task` solto; `Task.detached` só com razão documentada. Handlers usam `async throws` direto — nada de `Task { }` solto sem retorno.
- Ao sugerir `@unchecked Sendable`/`nonisolated(unsafe)`: na **fronteira** (DTO/Error/Event/`shared/`) é proibido (ADR-018) — modele `enum` fechado. Fora da fronteira, exija invariante de segurança documentada + plano de remoção.
- `Sendable` é sintetizado para `struct` cujas props são todas `Sendable` — não anote manualmente o que o compilador já infere.

## Common Diagnostics

| Diagnostic | First check | Smallest safe fix | Aprofundar em |
|---|---|---|---|
| `Sending value of non-Sendable type ... risks causing data races` | Que fronteira de isolamento está sendo cruzada? | Mantenha o acesso dentro de um `actor`, ou converta o valor transferido para tipo de valor imutável (`Sendable`). | `references/sendable.md`, `references/threading.md` |
| `Actor-isolated type does not conform to protocol` | O requisito precisa rodar no actor? | Prefira conformance isolada; use `nonisolated` só para requisitos genuinamente não-isolados. | `references/actors.md`, `references/swift-6-2-concurrency.md` |
| `... cannot satisfy conformance requirement for a 'Sendable' type parameter` (`SendableMetatype`) | A conformance carrega isolamento de global actor? | Remova o isolamento da conformance, ou evite passar o metatype através da fronteira. | `references/actors.md` |
| `Main actor-isolated ... cannot be used from a nonisolated context` | Isso é realmente UI-bound? (Aqui: quase nunca.) | Provavelmente o tipo não deveria ser `@MainActor` — mova para `actor` ou `Sendable` value. | `references/actors.md` |
| `wait(...) is unavailable from asynchronous contexts` | É espera de XCTest legado? | Use APIs de `swift-testing` (`confirmation`, `#expect`) — ver skill `swift-testing`. | `references/testing.md`, `references/testing-review.md` |
| Lint concorrência (`async_without_await`) | `async` é exigido por protocolo/override? | Remova `async` ou suprima com rationale. Nunca adicione `await` falso. | `references/linting.md` |

## Concurrency Tool Selection

| Need | Tool | Guidance no social-care |
|---|---|---|
| Operação async sequencial | `async/await` | Default em handlers (`try await repository.save(...)`). |
| Paralelas de contagem fixa | `async let` | Parses paralelos de VOs. Swift 6.3.1 fixou stack-alloc em `async let`. |
| Paralelas de contagem dinâmica | `withTaskGroup` | Cancela filhos ao sair do escopo. |
| Estado mutável compartilhado | `actor` | **Command handlers**, fakes `InMemory*Repository`/`InMemoryEventBus` (testes). |
| Leitura sem mutação | `struct` (não `actor`) | **Query handlers** — dispensam exclusão mútua. |

### Cenário canônico — command handler (write side)

```swift
public actor RegisterPatientCommandHandler: RegisterPatientUseCase {
    private let repository: any PatientRepository   // Sendable port
    // parse (VOs Sendable) → validate → domain → persist → publish (via Outbox)
    public func handle(_ command: RegisterPatientCommand) async throws -> String {
        let personId = try PersonId(command.personId)        // VO Sendable
        guard try await repository.exists(byPersonId: personId) == false else { /* ... */ }
        var patient = try Patient(/* ... */)
        try await repository.save(patient)   // Outbox events na MESMA TX (ADR-014)
        return patient.id.description
    }
}
```

### Sendable na fronteira — o que ADR-018 exige

```swift
// ❌ Proibido na fronteira (DTO/Error/Event/shared): promessa que `Any` não cumpre.
struct Boundary: @unchecked Sendable { let payload: Any }

// ✅ enum fechado — Sendable verdadeiro, strict concurrency verifica recursivamente.
public enum AnySendable: Sendable {
    case string(String), int(Int), double(Double), bool(Bool)
    case array([AnySendable]), object([String: AnySendable]), null
}
```

## Swift 6.x — strict concurrency

Mudanças que valem aqui (já é o estado do repo): data-race safety em compile-time, `Sendable` enforçado em boundaries, isolation checking em todo boundary async. Para estratégia de rollout e guardrails veja `references/migration.md`; para o que mudou em 6.2 (isolated conformances, approachable mode, `@concurrent`) veja `references/swift-6-2-concurrency.md` e `references/approachable-concurrency.md`.

> O modo "Approachable Concurrency" / `defaultIsolation(MainActor.self)` é pensado para **apps cliente**; em um serviço Vapor headless o default `nonisolated` + `actor` explícito é o que se usa. Trate a doc de approachable mode como aprofundamento conceitual, não como recomendação para este repo.

## Code Review — onde procurar bugs de concorrência

Ao revisar concorrência neste serviço, varra por (detalhe em `references/hotspots.md` + `references/bug-patterns.md`):

- `Task.detached` / `Task { }` solto sem retorno em handler — handler usa `async throws` direto.
- `@unchecked Sendable` / `nonisolated(unsafe)` em DTO/Error/Event/`shared/` → violação ADR-018.
- Reentrância de `actor`: estado lido antes de um `await` pode estar obsoleto depois (`references/actors-review.md`).
- Cancelamento cooperativo ausente em loops/relays longos (`references/cancellation.md`) — checar `Task.isCancelled`.
- `AsyncStream`/back-pressure em consumidores (`references/async-streams.md`).
- Semáforo/lock ad-hoc em contexto async — usar `actor` ou `Mutex`.

## Reference Router

Abra a menor referência que casa com a pergunta. Índice completo e por-problema em `references/_index.md`.

- **Foundations:** `async-await-basics.md`, `tasks.md`, `actors.md`, `sendable.md`, `threading.md`, `async-sequences.md`, `async-algorithms.md`, `memory-management.md`, `glossary.md`
- **Swift 6.2+ / Advanced:** `swift-6-2-concurrency.md`, `approachable-concurrency.md`, `structured.md`, `unstructured.md`, `cancellation.md`, `bridging.md`, `interop.md`, `new-features.md`
- **Code Review:** `hotspots.md`, `bug-patterns.md`, `diagnostics.md`, `actors-review.md`, `testing-review.md`
- **Migração / tooling / testes:** `migration.md`, `linting.md`, `performance.md`, `testing.md`
- *(`core-data.md` é iOS-only — herdado da base, não se aplica a este backend.)*

## Verification Checklist

1. Reconfira o modo strict concurrency antes de interpretar diagnósticos.
2. Limpe uma categoria de erro por vez (`swift build -c release` zero warnings). Não batch unrelated fixes.
3. Rode os testes (`make test`), especialmente sensíveis a `actor`/lifetime/cancelamento — **suite inteira verde** (regra inviolável do projeto).
4. Confirme que nenhum tipo de fronteira virou `@unchecked Sendable` (ADR-018).
5. Verifique cancelamento/`Task.isCancelled` em tasks de vida longa (relay Outbox).
6. Nunca use semáforo/lock ad-hoc onde `actor`/`Mutex` expressam ownership.

---

**Nota:** o material de foundations desta skill é baseado no [Swift Concurrency Course](https://www.swiftconcurrencycourse.com?utm_source=github&utm_medium=agent-skill&utm_campaign=skill-footer) de Antoine van der Lee. Re-contextualizado e fundido (foundations + Swift 6.2+ + code-review) para o backend `social-care`.
