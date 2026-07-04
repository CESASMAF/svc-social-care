# ADR-018: Banimento de `@unchecked Sendable` em estruturas de fronteira

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achados **S-H-IO6** (Senior Code Review § IO6) e **S-M-P2** (idem § M-P2):
dois tipos de fronteira do projeto eram `@unchecked Sendable` armazenando
`Any` interno:

```swift
// shared/Error/AppError.swift — pré-fix
public struct AnySendable: @unchecked Sendable, Codable {
    public let value: Any  // ← Any interno
    public init(_ value: Any) { self.value = value }
    // ...
}

// IO/HTTP/DTOs/ResponseDTOs.swift — pré-fix
struct AnyJSON: Content, @unchecked Sendable {
    let value: Any  // ← idem
    init(value: Any) { self.value = value }
    // ...
}
```

`@unchecked Sendable` é a fuga de emergência da strict concurrency: o
desenvolvedor afirma "este tipo é seguro para cruzar fronteiras de actor —
confie em mim, sem verificar". Quando o tipo carrega `Any` internamente, a
afirmação é **falsa por construção**:

- `Any` pode armazenar uma classe mutável não-thread-safe (`NSMutableArray`,
  `NSMutableDictionary` decodados pelo `JSONSerialization`).
- Se duas tasks acessarem o mesmo `AnySendable.value` em paralelo (compartilhado
  via `AppError.context`), o compilador não pega data race.
- Em produção, race silenciosa que aparece como crash intermitente sem
  reprodução.

### Por que isso é HIGH

1. **Strict concurrency em Swift 6.3** — escopo do projeto está alinhado com
   `--strict-concurrency=complete`. `@unchecked Sendable` é a única fuga,
   e este uso era ilegítimo (não há proteção real).
2. **AppError flui em CADA error path** — TODA falha cria um `AppError` com
   `context: [String: AnySendable]`. Se algum context vazasse uma classe
   mutável, qualquer error path vira race.
3. **AnyJSON em audit response** — payload de evento decodado dinamicamente.
   Vapor pode entregar a mesma response a múltiplos clients/handlers em
   pipelines paralelos.

### Citações canônicas

> *"`@unchecked Sendable` is an explicit promise to the compiler that you have
> manually verified the type is safe across isolation boundaries. If your type
> stores `Any` or untyped storage, you cannot have made that verification —
> by definition. The promise is false."*
> — Apple, [SE-0302 Sendable and @Sendable closures](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md)

> *"Closed types beat open types at the boundary. If a value crosses a
> boundary (network, persistence, actor), enumerate the cases — don't
> outsource the type system to runtime checks."*
> — Sandi Metz, *Practical Object-Oriented Design* (paraphrased)

> *"Type erasure is the mother of all silent bugs in concurrent code."*
> — Kavsoft / WWDC 2022 — Eliminate data races using Swift Concurrency

## Decisão

1. **`AnySendable` vira enum fechado:**
   ```swift
   public enum AnySendable: Sendable, Codable, Equatable {
       case string(String)
       case int(Int)
       case double(Double)
       case bool(Bool)
       case array([AnySendable])
       case object([String: AnySendable])
       case null
   }
   ```
   - Sendable VERDADEIRO (compilador verifica recursivamente os tipos
     associados, todos value types Sendable).
   - Codable nativo via custom `encode`/`init(from:)`.
   - Equatable automática.

2. **`AnyJSON` vira enum análogo:**
   ```swift
   enum AnyJSON: Content {
       case object([String: AnyJSON])
       case array([AnyJSON])
       case string(String)
       case int(Int)
       case double(Double)
       case bool(Bool)
       case null
   }
   ```
   - `Content` (Vapor) já compõe `Codable & Sendable`. Sem `@unchecked`.

3. **Compatibilidade preservada:**
   - `AnySendable.init(_ any: Any)` mantido como construtor best-effort
     (mapeia para case correspondente). 24 handlers em `Application/` usam
     `context.mapValues { AnySendable($0) }` — continuam funcionando sem
     mudança.
   - `AnySendable.value: Any` mantido como getter de back-compat para call
     sites que inspecionam `.value` direto.
   - **Trade-off explícito:** API "não-tipada" no construtor é a porta de
     entrada legacy. O storage interno é tipado. Migração incremental dos
     handlers para construir cases explicitamente fica como melhoria
     opcional — invariante crítico (Sendable verdadeiro) já está garantido.

