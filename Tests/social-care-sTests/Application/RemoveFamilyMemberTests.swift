import Testing
import Foundation
@testable import social_care_s

@Suite("RemoveFamilyMember Command Handler")
struct RemoveFamilyMemberTests {

    @Test("Deve remover membro familiar com sucesso")
    func successfulRemoval() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createWithAdditionalMemberActive()
        await repo.seed(patient)

        let handler = RemoveFamilyMemberCommandHandler(repository: repo)

        try await handler.handle(RemoveFamilyMemberCommand(
            patientId: patient.id.description,
            memberId: PatientFixture.defaultMemberId,
            actorId: "actor-1"
        ))

        let saved = await repo.stored(byId: patient.id)
        #expect(saved?.familyMembers.count == 1)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar quando membro nao encontrado")
    func memberNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = RemoveFamilyMemberCommandHandler(repository: repo)

        await #expect(throws: RemoveFamilyMemberError.self) {
            try await handler.handle(RemoveFamilyMemberCommand(
                patientId: patient.id.description,
                memberId: UUID().uuidString,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = RemoveFamilyMemberCommandHandler(repository: repo)

        await #expect(throws: RemoveFamilyMemberError.self) {
            try await handler.handle(RemoveFamilyMemberCommand(
                patientId: UUID().uuidString,
                memberId: UUID().uuidString,
                actorId: "actor-1"
            ))
        }
    }
}
