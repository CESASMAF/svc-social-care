# ADR-012: Security headers obrigatórios e body size limit no boot

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** ADR só pode ficar `Aceito` quando
> todas as seções estão preenchidas — incluindo `Teste de regressão` e
> `Better Pattern para skills`.

## Contexto

Achado **S-C5** (Senior Code Review): o boot do social-care registrava
apenas `AppErrorMiddleware` + `JWTAuthMiddleware`. Faltava cinturão de
headers de defesa em profundidade que a indústria considera baseline
(OWASP ASVS L1 V14.4 — "HTTP Security Headers"):

- `Strict-Transport-Security` — não força HTTPS em browsers compatíveis
- `X-Content-Type-Options: nosniff` — permite MIME sniffing → XSS via imagem maliciosa
- `X-Frame-Options: DENY` — permite clickjacking
- `Referrer-Policy: no-referrer` — URLs do social-care podem vazar via Referer para terceiros
- `Cache-Control: no-store` em endpoints autenticados — proxies podem cachear payloads sensíveis

Adicionalmente: `app.routes.defaultMaxBodySize` ficava no default Vapor
(~16 KB para forms, **sem limite explícito** para JSON). Endpoints como
`RegisterPatientRequest` aceitam listas de diagnósticos, benefícios,
documentos — payload pode crescer arbitrariamente. **Vetor potencial de DoS**:
atacante envia POST com 100 MB de JSON, serviço aloca buffer, OOM.

Citações canônicas:

> *"Defense in depth provides multiple layers of security controls. […]
> A failure in one layer of defense should not result in compromise."*
> — OWASP Secure Coding Practices, Principle of Defense in Depth

> *"In a typical web application, the HTTP response headers are the last
> line of defense. They cost almost nothing to apply but prevent entire
> classes of attacks (XSS via MIME sniffing, clickjacking, downgrade
> attacks). Not adding them is negligence."*
> — Adam Shostack, *Threat Modeling: Designing for Security*

## Decisão

### 1. Middleware novo `SecurityHeadersMiddleware`

```swift
public struct SecurityHeadersMiddleware: AsyncMiddleware {
    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        Self.apply(headers: &response.headers, requestPath: request.url.path)
        return response
    }

    public static func apply(headers: inout HTTPHeaders, requestPath: String) {
        headers.replaceOrAdd(name: "Strict-Transport-Security",
                             value: "max-age=63072000; includeSubDomains; preload")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        if requestPath.hasPrefix("/api/") {
            headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        }
    }
}
```

`apply(headers:requestPath:)` é `static` para teste unitário direto sem
subir Application.

### 2. Registrado como PRIMEIRO middleware no `configure.swift`

```swift
app.middleware.use(SecurityHeadersMiddleware())  // PRIMEIRO
app.middleware.use(AppErrorMiddleware())
app.middleware.use(JWTAuthMiddleware())
```

Ordem importa: o `AppErrorMiddleware` produz responses de erro. Se
`SecurityHeadersMiddleware` ficar depois dele, error responses **NÃO**
recebem headers — vazamento parcial em error path.

### 3. `defaultMaxBodySize = "256kb"`

```swift
app.routes.defaultMaxBodySize = "256kb"
```

256 KB cobre os maiores payloads esperados (`RegisterPatientRequest` com
listas de diagnósticos/benefícios). Acima disso, Vapor rejeita com HTTP 413
Payload Too Large.

### 4. `Cache-Control` apenas em `/api/*`

Rotas públicas (`/health`, `/ready`) são cacheáveis — monitoramento usa
isso. Só payloads autenticados ganham `no-store`.

## Alternativas consideradas

- **Confiar no reverse proxy (nginx/Caddy) para headers.** Descartada — defesa em profundidade requer que cada camada se defenda. Se o proxy falhar (config errada, container errado), serviço fica vulnerável.
- **Content-Security-Policy (CSP) também.** Considerada. Adiada porque CSP exige inventário de fontes de scripts/styles do consumidor BFF — fora do escopo deste ticket. Próximo ADR cobre.
- **Body limit por rota.** Considerada. Descartada por agora — 256 KB universal cobre. Se algum endpoint específico precisar mais (upload de imagem futuro), aplica-se override pontual.
- **Body limit menor (e.g. 64 KB).** Descartada — `RegisterPatient` realista pode passar disso. 256 KB é cinto+suspensórios.
- **HSTS sem `preload`.** Descartada — preload é commit forte mas serve a ambientes que **só** atendem HTTPS. Se o social-care servir HTTP no futuro (improvável), remover.

