# T-013 — W3 Quality Gates

**Data:** 2026-05-14
**Achado:** S-C4 (Senior Code Review — OutboxEventBus.publish dead code)

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 41.76s, 0 warnings novos |
| Full test suite | ✅ **374/374** passam, 0.079s |
| Regression suite | ✅ 70 testes em 13 suites (+3 do T-013) |
| Testes T-013 | ✅ **3/3** passam (1 runtime + 2 lint estruturais) |
| ADR-014 | ✅ |
| DECISIONS.md index | próximo ID = 015 | ✅ |
| Skill `swift-application-orchestrator` | entrada 2 em "Lições Aprendidas" | ✅ |

## Arquivos deletados

- `Sources/.../IO/EventBus/OutboxEventBus.swift` — era dead code
- `Tests/.../TestDoubles/InMemoryEventBus.swift` — órfão pós-refator

## Arquivos modificados

**Sources (29 arquivos):**
- `shared/Domain/DomainProtocols.swift` — protocol `EventBus` removido + comentário documental
- `IO/HTTP/Bootstrap/ServiceContainer.swift` — não cria mais `OutboxEventBus()`; handlers instanciados sem `eventBus:`
- 27 `*CommandHandler.swift` — removido `private let eventBus`, parâmetro `eventBus:` no init, `try await eventBus.publish(...)` no body

**Tests (24 arquivos):**
- `Tests/.../Application/TestDoubles/InMemoryPatientRepository.swift` — adicionado `private(set) var publishedEvents`; `save(_:)` registra `patient.uncommittedEvents`
- 21 `*Tests.swift` em `Application/` — `eventBus: bus` removido; `bus.publishedEvents`/`eventCount`/`lastEvent` migrado para `repo.publishedEvents`
- `Tests/.../Regression/Security/PeopleContextNoFailOpenRegressionTests.swift` — adaptado para nova interface
- `Tests/.../Regression/EventPublication/OutboxEventBusDeadCodeRegressionTests.swift` — **NOVO** (3 testes)

**Handbook + skill:**
- `handbook/architecture/DECISIONS/ADR-014-outbox-events-via-repository.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-014 indexado; próximo ID = **015**
- `.claude/skills/swift-application-orchestrator/SKILL.md` — Lições Aprendidas entrada 2

## Decisões arquiteturais

1. **Opção A da pipeline** (proposta original): repository.save é porta única. Mais limpa que UoW cross-repository (Opção B) ou DomainEventPublisher singleton (Opção C — Vernon p. 382).
2. **`InMemoryPatientRepository.publishedEvents`** espelha o invariante real do `SQLKitPatientRepository` (que escreve `outbox_messages` na TX do save). Sem esse espelhamento, fakes mentem em relação ao real.
3. **Sed batch para 27 handlers** funcionou bem — padrão muito repetitivo. Validei com build incremental a cada passo.
4. **`EventBus` protocol deletado** — nenhum uso restante. Comentário documental no DomainProtocols.swift orienta o leitor.

## Antes vs depois (handler típico)

```diff
 public actor RegisterIntakeInfoCommandHandler: RegisterIntakeInfoUseCase {
     private let repository: any PatientRepository
-    private let eventBus: any EventBus
     private let lookupValidator: any LookupValidating

-    public init(repository: any PatientRepository, eventBus: any EventBus, lookupValidator: any LookupValidating) {
+    public init(repository: any PatientRepository, lookupValidator: any LookupValidating) {
         self.repository = repository
-        self.eventBus = eventBus
         self.lookupValidator = lookupValidator
     }

     public func handle(_ command: RegisterIntakeInfoCommand) async throws {
         // ... domain logic ...
         try await repository.save(patient)
-        try await eventBus.publish(patient.uncommittedEvents)
     }
 }
```

Boilerplate -3 linhas por handler × 27 handlers = **-81 linhas**.

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-014 (já reportados) | 12 fechados | 13 ADRs | 51 testes |
| T-013 | S-C4 | ADR-014 | 3 |
| **Total** | **13 fechados** | **14 ADRs** | **54 regression tests** |

## Próximos tickets sugeridos

- **T-015** — `audit_trail.id` distinto de `outbox.id` (S-C10, CRITICAL — batch dies on duplicate)
- **T-017** — NATS cliente oficial (S-C9, CRITICAL — substitui custom TCP frágil)
- **T-019** — `AnyJSON` enum Sendable (S-H-IO6, HIGH — strict concurrency)
