import Testing
import Foundation
@testable import social_care_s

@Suite("DischargePatient Command Handler")
struct DischargePatientTests {

    private static let actorId = "actor-social-worker"

    private static func makeCommand(
        patientId: String = "placeholder",
        reason: String = "caseObjectiveAchieved",
        notes: String? = nil,
        actorId: String = DischargePatientTests.actorId
    ) -> DischargePatientCommand {
        DischargePatientCommand(
            patientId: patientId,
            reason: reason,
            notes: notes,
            actorId: actorId
        )
    }

    // MARK: - Happy Path

    @Test("Deve desligar paciente ativo com sucesso")
    func successfulDischarge() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = DischargePatientCommandHandler(
            repository: repo
        )

        try await handler.handle(Self.makeCommand(
            patientId: patient.id.description,
            reason: "caseObjectiveAchieved"
        ))

        let saved = await repo.stored(byId: patient.id)
        #expect(saved?.status == .discharged)
        #expect(saved?.dischargeInfo?.reason == .caseObjectiveAchieved)

        let saveCount = await repo.saveCallCount
        #expect(saveCount == 1)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve desligar paciente com reason=other e notes validas")
    func successfulDischargeWithOtherReason() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = DischargePatientCommandHandler(
            repository: repo
        )

        try await handler.handle(Self.makeCommand(
            patientId: patient.id.description,
            reason: "other",
            notes: "Motivo especifico nao categorizado"
        ))

        let saved = await repo.stored(byId: patient.id)
        #expect(saved?.status == .discharged)
        #expect(saved?.dischargeInfo?.reason == .other)
        #expect(saved?.dischargeInfo?.notes == "Motivo especifico nao categorizado")
    }

    @Test("Deve publicar evento apos persistencia")
    func eventPublishedAfterPersistence() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = DischargePatientCommandHandler(
            repository: repo
        )

        try await handler.handle(Self.makeCommand(
            patientId: patient.id.description
        ))

        let lastEvent = await repo.publishedEvents.last
        #expect(lastEvent is PatientDischargedEvent)
    }

    // MARK: - Error Cases

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()

        let handler = DischargePatientCommandHandler(
            repository: repo
        )

        let nonExistentId = PatientId().description

        await #expect(throws: DischargePatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: nonExistentId
            ))
        }

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount == 0)
    }

    @Test("Deve falhar quando paciente ja esta desligado")
    func alreadyDischarged() async throws {
        let repo = InMemoryPatientRepository()
        var patient = try PatientFixture.createMinimalActive()
        try patient.discharge(
            reason: .caseObjectiveAchieved,
            notes: nil,
            actorId: "setup-actor"
        )
        patient.clearEvents()
        await repo.seed(patient)

        let handler = DischargePatientCommandHandler(
            repository: repo
        )

        await #expect(throws: DischargePatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: patient.id.description
            ))
        }
    }

    @Test("Deve falhar com formato de patientId invalido")
    func invalidPatientIdFormat() async throws {
        let repo = InMemoryPatientRepository()

        let handler = DischargePatientCommandHandler(
            repository: repo
        )

        await #expect(throws: DischargePatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: "not-a-valid-uuid"
            ))
        }
    }

    @Test("Deve falhar com razao de desligamento invalida")
    func invalidReason() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = DischargePatientCommandHandler(
            repository: repo
        )

        await #expect(throws: DischargePatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: patient.id.description,
                reason: "invalidReasonThatDoesNotExist"
            ))
        }
    }

    @Test("Deve falhar quando reason=other sem notes")
    func otherReasonWithoutNotes() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = DischargePatientCommandHandler(
            repository: repo
        )

        await #expect(throws: DischargePatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: patient.id.description,
                reason: "other",
                notes: nil
            ))
        }

        let saved = await repo.stored(byId: patient.id)
        #expect(saved?.status == .active)
    }

    @Test("Deve falhar quando notes excede 1000 caracteres")
    func notesExceedMaxLength() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = DischargePatientCommandHandler(
            repository: repo
        )

        let longNotes = String(repeating: "z", count: 1001)

        await #expect(throws: DischargePatientError.self) {
            try await handler.handle(Self.makeCommand(
                patientId: patient.id.description,
                reason: "caseObjectiveAchieved",
                notes: longNotes
            ))
        }
    }
}
