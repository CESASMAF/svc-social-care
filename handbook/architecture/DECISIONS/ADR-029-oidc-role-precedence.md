# ADR-029: Precedência de roles multi-claim + property mapping `acdg-roles`

**Data:** 2026-07-04 (materializado retroativamente — decisão em vigor desde a PR #18)
**Status:** Aceito
**Supersedes:** —

> **Nota de numeração (2026-07-04):** materializado na reconciliação do handbook.
> Código (`OIDCJWTPayload.roleNames`) e testes já citavam `ADR-029` para
> "property mapping `acdg-roles` / precedência de roles". O
> `REMEDIATION_PIPELINE_2026_05_14.md` havia reservado 029 para "JWKS refresh +
> introspection cache" (T-029), **nunca implementado**; reserva superada (tema de
> JWKS-refresh, se promovido, recebe ID ≥040 — ver `DECISIONS.md`).

## Contexto

Cada IdP expõe roles em um claim diferente, e o `social-care` precisa derivar um
`Set<String>` de roles **determinístico** para o `RoleGuardMiddleware`,
independentemente do emissor:

- **Authentik com property mapping custom `acdg-roles`** → claim `roles: [String]`.
- **Authentik default (sem mapping custom)** → claim `groups: [String]`.
- **Zitadel legado** → claim `urn:zitadel:iam:org:project:roles` (dicionário).

Durante a migração (ADR-027) um mesmo request pode vir de qualquer um dos três.
Sem uma ordem de precedência explícita, a derivação de roles fica ambígua quando
mais de um claim está presente.

**Risco de segurança (code-review M5, 2026-05-14):** se a precedência fizer
fallback ingênuo — "usa `roles`; se vazio, tenta `groups`" — então uma property
mapping `acdg-roles` que retorne `[]` **por bug** cairia silenciosamente no
`groups`, podendo **escalar** privilégios de forma não-intencional. `roles`
presente-porém-vazio é um sinal legítimo ("mapping aplicada, zero roles"), não um
"não sei, tenta outro lugar".

## Decisão

`OIDCJWTPayload.roleNames` deriva roles por **precedência estrita com short-circuit
na presença** (não no conteúdo):

1. Se `roles` **está presente** (mesmo `[]`) → retorna `Set(roles)`. **Sem
   fallback** para `groups`.
2. Senão, se `groups` presente → `Set(groups)`.
3. Senão, se `projectRoles` (Zitadel) presente → `Set(projectRoles.keys)`.
4. Senão → `[]`.

A property mapping **`acdg-roles`** no Authentik é o mecanismo canônico
(item 1); `groups` é o default de transição (item 2); o claim Zitadel (item 3)
sai de cena no cleanup pós-Sprint 6.

## Alternativas consideradas

- **Fallback por conteúdo ("`roles` vazio → tenta `groups`").** Descartada
  (M5): mascara bug de mapping e permite escalonamento silencioso. Presença, não
  conteúdo, decide.
- **União de todos os claims (`roles ∪ groups ∪ projectRoles`).** Descartada:
  soma privilégios de fontes que deveriam ser mutuamente exclusivas por IdP;
  amplia superfície de escalonamento.
- **Exigir sempre `acdg-roles` (sem `groups`/Zitadel).** Descartada: quebraria
  tokens em campo durante a migração (o default Authentik e o Zitadel legado
  precisam funcionar na janela de convivência).

## Consequências

- **Positivas:** derivação determinística e auditável; fecha o vetor de
  escalonamento por `roles` vazio; suporta os três formatos sem `if idp ==`.
- **Negativas / custos:** exige que a property mapping `acdg-roles` seja
  configurada corretamente no Authentik (caso contrário cai em `groups`, que é
  aceitável no período de transição); a regra "presença, não conteúdo" é sutil e
  precisa estar coberta por teste para não regredir.
- **Ações requeridas:** (1) `roleNames` com a ordem acima; (2) property mapping
  `acdg-roles` no Authentik; (3) testes de precedência e do caso `roles == []`.

## Plano de adoção

1. [x] `roleNames` com precedência `roles → groups → projectRoles` e
   short-circuit por presença.
2. [x] Property mapping `acdg-roles` configurada no Authentik (infra).
3. [x] Testes de precedência + M5 (`roles` vazio explícito).
4. [ ] **Cleanup pós-Sprint 6:** remover o ramo `projectRoles` (Zitadel).

## Como reverter

`git revert` da mudança em `roleNames`. Sem efeito em dados persistidos (roles
são derivadas por request, não armazenadas).

## Teste de regressão

`Tests/social-care-sTests/IO/Auth/OIDCJWTPayloadTests.swift`:

- `@Test("`roles` claim tem precedencia sobre `groups` (ADR-029 property mapping ativa)")`
  — garante o item 1 da precedência.
- `@Test("M5: roles vazio explicito retorna [] (sem fallback para groups)")`
  — **o teste-chave**: `roles: []` presente NÃO cai em `groups` (fecha o
  escalonamento silencioso).
- `@Test("Authentik default: derive roles do claim 'groups'")` e
  `@Test("Zitadel legado: derive roles do claim `urn:zitadel:iam:org:project:roles`")`
  — garantem os itens 2 e 3.
- `@Test("Contrato #6: groups 'social-care:<role>' satisfazem os RoleGuards…")` e
  `@Test("Contrato #6: group 'superadmin' faz bypass de todos os guards")`
  — contrato com o people-context #6.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` — entrada
  na tabela "Lições Aprendidas" apontando para este ADR e o teste M5.
- **Regra resumida:** ao derivar autorização de múltiplos claims, faça
  **precedência por presença, não por conteúdo**. Um claim de roles presente-mas-vazio
  é resposta final (`[]`), nunca gatilho de fallback — senão um mapping quebrado
  vira escalonamento de privilégio.

## Referências

- Código: `IO/HTTP/Auth/OIDCJWTPayload.swift` (`roleNames`, comentário M5).
- ADRs relacionados: **ADR-027** (multi-issuer), **ADR-031** (claims ACDG +
  defense-in-depth), políticas de RBAC (`RoleGuardMiddleware`).
- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` (achado M5).
