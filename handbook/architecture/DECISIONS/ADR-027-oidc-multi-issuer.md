# ADR-027: OIDC multi-issuer (migração Zitadel → Authentik)

**Data:** 2026-07-04 (materializado retroativamente — decisão em vigor desde a PR #18)
**Status:** Aceito
**Supersedes:** —

> **Nota de numeração (2026-07-04):** este ADR foi *materializado na reconciliação
> do handbook*. O código, os testes e a skill `swift-io-implementer` já
> referenciavam `ADR-027` para "multi-issuer OIDC" desde a PR #18
> (`feat/oidc-multi-issuer-authentik`) e o `SENIOR_CODE_REVIEW_2026_05_14.md`
> (§ "ADR-027-* + ADR-031-* — Multi-issuer OIDC"), mas o arquivo nunca havia sido
> escrito (débito de documentação). O `REMEDIATION_PIPELINE_2026_05_14.md` havia
> reservado o ID 027 para um tema diferente ("naming EN universal", T-027) que
> **nunca foi implementado**; essa reserva é considerada superada — se o tema de
> naming for promovido, receberá um ID ≥040 (ver `DECISIONS.md`).

## Contexto

O `social-care` autenticava exclusivamente contra o **Zitadel** (self-hosted,
`auth.acdgbrasil.com.br`), com `ZitadelJWTPayload` decodificando o claim
`urn:zitadel:iam:org:project:roles`. A organização decidiu **migrar o IdP para
Authentik**. Uma migração big-bang (trocar o issuer de todos os clientes de uma
vez) é inviável: apps mobile/web em campo continuam emitindo tokens Zitadel
durante o rollout (Sprints 3-6).

Durante a janela de migração o serviço precisa **aceitar tokens dos dois
issuers simultaneamente** — validando assinatura contra o JWKS correto de cada
um e aceitando ambos os `iss`/`aud` — sem duplicar o middleware de auth nem
acoplar o código a um IdP específico.

## Decisão

Adotamos um payload **agnóstico de IdP**, `OIDCJWTPayload` (substitui
`ZitadelJWTPayload`), e configuração **multi-issuer via CSV** no boot:

- `OIDC_JWKS_URLS` (CSV) — um endpoint JWKS por issuer; o `JWTAuthMiddleware`
  tenta cada JWKS configurado ao validar a assinatura RS256.
- `OIDC_ISSUERS` (CSV) — allowlist de `iss` aceitos.
- `OIDC_AUDIENCES` (CSV) — allowlist de `aud` aceitos (intersecção não-vazia).

`OIDCJWTValidators.fromValues(issuersCsv:audiencesCsv:)` faz o parse (split por
vírgula + trim + filtro de vazios) e **falha se qualquer lista vier vazia**
(`nil` → fail-fast no boot): um IdP mal configurado não deve passar silencioso.

**Fallback legado** (compatibilidade durante o corte): se `OIDC_JWKS_URLS` não
estiver setada, usa `JWKS_URL`; `OIDC_ISSUERS` → `ZITADEL_ISSUER`;
`OIDC_AUDIENCES` → `ZITADEL_PROJECT_ID`. Em produção `OIDC_JWKS_URLS` é
obrigatória (Abort no boot se ausente). Após o Sprint 6 (cleanup), apenas
Authentik permanece nas listas.

A derivação de roles multi-claim e os claims ACDG/defense-in-depth são tratados
em ADRs próprios (ver Referências): este ADR cobre **apenas** a aceitação
multi-issuer.

## Alternativas consideradas

- **Big-bang (trocar issuer de uma vez).** Descartada: quebra todo cliente que
  ainda emite token Zitadel durante o rollout; sem janela de convivência.
- **Dois deployments do serviço (um por issuer) atrás do gateway.** Descartada:
  duplica infra e estado (DB, Outbox) por um período transitório; roteamento por
  issuer no Caddy é frágil.
- **Manter `ZitadelJWTPayload` e adicionar `if authentik { … }`.** Descartada:
  acopla o payload a nomes de IdP; a abstração correta é "lista de issuers/JWKS
  confiáveis", não "Zitadel ou Authentik".
- **Aceitar qualquer issuer cujo JWKS valide a assinatura.** Descartada
  (inseguro): assinatura válida de um IdP não-confiável não pode bastar — `iss`
  precisa estar na allowlist (ver ADR-031, mitigação CRIT-2).

## Consequências

- **Positivas:** migração sem downtime nem coordenação lockstep dos clientes;
  código desacoplado do IdP; adicionar/remover issuer é mudança de env (CSV),
  não de código; fail-fast no boot se as listas vierem vazias.
- **Negativas / custos:** o middleware tenta N JWKS por request na janela
  multi-issuer (custo pequeno, JWKS é cacheado); exige disciplina de cleanup
  pós-Sprint 6 para remover o issuer Zitadel e o fallback legado.
- **Ações requeridas:** (1) `OIDCJWTPayload` + `OIDCJWTValidators`; (2) leitura
  CSV + fallback legado em `configure.swift`; (3) envs no `.env.example` e nos
  manifests do `edge-cloud-infra`; (4) teste de regressão.

## Plano de adoção

1. [x] `OIDCJWTPayload` (substitui `ZitadelJWTPayload`) + `OIDCJWTValidators`.
2. [x] `configure.swift` lê `OIDC_JWKS_URLS/ISSUERS/AUDIENCES` (CSV) com fallback
   legado para `JWKS_URL/ZITADEL_ISSUER/ZITADEL_PROJECT_ID`.
3. [x] `JWTAuthMiddleware` tenta cada JWKS configurado.
4. [x] Testes de multi-issuer (aceita/rejeita por `iss` e `aud`).
5. [ ] **Cleanup pós-Sprint 6:** remover issuer Zitadel das listas e o fallback
   legado; deletar o caminho `urn:zitadel:...` (ver ADR-029).

## Como reverter

`git revert` da PR de multi-issuer restaura o payload single-issuer. Como a
mudança é de configuração + parsing (sem migração de dados), reverter é seguro;
tokens em campo continuam válidos enquanto o issuer correspondente estiver na
lista.

## Teste de regressão

`Tests/social-care-sTests/IO/Auth/OIDCJWTPayloadTests.swift` (suite
`OIDCJWTPayload — multi-issuer (Authentik + Zitadel legado)`):

- `@Test("verify aceita issuer presente na lista OIDC_ISSUERS")` e
  `@Test("verify rejeita issuer fora da lista (JWTError.claimVerificationFailure)")`
  — garantem que só `iss` na allowlist passa.
- `@Test("verify rejeita audience fora da lista")` e
  `@Test("verify aceita aud como array com pelo menos um valor da lista")`
  — garantem a política de audiência (intersecção não-vazia).
- `@Test("OIDCJWTValidators.fromValues: divide CSV por virgula com trim")` e
  `@Test("OIDCJWTValidators.fromValues: rejeita lista vazia (fail-fast no boot)")`
  — garantem o parsing CSV e o fail-fast.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` — já
  carrega o snippet "ADR-027: multi-issuer — tenta cada JWKS configurado";
  adicionar entrada na tabela "Lições Aprendidas" apontando para este ADR.
- **Regra resumida:** auth OIDC nunca acopla o payload a um IdP nomeado. Modele
  como **allowlist de issuers/JWKS/audiences** (CSV no boot, fail-fast se vazio).
  Migração de IdP = adicionar/remover entrada na lista, não editar código.
  Assinatura válida **não basta**: `iss` tem de estar na allowlist.

## Referências

- Código: `IO/HTTP/Auth/OIDCJWTPayload.swift`, `IO/HTTP/Bootstrap/configure.swift`
  (bloco OIDC), `IO/HTTP/Middleware/JWTAuthMiddleware.swift`.
- ADRs relacionados: **ADR-029** (precedência de roles multi-claim),
  **ADR-031** (claims ACDG + defense-in-depth no `verify`), **ADR-023**
  (actorId via `sub` — preservado).
- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` (§ Multi-issuer OIDC).
