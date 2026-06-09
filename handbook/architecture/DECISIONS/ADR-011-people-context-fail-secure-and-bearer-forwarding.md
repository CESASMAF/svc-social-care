# ADR-011: PeopleContext fail-secure tri-state com Bearer forwarding

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** um ADR só pode ficar `Aceito`
> quando **todas** as seções abaixo estão preenchidas — incluindo `Teste de
> regressão` e `Better Pattern para skills`. ADR sem essas duas seções fica
> `Proposto` até completar.

## Contexto

Achado **S-C1** (Senior Code Review § achado mais grave): `PeopleContextPersonValidator` tinha três falhas sobrepostas que juntas formam **bypass de invariante de domínio sem rastro de segurança**:

### 1. Fail-open silencioso

```swift
// PRÉ-FIX
public func exists(personId: PersonId) async throws -> Bool {
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        ...
        default:
            logger.warning("people-context returned \(code) — fail-open")
            return true  // ⚠️ S-C1
    } catch {
        logger.warning("people-context unreachable: \(error) — fail-open")
        return true  // ⚠️ S-C1
    }
}
```

Qualquer erro (timeout, 5xx, DNS, 401) virava `true`. Cenário de ataque:
1. Atacante derruba o people-context (DDoS, ou só espera janela de instabilidade)
2. Faz POST `/api/v1/patients` com `personId` inventado
3. Validator retorna `true` (fail-open)
4. Paciente é registrado com `personId` que não existe
5. Audit trail mostra apenas `warning` de log — visível só para SRE, não bloqueia

Em healthcare/social-care isso quebra a invariante "Patient existe ⇒ Person existe" da arquitetura v2.0 do handbook. Pacientes "fantasma" comprometem relatórios SUAS, auditoria PBF/BPC, e tracking de acesso a benefícios.

### 2. Bearer não encaminhado (viola ADR-023)

```swift
// PRÉ-FIX — request sem header Authorization
var request = URLRequest(url: url)
request.httpMethod = "GET"
request.timeoutInterval = 5
// nenhum Authorization
```

ADR-023 (frontend handbook) determina: BFFs e gateways DEVEM encaminhar `Authorization: Bearer <jwt>` em outbound. People-context aplicava JWT auth nos endpoints de leitura → respondia 401 → fail-open silenciava.

### 3. URL via interpolação direta

```swift
let url = URL(string: "\(baseURL)/api/v1/people/\(personId.description)")!
```

`personId` é VO controlado, então o risco é teórico — mas o pattern é frágil. Sem `URLComponents`, qualquer mudança futura em `PersonId` quebra silenciosamente.

### Citações canônicas

> *"All security controls should fail securely. […] When a security mechanism encounters an unexpected condition or input, it should default to the most secure state."* — OWASP Secure Coding Practices, Principle of Fail-Secure

> *"Anti-Corruption Layer is a translation layer between a model and an external system. […] If the boundary is not faithful, your model is corrupted."* — Eric Evans, *Domain-Driven Design*, p. 365

O `PeopleContextPersonValidator` é exatamente o ACL para o BC people-context. Fail-open o transforma de defesa em via livre.

## Decisão

Três mudanças, aplicadas atomicamente:

### 1. Porta `PersonExistenceValidating` retorna tri-state

```swift
public enum PersonExistence: Sendable, Equatable {
    case exists
    case notFound
    case unknown(reason: String)
}

public protocol PersonExistenceValidating: Sendable {
    /// Consulta o people-context para verificar a existência de `personId`.
    /// - Parameter bearer: JWT do request original (ADR-023). `nil` em
    ///   contextos não-autenticados (cron, integração interna, testes).
    func validate(personId: PersonId, bearer: String?) async -> PersonExistence
}
```

Método **não-throws** porque o tri-state cobre todos os caminhos. Elimina o padrão `catch { return true }` que era raiz do fail-open.

### 2. Implementação fail-secure + Bearer forwarding

`PeopleContextPersonValidator`:
- `200` → `.exists`
- `404` → `.notFound`
- `401` → `.unknown(reason: "upstream_unauthorized")` — sinaliza bearer rejeitado, registro bloqueado
- Outros 4xx/5xx → `.unknown(reason: "http_<code>")`
- Timeout / DNS / transporte → `.unknown(reason: "transport_<type>")`
- Encaminha `Authorization: Bearer <jwt>` quando `bearer` não-nil
- `URLComponents` para construção segura da URL

Log usa `String(reflecting: type(of: error))` (ADR-019) — nunca payload bruto.

### 3. Handler bloqueia em `.unknown`

```swift
// RegisterPatientCommandHandler — sequência 6
switch await validator.validate(personId: personId, bearer: command.bearer) {
case .exists:
    break  // OK
case .notFound:
    throw RegisterPatientError.personIdNotFoundInPeopleContext(command.personId)  // HTTP 422
case .unknown(let reason):
    throw RegisterPatientError.personValidationUnavailable(reason: reason)  // HTTP 503
}
```

Novo erro `RegisterPatientError.personValidationUnavailable(reason:)` mapeia para HTTP 503 — operador recebe sinal claro de "retentar".

### 4. Bearer no Command + Controller

`RegisterPatientCommand` ganha campo opcional `bearer: String?`. Controller extrai via `req.headers.bearerAuthorization?.token` e passa por `toCommand(actorId:bearer:)`.

