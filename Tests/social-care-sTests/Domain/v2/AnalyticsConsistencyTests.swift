import Testing
@testable import social_care_s
import Foundation

@Suite("Analytics Services Consistency")
struct AnalyticsConsistencyTests {

    @Test("HousingAnalytics - Divisão por zero ou vazios")
    func housingEdgeCases() {
        // Zero dormitórios deve tratar como 1 para evitar crash, ou conforme regra
        let d = HousingAnalyticsService.density(forMembers: 4, inBedrooms: 0)
        #expect(d == 4.0)
    }

    @Test("FinancialAnalytics - Listas vazias")
    func financialEmpty() {
        let indicators = FinancialAnalyticsService.calculate(workIncomes: [], socialBenefits: [], memberCount: 0)
        // ADR-009: Indicators são Money agora.
        #expect(indicators.totalWorkIncome == .zero)
        #expect(indicators.perCapitaGlobalIncome == .zero)
    }

    @Test("EducationAnalytics - Sem membros")
    func educationEmpty() throws {
        let report = EducationAnalyticsService.calculateVulnerabilities(for: [], at: .now)
        #expect(report.count(vulnerability: .notInSchool, ageRange: .range0to5) == 0)
    }
}
