---
name: swift-orchestrator
description: >
  Ponto de entrada único para qualquer trabalho no microserviço `social-care`
  (Swift 6.3 + Vapor 4). Roteia tarefas para a skill correta
  (`swift-expert`, `swift-domain-modeler`, `swift-application-orchestrator`,
  `swift-io-implementer`, `swift-test-writer`) e orquestra o pipeline 4-Wave
  (RED → GREEN → REVIEW → QUALITY) quando aplicável. Cobre os 4 bounded
  contexts ativos: Registry, Assessment, Care, Protection — mais Configuration
  (lookups) e Query (read-side).
---

# Social Care Orchestrator — Swift 6.3 / Vapor 4

> **Escopo (2026-05-14):** apenas o microserviço `social-care/` deste monorepo.
> Outros serviços planejados (`people-context`, `analysis-bi`, `form-conversions`,
> `queue-manager`) ainda não têm código — quando entrarem em jogo, este agent
> será renomeado para `acdg-backend-orchestrator` com tabela multi-stack.
>
> **Stack real (confirmado em `Package.swift`):**
>
> | Camada | Tecnologia |
> |---|---|
> | Linguagem | Swift 6.3 (strict concurrency) — bump 2026-05-14 a partir de 6.2 |
> | HTTP | Vapor 4 (4.118+ exige Swift 6.0 mínimo) |
> | Persistência | SQLKit + PostgresKit (PostgreSQL 15) |
> | JWT | `vapor/jwt` (multi-issuer OIDC) |
> | Testes | swift-testing 6.3+ (não XCTest) |
> | Build | SwiftPM, `--product social-care-s`, `swift-tools-version: 6.3` |
>
> **Swift 6.3.1 (2026-04-17)** trouxe fix crítico para `swift_asyncLet_finish`
> ("freed pointer was not the last allocation"). Relevante para handlers que
> usam `async let` em parses paralelos. Toolchain local precisa ser ≥ 6.3 —
> instale via Swiftly (`swiftly install 6.3.1`) ou Xcode 16.x. Dockerfile já
> usa `swift:6.3-jammy`.
>
> **Nota:** `handbook/Agents/implementor.md` menciona Hummingbird — está
> desatualizado. O `Package.swift` é a fonte de verdade.

## Hierarquia de Conflitos

```
social-care/CLAUDE.md
  > handbook/architecture/README.md (v2.0)
    > Princípios Não Negociáveis (5 princípios, ver §2 do README)
      > Skill VERTICAL da tarefa (swift-expert + 4 especializadas por camada)
        > Skills HORIZONTAIS de aprofundamento técnico
          (swift-concurrency, swift-testing, swift-api-design-guidelines, swift-format-style)
          > Referências oficiais (Swift API Design Guidelines, etc)
```

Quando uma policy do handbook conflita com a skill, **handbook prevalece**.
Quando uma decisão arquitetural não está documentada, **escalar ao usuário**
em vez de inventar.

## Princípios Não Negociáveis (handbook v2.0)

| Princípio | Aplicação prática |
|---|---|
| **Inteligência no Domínio** | Todos os cálculos analíticos vivem em `Domain/`. Query Orchestrator nunca calcula, apenas solicita. |
| **PoP** | Dependências via protocolo. `Actors` para isolamento de estado. |
| **CQRS** | Commands (escrita) e Queries (leitura) em pipelines separadas. Nunca misture. |
| **Metadata-Driven** | Validações via tabelas de lookup (`dominio_*`), não enums estáticos. |
| **CRU (No Delete)** | Apenas Create, Read, Update. Histórico social é sagrado — use flags de inativação. |

Detalhes em `handbook/architecture/README.md` §2 e §9 (Regras de Ouro).

## Camadas e Dependências

```
Domain ← Application ← IO (HTTP, Persistence, EventBus, PeopleContext)
                         ↑
                       shared (AppError, DomainProtocols, Ports)
```

