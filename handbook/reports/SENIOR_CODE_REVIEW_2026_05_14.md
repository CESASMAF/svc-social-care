# Senior Code Review — Análise Teórica Fundamentada

**Escopo:** `Sources/social-care-s/` (279 arquivos Swift)
**Stack:** Swift 6.3 (strict concurrency) + Vapor 4 + SQLKit/PostgresKit + swift-testing
**Branch:** `feat/oidc-multi-issuer-authentik`
**Data:** 2026-05-14
**Tipo:** Revisão completa cross-camada, read-only, com fundamentação na literatura canônica do projeto
**Bounded contexts analisados:** Registry, Assessment, Care, Protection, Configuration, Query

---

## 1. Veredicto Executivo

**Estado geral:** **BOM com débito sério em pontos críticos**.

A arquitetura tem fundação madura. Os 5 princípios não-negociáveis do handbook v2.0 (Inteligência no Domínio, PoP, CQRS, Metadata-Driven, CRU/No Delete) são respeitados em pontos críticos: VOs com `init(_:) throws` consistente, `AppError` padronizado com código estruturado, `LookupId` substituindo enums hardcoded, `AllowedLookupTables.all` blindando table-name injection, defense-in-depth no JWT (`OIDCJWTPayloadBootstrap` + `verify(using:)` validando iss/aud/exp/nbf em todo codepath), Transactional Outbox real (`SQLKitPatientRepository.save:14-47`), e a sequência canônica `parse → validate → fetch → domain → persist → publish` respeitada em ~95% dos 21 handlers.

**Mas** há um cinturão de bugs latentes que só se manifestam sob carga real, falha do upstream, ou múltiplas instâncias do serviço. Os mais graves:

1. **`PeopleContextPersonValidator` é fail-open + zero auth** — viola ADR-023 e abre bypass de invariante de domínio.
2. **Outbox relay duplica eventos** — sem `FOR UPDATE SKIP LOCKED`, dois pods leem o mesmo lote.
3. **Save sem optimistic locking** apesar da coluna `version` existir — perde escritas concorrentes silenciosamente.
4. **`OutboxEventBus.publish` é dead code** acoplado implicitamente ao `repository.save` — quebra invariante "events after persist" se trocar repository.
5. **God aggregate `Patient`** carrega 4 bounded contexts (Registry + Care + Protection + Assessment), com 18 propriedades mutáveis e 12 setters CRUD-style sem invariantes defendidas.
6. **20 de 21 handlers não mapeiam `PersistenceConflictError`** — apenas RegisterPatient cumpre a regra do handbook.

Esses achados não impedem o MVP, mas bloqueiam produção multi-instância em healthcare. Este relatório consolida ~75 achados, fundamenta cada CRITICAL na literatura canônica indexada via `acdg-skills` MCP (Evans, Vernon, Fowler, Newman, Martin), e propõe um roadmap de 3 sprints.

---

## 2. Metodologia

A revisão usou:

1. **Análise de senior em 4 camadas paralelas** (Domain, Application, IO/HTTP+PeopleContext, IO/Persistence+EventBus+shared) via 4 sub-agentes Maestro independentes. Cada um leu o código com lente própria, gerou findings com `file:line`, e propôs correção concreta.
2. **Fundamentação teórica via `acdg-skills` MCP** (`/Users/.../skills_base/shared-tools/buscar.ts` + `citar.ts`) sobre os livros canônicos das skills ACDG: Evans (DDD), Vernon (Implementing DDD), Fowler (Refactoring), Martin (Código Limpo), Newman (Building Microservices). Cada CRITICAL foi cross-referenced com citação literal.
3. **Cross-check contra o handbook** (`architecture/README.md` v2.0, `IMPLEMENTATION_PLAN.md` gaps G1-G17, ADRs ativos).
4. **Read-only** — nenhuma modificação no código foi feita.

Hierarquia adotada para resolver conflito de prescrição:

```
handbook/architecture/README.md (v2.0)
  > handbook/architecture/DECISIONS/ADR-NNN-*.md
    > literatura canônica (Evans, Vernon, Fowler, Newman)
      > convenções implícitas do código atual
```

---

## 3. Princípios Teóricos Invocados

### 3.1 Agregados e fronteiras de consistência (Evans + Vernon)

> **AGGREGATE** — A cluster of associated objects that are treated as a unit for the purpose of data changes. External references are restricted to one member of the AGGREGATE, designated as the root. A set of consistency rules applies within the AGGREGATE'S boundaries.
> — *Evans, Domain-Driven Design, p. 311 (linha 6777 do índice acdg-skills)*

> **Rule: Model True Invariants in Consistency Boundaries** — When trying to discover the Aggregates in a Bounded Context, we must understand the model's true invariants. Only with that knowledge can we determine which objects should be clustered into a given Aggregate. […] **The consistency boundary logically asserts that everything inside adheres to a specific set of business invariant rules no matter what operations are performed. The consistency of everything outside this boundary is irrelevant to the Aggregate. Thus, Aggregate is synonymous with transactional consistency boundary.**
> — *Vernon, Implementing Domain-Driven Design, p. 450 (linha 8985)*

> **Rule: Design Small Aggregates** — We can now thoroughly address this question: What additional cost would there be for keeping the large-cluster Aggregate? **Even if we guarantee that every transaction would succeed, a large cluster still limits performance and scalability.** [...] Performance and scalability are nonfunctional requirements that cannot be ignored.
> — *Vernon, ibidem, p. 450 (linha 9014)*

> **Rule: Reference Other Aggregates by Identity** — When designing Aggregates, we may desire a compositional structure that allows for traversal through deep object graphs, but **that is not the motivation of the pattern**. [Evans] states that one Aggregate may hold references to the Root of other Aggregates. However, **we must keep in mind that this does not place the referenced Aggregate inside the consistency boundary of the one referencing it.**
> — *Vernon, ibidem, p. 458 (linha 9074)*

**Implicação no nosso código:** `Patient` carrega `appointments: [SocialCareAppointment]`, `referrals: [Referral]` e `violationReports: [RightsViolationReport]` — agregados de Care e Protection — dentro da própria struct. Isto é exatamente o "large-cluster Aggregate" que Vernon recomenda evitar. A composição correta é por **referência por identidade** (`patientId`), com cada agregado tendo seu próprio repositório e suas próprias invariantes transacionais.

### 3.2 Publicação de eventos de domínio (Vernon)

> **Publishing Events from the Domain Model** — Avoid exposing the domain model to any kind of middleware messaging infrastructure. Those kinds of components live only in the infrastructure. And while the domain model might at times use such infrastructure indirectly, it **would never explicitly couple to it**. […] All registered subscribers execute in the same process space with the publisher and run on the same thread. When an Event is published, each subscriber is notified synchronously, one by one. **This also implies that all subscribers are running within the same transaction**, perhaps controlled by an Application Service that is the direct client of the domain model.
> — *Vernon, Implementing DDD, p. 382 (linha 7320)*

**Implicação no nosso código:** `OutboxEventBus.publish` é hoje no-op. O Outbox real é feito implicitamente dentro de `SQLKitPatientRepository.save` (escreve a tabela `outbox_messages` na mesma transação do agregado). O design correto é exatamente esse — eventos persistidos na mesma transação do agregado — mas a interface do handler engana o leitor sugerindo que `eventBus.publish` controla a publicação. Refatorar para que a invariante seja **tipada** (não dependente de coincidência).

### 3.3 Primitive Obsession e Replace Primitive with Object (Fowler)

> **PRIMITIVE OBSESSION** — Most programming environments are built on a widely used set of primitive types: integers, floating point numbers, and strings. [...] We find many programmers are curiously reluctant to create their own fundamental types which are useful for their domain — such as money, coordinates, or ranges. [...] **Strings are particularly common petri dishes for this kind of odor: A telephone number is more than just a collection of characters.** [...] Representing such types as strings is such a common stench that people call them "stringly typed" variables.
> — *Fowler, Refactoring, p. 68 (linha 2572)*

**Implicação no nosso código:**
- `SocialBenefit.benefitName: String` em vez de `benefitTypeId: LookupId` (anti-Metadata-Driven).
- `actorId: String` em todos os métodos mutadores em vez de um VO `ActorId` ou `ProfessionalId`.
- `LookupRepository.codigoExists(_ table: String, …)` em vez de um VO `LookupTableName(_:) throws` validando contra `AllowedLookupTables.all`.
- `rights_violation_reports.violation_type: TEXT livre` em vez de FK para um lookup (perde rastreabilidade de uso para o `isItemReferenced` do admin).

### 3.4 Idempotência (Newman)

> **Idempotency** — In idempotent operations, the outcome doesn't change after the first application, even if the operation is subsequently applied multiple times. If operations are idempotent, we can repeat the call multiple times without adverse impact. **This is very useful when we want to replay messages that we aren't sure have been processed, a common way of recovering from error.** [...] This mechanism works just as well with event-based collaboration and can be especially useful if you have multiple instances of the same type of service subscribing to events. **Even if we store which events have been processed, with some forms of asynchronous message delivery there may be small windows in which two workers can see the same message.** By processing the events in an idempotent manner, we ensure this won't cause us any issues.
> — *Newman, Building Microservices, p. 500 (linha 6572)*

**Implicação no nosso código:** O outbox relay (`SQLKitOutboxRelay.swift:91-167`) é **at-least-once** mas não emite um `idempotencyKey` para o consumidor (header `Nats-Msg-Id` no NATS, por exemplo). Combinado com o problema do `SELECT` sem `FOR UPDATE SKIP LOCKED`, isso vira at-least-twice em situações banais (deploy rolling, dois pods, crash entre publish e UPDATE). Consumidor downstream não tem como deduplicar.

