# ADR-031: Defense-in-depth no `verify` OIDC + claims ACDG (org_id/person_id/legacy_sub)

**Data:** 2026-07-04 (materializado retroativamente — decisão em vigor desde a PR #18)
**Status:** Aceito
**Supersedes:** —

> **Nota de numeração (2026-07-04):** materializado na reconciliação do handbook.
> Código (`OIDCJWTPayload`, `JWTAuthMiddleware`, `AuthenticatedUser`) e testes já
> citavam `ADR-031` para "claims ACDG + defense-in-depth". O
> `REMEDIATION_PIPELINE_2026_05_14.md` havia reservado 031 para
> "LookupBatchValidator" (T-031), **nunca implementado**; reserva superada
> (LookupBatchValidator, se promovido, recebe ID ≥040 — ver `DECISIONS.md`).

## Contexto

No Vapor/JWTKit, `request.jwt.verify(as: OIDCJWTPayload.self)` chama
automaticamente `OIDCJWTPayload.verify(using:)` **após** validar a assinatura
RS256 contra o JWKS. Se a validação de claims (`iss`/`aud`/`exp`/`nbf`) só
acontecesse dentro do `JWTAuthMiddleware`, qualquer **outro** codepath que
verifique um JWT (um job, uma integração futura, um teste que use
`request.jwt.verify` direto) validaria **apenas a assinatura** — e uma
assinatura válida de um issuer não-confiável passaria.

Achados do AppSec review (2026-05-14):

- **CRITICAL-1:** confiar só no middleware para chamar a validação de claims
  viola defense-in-depth. A validação completa precisa rodar em **todo** caminho
  de verificação de JWT.
- **CRITICAL-2:** assinatura válida ≠ token confiável — `iss` fora da allowlist
  deve ser rejeitado mesmo com assinatura íntegra.
- **HIGH-A:** o Authentik emite `nbf` (not-before) por default; a RFC 7519 obriga
  validá-lo quando presente. O código anterior não validava `nbf`.

Além disso, a migração introduz **claims ACDG opcionais** — `org_id`,
`person_id`, `legacy_sub` — usados para correlação. Em particular, `legacy_sub`
correlaciona o `sub` novo (Authentik) com o `sub` antigo (Zitadel) que eventos
históricos referenciam, **sem** quebrar o ADR-023 (o `userId`/actorId do audit
trail continua sendo o `sub` corrente).

## Decisão

**1. Defense-in-depth via storage global (`OIDCJWTPayloadBootstrap`).** No boot,
`configure.swift` registra os `OIDCJWTValidators` em
`OIDCJWTPayloadBootstrap.shared.set(...)`. `OIDCJWTPayload.verify(using:)`
consulta esse storage e roda a validação **completa** de `iss`/`aud`/`exp`/`nbf`
— logo, qualquer codepath que chame `request.jwt.verify(as:)` valida claims sem
precisar lembrar de uma segunda passada manual. **Fail-closed:** se o bootstrap
não foi registrado, `verify(using:)` lança
`JWTError.claimVerificationFailure` (nega em vez de passar).

**2. Validação de `nbf` (HIGH-A).** `verify` chama `nbf?.verifyNotBefore()`
quando o claim está presente.

**3. Claims ACDG opcionais.** `org_id`, `person_id`, `legacy_sub` decodificados
como opcionais e propagados para `AuthenticatedUser`. **ADR-023 preservado:**
`userId` = `sub` corrente (canônico); `legacySub` é só metadado de correlação.

## Alternativas consideradas

- **Validar claims só no middleware.** Descartada (CRITICAL-1): deixa outros
  codepaths de verificação com validação parcial (só assinatura).
- **Injetar os validators por DI no payload.** Descartada: `JWTPayload.verify`
  é chamado pelo framework sem contexto de request/DI; um storage global
  thread-safe (`NSLock`) é o ponto de extensão viável e fail-closed.
- **Fail-open se o bootstrap não estiver registrado.** Descartada: um serviço
  mal-inicializado que aceite qualquer token é pior do que um que recuse tudo.
- **`orgId` obrigatório já.** Descartada por ora: o senior review apontou que
  `orgId` é carregado mas ainda não é *enforced* — enforcement multi-tenant é
  follow-up (evitar cross-tenant leak), não bloqueia esta decisão.

## Consequências

- **Positivas:** validação de claims uniforme em todo codepath (não só
  middleware); fail-closed por default; `nbf` validado (RFC 7519); correlação
  histórica de ator via `legacy_sub` sem violar ADR-023.
- **Negativas / custos:** introduz **estado global mutável** (`@unchecked
  Sendable` com `NSLock`) — aceitável e isolado, mas exige `reset()` test-only
  para evitar leak entre testes (suite marcada `.serialized`); `orgId` presente-mas-não-enforced
  é dívida de segurança rastreada (multi-tenant).
- **Ações requeridas:** (1) `OIDCJWTPayloadBootstrap` + `verify(using:)`
  fail-closed; (2) `nbf` no `verify`; (3) claims ACDG em `OIDCJWTPayload` e
  `AuthenticatedUser`; (4) `set(...)` no boot; (5) testes.

## Plano de adoção

1. [x] `OIDCJWTPayloadBootstrap` (storage global thread-safe) + `reset()` test-only.
2. [x] `verify(using:)` consulta o storage e valida `iss`/`aud`/`exp`/`nbf`
   (fail-closed se não registrado).
3. [x] `configure.swift` chama `OIDCJWTPayloadBootstrap.shared.set(validators)` no boot.
4. [x] Claims `org_id`/`person_id`/`legacy_sub` em `OIDCJWTPayload` + `AuthenticatedUser`.
5. [x] Testes (verify global, fail-closed, CRIT-2, nbf, legacy_sub).
6. [ ] **Follow-up:** enforce `orgId` (isolamento multi-tenant) — abrir ADR/ticket próprio.

## Como reverter

`git revert` restaura a validação só-no-middleware. **Atenção:** reverter
reabre CRITICAL-1 (validação parcial em codepaths alternativos) — só reverter se
o middleware voltar a ser o único ponto de verificação de JWT.

## Teste de regressão

`Tests/social-care-sTests/IO/Auth/OIDCJWTPayloadTests.swift`:

- `@Test("verify(using:) consulta storage global e valida iss/aud sem segunda passada manual")`
  — garante o defense-in-depth (CRITICAL-1).
- `@Test("verify(using:) FALHA se OIDCJWTPayloadBootstrap nao registrado (fail-closed)")`
  — garante fail-closed.
- `@Test("verify(using:) rejeita issuer fora da whitelist mesmo com signature valida (CRIT-2 mitigation)")`
  — garante que assinatura válida não basta.
- `@Test("verify rejeita token com nbf no futuro")` — garante HIGH-A (`nbf`).

`Tests/social-care-sTests/IO/Auth/AuthenticatedUserTests.swift` (suite
`AuthenticatedUser — ADR-023 + ADR-031 (legacy_sub correlation)`):

- `@Test("ADR-023: userId nao e afetado por legacySub (sub Authentik atual e canonico)")`
  — garante que `legacy_sub` não vira actorId (ADR-023 preservado).
- `@Test("Construtor com claims ACDG completos (Authentik com acdg-roles property mapping)")`.

`OIDCJWTSigningE2ETests.swift` cobre o decode de `exp` no caminho de produção
(round-trip sign+parse).

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` — entrada
  na tabela "Lições Aprendidas" apontando para este ADR e os testes CRIT-1/CRIT-2/nbf.
- **Regra resumida:** validação de claims JWT roda em **todo** codepath de
  `verify`, não só no middleware — implemente-a dentro de `JWTPayload.verify(using:)`
  com **fail-closed** se a config não foi registrada no boot. Assinatura válida
  nunca basta: cheque `iss`/`aud`/`exp`/`nbf`. Metadado de correlação (`legacy_sub`)
  jamais substitui o actorId canônico (ADR-023).

## Referências

- Código: `IO/HTTP/Auth/OIDCJWTPayload.swift` (`verify`, `OIDCJWTPayloadBootstrap`),
  `IO/HTTP/Middleware/JWTAuthMiddleware.swift`, `IO/HTTP/Auth/AuthenticatedUser.swift`,
  `IO/HTTP/Bootstrap/configure.swift`.
- RFC 7519 (§ 4.1.5 `nbf`).
- ADRs relacionados: **ADR-027** (multi-issuer), **ADR-029** (precedência de
  roles), **ADR-023** (actorId via `sub`), **ADR-012** (security headers),
  **ADR-018** (banimento de `@unchecked Sendable` em fronteira — exceção
  justificada aqui: storage global de boot, não estrutura de fronteira de dados).
- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` (CRITICAL-1, CRITICAL-2,
  HIGH-A; achado `orgId` não-enforced).
