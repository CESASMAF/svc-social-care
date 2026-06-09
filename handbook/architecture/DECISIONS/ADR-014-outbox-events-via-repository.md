# ADR-014: Outbox Pattern — persistência atômica de eventos via Repository

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achado **S-C4** (Senior Code Review § achado C4): `OutboxEventBus.publish(_:)` era literalmente **dead code**:

```swift
// OutboxEventBus.swift — pré-fix
public actor OutboxEventBus: EventBus {
    public func publish(_ events: [any DomainEvent]) async throws {
        // Os eventos já foram escritos na tabela outbox_messages pelo repository.save().
        // Aqui poderíamos sinalizar o relay para uma poll imediata —
        // por ora, o relay processa automaticamente via polling periódico.
        guard !events.isEmpty else { return }
    }
}
```

A função recebia eventos e retornava sem fazer nada. **Mas** os 21 handlers chamavam `try await eventBus.publish(patient.uncommittedEvents)` cosmético — convencidos de que controlavam a publicação:

```swift
// 21 handlers tinham esta sequência (pré-fix)
try await repository.save(patient)
try await eventBus.publish(patient.uncommittedEvents)  // ← no-op silencioso
```

O efeito real (escrever na tabela `outbox_messages` na mesma transação do agregado) acontecia **dentro de** `SQLKitPatientRepository.save()`. Acoplamento implícito — a invariante "events ficam no outbox" dependia de o repository fazer a coisa certa, mas a interface do handler enganava.

### Riscos pré-fix

1. **Repository novo silencioso.** Se algum dia outro repository não inserir no outbox interno, eventos somem sem warning porque o handler "publica" via no-op.
2. **Duplicação se EventBus virar real.** Se alguém trocar `OutboxEventBus` por implementação que **realmente** publica (NATS direto, Kafka, etc), os mesmos eventos viram **publicados duas vezes** — uma via outbox interno do save, outra via EventBus externo.
3. **Cognitive overhead.** Leitor do handler vê `eventBus.publish` e perde tempo entendendo que é no-op cosmético.

### Citações canônicas

> *"Avoid exposing the domain model to any kind of middleware messaging infrastructure. […] All registered subscribers execute in the same process space with the publisher and run on the same thread. […] This also implies that all subscribers are running within the same transaction, perhaps controlled by an Application Service that is the direct client of the domain model."*
> — Vaughn Vernon, *Implementing DDD*, p. 382

A intenção do design original (Outbox Pattern) está correta — events na mesma TX do agregado. O bug é que a interface não reflete isso.

> *"Make the assumption explicit by writing an assertion. […] Such assumptions are often not stated but can only be deduced by looking through an algorithm."*
> — Martin Fowler, *Refactoring* 2ª ed., p. 326 (Introduce Assertion)

A "assumption implícita" aqui é: handler chama `eventBus.publish` mas o efeito vem do `repository.save`. Refator move essa assumption para o tipo: handler **só** conhece o repository.

## Decisão

**Opção A da pipeline (proposta no `REMEDIATION_PIPELINE_2026_05_14.md` § T-013):**

1. Handler **não recebe mais** `eventBus` no init.
2. Handler **não chama mais** `eventBus.publish(...)`.
3. `repository.save(patient)` é a porta única de persistência de eventos. Documentado no `PatientRepository` que save escreve agregado + uncommittedEvents na mesma transação.
4. `OutboxEventBus.swift` deletado.
5. `EventBus` protocol em `shared/Domain/DomainProtocols.swift` removido (nenhum uso restante).
6. `InMemoryPatientRepository` (fake) ganha `private(set) var publishedEvents` populado por `save(_:)` — espelha o invariante real para que testes possam asserir eventos via `await repo.publishedEvents`.
7. `InMemoryEventBus` em `TestDoubles/` deletado (órfão).

### Antes vs depois

