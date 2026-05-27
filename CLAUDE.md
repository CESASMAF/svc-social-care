# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Comandos

```bash
make deps              # Resolver dependências SwiftPM
make build             # Build debug
make build-release     # Build release (--product social-care-s)
make dev               # swift run social-care-s (requer PostgreSQL rodando)
make test              # Executar todos os testes
make coverage          # Testes + gate de cobertura (30% local, 95% no CI)
make ci                # Pipeline completo: deps → build-release → coverage

# Teste individual
swift test --filter NomeDoTeste

# PostgreSQL via Docker para dev local
docker compose up postgres -d
```

## Arquitetura

Microserviço Swift 6.2 / Vapor 4 com Clean Architecture + DDD, CQRS e Transactional Outbox. Código fonte em `Sources/social-care-s/`, testes em `Tests/social-care-sTests/`.

### Camadas e fluxo de dependência

```
Domain ← Application ← IO (HTTP, Persistence, EventBus)
                         ↑
                       shared (AppError, DomainProtocols, Ports)
```

- **Domain/** — Value Objects, Agregados, Entidades, Analytics services. Zero dependências externas. Organizado por bounded context: `Kernel/` (VOs cross-cutting), `Registry/`, `Assessment/`, `Care/`, `Protection/`, `Configuration/`.
- **Application/** — Command/Query handlers. Cada use case segue a estrutura `<UseCase>/Command/`, `<UseCase>/UseCase/` (protocolo), `<UseCase>/Services/` (handler `actor`), `<UseCase>/Error/`. Organizado por BC: `Registry/`, `Assessment/`, `Care/`, `Protection/`, `Configuration/`, `Query/`.
- **IO/** — Adapters. `HTTP/` (Controllers, DTOs, Middleware, Auth, Validation, Bootstrap), `Persistence/SQLKit/` (repositórios, mappers, migrations), `EventBus/` (Outbox).
- **shared/** — `AppError` (erro padronizado com código tipo PAT-001, category, severity), `DomainProtocols` (Command, Query, EventBus, EventSourcedAggregate), `Ports/` (protocolos de integração), `PersistenceConflictError`.

### Padrões-chave

- **Use cases são `actor`**: garantem exclusão mútua. Implementam `CommandHandling<C>` ou `ResultCommandHandling<C>`.
- **VOs e Commands são `struct Sendable`**: imutáveis, seguros para concorrência.
- **Validação de VOs via `init(_ raw:) throws`**: CPF, NIS, CEP, etc. fazem parsing no construtor.
- **Erros de domínio implementam `AppErrorConvertible`**: traduzem para `AppError` na fronteira IO.
- **`PersistenceConflictError.uniqueViolation`**: repositórios lançam este erro genérico para violações de unicidade; o handler de Application mapeia para o erro de negócio específico.
- **Repository contracts são `protocol`** definidos em Domain (ex: `PatientRepository` em `Domain/Registry/Repository/`).
- **`ServiceContainer`** em `IO/HTTP/Bootstrap/` é o composition root — instancia todos os handlers e repositórios, acessível via `Request.services`.
- **StandardResponse\<T\>** com `meta.timestamp` envolve todas as respostas HTTP.
- **Audit trail via `JWT.sub`**: `Request+ActorId.swift::extractActorId()` retorna `requireAuthenticatedUser().userId` (extraído do `sub` claim em `JWTAuthMiddleware.swift` — busque por âncora `// ADR-023:`). Adapters HTTP upstream (BFFs, gateways) DEVEM encaminhar o header `Authorization: Bearer <jwt>` — não há header customizado de identidade do ator. Ver ADR-023 do handbook frontend (`handbook/architecture/DECISIONS/ADR-023-bff-adapter-bearer-forwarding.md`).
- **Multi-issuer OIDC (ADR-027 + ADR-031)**: durante a migração Zitadel → Authentik, o serviço aceita tokens de ambos os issuers (env `OIDC_JWKS_URLS`, `OIDC_ISSUERS`, `OIDC_AUDIENCES` em CSV). `OIDCJWTPayload` (substitui `ZitadelJWTPayload`) lê roles via precedência: claim `roles` (Authentik com property mapping `acdg-roles`) → `groups` (Authentik default) → `urn:zitadel:iam:org:project:roles` (Zitadel legado). Defense-in-depth: `OIDCJWTPayloadBootstrap` registra validators globalmente no boot — `verify(using:)` valida iss/aud/exp/nbf em todo codepath, não apenas no middleware.

### Sequência obrigatória em command handlers

```
parse (VOs) → validate (lookups, existence) → domain logic → persist → publish events
```

Erros são capturados com `do/catch` no handler e mapeados via função `mapError` local.

### Testes

- Framework: `swift-testing` (não XCTest)
- Test doubles em `Tests/social-care-sTests/Application/TestDoubles/`: `InMemoryPatientRepository`, `InMemoryEventBus`, `InMemoryLookupValidator`, `PatientFixture`
- Cobertura mínima: **95%** enforçada no CI via `scripts/check_coverage.sh`
- Testes de domínio em `Tests/.../Domain/v2/`, de application em `Tests/.../Application/`, de IO em `Tests/.../IO/`

## Convenções

- **Branches**: `feat/<slug>`, `fix/<slug>`, `chore/...`
- **Commits**: Conventional Commits (`feat:`, `fix:`, `chore:`, `refactor:`, `test:`)
- **Tags SemVer**: obrigatórias para `feat:` (minor bump) e `fix:` (patch bump) em `main`. Consultar `git tag --sort=-v:refname | head -1` antes de criar nova tag.
- **Strict concurrency**: Swift 6.2 com todas as checks habilitadas. Todo tipo público que cruza boundary de concorrência deve ser `Sendable`.

## Reference Network — consulta fria (especialistas externos)

Para FATOS de documentação de tecnologias (sintaxe, versão exata, comportamento), não responda de memória nem chute: consulte o especialista **EXTERNO read-only**, que cita a doc oficial offline (`infra/reference/`) ou recusa. Divisão: você (interno) conhece o código e **decide**; ele (externo) só entrega o **fato citado** — nunca vê seu código.

Invocação: delegue isolado via `subagent_type: "acdg-ref:ref-<tech>"`, ou direto `/acdg-ref:ref-<tech> <pergunta>`.

| Dúvida sobre… | Consulte |
|---|---|
| Vapor: rotas, middleware, Content, async, JWT/JWKS/OIDC (vapor/jwt) | `ref-vapor` |
| SQL, tipos, funções, GUCs, índices, MVCC (PostgreSQL) | `ref-postgresql` |
| NATS/JetStream: subjects, consumers, ack, Outbox/at-least-once | `ref-nats` |
| Authentik: OIDC/OAuth2 provider, flows, claims/scopes | `ref-authentik` |

Regras: passe a pergunta como **texto** (não mande "olhe meu arquivo X" — ele recusa). Se retornar `NÃO ENCONTRADO`, não invente: escale ou peça download da doc. Detalhes: `infra/reference-network/README.md`.
