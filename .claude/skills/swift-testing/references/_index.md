# Reference Index — Swift Testing (social-care)

Navegação para o aprofundamento técnico fundido (fundamentals + advanced + code-review).
A porta de entrada é `../SKILL.md`. No projeto, o *como testar a feature* é a vertical
`swift-test-writer`; aqui está a *profundidade do framework `swift-testing`*.

## Fundamentals

| File | Use it for |
|---|---|
| `fundamentals.md` | `@Test`/`@Suite`, display names, `init`/`deinit` (não setUp/tearDown) |
| `test-organization.md` | suites, tags, traits, execução paralela |
| `test-doubles.md` | taxonomia Fowler (Dummy/Fake/Stub/Spy/SpyingStub/Mock) |
| `fixtures.md` | padrões de fixture, datas determinísticas |
| `integration-testing.md` | interações de módulo, in-memory, workflows |
| `parameterized-tests.md` | múltiplos inputs (arguments, zip, produto cartesiano) |
| `parameterized-testing.md` | ângulo complementar de parameterized |
| `snapshot-testing.md` | snapshot de UI *(menos relevante neste backend)* |
| `dump-snapshot-testing.md` | snapshot textual de estruturas/eventos/agregados |

## Advanced

| File | Use it for |
|---|---|
| `traits-and-tags.md` | filtragem por tag (CI, `make regression`), `.timeLimit`, `.bug` |
| `parallelization-and-isolation.md` | segurança paralela, `.serialized` (testes de Postgres) |
| `expectations.md` | tabela de decisão `#expect` vs `#require`, throw expectations |
| `async-testing.md` | async/await, `confirmation`, timeouts, cancelamento |
| `async-testing-and-waiting.md` | padrões de espera async, actor isolation em testes |
| `async-tests.md` | testes serializados, `confirmation`, mock de rede |
| `performance-and-best-practices.md` | dados determinísticos, prevenção de flakiness |

## Code Review

| File | Use it for |
|---|---|
| `core-rules.md` | struct vs class, `init`/`deinit`, paralelismo, `withKnownIssue`, tags |
| `writing-better-tests.md` | higiene, dependências ocultas, `Issue.record()` |
| `new-features.md` | raw identifiers, test scoping, exit tests, attachments, `#expect(throws:)` atualizado |

## Migração / tooling

| File | Use it for |
|---|---|
| `migration-xctest.md` | guia principal XCTest → Swift Testing |
| `migration-from-xctest.md` | ângulo complementar de migração |
| `migrating-from-xctest.md` | passos de coexistência XCTest/Swift Testing |
| `xcode-workflows.md` | *(orientado a Xcode/IDE — marginal num serviço SwiftPM/Docker)* |

## Quick Links by Problem

- "começar com Swift Testing" → `fundamentals.md`, `test-organization.md`
- "testar múltiplos inputs (ex.: CPFs inválidos)" → `parameterized-tests.md`
- "testar handler async + eventos" → `async-testing.md`, `confirmation` em `async-tests.md`
- "criar fakes / fixtures" → `test-doubles.md`, `fixtures.md`
- "teste flaky / não-determinístico" → `performance-and-best-practices.md`, `fixtures.md` (datas)
- "isolar testes de Postgres" → `parallelization-and-isolation.md` (`.serialized`)
- "revisar qualidade de um teste" → `core-rules.md`, `writing-better-tests.md`
- "migrar de XCTest" → `migration-xctest.md`
