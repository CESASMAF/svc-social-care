# T-009 — W3 Quality Gates

**Data:** 2026-05-14
**Achado:** DB-8 (Database Modeling Review § Achado 8)

## Gates

| Gate | Comando | Resultado |
|---|---|---|
| Build debug | `swift build --target social-care-s` | ✅ exit 0 |
| Build release | `make build-release` | ✅ exit 0, 43.14s, 0 warnings novos |
| Full test suite | `make test` | ✅ **354/354** passam, 0.082s |
| Regression suite | `make regression` | ✅ 50 testes em 8 suites (+6 do T-009) |
| Testes T-009 | `swift test --filter MoneyIsExact` | ✅ **6/6** passam |
| ADR-009 | `DECISIONS/ADR-009-*.md` | ✅ |
| DECISIONS.md index | próximo ID = 010 | ✅ |
| Skill atualizada | entrada 2 em "Lições Aprendidas" do swift-domain-modeler | ✅ |

## Arquivos criados

- `Sources/.../Domain/Kernel/Money/Money.swift` — **NOVO** (VO + MoneyError)
- `Tests/.../Regression/DomainInvariants/MoneyIsExactRegressionTests.swift` — **NOVO** (6 testes)
- `handbook/architecture/DECISIONS/ADR-009-money-vo-replaces-double.md` — **NOVO**

## Arquivos modificados (12)

**Domain:**
- `Domain/Assessment/ValueObjects/SocialBenefit/SocialBenefit.swift` — `amount: Money`
- `Domain/Assessment/ValueObjects/SocialBenefit/Errors/SocialBenefitErrors.swift` — `case amountInvalid(centavos: Int64)`
- `Domain/Assessment/ValueObjects/WorkAndIncome/WorkAndIncome.swift` — `WorkIncomeVO.monthlyAmount: Money` (init não-throws)
- `Domain/Assessment/ValueObjects/SocioEconomicSituation/SocioEconomicSituation.swift` — `totalFamilyIncome/incomePerCapita: Money`
- `Domain/Assessment/ValueObjects/SocioEconomicSituation/Errors/SocioEconomicSituationErrors.swift` — removidos cases `negative*`
- `Domain/Assessment/ValueObjects/SocialBenefitsCollection/SocialBenefitsCollection.swift` — `totalAmount: Money`
- `Domain/Assessment/Analytics/Models/WorkIncome.swift` — `monthlyAmount: Money`
- `Domain/Assessment/Analytics/Services/FinancialAnalyticsService.swift` — Indicators com Money + soma exata em centavos

**Application:**
- `Application/Assessment/UpdateWorkAndIncome/Services/UpdateWorkAndIncomeCommandHandler.swift` — converte Double → Money via `Money(valorReal:)`
- `Application/Assessment/UpdateSocioEconomicSituation/Services/UpdateSocioEconomicSituationCommandHandler.swift` — idem
- `Application/Assessment/UpdateSocioEconomicSituation/Error/UpdateSocioEconomicSituationError.swift` — error cases atualizados
- `Application/Assessment/UpdateSocioEconomicSituation/Error/UpdateSocioEconomicSituationMapperError.swift` — adiciona MoneyError mapping
- `Application/Query/PatientQueries/PatientQueryDTO.swift` — `WorkAndIncomeDTO.totalWorkIncome` calcula via centavos exato

**IO:**
- `IO/HTTP/DTOs/ResponseDTOs.swift` — DTOs serializam Money via `valorReal`
- `IO/Persistence/SQLKit/Mappers/PatientDatabaseMapper.swift` — encode `valorReal`, decode `try Money(valorReal:)`

**Tests:**
- `Tests/.../Application/UpdateSocioEconomicSituationTests.swift` — comparações via Money
- `Tests/.../Domain/v2/CodeReviewRegressionTests.swift` — WorkIncomeVO test usa MoneyError
- `Tests/.../Domain/v2/AnalyticsConsistencyTests.swift` — Indicators comparados como Money
- `Tests/.../Domain/v2/DomainAnalyticsSpecificationTests.swift` — fixtures Money

**Handbook + Skills:**
- `handbook/architecture/DECISIONS.md` — ADR-009 indexado; próximo ID = **010**
- `.claude/skills/swift-domain-modeler/SKILL.md` — Lições Aprendidas entrada 2

## Decisões arquiteturais

1. **`Int64 centavos`** — padrão fintech (Stripe/PayPal/Square). Comprovado em escala. Soma exata até ~92 quatrilhões.
2. **`currency: String`** ISO 4217 (3 chars) — currency mismatch detectado em runtime. SUAS sempre BRL, mas typing protege contra qualquer expansão futura.
3. **Conversão na fronteira** — `Money(valorReal:)` na entrada, `.valorReal` na saída. Domínio puro Money internamente.
4. **`Money.zero`** via `init(unsafe:)` privado — evita `try!` em `static let`.
5. **Aritmética throws** — `+/-/*` lança em currency mismatch. Reduce + try é o pattern idiomático.
6. **2 erros eliminados** — `negativeFamilyIncome` e `negativeIncomePerCapita` não existem mais (impossível por construção). Limpa a API.

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001 | Foundations | ADR-002 | 5 |
| T-002 | Estrutura ADR | ADR-003 | meta |
| T-004 | S-C7 | ADR-004 | 2 |
| T-005 | S-C3 + DB-2 | ADR-005 | 4 |
| T-006 | DB-1 | ADR-006 | 4 |
| T-007 | DB-4 + S-H-D5 | ADR-007 | 5 |
| T-008 | DB-3 | ADR-008 | 8 |
| T-009 | DB-8 | ADR-009 | 6 |
| **Total** | **8 fechados** | **9 ADRs** | **34 regression tests** |

## Próximos tickets sugeridos

- **T-010** — `mapUniqueViolation` universal nos 21 handlers (S-C6, CRITICAL). Helper genérico + retrofit.
- **T-011** — PeopleContext tri-state + Bearer forwarding (S-C1, CRITICAL de segurança).
- **T-014** — Security headers + body size limit (S-C5, CRITICAL).
