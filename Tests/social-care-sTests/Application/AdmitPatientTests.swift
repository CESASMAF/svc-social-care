import Testing
import Foundation
@testable import social_care_s

@Suite("AdmitPatient Command Handler")
struct AdmitPatientTests {

    private static let actorId = "actor-social-worker"

    private static func makeCommand(
        patientId: String = "placeholder",
        actorId: String = AdmitPatientTests.actorId
    ) -> AdmitPatientCommand {
        AdmitPatientCommand(
            patientId: patientId,
            actorId: actorId
        )
    }

    /// Creates a waitlisted patient, clears events, seeds in repo.
    private static func seedWaitlistedPatient(
        repo: InMemoryPatientRepository
    ) async throws -> Patient {
        var patient = try PatientFixture.createMinimalWaitlisted()
        await repo.seed(patient)
        return patient
    }

    /// Creates an active patient (default), clears events, seeds in repo.
    private static func seedActivePatient(
        repo: InMemoryPatientRepository
    ) async throws -> Patient {
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)
        return patient
    }

    /// Creates a discharged patient (active + discharge), clears events, seeds in repo.
    private static func seedDischargedPatient(
        repo: InMemoryPatientRepository
    ) async throws -> Patient {
        var patient = try PatientFixture.createMinimalActive()
        try patient.discharge(
            reason: .caseObjectiveAchieved,
            notes: nil,
            actorId: "setup"
        )
        patient.clearEvents()
        await repo.seed(patient)
        return patient
    }

    // MARK: - Happy Path

    @Test("Deve admitir paciente waitlisted com sucesso")
    func successfulAdmit() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try await Self.seedWaitlistedPatient(repo: repo)

        let handler = AdmitPatientCommandHandler(
            repository: repo
        )

        try await handler.handle(Self.makeCommand(
            patientId: patient.id.description
        ))

        let saved = await repo.stored(byId: patient.id)
        #expect(saved?.status == .active)

        let saveCount = await repo.saveCallCount
        #expect(saveCount == 1)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve publicar PatientAdmittedEvent apos persistencia")
    func eventPublishedAfterPersistence() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try await Self.seedWaitlistedPatient(repo: repo)

        let handler = AdmitPatientCommandHandler(
            repository: repo
        )

        try await handler.handle(Self.makeCommand(
            patientId: patient.id.description
        ))

        let lastEvent = await repo.publishedEvents.last
        #expect(lastEvent is PatientAdmittedEvent)
    }

    // MARK: - Error Cases

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()

        let handler = AdmitPatientCommandHandler(
            repository: repo
        )

        let nonExistentId = PatientId().description

        await #expect(throws: AdmitPatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: nonExistentId
            ))
        }

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount == 0)
    }

    @Test("Deve falhar quando paciente ja esta ativo")
    func alreadyActive() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try await Self.seedActivePatient(repo: repo)

        let handler = AdmitPatientCommandHandler(
            repository: repo
        )

        await #expect(throws: AdmitPatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: patient.id.description
            ))
        }
    }

    @Test("Deve falhar quando paciente esta desligado")
    func cannotAdmitDischarged() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try await Self.seedDischargedPatient(repo: repo)

        let handler = AdmitPatientCommandHandler(
            repository: repo
        )

        await #expect(throws: AdmitPatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: patient.id.description
            ))
        }
    }

    @Test("Deve falhar com formato de patientId invalido")
    func invalidPatientIdFormat() async throws {
        let repo = InMemoryPatientRepository()

        let handler = AdmitPatientCommandHandler(
            repository: repo
        )

        await #expect(throws: AdmitPatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: "not-a-valid-uuid"
            ))
        }
    }
}