## Alternativas consideradas

- **Manter `Bool` + adicionar nova função `existsOrUnknown` retornando `Result`.** Descartada — fica fácil chamar o método antigo errado por reflexo; tri-state força tratamento explícito no compilador.
- **Lançar erro do tipo `PeopleContextError.unavailable` em vez de retornar `.unknown`.** Considerada. Descartada porque `throws` reintroduz a tentação de `catch { return true }` no handler. Tri-state explícito é mais difícil de errar.
- **Manter `throws` mas adicionar variante `.upstreamFailure` em `RegisterPatientError`.** Descartada — handler precisa decidir entre "esse erro é fatal" vs "esse erro deveria ter sido capturado". Tri-state explícito move a decisão para tipo.
- **Adicionar bearer ao `ServiceContainer` (acessível globalmente).** Descartada — bearer é por-request, não por-aplicação. Singleton vazaria tokens entre requests.
- **Bearer encaminhado via header customizado em vez de `Authorization`.** Descartada — ADR-023 é universal: header padrão `Authorization`. Custom = mais um padrão para o people-context implementar.

## Consequências

### Positivas

- **Bug S-C1 eliminado** — registro com personId não-verificado é impossível quando upstream está indisponível.
- **ADR-023 cumprido** — Bearer forwarding em outbound.
- **Diagnóstico mensurável** — log estruturado conta `.unknown` por reason; SRE detecta degradação do upstream cedo.
- **HTTP 503 sinal claro ao cliente** — em vez de erro interno 500 ou sucesso silencioso.
- **`URLComponents`** elimina classe inteira de bugs de URL building.

### Negativas / custos

- Cliente HTTP recebe 503 quando people-context está down — antes recebia 201 silencioso (com personId não-verificado). UX "pior" mas correta.
- Operadores precisam saber que 503 = retentar em alguns instantes (não é bug do social-care).
- Bearer no Command adiciona 1 campo opcional — propaga pelo Controller. Pequeno boilerplate.
- Testes que dependiam de validator retornando `true` silenciosamente precisaram atualizar (no projeto: nenhum — só RegisterPatient usava, e os testes existentes usam `nil` para o validator).

### Ações requeridas

- [x] Refatorar porta `PersonExistenceValidating` para tri-state
- [x] Refatorar `PeopleContextPersonValidator` fail-secure + Bearer forwarding + URLComponents
- [x] `RegisterPatientCommand.bearer: String?`
- [x] `RegisterPatientCommandHandler` switch sobre tri-state
- [x] Novo erro `RegisterPatientError.personValidationUnavailable(reason:)` → HTTP 503
- [x] Controller passa `req.headers.bearerAuthorization?.token` para o Command
- [x] Teste de regressão (4 testes)
- [x] Skill `swift-io-implementer` atualizada
- [ ] **T-012 + outros adapters outbound futuros:** seguir o mesmo padrão tri-state + Bearer.

## Plano de adoção

1. **Imediato (T-011):** porta + validator + handler + controller + teste. Suite 361/361 verde.
2. **Próximo deploy:** people-context recebe Bearer automaticamente. Se people-context não aceitar bearer (configuração antiga), o validator retorna `.unknown(reason: "upstream_unauthorized")` — registro bloqueado, sinal claro para coordenar com time do people-context.
3. **Métricas (ADR futuro):** contar `.unknown` por reason em log estruturado; alarmar SRE se taxa > X%.

## Como reverter

Reverter ADR-011 reintroduz S-C1.

Caminho técnico:
1. Restaurar `func exists(personId:) async throws -> Bool`
2. Remover bearer do Command/Controller
3. Marcar este ADR como `Deprecado`

Não recomendado.

## Teste de regressão

`Tests/social-care-sTests/Regression/Security/PeopleContextNoFailOpenRegressionTests.swift`:

1. **`test_S_C1_port_is_tri_state`** — porta declara `enum PersonExistence` (compile-time guard).
2. **`test_S_C1_handler_blocks_on_unknown_upstream`** — fake retorna `.unknown` → handler lança → nada persistido, nenhum evento publicado.
3. **`test_S_C1_handler_blocks_on_not_found`** — fake retorna `.notFound` → handler lança (comportamento mantido).
4. **`test_S_C1_bearer_is_forwarded_to_validator`** — bearer no Command chega ao validator via método `validate(personId:bearer:)`.

4/4 passam.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` — nova entrada em "Lições Aprendidas".
- **Regra resumida:** TODO adapter outbound retorna **tri-state explícito** (`.ok / .notFound / .unknown(reason:)`), nunca `Bool`. Falha de upstream NUNCA é fail-open. Bearer JWT é encaminhado quando o método aceita `bearer: String?`. Log de erro usa `String(reflecting: type(of:))` — nunca payload bruto (ADR-019). URL via `URLComponents`, nunca interpolação.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § C1 — origem
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-011 — especificação
- ADR-023 (frontend handbook) — BFF Bearer forwarding (origem do padrão)
- [ADR-002](ADR-002-regression-test-policy.md) — política de testes de regressão
- [ADR-019](#) — sanitização de log (planejado em T-018)
- OWASP Secure Coding Practices — Principle of Fail-Secure
- Eric Evans, *Domain-Driven Design*, p. 365 — Anti-Corruption Layer
