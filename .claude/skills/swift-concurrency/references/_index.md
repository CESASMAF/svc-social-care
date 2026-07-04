# Reference Index — Swift Concurrency (social-care)

Navegação para o aprofundamento técnico fundido (foundations + Swift 6.2+ + code-review).
A porta de entrada é `../SKILL.md`; abra aqui a menor referência que casa com a dúvida.

## Foundations

| File | Use it for |
|---|---|
| `async-await-basics.md` | bridges callback→async, ordem de execução, `async let`, padrões URLSession |
| `tasks.md` | `Task`, cancelamento, prioridades, task groups, estruturado vs não-estruturado |
| `actors.md` | isolamento de actor, reentrância, custom executors, `Mutex`, `SendableMetatype` |
| `sendable.md` | `Sendable`, `@Sendable`, region isolation, escape hatches |
| `threading.md` | modelo de execução, suspension points, comportamento de isolamento 6.2 |
| `async-sequences.md` | `AsyncSequence`, `AsyncStream`, quando usar vs async one-shot |
| `async-algorithms.md` | debounce, throttle, merge, `combineLatest`, channels, timers |
| `memory-management.md` | retain cycles em tasks, limpeza de tasks de vida longa |
| `glossary.md` | definições rápidas dos termos núcleo |

## Swift 6.2+ / Advanced

| File | Use it for |
|---|---|
| `swift-6-2-concurrency.md` | isolated conformances, caller-actor semantics, `@concurrent` |
| `approachable-concurrency.md` | default actor isolation mode (conceitual — pensado p/ apps cliente) |
| `structured.md` | task groups vs loops, propagação de cancelamento |
| `unstructured.md` | árvore de decisão `Task` vs `Task.detached` |
| `cancellation.md` | cancelamento cooperativo (relays/loops longos) |
| `bridging.md` | pontes entre código legado e async |
| `interop.md` | interoperabilidade com APIs não-async |
| `new-features.md` | recursos recentes de concorrência |

## Code Review

| File | Use it for |
|---|---|
| `hotspots.md` | alvos de busca em review: `DispatchQueue`, `Task.detached`, loops, continuations, `AsyncStream`, `@unchecked Sendable` |
| `bug-patterns.md` | bugs de runtime comuns |
| `diagnostics.md` | mapeamento erro do compilador → fix |
| `actors-review.md` | reentrância e isolamento de estado compartilhado (ângulo de review) |
| `testing-review.md` | revisão de testes sensíveis a concorrência (ângulo de review) |

## Migração / tooling / testes

| File | Use it for |
|---|---|
| `migration.md` | ordem de rollout, build settings, guardrails |
| `linting.md` | regras de lint focadas em concorrência |
| `performance.md` | workflow Instruments, actor hops, custo de suspensão |
| `testing.md` | testar código async (ver também a skill `swift-testing`) |
| `core-data.md` | *(iOS-only — não se aplica ao backend; herdado da base)* |

## Problem Router

- "preciso corrigir um erro do compilador rápido" → `../SKILL.md`
- "proteger estado mutável compartilhado" → `actors.md` (+ `actors-review.md`)
- "passar dado com segurança entre boundaries" → `sendable.md`
- "achar bug de concorrência em review" → `hotspots.md`, `bug-patterns.md`
- "entender Swift 6.2 isolated conformances / `@concurrent`" → `swift-6-2-concurrency.md`
- "cancelar um relay/loop longo" → `cancellation.md`
- "operadores de stream" → `async-algorithms.md`
- "migrar para Swift 6" → `migration.md`