### 3.5 Sagas / 2PC para coordenação multi-recurso (Newman)

> **Sagas** — Unlike a two-phase commit, a saga is by design an algorithm that can coordinate multiple changes in state, but avoids the need for locking resources for long periods of time. A saga does this by modeling the steps involved as discrete activities that can be executed independently. […] **a saga does not give us atomicity in ACID terms** [...] **What a saga gives us is enough information to reason about which state it's in; it's up to us to handle the implications of this.**
> — *Newman, Building Microservices, p. 229 (linha 3017)*

**Implicação no nosso código:** `ApproveLookupRequestCommandHandler.swift:34-47` faz `lookupRepository.createItem(...)` seguido de `requestRepository.updateStatus(...)` em chamadas separadas sem qualquer coordenação. Não é Saga (não há compensação), não é transação (não há UoW). É exatamente "fire-and-pray". O caminho correto é (a) introduzir Unit-of-Work cross-repository (mesma transação SQL), ou (b) Saga explícita com etapa de compensação para o caso da segunda falhar.

### 3.6 Tratamento de erro é uma coisa só (Martin)

> **Tratamento de erro é uma coisa só** — As funções devem fazer uma coisa só. Tratamento de erro é uma coisa só. Portanto, uma função que trata de erros não deve fazer mais nada. Isso implica (como no exemplo acima) que a palavra `try` está dentro de uma função e deve ser a primeira instrução e nada mais deve vir após os blocos `catch`/`finally`.
> — *Martin, Código Limpo, p. 48 (linha 1260)*

**Implicação no nosso código:** O padrão `do { … } catch { throw mapError(error, …) }` está correto. O problema é a **duplicação de `mapError`** sem extração: 21 handlers, cada um com um arquivo `*MapperError.swift` à parte, com lógica quase idêntica de mapeamento de `PersistenceConflictError.uniqueViolation` → erro de negócio. Apenas 1 dos 21 implementa esse mapeamento (RegisterPatient), os outros vazam erro genérico — violação direta da regra do handbook.

### 3.7 Make the assumption explicit (Fowler)

> **Motivation [Introduce Assertion]** — Often, sections of code work only if certain conditions are true. […] Such assumptions are often not stated but can only be deduced by looking through an algorithm. Sometimes, the assumptions are stated with a comment. **A better technique is to make the assumption explicit by writing an assertion.**
> — *Fowler, Refactoring, p. 326 (linha 11140)*

**Implicação no nosso código:**
- `recordEvent` (`shared/Domain/DomainProtocols.swift:67-79`) usa `if var internalSelf = self as? any EventSourcedAggregateInternal` — se o agregado novo esquecer de conformar `EventSourcedAggregateInternal`, **eventos são engolidos sem erro**. Assumption implícita que precisa virar requisito tipado (`EventSourcedAggregate: EventSourcedAggregateInternal`).
- `TimeStamp.now { try! TimeStamp(Date()) }` (`Kernel/TimeStamp/TimeStamp.swift:19`) — assumption "Date() sempre passa no init" enterrada em `try!`. Refactor desse init quebra silenciosamente todo o código que usa `.now`.
- `CPF.fiscalRegion { FiscalRegion(rawValue: fiscalRegionDigit)! }` — assumption "FiscalRegion tem raw para 0..9" não verificada no init.

### 3.8 Open Host Service / Anti-Corruption Layer (Evans)

> **Open Host Service** — Typically for each BOUNDED CONTEXT, you will define a translation layer for each component outside the CONTEXT with which you have to integrate. […] **When a subsystem has to be integrated with many others, customizing a translator for each can bog down the team.**
> — *Evans, DDD, p. 248 (linha 5101)*

**Implicação no nosso código:** `PeopleContextPersonValidator` (`IO/PeopleContext/`) é o adapter de Anti-Corruption Layer para o Bounded Context `people-context`. Hoje ele é fail-open, sem auth, sem forwarding do Bearer (viola ADR-023). Deve virar uma porta tri-state (`exists / notFound / unknown`), com `unknown` traduzido para um erro de domínio que **bloqueie** o registro até retomada — não permitindo "passar" como verdadeiro.

---

## 4. Achados CRITICAL

Cada achado segue a estrutura: **Sintoma → Localização → Fundamentação teórica → Solução correta → Como implementar no código atual**.

---

### C1 — `PeopleContextPersonValidator` é fail-open, sem auth e viola ADR-023

**Localização:** `IO/PeopleContext/PeopleContextPersonValidator.swift:22-50`

**Sintoma:** Três falhas sobrepostas no único client outbound:

1. **Fail-open**: qualquer erro (4xx ≠ 404, 5xx, timeout, DNS) retorna `true`. Um atacante que derrubar o people-context (ou só esperar uma janela de instabilidade) consegue registrar pacientes com `personId` arbitrário — quebra a invariante "Patient existe ⇒ Person existe" sem deixar rastro de segurança no log (apenas `warning`).
2. **Sem `Authorization: Bearer`** — viola ADR-023 explicitamente. Hoje a chamada vai sem nenhum header de identidade.
3. **`URL(string: …)!`** com `personId.description` direto na string — sem percent-encoding.

**Fundamentação teórica:** Anti-Corruption Layer / Open Host Service (Evans, p. 248). O adapter de integração com outro BC é a **fronteira de confiança** — toda falha do upstream deve ser traduzida para um erro de domínio explícito do BC local, nunca interpretada como "tudo bem". Acoplar isso a um fail-open viola simultaneamente o ACL (que existe justamente para isolar mudanças do upstream) e o princípio de **secure defaults** (OWASP ASVS V14.5).

**Solução correta:**

- Mudar contrato para tri-state: `enum PersonExistence { case exists, notFound, unknown }`.
- Tratar `unknown` como erro de domínio (`personValidationUnavailable`) que bloqueia o registro com HTTP 503 ("upstream dependency unavailable").
- Aceitar o JWT do request via `req.client` e propagar `Authorization: Bearer <jwt>` (ADR-023).
- Usar `URLComponents` com `percentEncoded`.

**Como implementar:**

```swift
// IO/PeopleContext/PeopleContextPersonValidator.swift
public enum PersonExistence: Sendable { case exists, notFound, unknown(reason: String) }

public actor PeopleContextPersonValidator: PersonExistenceValidating {
    public func validate(personId: PersonId, bearer: String) async -> PersonExistence {
        guard var components = URLComponents(string: baseURL) else { return .unknown(reason: "invalid base url") }
        components.path += "/api/v1/people/\(personId.description)"
        guard let url = components.url else { return .unknown(reason: "url build failed") }
        // ... GET com Authorization: Bearer <bearer>, mapeia 200 → .exists, 404 → .notFound, else .unknown
    }
}
```

E em `RegisterPatientCommandHandler`, `.unknown` deve falhar com `RegisterPatientError.personValidationUnavailable` (HTTP 503), nunca prosseguir.

---

### C2 — Outbox relay duplica eventos em múltiplas instâncias

**Localização:** `IO/Persistence/SQLKit/Outbox/SQLKitOutboxRelay.swift:91-167`

**Sintoma:** O `pollAndDistribute` lê com um SELECT comum (`SELECT * FROM outbox_messages WHERE processed_at IS NULL LIMIT 50`), publica no NATS, e *depois* faz UPDATE para marcar como processado. Não há lock pessimista entre SELECT e UPDATE. Se dois pods rodarem, ambos pegam as mesmas 50 linhas e publicam duas vezes. Pior: o gap entre `nats.publish` (linha 117) e o `UPDATE processed_at` (linha 162) é grande — se a app crashar nesse intervalo, o mesmo evento será re-publicado no próximo poll.

**Fundamentação teórica:** Newman (*Building Microservices*, p. 500) ensina que **at-least-once é aceitável**, desde que (a) o consumidor seja idempotente, e (b) o produtor emita um `idempotencyKey` por evento (ex: header `Nats-Msg-Id` do NATS JetStream).

> *"Even if we store which events have been processed, with some forms of asynchronous message delivery there may be small windows in which two workers can see the same message. By processing the events in an idempotent manner, we ensure this won't cause us any issues."* — Newman, p. 500

Hoje não há (b) — o payload não carrega `idempotencyKey` deduplicável pelo broker, e a janela "two workers see the same message" é a regra, não exceção (sem `FOR UPDATE SKIP LOCKED`).

**Solução correta:**

1. **Lock pessimista no SELECT** com `FOR UPDATE SKIP LOCKED LIMIT 50` dentro de uma transação curta.
2. **OU** advisory lock global (`pg_try_advisory_lock(<job_id>)`) para garantir single-leader.
3. **Propagar `id` do outbox no payload** como `Nats-Msg-Id` (JetStream deduplica nativo por 2min default).
4. **Documentar formalmente** que o contrato é at-least-once.

**Como implementar:**

```swift
// SQLKitOutboxRelay.swift
let rows = try await db.transaction { tx in
    try await tx.raw("""
        SELECT id, event_type, payload, created_at
        FROM outbox_messages
        WHERE processed_at IS NULL
        ORDER BY created_at ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 50
    """).all()
}
// publish com headers: ["Nats-Msg-Id": row.id.uuidString]
```

---

### C3 — `save(_:)` sem optimistic lock apesar de coluna `version` existente

**Localização:** `IO/Persistence/SQLKit/SQLKitPatientRepository.swift:19-22` + `IO/Persistence/SQLKit/Models/PatientDatabaseModels.swift:9`

