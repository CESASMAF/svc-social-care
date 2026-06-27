# T-004 — W3 Quality Gates

**Data:** 2026-05-14

## Gates

| Gate | Comando | Resultado |
|---|---|---|
| Build debug compila | `swift build --target social-care-sTests` | ✅ exit 0 |
| Build release zero warnings | `make build-release` | ✅ exit 0, **0 warnings**, 242s |
| Full test suite verde | `make test` | ✅ **327/327** passam, 0.040s |
| Regression suite verde | `make regression` | ✅ 23 testes em 3 suites |
| Teste de regressão novo (T-004) | `swift test --filter RecordEventSilentNoop` | ✅ 2/2 passam, 0.004s |
| Falha colateral OIDC consertada | `swift test --filter OIDCJWTPayload` | ✅ 18/18 passam, 0.019s |
| ADR-004 criado | `handbook/architecture/DECISIONS/ADR-004-*.md` | ✅ |
| DECISIONS.md index atualizado | próximo ID = 005 | ✅ |
| Skill atualizada | `.claude/skills/swift-domain-modeler/SKILL.md` | ✅ Lições Aprendidas + Padrão Aggregate Root |
| Regra "suite verde" propagada | CLAUDE.md + swift-orchestrator + swift-test-writer + swift-domain-modeler | ✅ |

## Compile-time guard validado

Durante o W1, removi temporariamente `addEvent`/`clearEvents` do `TestAggregate` para validar que o compilador rejeita. Output:

```
error: type 'TestAggregate' does not conform to protocol 'EventSourcedAggregateInternal'
note: protocol requires function 'addEvent' with type '(any DomainEvent) -> ()'
note: protocol requires function 'clearEvents()' with type '() -> ()'
```

**Confirmado:** qualquer agregado novo escrito sem `addEvent`/`clearEvents` falha em compile-time. Bug C7 torna-se impossível.

## Falha colateral consertada (T-004.fix)

Suite completo passou para 326/327 antes da fix colateral. Após consertar:
- 1. Helper `decode` em `OIDCJWTPayloadTests.swift` agora usa `.secondsSince1970`
- 2. `@Suite(.serialized)` para serializar acesso ao singleton `OIDCJWTPayloadBootstrap.shared`

Resultado final: 327/327 verde.

## Indicadores de cobertura

```
SwiftPM build:
- 933 arquivos compilados (release)
- 0 warnings após T-004 + T-004.fix
- Tempo: 242s (full release rebuild a frio após Swift 6.3 toolchain switch)

Tests:
- Total: 327 testes em 62 suites
- Regressão: 23 testes em 3 suites (Code Review 2026-03-06 + Regression: Meta + Regression: Event Publication)
- Tempo de execução pura: 0.040s
```

## Próximos tickets liberados

Com T-004 fechado, o invariante "todo agregado é `EventSourcedAggregate` com `addEvent`/`clearEvents` obrigatórios" está enforçado em compile-time. Próximos tickets que criam agregados novos (T-024 decomposição, T-031 UoW) já nascem corretos.

Recomendação:
- **T-005** (Optimistic locking via coluna `version`) — próximo CRITICAL e tem confirmação dupla S-C3 + DB-2.
- **T-007** (`relationship_id` UUID + FK) — só depois de T-006 (PKs), mas DB-1+DB-4 são confirmados duplos.

## Regra inviolável adicionada à pipeline

Durante o W3, a falha OIDC (não relacionada ao T-004) ensinou: **falha colateral é responsabilidade do ticket atual consertar**. Regra agora vive em:

- `CLAUDE.md` (raiz operacional)
- `.claude/agents/swift-orchestrator.md` (orquestrador)
- `.claude/skills/swift-test-writer/SKILL.md` (skill de testes)
- `.claude/skills/swift-domain-modeler/SKILL.md` (skill de domínio)

Próximos tickets que rodarem `make test` e virem teste vermelho **devem parar e consertar**, criando sub-ticket se a fix exigir mudança fora do escopo do ticket atual.
