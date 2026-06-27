---
name: swift-api-design-guidelines
description: >
  Aprofundamento técnico (horizontal) das Swift API Design Guidelines oficiais
  aplicadas ao backend `social-care` — naming, argument labels, doc comments,
  terminologia e convenções. Use para projetar/revisar/melhorar APIs Swift:
  clareza no ponto de uso, nomeação por papel, gramática fluente, pares
  mutating/nonmutating, capacidades `-ing`/`-ible`, booleanos como asserção,
  e doc Markdown obrigatória em API pública. Para "modele esta camada do
  social-care", use as verticais (`swift-domain-modeler`, `swift-expert`);
  esta skill é a referência de estilo de API que elas seguem.
---
# Swift API Design Guidelines — aplicadas ao social-care

> **Contexto deste serviço:** o `social-care` adota as Swift API Design
> Guidelines oficiais como referência **estrita**. O espelho in-place do
> handbook é a fonte canônica — abra a partir da raiz do repo:
> `handbook/tooling/swift/api-design-guidelines/` (`index.md`, `protocols.md`,
> `concurrency.md`, `memory_safe.md`, `patterns_guideline.md`). O prompt de
> review é `handbook/Agents/reviewr.md`. **Em conflito, handbook prevalece.**
>
> Esta skill é horizontal: dá a *profundidade da regra de naming*; as
> verticais decidem *onde aplicá-la*. Doc Markdown é **obrigatória** em toda
> API pública nova (sumário em fragmento de frase + `- Parameter` + `- Returns`).

## Como esta API "fala" no social-care (exemplos canônicos)

| Regra | Exemplo do projeto | Anti-exemplo |
|---|---|---|
| Clareza no ponto de uso | `repository.exists(byPersonId: id)` | `repository.checkExistence(id, 1)` |
| Nomeação por **papel**, não por tipo | `lookupValidator: any LookupValidating` | `validator: Validator` |
| Capacidade com `-ing`/`-ible` | `LookupValidating`, `AppErrorConvertible`, `EventSourcedAggregate`, `PersonExistenceValidating` | `LookupValidatorProtocol` |
| "O que é" = substantivo | `Command`, `Query`, `DomainEvent` | `Commandable` |
| Mutating = verbo imperativo | `patient.updateSocialIdentity(_:)`, `appendDiagnosis(_:)` | `patient.socialIdentityUpdate()` |
| Non-mutating = substantivo/`-ed`/`-ing` | `financial.perCapita(_:)`, `densityRatio(_:)` | `financial.calculatePerCapita(_:)` |
| Boolean como asserção | `hasValidCheckDigits`, `isPrimaryCaregiver`, `residesWithPatient` | `validCheckDigits`, `caregiver` |
| Impl por **estratégia**, nunca `*Impl` | `SQLKitPatientRepository`, `InMemoryEventBus`, `FakeLookupValidator` | `PatientRepositoryImpl` |
| Erro como `enum` por causa | `case invalidLookupId(table:id:)`, `personIdAlreadyExists` | `throw NSError(...)` / string concatenada |

## Work Decision Tree

### 1) Revisar código existente
- Inspecione declaração **e** call sites juntos, não só a declaração.
- Clareza/fluência: `references/promote-clear-usage.md`, `references/strive-for-fluent-usage.md`.
- Labels/parâmetros: `references/parameters.md`, `references/argument-labels.md`.
- Doc comments e markup: `references/fundamentals.md`.
- Convenções/overloads: `references/general-conventions.md`, `references/special-instructions.md`.

### 2) Melhorar
- Renomeie APIs ambíguas, redundantes ou com papel obscuro.
- Refatore labels para a chamada ler como frase em inglês.
- Substitua parâmetros com nome fraco por nomes por papel.
- Resolva overloads que ficam ambíguos com tipagem fraca (`Any`, `String`).

### 3) Implementar feature nova
- Comece dos exemplos de uso antes de fixar a declaração.
- Escolha base name + labels para a chamada ler natural.
- Defaults só quando simplificam o uso comum; coloque-os perto do fim.
- Pares mutating/nonmutating com naming consistente.
- Doc comment conciso em **toda** declaração nova (regra do projeto, não opcional).

## Quick Reference

### Name Shape
| Situação | Padrão |
|---|---|
| Mutating verb | `reverse()`, `updateSocialIdentity(_:)` |
| Nonmutating verb | `reversed()`, `strippingNewlines()` |
| Nonmutating noun op | `union(_:)`, `perCapita(_:)` |
| Mutating noun op | `formUnion(_:)` |
| Factory method | `makeSUT(...)` (em testes) |
| Boolean query | `isEmpty`, `hasValidCheckDigits` |

### Argument Label Rules
| Situação | Regra |
|---|---|
| Args distinguíveis sem label | Omita labels só se a distinção continuar clara |
| Init de conversão value-preserving | Omita o primeiro label (`CPF(_ raw: String)`) |
| 1º arg em frase preposicional | Use label da preposição (`exists(byPersonId:)`) |
| 1º arg em frase gramatical | Omita o primeiro label |
| Args com default | Mantenha labels |
| Demais | Sempre label |

### Documentation Rules
| Tipo de declaração | O sumário descreve |
|---|---|
| Função / método | O que faz e o que retorna |
| Subscript | O que acessa |
| Initializer | O que cria |
| Outras | O que é |

## Review Checklist

- [ ] Call sites claros sem ler a implementação.
- [ ] Base names com todas as palavras para remover ambiguidade; sem repetir nome de tipo.
- [ ] APIs sem efeito colateral leem como substantivo/query; com efeito, como verbo imperativo.
- [ ] Pares mutating/nonmutating consistentes; booleanos como asserção.
- [ ] Labels de 1º arg seguem regra de gramática/conversão; demais labelados.
- [ ] **Toda** declaração pública tem sumário + markup (`- Parameter`/`- Returns`/`- Throws`).
- [ ] Complexidade documentada em computed property não-`O(1)`.
- [ ] Overloads evitam distinção só por tipo de retorno / ambiguidade de tipo fraco.
- [ ] Impl nomeada por estratégia (`SQLKit*`/`InMemory*`/`Fake*`), nunca `*Impl`.

## References
- `references/fundamentals.md` — princípios núcleo e regras de doc comment
- `references/promote-clear-usage.md` — redução de ambiguidade, naming por papel
- `references/strive-for-fluent-usage.md` — fluência, efeitos colaterais, pares mutating
- `references/use-terminology-well.md` — termos de arte, abreviações, precedência
- `references/general-conventions.md` — complexidade, free functions, casing, overloads
- `references/parameters.md` — naming de parâmetros e estratégia de default
- `references/argument-labels.md` — regras de 1º arg e gerais
- `references/special-instructions.md` — tuple/closure naming e polimorfismo não-restrito

## Philosophy
- Semântica clara no ponto de uso > esperteza na declaração.
- Convenções Swift estabelecidas antes de inventar estilo local.
- Otimize por manutenibilidade e revisabilidade da superfície pública.
- Aplique a menor mudança que melhora a clareza.
