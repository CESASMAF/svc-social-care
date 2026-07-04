# T-014 — W3 Quality Gates

**Data:** 2026-05-14
**Achado:** S-C5 (Senior Code Review)

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 40.57s, 0 warnings novos |
| Full test suite | ✅ **367/367** passam, 0.055s |
| Regression suite | ✅ 63 testes em 11 suites (+6 do T-014) |
| Testes T-014 | ✅ **6/6** passam (3 unit + 3 estruturais) |
| ADR-012 | ✅ |
| DECISIONS.md index | próximo ID = 013 | ✅ |
| Skill `swift-io-implementer` | entrada 6 em "Lições Aprendidas" | ✅ |

## Arquivos criados

- `Sources/.../IO/HTTP/Middleware/SecurityHeadersMiddleware.swift` — **NOVO** (middleware + static apply)
- `Tests/.../Regression/Security/SecurityHeadersRegressionTests.swift` — **NOVO** (6 testes)
- `handbook/architecture/DECISIONS/ADR-012-security-headers-and-body-size-limit.md` — **NOVO**

## Arquivos modificados

- `Sources/.../IO/HTTP/Bootstrap/configure.swift`:
  - `SecurityHeadersMiddleware()` registrado como PRIMEIRO middleware
  - `app.routes.defaultMaxBodySize = "256kb"` adicionado
- `handbook/architecture/DECISIONS.md` — ADR-012 indexado; próximo ID = **013**
- `.claude/skills/swift-io-implementer/SKILL.md` — Lições Aprendidas entrada 6

## Headers aplicados

| Header | Valor | Escopo |
|---|---|---|
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains; preload` | universal |
| `X-Content-Type-Options` | `nosniff` | universal |
| `X-Frame-Options` | `DENY` | universal |
| `Referrer-Policy` | `no-referrer` | universal |
| `Cache-Control` | `no-store` | apenas rotas `/api/*` |

Body limit: 256 KB universal (`app.routes.defaultMaxBodySize`).

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001 | Foundations | ADR-002 | 5 |
| T-002 | Estrutura ADR | ADR-003 | meta |
| T-004 | S-C7 | ADR-004 | 2 |
| T-005 | S-C3 + DB-2 | ADR-005 | 4 |
| T-006 | DB-1 | ADR-006 | 4 |
| T-007 | DB-4 + S-H-D5 | ADR-007 | 5 |
| T-008 | DB-3 | ADR-008 | 8 |
| T-009 | DB-8 | ADR-009 | 6 |
| T-010 | S-C6 | ADR-010 | 3 + lint |
| T-011 | S-C1 (mais grave) | ADR-011 | 4 |
| T-014 | S-C5 | ADR-012 | 6 |
| **Total** | **11 fechados** | **12 ADRs** | **47 regression tests** |

## Próximos tickets sugeridos

- **T-012** — Outbox FOR UPDATE SKIP LOCKED (S-C2, CRITICAL — produção multi-instância)
- **T-013** — Remover OutboxEventBus.publish dead code (S-C4, CRITICAL — clareza arquitetural)
- **T-015** — `audit_trail.id` distinto de `outbox.id` (S-C10, CRITICAL — batch dies on duplicate)
