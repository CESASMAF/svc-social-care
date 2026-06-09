# ADR-003: ADR carrega obrigatoriamente teste de regressão e Better Pattern

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** um ADR só pode ficar `Aceito`
> quando **todas** as seções abaixo estão preenchidas — incluindo `Teste de
> regressão` e `Better Pattern para skills`. ADR sem essas duas seções fica
> `Proposto` até completar. A intenção é que cada decisão estrutural carregue
> seu próprio mecanismo de enforcement (teste) e sua transferência de
> aprendizado (skill).

## Contexto

ADR-002 estabeleceu a política de testes de regressão, mas não amarrou esses
testes aos ADRs futuros. Sem isso, ADRs podem virar prosa decorativa: "decidimos X"
sem mecanismo para garantir que X continua valendo daqui 6 meses.

Três cenários reais já vistos neste projeto e em projetos análogos:

1. **ADR vira letra morta.** "Decidimos não usar `try!` em produção" — sem teste,
   `try!` volta no próximo PR e ninguém revisita o ADR. Foi exatamente o que
   aconteceu com várias decisões em `handbook/reports/CODE_REVIEW_*_2026_03_*.md`.
2. **Aprendizado fica preso no ADR.** A decisão fica em `DECISIONS/` mas a IA
   que vai gerar próximo handler nunca lê 30 ADRs antes de codar. Sem o Better
   Pattern propagado à skill, cada novo código nasce sem o aprendizado.
3. **ADRs "Aceitos" parcialmente especificados.** Decisão fechada, status
   `Aceito`, mas implementação inconsistente entre devs por falta de teste
   normativo. Surgem variações que ninguém percebe contradizerem o ADR.

A `REMEDIATION_PIPELINE_2026_05_14.md` planeja 37 ADRs novos (ADR-002 a ADR-038).
Sem este meta-ADR, cada um deles pode entrar como prosa sem enforcement.

## Decisão

`ADR-TEMPLATE.md` ganha duas seções **obrigatórias**:

1. **Teste de regressão** — identificador do teste (`Tests/.../Regression/...::test_…`)
   que enforça a decisão, ou mecanismo equivalente (lint test, schema snapshot)
   quando o ADR não exige fix de código.
2. **Better Pattern para skills** — qual skill é atualizada com a "lição aprendida"
   e (opcionalmente) qual doc em `handbook/tooling/swift/<area>/` carrega o
   pattern completo.

Adicionalmente, ADRs só podem transitar `Proposto` → `Aceito` quando essas duas
seções estão preenchidas. Status `Aceito` sem teste/pattern é considerado bug
e o ADR é rebaixado para `Proposto` em review.

## Alternativas consideradas

- **Manter template livre, confiar em PR review.** Descartada — mesma falha que
  motivou ADR-002. Sem mecanismo automatizado, depende de memória humana, não
  escala, e desaparece quando equipe rotaciona.
- **Seções opcionais com nota "preencha quando possível".** Descartada — semi-obrigatório
  é o mesmo que opcional. Em 2 meses, ninguém preenche.
- **Tornar teste de regressão obrigatório mas Better Pattern opcional.** Descartada —
  cobre a regressão imediata mas não fecha o loop de aprendizado para IA-gerada.
  Cenário 2 (aprendizado preso) continua aberto.
- **ADR só fica `Aceito` após executar a pipeline 4-Wave completa do ticket
  correspondente.** Considerada mas descartada como rigidez excessiva — alguns
  ADRs são puramente arquiteturais e o teste/skill update pode vir em ticket
  separado já planejado.

## Consequências

### Positivas

- Cada ADR carrega seu próprio mecanismo de enforcement em produção (teste).
- Lições aprendidas viajam automaticamente para skills (IA-gerada aplica por default).
- ADR "Aceito" passa a ser um contrato verificável, não declaração.
- Revisão de PR fica mais barata — ADR sem as seções é rejeitado mecanicamente.

### Negativas / custos

- Custo de escrita de ADR aumenta (~15-20%) — autor precisa identificar/criar teste e atualizar skill antes de promover para Aceito.
- ADRs documentais puros (raros) precisam justificar **por que** não há teste/skill update — adiciona 1 parágrafo.
- Risco de gaming: autor cita teste que não enforça de verdade ("`make test` cobre"). Mitigação: review valida que o teste cobre o invariante específico do ADR.

### Ações requeridas

- [x] `ADR-TEMPLATE.md` ganha as 2 seções novas + nota de promoção `Proposto → Aceito`
- [x] ADR-002 (criado antes deste) já segue o novo formato — auditado, conforme
- [x] ADR-003 (este) segue o formato
- [x] Atualizar `DECISIONS.md` com a regra de promoção
- [ ] Próximos ADRs (004 a 038, conforme pipeline) seguem o template novo

## Plano de adoção

1. **Imediato (T-002 — este ticket):** template atualizado, ADR-003 criado já no formato novo.
2. **ADR-002 retrocompat:** ADR-002 (criado em T-001 antes deste meta-ADR) já tinha as seções "Teste de regressão" e "Better Pattern para skills" — sem retrofit necessário.
3. **Próximos ADRs:** T-004 a T-038 da pipeline criam ADRs novos seguindo este template. Cada PR que cria ADR sem as 2 seções é rejeitado em review.
4. **Auditoria periódica:** ao final de cada sprint da pipeline, verificar `DECISIONS.md` por ADRs com status inconsistente (Aceito sem teste/pattern). Rebaixar se necessário.

## Como reverter

Reverter ADR-003 significa permitir ADRs "Aceitos" sem enforcement — efetivamente cancelar ADR-002 também (testes sem amarra ao ADR perdem rastreabilidade).

Caminho técnico:
1. Editar `ADR-TEMPLATE.md` removendo as 2 seções obrigatórias e a nota de promoção
2. Marcar este ADR como `Deprecado` com data e justificativa
3. Atualizar `DECISIONS.md` removendo a regra

Não recomendado. Se necessário, registrar **por que** o custo de manutenção excedeu o valor (geralmente sinal de problema separado: equipe muito pequena, escopo do projeto encolheu, etc.).

## Teste de regressão

ADR-003 é meta-ADR sobre **estrutura** de ADRs — não há código a testar diretamente. O mecanismo de enforcement é **revisional**: PR que cria ADR sem as 2 seções é rejeitado.

Para tornar isso mais robusto, planejado em **T-038** da pipeline:

`scripts/check_adr_completeness.sh` — script que percorre `handbook/architecture/DECISIONS/ADR-*.md` e falha se algum ADR com status `Aceito` não contém headings `## Teste de regressão` E `## Better Pattern para skills`. Rodar em CI.

Até T-038 fechar, enforcement é manual em code review.

## Better Pattern para skills

- **Skill atualizada:** nenhuma skill Swift específica é afetada (este ADR é cross-skill, governança documental).
- **Handbook:** este ADR + ADR-TEMPLATE.md atualizado servem como pattern.
- **Regra resumida:** `ADR sem '## Teste de regressão' E '## Better Pattern para skills' não pode ter status 'Aceito' — fica 'Proposto'`.

Esta regra é referenciada em `DECISIONS.md` como política universal.

## Referências

- [ADR-002](ADR-002-regression-test-policy.md) — Política de testes de regressão (motivação original)
- `handbook/architecture/DECISIONS/ADR-TEMPLATE.md` — template atualizado
- `handbook/architecture/DECISIONS.md` — índice e regra de promoção
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-002 — especificação do ticket