**Sintoma:** O `PatientModel` carrega `version: Int`, mas o upsert é `INSERT … ON CONFLICT (id) DO UPDATE SET … excluded.*`. Duas requisições concorrentes que ambas leiam `version=5` e gravem ambas como `version=6` vão sobrescrever uma à outra silenciosamente. Em healthcare, isso significa perder anotações de atendimento concorrentes (dois assistentes sociais editando o mesmo paciente).

**Fundamentação teórica:** Vernon define o agregado como **fronteira de consistência transacional** (Implementing DDD, p. 450). Para que essa fronteira funcione sob concorrência, é necessário um mecanismo de detecção de conflito — optimistic locking via coluna `version` é o padrão clássico (Evans, p. 154; Vernon, capítulo 10). O MySQL manual reforça que sem isolation level adequado + version check, "lost updates" são possíveis em qualquer isolation < SERIALIZABLE.

> *"A consistent read means that InnoDB uses multi-versioning to present to a query a snapshot of the database at a point in time."* — MySQL Reference Manual 8.4 (linha 136643)

Optimistic locking move a checagem para a aplicação (`UPDATE ... WHERE version = ?`), evitando o custo de SERIALIZABLE.

**Solução correta:**

```sql
-- Em vez de:
INSERT ... ON CONFLICT (id) DO UPDATE SET ... excluded.*

-- Fazer:
UPDATE patients SET
    first_name = $2, last_name = $3, ...,
    version = version + 1
WHERE id = $1 AND version = $expectedVersion
RETURNING version;
```

Se `rowsAffected == 0` → lançar `PersistenceConflictError.optimisticLockFailed(expectedVersion:, actualVersion: …)`. O handler de Application mapeia para o erro de negócio (`PatientHasBeenModifiedConcurrently` → HTTP 409 Conflict com hint para o cliente re-buscar).

O domínio (`Patient`) já tem `internal(set) var version: Int` — precisa incrementar em cada `mutating func` ou centralizar em `recordEvent`.

---

### C4 — `OutboxEventBus.publish` é dead code que mascara violação de invariante

**Localização:** `IO/EventBus/OutboxEventBus.swift:13-18` + todos os 21 command handlers

**Sintoma:** A função recebe eventos, comenta que "eventos já foram escritos pelo repository", e retorna. O `try await eventBus.publish(patient.uncommittedEvents)` que aparece em todo handler é cosmético — o "Outbox Pattern" real está implementado dentro de `SQLKitPatientRepository.save`. Se algum dia outro repository não inserir no `outbox_messages`, os eventos somem sem warning.

**Fundamentação teórica:** Vernon (*Implementing DDD*, p. 382):

> *"Avoid exposing the domain model to any kind of middleware messaging infrastructure. […] All registered subscribers execute in the same process space with the publisher and run on the same thread. When an Event is published, each subscriber is notified synchronously, one by one. **This also implies that all subscribers are running within the same transaction**, perhaps controlled by an Application Service that is the direct client of the domain model."*

O design **correto** é exatamente o que está implementado — eventos persistidos na mesma transação do agregado. O problema é a **interface enganosa**: o handler chama `eventBus.publish` achando que controla a publicação, mas o controle real está enterrado no repository. Fowler chamaria isso de assumption implícita que deveria virar assertion explícita (Refactoring, p. 326, linha 11140).

**Solução correta:** três opções, escolher uma e documentar como ADR.

**Opção A (preferida — manter Outbox enterrado, tornar interface honesta):**

Remover `eventBus.publish(events)` dos handlers. O Application Service confia que `repository.save(aggregate)` persiste agregado + eventos na mesma transação, e o relay polling é o único caminho de publish. A invariante vira:

```swift
// Em PatientRepository (protocol no Domain)
public protocol PatientRepository: Sendable {
    /// Persists the aggregate AND its uncommittedEvents in the same transaction.
    /// Returns the aggregate with cleared events.
    func save(_ patient: Patient) async throws -> Patient
}
```

**Opção B (Outbox separado, handler controla):**

`repository.save` salva só o agregado. Handler chama `eventBus.publish(events, tx: …)` numa transação coordenada (UoW). Mais complexo, mas torna o publish explícito.

**Opção C (Domain Event Publisher in-process, like Vernon):**

Usar `DomainEventPublisher.shared.publish(event)` dentro do agregado, registrar subscriber que escreve no outbox. Padrão clássico Vernon, mas adiciona singleton mutável global.

**Recomendação:** Opção A, com ADR documentando.

---

### C5 — Boot não instala headers de segurança HTTP nem limite de body

**Localização:** `IO/HTTP/Bootstrap/configure.swift:240-244`

**Sintoma:** Só `AppErrorMiddleware` e `JWTAuthMiddleware` são registrados. **Faltando:**

- `Strict-Transport-Security`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY` (ou CSP `frame-ancestors 'none'`)
- `Referrer-Policy: no-referrer`
- `Cache-Control: no-store` em endpoints autenticados
- `app.routes.defaultMaxBodySize` continua o default Vapor (~16KB form, sem limite explícito em JSON) — endpoints como `RegisterPatientRequest` aceitam listas grandes
- Sem CORS configurado — se BFF same-origin OK, mas precisa estar **explícito e fail-closed**
- Sem rate-limiting

**Fundamentação teórica:** OWASP ASVS L1 V14.4 ("HTTP Security Headers"), OWASP ASVS V13.1 ("Generic Web Service Security"). Trata-se de defense-in-depth — uma camada que existe para reduzir impacto de outras falhas (XSS, MIME confusion, clickjacking).

**Solução correta:**

```swift
// IO/HTTP/Bootstrap/SecurityHeadersMiddleware.swift
public struct SecurityHeadersMiddleware: AsyncMiddleware {
    public func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let res = try await next.respond(to: req)
        res.headers.replaceOrAdd(name: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains; preload")
        res.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        res.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        res.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        res.headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        return res
    }
}

// configure.swift, ANTES de qualquer outro middleware:
app.middleware.use(SecurityHeadersMiddleware())
app.routes.defaultMaxBodySize = "256kb"
```

Para rate-limiting, considerar `vapor/rate-limiting` ou implementar token-bucket por `actorId`/IP em `actor` separado.

---

### C6 — Apenas 1 de 21 handlers mapeia `PersistenceConflictError.uniqueViolation`

**Localização:** `Application/Registry/RegisterPatient/Error/RegisterPatientMapperError.swift:107-116` (único) + 20 outros handlers

**Sintoma:** O `CLAUDE.md` determina: *"Repositórios lançam `PersistenceConflictError.uniqueViolation` para violações de unicidade; o handler mapeia para o erro de negócio específico."* Apenas RegisterPatient cumpre. AddFamilyMember (member duplicado), CreateLookupItem (codigo duplicado), CreateLookupRequest, ApproveLookupRequest, todos os Update*Status — nenhum mapeia. Resultado: violação de unicidade vira `persistenceMappingFailure` 500 ao invés de 409 Conflict de negócio.

**Fundamentação teórica:** Martin, *Código Limpo*, p. 48 (linha 1260):

> *"Tratamento de erro é uma coisa só. […] Portanto, uma função que trata de erros não deve fazer mais nada."*

O `do/catch` está correto, mas falta o **DRY** no `mapError`: cada handler reescreve quase a mesma lógica de identificar `PersistenceConflictError` e mapear, e 20 dos 21 esquecem. Isso é caso clássico de **Extract Method** (Fowler) — eleva para helper genérico no shared.

**Solução correta:**

```swift
// shared/Error/PersistenceConflictMapping.swift
public extension PersistenceConflictError {
    /// Maps a unique-violation constraint name to a domain error.
    /// Returns nil if the error is not a unique violation, or if no mapping is provided.
    func mapUniqueViolation<E: Error>(_ mapping: (String) -> E?) -> E? {
        guard case .uniqueViolation(let constraint, _) = self else { return nil }
        return mapping(constraint)
    }
}

// Em RegisterPatientMapperError.swift:
func mapError(_ error: Error, patientId: PatientId) -> RegisterPatientError {
    if let conflict = error as? PersistenceConflictError,
       let mapped = conflict.mapUniqueViolation({ constraint -> RegisterPatientError? in
           switch constraint {
           case "idx_patients_cpf_unique": return .cpfAlreadyRegistered(...)
           case "idx_patients_person_id_unique": return .personIdAlreadyRegistered(...)
           default: return nil
           }
       }) {
        return mapped
    }
    // ... resto do mapping
}
```

E adicionar lint test (em `Tests/`) que percorre todos os `*MapperError.swift` e falha se algum não chama `mapUniqueViolation`.

---

### C7 — `recordEvent` é no-op silencioso

**Localização:** `shared/Domain/DomainProtocols.swift:67-79`

**Sintoma:**

```swift
extension EventSourcedAggregate {
    public mutating func recordEvent(_ event: any DomainEvent) {
        if var internalSelf = self as? any EventSourcedAggregateInternal {
            internalSelf.addEvent(event)
            if let back = internalSelf as? Self { self = back }
        }
    }
}
```

Se um agregado novo conformar `EventSourcedAggregate` mas esquecer `EventSourcedAggregateInternal`, **eventos são engolidos sem erro**. Não há `precondition`/asserção e o protocolo `EventSourcedAggregate` não tem o requisito como `where`-clause. É bug que só aparece em produção quando o Outbox falha em publicar algo que "deveria" ter sido publicado.

**Fundamentação teórica:** Fowler, *Refactoring*, p. 326 (linha 11140) — Introduce Assertion:

> *"Such assumptions are often not stated but can only be deduced by looking through an algorithm. […] A better technique is to make the assumption explicit by writing an assertion."*

A assumption "todo `EventSourcedAggregate` é também `EventSourcedAggregateInternal`" deveria estar no sistema de tipos.

**Solução correta:**

```swift
// shared/Domain/DomainProtocols.swift
public protocol EventSourcedAggregate: EventSourcedAggregateInternal {
    var uncommittedEvents: [any DomainEvent] { get }
}

