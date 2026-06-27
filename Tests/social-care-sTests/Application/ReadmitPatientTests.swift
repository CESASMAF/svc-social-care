import Testing
import Foundation
@testable import social_care_s

@Suite("ReadmitPatient Command Handler")
struct ReadmitPatientTests {

    private static let actorId = "actor-social-worker"

    private static func makeCommand(
        patientId: String = "placeholder",
        notes: String? = nil,
        actorId: String = ReadmitPatientTests.actorId
    ) -> ReadmitPatientCommand {
        ReadmitPatientCommand(
            patientId: patientId,
            notes: notes,
            actorId: actorId
        )
    }

    /// Creates a discharged patient with cleared setup events, seeds it in the repo.
    private static func seedDischargedPatient(
        repo: InMemoryPatientRepository
    ) async throws -> Patient {
        var patient = try PatientFixture.createMinimalActive()
        try patient.discharge(
            reason: .caseObjectiveAchieved,
            notes: nil,
            actorId: "setup-actor"
        )
        patient.clearEvents()
        await repo.seed(patient)
        return patient
    }

    // MARK: - Happy Path

    @Test("Deve readmitir paciente desligado com sucesso")
    func successfulReadmit() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try await Self.seedDischargedPatient(repo: repo)

        let handler = ReadmitPatientCommandHandler(
            repository: repo
        )

        try await handler.handle(Self.makeCommand(
            patientId: patient.id.description
        ))

        let saved = await repo.stored(byId: patient.id)
        #expect(saved?.status == .active)
        #expect(saved?.dischargeInfo == nil)

        let saveCount = await repo.saveCallCount
        #expect(saveCount == 1)
    }

    @Test("Deve readmitir paciente com notes opcionais")
    func successfulReadmitWithNotes() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try await Self.seedDischargedPatient(repo: repo)

        let handler = ReadmitPatientCommandHandler(
            repository: repo
        )

        try await handler.handle(Self.makeCommand(
            patientId: patient.id.description,
            notes: "Paciente retornou ao municipio apos relocacao"
        ))

        let saved = await repo.stored(byId: patient.id)
        #expect(saved?.status == .active)
    }

    @Test("Deve publicar evento PatientReadmittedEvent apos persistencia")
    func eventPublishedAfterPersistence() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try await Self.seedDischargedPatient(repo: repo)

        let handler = ReadmitPatientCommandHandler(
            repository: repo
        )

        try await handler.handle(Self.makeCommand(
            patientId: patient.id.description
        ))

        let lastEvent = await repo.publishedEvents.last
        #expect(lastEvent is PatientReadmittedEvent)
    }

    // MARK: - Error Cases

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()

        let handler = ReadmitPatientCommandHandler(
            repository: repo
        )

        let nonExistentId = PatientId().description

        await #expect(throws: ReadmitPatientError.self) {
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
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = ReadmitPatientCommandHandler(
            repository: repo
        )

        await #expect(throws: ReadmitPatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: patient.id.description
            ))
        }
    }

    @Test("Deve falhar com formato de patientId invalido")
    func invalidPatientIdFormat() async throws {
        let repo = InMemoryPatientRepository()

        let handler = ReadmitPatientCommandHandler(
            repository: repo
        )

        await #expect(throws: ReadmitPatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: "invalid-format-not-uuid"
            ))
        }
    }

    @Test("Deve falhar quando notes excede 1000 caracteres")
    func notesExceedMaxLength() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try await Self.seedDischargedPatient(repo: repo)

        let handler = ReadmitPatientCommandHandler(
            repository: repo
        )

        let longNotes = String(repeating: "w", count: 1001)

        await #expect(throws: ReadmitPatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: patient.id.description,
                notes: longNotes
            ))
        }

        let saved = await repo.stored(byId: patient.id)
        #expect(saved?.status == .discharged)
    }
}
