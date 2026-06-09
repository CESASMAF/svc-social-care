# ADR-039: Política de erasure ao consumir `people.person.deleted` (LGPD × No-Delete)

**Data:** 2026-06-09
**Status:** Proposto
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** este ADR fica `Proposto` até (a)
> ratificação pelo **encarregado/DPO** (decisão tem peso jurídico — LGPD), e (b)
> implementação do consumer + teste de regressão + Better Pattern. **Nenhum
> código de consumo de `people.person.deleted` deve ser mergeado antes do aval
> jurídico.**

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

## Decisão (proposta a ratificar)

Ao consumir `people.person.deleted`, o `social-care` **NÃO faz hard-delete**.
Em vez disso, executa **erasure por anonimização/pseudonimização da PII direta**
do paciente correlato (nome, CPF, NIS, CNS, endereço, contatos, datas finas),
**preservando**:

1. o **registro clínico** e os agregados (diagnósticos, assessments etc.)
   referenciados por identificador interno **pseudonimizado** (`patientId` /
   `personId`), sob base de **obrigação legal / exercício regular de direitos**
   (Art. 16, I; Art. 11, II.a/d);
2. o **audit trail** intacto (imutável por ADR — retenção legal), registrando a
   própria operação de erasure como evento auditável (ator = `superadmin` que
   originou no people-context, propagado no evento).

O passo concreto e a **fronteira PII a apagar vs. campos a pseudonimizar** são
definidos com o encarregado/DPO antes da implementação (ver Plano de adoção).

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

1. **Aval jurídico (DPO):** validar a base de retenção e a lista exata de campos
   PII a anonimizar/eliminar vs. pseudonimizar. **Bloqueia os passos seguintes.**
2. Modelar operação de domínio `AnonymizePatientPII` (mantém `patientId`,
   neutraliza VOs de PII) — segue `parse → validate → domain → persist → publish`.
3. Implementar consumer `people.person.deleted` em `configure.swift` (idempotente,
   at-least-once), correlacionando por `personId`.
4. Emitir evento de audit `PatientPIIAnonymized` no Outbox.
5. Teste de regressão (ver seção) + Better Pattern.
6. Promover este ADR para `Aceito`.

## Como reverter

Antes da implementação: nenhum efeito (apenas documento). Após implementação:
`git revert` do consumer + da operação de domínio. **Importante:** a
anonimização aplicada a dados já processados é, por desenho, **irreversível** —
reverter o código não restaura PII apagada (comportamento desejado).

## Teste de regressão

> **Pendente (mantém o ADR em `Proposto`).** A criar quando do aval:
> `Tests/social-care-sTests/Regression/Security/ErasureRegressionTests.swift::test_PEO_DELETE_anonymizes_pii_and_preserves_audit()`
> — garante que consumir `people.person.deleted` neutraliza a PII direta do
> paciente **e** mantém `patientId`/audit trail intactos (não hard-delete).

## Better Pattern para skills

> **Pendente (mantém o ADR em `Proposto`).** Ao aceitar:
> - **Skill:** `.claude/skills/swift-domain-modeler/SKILL.md` e
>   `swift-application-orchestrator/SKILL.md` — entrada "Lições Aprendidas":
>   *erasure cross-service em domínio No-Delete = anonimização/pseudonimização
>   da PII com retenção do registro+audit, nunca hard-delete*.
> - **Regra resumida:** evento de eliminação LGPD do people-context ⇒
>   `AnonymizePatientPII` (preserva `patientId` + audit), nunca DELETE.

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
