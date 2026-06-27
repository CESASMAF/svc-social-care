# ADR-017: `LogSanitizer` é a porta única de log de erro em camadas com PII

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achado **S-H-IO5** (Senior Code Review § achado IO5) e **S-H-P6** (DB review
§ outbox): logs em camadas IO/HTTP/EventBus/Persistence usavam interpolação
crua de `error` — vaza PII em violação direta da LGPD.

```swift
// SQLKitOutboxRelay.swift — pré-fix
logger.error("Outbox relay poll failed", metadata: ["error": "\(error)"])
//                                                            ↑
//          Se error é DecodingError, vaza JSON do payload (CPF/NIS/etc).

// JWTAuthMiddleware.swift — pré-fix
request.logger.warning("JWT verify falhou: \(error)")
//                                          ↑
//          Vapor JWTError pode incluir fragmento do token (header/claims).

// AppErrorMiddleware.swift — pré-fix
request.logger.error("Unhandled error: \(error)")
//                                      ↑
//          PSQLError.serverInfo inclui SQL com valores bound.
//          URLError.failingURL inclui query string.
```

### Por que isso é HIGH (não MEDIUM)

1. **LGPD scope direto** — paciente é categoria especial (saúde). Vazamento
   em log já é incidente reportável à ANPD, mesmo que log esteja em sistema
   "interno". Stack atual: Loki + Grafana → quem acessa Grafana acessa o
   payload. Audit miss.
2. **Tipos comuns vazam por design** — `DecodingError` da Foundation inclui
   o JSON ofensor no `description` para ajudar dev local. Em prod, é
   exfiltração silenciosa. PostgresKit `PSQLError.serverInfo` inclui SQL
   fragments. URLError inclui query.
3. **Ataque de log injection** — error `description` pode conter `\n` (linha
   nova) — atacante consegue emitir linha falsa em log que parece autêntica
   ("`POST /api OK status=200`"), atrapalhando forensics.

### Citações canônicas

> *"Logs are part of the trust boundary. Any field that can flow into a log
> must pass through the same sanitization as data that flows back to the
> user. PII flowing to logs is exfiltration."*
> — OWASP Logging Cheat Sheet

> *"Error messages are user input. They are formatted by code you do not
> control (kernel, library, framework) and contain values that came from
> the request."*
> — David A. Wheeler, *Secure Programming HOWTO*, cap. 5

> *"Don't log raw payloads. Period. Type and message — never the body."*
> — Adam Shostack, *Threat Modeling*, cap. 8 (privacy section)

## Decisão

1. **Criar `Sources/.../shared/Error/LogSanitizer.swift`** — porta única de
   sanitização:
   ```swift
   public enum LogSanitizer {
       public static let maxDescriptionLength: Int = 200

       public static func metadata(for error: Error, extra: Logger.Metadata = [:]) -> Logger.Metadata {
           var meta: Logger.Metadata = [
               "errorType": .string(String(reflecting: type(of: error))),
               "errorDescription": .string(safeDescription(error))
           ]
           for (k, v) in extra { meta[k] = v }
           return meta
       }

       public static func summary(for error: Error) -> String {
           String(reflecting: type(of: error))
       }

       private static func safeDescription(_ error: Error) -> String {
           let raw = error.localizedDescription
           let neutralized = raw
               .replacingOccurrences(of: "\n", with: " ")
               .replacingOccurrences(of: "\r", with: " ")
               .replacingOccurrences(of: "\t", with: " ")
           return neutralized.count <= maxDescriptionLength
               ? neutralized
               : String(neutralized.prefix(maxDescriptionLength)) + "…"
       }
   }
   ```

2. **Política universal:** logs em IO/HTTP/EventBus/Persistence usam
   `LogSanitizer.metadata(for:)` ou `LogSanitizer.summary(for:)`. NUNCA
   interpolar `error` direto.

3. **Camadas isentas (com justificativa):**
   - `Bootstrap/` (startup time, sem PII fluindo) — interpolação OK em
     mensagens de migration/JWKS load.
   - `social_care_s.swift` (entry point) — idem.
   - Tipos `AppError` que já têm `safeContext` — sanitização própria via
     ADR-010, não precisa passar pelo sanitizer.

