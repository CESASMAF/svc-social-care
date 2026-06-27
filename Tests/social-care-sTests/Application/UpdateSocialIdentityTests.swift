import Testing
import Foundation
@testable import social_care_s

@Suite("UpdateSocialIdentity Command Handler")
struct UpdateSocialIdentityTests {

    @Test("Deve atualizar identidade social com sucesso")
    func successfulUpdate() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateSocialIdentityCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        let typeId = UUID().uuidString

        try await handler.handle(UpdateSocialIdentityCommand(
            patientId: patient.id.description,
            typeId: typeId,
            description: "Comunidade quilombola",
            actorId: "actor-1"
        ))

        let saved = await repo.stored(byId: patient.id)
        #expect(saved?.socialIdentity != nil)
        #expect(saved?.socialIdentity?.typeId.description == typeId.lowercased())

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar com lookup de tipo de identidade invalido")
    func invalidLookup() async throws {
        let repo = InMemoryPatientRepository()
        let lookup = InMemoryLookupValidator()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateSocialIdentityCommandHandler(
            repository: repo, lookupValidator: lookup
        )

        await #expect(throws: UpdateSocialIdentityError.self) {
            try await handler.handle(UpdateSocialIdentityCommand(
                patientId: patient.id.description,
                typeId: UUID().uuidString,
                description: nil,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = UpdateSocialIdentityCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        await #expect(throws: UpdateSocialIdentityError.self) {
            try await handler.handle(UpdateSocialIdentityCommand(
                patientId: UUID().uuidString,
                typeId: UUID().uuidString,
                description: nil,
                actorId: "actor-1"
            ))
        }
    }
}
