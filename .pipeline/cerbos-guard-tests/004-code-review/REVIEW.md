# cerbos-guard-tests · W2 — REVIEW (code-reviewer)

**Status:** DONE · **Veredito:** APPROVED (round 1) · **Data:** 2026-07-28

## Checklist

- [x] `struct`/`enum` por padrão; `Sendable` onde cruza concurrency domain
- [x] Enum `String` com `CaseIterable` — permite o teste de contrato varrer todos os casos
- [x] Nomeação por papel (`PatientPolicyAction`, `patientControllerUsesTypedInit`)
- [x] Docs explicam o **porquê** (default deny → negação silenciosa), não o quê
- [x] Init genérico preservado — não engessa outros recursos
- [x] Zero `try!`, zero `Any`, zero `print`
- [x] Fakes em test doubles próprios, sem mock ad-hoc
- [x] `swift build -c release`: nenhum warning nos arquivos do ticket

## Achados do próprio W2

### 1. O teste de lista não bastava (corrigido no W1)

`controllerActionsAreValid` confere uma lista escrita à mão — não impediria
alguém de voltar a usar string crua no controller, que é **exatamente como o bug
entrou**. Acrescentado o lint estrutural `patientControllerUsesTypedInit`, que lê
o fonte real, no mesmo padrão do `NoPiiInLogTests` já existente no repo.

### 2. Duplicação da lista de ações (aceito, com razão)

A lista da policy aparece em dois lugares: o enum (produção) e o `policyActions`
do teste. É duplicação **intencional** — se fosse derivada do enum, o teste
compararia o enum consigo mesmo e não detectaria divergência com a policy real.
O teste falha de propósito quando a policy muda, obrigando a atualizar os dois
lados juntos.

### 3. O contrato ainda é verificado por cópia, não contra o arquivo real

O ideal seria o teste ler `patient.yaml` do repo `infra`. Não é possível: são
repositórios separados e o CI do `social-care` não tem a policy em disco.
Alternativas para um follow-up: publicar as ações como artefato versionado, ou
um job de integração que suba o Cerbos e valide as ações de verdade.

### 4. Granularidade por rota (fora de escopo, registrado)

O desenho usa uma ação representativa por grupo. Funciona porque a policy trata o
grupo inteiro igual, mas perde precisão: `auditTrail` e `list` têm a mesma regra
hoje e poderiam divergir amanhã sem que o guard perceba. Passo seguinte natural.

## Veredito

**APPROVED.** O ticket entrega o que faltava (testes) e corrige um bug crítico
que os testes revelaram — com defesa em três camadas contra a regressão:
compilador (init tipado), contrato (enum × policy) e lint estrutural (fonte real).