public protocol EventSourcedAggregateInternal {
    mutating func addEvent(_ event: any DomainEvent)
    mutating func clearEvents()
}

// O default implementation recordEvent passa a chamar addEvent direto, sem cast.
```

Compilador agora bloqueia quem esquecer.

---

### C8 — `ApproveLookupRequest` faz duas escritas em repositórios diferentes sem transação

**Localização:** `Application/Configuration/LookupRequest/Services/ApproveLookupRequestCommandHandler.swift:34-47`

**Sintoma:** `lookupRepository.createItem(...)` e em seguida `requestRepository.updateStatus(..., status: .aprovado, ...)`. Se a segunda chamada falhar (rede, deadlock, lock timeout), o item de lookup é criado mas o request fica `pendente` para sempre — operador clica "aprovar" de novo → 409 codigoAlreadyExists. Estado inconsistente sem reconciliação.

**Fundamentação teórica:** Newman, *Building Microservices*, p. 229 (linha 3017):

> *"Unlike a two-phase commit, a saga is by design an algorithm that can coordinate multiple changes in state, but avoids the need for locking resources for long periods of time. […] **a saga does not give us atomicity in ACID terms** […] **What a saga gives us is enough information to reason about which state it's in; it's up to us to handle the implications of this.**"*

Vernon (*Implementing DDD*, p. 468, linha 9245) lista exceções legítimas à regra "1 agregado = 1 transação" — "User Interface Convenience" sendo uma — mas exige que a transação seja **explícita** e justificada. Hoje é nem-saga-nem-transação.

**Solução correta:** como ambos os repositórios apontam para o mesmo Postgres (mesmo `SQLDatabase`), o caminho mais barato é:

```swift
// Application/Configuration/LookupRequest/Services/ApproveLookupRequestCommandHandler.swift
public func handle(_ cmd: ApproveLookupRequestCommand) async throws {
    try await uow.transaction { tx in
        let createdId = try await lookupRepository.createItem(...,  tx: tx)
        try await requestRepository.updateStatus(..., status: .aprovado, itemId: createdId, tx: tx)
    }
}
```

Onde `UnitOfWork` é uma porta nova em `shared/Ports/`. Implementação em `IO/Persistence/SQLKit/SQLKitUnitOfWork.swift` envolve `SQLDatabase.transaction`. Cada repository aceita `tx: SQLDatabase` opcional (usa o passado se houver).

Alternativa (se cross-DB no futuro): Saga com etapa de compensação (`deleteLookupItem` se `updateStatus` falhar) — mais complexa, justificada apenas se a separação física estiver no roadmap.

---

### C9 — `NATSEventPublisher.readInbound()` retorna buffer vazio sempre

**Localização:** `IO/EventBus/NATSEventPublisher.swift:138-144`

**Sintoma:**

```swift
func readInbound() async throws -> ByteBuffer? {
    var buffer = allocator.buffer(capacity: 1024)
    try? await Task.sleep(for: .milliseconds(100))
    return buffer  // sempre vazio!
}
```

A função existe para ler o `INFO` frame do servidor NATS, mas nunca lê de fato. O `CONNECT` é enviado às cegas. Como o channel não tem `ChannelInboundHandler` instalado, qualquer dado do servidor (PING, +ERR, INFO) é silenciosamente descartado pelo NIO. **Consequência prática:** o servidor manda `PING` a cada ~2min (default NATS), o publisher não responde, servidor fecha o socket, próximas publicações retornam `notConnected` ou silenciam o erro.

**Fundamentação teórica:** RFC 6455 (WebSockets) e o protocolo NATS exigem keepalive bidireccional. Implementação half-duplex é design defeituoso.

**Solução correta:** substituir pela biblioteca oficial `nats.swift` (https://github.com/nats-io/nats.swift) ou ao menos instalar um `ChannelInboundHandler` simétrico ao `NATSEventSubscriber` que responde PONG ao PING e loga `+ERR`.

---

### C10 — `audit_trail` PK reusa `outbox_messages.id` → unique violation mata batch

**Localização:** `IO/Persistence/SQLKit/Outbox/SQLKitOutboxRelay.swift:128, 158-166`

**Sintoma:**

```swift
let auditEntries = batch.map { message in
    AuditTrailEntry(
        id: message.id, // PK do audit reusa o ID do outbox message
        aggregate_type: "Patient", // <- hardcoded, ver M10
        ...
    )
}
try await db.transaction { tx in
    for entry in auditEntries { try await tx.insert(into: "audit_trail").model(entry).run() }
    try await tx.update("outbox_messages").set("processed_at", to: now).where("id", .in, finalIds).run()
}
```

Quando o relay re-processa um evento (consequência do C2: dois pods, ou crash entre publish e UPDATE), tenta inserir o mesmo `audit_trail.id` → unique violation → toda a transação aborta → **49 eventos válidos voltam para `processed_at IS NULL`** → próxima poll tenta de novo → loop infinito de falha.

**Fundamentação teórica:** princípio de **idempotência de consumidor** (Newman, p. 500). Quando o sistema é at-least-once, cada consumidor — incluindo o "consumidor interno" que escreve audit trail — precisa absorver duplicatas.

**Solução correta:**

```swift
// Opção 1: audit_trail.id próprio
let auditEntry = AuditTrailEntry(id: UUID(), outboxMessageId: message.id, ...)