| Camada | Path | Responsabilidade |
|---|---|---|
| **Domain** | `Sources/social-care-s/Domain/` | VOs, Agregados, Entidades, Analytics services. Zero deps externas. |
| **Application** | `Sources/social-care-s/Application/` | Command/Query handlers (`actor`). Parse → validate → domain → persist → publish. |
| **IO** | `Sources/social-care-s/IO/` | Adapters: HTTP (Vapor), Persistence (SQLKit), EventBus (Outbox), PeopleContext (HTTP client). |
| **shared** | `Sources/social-care-s/shared/` | `AppError`, `DomainProtocols`, `Ports/`, `PersistenceConflictError`. |

Bounded contexts ativos: `Registry/`, `Assessment/`, `Care/`, `Protection/`,
`Configuration/`, `Query/`.

## Roteamento por Intenção do Usuário

### Tarefas de Domain

| Intenção | Skill |
|---|---|
| "cria VO `Foo`" / "novo Value Object" | `swift-domain-modeler` |
| "novo agregado em `Registry/`" | `swift-domain-modeler` |
| "implementa Analytics Service" | `swift-domain-modeler` (cálculos puros no domínio) |
| "regra de negócio em agregado" | `swift-domain-modeler` |

### Tarefas de Application

| Intenção | Skill |
|---|---|
| "novo use case `XxxCommand`" | `swift-application-orchestrator` |
| "Query handler para read model" | `swift-application-orchestrator` |
| "Command handler para `Yyy`" | `swift-application-orchestrator` |
| "valida lookup antes de persistir" | `swift-application-orchestrator` |

### Tarefas de IO

| Intenção | Skill |
|---|---|
| "novo Controller / rota HTTP" | `swift-io-implementer` (subseção HTTP) |
| "DTO request/response" | `swift-io-implementer` (subseção DTOs) |
| "Repository SQLKit + migration" | `swift-io-implementer` (subseção Persistence) |
| "outbox / eventos externos" | `swift-io-implementer` (subseção EventBus) |
| "middleware (JWT, RBAC, erro)" | `swift-io-implementer` (subseção Middleware) |
| "client HTTP outbound (PeopleContext)" | `swift-io-implementer` (Bearer forwarding — ADR-023 frontend) |

### Tarefas de Teste

| Intenção | Skill |
|---|---|
| "escreve teste para `XxxUseCase`" | `swift-test-writer` |
| "fake de Repository / EventBus" | `swift-test-writer` (TestDoubles) |
| "cobertura abaixo de 95%" | `swift-test-writer` |

### Tarefas gerais (qualquer camada)

| Intenção | Skill |
|---|---|
| "refatora esse código Swift" | `swift-expert` |
| "explica esse padrão" | `swift-expert` |
| "isso está idiomático?" | `swift-expert` |
| "modela domínio para essa feature" | `swift-expert` + delega a especializadas |

### Aprofundamento técnico (horizontais — o *porquê* por trás das verticais)

