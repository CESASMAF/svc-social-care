import Testing
import Foundation
@testable import social_care_s

@Suite("UpdateSocialHealthSummary Command Handler")
struct UpdateSocialHealthSummaryTests {

    @Test("Deve atualizar resumo de saude social com sucesso")
    func successfulUpdate() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateSocialHealthSummaryCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        try await handler.handle(UpdateSocialHealthSummaryCommand(
            patientId: patient.id.description,
            requiresConstantCare: true,
            hasMobilityImpairment: false,
            functionalDependencies: ["Alimentacao", "Higiene"],
            hasRelevantDrugTherapy: true,
            actorId: "actor-1"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.socialHealthSummary?.requiresConstantCare == true)
        #expect(saved?.socialHealthSummary?.functionalDependencies.count == 2)
        #expect(saved?.socialHealthSummary?.hasRelevantDrugTherapy == true)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = UpdateSocialHealthSummaryCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        await #expect(throws: UpdateSocialHealthSummaryError.self) {
            try await handler.handle(UpdateSocialHealthSummaryCommand(
                patientId: UUID().uuidString,
                requiresConstantCare: false,
                hasMobilityImpairment: false,
                functionalDependencies: [],
                hasRelevantDrugTherapy: false,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: handler serializa chamadas corretamente")
    func actorSerialization() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateSocialHealthSummaryCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        // Duas chamadas sequenciais no mesmo patient — a segunda sobrescreve
        try await handler.handle(UpdateSocialHealthSummaryCommand(
            patientId: patient.id.description,
            requiresConstantCare: false,
            hasMobilityImpairment: false,
            functionalDependencies: [],
            hasRelevantDrugTherapy: false,
            actorId: "actor-1"
        ))

        try await handler.handle(UpdateSocialHealthSummaryCommand(
            patientId: patient.id.description,
            requiresConstantCare: true,
            hasMobilityImpairment: true,
            functionalDependencies: ["Locomocao"],
            hasRelevantDrugTherapy: true,
            actorId: "actor-2"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.socialHealthSummary?.requiresConstantCare == true)
        #expect(saved?.socialHealthSummary?.hasMobilityImpairment == true)

        let saveCount = await repo.saveCallCount
        #expect(saveCount == 2)
    }
}
