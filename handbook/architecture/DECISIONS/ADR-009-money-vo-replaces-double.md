# ADR-009: Money VO substitui Double em todo valor monetário

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** um ADR só pode ficar `Aceito`
> quando **todas** as seções abaixo estão preenchidas — incluindo `Teste de
> regressão` e `Better Pattern para skills`. ADR sem essas duas seções fica
> `Proposto` até completar.

## Contexto

Achado **DB-8** (Database Modeling Review § Achado 8): valores monetários
no domínio (`SocialBenefit.amount`, `MemberIncome.monthlyAmount`,
`SocioEconomicSituation.totalFamilyIncome`, `incomePerCapita`) eram
modelados como `Double`. O schema PostgreSQL armazena como `NUMERIC(12,2)`,
mas todo o caminho Domain → Application → DTO → Mapper trafegava em IEEE 754.

**Demonstração canônica do bug** (mesmo cenário que aparece em produção SUAS):

```swift
let cemBeneficios = (1...100).reduce(0.0) { acc, _ in acc + 0.10 }
// Esperado: 10.0 (R$ 0,10 × 100 = R$ 10,00)
// Real:     10.000000000000002
```

`0.1` não tem representação exata em IEEE 754 — pequenos erros se acumulam.

Em healthcare/social-care esse erro silencioso compromete:

1. **Auditoria PBF/BPC** — relatório do social-care não fecha com a fonte oficial. Diferença de centavos por mês × N beneficiários × 12 meses = divergência mensurável em fechamento contábil.
2. **Cálculo de renda per capita** — limiar de pobreza extrema é baseado em renda per capita exata (R$ 218,00 em 2024). Valor `217.999...` falha o limiar; `218.000...001` passa. Decisões de elegibilidade ficam não-determinísticas.
3. **Auditoria de operador** — operador alega ter cadastrado R$ 600,00 de Bolsa Família; sistema mostra R$ 599,99 ou R$ 600,01. Quem está certo?

Citações canônicas:

> *"Floating-point arithmetic can be surprising in many ways. […] Use exact integer arithmetic for monetary values."* — IEEE 754 (informalmente, prática de finance)

> *"Each attribute has a name and a domain […] The domain restricts what values can appear in that attribute."* — Ramakrishnan & Gehrke, Cap. 3.1

Money como `Double` é categorialmente o tipo errado para o domínio "valor monetário".

## Decisão

Criar VO `Money` em `Domain/Kernel/Money/Money.swift`:

```swift
public struct Money: Codable, Equatable, Hashable, Sendable, Comparable {
    public let centavos: Int64       // unidade mínima da moeda
    public let currency: String      // ISO 4217 (3 chars)
    public static let zero = Money(unsafe: 0, currency: "BRL")

    public init(centavos: Int64, currency: String = "BRL") throws { ... }
    public init(valorReal: Double, currency: String = "BRL") throws { ... }
    public var valorReal: Double { Double(centavos) / 100.0 }

    public static func + (lhs: Money, rhs: Money) throws -> Money { ... }
    public static func - (lhs: Money, rhs: Money) throws -> Money { ... }
    public static func * (lhs: Money, rhs: Int) throws -> Money { ... }
}

public enum MoneyError: Error, Equatable, Sendable {
    case negativeAmount(centavos: Int64)
    case invalidCurrency(received: String)
    case currencyMismatch(left: String, right: String)
}
```

Substituir `Double` por `Money` em todos os 5 sites do domínio:

- `SocialBenefit.amount: Money`
- `WorkIncomeVO.monthlyAmount: Money`
- `SocioEconomicSituation.totalFamilyIncome: Money`, `incomePerCapita: Money`
- `WorkIncome` (analytics) `.monthlyAmount: Money`
- `FinancialAnalyticsService.Indicators.{totalWorkIncome, perCapitaWorkIncome, totalGlobalIncome, perCapitaGlobalIncome}: Money`
- `SocialBenefitsCollection.totalAmount: Money` (computed)

Errors do domínio (`SocioEconomicSituationError`, `SocialBenefitError`) trocam `Double` por `Int64 centavos` nos cases que carregam quantia para diagnóstico.

**Fronteiras** (Application Commands, IO DTOs HTTP, IO Mapper SQL) **continuam aceitando `Double`** — porque é o que JSON/`NUMERIC` natural devolvem. Conversão explícita acontece em 2 pontos:

1. **Entrada:** `try Money(valorReal: command.amount)` no handler.
2. **Saída:** `money.valorReal` no DTO HTTP / mapper SQL.

Removidos os erros `negativeFamilyIncome` e `negativeIncomePerCapita` de `SocioEconomicSituationError` — `Money.init` rejeita centavos < 0, então o caminho não existe mais.

## Alternativas consideradas

- **Manter `Double` + adicionar `MonetaryValue` typealias.** Descartada — typealias não troca semântica, IEEE 754 continua imprecisa. Adiciona ruído sem ganho.
- **`Decimal` Swift nativo.** Considerada. `Decimal` tem precisão arbitrária e seria semanticamente correto. Descartada porque (a) Swift `Decimal` tem ergonomia ruim para operações simples, (b) round-trip com `NUMERIC(12,2)` via PostgresKit não é direto, (c) `Int64 centavos` é o padrão fintech (Stripe, PayPal, Square) — comprovado em escala, simples de raciocinar.
- **`Decimal` apenas no boundary HTTP, `Int64` interno.** Adicionaria um terceiro tipo no caminho. Descartada — overkill para o caso de uso.
- **Manter Double + biblioteca terceira (e.g. SwiftDecimal).** Descartada — adiciona dependência para problema solúvel com 100 linhas próprias. `Money` precisa ser auditável.
- **Fazer apenas no `SocialBenefit` (escopo mínimo).** Descartada — o bug aparece em qualquer reduce de Double monetário. Cobertura parcial deixa Mapper inconsistente; melhor refator atomico.