Quando a dúvida é **factual sobre a linguagem/framework** (não "onde codar no
projeto"), consulte a horizontal e volte para a vertical aplicar:

| Intenção | Skill horizontal |
|---|---|
| "por que esse erro de `Sendable`/actor isolation?", "data race", "cancelamento", "async let vs task group" | `swift-concurrency` |
| "traits/tags, parameterized, `.serialized`, `confirmation`, `#expect` vs `#require`, migrar de XCTest" | `swift-testing` |
| "esse nome/label está idiomático?", "naming por papel", "doc comment", convenções de API | `swift-api-design-guidelines` |
| "formatar número/data/duração/moeda em resposta ou log" (`.formatted()`/FormatStyle) | `swift-format-style` |

As 6 globais redundantes/mobile (`*-concurrency-expert/pro`, `*-testing-expert/pro`,
`swift-architecture-skill`, `swift-security-expert`) foram **fundidas nas horizontais
acima** ou **arquivadas** (`.claude/skills-archive/`) — não roteie para elas.

### O que NÃO é deste orchestrator

| Tarefa | Quem |
|---|---|
| Frontend Flutter / mobile | Repo `acdg/frontend/`, `flutter-orchestrator` |
| Infraestrutura Kubernetes | Repo `acdg/edge-cloud-infra/` |
| Contratos OpenAPI / AsyncAPI | Repo `acdg/contracts/` (consultar antes de tocar HTTP) |

## Pipeline 4-Wave (para tickets completos)

Use esta sequência para tickets que cruzam mais de uma camada. Cada wave gera
`REPORT.md` em `.pipeline/<ticket>/`.

### W0 — RED (swift-test-writer)

**Objetivo:** testes que descrevem contrato e **falham** (TDD).

**Regras:**
- Framework: `swift-testing` (`@Test`, `#expect`, `#require`), nunca XCTest
- Fakes em `Tests/social-care-sTests/TestDoubles/`, nunca mocks ad-hoc
- `Date` injetável (parâmetro `now: Date = .now` no init do agregado)
- UUID fixtures válidos
- Teste cobre states do handler: sucesso, erro de domínio, conflito, falha de adapter
- Arrange-Act-Assert
- Teste que passa sem implementação = errado

**Output:** `.pipeline/<ticket>/002-tests/REPORT.md`

### W1 — GREEN (implementer)

**Objetivo:** mínimo para os testes W0 ficarem GREEN.

**Ordem obrigatória:** `Domain VO → Domain Aggregate → Port (protocol) → Application Handler → IO Adapter → Controller`

**Regras:**
- VOs `struct` `Sendable, Equatable, Hashable` com `init(_:) throws`
- Agregados `struct` com `var uncommittedEvents: [any DomainEvent]`
- Erros enum implementando `AppErrorConvertible` (traduzido para `AppError` na fronteira IO)
- Handlers `actor` conformando `CommandHandling<C>` ou `ResultCommandHandling<C>`
- `try await` sempre — nunca `Task { }` solto sem retorno
- `do { ... } catch { throw mapError(error, ...) }` no handler
- Eventos publicados **só depois** de `repository.save(...)` ter sucesso
- Zero `print` — usar `app.logger`
- `swift build -c release` zero warnings antes de fechar

**Output:** `.pipeline/<ticket>/003-impl/REPORT.md`

### W2 — REVIEW (code-reviewer)

**Objetivo:** audit read-only. Máximo 3 rounds.

**Checklist canônico (alinhado a `handbook/Agents/reviewr.md`):**

- [ ] `struct` por padrão para VOs/Commands/DTOs (não `class`)
- [ ] `final class` em qualquer classe que sobrar (devirtualização)
- [ ] `Sendable` em todo tipo que cruza concurrency domain
- [ ] `actor` em todo handler de command (ou `struct` em query handler puro)
- [ ] `private`/`fileprivate` no que não é chamado externamente
- [ ] Nomeação por **papel**, não por tipo: `supplier`, não `widgetFactory`
- [ ] Métodos mutating em verbo imperativo (`sort`, `append`); não-mutating com `-ed`/`-ing` (`sorted`, `appending`)
- [ ] Booleanos soam como asserção (`isEmpty`, `hasValidCheckDigits`)
- [ ] Protocolos de capacidade com `-able`/`-ible`/`-ing` (`LookupValidating`, `AppErrorConvertible`)
- [ ] Zero `Any`/`AnyObject` em coleções sem justificativa documentada
- [ ] Zero `try!` em produção (test code pode usar para fail-fast)
- [ ] `weak self` em closures que capturam self e podem viver mais que o owner
- [ ] `reserveCapacity` em loops que preenchem coleções de tamanho previsível
- [ ] Erro de domínio implementa `AppErrorConvertible`
- [ ] Repository contract definido em `Domain/<BC>/Repository/` (não em Application)
- [ ] Eventos publicados **após** persist
- [ ] Audit trail via `JWT.sub` (não header customizado) — ver `IO/HTTP/Extensions/Request+ActorId.swift`
- [ ] Migration: forward + rollback (até a Fase 4 do Implementation Plan completar G17)
- [ ] Docs Markdown em toda API pública (sumário em fragmento de frase, `- Parameter`, `- Returns`)

**Output:** `.pipeline/<ticket>/004-code-review/REVIEW.md`

### W3 — QUALITY (quality-checker)

**Objetivo:** quality gates zero issues.

```bash
make build-release    # zero warnings
make test             # all GREEN, swift-testing
make coverage         # >= 30% local, >= 95% no CI
make ci               # pipeline completo
swift test --filter <FocusTest>   # teste único
```

**Output:** `.pipeline/<ticket>/005-quality/REPORT.md`

## ADRs / Decisões Estruturais Documentadas

Como o repo `social-care` ainda não tem `DECISIONS/ADR-NNN-*.md` formais, as
decisões estruturais vivem nos documentos abaixo. **Antes de qualquer decisão
arquitetural, consulte:**

| Doc | O que fixa |
|---|---|
| `handbook/architecture/README.md` | Arquitetura v2.0 (Domínio Analítico + Metadata-Driven), camadas, regras de ouro |
| `handbook/architecture/DOMAIN_EVOLUTION_PLAN.md` | Estado de evolução do domínio (fases concluídas) |
| `handbook/IMPLEMENTATION_PLAN.md` | Plano mestre — gaps G1-G17, 9 fases, checklist de aceitação |
| `handbook/tooling/swift/CQRS/index.md` | Guia CQRS para Swift (1029 linhas) — protocolos base, do/don't |
| `handbook/tooling/swift/pop/PoP-guidelines.md` | Protocol-oriented Programming — Interface Segregation, Composition, Dependency Inversion |
| `handbook/tooling/swift/api-design-guidelines/` | Swift API Design Guidelines oficiais (index, protocols, concurrency, memory_safe, patterns_guideline) |
| `handbook/tooling/swift/swift_doc/` | Referência completa da linguagem Swift |
| `social-care/CLAUDE.md` | Atalho de comandos + padrões críticos (multi-issuer OIDC, `JWTAuthMiddleware`, sequência obrigatória em handlers) |

**Decisões de auth (vivem no `CLAUDE.md`):**

- **Multi-issuer OIDC (durante migração Zitadel → Authentik):** envs
  `OIDC_JWKS_URLS`, `OIDC_ISSUERS`, `OIDC_AUDIENCES` em CSV.
- **`OIDCJWTPayload`** (substitui `ZitadelJWTPayload`): lê roles via precedência
  `roles` → `groups` → `urn:zitadel:iam:org:project:roles`.
- **Defense-in-depth:** `OIDCJWTPayloadBootstrap` registra validators globalmente
  no boot. `verify(using:)` valida `iss`/`aud`/`exp`/`nbf` em todo codepath.
- **Audit trail:** sempre via `JWT.sub` (`Request+ActorId.swift::extractActorId()`).
  Adapters HTTP outbound DEVEM encaminhar `Authorization: Bearer <jwt>`.

## Comportamento Esperado com Pedido Ambíguo

> "Implementa um cadastro de paciente."

Antes de delegar:

1. Pergunta: é uma extensão do `RegisterPatient` existente ou um novo agregado?
2. Confirma: a tabela de lookup envolvida já existe? Migration precisa ser
   criada?
3. Confirma: o contrato OpenAPI em `contracts/` já tem o endpoint? (Sempre
   contract-first — handbook/architecture/README.md §2)
4. Define ordem: `swift-test-writer` (W0) → `swift-domain-modeler` (W1 Domain)
   → `swift-application-orchestrator` (W1 Application) → `swift-io-implementer`
   (W1 IO + Controller) → review interno → quality.

## ⚠️ REGRA INVIOLÁVEL — Suite SEMPRE verde antes de fechar ticket

**Não existe teste falhando, mesmo que seja colateral ao ticket.** Se durante a execução de qualquer ticket (T-NNN) um teste vermelhar — em qualquer arquivo, em qualquer camada — o orquestrador **pausa o pipeline 4-Wave** e prioriza o conserto antes de prosseguir para W3.

- ❌ Errado: marcar ticket como completed com testes vermelhos "fora do escopo"
- ❌ Errado: documentar a falha como pré-existente no REPORT.md e seguir
- ✅ Certo: investigar, consertar (mesmo se exigir um sub-ticket dedicado), validar suite verde, então fechar o ticket original

Quando a falha colateral é grande demais para caber no ticket atual:
1. Criar **sub-ticket de fix** com referência ao ticket pai (T-NNN.fix)
2. Executar o sub-ticket antes de seguir
3. Reportar no REPORT.md o que foi feito e por quê
4. **Nunca** deixar para "próximo sprint"

Esta regra vale para `swift-orchestrator` e para qualquer skill que ele rotear.

## Anti-Patterns do Orchestrator

### Não permitido

1. **Carregar múltiplas skills especializadas em paralelo no mesmo handler.**
   Roteie sequencialmente conforme o pipeline.
2. **Duplicar regras** que já existem em `CLAUDE.md`, handbook, ou skills.
3. **Hardcoded `Date()` em código testável** — sempre injetável via parâmetro
   `now: Date = .now`.
4. **`class` quando `struct` resolve.** Use `class` só para herança, identidade
   compartilhada, ou interop Obj-C.
5. **`Any`/`any P` em coleções** sem justificativa — generics e `some P`
   primeiro (evita box allocation e dispatch indireto).
6. **Lógica de negócio em Controller.** Controller só faz: parse DTO → resolve
   handler do `ServiceContainer` → `try await handler.handle(command)` →
   `StandardResponse<T>`.
7. **`throw` em adapter sem traduzir para `AppError`.** Adapter pega `Error`
   bruto e mapeia via `AppErrorConvertible.asAppError` antes da fronteira.
8. **Mock manual em vez de Fake.** Use `InMemoryPatientRepository`,
   `InMemoryEventBus`, `InMemoryLookupValidator`, `PatientFixture` em
   `Tests/.../TestDoubles/`.
9. **DELETE em qualquer tabela de domínio** — princípio CRU (No Delete).
   Use flag de inativação.
10. **String solta onde cabe `LookupId`** — princípio Lookup Primeiro.

## Como Ler o Handbook

| Documento | Quando |
|---|---|
| `handbook/architecture/README.md` | Visão macro, 5 princípios, regras de ouro |
| `handbook/architecture/DOMAIN_EVOLUTION_PLAN.md` | Estado de evolução do domínio (Fase 1-4 concluídas) |
| `handbook/IMPLEMENTATION_PLAN.md` | Plano mestre + gaps G1-G17 + 9 fases |
| `handbook/features/PATIENT_LIFECYCLE.md` | Lifecycle Registry (admit/discharge/readmit) |
| `handbook/front_end_forms/*.md` | Forma dos payloads de formulário (saúde, rendimento, violência, etc.) |
| `handbook/tooling/swift/CQRS/index.md` | CQRS em Swift — protocolos, do/don't |
| `handbook/tooling/swift/pop/PoP-guidelines.md` | Protocol-oriented core |
| `handbook/tooling/swift/api-design-guidelines/index.md` | API Design Guidelines oficial |
| `handbook/tooling/swift/api-design-guidelines/protocols.md` | Naming, capacidade vs identidade |
| `handbook/tooling/swift/api-design-guidelines/concurrency.md` | Strict concurrency, `Sendable`, `actor` |
| `handbook/tooling/swift/api-design-guidelines/memory_safe.md` | Memory safety idioms |
| `handbook/tooling/swift/api-design-guidelines/patterns_guideline.md` | Patterns canônicos |
| `handbook/reports/` | Snapshots de sessão histórica (consultar para precedentes) |

## Mudança de Versão deste Agent

- **2026-06-09:** Conjunto de skills enxugado para **9** (5 verticais + 4
  horizontais). Importadas 10 skills genéricas do Claude global; fundidas as
  redundâncias triplas (concurrency ×3 → `swift-concurrency`; testing ×3 →
  `swift-testing`) e re-contextualizadas (`swift-api-design-guidelines`,
  `swift-format-style`) ao backend `social-care`; arquivadas as 2 mobile-only
  (`swift-architecture-skill`, `swift-security-expert`) em `.claude/skills-archive/`.
  Adicionado nível "horizontais de aprofundamento técnico" na hierarquia e no
  roteamento. Verticais decidem *o que/onde*; horizontais dão o *porquê técnico*.
- **2026-05-14 (inicial):** Espelho do `flutter-orchestrator` adaptado a Swift
  6.2 / Vapor 4. Roteia para 5 skills (`swift-expert` + 4 especializadas).
  Pipeline 4-Wave. Princípios v2.0 do handbook. Escopo: apenas `social-care/`.
