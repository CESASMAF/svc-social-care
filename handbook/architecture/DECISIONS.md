# Architecture Decision Records — social-care

Índice de ADRs (Architecture Decision Records) do microserviço. Cada decisão
estrutural tem um arquivo dedicado em `DECISIONS/ADR-NNN-<slug>.md`.

> **Quando criar um ADR?** Qualquer decisão que: (a) afeta a forma de codar /
> testar / operar; (b) tem trade-offs que outra pessoa precisará entender no
> futuro; (c) seria difícil de reverter; (d) substitui ou contradiz uma
> decisão anterior. Bug fixes e features de produto não viram ADR — vão no
> commit e no PR.
>
> Para propostas **ainda não aceitas**, use `handbook/architecture/IMPROVEMENT_BACKLOG.md`.
> Quando uma proposta vira decisão fechada, promova para um ADR aqui.

## Índice

| # | Título | Status | Data | Supersedes |
|---:|---|:-:|---|---|
| [001](DECISIONS/ADR-001-swift-6-3-upgrade.md) | Upgrade para Swift 6.3 | Aceito | 2026-05-14 | — |
| [002](DECISIONS/ADR-002-regression-test-policy.md) | Política de testes de regressão | Aceito | 2026-05-14 | — |
| [003](DECISIONS/ADR-003-adr-structure-enforces-test-and-pattern.md) | ADR carrega obrigatoriamente teste de regressão e Better Pattern | Aceito | 2026-05-14 | — |
| [004](DECISIONS/ADR-004-event-sourced-aggregate-composite-protocol.md) | Eventos de domínio via protocolo composto sem cast dinâmico | Aceito | 2026-05-14 | — |
| [005](DECISIONS/ADR-005-optimistic-locking-via-version.md) | Optimistic Locking via coluna `version` | Aceito | 2026-05-14 | — |
| [006](DECISIONS/ADR-006-primary-keys-for-aggregate-tables.md) | Toda tabela é uma relação com PK declarada | Aceito | 2026-05-14 | — |
| [007](DECISIONS/ADR-007-typed-foreign-keys-for-semantic-identity.md) | Colunas que carregam identidade semântica usam tipo nativo + FK | Aceito | 2026-05-14 | — |
| [008](DECISIONS/ADR-008-foreign-keys-for-lookup-tables.md) | FK declarada para toda coluna *_id que aponta para lookup table | Aceito | 2026-05-14 | — |
| [009](DECISIONS/ADR-009-money-vo-replaces-double.md) | Money VO substitui Double em todo valor monetário | Aceito | 2026-05-14 | — |
| [010](DECISIONS/ADR-010-universal-persistence-conflict-mapping.md) | Mapeamento universal de PersistenceConflictError nos handlers | Aceito | 2026-05-14 | — |
| [011](DECISIONS/ADR-011-people-context-fail-secure-and-bearer-forwarding.md) | PeopleContext fail-secure tri-state com Bearer forwarding | Aceito | 2026-05-14 | — |
| [012](DECISIONS/ADR-012-security-headers-and-body-size-limit.md) | Security headers obrigatórios e body size limit no boot | Aceito | 2026-05-14 | — |
| [013](DECISIONS/ADR-013-outbox-for-update-skip-locked.md) | Outbox at-least-once com FOR UPDATE SKIP LOCKED + Nats-Msg-Id | Aceito | 2026-05-14 | — |
| [014](DECISIONS/ADR-014-outbox-events-via-repository.md) | Outbox Pattern — persistência atômica de eventos via Repository | Aceito | 2026-05-14 | — |
| [015](DECISIONS/ADR-015-audit-trail-distinct-id-from-outbox.md) | `audit_trail.id` distinto de `outbox.id` + `outbox_message_id` para rastreio | Aceito | 2026-05-14 | — |
| [016](DECISIONS/ADR-016-nats-publisher-bidirectional-handler.md) | `NATSEventPublisher` adota handler bidirecional NIO (PING/PONG real) | Aceito | 2026-05-14 | — |
| [017](DECISIONS/ADR-017-log-sanitizer-no-pii-in-logs.md) | `LogSanitizer` é a porta única de log de erro em camadas com PII | Aceito | 2026-05-14 | — |
| [018](DECISIONS/ADR-018-no-unchecked-sendable-on-boundary.md) | Banimento de `@unchecked Sendable` em estruturas de fronteira | Aceito | 2026-05-14 | — |
| [019](DECISIONS/ADR-019-decomposition-of-patient-god-aggregate.md) | Decomposição estrutural do god aggregate `Patient` — plano de adoção da Fase 4 | Aceito | 2026-05-14 | — |
| [020](DECISIONS/ADR-020-required-documents-1nf-and-try-map.md) | `required_documents` em tabela filha 1NF + `try map` em vez de `compactMap` | Aceito | 2026-05-14 | — |
| [021](DECISIONS/ADR-021-deterministic-uuid-and-diff-based-upsert.md) | `DeterministicUUID` + diff-based upsert preservam identidade de entidades-filhas | Aceito | 2026-05-14 | — |
| [022](DECISIONS/ADR-022-jsonb-and-temporal-types.md) | JSONB para payloads, TIMESTAMPTZ para operacionais, DATE para conceituais; `JSONCodec` padrão | Aceito | 2026-05-14 | — |
| [023](DECISIONS/ADR-023-created-updated-at-on-root-tables.md) | Auditoria operacional via `created_at`/`updated_at` automáticos em tabelas raiz | Aceito | 2026-05-14 | — |
| [024](DECISIONS/ADR-024-patient-assessment-aggregate-expand.md) | `PatientAssessment` aggregate — estágio EXPAND da decomposição da Fase 4 | Aceito | 2026-05-14 | — |
| [025](DECISIONS/ADR-025-patient-assessment-dual-write.md) | `PatientAssessment` — estágio DUAL-WRITE da decomposição da Fase 4 | Aceito | 2026-05-14 | — |
| [039](DECISIONS/ADR-039-erasure-policy-people-person-deleted.md) | Política de erasure ao consumir `people.person.deleted` (LGPD × No-Delete) | Aceito | 2026-06-09 | — |

