import Foundation

/// Serviço de Domínio responsável por consolidar indicadores financeiros da família.
///
/// Aplica as fórmulas oficiais do SUAS para cálculo de renda familiar total e per capita,
/// diferenciando rendimentos do trabalho de benefícios de programas sociais.
public struct FinancialAnalyticsService: Sendable {
    
    // MARK: - Nested Types

    /// Conjunto de indicadores financeiros projetados.
    ///
    /// ADR-009: tipos `Money` em vez de `Double`. Soma exata em centavos;
    /// per-capita usa divisão integer (perda máxima de N-1 centavos no total
    /// — aceito como custo de exatidão monetária).
    public struct Indicators: Sendable {
        /// Renda Total Familiar (Trabalho) - RTF_S.
        public let totalWorkIncome: Money
        /// Renda Per Capita (Trabalho) - RPC_S.
        public let perCapitaWorkIncome: Money
        /// Renda Total Global (Trabalho + Benefícios) - RTG.
        public let totalGlobalIncome: Money
        /// Renda Per Capita Global (Trabalho + Benefícios) - RPC_G.
        public let perCapitaGlobalIncome: Money
    }

    // MARK: - Analytics Logic

    /// Calcula os indicadores econômicos da família.
    ///
    /// - Parameters:
    ///   - workIncomes: Lista de rendimentos individuais do trabalho.
    ///   - socialBenefits: Lista de benefícios sociais recebidos.
    ///   - memberCount: Total de membros da família (divisor para per capita).
    /// - Returns: Uma estrutura `Indicators` com os valores consolidados.
    public static func calculate(
        workIncomes: [WorkIncome],
        socialBenefits: [SocialBenefit],
        memberCount: Int
    ) -> Indicators {
        let totalMembers = Int64(max(memberCount, 1))

        // Soma exata em centavos (Int64) — sem perda IEEE 754.
        let totalWorkCentavos = workIncomes.reduce(Int64(0)) { $0 + $1.monthlyAmount.centavos }
        let totalBenefitsCentavos = socialBenefits.reduce(Int64(0)) { $0 + $1.amount.centavos }
        let totalGlobalCentavos = totalWorkCentavos + totalBenefitsCentavos

        // Money construído via init não-throws aqui porque centavos >= 0
        // (já garantido pelos Money individuais somados). Falha aqui é bug
        // de modelagem — propagamos como precondition.
        guard let totalWork = try? Money(centavos: totalWorkCentavos),
              let perCapitaWork = try? Money(centavos: totalWorkCentavos / totalMembers),
              let totalGlobal = try? Money(centavos: totalGlobalCentavos),
              let perCapitaGlobal = try? Money(centavos: totalGlobalCentavos / totalMembers) else {
            preconditionFailure("FinancialAnalyticsService: soma de Money negativos é impossível por construção (Money.init rejeita centavos < 0). Bug upstream.")
        }

        return Indicators(
            totalWorkIncome: totalWork,
            perCapitaWorkIncome: perCapitaWork,
            totalGlobalIncome: totalGlobal,
            perCapitaGlobalIncome: perCapitaGlobal
        )
    }
}
