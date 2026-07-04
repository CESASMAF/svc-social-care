# ADR-039: Política de erasure ao consumir `people.person.deleted` (LGPD × No-Delete)

**Data:** 2026-06-09
**Status:** Aceito
**Supersedes:** —

> **Aval registrado (2026-06-09):** a fronteira PII foi ratificada pelo
> responsável do deploy ACDG-BV (no papel de decisor/encarregado) como **"só PII
> do titular"** — anonimizar `personalData`, `civilDocuments` e `address`;
> preservar registro clínico, audit trail e `familyMembers` (terceiros). Consumer,
> teste de regressão e Better Pattern implementados (seções abaixo), satisfazendo
> a promoção da ADR-003.

## Contexto

O **people-context #6** (`feat/authentik-auth-and-user-lifecycle`, mergeado na
`main`) introduziu o fluxo de **erasure** (direito à eliminação, LGPD): o
endpoint `DELETE /api/v1/people/:personId` (restrito a `superadmin`) executa
hard-delete IdP-first → DB e **emite o evento NATS novo `people.person.deleted`**
com payload `{ personId }` (sem PII). Ver `people-context/src/routes/people.ts`
(linhas ~528-584) e `people-context/src/events/publisher.ts`.

O `social-care` **já é consumidor NATS** do people-context: hoje assina apenas
`people.person.registered` e correla `personId`↔CPF (`configure.swift`, bloco
"NATS Subscriber"). **Não há handler para `people.person.deleted`** — o evento é
silenciosamente ignorado.

Tensão estrutural:

- O `social-care` é **CRU / No-Delete** por design e mantém **audit trail
  retido por 5 anos** (e Protection BC por 10 anos). Registros clínicos de
  pacientes raros são **dados sensíveis de saúde**.
