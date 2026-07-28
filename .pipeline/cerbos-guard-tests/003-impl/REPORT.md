# cerbos-guard-tests · W1 — GREEN (implementer)

**Status:** DONE · **Data:** 2026-07-28

## 1. `PatientPolicyAction` (novo) — o contrato vira tipo

`Sources/social-care-s/IO/HTTP/Auth/PatientPolicyAction.swift`

Enum `String`/`CaseIterable` com as 19 ações da policy. O doc registra **por que
existe**: a ação é a chave da decisão do PDP e o Cerbos é default deny, então
ação inexistente não dá erro — dá negação silenciosa.

## 2. `CerbosGuardMiddleware` — init tipado

Além do init genérico (`resource:`/`action:`, mantido para recursos que ainda não
têm enum), agora há `init(patient:)`. O compilador passa a barrar ação inválida
para o recurso `patient`, sem engessar o middleware para os demais.

## 3. `PatientController` — correção do bug

```diff
- CerbosGuardMiddleware(resource: "patient", action: "read")     → 403 em 4 rotas
+ CerbosGuardMiddleware(patient: .list)
- CerbosGuardMiddleware(resource: "patient", action: "create")    → 403 em 5 rotas
+ CerbosGuardMiddleware(patient: .register)
- CerbosGuardMiddleware(resource: "patient", action: "admit")     (já correta)
+ CerbosGuardMiddleware(patient: .admit)
```

O comentário do grupo passou a explicar que a ação é **representativa** e por que
isso é válido: dentro de cada grupo a policy aplica a mesma regra a todas as
rotas.

## Resultado

13/13 testes do ticket GREEN · suíte completa **477 testes em 87 suites**, todos
passando.
