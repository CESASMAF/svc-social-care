# cerbos-guard-tests — testes do wiring Cerbos + correção do contrato de ações

## Origem

Follow-up da migração Ory: o PR #2 (`feat/ory-cerbos-wiring`) entregou 167 linhas
(`CerbosClient`, `CerbosGuardMiddleware`, wiring no `PatientController` e no
`configure`) **sem nenhum teste**.

## Achado que a investigação revelou (🔴 crítico)

Antes de escrever os testes, verifiquei o contrato entre o que o controller pede
e o que a policy do Cerbos declara (`infra:stack/cells/idp/config/cerbos/policies/social-care/patient.yaml`).
**Duas das três ações usadas não existem na policy.**

Provado contra o **Cerbos 0.53.0 real** (container na x99, com as policies do repo):

| Ação pedida pelo controller | Resultado real |
|---|---|
| `read` (4 rotas de leitura) | **EFFECT_DENY** |
| `create` (5 rotas de escrita) | **EFFECT_DENY** |
| `admit` (3 rotas de lifecycle) | EFFECT_ALLOW ✅ |

A policy declara `list`, `getById`, `getByPersonId`, `auditTrail`, `register`,
`family`, `caregiver`, `socialIdentity`, `admit`, `discharge`, `readmit`,
`withdraw`, `anonymize` — e a única regra com `actions: ["*"]` é o bypass de
`superadmin` (derived role).

**Impacto:** ao definir `CERBOS_URL` em produção, **9 das 12 rotas de paciente
passam a responder 403 para todos os usuários** que não sejam superadmin. Como o
Cerbos entra por feature-flag, o problema só apareceria no momento da ativação —
exatamente quando ninguém quer descobrir isso.

## Escopo

1. **Corrigir as ações** para nomes que existem na policy.
2. **Impedir a regressão por construção**: tipo com os valores válidos, para que
   uma ação inventada não compile — o erro atual é invisível ao compilador, ao
   `swift test` e ao code review humano (`"read"` parece perfeitamente razoável).
3. **Testar o que existe**: `CerbosClient` (ALLOW/DENY/indisponível/resposta
   inesperada) e `CerbosGuardMiddleware` (flag off, ALLOW, DENY, fail-open).

## Decisão de projeto

O middleware continua genérico (`resource`/`action` como String) — outros
recursos (lookup, people) usarão o mesmo tipo. A segurança vem de um enum
`PatientPolicyAction` que espelha a policy e é o que o `PatientController` passa.
Assim o compilador barra ação inexistente **para o recurso patient**, sem
engessar o middleware.

Mantido o agrupamento por ação representativa do PR original: dentro de cada
grupo de rotas as regras da policy são idênticas (todas as de leitura exigem
worker|owner|admin; todas as de escrita cadastral exigem worker), então
`list`/`register`/`admit` representam corretamente seus grupos. Granularidade por
rota fica registrada como passo seguinte.

## Fora de escopo

- Granularidade de ação por rota (hoje: 3 grupos).
- Testes de integração contra um Cerbos real no CI — a verificação foi manual
  nesta rodada; automatizá-la exigiria subir container no pipeline.