- O people-context faz **hard-delete** (Art. 5, XIV — "eliminação: exclusão de
  dado [...]"), mas o social-care **não pode** simplesmente apagar o paciente:
  perderia (i) o audit obrigatório e (ii) registros clínicos sob retenção legal.
- O emissor **não define SLA nem contrato** de como/quando o consumidor deve
  reagir ao `people.person.deleted` (lacuna identificada no mapeamento do #6).

Sem decisão explícita, o estado atual é **fail-silent**: a PII do paciente
permanece no `social-care` indefinidamente após uma solicitação de eliminação
válida no people-context — risco de não-conformidade.

### Base legal (LGPD — Lei 13.709/2018, citações por artigo)

- **Art. 5, XIV** — "eliminação" é a *exclusão* do dado; a lei **não a equipara**
  a anonimização (são alternativas distintas em Art. 18, IV).
- **Art. 5, III + XI e Art. 12** — dado **anonimizado** (irreversível por meios
  razoáveis) **sai do escopo da LGPD**. **Art. 13, §4** — **pseudonimização**
  (reversível via informação adicional mantida separada) **continua dado pessoal**.
- **Art. 11** — tratamento de dado sensível de saúde é permitido sem
  consentimento quando indispensável para **obrigação legal/regulatória (II.a)**,
  **tutela da saúde por serviços/profissionais de saúde (II.f)** e **exercício
  regular de direitos (II.d)**. Como a base do social-care **não é
  consentimento**, o **Art. 18, VI** (eliminação de dados tratados *com
  consentimento*) **não se aplica diretamente**.
- **Art. 16** — após o término do tratamento, a **conservação é permitida** para
  **cumprimento de obrigação legal/regulatória (I)**, pesquisa com anonimização
  sempre que possível (II), e uso exclusivo do controlador desde que anonimizado
  (IV).
- **Art. 18, IV** — o titular pode pedir **anonimização, bloqueio ou eliminação**
  de dados desnecessários/excessivos/ilegais (três respostas distintas válidas).

Leitura factual: a LGPD **permite reter** o audit e o registro clínico sob
obrigação legal (Art. 16, I; Art. 11, II.a/d), **desde que** a PII de uso
corrente seja neutralizada — o que a lei admite via **anonimização** (Art. 12)
ou, no mínimo, **bloqueio** (Art. 18, IV).

## Decisão (ratificada)

Ao consumir `people.person.deleted`, o `social-care` **NÃO faz hard-delete**. Em
vez disso executa **erasure por anonimização da PII direta** do paciente
correlato. A fronteira ratificada é **"só PII do titular"**:

- **Anonimizado (removido → `nil`):** `personalData` (nome, nome da mãe, data de
  nascimento, telefone, nome social, sexo), `civilDocuments` (CPF, NIS, RG, CNS) e
  `address` (CEP, logradouro, bairro, número, complemento). Os VOs não admitem
  valor "anonimizado parcial" (ex.: `CPF`/`PersonalData` exigem valor válido no
  `init`), então a anonimização é a **remoção** dos VOs opcionais.
- **Preservado** (retenção sob obrigação legal — Art. 16, I; Art. 11, II.a/d):
  `diagnoses` e assessments (registro clínico), `status`, `id`/`personId`
  (correlação), `familyMembers` (terceiros — sujeitos a erasure próprio) e o
  **audit trail** (imutável). A própria operação é auditada via
  `PatientPIIAnonymizedEvent` (payload sem PII; ator propagado do evento).

Implementação: `Patient.anonymizePII(actorId:)` (idempotente) →
`AnonymizePatientPIICommandHandler` → consumer NATS `people.person.deleted` em
`configure.swift`. Idempotência **por estado** (segura para entrega at-least-once).

## Alternativas consideradas

- **Hard-delete do paciente (espelhar o people-context).** Descartada: viola a
  retenção legal obrigatória do audit (5 anos) e dos registros clínicos
  (Art. 16, I; Art. 11), e quebra o invariante No-Delete (ADR de domínio).
- **Ignorar o evento (fail-silent — estado atual).** Descartada: deixa PII
  sensível no sistema após eliminação válida → risco de não-conformidade e de
  divergência IdP↔social-care sem detecção.
- **Apenas bloqueio (Art. 18, IV) sem anonimizar.** Mantida como *fallback*
  aceitável se o jurídico considerar a anonimização inviável para certos campos,
  mas inferior: dado pessoal segue existindo e re-identificável.
- **Anonimização total (Art. 12) de todo o registro.** Descartada como default:
  registros clínicos podem ser re-identificáveis (datas, ICD raros, família) —
  anonimização irreversível real é difícil sem destruir utilidade clínica/legal;
  por isso a recomendação é **pseudonimizar** o registro e **anonimizar/eliminar**
  apenas a PII direta.

## Consequências

- **Positivas:** honra o direito do titular (PII direta neutralizada) **e**
  cumpre a retenção legal; mantém audit íntegro; fecha a lacuna fail-silent.
- **Negativas / custos:** exige um caminho de mutação que "apaga sem deletar"
  num domínio No-Delete (precisa de operação de domínio explícita, ex.
  `AnonymizePatientPII`); define contrato de idempotência e ordenação
  (at-least-once) para o consumer; exige decisão jurídica sobre a fronteira PII.
- **Ações requeridas:** (1) ratificação DPO; (2) handler de domínio/application de
  anonimização; (3) subscriber `people.person.deleted` em `configure.swift`;
  (4) teste de regressão; (5) entrada na skill.

## Plano de adoção

1. [x] **Aval da fronteira PII** ("só PII do titular") — registrado 2026-06-09.
2. [x] `Patient.anonymizePII(actorId:)` + `PatientPIIAnonymizedEvent` (registrado
   no `DomainEventRegistryBootstrap`).
3. [x] `AnonymizePatientPIICommandHandler` + consumer NATS `people.person.deleted`
   em `configure.swift` (idempotente, at-least-once), correlacionando por `personId`.
4. [x] Evento de audit `PatientPIIAnonymizedEvent` no Outbox (via `save`).
5. [x] Teste de regressão + Better Pattern (ver seções).
6. [x] Promovido para `Aceito`.

> **Follow-up aberto:** alinhar com o time do people-context um **SLA/contrato
> cross-service** de erasure (quando/como o consumidor deve agir) — ainda
> indefinido pelo emissor.

## Como reverter

Antes da implementação: nenhum efeito (apenas documento). Após implementação:
`git revert` do consumer + da operação de domínio. **Importante:** a
anonimização aplicada a dados já processados é, por desenho, **irreversível** —
reverter o código não restaura PII apagada (comportamento desejado).

## Teste de regressão

`Tests/social-care-sTests/Regression/Security/ErasureRegressionTests.swift::test_PEO_DELETE_anonymizes_pii_and_preserves_audit()`
— garante que consumir `people.person.deleted` neutraliza a PII direta
(`personalData`/`civilDocuments`/`address` → `nil`), **mantém** o registro clínico
(`diagnoses`) e emite `PatientPIIAnonymizedEvent` no audit trail (não hard-delete).

Cobertura complementar:
- `Domain/v2/PatientErasureTests.swift` — mutation, preservação clínica,
  registro do evento + bump de `version`, idempotência.
- `Application/AnonymizePatientPIITests.swift` — handler: anonimiza correlato,
  no-op para `personId` sem prontuário, idempotência em reentrega, `personId` inválido.

## Better Pattern para skills

- **Skill:** `.claude/skills/swift-domain-modeler/SKILL.md` (e
  `swift-application-orchestrator/SKILL.md`) — adicionar à tabela "Lições
  Aprendidas" apontando para este ADR e o teste de regressão.
- **Regra resumida:** erasure cross-service em domínio **CRU/No-Delete** =
  **anonimizar a PII direta** (remover VOs opcionais → `nil`) **preservando**
  registro clínico + audit trail; **nunca** hard-delete. Disparado por
  `people.person.deleted`; idempotência **por estado** (at-least-once); a própria
  operação é auditada por evento sem PII (`PatientPIIAnonymizedEvent`).

## Referências

- people-context #6: `src/routes/people.ts` (erasure), `src/events/publisher.ts`
  (`people.person.deleted`).
- LGPD: Art. 5 (III, XI, XIV), Art. 11 (II.a/d/f), Art. 12, Art. 13 §4,
  Art. 16 (I, IV), Art. 18 (IV, VI).
- ADRs relacionados: ADR-011 (PeopleContext fail-secure + Bearer), ADR-015
  (audit trail), ADR-017 (LogSanitizer — sem PII em log).
- Pipeline de remediação (`handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md`):
  ADR-029/T-029 (JWKS refresh + cache de introspection — *hardening de auth já
  catalogado*) e ADR-032/T-032 (lint default-deny `RoleGuardMiddleware` em
  `/api/*`). Este ADR usa **039** por ser tema externo ao range reservado 026-038.