4. **Lints estruturais** em
   `Tests/.../Regression/Security/NoPiiInLogTests.swift`:
   - Falha o build se aparecer `"\(error)"` em metadata em
     `IO/Persistence/`, `IO/EventBus/`, `IO/HTTP/Middleware/`,
     `IO/HTTP/Controllers/`.
   - Falha se interpolação `\(error)` aparecer dentro de mensagem (não só
     metadata) em qualquer logger call (`logger.`, `request.logger.`,
     `req.logger.`, `app.logger.`) nas mesmas camadas.

### Antes vs depois

```diff
 // SQLKitOutboxRelay.swift
-logger.error("Outbox relay poll failed", metadata: ["error": "\(error)"])
+logger.error("Outbox relay poll failed", metadata: LogSanitizer.metadata(for: error))

 // JWTAuthMiddleware.swift
-request.logger.warning("JWT verify falhou: \(error)")
+request.logger.warning("JWT verify falhou", metadata: LogSanitizer.metadata(for: error))

 // AppErrorMiddleware.swift
-request.logger.error("Unhandled error: \(error)")
+request.logger.error("Unhandled error", metadata: LogSanitizer.metadata(for: error))

 // HealthController.swift
-req.logger.error("Readiness check failed: \(error)")
+req.logger.error("Readiness check failed", metadata: LogSanitizer.metadata(for: error))

 // NATSEventPublisher.swift
-logger.error("Failed to connect to NATS: \(error)")
-throw NATSError.connectionFailed("\(host):\(port) — \(error)")
+logger.error("Failed to connect to NATS", metadata: LogSanitizer.metadata(for: error))
+throw NATSError.connectionFailed("\(host):\(port) — \(LogSanitizer.summary(for: error))")

 // NATSEventSubscriber.swift
-logger.error("NATS subscriber error: \(error) — reconnecting in 5s")
+logger.error("NATS subscriber error — reconnecting in 5s", metadata: LogSanitizer.metadata(for: error))
-logger.error("Channel error: \(error)")
+logger.error("Channel error", metadata: LogSanitizer.metadata(for: error))
```

Resultado no Loki:

```jsonc
// Pré-fix
{
  "msg": "Outbox relay poll failed",
  "error": "DecodingError(...payload com CPF=12345678900, nome='Fulano de Tal', endereco='Rua...')"
}

// Pós-fix
{
  "msg": "Outbox relay poll failed",
  "errorType": "Foundation.DecodingError",
  "errorDescription": "The data couldn't be read because it isn't in the correct format."
}
```

## Alternativas consideradas

- **Wrapper logger global que filtra `\(error)` automaticamente.** Descartada.
  Hard de testar, magic implícito, depende do call site não escapar via
  string concat. Helper explícito (`LogSanitizer.metadata(for:)`) é mais
  honest e auditável via grep.
- **Bloquear `error.description` no compilador via macro/Diagnostic.** Não
  viável — Swift 6.3 não tem hook para isso. Lint estrutural em testes é o
  enforcement mais próximo.
- **Sanitizar via `try? JSONSerialization.data(error.description)` removendo
  CPFs/NIS via regex.** Descartada. Regex de PII é frágil (formatação
  variável); sanitização por exclusão (só tipo+localizedDescription) é
  defense-in-depth — não importa o tipo de PII.
- **Logar `error.localizedDescription` cru sem truncar.** Considerada.
  Descartada — alguns errors retornam descrição multi-MB (NIO buffer
  errors). 200 chars é trade-off entre debug útil e risco.

## Consequências

### Positivas

- **Bug S-H-IO5/S-H-P6 eliminado** — payload nunca mais entra em log dessas
  camadas.
- **Política única** — nova feature em IO/HTTP segue o pattern
  automaticamente; lint estrutural impede regressão.
- **LGPD compliance reforçada** — defense em camadas (sanitizer + lint).
  Audit de logs no Loki não vai expor PII.
- **Log injection mitigado** — `\n`/`\r`/`\t` neutralizados em
  `errorDescription`.
- **Truncamento explícito** — `maxDescriptionLength=200` evita NIO buffer
  errors gigantes em log.

### Negativas / custos

- **Debug local pior** — dev que quer ver o payload do DecodingError em
  staging precisa habilitar feature flag de "debug logs" (não implementado
  ainda — TODO no backlog) ou reproduzir local com strict logging desligado.
- **Lint estrutural pode ter falsos positivos** — código novo que use
  `\(error)` em comentário disparou? Não — lint procura prefix
  `logger.`/`request.logger.`/`req.logger.`/`app.logger.`. Comentários safe.
