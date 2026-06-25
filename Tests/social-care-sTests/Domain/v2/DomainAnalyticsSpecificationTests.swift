import Testing
@testable import social_care_s
import Foundation

@Suite("Domain Analytics Specification")
struct DomainAnalyticsSpecificationTests {

    // MARK: - Housing Analytics
    @Suite("Housing Analytics")
    struct HousingAnalyticsSpec {
        @Test("Deve calcular densidade habitacional corretamente")
        func densityCalculation() {
            let density = HousingAnalyticsService.density(forMembers: 4, inBedrooms: 2)
            #expect(density == 2.0)
        }

        @Test("Deve identificar superlotação quando densidade > 3")
        func overcrowding() {
            #expect(HousingAnalyticsService.isOvercrowded(members: 10, bedrooms: 2) == true)
            #expect(HousingAnalyticsService.isOvercrowded(members: 3, bedrooms: 1) == false)
        }
    }

    // MARK: - Financial Analytics
    @Suite("Financial Analytics")
    struct FinancialAnalyticsSpec {
        @Test("Deve consolidar rendas e benefícios")
        func financialConsolidation() throws {
            let member1 = PersonId()
            let member2 = PersonId()
            
            // ADR-009: Money em todo lugar.
            let workIncomes = [
                WorkIncome(memberId: member1, monthlyAmount: try Money(valorReal: 1200.0)),
                WorkIncome(memberId: member2, monthlyAmount: try Money(valorReal: 800.0))
            ]

            let benefits = [
                try SocialBenefit(benefitName: "Bolsa Família", amount: try Money(valorReal: 600.0), beneficiaryId: member1)
            ]

            let indicators = FinancialAnalyticsService.calculate(
                workIncomes: workIncomes,
                socialBenefits: benefits,
                memberCount: 4
            )

            #expect(indicators.totalWorkIncome == (try Money(valorReal: 2000.0)))
            #expect(indicators.perCapitaWorkIncome == (try Money(valorReal: 500.0)))
            #expect(indicators.totalGlobalIncome == (try Money(valorReal: 2600.0)))
            #expect(indicators.perCapitaGlobalIncome == (try Money(valorReal: 650.0)))
        }
    }

    // MARK: - Education Analytics
    @Suite("Education Analytics")
    struct EducationAnalyticsSpec {
        @Test("Deve reportar vulnerabilidades educacionais por faixa")
        func educationVulnerabilities() throws {
            let now = try TimeStamp(iso: "2024-01-01T00:00:00Z")
            
            let members = [
                // 4 anos, fora da creche
                EducationalMember(personId: PersonId(), birthDate: try TimeStamp(iso: "2020-01-01T00:00:00Z"), attendsSchool: false, canReadWrite: false),
                // 15 anos, analfabeto
                EducationalMember(personId: PersonId(), birthDate: try TimeStamp(iso: "2009-01-01T00:00:00Z"), attendsSchool: true, canReadWrite: false),
                // 65 anos, analfabeto
                EducationalMember(personId: PersonId(), birthDate: try TimeStamp(iso: "1959-01-01T00:00:00Z"), attendsSchool: true, canReadWrite: false)
            ]
            
            let report = EducationAnalyticsService.calculateVulnerabilities(for: members, at: now)
            
            #expect(report.count(vulnerability: .notInSchool, ageRange: .range0to5) == 1)
            #expect(report.count(vulnerability: .illiteracy, ageRange: .range10to17) == 1)
            #expect(report.count(vulnerability: .illiteracy, ageRange: .range60Plus) == 1)
        }
    }
}
