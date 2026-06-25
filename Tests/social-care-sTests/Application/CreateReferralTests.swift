import Testing
import Foundation
@testable import social_care_s

@Suite("CreateReferral Command Handler")
struct CreateReferralTests {

    @Test("Deve criar encaminhamento com sucesso")
    func successfulCreation() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = CreateReferralCommandHandler(repository: repo)

        let referralId = try await handler.handle(CreateReferralCommand(
            patientId: patient.id.description,
            referredPersonId: PatientFixture.defaultPersonId,
            destinationService: "CRAS",
            reason: "Acompanhamento familiar",
            actorId: "actor-1"
        ))

        #expect(!referralId.isEmpty)

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.referrals.count == 1)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar com servico de destino invalido")
    func invalidDestinationService() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = CreateReferralCommandHandler(repository: repo)

        await #expect(throws: CreateReferralError.self) {
            try await handler.handle(CreateReferralCommand(
                patientId: patient.id.description,
                referredPersonId: PatientFixture.defaultPersonId,
                destinationService: "SERVICO_INVALIDO",
                reason: "Motivo",
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = CreateReferralCommandHandler(repository: repo)

        await #expect(throws: CreateReferralError.self) {
            try await handler.handle(CreateReferralCommand(
                patientId: UUID().uuidString,
                referredPersonId: UUID().uuidString,
                destinationService: "CRAS",
                reason: "Motivo",
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: encaminhamentos concorrentes")
    func concurrentReferrals() async throws {
        let repo = InMemoryPatientRepository()

        let p1 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        let p2 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        await repo.seed(p1)
        await repo.seed(p2)

        let handler = CreateReferralCommandHandler(repository: repo)

        async let r1 = handler.handle(CreateReferralCommand(
            patientId: p1.id.description,
            referredPersonId: p1.personId.description,
            destinationService: "CRAS",
            reason: "Motivo A",
            actorId: "actor-1"
        ))
        async let r2 = handler.handle(CreateReferralCommand(
            patientId: p2.id.description,
            referredPersonId: p2.personId.description,
            destinationService: "CREAS",
            reason: "Motivo B",
            actorId: "actor-2"
        ))

        let id1 = try await r1
        let id2 = try await r2

        #expect(!id1.isEmpty)
        #expect(!id2.isEmpty)
        #expect(id1 != id2)
    }
}
