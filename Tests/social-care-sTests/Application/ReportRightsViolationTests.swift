import Testing
import Foundation
@testable import social_care_s

@Suite("ReportRightsViolation Command Handler")
struct ReportRightsViolationTests {

    @Test("Deve registrar violacao de direitos com sucesso")
    func successfulReport() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = ReportRightsViolationCommandHandler(repository: repo)

        let reportId = try await handler.handle(ReportRightsViolationCommand(
            patientId: patient.id.description,
            victimId: PatientFixture.defaultPersonId,
            violationType: "NEGLECT",
            descriptionOfFact: "Descricao detalhada do fato ocorrido",
            actorId: "actor-1"
        ))

        #expect(!reportId.isEmpty)

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.violationReports.count == 1)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar com tipo de violacao invalido")
    func invalidViolationType() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = ReportRightsViolationCommandHandler(repository: repo)

        await #expect(throws: ReportRightsViolationError.self) {
            try await handler.handle(ReportRightsViolationCommand(
                patientId: patient.id.description,
                victimId: PatientFixture.defaultPersonId,
                violationType: "TIPO_INVALIDO",
                descriptionOfFact: "Descricao",
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = ReportRightsViolationCommandHandler(repository: repo)

        await #expect(throws: ReportRightsViolationError.self) {
            try await handler.handle(ReportRightsViolationCommand(
                patientId: UUID().uuidString,
                victimId: UUID().uuidString,
                violationType: "NEGLECT",
                descriptionOfFact: "Descricao",
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: relatos concorrentes em pacientes distintos")
    func concurrentReports() async throws {
        let repo = InMemoryPatientRepository()

        let p1 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        let p2 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        await repo.seed(p1)
        await repo.seed(p2)

        let handler = ReportRightsViolationCommandHandler(repository: repo)

        async let r1 = handler.handle(ReportRightsViolationCommand(
            patientId: p1.id.description,
            victimId: p1.personId.description,
            violationType: "NEGLECT",
            descriptionOfFact: "Fato A",
            actorId: "actor-1"
        ))
        async let r2 = handler.handle(ReportRightsViolationCommand(
            patientId: p2.id.description,
            victimId: p2.personId.description,
            violationType: "DISCRIMINATION",
            descriptionOfFact: "Fato B",
            actorId: "actor-2"
        ))

        let id1 = try await r1
        let id2 = try await r2

        #expect(!id1.isEmpty)
        #expect(!id2.isEmpty)
    }
}