// Opção 2: ON CONFLICT DO NOTHING no INSERT do audit_trail
try await tx.raw("""
    INSERT INTO audit_trail (id, ...) VALUES (\(bind: message.id), ...)
    ON CONFLICT (id) DO NOTHING
""").run()
```

Recomendo Opção 1 — separar identidades é mais robusto e permite múltiplos audit entries por evento se algum dia o design crescer.

---

## 5. Achados HIGH

Resumo compactado por camada. Para cada um, o problema, file:line, e a sugestão concreta. Fundamentação teórica condensada — para detalhe completo, ver referências.

### 5.1 Domain

**H-D1. God Aggregate `Patient` — 4 BCs colapsados num único struct**

`Domain/Registry/Aggregates/Patient/Patient.swift:39-99,71-83` + `PatientAssessments.swift`

`Patient` (Registry BC) carrega `appointments: [SocialCareAppointment]` (Care BC), `referrals: [Referral]` (Protection BC), `violationReports: [RightsViolationReport]` (Protection BC), `housingCondition`, `healthStatus`, `educationalStatus`, `socioEconomicSituation`, `workAndIncome`, `socialBenefits`, `communitySupportNetwork`, `socialHealthSummary` (Assessment BC) — 18 propriedades mutáveis + 12 métodos `update*` que são CRUD puro sem invariante.

**Fundamentação:** Vernon (Rule: Design Small Aggregates, p. 450):

> *"Even if we guarantee that every transaction would succeed, a large cluster still limits performance and scalability."*

E (Rule: Reference Other Aggregates by Identity, p. 458):

> *"One Aggregate may hold references to the Root of other Aggregates. However, we must keep in mind that this does not place the referenced Aggregate inside the consistency boundary of the one referencing it."*

**Sugestão:** Promover Assessment, Care e Protection a agregados próprios. `Patient` carrega apenas `Registry` + `FamilyMember` + `lifecycle status`. Outros agregados referenciam por `patientId: PatientId` (referência por identidade). Cada um tem repositório próprio com sua transação.

---

**H-D2. VOs aceitam estado inválido — não-throws + sem validação de duplicatas/ranges**

- `Domain/Assessment/ValueObjects/HealthStatus/HealthStatus.swift:12-24` — `gestatingMembers` aceita `monthsGestation = -3` ou `99`; `memberDeficiencies` aceita mesmo memberId 2x; `responsibleCaregiverName` aceita vazio.
- `Domain/Assessment/ValueObjects/WorkAndIncome/WorkAndIncome.swift:11-22` — `individualIncomes` aceita mesmo `memberId` 2x.
- `Domain/Assessment/ValueObjects/EducationalStatus/EducationalStatus.swift:10-18` — `memberProfiles` aceita `memberId` duplicado (impossível semanticamente).
- `Domain/Registry/Entities/FamilyMember/FamilyMember.swift:30-47` — `birthDate` futuro aceito (contamina toda análise de idade downstream).

**Fundamentação:** Princípio "Inteligência no Domínio" do handbook v2.0. Vernon (p. 450): *"Aggregate is synonymous with transactional consistency boundary."* Um VO que aceita estado inválido empurra a invariante para a camada de aplicação — anti-pattern explícito.

**Sugestão:** todos viram `init throws` com validação de duplicatas, ranges e não-vazio. Adicionar erros tipados.

---

**H-D3. `removeMember` é DELETE físico — viola CRU/No Delete**

`Domain/Registry/Aggregates/Patient/PatientFamily.swift:47-61`

`familyMembers.remove(at:)` é exclusão física. Handbook v2.0 define CRU. Histórico se perde — restitui só via EventBus.

**Sugestão:** flag `isActive: Bool` em `FamilyMember`, métodos como `countMembers(inAgeRange:)` filtram por `isActive`. Histórico fica no agregado.

---

**H-D4. Force-unwraps frágeis em VOs (`try!` / `!`)**

- `Kernel/TimeStamp/TimeStamp.swift:19` — `static var now { try! TimeStamp(Date()) }`
- `Kernel/CPF/CPF.swift:27,73` — `FiscalRegion(rawValue:)!`, `Int(String(value[idx]))!`
- `Kernel/CEP/CEP.swift:24-27` — 3 `!` em region/distributionKind
- `Care/ValueObjects/ICDCode/ICDCode.swift:57` — `static let underInvestigation = try! ICDCode("Z03.9")`

**Fundamentação:** Fowler, *Refactoring*, p. 326 (Introduce Assertion):

> *"A better technique is to make the assumption explicit by writing an assertion."*

`try!` é assertion implícita não auditada. Refactor do init quebra silenciosamente em produção (crash em property initializer).

**Sugestão:** validar conversão no init e armazenar o resultado tipado (`let fiscalRegion: FiscalRegion`). Para constantes, `assert` em debug + fallback explícito em release.

---

**H-D5. `SocialBenefit` deduplica por `benefitName: String` — anti-Metadata-Driven**

`Domain/Assessment/ValueObjects/SocialBenefitsCollection/SocialBenefitsCollection.swift:26-31` + `SocialBenefit.swift:11`

`SocialBenefit.benefitName: String` em vez de `LookupId`. Duas escritas com "Bolsa Familia" e "BOLSA FAMÍLIA" (acento) escapam da deduplicação.

**Fundamentação:** Fowler, *Refactoring*, p. 68 (Primitive Obsession):

> *"Strings are particularly common petri dishes for this kind of odor. […] Representing such types as strings is such a common stench that people call them 'stringly typed' variables."*

Princípio Metadata-Driven do handbook v2.0 manda usar lookup.

**Sugestão:** `benefitTypeId: LookupId` (FK para `dominio_tipo_beneficio`) + `customLabel: String?` opcional quando o type tiver `exigeDescricao = true`.

---

**H-D6. Eventos confundem `occurredAt` (data do fato vs auditoria)**

`Domain/Registry/Aggregates/Patient/PatientFamily.swift:37` + 7 locais

Vários eventos usam `date.date` (data do appointment/referral/violation) como `occurredAt`, em vez de `now.date`. Confunde "quando o fato de negócio aconteceu" com "quando o evento foi emitido".

**Fundamentação:** Vernon (p. 382) — Domain Events são notificações de coisas que aconteceram **no domínio**. `occurredAt` deve ser tempo de emissão; tempo de fato de negócio é campo separado.

**Sugestão:** `occurredAt` sempre `now`. Adicionar `eventAbout: BusinessDate` ou similar no evento se necessário.

---

### 5.2 Application

**H-A1. `RegisterPatient` insere holder como `FamilyMember` com `birthDate = TimeStamp.now`**

`Application/Registry/RegisterPatient/Services/RegisterPatientCommandHandler.swift:131-137`

Quando `personalData == nil`, o titular vira `FamilyMember` recém-nascido. Contamina analytics silenciosamente.

**Sugestão:** `FamilyMember.birthDate: TimeStamp?` ou construtor explícito `FamilyMember.holderWithUnknownBirthDate(...)`. Decisão move para Domain.

---

**H-A2. Handlers de lifecycle não injetam `now` → não-testáveis**

`Application/Registry/{Admit,Discharge,Readmit,WithdrawFromWaitlist}/Services/*.swift`

Chamam `patient.discharge(reason:..., notes:..., actorId:...)` sem `now:`, deixando o domínio usar `.now`. Impossível testar `PatientDischargedEvent.occurredAt == X`.

**Fundamentação:** princípio de testabilidade via inversão de dependência (Martin, *Clean Architecture*, ainda que não indexado neste corpus, é o argumento padrão). Time é dependência.

**Sugestão:** `Clock` injetável (`@Sendable () -> TimeStamp`) no init do handler com default `{ .now }`. Passar `clock()` ao domínio em todo método.

---

**H-A3. Lookup validation duplicada literalmente em 8 handlers**

`Application/{Registry/RegisterPatient, Registry/AddFamilyMember, Registry/UpdateSocialIdentity, Care/RegisterIntakeInfo, Assessment/UpdateHealthStatus, Assessment/UpdateEducationalStatus, Assessment/UpdateWorkAndIncome}/Services/*.swift`

Cada um faz `guard try await lookupValidator.exists(id: typeId, in: "dominio_xxx") else { throw … }`. N round-trips ao banco quando 1 query "exists in many" resolveria.

**Fundamentação:** DRY (Hunt & Thomas, *Pragmatic Programmer*). Fowler — Extract Method.

**Sugestão:** `LookupBatchValidator` no Application com `validateAll(_ pairs: [(LookupId, table: String)]) async throws`. Uma única query `WHERE (id, tabela) IN (...)`. Cache opcional dentro do actor.

---

**H-A4. `PatientRegistrationService` engole erros não-`RegisterPatientError`**

`Application/Query/PatientRegistration/PatientRegistrationService.swift:39-42`

```swift
catch {
    throw PatientRegistrationError.registrationFailed(.persistenceMappingFailure(issues: [String(describing: error)]))
}
```

Mata o erro original (categoria/severidade/código). Sintoma: SRE recebe erro genérico quando precisa do detalhe.

**Sugestão:** propagar erro original (`throw error`) ou eliminar o Service (dead wrapper).

---

**H-A5. `WorkAndIncomeDTO` calcula `totalWorkIncome` no DTO da Query, duplicando `FinancialAnalyticsService`**

`Application/Query/PatientQueries/PatientQueryDTO.swift:62-65`

Cálculo `individualIncomes.reduce(0) { $0 + $1.monthlyAmount }` no DTO duplica `FinancialAnalyticsService.calculate`. Viola "Inteligência no Domínio".

**Sugestão:** DTO chama `FinancialAnalyticsService.compute(for: patient)`. Nunca recalcula.

---

**H-A6. `LookupAdmin` (Toggle/Update/Create) ignora `actorId` recebido no Command**

`Application/Configuration/LookupAdmin/Services/{Toggle,Update,CreateLookupItem}CommandHandler.swift`

Receber `actorId` no Command e não usar é interface enganosa. Tabela de lookup compartilhada por todos os pacientes precisa de audit.

**Sugestão:** propagar para `LookupRepository.toggleActive(in:id:actorId:)`. Persistir em coluna `last_modified_by` + audit_trail.

---

**H-A7. `AddFamilyMember.requiredDocuments` faz `compactMap` silencioso de inválidos**

`Application/Registry/AddFamilyMember/Services/AddFamilyMemberCommandHandler.swift:39`

`command.requiredDocuments.compactMap { RequiredDocument(rawValue: $0) }` aceita `["RG", "TYPO", "CPF"]` como `[.rg, .cpf]`. Cliente acha que registrou 3, ficaram 2, sem warning.

**Sugestão:** `try map { raw in guard let doc = RequiredDocument(rawValue: raw) else { throw .invalidRequiredDocument(raw) }; return doc }`.

---

### 5.3 IO/HTTP

**H-IO1. `AppErrorMiddleware` não captura erros do Vapor (404 de rota, 415, decoding)**

`IO/HTTP/Middleware/AppErrorMiddleware.swift:9-47`

`ErrorMiddleware.default()` não está adicionado. Decoding errors do `req.content.decode` viram `AbortError` (status 400) com `reason` que pode vazar nome de campo e tipo.

**Sugestão:** garantir middleware como primeiro da chain (já está). Sanitizar reasons em produção. Logar `request.method`, `request.url.path`, `actorId` em todo log de erro.

---

**H-IO2. Service-account introspection sem cache — derruba IdP**

`IO/HTTP/Middleware/JWTAuthMiddleware.swift:33-53`

Tokens de SA batem no introspect endpoint a cada request. Sob carga (~100 req/s mesmo SA) você multiplica latência, derruba IdP, dependência síncrona crítica.

**Sugestão:** TTL cache (`actor`) keyed por `sha256(token)` com TTL ≤ `exp - now` (piso curto, 60s), invalidação em rejeição. Diferenciar 503 ("introspection upstream unavailable") de 401 ("token invalid").

---

**H-IO3. JWKS sem rotação automática em runtime**

`IO/HTTP/Bootstrap/configure.swift:158-190`

JWKS é buscado UMA vez no boot. Key rotation da Authentik (rotina 30-90 dias) quebra silenciosamente todo token novo. Vapor JWT **não** tem refresh automático.

**Sugestão:** background task que re-busca JWKS a cada 15min e faz `app.jwt.keys.add(jwksJSON:)`. Observar contagem de "kid not found" como sinal de drift.

---

**H-IO4. Audit-trail endpoint não filtra `aggregate_type` → vaza eventos cross-aggregate**

`IO/HTTP/Controllers/PatientController.swift:212-226`

Filtra por `aggregate_id == patientUUID` mas não por `aggregate_type == 'patient'`. UUID coincidente vaza eventos. Sem check de existência do paciente → oracle de presença/ausência.

**Sugestão:** `where("aggregate_type", .equal, "patient")` + 404 explícito se paciente não existe.

---

**H-IO5. `ListPatients` não filtra por `orgId` do usuário**

`IO/HTTP/Controllers/PatientController.swift:31-48`

`AuthenticatedUser` carrega `orgId` (ADR-031) mas nada usa. Cross-tenant leak em multi-tenant Authentik.

**Sugestão:** propagar `user.orgId` para a query e filtrar no SQL. Teste explícito cross-tenant.

---

**H-IO6. `AnyJSON` e `AnySendable` com `@unchecked Sendable` armazenando `Any`**

`IO/HTTP/DTOs/ResponseDTOs.swift:619-664` + `shared/Error/AppError.swift:125-155`

`Any` em propriedade não-`let-Sendable` quebra strict concurrency. Data race silencioso possível sob carga.

**Sugestão:** `enum AnyJSON: Sendable { case object([String: AnyJSON]), array([AnyJSON]), string(String), number(Double), bool(Bool), null }`. Remove `@unchecked`.

---

**H-IO7. Business validation em controller (CrossValidator/MetadataValidator)**

`IO/HTTP/Controllers/AssessmentController.swift:48-49,75,122-128` + `ProtectionController.swift:23-28,56-60`

`CrossValidator` faz fetch do agregado + check de sex/gestação. `MetadataValidator` consulta SQL direto. Ambos são lógica de domínio rodando em controller, e `MetadataValidator` recebe `db: any SQLDatabase` direto — anti Clean Architecture.

**Fundamentação:** Princípio "Inteligência no Domínio". Vernon (p. 450): regras de negócio defendidas pelo agregado.

**Sugestão:** mover `MetadataValidator` para porta em Application (`BenefitMetadataValidating`) com implementação SQLKit em IO. `CrossValidator` vira método estático em `HealthStatus` ou Domain Service. Controllers ficam puros.

---

### 5.4 IO/Persistence + EventBus + shared

**H-P1. `deleteAndInsert` em todos os child tables com UUIDs novos a cada save**

`IO/Persistence/SQLKit/SQLKitPatientRepository.swift:256-266` + `Mappers/PatientDatabaseMapper.swift:391,407,421,437,450,465,479,506`

Cada `save` deleta filhos e re-insere com **UUIDs novos** (`UUID()` inline no mapper). Consequências:
1. Audit trail não rastreia mutação atômica
2. FKs externas (se algum dia) quebram em todo save
3. Anti-CRU (perde histórico)
4. Cada save = N DELETEs + N INSERTs por tabela filha

Apenas `placement_registries` faz certo (preserva `r.id` — linha 492).

**Sugestão:** todos seguem o padrão `placement_registries` — IDs estáveis no domínio + upsert com `ON CONFLICT`.

---

**H-P2. `loadAggregate` é N+1 por design — 13 SELECTs sequenciais**

`IO/Persistence/SQLKit/SQLKitPatientRepository.swift:268-302`

Em latência média 3ms/query, isto é 40ms de overhead por `save` (que faz `find → mutate → save`). Em pico, satura pool.

**Sugestão:** paralelizar com `async let` (ganho imediato 5-10x) ou consolidar em query única com `LEFT JOIN LATERAL` + JSON aggregation por tabela filha.

---

**H-P3. Force-unwrap de UUID em ~25 sites do mapper**

`IO/Persistence/SQLKit/SQLKitPatientRepository.swift:61,72,128,235,236,244` + `Mappers/PatientDatabaseMapper.swift` (16 sites)

Padrão `UUID(uuidString: x.description)!`. Em dado sujo, crash do processo Vapor inteiro.

**Sugestão:** expor `var uuid: UUID { get }` direto no VO do domínio. Eliminar `UUID(uuidString:)!` da camada IO.

---

**H-P4. Mapping SQL→Conflict só olha código `23505`, ignora `23503` (FK), `23514` (CHECK)**

`IO/Persistence/SQLKit/SQLKitPatientRepository.swift:48-57`

Outros constraint violations escapam como `PSQLError` cru → 500 sem código estruturado. FK violations são comuns (lookup desativado enquanto paciente é editado).

**Sugestão:** mapear toda classe `23xxx` para subtipos de `PersistenceConflictError` (`fkViolation`, `checkViolation`, `uniqueViolation`).

---

**H-P5. Cursor pagination ordena por UUID v4 (aleatório)**

`SQLKitPatientRepository.swift:129,133`

`WHERE id > ? ORDER BY id`. UUID v4 é aleatório → ordem arbitrária para o usuário. Falta `created_at` (sem migration).

**Sugestão:** adicionar `created_at TIMESTAMPTZ DEFAULT NOW()` em migration, ordenar por `(created_at DESC, id DESC)`.

---

**H-P6. PII em log do outbox warning**

`IO/Persistence/SQLKit/Outbox/SQLKitOutboxRelay.swift:141-145`

```swift
logger.warning("Failed to process outbox event", metadata: [
    "error": "\(error)"   // ← pode conter o payload com CPF, nome, endereço
])
```

`DecodingError` descreve o JSON em `error`. Eventos contêm PII. LGPD blocker.

**Sugestão:** sanitizar — logar `error.localizedDescription` e `String(reflecting: type(of: error))`, nunca `"\(error)"` bruto.

---

**H-P7. JSON encoder/decoder sem estratégia consistente entre Mapper e NATS**

`Mappers/PatientDatabaseMapper.swift:4-5` (default) vs `NATSEventPublisher.swift:41` (`.iso8601`)

Mesmo evento, encoding diferente entre outbox (numérico) e NATS publish (ISO). Quem consome via NATS vê ISO, quem lê `audit_trail.payload` vê Double. Bug invisível.

**Sugestão:** config central `JSONCodec.default` com `dateEncodingStrategy = .iso8601` aplicada em todo lugar.

---

## 6. Achados MEDIUM

Compactado em tabela. Sugestões disponíveis nos relatórios per-camada (anexos).

| Código | File:Line | Sintoma | Sugestão |
|---|---|---|---|
| M-D1 | `Domain/Registry/Aggregates/Patient/PatientLifecycle.swift:89` | `reconstitute` default `status: .waitlisted` | Remover default — repositório deve passar sempre |
| M-D2 | `Domain/Assessment/ValueObjects/SocioEconomicSituation/SocioEconomicSituation.swift:35-77` | `incomePerCapita` é input, não derivado | Construir recebendo `memberCount`, derivar per capita |
| M-D3 | `Domain/Configuration/LookupItemMetadata.swift:6-8` | Props em português (`exigeRegistroNascimento`) | Renomear para `requiresBirthCertificate` |
| M-D4 | `Domain/Configuration/LookupRequestRecord.swift:13,14` | `Date` cru, não `TimeStamp` | Migrar para TimeStamp |
| M-D5 | `Domain/Configuration/LookupRepository.swift:7-23` | Port aceita `table: String` | Tipar com VO `LookupTableName(_:) throws` |
| M-D6 | `Domain/Kernel/Address/Address.swift:83-117` | `isHomeless==true && cep != nil` é aceito | Validar incompatibilidade |
| M-D7 | `Domain/Registry/Entities/FamilyMember/FamilyMember.swift:30-47` | Falta `Hashable` em vários VOs | Adicionar conformance |
| M-D8 | `Domain/Protection/Entities/PlacementHistory.swift:31-42` | `reason: String` aceita whitespace | Trim + validate not empty |
| M-A1 | `Application/{many}/Error/*MapperError.swift` | mapError em arquivo separado, fora do handler | Mover inline ou renomear para `Handler+Mapping.swift` |
| M-A2 | `Application/Registry/AddFamilyMember/Error/AddFamilyMemberErrors.swift:20` | `codePrefix = "APP"` (genérico) | `AFM` |
| M-A3 | `Application/Registry/RegisterPatient/Services/RegisterPatientCommandHandler.swift:118-127` | TOCTOU: 3 `exists` antes do save | Confiar em `PersistenceConflictError` + single query |
| M-A4 | `Application/Registry/LinkPersonId/Services/LinkPersonIdCommandHandler.swift:11-18` | Não publica evento, instancia próprio Logger | Alinhar à convenção; injetar Logger |
| M-A5 | `Application/{many}/Command/*Command.swift` | Comandos só com `String/Date`, parse repete em 21 handlers | Aceitar VOs nos Commands ou helper genérico de parse |
| M-A6 | `Application/Configuration/LookupRequest/Services/CreateLookupRequestCommandHandler.swift:32` | `command.codigo.uppercased()` é regra do VO | Mover para `LookupItemCode.init(_:)` |
| M-A7 | `Application/Assessment/UpdateHousingCondition/Services/UpdateHousingConditionCommandHandler.swift:18-38` | 7 `guard let X = rawValue` no handler | Helper `parseEnum<E>(_:_:)` |
| M-A8 | `Application/Query/PatientQueries/GetPatientByPersonIdQueryHandler.swift:5` | Recebe `personId: String`, sibling recebe `PatientId` | Padronizar — Controller faz parse |
| M-IO1 | `IO/HTTP/Bootstrap/ServiceContainer.swift` | 30+ campos no Service Locator | Per-handler `.live(deps:)` em Application storage |
| M-IO2 | `IO/HTTP/Middleware/RoleGuardMiddleware.swift` (opt-in por rota) | Rota sem `RoleGuard` = qualquer user autenticado acessa | Default-deny + lint test |
| M-IO3 | `IO/HTTP/Auth/AuthenticatedUser.swift:35-37` | `roles.contains("superadmin")` hardcoded | `enum SystemRole` em Domain/Configuration |
| M-IO4 | `IO/HTTP/Bootstrap/configure.swift:90-95` | `actorId` vindo de NATS sem validação de origem | Prefixar com origem (`people-context:`) ou trust boundary explícita |
| M-IO5 | `IO/HTTP/Bootstrap/configure.swift:8` | Production fallback condicional em env não-set | Fail-closed: assumir produção, exigir `ENVIRONMENT=development` para liberar fallbacks |
| M-IO6 | `IO/HTTP/Middleware/JWTAuthMiddleware.swift:5,9` | Public paths comparados por exact match | `lowercased()` + considerar regex/marker |
| M-IO7 | `IO/PeopleContext/PeopleContextPersonValidator.swift:23` | `URL(string:)!` force-unwrap | Validar `baseURL` no init |
| M-IO8 | `IO/HTTP/Controllers/LookupController.swift:155-176` | Admin aprova próprio request (auto-approve) | `request.requestedBy != actorId` ou ADR explicitando |
| M-P1 | `shared/Error/AppError.swift:7-9` | Equatable compara só `code/bc/module` | Comparar por `id` apenas, ou método separado `sameKind` |
| M-P2 | `shared/Error/AppError.swift:125-155` | `AnySendable.value: Any` com `@unchecked Sendable` | Enum fechado |
| M-P3 | `IO/Persistence/SQLKit/Migrations/2026_03_08_NormalizeSchema.swift:300` | Revert "no data migration" | `fatalError` em revert de migration destrutiva |
| M-P4 | `IO/Persistence/SQLKit/Outbox/SQLKitOutboxRelay.swift:11,68` | Polling interval fixo 1s, sem backoff | Adaptive ou `LISTEN/NOTIFY` |
| M-P5 | `IO/Persistence/SQLKit/Migrations/SQLKitMigrationRunner.swift:45-46` | `migrations_meta` sem `applied_at`/`checksum` | Adicionar colunas (compliance healthcare) |
| M-P6 | `IO/Persistence/SQLKit/SQLDatabaseTransaction.swift:28-39` | Fallback "menos seguro mas funcional" | Remover fallback ou `precondition(false)` |
| M-P7 | `IO/Persistence/SQLKit/Models/PatientDatabaseModels.swift:183-190` | `source: String` com valores "SOCIOECONOMIC"/"WORK_AND_INCOME" sem enum | Enum + CHECK constraint |
| M-P8 | `IO/Persistence/SQLKit/SQLKitPatientRepository.swift:271-284` | Nenhum SELECT de child tem `ORDER BY` | `.orderBy("date" or "id")` em todos os 13 selects |
| M-P9 | `IO/Persistence/SQLKit/SQLKitLookupAdminRepository.swift:11-25,55-71` | `referenceMap` com 5 entradas vazias → toggle nunca detecta uso | Normalizar `social_benefits.benefit_name`/`violation_type` para FK |
| M-P10 | `IO/Persistence/SQLKit/Outbox/SQLKitOutboxRelay.swift:130,170-177` | `aggregate_type: "Patient"` hardcoded | DomainEvent expõe `aggregateType` direto |
| M-P11 | `shared/Domain/DomainEventRegistry.swift:6` | Singleton mutável global | Injetar por DI no relay |

---

## 7. Achados LOW / Nitpick

Lista enxuta — polimento, idiomático, naming, docs:

**Domain:**
- `CPF.fiscalRegion` é computed que faz lookup a cada chamada — cachear no init
- `SocialBenefit` existe em paralelo a `WorkAndIncome.socialBenefits` — caminho duplo confuso
- `PatientStatus.discharged` usado para "desligado" e "removido da fila" — considerar `case withdrawn` separado
- `PatientError.initialIdIsRequired` e `initialPersonIdIsRequired` — código morto (não usados)
- `RightsViolationReport.actionsTaken: String` aceita `""` sem reclamar — documentar ou validar
- `Address.state: String` validado contra `validStates: Set<String>` hardcoded — virar `dominio_uf` lookup (médio prazo)
- `NIS` não valida dígito verificador (só comprimento) — inconsistente com CPF/CNS
- Comentários em português + inglês misturados — padronizar
- Naming SQL snake_case vazando em Swift props (`first_name`, `cns_qr_code` etc.) em `PatientDatabaseModels.swift` — `CodingKeys` ou `keyDecodingStrategy = .convertFromSnakeCase`

**Application:**
- `AddFamilyMember`: `relationship: String` + `prRelationshipId: String` — naming desalinhado
- `LifecycleCommand` protocol unificaria Admit/Discharge/Readmit/Withdraw
- `PatientQueryDTO.fullName`: monta `"\(first) \(last)"` — formatação no DTO; mover para View
- `UpdateSocialHealthSummaryCommandHandler`/`UpdateCommunitySupportNetworkCommandHandler`: mapError inline (inconsistente)
- `RegisterPatientError` mistura erros de domínio com infra — split em nested enums
- `CreateReferralCommandHandler.swift:19`: `ProfessionalId()` aleatório se não informado — silent bug
- `ReportRightsViolationCommandHandler.swift:18`: `ViolationReportId()` arbitrário do cliente — idempotência?
- `LookupAdmin/UpdateLookupItemCommandHandler:24`: `repository.updateDescription` não valida vazio
- `Application/Registry/AddFamilyMember/Error/AddFamilyMemberErrors.swift` (plural) vs todos outros singulares

**IO/HTTP:**
- `PatientController.swift:65-66`: `do/catch` perde root cause — `catch { throw Abort(...).with(cause: error) }`
- `PatientController.swift:204`: `UUID(uuidString:)` direto em controller (deveria parse via VO)
- `PatientController.swift:75-77`: `try? PersonId(personId)` engole erro útil
- Boilerplate `req.extractActorId()` + `parameters.require()` — helper `req.parsePatientCommand(_:)`
- `RequestDTOs.swift`: DTOs sem `Sendable` explícito
- `ResponseDTOs.swift:286`: `cpf?.formatted` retorna com pontos/hífen — documentar contrato
- `HealthController.swift:11-13`: liveness/readiness sem rate-limit
- `LookupController.swift:55-61`: decoding manual em loop — preferir model `Codable`
- `LookupController.swift:32`: `PATCH toggle` semanticamente é POST de ação
- `OIDCJWTPayload.swift:172-198`: Singleton mutável global (test-only reset documentado) — considerar `TaskLocal`
- `configure.swift:107-109`: `personValidator` opcional desabilita C1 se env não setada — em prod, obrigatório
- `configure.swift:226-238`: bloco "Token Introspection" usa `ZITADEL_*` env (legado) — renomear para `OIDC_INTROSPECT_*` antes do Sprint 6 cleanup
- Timeouts inconsistentes — `PeopleContextPersonValidator` 5s, introspector nenhum, JWKS retry mas não timeout per-call

**Persistence/EventBus/shared:**
- Severity `.error` colide com `Error` protocol — `.serviceError`/`.failure`
- `NATSError`/`DomainEventError` não conformam `AppErrorConvertible`
- `NATSEventSubscriber.start()` sem `Task.isCancelled` check — graceful shutdown não funciona
- `NATSEventSubscriber.parseURL` quebra com `nats://user:pass@host:port` (não usa `URLComponents`)
- Comentários `// ──────────` decorativos em migrations — preferir `// MARK: -`
- `print("⏳ Applying migration:...")` em `SQLKitMigrationRunner` — usar `Logger`
- `LookupRequestStatus(rawValue: status) ?? .pendente` esconde corrupção como "pendente"
- `Migration` protocol e runner no mesmo `Migrations/` — separar `Engine/` de `Definitions/`

---

## 8. Padrões Positivos (preservar e propagar)

A revisão também identifica disciplina notável em pontos críticos. Vale documentar para que evolução futura não regrida:

1. **`init(_:) throws` consistente em quase todos os VOs** (CPF, CEP, CNS, NIS, RGDocument, LookupId, PersonId, ProfessionalId, PatientId, Address, PersonalData, SocialBenefit, Diagnosis, ICDCode) com **normalização** (trim, upper-snake-case, autoDot, removeNonDigits) e **erros tipados**. Esse é exatamente o padrão "Smart Constructor" recomendado em DDD/FP.

2. **`AppErrorConvertible` em todos os erros de domínio** com código estruturado (`PAT-NNN`, `CEP-NNN`), severity, http status, observability category. Disciplina rara — facilita observability e contratos com cliente.

3. **Defense-in-depth no JWT** — `OIDCJWTPayloadBootstrap` registra validators globalmente; `verify(using:)` valida iss/aud/exp/nbf em todo codepath. Comentário CRITICAL-1 explicando o porquê é exemplar.

4. **Privilege escalation guard no introspect** (`JWTAuthMiddleware.swift:44-51`) rejeitando `superadmin` vindo do introspection — exatamente o tipo de defense-in-depth que diferencia produção de POC.

5. **Allowlist `AllowedLookupTables.all`** antes de `.from(tableName)` — bloqueia table-name injection com pattern simples e correto.

6. **Transactional Outbox real** (`SQLKitPatientRepository.save:14-47`) — agregado + outbox na mesma transação. Ponto mais maduro do código.

7. **`PersistenceConflictError.uniqueViolation` preserva `constraint`** para handler mapear contextualmente — boa separação Domain/IO.

8. **Analytics services puros** (`FinancialAnalyticsService`, `EducationAnalyticsService`, `HousingAnalyticsService`, `FamilyAnalytics`) — `static func`, sem dep, fácil teste. Aplicação correta do princípio "Inteligência no Domínio".

9. **CRU em status do paciente** — `discharge`/`readmit`/`admit`/`withdraw` em vez de delete. Mantém histórico vivo.

10. **Repository contracts como `protocol`** em `Domain/Registry/Repository/PatientRepository.swift` — Domain define a porta, IO implementa. PoP respeitado.

11. **Sequência canônica respeitada** (parse → validate → fetch → domain → persist → publish) em ~95% dos 21 handlers.

12. **`actor` para Command, `struct` para Query** — convenção do handbook respeitada universalmente.

13. **`PersonExistenceValidating` opcional** no RegisterPatient — bom uso de port com graceful degradation enquanto people-context ainda não é mandatório.

14. **`Sendable` correto via inheritance** (`Command: Sendable`) — sem necessidade de declarar em cada Command.

15. **`PatientRepository.find(byId:)` retorna `Patient?`** — uso de Optional em vez de throws para "not found".

16. **`safeContext` separado de `context`** no `AppError` — arquitetura correta para controlar PII em respostas.

17. **JWKS load paralelo** + retry — boa otimização documentada.

18. **`Sendable` aplicado em VOs, payloads, container** — strict concurrency respeitado no geral (exceto `AnyJSON`/`AnySendable`).

19. **Nbf validation explícita** — RFC 7519 compliance que muitos serviços esquecem.

20. **`StandardResponse<T>`** envelopa todas as respostas com `meta.timestamp` consistentemente.

21. **Audit-trail derivado do `JWT.sub`** via extension dedicada (`Request+ActorId.swift`) — single source of truth (ADR-023).

22. **Índice parcial no outbox** `WHERE processed_at IS NULL` (`AddPerformanceIndexes:18-22`) — demonstra entendimento real de performance.

23. **Audit trail derivada do outbox** (`SQLKitOutboxRelay:125-167`) — uma única fonte de verdade alimenta dois consumidores.

24. **`@unchecked Sendable` justificado por comentário** no `NATSMessageHandler` (`NATSEventSubscriber:96-98`) — exatamente o tipo de doc que estricts pedem.

25. **CSV-driven migrations seedam dados oficiais** com referência a normas (CadÚnico, IBGE/MEC, Tipificação Nacional SUAS) — boa rastreabilidade.

26. **`PoP` em `CommandHandling<C>` / `ResultCommandHandling<C>`** com associated type opaco é o uso idiomático Swift 6.

27. **Idempotência em `LinkPersonIdCommandHandler`** — trata "já vinculado" com no-op silencioso e log informativo. Correto para handler de eventos externos.

---

## 9. Roadmap de Remediação (3 sprints)

### Sprint A — Segurança crítica e perda de dados (1-2 semanas)

**Objetivo:** eliminar os bugs que comprometem produção multi-instância e/ou abrem bypass de segurança.

| Item | Critical refs | Esforço |
|---|---|---|
| 1. PeopleContext tri-state + Bearer forwarding (ADR-023) + remover fail-open | C1 | 2-3 dias |
| 2. Outbox: `FOR UPDATE SKIP LOCKED` + `audit_trail.id` distinto do `message.id` + `Nats-Msg-Id` header | C2, C10 | 2 dias |
| 3. Optimistic lock no `save` usando coluna `version` existente; mapeamento `PersistenceConflictError.optimisticLockFailed` | C3 | 2 dias |
| 4. `SecurityHeadersMiddleware` + `defaultMaxBodySize = "256kb"` no boot | C5 | 1 dia |
| 5. Helper `mapUniqueViolation` + retrofit em todos os 21 handlers + lint test | C6 | 3 dias |
| 6. `NATSEventPublisher` substituído por cliente oficial OU instalar handler de PING/PONG | C9 | 1-2 dias |

**Saída esperada:** ADR-032 (Outbox at-least-once contract), ADR-033 (PeopleContext tri-state), tag `v0.6.0`.

### Sprint B — Arquitetura (2-3 semanas)

**Objetivo:** quebrar débito estrutural que dificulta evolução.

| Item | Refs | Esforço |
|---|---|---|
| 7. Unificar `EventSourcedAggregate: EventSourcedAggregateInternal`; resolver `OutboxEventBus` (Opção A: remover do handler, documentar como ADR) | C4, C7 | 2 dias |
| 8. Promover `Assessment` a agregado próprio; mover eventos cross-BC para seus contexts; reduzir `Patient` a Registry+lifecycle | H-D1 | 1 semana |
| 9. `ApproveLookupRequest`: `UnitOfWork` cross-repository | C8 | 2 dias |
| 10. Mover `CrossValidator`/`MetadataValidator` para Application (ports) ou Domain | H-IO7 | 2 dias |
| 11. `ServiceContainer` → factories per-handler em Application storage | M-IO1 | 3 dias |
| 12. JWKS refresh em background + cache de introspection (TTL) | H-IO2, H-IO3 | 2 dias |
| 13. `deleteAndInsert` → upsert com IDs estáveis em todos os child tables | H-P1 | 3 dias |
| 14. `loadAggregate` paralelizado com `async let` | H-P2 | 1 dia |

**Saída esperada:** ADR-034 (Aggregate decomposition), ADR-035 (UoW pattern), tag `v0.7.0`.

### Sprint C — Testabilidade e polimento (2 semanas)

**Objetivo:** elevar testabilidade e reduzir boilerplate.

| Item | Refs | Esforço |
|---|---|---|
| 15. `Clock` injetável em todos os handlers (eliminar `Date()`/`.now` hardcoded) | H-A2 | 2 dias |
| 16. `LookupBatchValidator` (1 query para N lookups, cache opcional) | H-A3 | 2 dias |
| 17. `RoleGuardMiddleware` default-deny + lint check de rotas | M-IO2 | 2 dias |
| 18. Substituir `UUID(uuidString:)!` no mapper por API tipada do domínio | H-P3 | 1 dia |
| 19. `LookupItemCode` normaliza no init (remover `.uppercased()` espalhado) | M-A6 | meio dia |
| 20. Mapping SQL `23xxx` completo → `PersistenceConflictError.{fk,check,unique}Violation` | H-P4 | 1 dia |
| 21. `AnyJSON`/`AnySendable` → enum fechado Sendable | H-IO6, M-P2 | 1 dia |
| 22. Adicionar `created_at` + cursor ordering temporal | H-P5 | 1 dia |
| 23. JSON encoder/decoder central (`JSONCodec.default`) | H-P7 | meio dia |
| 24. Sanitização de log no relay (LGPD) | H-P6 | meio dia |
| 25. Audit-trail filter `aggregate_type` + 404 explícito | H-IO4 | meio dia |
| 26. `ListPatients` com `orgId` (cross-tenant) | H-IO5 | 1 dia |

**Saída esperada:** ADR-036 (Clock injection convention), tag `v0.8.0`.

---

## 10. Bibliografia

Indexada via `acdg-skills` MCP em `/Users/.../skills_base/shared-references/`:

- **DDD:** Evans, Eric. *Domain-Driven Design: Tackling Complexity in the Heart of Software*. Addison-Wesley, 2003. (`ddd--evans-livro-azul.md`)
- **DDD:** Vernon, Vaughn. *Implementing Domain-Driven Design*. Addison-Wesley, 2013. (`ddd--vernon-livro-vermelho.md`)
- **Clean Code:** Fowler, Martin. *Refactoring: Improving the Design of Existing Code*, 2nd ed. Addison-Wesley, 2018. (`refactoring--martin-fowler.md`)
- **Clean Code:** Martin, Robert C. *Código Limpo: Habilidades práticas do Agile Software*. Alta Books, 2009. (`codigo-limpo--uncle-bob.md`)
- **Architecture:** Newman, Sam. *Building Microservices*, 2nd ed. O'Reilly, 2021. (`building-microservices--sam-newman.md`)
- **Database:** Oracle. *MySQL 8.4 Reference Manual* (`mysql-refman-8.4--oracle.md`)
- **Security:** OWASP. *OWASP AI Exchange* (`owasp-ai-exchange.md`)

**Handbook interno:**
- `handbook/architecture/README.md` — Arquitetura v2.0 (5 princípios + regras de ouro)
- `handbook/architecture/DECISIONS.md` — Índice de ADRs
- `handbook/architecture/DECISIONS/ADR-023-*` — BFF adapter Bearer forwarding (referenciado no frontend)
- `handbook/architecture/DECISIONS/ADR-027-*` + `ADR-031-*` — Multi-issuer OIDC
- `handbook/IMPLEMENTATION_PLAN.md` — Gaps G1-G17

**Referências externas relevantes (não indexadas no acdg-skills, mas citadas):**
- IETF RFC 7519 — JSON Web Token (JWT)
- IETF RFC 6749 — OAuth 2.0
- OWASP ASVS L1/L2 — Application Security Verification Standard
- Hector Garcia-Molina, Kenneth Salem. *Sagas*. ACM SIGMOD, 1987 (citado por Newman p. 229)
- Chris Richardson. *Microservices Patterns* (Transactional Outbox, Idempotent Consumer)

---

## Apêndice A — Sumário de Severidade

| Severidade | Quantidade | Impacto principal |
|---|---|---|
| **CRITICAL** | 10 | Bypass de invariante, perda de dados, race condition, dead code mascarando bug |
| **HIGH** | 20 | Débito técnico que bloqueia evolução, smells de god aggregate, performance |
| **MEDIUM** | 30 | Inconsistência de padrões, boilerplate evitável, primitive obsession |
| **LOW / Nitpick** | ~30 | Naming, comentários, idiomatic |
| **Positivos** | 27 | A preservar — disciplina notável em segurança, VOs, error handling |

**Total de achados:** ~117 (excluindo positivos).

---

## Apêndice B — Cobertura por Camada

| Camada | CRITICAL | HIGH | MEDIUM | LOW |
|---|---|---|---|---|
| Domain | 0 | 6 | 8 | 9 |
| Application | 0 | 7 | 8 | 9 |
| IO/HTTP + PeopleContext | 5 | 7 | 8 | 13 |
| IO/Persistence + EventBus | 4 | 7 | 11 | 8 |
| shared (Domain/Protocols, Error, Ports) | 1 | 0 | 3 | 3 |

A camada **IO/HTTP** concentra metade dos CRITICAL (vulnerabilidades de segurança + cliente PeopleContext) e exige Sprint A dedicado. A camada **Domain** não tem CRITICAL mas tem 6 HIGH centrados no god aggregate Patient — Sprint B.

---

*Fim do relatório.*