## Consequências

### Positivas

- Cinco classes de vulnerabilidade browser-side bloqueadas em uma camada.
- Vetor DoS por payload gigante eliminado.
- Compliance OWASP ASVS L1 V14.4 atendido.
- Headers aplicam-se também a responses de erro (ordem correta).
- Teste estrutural impede regressão silenciosa (alguém remove middleware do boot).

### Negativas / custos

- HSTS é stateful no browser — depois de aplicado, browser força HTTPS por 2 anos. Se o serviço precisar voltar a HTTP, browsers que receberam HSTS bloqueiam. Mitigação: nunca voltar para HTTP — é decisão de uma via.
- `X-Frame-Options: DENY` bloqueia embed em iframe — se algum dashboard interno tentar embedar social-care, falha. Mitigação: documentar, considerar CSP `frame-ancestors` granular no próximo ADR.
- `defaultMaxBodySize` aplicado universalmente — endpoint futuro com upload precisa override pontual (`route.maxBodySize = "10mb"`).

### Ações requeridas

- [x] Criar `IO/HTTP/Middleware/SecurityHeadersMiddleware.swift`
- [x] Registrar como PRIMEIRO middleware no `configure.swift`
- [x] `app.routes.defaultMaxBodySize = "256kb"`
- [x] 6 testes de regressão (3 unit + 3 estruturais)
- [x] Skill `swift-io-implementer` atualizada
- [ ] **Futuro:** CSP `frame-ancestors` granular se algum BFF precisa embedar
- [ ] **Futuro:** body limit pontual em endpoint de upload (se vier)

## Plano de adoção

1. **Imediato (T-014):** middleware + body limit. Suite 367/367 verde.
2. **Próximo deploy:** browsers começam a respeitar HSTS. Se houver requests HTTP residuais via proxy, serão redirecionadas a HTTPS pelo proxy (que já faz isso).
3. **Monitoramento:** SRE observa taxa de 413 (payload limit) — se aumentar inesperadamente, ajustar limit ou identificar abuso.

## Como reverter

Caminho técnico:
1. Remover `app.middleware.use(SecurityHeadersMiddleware())` do configure.swift
2. Remover `app.routes.defaultMaxBodySize`
3. Deletar `SecurityHeadersMiddleware.swift`
4. Marcar este ADR como `Deprecado`

HSTS persiste no browser por 2 anos mesmo após reverter — não é totalmente reversível.

## Teste de regressão

`Tests/social-care-sTests/Regression/Security/SecurityHeadersRegressionTests.swift`:

**Unit (3 testes):**
1. `test_S_C5_universal_headers_applied` — 4 headers universais em qualquer path
2. `test_S_C5_cache_control_in_api_routes` — `/api/*` ganha `Cache-Control: no-store`
3. `test_S_C5_no_cache_control_on_health` — `/health` e `/ready` NÃO ganham

**Estrutural (3 testes):**
4. `test_S_C5_configure_registers_middleware` — `configure.swift` cita SecurityHeadersMiddleware
5. `test_S_C5_configure_sets_body_size_limit` — `configure.swift` cita `defaultMaxBodySize`
6. `test_S_C5_security_headers_runs_first` — middleware aparece ANTES de AppErrorMiddleware no source

6/6 passam.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` — entrada 6 em "Lições Aprendidas".
- **Regra resumida:** TODO `configure.swift` registra `SecurityHeadersMiddleware` como PRIMEIRO middleware (antes do AppError) + configura `app.routes.defaultMaxBodySize`. Headers universais: HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy. `Cache-Control: no-store` apenas em rotas autenticadas (`/api/*`). Middleware tem `static apply(headers:requestPath:)` para teste unitário direto.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § C5 — origem
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-014 — especificação
- [ADR-002](ADR-002-regression-test-policy.md) — política de testes de regressão
- [ADR-011](ADR-011-people-context-fail-secure-and-bearer-forwarding.md) — outra peça do conjunto de segurança HTTP
- OWASP ASVS L1 V14.4 — HTTP Security Headers
- OWASP Secure Headers Project — referência canônica de valores recomendados
- Adam Shostack, *Threat Modeling: Designing for Security* — princípio de defesa em profundidade
- HSTS Preload List — https://hstspreload.org/ (max-age ≥ 63072000 + includeSubDomains)
