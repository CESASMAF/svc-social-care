import Testing
import Foundation
@testable import social_care_s

@Suite("UpdateSocioEconomicSituation Command Handler")
struct UpdateSocioEconomicSituationTests {

    @Test("Deve atualizar situacao socioeconomica com sucesso")
    func successfulUpdate() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateSocioEconomicSituationCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        try await handler.handle(UpdateSocioEconomicSituationCommand(
            patientId: patient.id.description,
            situation: .init(
                totalFamilyIncome: 2500.0,
                incomePerCapita: 1250.0,
                receivesSocialBenefit: true,
                socialBenefits: [
                    .init(benefitName: "Bolsa Familia", amount: 600.0, beneficiaryId: PatientFixture.defaultPersonId)
                ],
                mainSourceOfIncome: "Trabalho informal",
                hasUnemployed: false
            ),
            actorId: "actor-1"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.socioeconomicSituation != nil)
        // ADR-009: totalFamilyIncome agora é Money — comparar com Money construído.
        #expect(saved?.socioeconomicSituation?.totalFamilyIncome == (try Money(valorReal: 2500.0)))

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve atualizar sem beneficios sociais")
    func updateWithoutBenefits() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateSocioEconomicSituationCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        try await handler.handle(UpdateSocioEconomicSituationCommand(
            patientId: patient.id.description,
            situation: .init(
                totalFamilyIncome: 1500.0,
                incomePerCapita: 750.0,
                receivesSocialBenefit: false,
                socialBenefits: [],
                mainSourceOfIncome: "Emprego formal",
                hasUnemployed: false
            ),
            actorId: "actor-1"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.socioeconomicSituation?.receivesSocialBenefit == false)
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = UpdateSocioEconomicSituationCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        await #expect(throws: UpdateSocioEconomicSituationError.self) {
            try await handler.handle(UpdateSocioEconomicSituationCommand(
                patientId: UUID().uuidString,
                situation: .init(
                    totalFamilyIncome: 1000.0,
                    incomePerCapita: 500.0,
                    receivesSocialBenefit: false,
                    socialBenefits: [],
                    mainSourceOfIncome: "Trabalho",
                    hasUnemployed: false
                ),
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: atualizacoes concorrentes")
    func concurrentUpdates() async throws {
        let repo = InMemoryPatientRepository()

        let p1 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        let p2 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        await repo.seed(p1)
        await repo.seed(p2)

        let handler = UpdateSocioEconomicSituationCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        async let r1: Void = handler.handle(UpdateSocioEconomicSituationCommand(
            patientId: p1.id.description,
            situation: .init(
                totalFamilyIncome: 3000.0, incomePerCapita: 1500.0,
                receivesSocialBenefit: false, socialBenefits: [],
                mainSourceOfIncome: "Fonte A", hasUnemployed: false
            ),
            actorId: "actor-1"
        ))
        async let r2: Void = handler.handle(UpdateSocioEconomicSituationCommand(
            patientId: p2.id.description,
            situation: .init(
                totalFamilyIncome: 1000.0, incomePerCapita: 500.0,
                receivesSocialBenefit: false, socialBenefits: [],
                mainSourceOfIncome: "Fonte B", hasUnemployed: true
            ),
            actorId: "actor-2"
        ))

        try await r1
        try await r2

        let saved1 = try await repo.find(byPersonId: p1.personId)
        let saved2 = try await repo.find(byPersonId: p2.personId)
        // ADR-009: totalFamilyIncome agora é Money.
        #expect(saved1?.socioeconomicSituation?.totalFamilyIncome == (try Money(valorReal: 3000.0)))
        #expect(saved2?.socioeconomicSituation?.totalFamilyIncome == (try Money(valorReal: 1000.0)))
    }
}