## Consequências

### Positivas

- Soma exata de centavos via `Int64` — sem erro IEEE 754.
- Currency mismatch detectado em compile/runtime — tentar somar BRL com USD lança.
- `Money.zero` como elemento neutro de reduce — código de soma fica idiomático.
- Erros do domínio ficam mais limpos: 2 cases removidos (`negativeFamilyIncome`, `negativeIncomePerCapita`) porque agora são impossíveis por construção.
- Diagnóstico de erros usa `Int64 centavos` — sem ambiguidade de formatação.
- Padrão fintech reconhecível para qualquer dev novo no projeto.

### Negativas / custos

- Conversão explícita Double ↔ Money em todos os boundaries (Command, DTO, Mapper). ~8 pontos no codebase atual. Mitigação: helpers `Money(valorReal:)` e `.valorReal` são one-liners.
- API de `Money` aritmética é throws (currency mismatch). Reduce + `try acc + item` adiciona um nível de wrap. Mitigação: para SUAS sempre BRL, mismatch nunca acontece — wrap é defensivo.
- `Money.zero` precisa de "trampolim" interno (`init(unsafe:)`) para evitar `try!` em static let. Trade-off aceito para evitar `try!` em código de produção.
- Round-trip Money → NUMERIC → Money perde precisão se `NUMERIC` não for `(N, 2)`. Schema atual é `NUMERIC(12,2)` — round-trip preserva. Documentado.

### Ações requeridas

- [x] Criar `Domain/Kernel/Money/Money.swift` (VO + MoneyError)
- [x] Refatorar `SocialBenefit.amount: Money`
- [x] Refatorar `WorkIncomeVO.monthlyAmount: Money` (init não-throws — Money valida)
- [x] Refatorar `SocioEconomicSituation.{totalFamilyIncome, incomePerCapita}: Money`
- [x] Refatorar `SocialBenefitsCollection.totalAmount: Money` (computed via reduce de centavos)
- [x] Refatorar `FinancialAnalyticsService.Indicators` para Money
- [x] Refatorar Errors removendo cases de `negative*` (impossíveis com Money)
- [x] Atualizar Mapper toDatabase: `money.valorReal` no bind
- [x] Atualizar Mapper toDomain: `try Money(valorReal: model.amount)` no decode
- [x] Atualizar Application Handlers: `try Money(valorReal: draft.amount)` na conversão Command → Domain
- [x] Atualizar DTOs HTTP: `money.valorReal` na resposta
- [x] Atualizar fixtures + tests para construir com Money
- [ ] **Médio prazo (T-035 — Fase 6):** auditar uso restante de Double em código não-monetário do domínio (e.g. `HousingAnalyticsService.density` que retorna Double — densidade habitacional não é dinheiro, ok manter).

## Plano de adoção

1. **Imediato (T-009 — este ticket):** Money VO + refator + suite 354/354 verde.
2. **Próximo deploy:** schema NUMERIC(12,2) inalterado — Mapper converte. Zero migration.
3. **Curto prazo (T-010):** mapeamento universal de erros — `MoneyError` ganha entrada padronizada nos handlers.
4. **Médio prazo (T-035):** lint test que falha se algum tipo `Double` aparecer em propriedade nomeada `amount/income/value/price/...` no Domain.

## Como reverter

Reverter ADR-009 reintroduz o bug de soma não-exata. Não recomendado.

Caminho técnico:

1. `git revert <commit-T-009>` — restaura Double em todos os sites.
2. `git revert` deleta `Money.swift`.
3. Marcar este ADR como `Deprecado`.
4. Manter o teste `MoneyIsExactRegressionTests` como xfail documentando regressão consciente.

## Teste de regressão

`Tests/social-care-sTests/Regression/DomainInvariants/MoneyIsExactRegressionTests.swift`:

1. **`test_DB_8_summing_decimals_in_money_is_exact`** — `100 × R$ 0,10` em Money == `R$ 10,00` exato. Comparação com Double demonstra a diferença (`10.000…002`).
2. **`test_DB_8_round_trip_via_valor_real_preserves_2_decimals`** — Money → Double → Money preserva precisão para 2 casas decimais.
3. **`test_DB_8_currency_mismatch_is_rejected`** — `BRL + USD` lança `MoneyError`.
4. **`test_DB_8_zero_is_neutral_for_addition`** — `Money.zero` é elemento neutro.
5. **`test_DB_8_negative_amounts_are_rejected`** — `Money(centavos: -1)` lança.
6. **`test_DB_8_invalid_currency_is_rejected`** — currency vazia ou tamanho ≠ 3 lança.

6/6 passam.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-domain-modeler/SKILL.md` — entrada 2 em "Lições Aprendidas".
- **Regra resumida:** valor monetário no Domain SEMPRE é `Money` (`centavos: Int64`, `currency: String`). NUNCA `Double`/`Float`/`Decimal` direto. Aritmética via operadores throws (currency-safe). Conversão para `Double` apenas no boundary HTTP/SQL via `valorReal`. Erros de "valor negativo" são impossíveis por construção — não modelar.

## Referências

- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § Achado 8 — origem
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-009 — especificação
- [ADR-002](ADR-002-regression-test-policy.md) — política de testes de regressão
- IEEE 754 — Floating-Point Arithmetic Standard (justifica não usar Double em monetary)
- Martin Fowler, *Patterns of Enterprise Application Architecture* — "Money" pattern
- Stripe API Docs — `Int amount + 3-letter currency` é o padrão fintech
- Ramakrishnan & Gehrke, *DBMS*, Cap. 3.1 — Column Domain