> IDs **026 a 038** estão **reservados** (planejados em
> `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md`, cada um amarrado a um
> ticket T-NNN; o ADR é criado conforme o ticket fecha). Por isso, temas **novos
> fora do pipeline** usam IDs a partir de **039** (nunca renumerar). Próximo ID
> livre fora da reserva: **040**.

## Regra de promoção `Proposto` → `Aceito` (ADR-003)

Um ADR só pode ficar `Aceito` quando o arquivo contém, **preenchidas**, as duas seções:

- `## Teste de regressão` — identificador do teste (ou lint/snapshot) que enforça a decisão
- `## Better Pattern para skills` — qual skill em `.claude/skills/` carrega a lição aprendida

ADR sem essas seções fica `Proposto` até completar. Em code review, ADR "Aceito" incompleto é rebaixado para `Proposto` mecanicamente — não é negociável. Justificativa em [ADR-003](DECISIONS/ADR-003-adr-structure-enforces-test-and-pattern.md).

Quando o ADR é puramente documental/governança (raro), citar **por que** teste/skill não é aplicável é aceito como conformidade — desde que justificado na própria seção.

---

## Status possíveis

- **Proposto** — em discussão, sem decisão fechada. Vive aqui como ADR draft.
- **Aceito** — decisão tomada e aplicável.
- **Superseded by ADR-NNN** — substituído por outro ADR. Manter o arquivo
  por histórico (não deletar).
- **Deprecado** — não vale mais, e não foi explicitamente substituído.
  Documentar por que perdeu relevância.
- **Rejeitado** — proposta avaliada e descartada. Manter por histórico
  para evitar re-discussão.

## Numeração

- IDs sequenciais (`ADR-001`, `ADR-002`, ...), nunca renumerar.
- Slug em kebab-case curto: `swift-6-3-upgrade`, `outbox-retry-policy`.
- Se uma proposta é rejeitada, ainda consome um ID — a justificativa
  documentada é tão valiosa quanto a decisão aceita.

## Hierarquia (em conflito)

```
CLAUDE.md (resumo operacional)
  > handbook/architecture/README.md (visão v2.0)
    > ADRs (DECISIONS/ADR-NNN-*.md)
      > Skills (.claude/skills/*) e Agents (.claude/agents/*)
```

Em conflito, **ADR prevalece sobre skill** porque ADR é decisão estrutural
versionada com contexto; skill é guia operacional.

## Histórico documental

Antes de 2026-05-14, decisões estruturais do social-care viviam diluídas em
`CLAUDE.md`, `handbook/architecture/README.md` e nos commits. A partir de
ADR-001, toda decisão futura ganha arquivo dedicado. Decisões antigas
**não serão retroativamente convertidas em ADRs** salvo quando alguém precise
revisitar — nesse caso, cria-se o ADR com seção "Histórico documental"
reconstituindo.
