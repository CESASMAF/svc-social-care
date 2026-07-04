# T-004 — Orchestrator Plan

**Data:** 2026-05-14
**Skill rota:** `swift-test-writer` (W0) + `swift-domain-modeler` (W1) — sequencial
**Achado:** S-C7 (`SENIOR_CODE_REVIEW_2026_05_14.md`) — recordEvent no-op silencioso

## Escopo confirmado

Conforme `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-004:

1. Refatorar `EventSourcedAggregate` para compor `EventSourcedAggregateInternal` (herança)
2. Simplificar `recordEvent` removendo cast dinâmico `as? any P`
3. Adicionar `clearEvents` ao protocolo `Internal`
4. Garantir que `Patient` continua conformando
5. Criar teste de regressão em `Regression/EventPublication/`
6. Criar ADR-004 + atualizar `swift-domain-modeler` SKILL.md

## Ordem de execução (4-Wave)

```
W0 RED → swift-test-writer
  • RecordEventSilentNoopRegressionTests.swift com TestAggregate SEM addEvent
  • test_S_C7_recordEvent_actually_appends — falha com count == 0 (bug presente)
  • test_S_C7_patient_conforms_internal_via_composition — passa (Patient já conforma)
  • Output: .pipeline/T-004/002-tests/REPORT.md

W1 GREEN → swift-domain-modeler (Domain shared)
  • DomainProtocols.swift: EventSourcedAggregate: EventSourcedAggregateInternal
  • EventSourcedAggregateInternal: addEvent + clearEvents
  • recordEvent default: self.addEvent(event) — sem cast
  • Patient: nada a mudar (já conformava ambos)
  • TestAggregate: adicionar addEvent/clearEvents (agora obrigatórios)
  • Output: .pipeline/T-004/003-impl/REPORT.md

W2 REVIEW (implícita — verifica grep recordEvent + uses)
  • Patient.swift inalterado, ainda conforma
  • Zero cast dinâmico em recordEvent
  • Build limpo

W3 QUALITY → quality gates
  • make build-release zero warnings
  • make test 327/327 verde (após fix colateral T-004.fix)
  • make regression 23 testes verdes
  • Output: .pipeline/T-004/005-quality/REPORT.md

PÓS-MERGE
  • ADR-004 criado (handbook/architecture/DECISIONS/)
  • swift-domain-modeler/SKILL.md ganha entrada "Lições Aprendidas"
  • DECISIONS.md index atualizado (próximo ID = 005)
```

## Falha colateral encontrada (T-004.fix)

Durante `make test` da W3, **1 teste OIDC** (`verifyRejectsExpiredToken`) falhou. **Não tinha relação com T-004**, mas conforme regra inviolável da pipeline ("não existe teste falhar"), tratei como sub-ticket prioritário antes de fechar T-004.

Causas (2 bugs encadeados):
1. **JSONDecoder vanilla com `.deferredToDate`** — decodifica `exp` (Unix epoch) como segundos desde 2001-01-01, mandando o `Date` ~31 anos para o futuro. `verifyNotExpired()` passa em vez de falhar.
2. **`OIDCJWTPayloadBootstrap.shared` singleton mutável** sem `.serialized` no `@Suite` — 3 testes mutam o singleton em paralelo, causando race.

Fix:
- Helper `decode` agora usa `decoder.dateDecodingStrategy = .secondsSince1970` (mesma estratégia que `JWTKit/CustomizedJSONCoders.swift:47` usa internamente).
- `@Suite(.serialized)` no `OIDCJWTPayloadTests` para serializar acesso ao singleton.

Documentação no próprio arquivo de teste explicando por quê.

## Dependências

- T-001 (Foundations — Regression Suite criada) ✅
- T-002 (ADR template com seções obrigatórias) ✅
- T-003 (Lições aprendidas em skills) ✅

## Bloqueia

- Nada diretamente. Mas é pré-requisito implícito para qualquer agregado novo (T-024 decomposição) — sem este fix, agregados novos poderiam virar bug C7.
