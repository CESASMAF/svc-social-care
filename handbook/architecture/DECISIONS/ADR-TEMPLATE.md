# ADR-NNN: Título curto e descritivo

**Data:** YYYY-MM-DD
**Status:** Proposto | Aceito | Superseded by ADR-XXX | Deprecado | Rejeitado
**Supersedes:** ADR-XXX (se aplicável)

> **Promoção Proposto → Aceito (ADR-003):** um ADR só pode ficar `Aceito`
> quando **todas** as seções abaixo estão preenchidas — incluindo `Teste de
> regressão` e `Better Pattern para skills`. ADR sem essas duas seções fica
> `Proposto` até completar. A intenção é que cada decisão estrutural carregue
> seu próprio mecanismo de enforcement (teste) e sua transferência de
> aprendizado (skill).

## Contexto

O que motiva esta decisão? Qual é o estado atual, qual é o problema, e qual
restrição obriga uma escolha? Inclua dados objetivos: gargalo, bug, mudança
de requirement, prazo, dependência externa.

Evite descrever a solução aqui — só o problema e o cenário. Se o leitor não
entender o contexto, a decisão vai parecer arbitrária no futuro.

## Decisão

O que foi decidido, em uma ou duas sentenças concretas. Use voz ativa:
"Adotamos X", "Removemos Y", "Substituímos Z por W".

Detalhe técnico mínimo necessário para entender o que vai ser feito — mas
sem virar guia de implementação.

## Alternativas consideradas

Liste pelo menos as opções avaliadas e a razão de cada uma ter sido
descartada. Sem isso, futuro-você (ou alguém novo no time) vai perder tempo
re-considerando as mesmas alternativas. Formato sugerido:

- **Alternativa A:** descrição curta. Descartada porque …
- **Alternativa B:** descrição curta. Descartada porque …

## Consequências

O que muda na prática? Inclua:

- **Positivas:** ganhos diretos.
- **Negativas / custos:** o que perdemos, complexidade adicionada, debt
  criado.
- **Ações requeridas:** mudanças concretas no código, infra, docs, CI.

## Plano de adoção

Passos sequenciais. Cada passo deve ser uma ação atômica verificável:

1. …
2. …
3. …

## Como reverter

Se essa decisão precisar ser revertida, qual é o caminho? Esta seção pode
ser curta ("git revert") quando a mudança é localizada, ou detalhada quando
afeta dados / infra.

## Teste de regressão

> **Obrigatória.** ADR sem teste de regressão fica **Proposto**, nunca
> **Aceito**. Regra firmada em ADR-003.

Identificador do teste que enforça esta decisão. Formato:

`Tests/social-care-sTests/Regression/<Tema>/<NomeRegressionTests>.swift::test_<ACHADO_ID>_<descrição>()`

Em uma frase: o que esse teste garante. Se a fix da decisão for distribuída
em múltiplos arquivos, listar todos os testes.

Exemplos:

- `Tests/.../Regression/Concurrency/OptimisticLockRegressionTests.swift::test_S_C3_DB_2_lost_update_is_rejected()` — garante que `save` rejeita escrita com `version` obsoleta.
- `Tests/.../Regression/Security/PeopleContextRegressionTests.swift::test_S_C1_unavailable_blocks_registration()` — garante que upstream indisponível bloqueia (não fail-open).

Quando o ADR não exige fix de código (e.g. ADR de política/cadência), citar o **mecanismo de enforcement** equivalente — geralmente um lint test ou um schema snapshot:

- "Lint test em `Tests/.../Regression/<Tema>/All<X>Test.swift` percorre todos os …"
- "Schema snapshot em `Tests/.../Regression/DataIntegrity/SchemaSnapshotTest.swift`"

Se nenhum teste/lint é aplicável (caso raro — geralmente ADR documental puro), justificar **por que** nesta seção em vez de citar teste.

## Better Pattern para skills

> **Obrigatória.** Onde a lição aprendida vive permanentemente para que IA-gerada
> e novos devs apliquem por default. ADR sem Better Pattern fica **Proposto**.

Indicar:

1. **Skill atualizada:** `.claude/skills/swift-{domain-modeler|application-orchestrator|io-implementer|test-writer|expert}/SKILL.md` — qual skill ganha entrada na tabela "Lições Aprendidas (regressões prevenidas)".
2. **(Opcional) Doc do handbook:** `handbook/tooling/swift/<area>/<nome>.md` — pattern completo, anti-patterns, exemplos. Cite o caminho.
3. **Regra resumida** em 1-3 linhas: a versão TL;DR que cabe na tabela da skill.

Exemplo (extraído de ADR-002):

> - **Skill atualizada:** `.claude/skills/swift-test-writer/SKILL.md` — entrada na tabela "Lições Aprendidas (regressões prevenidas)" com link para este ADR.
> - **Handbook:** `handbook/tooling/swift/testing/regression-pattern.md` — padrão completo.
> - **Regra resumida:** todo `@Test` de regressão tem ID do achado no nome, vive em `Tests/.../Regression/<subpasta>/`, e usa `RegressionFixture` para determinismo.

## Referências

Links internos (outros ADRs, docs do handbook) e externos (release notes,
RFCs, artigos).
