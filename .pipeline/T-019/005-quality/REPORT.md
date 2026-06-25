# T-019 — W3 Quality Gates

**Data:** 2026-05-14
**Achados:** S-H-IO6 (Senior Code Review § IO6) + S-M-P2 — `AnySendable` e `AnyJSON` eram `@unchecked Sendable` armazenando `Any` (Sendable falso, race silenciosa em strict concurrency).

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 45.06s, 0 warnings novos |
| Full test suite | ✅ **400/400** passam, 0.083s |
| Regression suite | ✅ 96 testes em 17 suites (+7 do T-019) |
| Testes T-019 | ✅ **7/7** passam (3 lints + 4 sanity Codable) |
| ADR-018 | ✅ |
| DECISIONS.md index | próximo ID = **019** | ✅ |
| Skill `swift-application-orchestrator` | entrada 3 em "Lições Aprendidas" | ✅ |
| Skill `swift-io-implementer` | entrada 11 em "Lições Aprendidas" | ✅ |

## Arquivos criados

**Testes:**
- `Tests/.../Regression/Concurrency/SendableJSONTests.swift` — 7 testes (3 lints estruturais + 4 sanity Codable)

**Handbook + skills:**
- `handbook/architecture/DECISIONS/ADR-018-no-unchecked-sendable-on-boundary.md` — **NOVO**
- `handbook/architecture/DECISIONS.md` — ADR-018 indexado; próximo ID = **019**
- `.claude/skills/swift-application-orchestrator/SKILL.md` — Lições Aprendidas entrada 3
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 11

## Arquivos modificados

**Sources (2 arquivos, 2 tipos refatorados):**

- `shared/Error/AppError.swift` — `struct AnySendable: @unchecked Sendable` reescrito como `enum AnySendable: Sendable, Codable, Equatable` com 7 cases (string/int/double/bool/array/object/null). `init(_ any: Any)` e `value: Any` getter mantidos para back-compat com 24 handlers.
- `IO/HTTP/DTOs/ResponseDTOs.swift` — `struct AnyJSON: Content, @unchecked Sendable` reescrito como `enum AnyJSON: Content` com cases análogos. `init(value: Any)` mantido para `AuditTrailEntryResponse`.

## Decisões arquiteturais

1. **Enum fechado (Opção A) sobre big-bang migration de 24 handlers** — invariante crítico (Sendable verdadeiro) é resolvido sem tocar call sites. Migração de handlers para construir cases explicitamente é melhoria opcional, anotada no backlog do ADR.
2. **`init(_ any: Any)` mantido como back-compat** — porta de entrada legacy. Storage interno fica fechado (mesmo que caller passe NSMutableArray, construtor degrada para `.string("\(value)")`). A porta não-tipada some quando handlers migrarem.
3. **`value: Any` getter mantido** — nenhum call site externo lê `.value` direto na busca (nenhum match em testes), mas o getter é defesa em profundidade contra introduzir bug em código legado. Custo: 1 método.
4. **Lint estrutural ignora comentários** — primeiro RED falhou porque o lint pegava menções a `@unchecked Sendable` em docstrings que documentavam o refactor. Helper `stripComments` filtra linhas iniciadas por `//` ou `///`.
5. **Lint cross-arquivo cobre `shared/` + `IO/HTTP/DTOs/`** — camadas de fronteira. Outras camadas (NIO handlers em `IO/EventBus/`) podem usar `@unchecked Sendable` legitimamente (event-loop isolation), por isso ficam fora do lint cross-arquivo.

## Antes vs depois

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
+    public init(_ value: Any) { /* best-effort mapping para case */ }
+    public var value: Any { /* getter back-compat */ }
+}

-struct AnyJSON: Content, @unchecked Sendable {
-    let value: Any
-}
+enum AnyJSON: Content {
+    case object([String: AnyJSON])
+    case array([AnyJSON])
+    case string(String)
+    case int(Int)
+    case double(Double)
+    case bool(Bool)
+    case null
+}
```

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001..T-018 (já reportados) | 16 fechados | 17 ADRs | 89 testes |
| T-019 | S-H-IO6 + S-M-P2 | ADR-018 | 7 |
| **Total** | **17 fechados** | **18 ADRs** | **96 regression tests** |

## Backlog gerado

1. **Migrar 24 handlers** em `Application/` para construir cases explicitamente em vez de `AnySendable($0)`. Ganho semântico (zero `Any` no call site), sem ganho de invariante. Anotar em `handbook/architecture/IMPROVEMENT_BACKLOG.md` quando próxima janela permitir.

## Próximos tickets sugeridos

- **T-020** (Phase 4) — `required_documents` vira tabela filha (1NF) — começa decomposição do god aggregate Patient.
- **T-021..T-024** (Phase 4) — continuação da decomposição.
- **T-025..T-031** (Phase 5) — UoW + polish.