```swift
// PRÉ-FIX
public actor RegisterIntakeInfoCommandHandler {
    private let repository: any PatientRepository
    private let eventBus: any EventBus  // ← removido
    private let lookupValidator: any LookupValidating

    public init(
        repository: any PatientRepository,
        eventBus: any EventBus,  // ← removido
        lookupValidator: any LookupValidating
    ) { ... }

    public func handle(_ command: RegisterIntakeInfoCommand) async throws {
        // ... domain logic ...
        try await repository.save(patient)
        try await eventBus.publish(patient.uncommittedEvents)  // ← no-op, removido
    }
}

// PÓS-FIX
public actor RegisterIntakeInfoCommandHandler {
    private let repository: any PatientRepository
    private let lookupValidator: any LookupValidating

    public init(
        repository: any PatientRepository,
        lookupValidator: any LookupValidating
    ) { ... }

    public func handle(_ command: RegisterIntakeInfoCommand) async throws {
        // ... domain logic ...
        try await repository.save(patient)
        // events persistem dentro de save() na mesma TX (Outbox Pattern)
    }
}
```

## Alternativas consideradas

- **Opção B da pipeline: `repository.save` salva só agregado; handler chama `eventBus.publish(events, tx: ...)` em UoW coordenado.** Descartada — exige UoW cross-repository (T-030 trata UoW para outro caso) + handler precisa conhecer transação. Mais complexo sem ganho semântico — Vernon é claro que events e agregado vão na MESMA transação.
- **Opção C: Domain Event Publisher in-process (Vernon p. 382 — Publish-Subscribe global).** Considerada. Descartada porque adiciona singleton mutável global (`DomainEventPublisher.shared`). Repository com responsabilidade clara é mais idiomático e não precisa de inicialização adicional.
- **Manter `eventBus.publish` como sinal de "pollar agora"** em vez de no-op puro. Considerada. Descartada — relay tem polling automático via `pollInterval: Duration = .seconds(1)`. Sinal manual é micro-otimização de latência improvável de pesar; complexidade não justifica.
- **Manter `EventBus` protocol como observer in-process opcional** (para casos futuros: BI handler que quer reagir a eventos sem ler outbox). Descartada por agora — princípio YAGNI. Quando vier um observer real, criamos novo protocolo com nome específico.

## Consequências

### Positivas

- **Bug S-C4 eliminado** — handlers não enganam mais o leitor. `repository.save` é a única porta.
- **27 handlers ficam mais enxutos** — menos um campo, menos uma linha. Boilerplate -3 linhas por handler = -81 linhas no total.
- **Repository ganha responsabilidade clara documentada.**
- **InMemoryPatientRepository.publishedEvents** espelha o invariante real — testes detectam regressão se save deixar de gravar events.
- **Dead code deletado** — OutboxEventBus.swift, InMemoryEventBus.swift, EventBus protocol.
- **ServiceContainer mais simples** — não cria mais `OutboxEventBus()`.

### Negativas / custos

- **Refactor invasivo** — 27 handlers + 21 testes + ServiceContainer + 2 testes de regressão tocados num único PR. Mitigação: sed batch validado por suite verde a cada passo.
- **`InMemoryEventBus` legacy desaparece** — testes que dependiam de `bus.eventCount()` foram migrados para `repo.publishedEvents.count`. Mudança puramente sintática.
- **Sinal manual para relay impossível** — se algum endpoint precisar publicar imediatamente em vez de esperar 1s do polling, precisará de outro mecanismo (LISTEN/NOTIFY, signal direto). Não há demanda atual.

### Ações requeridas

