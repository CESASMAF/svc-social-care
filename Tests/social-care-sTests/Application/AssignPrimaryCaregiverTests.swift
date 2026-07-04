import Testing
import Foundation
@testable import social_care_s

@Suite("AssignPrimaryCaregiver Command Handler")
struct AssignPrimaryCaregiverTests {

    @Test("Deve atribuir cuidador principal com sucesso")
    func successfulAssignment() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createWithAdditionalMemberActive()
        await repo.seed(patient)

        let handler = AssignPrimaryCaregiverCommandHandler(repository: repo)

        try await handler.handle(AssignPrimaryCaregiverCommand(
            patientId: patient.id.description,
            memberPersonId: PatientFixture.defaultMemberId,
            actorId: "actor-1"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        let newCaregiver = saved?.familyMembers.first { $0.personId.description == PatientFixture.defaultMemberId }
        #expect(newCaregiver?.isPrimaryCaregiver == true)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar quando membro nao pertence a familia")
    func memberNotInFamily() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = AssignPrimaryCaregiverCommandHandler(repository: repo)

        await #expect(throws: AssignPrimaryCaregiverError.self) {
            try await handler.handle(AssignPrimaryCaregiverCommand(
                patientId: patient.id.description,
                memberPersonId: UUID().uuidString,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = AssignPrimaryCaregiverCommandHandler(repository: repo)

        await #expect(throws: AssignPrimaryCaregiverError.self) {
            try await handler.handle(AssignPrimaryCaregiverCommand(
                patientId: UUID().uuidString,
                memberPersonId: UUID().uuidString,
                actorId: "actor-1"
            ))
        }
    }
}