- **Camadas Bootstrap não cobertas** — decisão consciente (sem PII), mas
  alguém pode adicionar PII no startup futuramente. Mitigação: revisão de
  PR fica responsável.

### Ações requeridas

- [x] `LogSanitizer.swift` criado em `shared/Error/`
- [x] `SQLKitOutboxRelay.swift` (2 ocorrências) refatorado
- [x] `JWTAuthMiddleware.swift` refatorado
- [x] `AppErrorMiddleware.swift` refatorado
- [x] `HealthController.swift` refatorado
- [x] `NATSEventPublisher.swift` (3 ocorrências: connect, throw, channel handler) refatorado
- [x] `NATSEventSubscriber.swift` (2 ocorrências) refatorado
- [x] 9 testes de regressão estruturais em `Regression/Security/NoPiiInLogTests.swift`
- [x] Skill `swift-io-implementer` atualizada (entrada 10 de Lições Aprendidas)
- [ ] **Backlog operacional:** runbook de debug local — como reproduzir
  payload de erro sem expor em prod (TODO em `handbook/runbook/`)
- [ ] **Backlog observability:** dashboard Grafana com filtro por `errorType`
  para tendências (PSQLError vs DecodingError vs URLError)

## Plano de adoção

1. **Imediato (T-018):** sanitizer + 6 arquivos refatorados. Suite 393/393 verde.
2. **Próxima feature em IO/HTTP:** PR template referencia ADR-017. Lint
   estrutural no CI bloqueia regressão.
3. **Migration de Application/:** `LinkPersonIdCommandHandler` já tem
   `maskedCpf` próprio — pattern paralelo para domain. Não precisa migrar
   para LogSanitizer (escopo diferente).

## Como reverter

Reverter ADR-017 reintroduz S-H-IO5 (vazamento de PII em log).

Caminho técnico:
1. Apagar `LogSanitizer.swift`
2. Reverter os 6 arquivos para `"\(error)"`
3. Apagar `NoPiiInLogTests.swift`
4. Marcar este ADR como `Deprecado`

Não recomendado — reabre incidente reportável.

## Teste de regressão

`Tests/social-care-sTests/Regression/Security/NoPiiInLogTests.swift`:

1. **`test_S_H_IO5_log_sanitizer_exists`** — `LogSanitizer.swift` existe.
2. **`test_S_H_IO5_sanitizer_exposes_metadata`** — declara enum `LogSanitizer`,
   método `metadata(for:)`, usa `String(reflecting: type(of:))`.
3-5. **`test_S_H_IO5_<layer>_no_raw_error`** — lints estruturais por camada
   (Persistence, EventBus, Middleware) verificando ausência de `"\(error)"`
   em metadata.
6. **`test_S_H_IO5_controllers_no_raw_error`** — idem para Controllers.
7-9. **`test_S_H_IO5_<layer>_no_interpolated_error_in_message`** — lints
   estruturais por camada (Middleware, EventBus, Controllers) verificando
   ausência de interpolação `\(error)` direto na mensagem do logger.

9/9 passam pós-fix.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` —
  entrada 10 em "Lições Aprendidas (regressões prevenidas)".
- **Regra resumida:** Em qualquer camada IO/HTTP/EventBus/Persistence,
  NUNCA interpolar `error` direto em log (nem em metadata `["error":
  "\(error)"]`, nem em mensagem `"... \(error)"`). Tipos da Foundation/NIO
  incluem o payload no `description` por design — vaza PII LGPD. Use
  `LogSanitizer.metadata(for: error)` (porta única). Camadas Bootstrap
  ficam isentas (sem PII fluindo no startup); domínios com `AppError`
  usam `safeContext` próprio (ADR-010). Lint estrutural em
  `NoPiiInLogTests` enforça via grep.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § IO5 — origem
- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § outbox/log
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-018 — especificação
- [ADR-010](ADR-010-universal-persistence-conflict-mapping.md) — `AppError`
  com `safeContext` é a sanitização para erros de domínio
- [ADR-013](ADR-013-outbox-for-update-skip-locked.md) — relay é a primeira
  camada exposta; também tinha o bug
- OWASP Logging Cheat Sheet
- LGPD Lei 13.709/2018, Art. 46 (medidas técnicas)