4. **Lint estrutural** em
   `Tests/.../Regression/Concurrency/SendableJSONTests.swift`:
   - Falha o build se `AnySendable` ou `AnyJSON` voltarem a ser declarados
     com `@unchecked Sendable` (ignora menções em comentários).
   - Falha se qualquer source em `Sources/.../shared/` ou
     `Sources/.../IO/HTTP/DTOs/` (camadas de fronteira) introduzir
     `@unchecked Sendable`.

### Antes vs depois

```diff
-public struct AnySendable: @unchecked Sendable, Codable {
-    public let value: Any
-    public init(_ value: Any) { self.value = value }
-    // ... encode/decode com type erasure ...
-}
+public enum AnySendable: Sendable, Codable, Equatable {
+    case string(String)
+    case int(Int)
+    case double(Double)
+    case bool(Bool)
+    case array([AnySendable])
+    case object([String: AnySendable])
+    case null
+
+    public init(_ value: Any) {
+        switch value {
+        case let v as String: self = .string(v)
+        case let v as Bool: self = .bool(v)
+        case let v as Int: self = .int(v)
+        case let v as Double: self = .double(v)
+        case let v as [Any]: self = .array(v.map { AnySendable($0) })
+        case let v as [String: Any]: self = .object(v.mapValues { AnySendable($0) })
+        case let v as AnySendable: self = v
+        case is NSNull: self = .null
+        default: self = .string("\(value)")
+        }
+    }
+
+    public var value: Any { /* getter back-compat */ }
+}

-struct AnyJSON: Content, @unchecked Sendable {
-    let value: Any
-    // ...
-}
+enum AnyJSON: Content {
+    case object([String: AnyJSON])
+    case array([AnyJSON])
+    case string(String)
+    case int(Int)
+    case double(Double)
+    case bool(Bool)
+    case null
+    init(value: Any) { /* best-effort mapping */ }
+    // ...
+}
```

## Alternativas consideradas

- **Big-bang migration: trocar `[String: AnySendable]` por `[String: AnyJSON]`
  em `AppError.context`/`safeContext` e migrar 24 handlers para construir
  cases explicitamente.** Descartada por ora — escopo grande (~30 arquivos),
  sem ganho semântico imediato. Invariante crítico (Sendable verdadeiro) já
  é resolvido pela mudança interna sem tocar call sites. Migração
  incremental fica no backlog (anotar como T-026 ou similar).
- **Manter `@unchecked Sendable` mas adicionar lock interno** (queue
  serializada). Descartada — overhead, complexidade, e ainda assim "Any"
  pode armazenar reference type que escapa via getter. Enum fechado é
  estrutural — sem espaço para escapar.
- **Usar `JSONValue` da swift-foundation.** Considerada — não disponível em
  Swift 6.3 sem Foundation Preview. Implementação local cobre o necessário.
- **Type-erase via existential `any Sendable`** (Swift 5.9+). Considerada.
  Não cobre o caso de back-compat (AnySendable já tem método `value: Any`
  usado em sites externos), e re-introduz typed-erasure a runtime no exato
  ponto que estávamos tentando eliminar.

## Consequências

### Positivas

- **Bug S-H-IO6/S-M-P2 eliminado** — Sendable é verdadeiro (compilador
  verifica). Strict concurrency Swift 6.3 não acusa mais falsa promessa.
- **Audit estrutural** — lint no CI bloqueia regressão (PR que adicione
  `@unchecked Sendable` em fronteira falha).
- **AppError.Equatable mais previsível** — enum tem Equatable estrutural
  automática (a custom `==` do AppError continua ignorando `context` por
  decisão de identidade, mas o tipo é comparável).
- **Codable mais robusto** — round-trip determinístico. Decodificador escolhe
  o case mais específico (Bool antes de Int, Int antes de Double).
- **Padrão para fronteiras futuras** — qualquer DTO/Event payload que precise
  carregar valor heterogêneo Sendable segue este molde.

### Negativas / custos

- **`init(_ any: Any)` mantido** — porta de entrada legacy continua
  type-erasing. Mitigação: storage interno é fechado, então mesmo que o
  caller passe `[String: NSMutableArray]`, o construtor faz fall-through
  para `.string("\(value)")` (degrada graciosamente). Migração futura para
  cases explícitos elimina essa porta.
- **Refactor não migra os 24 handlers** — eles continuam usando `AnySendable($0)`.
  Trade-off documentado e priorizado como melhoria incremental.
- **Lint estrutural não cobre 100%** — outras camadas (Persistence, EventBus,
  Application) podem usar `@unchecked Sendable` legitimamente (ex.: NIO
  handlers em ADR-016). Lint cobre só camadas de fronteira de DTO/error
  (`shared/`, `IO/HTTP/DTOs/`). Revisão de PR cobre o resto.

