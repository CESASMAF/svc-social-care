# Regression / Security

Previne **regressões de segurança** que abrem bypass, vazam PII ou comprometem a fronteira de confiança.

## Classe de bugs prevenidos

- **Fail-open em adapter outbound** — falha de upstream interpretada como "tudo bem".
- **Bearer não forwardado** — viola ADR-023.
- **Headers de segurança ausentes** — HSTS / X-Content-Type-Options / X-Frame-Options / CSP.
- **Body size sem limite** — endpoints aceitam payloads gigantes.
- **PII em log** — CPF, NIS, nome completo vazam via `"\(error)"`.
- **JWT validation incompleta** — iss/aud/exp/nbf não verificados em algum codepath.
- **JWKS sem refresh** — key rotation quebra serviço.
- **Service-account introspection sem cache** — derruba IdP.
- **Audit-trail vaza cross-aggregate** — UUID coincidente não filtrado por `aggregate_type`.
- **Cross-tenant leak** — `orgId` ignorado em queries.
- **Rota sem `RoleGuardMiddleware`** — qualquer user autenticado acessa.

## Tickets que adicionam testes aqui

| Ticket | Teste | Achado |
|---|---|---|
| T-011 | `PeopleContextNoFailOpenTest` | S-C1 |
| T-014 | `SecurityHeadersTest` | S-C5 |
| T-018 | `NoPiiInLogTest` | S-H-P6 |
| T-029 | `JWKSRefreshTest`, `IntrospectCacheTest` | S-H-IO2 + S-H-IO3 |
| T-032 | `AllRoutesHaveRoleGuardTest` | S-M-IO2 |

## Princípios anti-pattern

| Anti-pattern | Pattern |
|---|---|
| Fail-open | tri-state `.exists/.notFound/.unknown` com `.unknown` ⇒ HTTP 503 |
| `"\(error)"` em log com PII | `String(reflecting: type(of: error))` + `error.localizedDescription` |
| Default-allow em rota | Default-deny + lint test que percorre `app.routes.all` |
| Singleton JWKS estático | Background refresh a cada 15min |

## Padrão típico

```swift
@Test("S-C1 — PeopleContext blocks registration when upstream is down")
func test_S_C1_unavailable_blocks_registration() async throws {
    let validator = PeopleContextPersonValidator(baseURL: "http://unreachable:9999", ...)
    let result = await validator.validate(personId: ..., bearer: "valid.jwt")
    if case .unknown = result { } else {
        Issue.record("Expected .unknown when upstream is unreachable")
    }
}
```