- [x] Remover `eventBus` do init dos 27 handlers (sed batch)
- [x] Remover `try await eventBus.publish(...)` dos 27 handlers (sed batch)
- [x] `InMemoryPatientRepository.save` registra `patient.uncommittedEvents` em `publishedEvents`
- [x] Atualizar 21 testes de Application — `bus.publishedEvents` → `repo.publishedEvents`, `bus.eventCount()` → `repo.publishedEvents.count`, `bus.lastEvent()` → `repo.publishedEvents.last`
- [x] Atualizar ServiceContainer — remover `OutboxEventBus()` instantiation, remover `eventBus:` dos handler inits
- [x] Deletar `OutboxEventBus.swift`
- [x] Deletar `InMemoryEventBus.swift`
- [x] Deletar `EventBus` protocol em `DomainProtocols.swift` + comentário documental
- [x] Atualizar testes de regressão (T-011 PeopleContext) que ainda referenciavam `eventBus: bus`
- [x] 3 testes de regressão estruturais em `Regression/EventPublication/`
- [x] Skill `swift-application-orchestrator` atualizada
- [ ] **Documentação:** atualizar `CLAUDE.md` se mencionar "handler chama eventBus.publish" (não menciona — invariante "Eventos publicados após save" continua válida, agora cumprida pelo save).

## Plano de adoção

1. **Imediato (T-013):** refator aplicado. Suite 374/374 verde.
2. **Próximo handler novo:** segue o template — repository é o único parâmetro de persistência. Skill `swift-application-orchestrator` carrega o pattern.
3. **T-024 (decomposição de god aggregate):** novos agregados (`PatientAssessment`, `Care`, `Protection` próprios) seguem o mesmo padrão desde a criação — repository expõe `save(_:)` que registra eventos.
4. **T-029 (futuro, NATS oficial):** quando T-017 substituir o NATS publisher custom, nada muda no contrato repository ↔ handler — só a implementação interna do relay.

## Como reverter

Reverter ADR-014 reintroduz S-C4 (interface enganosa).

Caminho técnico:
1. Restaurar `EventBus` protocol em `DomainProtocols.swift`
2. Recriar `OutboxEventBus.swift` no-op
3. Restaurar `eventBus` no init dos 27 handlers
4. Restaurar chamadas `try await eventBus.publish(...)`
5. Marcar este ADR como `Deprecado`

Não recomendado.

## Teste de regressão

`Tests/social-care-sTests/Regression/EventPublication/OutboxEventBusDeadCodeRegressionTests.swift`:

1. **`test_S_C4_repository_save_registers_events`** — runtime: `InMemoryPatientRepository.save(patient)` adiciona `patient.uncommittedEvents` ao `publishedEvents`.
2. **`test_S_C4_no_handler_calls_eventbus_publish`** — lint estrutural: nenhum `*CommandHandler.swift` em `Application/` contém `eventBus.publish`.
3. **`test_S_C4_no_handler_has_eventbus_in_init`** — lint estrutural: nenhum handler tem `eventBus:` no init.

3/3 passam após refactor.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-application-orchestrator/SKILL.md` — entrada 2 em "Lições Aprendidas".
- **Regra resumida:** Handler NÃO recebe `EventBus` no init. `repository.save(aggregate)` é a porta única de persistência de eventos — escreve agregado + `uncommittedEvents` na mesma transação (Outbox Pattern). Sequência canônica fica: `parse → validate → fetch → domain → persist`. NUNCA chamar `eventBus.publish(...)` no handler — interface enganosa. Fakes (`InMemory*Repository`) espelham o invariante via `publishedEvents` populado pelo save.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § C4 — origem
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-013 — especificação (Opção A)
- [ADR-002](ADR-002-regression-test-policy.md) — política de testes de regressão
- [ADR-005](ADR-005-optimistic-locking-via-version.md) — `repository.save` é o ponto onde optimistic lock vive
- [ADR-013](ADR-013-outbox-for-update-skip-locked.md) — relay lê outbox via FOR UPDATE SKIP LOCKED
- Vaughn Vernon, *Implementing DDD*, cap. 8 (Domain Events) e p. 382 (Publishing Events from the Domain Model)
- Martin Fowler, *Refactoring* 2ª ed., p. 326 (Introduce Assertion)
- Chris Richardson — *Microservices Patterns*, Transactional Outbox