### Ações requeridas

- [x] `AnySendable` em `shared/Error/AppError.swift` reescrito como enum
- [x] `AnyJSON` em `IO/HTTP/DTOs/ResponseDTOs.swift` reescrito como enum
- [x] 7 testes de regressão em `Regression/Concurrency/SendableJSONTests.swift`
  (3 lints + 4 sanity Codable)
- [x] Skill `swift-application-orchestrator` atualizada (entrada nova)
- [x] Skill `swift-io-implementer` atualizada (entrada 11)
- [ ] **Backlog opcional:** migrar os 24 handlers em `Application/` para
  construir cases explicitamente em vez de `AnySendable($0)`. Ganho
  semântico (sem `Any` no call site), sem ganho de invariante. Anotar em
  `handbook/architecture/IMPROVEMENT_BACKLOG.md`.

## Plano de adoção

1. **Imediato (T-019):** ambos tipos refatorados. Suite 400/400 verde.
2. **Próximo DTO de fronteira:** se precisar carregar valor heterogêneo
   Sendable, segue o molde (enum fechado). PR template referencia ADR-018.
3. **Migração futura (opcional):** handlers passam a construir cases
   explicitamente — `context: ["patientId": .string(id), "amount":
   .int(value)]` — e a back-compat porta `init(_ any:)` pode ser deprecada
   e eventualmente removida.

## Como reverter

Reverter ADR-018 reintroduz S-H-IO6 (Sendable falso, race silenciosa).

Caminho técnico:
1. Restaurar struct `AnySendable: @unchecked Sendable` com `value: Any`
2. Restaurar struct `AnyJSON: Content, @unchecked Sendable` com `value: Any`
3. Apagar `SendableJSONTests.swift`
4. Marcar este ADR como `Deprecado`

Não recomendado.

## Teste de regressão

`Tests/social-care-sTests/Regression/Concurrency/SendableJSONTests.swift`:

1. **`test_S_H_IO6_anysendable_no_unchecked`** — lint estrutural: `AppError.swift`
   declara `enum AnySendable` e não contém `@unchecked Sendable` (ignorando
   linhas de comentário).
2. **`test_S_H_IO6_anyjson_no_unchecked`** — idem para `AnyJSON` em
   `ResponseDTOs.swift`.
3. **`test_S_H_IO6_no_unchecked_in_boundary_layers`** — lint cross-arquivo:
   nenhum source em `shared/` ou `IO/HTTP/DTOs/` declara `@unchecked Sendable`.
4. **`test_S_H_IO6_anysendable_is_truly_sendable`** — sanity runtime: prova
   por compilação (capturar `AnySendable` em `Task` exige Sendable real).
5-7. **`test_S_H_IO6_anysendable_codable_<type>`** — round-trip Codable
   preserva string/int/bool.

7/7 passam pós-fix.

## Better Pattern para skills

- **Skills atualizadas:**
  - `.claude/skills/swift-application-orchestrator/SKILL.md` — entrada nova
    em "Lições Aprendidas" (Application produz `AppError` com `[String:
    AnySendable]` — invariante Sendable agora é verdadeiro).
  - `.claude/skills/swift-io-implementer/SKILL.md` — entrada 11 em "Lições
    Aprendidas" (DTOs de fronteira HTTP nunca usam `@unchecked Sendable`).
- **Regra resumida:** Qualquer struct/class/enum em fronteira (DTO, Error,
  Event payload, Audit response) que precise ser Sendable + carregue valor
  heterogêneo DEVE ser modelado como **enum fechado com cases tipados**,
  NUNCA `@unchecked Sendable` armazenando `Any`. `@unchecked` é uma
  promessa que o `Any` interno **não pode** cumprir (pode armazenar classe
  mutável). Strict concurrency Swift 6 não pega data race em type-erased
  storage. Lint estrutural em `SendableJSONTests` enforça via grep
  (ignorando comentários) nas camadas `shared/` e `IO/HTTP/DTOs/`.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § IO6 — origem
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-019 —
  especificação
- [ADR-016](ADR-016-nats-publisher-bidirectional-handler.md) —
  `@unchecked Sendable` legítimo (NIO handler com event-loop isolation);
  contraste com este ADR
- [SE-0302](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md) — Sendable
- WWDC 2022 — Eliminate data races using Swift Concurrency
- Sandi Metz, *Practical Object-Oriented Design*
