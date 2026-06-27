import Testing
import Foundation
@testable import social_care_s

@Suite("UpdateCommunitySupportNetwork Command Handler")
struct UpdateCommunitySupportNetworkTests {

    @Test("Deve atualizar rede de apoio comunitario com sucesso")
    func successfulUpdate() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateCommunitySupportNetworkCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        try await handler.handle(UpdateCommunitySupportNetworkCommand(
            patientId: patient.id.description,
            hasRelativeSupport: true,
            hasNeighborSupport: false,
            familyConflicts: "Nenhum",
            patientParticipatesInGroups: true,
            familyParticipatesInGroups: false,
            patientHasAccessToLeisure: true,
            facesDiscrimination: false,
            actorId: "actor-1"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.communitySupportNetwork?.hasRelativeSupport == true)
        #expect(saved?.communitySupportNetwork?.patientParticipatesInGroups == true)
        #expect(saved?.communitySupportNetwork?.facesDiscrimination == false)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
        let saveCount = await repo.saveCallCount
        #expect(saveCount == 1)
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = UpdateCommunitySupportNetworkCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        await #expect(throws: UpdateCommunitySupportNetworkError.self) {
            try await handler.handle(UpdateCommunitySupportNetworkCommand(
                patientId: UUID().uuidString,
                hasRelativeSupport: true,
                hasNeighborSupport: false,
                familyConflicts: "",
                patientParticipatesInGroups: false,
                familyParticipatesInGroups: false,
                patientHasAccessToLeisure: false,
                facesDiscrimination: false,
                actorId: "actor-1"
            ))
        }

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount == 0)
    }

    @Test("Deve falhar com patientId invalido")
    func invalidPatientId() async throws {
        let repo = InMemoryPatientRepository()
        let handler = UpdateCommunitySupportNetworkCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        await #expect(throws: UpdateCommunitySupportNetworkError.self) {
            try await handler.handle(UpdateCommunitySupportNetworkCommand(
                patientId: "not-a-uuid",
                hasRelativeSupport: true,
                hasNeighborSupport: false,
                familyConflicts: "",
                patientParticipatesInGroups: false,
                familyParticipatesInGroups: false,
                patientHasAccessToLeisure: false,
                facesDiscrimination: false,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: chamadas concorrentes no mesmo handler")
    func concurrentCalls() async throws {
        let repo = InMemoryPatientRepository()

        let patient1 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        let patient2 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        await repo.seed(patient1)
        await repo.seed(patient2)

        let handler = UpdateCommunitySupportNetworkCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        async let r1: Void = handler.handle(UpdateCommunitySupportNetworkCommand(
            patientId: patient1.id.description,
            hasRelativeSupport: true, hasNeighborSupport: true,
            familyConflicts: "", patientParticipatesInGroups: false,
            familyParticipatesInGroups: false, patientHasAccessToLeisure: false,
            facesDiscrimination: false, actorId: "actor-1"
        ))
        async let r2: Void = handler.handle(UpdateCommunitySupportNetworkCommand(
            patientId: patient2.id.description,
            hasRelativeSupport: false, hasNeighborSupport: false,
            familyConflicts: "Conflito", patientParticipatesInGroups: true,
            familyParticipatesInGroups: true, patientHasAccessToLeisure: true,
            facesDiscrimination: true, actorId: "actor-2"
        ))

        try await r1
        try await r2

        let saved1 = try await repo.find(byPersonId: patient1.personId)
        let saved2 = try await repo.find(byPersonId: patient2.personId)
        #expect(saved1?.communitySupportNetwork?.hasRelativeSupport == true)
        #expect(saved2?.communitySupportNetwork?.facesDiscrimination == true)

        let saveCount = await repo.saveCallCount
        #expect(saveCount == 2)
    }
}
