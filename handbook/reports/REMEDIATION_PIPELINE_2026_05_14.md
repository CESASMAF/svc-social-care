# Pipeline de Remediação — `social-care` (2026-05-14)

> ## 🔖 SELO DE STATUS — 2026-07-04 (v0.15.0)
>
> **Este é um report datado (snapshot de 2026-05-14) — não é reescrito, apenas
> selado com o status de execução.** Reconciliado com o código em 2026-07-04:
>
> - **Fases 0-4 (T-001..T-024): CONCLUÍDAS.** Materializaram-se `ADR-004..ADR-025`
>   e o suite `Tests/.../Regression/` (T-001) com 22 arquivos em 6 subpastas.
>   As migrations `2026_05_14_*` (PKs, FKs, TypeRelationshipAsUUID, AuditTrailDistinctId,
>   PatientAssessments, RequiredDocuments, JSONB restore) são a evidência.
> - **Fase 5 (T-025..T-031): PARCIAL.** ✅ T-028 (cursor pagination) entregue em
>   v0.7.0 (`ListPatients`) — **sem ADR-028 formal** (dívida). ❌ T-025 (outbox
>   index event_type — verificar), T-026 (UF CHECK), T-030 (UnitOfWork cross-repo),
>   T-031 (LookupBatchValidator) **não implementados** — `grep` não encontra
>   `UnitOfWork` nem `LookupBatchValidator` no código.
> - **Fase 6 (T-032..T-038): PARCIAL.** Alguns lint tests de regressão existem
>   (RoleGuard); UoW/clock-injetável/naming em aberto.
> - **⚠️ Conflito de numeração de ADR resolvido:** os IDs **027 / 029 / 031**
>   reservados aqui para *naming EN* / *JWKS-refresh* / *LookupBatchValidator*
>   foram, na prática, **materializados para o tema OIDC multi-issuer** (PR #18) —
>   é como código, testes e skills os usam. A atribuição deste report para esses
>   três IDs está **superada**; os temas do pipeline, se promovidos, recebem
>   ID ≥040. Ver `handbook/architecture/DECISIONS.md` (nota da faixa 026-038).
>
> Fora deste pipeline, o serviço também ganhou: patient lifecycle, erasure LGPD
> (ADR-039), Configuration BC e OIDC multi-issuer (ADR-027/029/031). Detalhe em
> `handbook/IMPLEMENTATION_PLAN.md` (bloco STATUS).

**Fonte:** cruzamento entre `SENIOR_CODE_REVIEW_2026_05_14.md` (revisão senior cross-camada) e `DATABASE_MODELING_REVIEW_2026_05_14.md` (revisão teórica de schema).
**Orquestrador:** `swift-orchestrator` (`.claude/agents/swift-orchestrator.md`) com pipeline 4-Wave (RED → GREEN → REVIEW → QUALITY).
**Objetivo:** transformar os ~117 achados em uma pipeline acionável de **tickets atômicos**, com testes de regressão escritos ANTES da implementação, ADRs documentando cada decisão estrutural, e _Better Patterns_ alimentando as skills para que erros similares não voltem.

---

## 1. Princípios desta pipeline

### 1.1 Cada erro vira três artefatos

Para cada ticket, geramos sempre **três artefatos**, não apenas a correção:

1. **Teste de regressão** (W0/RED) — escrito antes da fix, falha hoje, passa após a fix, e fica permanentemente no suite para impedir reintrodução.
2. **ADR** (quando a fix muda forma de codar/testar/operar) — documenta a decisão, alternativas, consequências.
3. **Better Pattern** — snippet/regra adicionada à skill correspondente (`swift-domain-modeler`, `swift-application-orchestrator`, `swift-io-implementer`, `swift-test-writer`) ou ao `handbook/tooling/swift/` para que futuras gerações de código nasçam corretas.

> **Por que o ADR vale o esforço:** futuro-você (ou um novo dev) vai querer entender *por que* a regra existe. Sem ADR, a regra parece arbitrária e é a primeira coisa a ser questionada/quebrada. Sem o teste de regressão, ela não é enforçada. Sem o Better Pattern na skill, o próximo código gerado por IA reintroduz o bug.

### 1.2 Estrutura de cada ticket

```
TICKET-NNN: <título>
├── Achados cobertos: S-CN (Senior Review), DB-N (Database Review)
├── Dependências: TICKET-XXX (precisa estar pronto antes)
├── Skill rota: swift-{domain,application,io,test}-* (do swift-orchestrator)
├── W0 — RED:    [testes de regressão a escrever]
├── W1 — GREEN:  [implementação mínima]
├── W2 — REVIEW: [critérios de aceitação além do checklist canônico]
├── W3 — QUALITY: [gates além de make ci]
├── ADR:         [ID candidato + título + escopo]
├── Better Pattern: [onde fica + regra adicionada]
└── Risco / Notas
```

### 1.3 Pipeline 4-Wave (do swift-orchestrator)

```
W0 RED      → swift-test-writer    → testes que descrevem contrato e FALHAM
W1 GREEN    → swift-{domain|application|io}-* → mínimo para os testes ficarem GREEN
W2 REVIEW   → maestro:code-reviewer → audit read-only, max 3 rounds
W3 QUALITY  → quality gates        → make build-release / test / coverage / ci
```

Cada wave gera `REPORT.md` em `.pipeline/<ticket>/`.

### 1.4 ADR como invariante perene

O `handbook/architecture/DECISIONS.md` já tem ADR-001 (Swift 6.3 upgrade). Próximo ID disponível: **ADR-002**. Cada ticket abaixo lista o ADR candidato com `[ADR-NNN]` — quando o ticket fechar, o ADR é criado a partir do `DECISIONS/ADR-TEMPLATE.md`.

---

## 2. Cruzamento dos dois relatórios

A tabela abaixo mostra a sobreposição entre os achados do Senior Review (S) e do Database Review (DB). Achados em ambos têm prioridade dobrada — duas lentes independentes confirmam o problema.

| Achado consolidado | Senior Review | DB Review | Severidade | Ticket |
|---|---|---|---|---|
| Save sem optimistic locking apesar de coluna `version` | C3 | DB-2 | CRITICAL | T-005 |
| God aggregate Patient = tabela ultra-larga | H-D1 | DB-7 | HIGH→CRITICAL | T-015 a T-019 |
| Delete-and-insert / IDs novos a cada save | H-P1 | DB-6 | HIGH→CRITICAL | T-021 |
| `family_members.relationship` é TEXT armazenando UUID | H-D5 | DB-4 | HIGH→CRITICAL | T-007 |
| Strings soltas onde cabe `LookupId` (PrimitiveObsession) | H-D5 | DB-3, DB-4 | HIGH | T-007, T-008 |
| `required_documents` JSON em TEXT (violação 1NF) | H-A7 | DB-5 | HIGH | T-020 |
| `Address.state` validado em código, não em schema | LOW | DB-11 | MEDIUM | T-026 |
| Encoders JSON inconsistentes / sem padronização | H-P7 | DB-9, DB-10 | HIGH | T-022 |
| Naming PT/EN misto no schema | LOW | DB-12 | LOW | T-027 |
| Falta `created_at`/`updated_at` em `patients` | H-P5 | DB-17 | MEDIUM | T-023 |
| `audit_trail.actor_id` como TEXT | — | DB-14 | MEDIUM | T-024 |
| Outbox sem índice em `event_type` | — | DB-15 | MEDIUM | T-025 |
| Money como Double | — | DB-8 | HIGH | T-009 |
| `patient_diagnoses`/`family_members` sem PK | — | DB-1 | CRITICAL | T-006 |
| 8+ colunas `*_id` sem FK declarada | — | DB-3 | CRITICAL | T-008 |
| Mistura TIMESTAMP / TIMESTAMPTZ | — | DB-10 | MEDIUM | T-022 |
| Regressão JSONB → TEXT | — | DB-9 | HIGH | T-022 |
| PeopleContext fail-open | C1 | — | CRITICAL | T-011 |
| Outbox relay duplica eventos | C2 | — | CRITICAL | T-012 |
| `OutboxEventBus.publish` dead code | C4 | — | CRITICAL | T-013 |
| Sem security headers | C5 | — | CRITICAL | T-014 |
| 20/21 handlers não mapeiam PersistenceConflictError | C6 | — | CRITICAL | T-010 |
| `recordEvent` cast dinâmico no-op silencioso | C7 | — | CRITICAL | T-004 |
| `ApproveLookupRequest` sem transação cross-repo | C8 | — | CRITICAL | T-031 |
| `NATSEventPublisher.readInbound` vazio | C9 | — | CRITICAL | T-029 |
| `audit_trail.id` colide com `outbox.id` | C10 | — | CRITICAL | T-030 |

**Total de tickets:** 38, organizados em **6 fases**.

---

## 3. Mapa das 6 fases

```
FASE 0 — Foundations            T-001 a T-003   (test infra + ADR cadence)
FASE 1 — Bloqueios estruturais  T-004 a T-009   (PK, optimistic lock, FKs, Money, recordEvent)
FASE 2 — Segurança crítica      T-010 a T-014   (PersistenceConflict, PeopleContext, Outbox, Headers)
FASE 3 — Outbox & Eventos       T-015 a T-019   (audit_trail, NATSPublisher, OutboxEventBus dead code)  ← renumerado
FASE 4 — Quebrar god aggregate  T-020 a T-024   (decompor Assessment/Care/Protection do Patient)
FASE 5 — UoW e Polish           T-025 a T-031   (UoW, LookupBatchValidator, JSONB revert, naming)
FASE 6 — Skill learning loop    T-032 a T-038   (better patterns, lint tests, prevenção contínua)
```

> ⚠️ As fases têm **dependências**. Não dá pra começar T-007 (FKs) antes de T-006 (PKs). T-021 (diff upsert) depende de T-006. T-015-T-019 dependem de T-005 (optimistic lock) para a decomposição não introduzir mais race.

A ordem abaixo respeita dependências — segui-la garante que cada ticket abre o próximo.

---

# FASE 0 — Foundations

Objetivo: estabelecer a infra que viabiliza o resto da pipeline. **Sem essa fase, os tickets seguintes ficam sem testes de regressão padronizados e os ADRs viram bagunça**.

---

## T-001 — Estabelecer suite de testes de regressão (Regression Suite)

| Campo | Valor |
|---|---|
| Achados | Meta — todos os outros tickets dependem |
| Dependências | — |
| Skill rota | `swift-test-writer` |

### W0 — RED

Não tem teste-de-teste. O ticket é meta-infra: criar `Tests/social-care-sTests/Regression/` com subpastas por tema:

```
Regression/
├── Concurrency/         (T-005, T-012 — race conditions)
├── DataIntegrity/       (T-006, T-007, T-008 — PK, FK, types)
├── EventPublication/    (T-013, T-029, T-030 — outbox/events)
├── Security/            (T-011, T-014 — auth, headers)
├── DomainInvariants/    (T-004, T-021 — agregado, identidade)
└── ErrorMapping/        (T-010 — PersistenceConflictError)
```

### W1 — GREEN

- Adicionar `make regression` no Makefile que roda `swift test --filter Regression`.
- Adicionar tag no CI para rodar **somente** o suite de regressão em PR pequeno (sanity check).
- Criar helper `RegressionFixture` em `Tests/.../TestDoubles/` com:
  - `frozenClock(_:)` → `Clock` injetável determinístico
  - `inMemoryUnitOfWork()` → para tickets de UoW
  - `prepopulatedLookupValidator(…)` → para isolar de fakes ad-hoc

### W2 — REVIEW

- [ ] Cada subpasta tem README explicando *qual classe de bug* aquele suite previne
- [ ] Helpers em `TestDoubles/` reutilizáveis, não duplicados

### W3 — QUALITY

- `make regression` passa em < 5s (não pode degradar para "rodar quando der")
- Cobertura do `Regression/` reportada separadamente

### ADR

**ADR-002 — Política de testes de regressão**
- Contexto: bugs corrigidos voltam quando ninguém escreve teste contra eles
- Decisão: todo achado de severidade ≥ HIGH ganha teste de regressão obrigatório antes do GREEN
- Alternativas: confiar em PR review (descartada — não escala); testes unitários genéricos (descartada — não capturam a forma específica do bug)
- Consequências: suite cresce indefinidamente; mitigação = tag CI por subpasta

### Better Pattern

Adicionar a `handbook/tooling/swift/testing/regression-pattern.md`:

> **Padrão Regression Test**
> Quando um bug é corrigido, o teste de regressão tem 3 partes obrigatórias:
> 1. **Reproduz o bug original** (assert que o estado inválido era aceito antes)
> 2. **Assert do invariante** que a fix garante
> 3. **Documenta o achado** no nome do teste: `test_S_C3_save_should_reject_stale_version()`
>
> Nome do teste é a primeira documentação. `test_doSomething()` perde contexto em 6 meses.

Adicionar à skill `swift-test-writer`:

```markdown
## Anti-pattern: teste de regressão sem referência ao achado original
Um teste chamado `testConcurrentSaveFails()` perde valor em 1 ano. Use o ID do
achado no nome (`test_S_C3_…`) e referencie o report no comentário do `@Test`.
```

---

## T-002 — Atualizar ADR-TEMPLATE com seções de teste e Better Pattern

| Campo | Valor |
|---|---|
| Achados | Meta — cada ADR futuro precisa amarrar teste + skill |
| Dependências | — |
| Skill rota | — (manual / documentação) |

### W0 — RED

Não aplicável. Ticket de docs.

### W1 — GREEN

Adicionar ao `handbook/architecture/DECISIONS/ADR-TEMPLATE.md` duas seções obrigatórias:

```markdown
## Teste de regressão

Identificador do teste (`Tests/.../Regression/.../<NomeDoTeste>.swift::test_…`) e
descrição em uma frase do que ele garante. Se a fix do achado for distribuída em
múltiplos arquivos, listar todos os testes.

## Better Pattern para skills

Qual skill foi atualizada (`swift-{domain,application,io,test}-*` ou
`handbook/tooling/swift/...`), e a regra resumida em 1-3 linhas. Esse é o
mecanismo que garante que IA-gerada não reintroduz o bug.
```

### W2 — REVIEW

- [ ] Template gera ADR consistente entre autores diferentes
- [ ] Referência cruzada para `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` (este doc) ajuda navegação

### ADR

**ADR-003 — Estrutura obrigatória de ADR com teste e Better Pattern**

### Better Pattern

`DECISIONS.md` adquire instrução: "ADR sem seção 'Teste de regressão' OU sem 'Better Pattern' NÃO é Aceito — fica Proposto até completar".

---

## T-003 — Catálogo de Better Patterns nas skills

| Campo | Valor |
|---|---|
| Achados | Meta — onde Better Patterns viram conhecimento permanente |
| Dependências | T-002 |
| Skill rota | — (manual / skill SKILL.md) |

### W0 — RED

N/A.

### W1 — GREEN

Cada skill em `.claude/skills/swift-*/SKILL.md` ganha seção `## Lições Aprendidas (regressões prevenidas)`:

```markdown
## Lições Aprendidas (regressões prevenidas)

> Cada item aqui é um padrão que **a skill deve aplicar por default** porque já
> custou caro no passado. Sempre que um ADR aprovado introduzir um Better
> Pattern, ele é adicionado aqui com link ao ADR e ao teste de regressão.

| # | Padrão | ADR | Teste |
|---|---|---|---|
| (vazio até o primeiro Better Pattern ser merged) |
```

### ADR

**ADR-004 — Skills carregam catálogo de Lições Aprendidas**

### Better Pattern

Quando uma skill é updateda, o git diff da seção é o mecanismo de auditoria. Sem
isso, "skill aprendeu" vira fé.

---

# FASE 1 — Bloqueios estruturais

Objetivo: corrigir os 6 problemas estruturais que **bloqueiam** outros tickets. PK ausente impede FK. recordEvent quebrado impede confiar em eventos. Optimistic lock ausente impede prod multi-instância. Money como Double envenena todos os cálculos financeiros downstream.

---

## T-004 — Unificar `EventSourcedAggregate` ⊇ `EventSourcedAggregateInternal`

| Campo | Valor |
|---|---|
| Achados | S-C7 (recordEvent no-op silencioso) |
| Dependências | T-001 |
| Skill rota | `swift-domain-modeler` (Domain) |

### W0 — RED

`Tests/social-care-sTests/Regression/EventPublication/RecordEventSilentNoopTest.swift`:

```swift
@Test
func test_S_C7_recordEvent_emits_event_when_aggregate_only_conforms_to_EventSourcedAggregate() {
    // Arrange: cria um agregado de teste que conforma APENAS EventSourcedAggregate
    // (não EventSourcedAggregateInternal) — antes da fix isto era no-op silencioso.
    struct TestAggregate: EventSourcedAggregate { ... }
    var agg = TestAggregate()

    // Act
    agg.recordEvent(TestEvent.foo)

    // Assert: depois da fix, o protocolo composto OBRIGA o storage.
    // Antes: agg.uncommittedEvents.count == 0 (bug); Depois: == 1.
    #expect(agg.uncommittedEvents.count == 1)
}
```

### W1 — GREEN

`shared/Domain/DomainProtocols.swift`:

```swift
public protocol EventSourcedAggregate: EventSourcedAggregateInternal {
    var uncommittedEvents: [any DomainEvent] { get }
}

public protocol EventSourcedAggregateInternal {
    mutating func addEvent(_ event: any DomainEvent)
    mutating func clearEvents()
}

extension EventSourcedAggregate {
    public mutating func recordEvent(_ event: any DomainEvent) {
        self.addEvent(event)
    }
}
```

Removida a cláusula `as? any` — compilador agora bloqueia quem esqueça.

### W2 — REVIEW

- [ ] Patient, SocialCareAppointment, Referral, RightsViolationReport conformam o novo protocolo composto
- [ ] Nenhum cast dinâmico permanece em `recordEvent`
- [ ] Sem regressões em testes existentes de eventos

### W3 — QUALITY

`make build-release` zero warnings (este patch toca shared, propaga compilação).

### ADR

**ADR-005 — Eventos de domínio via protocolo composto sem cast dinâmico**
- Contexto: `recordEvent` via `as? any` engole eventos se agregado esquecer de conformar
- Decisão: `EventSourcedAggregate: EventSourcedAggregateInternal` torna requisito tipado
- Alternativas: `precondition` em runtime (descartada — pega tarde); deixar como está + lint (descartada — frágil)

### Better Pattern

Adicionar a `swift-domain-modeler.skill.md`:

```markdown
## Padrão Eventos de Agregado

Aggregate root SEMPRE adota `EventSourcedAggregate` (que inclui `Internal`).
NUNCA criar protocolo paralelo "lite" que omite `addEvent` — events viram no-op.
```

---

## T-005 — Optimistic locking via coluna `version`

| Campo | Valor |
|---|---|
| Achados | S-C3 + DB-2 (DUPLO HIT — confirmado por duas lentes) |
| Dependências | T-001 |
| Skill rota | `swift-io-implementer` (Persistence) + `swift-domain-modeler` (incrementar version) |

### W0 — RED

`Tests/.../Regression/Concurrency/OptimisticLockTest.swift`:

```swift
@Test
func test_S_C3_DB_2_lost_update_is_rejected() async throws {
    // Arrange: paciente já existe com version=1.
    let initial = try PatientFixture.registered()
    try await repo.save(initial)

    // Ambos processos carregam version=1
    let a = try await repo.find(byId: initial.id)!
    let b = try await repo.find(byId: initial.id)!

    // A salva primeiro → version=2 no banco
    var aMutated = a
    try aMutated.updateSocialIdentity(typeId: …, actorId: "userA")
    try await repo.save(aMutated)

    // B tenta salvar com version=1 (já obsoleto)
    var bMutated = b
    try bMutated.updateSocialIdentity(typeId: …, actorId: "userB")

    await #expect(throws: PersistenceConflictError.self) {
        try await repo.save(bMutated)  // DEVE falhar com optimistic lock
    }
}
```

### W1 — GREEN

Domínio (`Patient.swift`):

```swift
// Adicionar: cada mutating func incrementa version (ou centralizar em recordEvent)
public mutating func addEvent(_ event: any DomainEvent) {
    self.uncommittedEvents.append(event)
    self.version += 1
}
```

Repositório (`SQLKitPatientRepository.swift`):

```swift
// Substituir UPSERT por UPDATE condicional
try await tx.raw("""
    UPDATE patients SET ..., version = \(bind: patient.version)
    WHERE id = \(bind: patient.id) AND version = \(bind: patient.version - 1)
""").run()

guard rowsAffected == 1 else {
    throw PersistenceConflictError.optimisticLockFailed(
        expectedVersion: patient.version - 1,
        actualVersion: try await currentVersion(of: patient.id)
    )
}
```

Adicionar a `shared/Error/PersistenceConflictError.swift`:

```swift
case optimisticLockFailed(expectedVersion: Int, actualVersion: Int)
```

Mapper em RegisterPatient/Update*Handlers traduz para erro de negócio:
- `PatientHasBeenModifiedConcurrently` → HTTP 409 com hint "re-fetch and retry".

### W2 — REVIEW

- [ ] **Caminho de CREATE** (primeiro save, version=0→1) testado separadamente
- [ ] Concurrent test passa em CI com paralelismo
- [ ] `INSERT` ainda é UPSERT (caminho create); `UPDATE` é condicional (caminho update)

### W3 — QUALITY

- Benchmark: latência média de `save()` ≤ 5% pior que antes (em principle, é só uma `WHERE` extra)
- Coverage do `OptimisticLockTest`: 100%

### ADR

**ADR-006 — Optimistic locking enforçado via coluna `version`**

### Better Pattern

`swift-io-implementer.skill.md`:

```markdown
## Padrão Optimistic Lock em Repository

TODO repository SQLKit que faça update de aggregate root DEVE:
1. Incluir `WHERE id = ? AND version = ?` no UPDATE
2. Checar `rowsAffected == 1`; senão lançar `PersistenceConflictError.optimisticLockFailed`
3. NUNCA usar `INSERT ... ON CONFLICT DO UPDATE` para o caminho de UPDATE
   (UPSERT só vale na criação; updates exigem versão checada)
```

---

## T-006 — Adicionar PK em `family_members` e `patient_diagnoses`

| Campo | Valor |
|---|---|
| Achados | DB-1 |
| Dependências | T-001, T-005 (não conflita com optimistic lock — mexe em filhas) |
| Skill rota | `swift-io-implementer` (Persistence — migration) |

### W0 — RED

`Tests/.../Regression/DataIntegrity/AggregateTableHasPKTest.swift`:

```swift
@Test
func test_DB_1_family_members_rejects_duplicate_patient_person() async throws {
    let patientId = UUID()
    let personId = UUID()
    try await db.insert(into: "family_members").columns(...).values(patientId, personId, ...).run()

    // Antes da fix: aceita silenciosamente. Depois: PK composta bloqueia.
    await #expect(throws: PersistenceConflictError.uniqueViolation.self) {
        try await db.insert(into: "family_members").columns(...).values(patientId, personId, ...).run()
    }
}

@Test
func test_DB_1_patient_diagnoses_has_stable_identity() async throws {
    // Mesmo paciente + mesmo CID + mesma data → 1 linha apenas
}
```

### W1 — GREEN

Migration nova `2026_05_NN_AddPrimaryKeys.swift`:

```sql
-- forward
ALTER TABLE family_members ADD PRIMARY KEY (patient_id, person_id);
ALTER TABLE patient_diagnoses ADD COLUMN id UUID NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE patient_diagnoses ADD PRIMARY KEY (id);
ALTER TABLE patient_diagnoses ADD CONSTRAINT uq_patient_diagnosis UNIQUE (patient_id, icd_code, date);

-- rollback
ALTER TABLE family_members DROP CONSTRAINT family_members_pkey;
ALTER TABLE patient_diagnoses DROP CONSTRAINT patient_diagnoses_pkey;
ALTER TABLE patient_diagnoses DROP COLUMN id;
ALTER TABLE patient_diagnoses DROP CONSTRAINT uq_patient_diagnosis;
```

Pré-validar dados existentes (script no PR):
- Detectar duplicatas `(patient_id, person_id)` em `family_members`
- Detectar duplicatas `(patient_id, icd_code, date)` em `patient_diagnoses`
- Plano de cleanup com aprovação manual

### W2 — REVIEW

- [ ] Forward + rollback testados em DB de dev limpo
- [ ] Pré-flight check rodado em snapshot do banco staging
- [ ] FK composta `(patient_id, person_id) → family_members` viável para T-007

### W3 — QUALITY

- `make ci` verde
- Validação de schema gerada (ver T-033 — schema snapshot test)

### ADR

**ADR-007 — Toda tabela é uma relação com PK declarada**
- Contexto: 2 tabelas modeladas como multi-set sem PK; SQL aceita mas modelo relacional não
- Decisão: PK composta natural quando há identidade lógica; surrogate UUID quando outras tabelas precisarem referenciar
- Citação: Ramakrishnan & Gehrke, "Each row in a relation represents a unique tuple"

### Better Pattern

`swift-io-implementer.skill.md`:

```markdown
## Padrão Migration: PK Obrigatória

TODA migration que cria tabela DEVE declarar PK (natural ou surrogate). Sem PK,
a tabela não é uma relação — apenas um multi-set permissivo. Lista de checks:
- [ ] PK declarada
- [ ] FK para qualquer coluna `*_id` que aponta para outra tabela do mesmo BC
- [ ] UNIQUE para invariantes de negócio que não são PK (ex: CPF unique parcial)
- [ ] Forward + rollback testados em fixture vazia
```

---

## T-007 — Tipar `family_members.relationship` como UUID + FK

| Campo | Valor |
|---|---|
| Achados | DB-4 + S-H-D5 (Primitive obsession em LookupId) |
| Dependências | T-006 (PK precisa existir antes de FK composta) |
| Skill rota | `swift-io-implementer` (Persistence) + `swift-domain-modeler` (VO já existe) |

### W0 — RED

`Tests/.../Regression/DataIntegrity/RelationshipIdIsTypedTest.swift`:

```swift
@Test
func test_DB_4_relationship_id_rejects_non_uuid() async throws {
    await #expect(throws: PersistenceConflictError.self) {
        try await db.raw("INSERT INTO family_members (..., relationship_id) VALUES (..., 'foo')").run()
    }
}

@Test
func test_DB_4_relationship_id_rejects_orphan_lookup_id() async throws {
    let randomLookupId = UUID() // não existe em dominio_parentesco
    await #expect(throws: PersistenceConflictError.self) {
        try await db.raw("INSERT INTO family_members (..., relationship_id) VALUES (..., \(bind: randomLookupId))").run()
    }
}
```

### W1 — GREEN

Migration `2026_05_NN_TypeRelationshipAsUUID.swift` (expand-contract):

1. Add `relationship_id UUID NULL` em `family_members`
2. Backfill: `UPDATE family_members SET relationship_id = relationship::UUID WHERE relationship ~ '^[0-9a-f]{8}-...'`
3. Tratar linhas com `relationship` não-UUID (provavelmente zero, mas script vai listar)
4. `ALTER TABLE family_members ALTER COLUMN relationship_id SET NOT NULL`
5. `ADD CONSTRAINT fk_family_member_relationship FOREIGN KEY (relationship_id) REFERENCES dominio_parentesco(id) ON DELETE RESTRICT`
6. Drop `relationship` antiga

Mapper:

```swift
// Antes: try LookupId(m.relationship)
// Depois: LookupId(uuid: m.relationship_id)  -- não-throws
```

### W2 — REVIEW

- [ ] Domínio `FamilyMember.relationshipId: LookupId` permanece igual (boa abstração)
- [ ] Mapper não usa mais `LookupId(_:) throws` — usa init não-throwing por UUID
- [ ] `RegressionFixture` atualizada

### ADR

**ADR-008 — Colunas que carregam identidade semântica usam tipo nativo + FK**
- Contexto: `relationship: TEXT` aceitava qualquer string, inclusive UUID inválido
- Decisão: toda coluna que conceitualmente é FK vira tipo nativo + FK declarada

### Better Pattern

`swift-io-implementer.skill.md`:

```markdown
## Anti-pattern: UUID/Lookup como TEXT

NUNCA declarar coluna como `TEXT` quando o valor é UUID/Identifier. Sempre:
- UUID nativo (`uuid_generate_v4()` ou bind explícito)
- FK declarada para a tabela alvo
- ON DELETE RESTRICT (lookup table) ou CASCADE (filha de aggregate)
```

---

## T-008 — Declarar FKs ausentes para `dominio_*`

| Campo | Valor |
|---|---|
| Achados | DB-3 (lista de 7 colunas) |
| Dependências | T-006 |
| Skill rota | `swift-io-implementer` |

### W0 — RED

`Tests/.../Regression/DataIntegrity/LookupFKsTest.swift` — um teste por coluna:

```swift
@Test
func test_DB_3_member_incomes_occupation_id_rejects_orphan() async throws {
    let orphan = UUID()
    await #expect(throws: PersistenceConflictError.self) {
        try await db.raw("INSERT INTO member_incomes (..., occupation_id) VALUES (..., \(bind: orphan))").run()
    }
}
// + 6 outros testes análogos para cada coluna da DB-3
```

### W1 — GREEN

Migration `2026_05_NN_DeclareLookupFKs.swift` adicionando 7 FKs:

```sql
ALTER TABLE patients
  ADD FOREIGN KEY (social_identity_type_id) REFERENCES dominio_tipo_identidade(id) ON DELETE RESTRICT,
  ADD FOREIGN KEY (ii_ingress_type_id) REFERENCES dominio_tipo_ingresso(id) ON DELETE RESTRICT;
ALTER TABLE member_incomes ADD FOREIGN KEY (occupation_id) REFERENCES dominio_condicao_ocupacao(id) ON DELETE RESTRICT;
-- ... 4 outros
```

Pré-flight: detectar registros órfãos antes da migration.

### W2 — REVIEW

- [ ] Política `ON DELETE RESTRICT` é universal para lookup tables (nunca CASCADE/SET NULL)
- [ ] Tickets de "soft-delete em lookup" (futuro) precisam considerar essa FK

### ADR

**ADR-009 — Integridade referencial declarada no schema para FK de lookups**
- Citação: Ramakrishnan & Gehrke (Cap. 3.3): "All foreign key constraints must be declared in the schema."
- Convive com validação semântica na Application (que continua para mensagens de erro bonitas + Metadata-Driven)

### Better Pattern

Em `swift-io-implementer.skill.md`, complementar T-006:

```markdown
## Política universal de FK

| Tipo de relação | Política |
|---|---|
| Coluna FK aponta para lookup table (dominio_*) | ON DELETE RESTRICT (nunca CASCADE) |
| Coluna FK aponta para aggregate root parent | ON DELETE CASCADE (filhas do agregado) |
| Coluna FK cross-service (person_id, professional_id) | NÃO declarar FK — documentar como cross-service |
```

---

## T-009 — VO `Money` substituindo `Double` em valores financeiros

| Campo | Valor |
|---|---|
| Achados | DB-8 |
| Dependências | T-001 |
| Skill rota | `swift-domain-modeler` (VO) + `swift-io-implementer` (Mapper) |

### W0 — RED

`Tests/.../Regression/DomainInvariants/MoneyIsExactTest.swift`:

```swift
@Test
func test_DB_8_summing_decimals_is_exact() {
    let amounts = (1...100).map { _ in Money(centavos: 10, currency: "BRL") }
    let total = amounts.reduce(Money.zero, +)
    #expect(total == Money(centavos: 1000, currency: "BRL"))  // exato; Double daria 9.999...
}

@Test
func test_DB_8_round_trip_database_preserves_precision() async throws {
    let original = Money(centavos: 60000, currency: "BRL")  // R$ 600,00
    try await repo.save(...) // grava
    let reloaded = try await repo.find(...)
    #expect(reloaded.amount == original)
}
```

### W1 — GREEN

`Domain/Kernel/Money/Money.swift`:

```swift
public struct Money: Sendable, Hashable, Codable {
    public let centavos: Int64
    public let currency: String  // ISO 4217, ex "BRL"

    public init(centavos: Int64, currency: String = "BRL") throws {
        guard ISO4217.contains(currency) else { throw MoneyError.invalidCurrency(currency) }
        self.centavos = centavos
        self.currency = currency
    }

    public static let zero = try! Money(centavos: 0)

    public static func + (lhs: Money, rhs: Money) throws -> Money {
        guard lhs.currency == rhs.currency else { throw MoneyError.currencyMismatch(...) }
        return try Money(centavos: lhs.centavos + rhs.centavos, currency: lhs.currency)
    }
}
```

Refactor:
- `SocialBenefit.amount: Money`
- `MemberIncome.monthlyAmount: Money`
- `SocioEconomicSituation.totalFamilyIncome: Money`, `incomePerCapita: Money`
- `FinancialAnalyticsService` atualizado
- Mapper bind `Money` → `NUMERIC(12,2)` (via `.centavos / 100`)

### W2 — REVIEW

- [ ] Zero `Double` em domínio para campo monetário
- [ ] `FinancialAnalyticsService.compute(for: patient)` retorna `Money`
- [ ] Mapper round-trip preserva precisão (teste de integração)

### ADR

**ADR-010 — `Money` VO substitui `Double` em todo valor monetário**

### Better Pattern

`swift-domain-modeler.skill.md`:

```markdown
## Anti-pattern: Dinheiro como `Double`/`Float`

JAMAIS modelar valor financeiro como `Double`. IEEE 754 não é fechado em soma de
decimais (`0.1 + 0.2 != 0.3`). Sempre usar VO `Money(centavos: Int64, currency:
String)`. Aritmética sempre via operadores tipados que checam currency match.
```

---

# FASE 2 — Segurança crítica e Error Mapping

Objetivo: fechar as portas que comprometem produção. PeopleContext fail-open, Outbox duplica, ErrorMapping inconsistente, headers ausentes.

---

## T-010 — Helper `mapUniqueViolation` + retrofit em 21 handlers

| Campo | Valor |
|---|---|
| Achados | S-C6 (apenas 1/21 handlers mapeia) |
| Dependências | T-001 |
| Skill rota | `swift-application-orchestrator` |

### W0 — RED

`Tests/.../Regression/ErrorMapping/UniqueViolationMappingTest.swift` — um teste por handler que tem unique constraint envolvido (~10):

```swift
@Test
func test_S_C6_AddFamilyMember_maps_duplicate_member_to_business_error() async throws {
    let cmd = AddFamilyMemberCommand(...)
    try await handler.handle(cmd)  // 1ª vez OK

    await #expect(throws: AddFamilyMemberError.memberAlreadyInFamily.self) {
        try await handler.handle(cmd)  // 2ª deve mapear PersistenceConflictError → erro de negócio
    }
}
```

### W1 — GREEN

`shared/Error/PersistenceConflictMapping.swift`:

```swift
public extension PersistenceConflictError {
    func mapUniqueViolation<E: Error>(_ mapping: (String) -> E?) -> E? {
        guard case .uniqueViolation(let constraint, _) = self else { return nil }
        return mapping(constraint)
    }
}
```

Retrofit cada `*MapperError.swift`:

```swift
func mapError(_ error: Error, …) -> AddFamilyMemberError {
    if let conflict = error as? PersistenceConflictError,
       let mapped = conflict.mapUniqueViolation({ constraint in
           switch constraint {
           case "uq_family_member_per_patient": return .memberAlreadyInFamily(...)
           default: return nil
           }
       }) { return mapped }
    // ... resto do mapping
}
```

### W2 — REVIEW

- [ ] Lint test em `Tests/.../Regression/ErrorMapping/AllHandlersMapConflictTest.swift` percorre todos os `*MapperError.swift` via reflection e falha se algum não chama `mapUniqueViolation`
- [ ] Cada handler mapeado tem entrada no `Regression/ErrorMapping/`

### ADR

**ADR-011 — Política universal de mapeamento `PersistenceConflictError`**

### Better Pattern

`swift-application-orchestrator.skill.md`:

```markdown
## Padrão: mapError com PersistenceConflictError obrigatório

Todo `*MapperError.swift` que serve handler com `repository.save` DEVE:
1. Chamar `error.mapUniqueViolation { … }` no início do mapError
2. Mapear cada constraint relevante para erro de negócio HTTP 409
3. Fallback para `persistenceMappingFailure` apenas se nenhum constraint conhecido bater

Se o handler não chama, o lint test no Regression/ErrorMapping falha.
```

---

## T-011 — PeopleContext tri-state + Bearer forwarding (ADR-023)

| Campo | Valor |
|---|---|
| Achados | S-C1 |
| Dependências | T-001 |
| Skill rota | `swift-io-implementer` (HTTP client outbound) |

### W0 — RED

`Tests/.../Regression/Security/PeopleContextNoFailOpenTest.swift`:

```swift
@Test
func test_S_C1_PeopleContextUnavailable_blocks_registration() async throws {
    let validator = PeopleContextPersonValidator(baseURL: "http://unreachable:9999", ...)

    // Antes: retornava .exists silenciosamente. Depois: .unknown(reason:).
    let result = await validator.validate(personId: PersonId(...), bearer: "valid.jwt")
    if case .unknown = result { } else { Issue.record("Should be .unknown when upstream is down") }
}

@Test
func test_S_C1_PeopleContextSends_Bearer_token() async throws {
    let captured = CapturingHTTPMock()
    let validator = PeopleContextPersonValidator(httpClient: captured)

    _ = await validator.validate(personId: PersonId(...), bearer: "user.jwt.xyz")

    #expect(captured.lastRequest?.headers.first(name: "Authorization") == "Bearer user.jwt.xyz")
}
```

### W1 — GREEN

`IO/PeopleContext/PeopleContextPersonValidator.swift`:

```swift
public enum PersonExistence: Sendable {
    case exists
    case notFound
    case unknown(reason: String)
}

public actor PeopleContextPersonValidator: PersonExistenceValidating {
    public func validate(personId: PersonId, bearer: String) async -> PersonExistence {
        guard var components = URLComponents(string: baseURL) else {
            return .unknown(reason: "invalid_base_url")
        }
        components.path += "/api/v1/people/\(personId.description)"
        guard let url = components.url else { return .unknown(reason: "url_build_failed") }

        var req = HTTPClientRequest(url: url.absoluteString)
        req.method = .GET
        req.headers.add(name: "Authorization", value: "Bearer \(bearer)")

        do {
            let res = try await client.execute(req, timeout: .seconds(5))
            switch res.status {
            case .ok: return .exists
            case .notFound: return .notFound
            default: return .unknown(reason: "http_\(res.status.code)")
            }
        } catch {
            return .unknown(reason: "transport_\(type(of: error))")
        }
    }
}
```

`RegisterPatientCommandHandler`:

```swift
switch await validator.validate(personId: cmd.personId, bearer: cmd.bearer) {
case .exists: break
case .notFound: throw .personDoesNotExistInPeopleContext
case .unknown(let reason): throw .personValidationUnavailable(reason)  // HTTP 503
}
```

### W2 — REVIEW

- [ ] Adapter HTTP recebe `bearer: String` por DI (não pega de singleton)
- [ ] Validador é `actor` com `@Sendable` httpClient

### ADR

**ADR-012 — PeopleContext fail-secure tri-state com Bearer forwarding obrigatório**
- Citação ADR-023 frontend (já existente) reforça política cross-stack

### Better Pattern

`swift-io-implementer.skill.md`:

```markdown
## Anti-pattern: fail-open em adapter outbound

Adapter de Anti-Corruption Layer NUNCA retorna "true/exists/ok" como fallback
para falha de upstream. Sempre tri-state explícito: `case .ok | .notFound |
.unknown(reason:)`. `.unknown` é traduzido para erro de domínio que BLOQUEIA
a operação (HTTP 503). Bearer forwarding obrigatório em todas as chamadas
outbound (ADR-023).
```

---

## T-012 — Outbox `FOR UPDATE SKIP LOCKED` + Nats-Msg-Id

| Campo | Valor |
|---|---|
| Achados | S-C2 |
| Dependências | T-001 |
| Skill rota | `swift-io-implementer` (Outbox relay) |

### W0 — RED

`Tests/.../Regression/EventPublication/OutboxNoDuplicationTest.swift`:

```swift
@Test
func test_S_C2_two_relay_workers_dont_pick_same_message() async throws {
    // Arrange: 100 mensagens não-processadas
    try await seed(100Messages)
    let relay1 = SQLKitOutboxRelay(db: db, ..., id: "relay1")
    let relay2 = SQLKitOutboxRelay(db: db, ..., id: "relay2")

    // Act: ambos rodam um ciclo de poll simultaneamente
    async let a = relay1.pollAndDistribute()
    async let b = relay2.pollAndDistribute()
    _ = await (a, b)

    // Assert: cada mensagem foi publicada exatamente 1x para o NATS mock
    let publishedIds = natsMock.publishedMessages.map(\.id)
    #expect(Set(publishedIds).count == publishedIds.count)  // sem duplicata
}
```

### W1 — GREEN

`SQLKitOutboxRelay.swift`:

```swift
// Substituir o SELECT por:
let rows = try await db.transaction { tx in
    try await tx.raw("""
        SELECT id, event_type, payload, occurred_at
        FROM outbox_messages
        WHERE processed_at IS NULL
        ORDER BY occurred_at ASC
        FOR UPDATE SKIP LOCKED
        LIMIT \(bind: batchSize)
    """).all()
}

// Ao publicar no NATS, passar header de dedup:
try await nats.publish(
    subject: subject,
    payload: payload,
    headers: ["Nats-Msg-Id": row.id.uuidString]
)
```

### W2 — REVIEW

- [ ] SELECT roda dentro de transação curta (apenas para o lock)
- [ ] `Nats-Msg-Id` propagado em 100% dos publishes
- [ ] JetStream config do NATS habilita dedup window (verificar com infra)

### ADR

**ADR-013 — Outbox at-least-once com dedup via Nats-Msg-Id; concorrência via FOR UPDATE SKIP LOCKED**

### Better Pattern

`swift-io-implementer.skill.md`:

```markdown
## Padrão Outbox Relay multi-instância

Qualquer relay que rode em múltiplas réplicas SEMPRE usa
`SELECT … FOR UPDATE SKIP LOCKED LIMIT N` dentro de transação. Sem isso, dois
pods leem o mesmo lote → duplicação garantida. Sempre propagar
`Nats-Msg-Id` (ou equivalente do broker) para que downstream possa deduplicar.
```

---

## T-013 — Remover `OutboxEventBus.publish` dos handlers (Opção A do ADR)

| Campo | Valor |
|---|---|
| Achados | S-C4 |
| Dependências | T-004 (eventos confiáveis via protocolo composto) |
| Skill rota | `swift-application-orchestrator` |

### W0 — RED

`Tests/.../Regression/EventPublication/RepositoryPersistsEventsWithAggregateTest.swift`:

```swift
@Test
func test_S_C4_save_persists_events_in_same_transaction() async throws {
    var patient = try PatientFixture.registered()
    patient.recordEvent(PatientRegisteredEvent.fixture)
    try await repo.save(patient)

    let outboxCount = try await db.raw("SELECT COUNT(*) FROM outbox_messages WHERE aggregate_id = \(bind: patient.id)").first().decode(...)
    #expect(outboxCount == 1)
}

@Test
func test_S_C4_save_failure_rolls_back_events() async throws {
    // Forçar UPDATE a falhar (violar invariante) → outbox_messages NÃO contém o evento
}
```

### W1 — GREEN

Remover `try await eventBus.publish(patient.uncommittedEvents)` de todos os 21 handlers. Atualizar interface do `PatientRepository`:

```swift
public protocol PatientRepository: Sendable {
    /// Persists aggregate and uncommittedEvents in the same transaction.
    /// Returns aggregate with cleared events.
    func save(_ patient: Patient) async throws -> Patient
}
```

Deletar `IO/EventBus/OutboxEventBus.swift` (dead code). EventBus port de Application removido.

### W2 — REVIEW

- [ ] Nenhum handler chama `eventBus.publish` mais
- [ ] `PatientRepository` documentado: "saves aggregate AND events atomically"
- [ ] Testes existentes que esperavam `eventBus.publish` corrigidos

### ADR

**ADR-014 — Outbox Pattern: persistência atômica de eventos via repository (não via EventBus)**

### Better Pattern

`swift-application-orchestrator.skill.md`:

```markdown
## Anti-pattern: eventBus.publish no handler

Não chamar `eventBus.publish` no handler é o caminho correto QUANDO o
repository implementa Transactional Outbox (events na mesma transação do
aggregate). Sintoma do bug oposto: `eventBus.publish` é dead code que
mascara o vínculo implícito repository ↔ outbox. ADR-014 fixou: repository
é a porta única de persistência de eventos.
```

---

## T-014 — Security headers + body size limit

| Campo | Valor |
|---|---|
| Achados | S-C5 |
| Dependências | T-001 |
| Skill rota | `swift-io-implementer` (Middleware) |

### W0 — RED

`Tests/.../Regression/Security/SecurityHeadersTest.swift`:

```swift
@Test
func test_S_C5_response_includes_security_headers() async throws {
    let res = try await app.test(.GET, "/health")
    #expect(res.headers.first(name: "Strict-Transport-Security") != nil)
    #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
    #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
    #expect(res.headers.first(name: "Referrer-Policy") == "no-referrer")
}

@Test
func test_S_C5_oversized_body_is_rejected() async throws {
    let huge = String(repeating: "x", count: 300_000) // 300KB > 256KB
    let res = try await app.test(.POST, "/api/v1/patients", body: huge)
    #expect(res.status == .payloadTooLarge)
}
```

### W1 — GREEN

`IO/HTTP/Middleware/SecurityHeadersMiddleware.swift`:

```swift
public struct SecurityHeadersMiddleware: AsyncMiddleware {
    public func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let res = try await next.respond(to: req)
        res.headers.replaceOrAdd(name: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains; preload")
        res.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        res.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        res.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        if req.url.path.hasPrefix("/api/") {
            res.headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        }
        return res
    }
}
```

`configure.swift`:

```swift
app.middleware.use(SecurityHeadersMiddleware())  // PRIMEIRO da chain
app.routes.defaultMaxBodySize = "256kb"
```

### ADR

**ADR-015 — Security headers obrigatórios e body size limit no boot**

### Better Pattern

`swift-io-implementer.skill.md`:

```markdown
## Padrão Boot Security

Todo `configure.swift` DEVE no boot:
1. `SecurityHeadersMiddleware` como PRIMEIRO middleware
2. `app.routes.defaultMaxBodySize` configurado (default Vapor é permissivo demais para JSON)
3. CORS explícito (allowlist) OU comentário documentando "BFF same-origin only"
4. Rate-limit middleware (próximo sprint — ADR separado)
```

---

# FASE 3 — Outbox & Eventos (continuação)

---

## T-015 — `audit_trail.id` distinto de `outbox_messages.id`

| Campo | Valor |
|---|---|
| Achados | S-C10 |
| Dependências | T-012 |
| Skill rota | `swift-io-implementer` (Persistence) |

### W0 — RED

`Tests/.../Regression/EventPublication/AuditTrailDeduplicatesTest.swift`:

```swift
@Test
func test_S_C10_relay_handles_reprocess_without_killing_batch() async throws {
    // Seed: 1 message já tem audit_trail entry com mesmo message.id
    // Antes: SELECT pega 50 mensagens, INSERT em audit_trail aborta toda transação → loop infinito
    // Depois: audit_trail.id é UUID gen_random, conflict impossível
    try await relay.pollAndDistribute()
    // outras 49 mensagens são processadas
}
```

### W1 — GREEN

Migration `2026_05_NN_AuditTrailOwnId.swift`:

```sql
-- audit_trail.id já é UUID PK, mas atualmente o relay seta = message.id.
-- Mudar: deixar gerar default + adicionar coluna outbox_message_id para rastreio
ALTER TABLE audit_trail ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE audit_trail ADD COLUMN outbox_message_id UUID NOT NULL;
CREATE INDEX idx_audit_outbox_msg ON audit_trail (outbox_message_id);
```

Relay:

```swift
let entry = AuditTrailEntry(
    id: UUID(),  // NEW
    outbox_message_id: message.id,  // rastreio
    aggregate_type: message.aggregateType,
    ...
)
```

### ADR

**ADR-016 — Identidades distintas para outbox messages e audit trail entries**

### Better Pattern

`swift-io-implementer.skill.md`:

```markdown
## Anti-pattern: reuso de PK entre tabelas distintas

Reusar PK entre tabelas (audit_trail.id = outbox_message.id) cria classe de
bugs onde re-processamento aborta batch. Cada tabela tem identidade própria;
se rastreio cruzado é necessário, usar coluna FK separada.
```

---

## T-016 — `DomainEvent` expõe `aggregateType` / `aggregateId` (não hardcoded)

| Campo | Valor |
|---|---|
| Achados | S-M-P10 + S-H-IO4 (relacionados) |
| Dependências | T-004 |
| Skill rota | `swift-domain-modeler` |

### W0 — RED

`Tests/.../Regression/EventPublication/EventCarriesAggregateMetadataTest.swift`:

```swift
@Test
func test_M_P10_event_exposes_aggregate_type() {
    let event = PatientRegisteredEvent(...)
    #expect(event.aggregateType == "Patient")
    #expect(event.aggregateId == event.patientId.uuidValue)
}

@Test
func test_H_IO4_audit_endpoint_filters_by_aggregate_type() async throws {
    // Mesma UUID em outro agregado (Care.SocialCareAppointment) não vaza
}
```

### W1 — GREEN

`shared/Domain/DomainProtocols.swift`:

```swift
public protocol DomainEvent: Sendable {
    var id: UUID { get }
    var occurredAt: TimeStamp { get }
    var aggregateType: String { get }  // NEW
    var aggregateId: UUID { get }       // NEW
}
```

Cada evento existente passa a implementar. Relay e audit endpoint usam direto sem parse de JSON.

### ADR

**ADR-017 — DomainEvent carrega metadata de agregado por contrato**

---

## T-017 — `NATSEventPublisher` substitui half-duplex por cliente correto

| Campo | Valor |
|---|---|
| Achados | S-C9 |
| Dependências | T-012 |
| Skill rota | `swift-io-implementer` (EventBus) |

### W0 — RED

`Tests/.../Regression/EventPublication/NATSPublisherSurvivesPingTest.swift`:

```swift
@Test
func test_S_C9_publisher_responds_to_server_ping() async throws {
    // Mock NATS server envia PING após 2min
    // Antes: connection cai silenciosa
    // Depois: publisher responde PONG → conexão estável após 5min
}
```

### W1 — GREEN

Substituir implementação custom por:
- (a) `nats.swift` oficial (https://github.com/nats-io/nats.swift), OU
- (b) instalar `ChannelInboundHandler` que responde PING/PONG

### ADR

**ADR-018 — Cliente NATS oficial (ou handler bidirecional) substitui implementação custom half-duplex**

### Better Pattern

`swift-io-implementer.skill.md`:

```markdown
## Anti-pattern: implementação custom de protocolo de mensageria

Implementar NATS/RabbitMQ/Kafka client à mão = bug factory. Sempre usar
biblioteca oficial. Se inviável, no MÍNIMO testar contra protocolo formal
(PING/PONG, +ERR, +OK) com mock server real, não mock alocador-de-buffer.
```

---

## T-018 — Sanitização de log no relay (LGPD)

| Campo | Valor |
|---|---|
| Achados | S-H-P6 |
| Dependências | T-001 |
| Skill rota | `swift-io-implementer` |

### W0 — RED

`Tests/.../Regression/Security/NoPiiInLogTest.swift`:

```swift
@Test
func test_H_P6_relay_failure_does_not_log_payload() {
    let captured = CapturingLogger()
    // Forçar falha de processamento com payload contendo CPF "123.456.789-00"
    relay.handleFailure(error: DecodingError.x, payload: payloadWithCPF, logger: captured)

    #expect(!captured.contains("123.456.789-00"))
    #expect(captured.contains("error_type:DecodingError"))  // tipo, sim
}
```

### W1 — GREEN

`SQLKitOutboxRelay.swift:141-145`:

```swift
// Antes: "error": "\(error)"  ← vaza payload no DecodingError
// Depois:
logger.warning("Failed to process outbox event", metadata: [
    "eventId": "\(message.id)",
    "eventType": .string(message.event_type),
    "errorType": .string(String(reflecting: type(of: error))),
    "errorMessage": .string(error.localizedDescription)
    // NÃO logar "\(error)" bruto
])
```

### ADR

**ADR-019 — Política universal: log de erro não inclui payload em camadas com PII**

### Better Pattern

`swift-io-implementer.skill.md`:

```markdown
## Anti-pattern: `"\(error)"` em log de camada com PII

Em qualquer camada que processa dados pessoais (LGPD scope), NUNCA logar
`"\(error)"` bruto. `DecodingError`, `PSQLError.serverInfo` etc. incluem
o payload no `description`. Logar `String(reflecting: type(of: error))` +
`error.localizedDescription` máximo. AppError tem `safeContext` justamente
pra isso — usar.
```

---

## T-019 — `AnyJSON`/`AnySendable` → enum fechado Sendable

| Campo | Valor |
|---|---|
| Achados | S-H-IO6 + S-M-P2 |
| Dependências | T-001 |
| Skill rota | `swift-application-orchestrator` (shared) + `swift-io-implementer` (DTOs) |

### W0 — RED

`Tests/.../Regression/Concurrency/SendableJSONTest.swift`:

```swift
@Test
func test_H_IO6_AnyJSON_is_truly_sendable() async {
    let json: AnyJSON = .object(["cpf": .string("..."), "amount": .number(100)])
    // Compilation only: tem que ser Sendable sem @unchecked
    Task { await use(json) }
}
```

### W1 — GREEN

`shared/Error/AppError.swift` + `IO/HTTP/DTOs/ResponseDTOs.swift`:

```swift
public enum AnyJSON: Sendable, Codable, Hashable {
    case object([String: AnyJSON])
    case array([AnyJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}
```

Substituir `AnySendable: @unchecked Sendable` por enum análogo para `AppError.context`.

### ADR

**ADR-020 — Banimento de `@unchecked Sendable` em estruturas de fronteira**

### Better Pattern

`swift-domain-modeler.skill.md` + `swift-io-implementer.skill.md`:

```markdown
## Anti-pattern: `@unchecked Sendable` + `Any`

Qualquer struct/class na fronteira (DTO, Error, Event payload) que precise ser
Sendable + carregue valor heterogêneo DEVE ser modelada com enum fechado, NUNCA
`@unchecked Sendable` armazenando `Any`. Strict concurrency Swift 6 não pega
data race em `Any` interno — bug volta no momento mais inconveniente.
```

---

# FASE 4 — Quebrar o god aggregate `Patient`

Objetivo: aliviar `Patient` carregando 4 BCs colapsados (Registry+Care+Protection+Assessment). Decomposição faz schema (DB-7) e domain (S-H-D1) ficarem alinhados.

> ⚠️ Esta fase é **a mais arriscada**. Cada ticket é uma decomposição de módulo opcional em agregado próprio. Recomenda-se ADR-única (ADR-021) antes do primeiro ticket, com seção "Plano de adoção" detalhado por sprint.

---

## T-020 — `required_documents` vira tabela filha (1NF)

| Campo | Valor |
|---|---|
| Achados | S-H-A7 + DB-5 |
| Dependências | T-006 |
| Skill rota | `swift-io-implementer` (Persistence) + `swift-application-orchestrator` (handler) |

### W0 — RED

`Tests/.../Regression/DataIntegrity/RequiredDocumentsAtomicityTest.swift`:

```swift
@Test
func test_S_H_A7_invalid_required_document_is_rejected_loudly() async throws {
    let cmd = AddFamilyMemberCommand(..., requiredDocuments: ["RG", "TYPO_INVALID", "CPF"])
    await #expect(throws: AddFamilyMemberError.invalidRequiredDocument("TYPO_INVALID").self) {
        try await handler.handle(cmd)
    }
}
```

### W1 — GREEN

- Migration: `family_member_required_documents(patient_id, person_id, document_type)` com PK composta + FK para `family_members`
- Handler: `try map { … }` (não `compactMap`) lança erro tipado em valor inválido

### ADR

**ADR-021 — Decomposição estrutural do agregado `Patient`** (mãe — referencia tickets T-020..T-024)

---

## T-021 — Delete-and-insert → diff-based upsert em child tables

| Campo | Valor |
|---|---|
| Achados | S-H-P1 + DB-6 |
| Dependências | T-006 (todas as filhas têm PK estável) |
| Skill rota | `swift-io-implementer` (Mapper + Repository) |

### W0 — RED

`Tests/.../Regression/DomainInvariants/ChildIdentityPreservedTest.swift`:

```swift
@Test
func test_S_H_P1_DB_6_family_member_id_persists_across_saves() async throws {
    var patient = try PatientFixture.withFamily(1)
    try await repo.save(patient)
    let originalMemberId = patient.familyMembers[0].id

    patient.familyMembers[0].update(...)  // qualquer mutação
    try await repo.save(patient)

    let reloaded = try await repo.find(byId: patient.id)
    #expect(reloaded.familyMembers[0].id == originalMemberId)
    // Antes: id mudava a cada save (UUID novo no mapper)
}
```

### W1 — GREEN

Refactor `SQLKitPatientRepository.deleteAndInsert` para `diff + upsert + delete-removed`:

```swift
private func upsertChildren<T>(...) async throws {
    let existingIds = try await tx.select().column("id").from(table).where("patient_id", .equal, patientId).all()
    let desiredIds = models.map(\.id)
    let toRemove = Set(existingIds).subtracting(desiredIds)

    if !toRemove.isEmpty {
        try await tx.delete(from: table).where("id", .in, toRemove).run()
    }
    for model in models {
        try await tx.raw("INSERT INTO \(ident: table) ... ON CONFLICT (id) DO UPDATE ...").run()
    }
}
```

Mapper: todas as entidades-filhas têm `id: UUID` estável (do domínio), não `UUID()` inline.

### ADR

**ADR-022 — Diff-based upsert preserva identidade de entidades-filhas**

### Better Pattern

`swift-io-implementer.skill.md`:

```markdown
## Anti-pattern: delete-and-insert em filhas com identidade

Apagar e re-inserir filhas a cada save destrói identidade física e audit trail.
Padrão correto: diff por PK + INSERT ... ON CONFLICT DO UPDATE + DELETE seletivo.
Custo: ~30 linhas a mais; ganho: identidade preservada, triggers ON UPDATE
funcionam, FKs externas viáveis.
```

---

## T-022 — JSONB revertido + timestamps unificados (TIMESTAMPTZ + DATE)

| Campo | Valor |
|---|---|
| Achados | S-H-P7 + DB-9 + DB-10 + DB-16 |
| Dependências | T-001 |
| Skill rota | `swift-io-implementer` |

### W0 — RED

`Tests/.../Regression/DataIntegrity/JSONBQueryableTest.swift`:

```swift
@Test
func test_DB_9_outbox_payload_is_jsonb_queryable() async throws {
    // SELECT WHERE payload->>'eventType' = 'X' funciona indexável
}

@Test
func test_DB_10_all_timestamps_are_TIMESTAMPTZ() async throws {
    // Inspect schema metadata: nenhuma coluna timestamp sem TZ em tabelas operacionais
}

@Test
func test_DB_16_birth_date_is_DATE_not_TIMESTAMP() async throws {
    // Inspect schema
}
```

### W1 — GREEN

Migration tripla:

```sql
-- Reverter JSONB
ALTER TABLE outbox_messages ALTER COLUMN payload TYPE JSONB USING payload::jsonb;
ALTER TABLE audit_trail    ALTER COLUMN payload TYPE JSONB USING payload::jsonb;
-- Bind no driver: usar SQLKit raw com cast explícito ::jsonb no INSERT

-- TIMESTAMPTZ universal em operacionais
ALTER TABLE social_care_appointments ALTER COLUMN date TYPE TIMESTAMPTZ USING date AT TIME ZONE 'America/Sao_Paulo';
-- ... (lista completa em ADR-023)

-- DATE em conceituais
ALTER TABLE patients          ALTER COLUMN birth_date     TYPE DATE USING birth_date::date;
ALTER TABLE patients          ALTER COLUMN rg_issue_date  TYPE DATE USING rg_issue_date::date;
ALTER TABLE family_members    ALTER COLUMN birth_date     TYPE DATE USING birth_date::date;
ALTER TABLE patient_diagnoses ALTER COLUMN date           TYPE DATE USING date::date;
```

Encoder/decoder JSON central: `shared/JSONCodec.default` com `dateEncodingStrategy = .iso8601`.

### ADR

**ADR-023 — Tipos temporais: TIMESTAMPTZ para operacionais, DATE para conceituais; JSONB para payloads opacos**

### Better Pattern

`swift-io-implementer.skill.md`:

```markdown
## Padrão Temporal & Payload

| Conceito | Tipo SQL | Swift |
|---|---|---|
| Instante operacional (timestamp evento) | `TIMESTAMPTZ` | `TimeStamp` |
| Data conceitual sem hora (nascimento, diagnóstico) | `DATE` | `BusinessDate` (criar VO) |
| Payload estruturado | `JSONB` | `Data` (bind via `::jsonb`) |
| Payload opaco/legado | NUNCA `TEXT` para JSON | — |

`JSONEncoder` SEMPRE com `dateEncodingStrategy = .iso8601`. Encoder default
serializa Date como Double — confusão garantida no audit trail.
```

---

## T-023 — `created_at` / `updated_at` em todas as tabelas raiz

| Campo | Valor |
|---|---|
| Achados | S-H-P5 + DB-17 |
| Dependências | T-006 |
| Skill rota | `swift-io-implementer` |

### W0 — RED

`Tests/.../Regression/DataIntegrity/TemporalAuditTest.swift`:

```swift
@Test
func test_DB_17_patient_has_created_and_updated_at() async throws {
    let patient = try PatientFixture.registered()
    try await repo.save(patient)
    let row = try await db.select().from("patients").where("id", .equal, patient.id).first()
    #expect(row?.decode(column: "created_at", as: Date.self) != nil)
    #expect(row?.decode(column: "updated_at", as: Date.self) != nil)
}
```

### W1 — GREEN

Migration adicionando colunas + trigger:

```sql
ALTER TABLE patients ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE patients ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER patients_updated_at BEFORE UPDATE ON patients
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
```

Aplicar em todas as tabelas raiz (não filhas).

### ADR

**ADR-024 — Auditoria operacional via `created_at`/`updated_at` automáticos**

---

## T-024 — Decompor módulos opcionais em sub-agregados (Assessment/Protection/Care)

| Campo | Valor |
|---|---|
| Achados | S-H-D1 + DB-7 |
| Dependências | T-005, T-006, T-008, T-020, T-021 |
| Skill rota | `swift-domain-modeler` + `swift-application-orchestrator` + `swift-io-implementer` |

> ⚠️ **Este é o ticket de mais alto risco**. Tocará dezenas de arquivos. Recomenda-se quebrá-lo em sub-tickets T-024.a (Assessment), T-024.b (Protection), T-024.c (Care) e que cada um vire um PR independente.

### W0 — RED

Suite extenso em `Tests/.../Regression/DomainInvariants/AggregateDecompositionTest.swift`. Testes-chave:

- Salvar `Patient` sem Assessment não cria row em `patient_assessment`
- Adicionar Assessment cria row; remover (set nil) deleta row
- Salvar Patient não dispara save de Assessment se ele não mudou (otimização)
- Cross-aggregate query: `getFullPatient(id:)` faz JOINs seletivos

### W1 — GREEN

Decompor em sub-agregados:

- `PatientAssessment` (todos os módulos `Assessment/`)
- `PatientPlacementHistory`
- `PatientIngressInfo`
- `PatientWorkAndIncome`
- `PatientHealthStatus`
- `PatientSocialHealthSummary`
- `PatientCommunitySupportNetwork`

Cada um:
- Aggregate root com `patientId: PatientId` (referência por identidade — Vernon Rule)
- Repository próprio (`PatientAssessmentRepository` etc.)
- Tabela 1:0..1 com `patient_id PK FK`
- Eventos próprios em `Assessment/Events/`

Migrations:

```sql
CREATE TABLE patient_assessments (
    patient_id UUID PRIMARY KEY REFERENCES patients(id) ON DELETE CASCADE,
    -- todos os campos hc_*, csn_*, shs_*, ses_*, etc.
    version INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Backfill: para cada paciente com qualquer hc_*/csn_*/etc. != NULL, INSERT.

-- Drop nas colunas do patients depois de validar.
```

### ADR

**ADR-021 (continuação) — Plano de adoção de decomposição de Patient**

### Better Pattern

`swift-domain-modeler.skill.md`:

```markdown
## Anti-pattern: God aggregate carregando módulos opcionais

Quando um aggregate root carrega N módulos opcionais (0..1) que são preenchidos
em momentos distintos da jornada do usuário (Registry no cadastro, Assessment
em avaliações, Care em atendimentos), **isso é sinal de que cada módulo é seu
próprio agregado**. Citação Vernon (Rule: Design Small Aggregates).
Referenciar por identidade (`patientId`), nunca composição.
```

---

# FASE 5 — UoW, Polish e Lookups

---

## T-025 — Outbox index em `event_type` (preparação para subscribers seletivos)

| Achados | DB-15 |
|---|---|
| Dependências | T-012 |
| Skill rota | `swift-io-implementer` |

### W0 — RED

Performance benchmark: query `WHERE event_type = 'PatientRegistered' AND processed_at IS NULL` deve usar index (verificar via EXPLAIN).

### W1 — GREEN

Migration: `CREATE INDEX idx_outbox_type_unprocessed ON outbox_messages (event_type, occurred_at) WHERE processed_at IS NULL;`

### ADR

**ADR-025 — Preparação de outbox para subscribers seletivos**

---

## T-026 — UF como CHECK (ou `dominio_uf` lookup)

| Achados | DB-11 + S-LOW (Address) |
| Dependências | T-001 |
| Skill rota | `swift-io-implementer` |

### W0 — RED

```swift
@Test
func test_DB_11_invalid_state_is_rejected_by_db() async throws {
    await #expect(throws: PersistenceConflictError.self) {
        try await db.raw("INSERT INTO patients (..., address_state) VALUES (..., 'XX')").run()
    }
}
```

### W1 — GREEN

Migration: `ALTER TABLE patients ADD CONSTRAINT chk_address_state CHECK (address_state IN ('AC', 'AL', ..., 'TO'));`

Domínio remove `Set<String>` hardcoded — schema é fonte única de verdade.

### ADR

**ADR-026 — UF brasileira como CHECK constraint no schema**

---

## T-027 — Padronização naming PT/EN

| Achados | DB-12 + S-LOW |
| Dependências | T-001 |
| Skill rota | `swift-io-implementer` |

### W0 — RED

`Tests/.../Regression/DataIntegrity/SchemaNamingTest.swift`:

```swift
@Test
func test_DB_12_all_tables_use_english_names() async throws {
    let tables = try await db.raw("SELECT table_name FROM information_schema.tables WHERE table_schema='public'").all()
    for table in tables {
        let name: String = try table.decode(column: "table_name", as: String.self)
        #expect(!isPortuguese(name), "Table '\(name)' should use English")
    }
}
```

### W1 — GREEN

Migration de rename:
- `dominio_*` → `lookup_*` (`lookup_relationship`, `lookup_identity_type`, etc.)
- Colunas `codigo`/`descricao`/`ativo` → `code`/`description`/`is_active`
- `lookup_requests.status` valores `'pendente'`/`'aprovado'` → `'pending'`/`'approved'`

> Trade-off: custo de migration médio (muitos updates em queries/mappers). Decidir se vale o esforço — outro caminho é manter PT e documentar como decisão consciente.

### ADR

**ADR-027 — Convenção de naming do schema: inglês universal**

---

## T-028 — Cursor pagination temporal (`created_at DESC, id DESC`)

| Achados | S-H-P5 |
| Dependências | T-023 |
| Skill rota | `swift-io-implementer` |

### W1 — GREEN

`SQLKitPatientRepository.list`:

```swift
.orderBy("created_at", .descending)
.orderBy("id", .descending)
.where(...)  // cursor composto (createdAt, id)
```

### ADR

**ADR-028 — Cursor pagination temporal estável**

---

## T-029 — JWKS refresh em background + introspection cache

| Achados | S-H-IO2 + S-H-IO3 |
| Dependências | T-001 |
| Skill rota | `swift-io-implementer` (Auth) |

### W0 — RED

```swift
@Test
func test_H_IO3_JWKS_refresh_picks_new_key() async throws {
    // Simular Authentik rotação de chave; novo token assinado com novo kid
    // Antes: serviço rejeita. Depois: pega após refresh.
}

@Test
func test_H_IO2_service_account_introspection_is_cached() async throws {
    // Duas requests do mesmo SA: introspect chamado 1x
}
```

### W1 — GREEN

Background `Task` que re-busca JWKS a cada 15min. Cache de introspection (`actor`) com TTL = min(exp - now, 60s).

### ADR

**ADR-029 — JWKS refresh automático + cache de introspection**

---

## T-030 — `ApproveLookupRequest` com UnitOfWork cross-repository

| Achados | S-C8 |
| Dependências | T-001 |
| Skill rota | `swift-application-orchestrator` |

### W0 — RED

```swift
@Test
func test_S_C8_approve_is_atomic() async throws {
    // Injetar repository que falha no updateStatus → createItem TAMBÉM rollback
    await #expect(throws: ApproveLookupRequestError.self) {
        try await handler.handle(cmd)
    }
    let item = try await lookupRepo.find(code: "NEW_CODE")
    #expect(item == nil)  // rollback total
}
```

### W1 — GREEN

`shared/Ports/UnitOfWork.swift`:

```swift
public protocol UnitOfWork: Sendable {
    func transaction<T>(_ work: (any SQLDatabase) async throws -> T) async throws -> T
}
```

`SQLKitUnitOfWork` em IO, repositórios aceitam `tx:` opcional.

Handler:

```swift
try await uow.transaction { tx in
    let itemId = try await lookupRepository.createItem(..., tx: tx)
    try await requestRepository.updateStatus(..., itemId: itemId, tx: tx)
}
```

### ADR

**ADR-030 — Unit-of-Work para coordenação cross-repository**

### Better Pattern

`swift-application-orchestrator.skill.md`:

```markdown
## Padrão: cross-repository = UoW

Handler que toca >1 repository em uma operação SEMPRE usa `UnitOfWork`.
Sem isso = fire-and-pray (estado inconsistente garantido em falha parcial).
```

---

## T-031 — `LookupBatchValidator` (1 query para N lookups)

| Achados | S-H-A3 |
| Dependências | T-008 |
| Skill rota | `swift-application-orchestrator` + `swift-io-implementer` |

### W0 — RED

```swift
@Test
func test_H_A3_register_patient_validates_lookups_in_one_query() async throws {
    let capturingValidator = CapturingLookupValidator()
    let handler = RegisterPatientCommandHandler(lookupValidator: capturingValidator, ...)
    try await handler.handle(cmd)

    #expect(capturingValidator.queryCount == 1)  // batch
    // Antes: queryCount == 4 (uma por lookup)
}
```

### W1 — GREEN

`Application/Services/LookupBatchValidator.swift`:

```swift
public protocol LookupBatchValidating: Sendable {
    func validateAll(_ pairs: [(LookupId, LookupTableName)]) async throws -> ValidationResult
}
```

Implementação SQLKit: `WHERE (id, tabela) IN (...)` com tuple matching, devolve lista de inválidos.

### ADR

**ADR-031 — LookupBatchValidator substitui N validações sequenciais**

---

# FASE 6 — Skill Learning Loop (prevenção contínua)

Objetivo: garantir que as lições aprendidas alimentam IA/skills para que código gerado no futuro nasça correto.

---

## T-032 — Lint test: rota sem `RoleGuardMiddleware`

| Achados | S-M-IO2 |
|---|---|

### W1 — GREEN

`Tests/.../Regression/Security/AllRoutesHaveRoleGuardTest.swift`:

```swift
@Test
func test_no_api_route_is_unguarded() async throws {
    for route in app.routes.all where route.path.hasPrefix("/api/") {
        let middlewares = route.userInfo["middlewares"] as? [Middleware] ?? []
        #expect(middlewares.contains(where: { $0 is RoleGuardMiddleware }),
                "Route \(route.path) has no RoleGuardMiddleware")
    }
}
```

### ADR

**ADR-032 — Default-deny via lint test: rota `/api/*` exige `RoleGuardMiddleware`**

---

## T-033 — Snapshot test do schema (drift detection)

### W0 — RED

`Tests/.../Regression/DataIntegrity/SchemaSnapshotTest.swift`:

```swift
@Test
func test_schema_matches_snapshot() async throws {
    let actual = try await db.dumpSchema()
    let expected = try String(contentsOf: URL(...).schema_snapshot.sql)
    #expect(actual == expected, "Schema drift detected — regenere snapshot se intencional")
}
```

`make snapshot-schema` regenera o snapshot localmente.

### ADR

**ADR-033 — Schema snapshot como teste de regressão**

---

## T-034 — Clock injetável em todos os handlers

| Achados | S-H-A2 |
|---|---|

### W1 — GREEN

`shared/Clock.swift`:

```swift
public typealias Clock = @Sendable () -> TimeStamp
public let systemClock: Clock = { .now }
```

Todos os handlers aceitam `clock: Clock` no init, default `systemClock`. Testes injetam `frozenClock(TimeStamp(...))`.

### ADR

**ADR-034 — Clock injetável (proibido `Date()`/`.now` direto em handler)**

### Better Pattern

`swift-application-orchestrator.skill.md` + `swift-test-writer.skill.md`:

```markdown
## Padrão Clock Injetável

Handler de comando NUNCA chama `.now`/`Date()` diretamente — recebe `clock:
Clock` no init. Testes determinísticos passam `frozenClock(...)`.
```

---

## T-035 — Substituir `try!`/`!` em hot path do mapper

| Achados | S-H-D4 + S-H-P3 |
|---|---|

### W1 — GREEN

VOs expõem `var uuid: UUID { get }` direto. Mapper para de fazer `UUID(uuidString: x.description)!`.

### ADR

**ADR-035 — Banimento de `try!`/force-unwrap em produção (test code pode usar)**

### Better Pattern

`swift-domain-modeler.skill.md`:

```markdown
## Anti-pattern: `try!` em propriedade estática

`static var underInvestigation = try! ICDCode("Z03.9")` quebra silenciosamente
em qualquer refactor do init. Sempre `assertionFailure` em debug + fallback
explícito, OU init não-throwing dedicado para constantes well-known.
```

---

## T-036 — Catálogo de prefixos de erro (`PAT-`, `AFM-`, `REGP-`, …)

| Achados | S-M-A2 |
|---|---|

### W1 — GREEN

`shared/Error/ErrorCodePrefixes.swift` central com enum de prefixos. Lint que falha se algum `AppErrorConvertible` usa prefixo não-declarado.

### ADR

**ADR-036 — Catálogo central de prefixos de erro**

---

## T-037 — Migration runner com `applied_at`/`checksum`

| Achados | S-M-P5 |
|---|---|

### W1 — GREEN

`migrations_meta` ganha `applied_at TIMESTAMPTZ`, `applied_by TEXT`, `checksum TEXT`. Runner valida checksum no boot e falha loudly se migration mudou após aplicada.

### ADR

**ADR-037 — Migration metadata: checksum + applied_at (compliance healthcare)**

---

## T-038 — Adicionar índice da pipeline em `handbook/architecture/IMPROVEMENT_BACKLOG.md`

| Achados | Meta — manter pipeline vivo |
|---|---|

Cada ticket fechado:
1. Marca checkbox em uma seção nova `## Pipeline de Remediação 2026-05-14` do `IMPROVEMENT_BACKLOG.md`
2. Atualiza `DECISIONS.md` com o ADR correspondente
3. Atualiza `MEMORY.md` da skill (auto-memory) com o link curto

### ADR

**ADR-038 — Cadência: cada ticket fechado da pipeline atualiza handbook + skill memory + DECISIONS index**

---

# 4. Tabela mestra: tickets × waves × ADRs × skills

| # | Ticket | W0 (testes) | W1 (skill) | ADR | Better Pattern em |
|---|---|---|---|---|---|
| T-001 | Regression suite | Meta | swift-test-writer | ADR-002 | tooling/swift/testing |
| T-002 | ADR-TEMPLATE com seções | — | — | ADR-003 | DECISIONS.md |
| T-003 | Catálogo Better Patterns | — | — | ADR-004 | todas as skills |
| T-004 | EventSourcedAggregate composto | RecordEventSilentNoopTest | swift-domain-modeler | ADR-005 | swift-domain-modeler |
| T-005 | Optimistic locking | OptimisticLockTest | swift-io-implementer | ADR-006 | swift-io-implementer |
| T-006 | PK em family_members/diagnoses | AggregateTableHasPKTest | swift-io-implementer | ADR-007 | swift-io-implementer |
| T-007 | relationship_id UUID + FK | RelationshipIdIsTypedTest | swift-io-implementer | ADR-008 | swift-io-implementer |
| T-008 | FKs lookups | LookupFKsTest | swift-io-implementer | ADR-009 | swift-io-implementer |
| T-009 | Money VO | MoneyIsExactTest | swift-domain-modeler | ADR-010 | swift-domain-modeler |
| T-010 | mapUniqueViolation universal | UniqueViolationMappingTest + lint | swift-application-orchestrator | ADR-011 | swift-application-orchestrator |
| T-011 | PeopleContext tri-state | PeopleContextNoFailOpenTest | swift-io-implementer | ADR-012 | swift-io-implementer |
| T-012 | Outbox FOR UPDATE SKIP LOCKED | OutboxNoDuplicationTest | swift-io-implementer | ADR-013 | swift-io-implementer |
| T-013 | Remover OutboxEventBus.publish | RepositoryPersistsEventsWithAggregateTest | swift-application-orchestrator | ADR-014 | swift-application-orchestrator |
| T-014 | SecurityHeaders + bodySize | SecurityHeadersTest | swift-io-implementer | ADR-015 | swift-io-implementer |
| T-015 | audit_trail.id distinto | AuditTrailDeduplicatesTest | swift-io-implementer | ADR-016 | swift-io-implementer |
| T-016 | DomainEvent.aggregateType | EventCarriesAggregateMetadataTest | swift-domain-modeler | ADR-017 | swift-domain-modeler |
| T-017 | NATS client correto | NATSPublisherSurvivesPingTest | swift-io-implementer | ADR-018 | swift-io-implementer |
| T-018 | Sanitização log relay | NoPiiInLogTest | swift-io-implementer | ADR-019 | swift-io-implementer |
| T-019 | AnyJSON Sendable enum | SendableJSONTest | swift-domain-modeler | ADR-020 | swift-domain-modeler |
| T-020 | required_documents 1NF | RequiredDocumentsAtomicityTest | swift-io-implementer | ADR-021 (parte) | swift-io-implementer |
| T-021 | Diff-based upsert | ChildIdentityPreservedTest | swift-io-implementer | ADR-022 | swift-io-implementer |
| T-022 | JSONB + TIMESTAMPTZ + DATE | JSONBQueryableTest+TimestampTZTest+DateTest | swift-io-implementer | ADR-023 | swift-io-implementer |
| T-023 | created_at/updated_at | TemporalAuditTest | swift-io-implementer | ADR-024 | swift-io-implementer |
| T-024 | Decompor god aggregate | AggregateDecompositionTest (suite) | swift-domain-modeler+app+io | ADR-021 | swift-domain-modeler |
| T-025 | Index outbox event_type | (benchmark) | swift-io-implementer | ADR-025 | — |
| T-026 | UF CHECK | InvalidStateRejectedTest | swift-io-implementer | ADR-026 | swift-io-implementer |
| T-027 | Naming EN universal | SchemaNamingTest | swift-io-implementer | ADR-027 | swift-io-implementer |
| T-028 | Cursor pagination temporal | (test) | swift-io-implementer | ADR-028 | swift-io-implementer |
| T-029 | JWKS refresh + introspect cache | JWKSRefreshTest+IntrospectCacheTest | swift-io-implementer | ADR-029 | swift-io-implementer |
| T-030 | UnitOfWork | ApproveAtomicTest | swift-application-orchestrator | ADR-030 | swift-application-orchestrator |
| T-031 | LookupBatchValidator | BatchValidationTest | swift-application-orchestrator | ADR-031 | swift-application-orchestrator |
| T-032 | Lint rota com RoleGuard | AllRoutesHaveRoleGuardTest | swift-test-writer | ADR-032 | swift-io-implementer |
| T-033 | Schema snapshot | SchemaSnapshotTest | swift-test-writer | ADR-033 | swift-test-writer |
| T-034 | Clock injetável | (em cada handler test) | swift-application-orchestrator | ADR-034 | swift-application-orchestrator + swift-test-writer |
| T-035 | Banir try!/! produção | ForceUnwrapAuditTest | swift-domain-modeler | ADR-035 | swift-domain-modeler |
| T-036 | Catálogo prefixos erro | ErrorCodePrefixesTest | swift-application-orchestrator | ADR-036 | swift-application-orchestrator |
| T-037 | Migration checksum | MigrationChecksumTest | swift-io-implementer | ADR-037 | swift-io-implementer |
| T-038 | Cadência fechamento | — | manual | ADR-038 | DECISIONS.md + MEMORY.md |

---

# 5. Como o `swift-orchestrator` executa cada ticket

Reaproveitando exatamente a hierarquia do `.claude/agents/swift-orchestrator.md`:

```
USUÁRIO: "Executa T-005 (optimistic locking)"
       ↓
swift-orchestrator
  1. Confirma escopo: Persistence + Domain (Patient.version)
  2. Confirma ordem: W0 (test-writer) → W1 (domain + io) → W2 (review) → W3 (quality)
       ↓
W0 — swift-test-writer
  • Escreve OptimisticLockTest em Tests/.../Regression/Concurrency/
  • Garante que falha no estado atual (assertion da hipótese)
  • Output: .pipeline/T-005/002-tests/REPORT.md
       ↓
W1.a — swift-domain-modeler
  • Patient.swift: addEvent incrementa version
  • Output: .pipeline/T-005/003-impl-domain/REPORT.md
       ↓
W1.b — swift-io-implementer
  • SQLKitPatientRepository.swift: UPDATE condicional
  • PersistenceConflictError.optimisticLockFailed
  • Output: .pipeline/T-005/003-impl-io/REPORT.md
       ↓
W2 — maestro:code-reviewer
  • Audit read-only com checklist do swift-orchestrator §W2
  • Output: .pipeline/T-005/004-code-review/REVIEW.md
       ↓
W3 — quality gates
  • make build-release / test / coverage / ci
  • Output: .pipeline/T-005/005-quality/REPORT.md
       ↓
PÓS-MERGE
  • Criar handbook/architecture/DECISIONS/ADR-006-optimistic-locking-version.md
  • Atualizar swift-io-implementer.skill.md com Better Pattern
  • Marcar T-005 ✅ em handbook/architecture/IMPROVEMENT_BACKLOG.md
  • Tag SemVer (feat: → bump minor)
```

Cada ticket segue exatamente esse fluxo. Onde o ticket exige skills múltiplas (T-005 toca Domain + IO), o swift-orchestrator roteia sequencialmente (não paralelamente — regra do orquestrator).

---

# 6. Cadência sugerida (calendário)

| Sprint | Duração | Tickets | Tag SemVer |
|---|---|---|---|
| Sprint A — Foundations + Bloqueios | 1 semana | T-001..T-009 | v0.6.0 |
| Sprint B — Segurança crítica | 1 semana | T-010..T-014 | v0.7.0 |
| Sprint C — Outbox/Eventos | 1 semana | T-015..T-019 | v0.7.x |
| Sprint D — Decomposição god aggregate | 2 semanas | T-020..T-024 | v0.8.0 |
| Sprint E — UoW + Polish | 1 semana | T-025..T-031 | v0.8.x |
| Sprint F — Skill learning loop | 1 semana | T-032..T-038 | v0.9.0 |

**Total:** 7 semanas. Sprints podem rodar em paralelo após T-006 (PK) — vários tickets ficam liberados.

---

# 7. Indicadores de sucesso

- [ ] **38 testes de regressão** vivos, todos passando em CI
- [ ] **38 ADRs** criados (ADR-002 a ADR-039)
- [ ] **5 skills atualizadas** com seções "Lições Aprendidas" (catálogo cresce)
- [ ] **Cobertura ≥ 95%** mantida em CI durante toda a pipeline
- [ ] **Zero `try!`/`!`** em código de produção (verificado por T-035)
- [ ] **Zero `@unchecked Sendable`** em DTOs/Errors (verificado por T-019)
- [ ] **Zero `deleteAndInsert`** em filhas com identidade (T-021)
- [ ] **Schema snapshot** estável em CI (T-033)
- [ ] **Achados duplicados S+DB** (ver §2) todos com ✅
- [ ] Cada PR fechado cita o ticket `[T-NNN]` e o ADR criado

---

# 8. Riscos e mitigações

| Risco | Probabilidade | Impacto | Mitigação |
|---|---|---|---|
| Decomposição god aggregate (T-024) introduz regressão funcional | Alta | Alto | Suite de regressão exaustivo ANTES; flag de feature para rollback rápido |
| Migrations destrutivas (T-007, T-022, T-027) | Média | Alto | Forward+rollback obrigatórios; pré-flight em snapshot staging; backup pré-deploy |
| Tempo do Sprint D (2 semanas) subestimado | Alta | Médio | Quebrar T-024 em T-024.a/b/c; entregar incrementalmente |
| Cliente NATS oficial introduz incompatibilidade (T-017) | Média | Médio | Feature flag para alternar entre client custom/oficial durante migração |
| ADRs viram backlog sem ação concreta | Média | Médio | T-002 obriga seções de teste+pattern → ADR sem implementação = Proposto, não Aceito |
| Skill catálogo desatualizado (T-003) | Baixa | Alto | T-038 estabelece cadência: cada merge atualiza skill + DECISIONS index |

---

# 9. Conexões com handbook existente

- `handbook/architecture/README.md` v2.0 — os 5 princípios continuam autoritativos; esta pipeline traduz "Inteligência no Domínio" + "Metadata-Driven" + "PoP" + "CQRS" + "CRU" em ações concretas mensuráveis.
- `handbook/IMPLEMENTATION_PLAN.md` G1-G17 — T-038 verifica overlap (G2 OutboxRelay = T-012; G17 Migration = T-037).
- `handbook/architecture/IMPROVEMENT_BACKLOG.md` — alguns achados podem já estar listados; pipeline absorve.
- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` — fonte 1.
- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` — fonte 2.
- `handbook/reports/CODE_REVIEW_DOMAIN_2026_03_06.md`, `CODE_REVIEW_APPLICATION_2026_03_06.md`, `CODE_REVIEW_IO_SHARED_2026_03_07.md` — reports históricos. Tickets desta pipeline absorvem achados ainda abertos desses reports (cross-check em T-038).

---

# 10. Próximos passos imediatos

1. **Aprovar a pipeline** (decisão produto/tech lead): se aprovada, virar issues no GitHub com label `pipeline-2026-05-14`.
2. **Executar T-001/T-002/T-003** antes de qualquer outro ticket (Foundations) — sem isso, o resto não tem onde aterrissar.
3. **Criar ADR-002** referenciando esta pipeline como contexto.
4. **Definir DRI** (directly responsible individual) por sprint — algumas tarefas (decomposição) precisam de pareamento.

---

> **Fim do documento.** Última atualização: 2026-05-14.
> Para abrir um ticket: `swift-orchestrator: executa T-NNN` ou criar issue com template no GitHub.
