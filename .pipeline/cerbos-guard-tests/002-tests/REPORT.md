# cerbos-guard-tests · W0 — RED (swift-test-writer)

**Status:** DONE · **Data:** 2026-07-28

## Investigação que antecedeu os testes

Antes de escrever, verifiquei o contrato entre o `PatientController` e a policy
do PDP. Rodei o **Cerbos 0.53.0 real** (container na x99, policies do repo
`infra`) e consultei o `/api/check/resources`:

| principal | action | resultado |
|---|---|---|
| `social-care:worker` | `read` | **EFFECT_DENY** |
| `social-care:worker` | `create` | **EFFECT_DENY** |
| `social-care:worker` | `admit` | EFFECT_ALLOW |
| `social-care:worker` | `list` | EFFECT_ALLOW |
| `social-care:worker` | `register` | EFFECT_ALLOW |

O controller pedia `read` e `create` — nomes que **não existem** na policy. Como
o Cerbos é *default deny*, 9 das 12 rotas de paciente responderiam 403 assim que
`CERBOS_URL` fosse definido.

## Testes escritos (13 casos)

`Tests/social-care-sTests/IO/Auth/CerbosGuardTests.swift`

**Contrato com a policy (o que pega o bug):**

| Teste | Fixa o quê |
|---|---|
| `everyDeclaredActionExistsInPolicy` | toda ação de `PatientPolicyAction` tem regra na policy |
| `controllerActionsAreValid` | as 3 ações representativas dos grupos existem |
| `patientControllerUsesTypedInit` | **lint estrutural** (padrão do `NoPiiInLogTests`): o controller não pode voltar a passar string crua — foi assim que o bug entrou |

**`CerbosClient`:** ALLOW→true · DENY→false · status≠200→nil · ação ausente na
resposta→nil · corpo indecodificável→nil · principal vazio→`anonymous`.

**`CerbosGuardMiddleware`:** flag off→pass-through · ALLOW→segue · DENY→403 **e o
handler não executa** · PDP indisponível→defere (fail-open documentado).

## Verificação RED

```
error: cannot find 'PatientPolicyAction' in scope   (4 ocorrências)
```

## Nota de design

Os testes de erro do cliente formam um conjunto deliberado: **status 502, corpo
inválido e ação ausente resultam em `nil`, nunca em `false`**. Confundir "PDP
quebrado" com "acesso negado" transformaria uma indisponibilidade do Cerbos numa
negação de serviço para todos os usuários — o oposto do fail-open que o desenho
escolheu.
