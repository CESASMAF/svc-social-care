import Foundation
import Testing
@testable import social_care_s

// ticket: T-009 — achado DB-8 (Database Modeling Review § Achado 8)
// ADR: ADR-009 — Money VO substitui Double em todo valor monetário

/// Regressão para o achado **DB-8**: valores monetários (`amount`,
/// `monthlyAmount`, `totalFamilyIncome`, `incomePerCapita`) eram modelados
/// como `Double`. IEEE 754 não é fechado em soma de decimais — auditoria
/// PBF/BPC fica comprometida.
///
/// Demonstração canônica do bug pré-fix (com `Double`):
///
/// ```swift
/// let total = (1...100).reduce(0.0) { $0 + 0.1 }
/// // Esperado: 10.0
/// // Real:     10.000000000000002
/// ```
///
/// Em healthcare/social-care, esse erro acumulado em soma de benefícios
/// sociais (BPC = R$ 1.412,00, Bolsa Família variável, etc.) gera divergência
/// em relatório de auditoria de **R$ 0,01 a R$ 0,10 por mês**, dependendo
/// do número de beneficiários — número que não fecha com a fonte oficial.
///
/// Este suite garante:
/// 1. **Soma de Money é exata**: `Money(centavos: 10).sum × 100 == Money(centavos: 1000)`.
/// 2. **Round-trip Money → Double → Money preserva precisão** quando
///    convertido via `centavos / 100.0` (forma do bind para NUMERIC(12,2)).
/// 3. **Currency mismatch é rejeitado** em soma — não somamos BRL com USD.
/// 4. **`Money.zero` é o elemento neutro** para reduce.
///
/// Os testes não dependem do mapper SQL — testam apenas o VO Money em
/// isolamento + comparação com Double para evidenciar a diferença.
@Suite("Regression: DomainInvariants — DB-8 Money é exato (Double não)")
struct MoneyIsExactRegressionTests {

    @Test("DB-8 — soma de 100 × R$ 0,10 em Money dá exatamente R$ 10,00 (Double daria 10.000…002)")
    func test_DB_8_summing_decimals_in_money_is_exact() throws {
        let dezCentavos = try Money(centavos: 10, currency: "BRL")
        let total = (1...100).reduce(Money.zero) { (acc: Money, _) -> Money in
            // Operação throws em currency mismatch; aqui mesmo currency, então `try!` é seguro
            (try? acc + dezCentavos) ?? .zero
        }
        let esperado = try Money(centavos: 1000, currency: "BRL")
        #expect(total == esperado, "Money DEVE somar centavos como Int64 — exato. Se falhar, alguém trocou Money por Double internamente.")

        // Demonstração: Double mostra o problema oposto
        let totalDouble = (1...100).reduce(0.0) { acc, _ in acc + 0.1 }
        #expect(totalDouble != 10.0, "Double NÃO é exato em soma de decimais — esta é a justificativa do ADR-009.")
    }

    @Test("DB-8 — Money(centavos: N) round-trip via valorReal (Double) preserva precisão para 2 casas decimais")
    func test_DB_8_round_trip_via_valor_real_preserves_2_decimals() throws {
        let original = try Money(centavos: 60099, currency: "BRL")  // R$ 600,99
        let asReal = original.valorReal  // 600.99
        #expect(asReal == 600.99)

        let reconstructed = try Money(valorReal: asReal, currency: "BRL")
        #expect(reconstructed == original, "Round-trip Money → Double → Money DEVE preservar precisão para 2 casas (limitação aceita: arredonda para centavos).")
    }

    @Test("DB-8 — soma com currency diferente lança currencyMismatch")
    func test_DB_8_currency_mismatch_is_rejected() throws {
        let brl = try Money(centavos: 100, currency: "BRL")
        let usd = try Money(centavos: 100, currency: "USD")
        #expect(throws: MoneyError.self) {
            _ = try brl + usd
        }
    }

    @Test("DB-8 — Money.zero é elemento neutro de soma")
    func test_DB_8_zero_is_neutral_for_addition() throws {
        let amount = try Money(centavos: 12345, currency: "BRL")
        let plusZero = try amount + .zero
        let zeroPlus = try Money.zero + amount
        #expect(plusZero == amount)
        #expect(zeroPlus == amount)
    }

    @Test("DB-8 — Money rejeita centavos negativos no init padrão")
    func test_DB_8_negative_amounts_are_rejected() {
        #expect(throws: MoneyError.self) {
            _ = try Money(centavos: -1, currency: "BRL")
        }
    }

    @Test("DB-8 — Money rejeita currency vazia ou inválida")
    func test_DB_8_invalid_currency_is_rejected() {
        #expect(throws: MoneyError.self) {
            _ = try Money(centavos: 100, currency: "")
        }
        #expect(throws: MoneyError.self) {
            _ = try Money(centavos: 100, currency: "RE")  // ISO 4217 = 3 chars
        }
    }
}
