import Testing
import Foundation
@testable import social_care_s

@Suite("RegisterAppointment Command Handler")
struct RegisterAppointmentTests {

    @Test("Deve registrar atendimento com sucesso")
    func successfulRegistration() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = RegisterAppointmentCommandHandler(repository: repo)

        let appointmentId = try await handler.handle(RegisterAppointmentCommand(
            patientId: patient.id.description,
            professionalId: UUID().uuidString,
            summary: "Atendimento inicial",
            actionPlan: "Encaminhar para CRAS",
            type: "HOME_VISIT",
            actorId: "actor-1"
        ))

        #expect(!appointmentId.isEmpty)

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.appointments.count == 1)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve registrar atendimento sem tipo (default other)")
    func registrationWithDefaultType() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = RegisterAppointmentCommandHandler(repository: repo)

        let appointmentId = try await handler.handle(RegisterAppointmentCommand(
            patientId: patient.id.description,
            professionalId: UUID().uuidString,
            summary: "Resumo",
            actorId: "actor-1"
        ))

        #expect(!appointmentId.isEmpty)
    }

    @Test("Deve falhar com tipo de atendimento invalido")
    func invalidAppointmentType() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = RegisterAppointmentCommandHandler(repository: repo)

        await #expect(throws: RegisterAppointmentError.self) {
            try await handler.handle(RegisterAppointmentCommand(
                patientId: patient.id.description,
                professionalId: UUID().uuidString,
                type: "TIPO_INVALIDO",
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = RegisterAppointmentCommandHandler(repository: repo)

        await #expect(throws: RegisterAppointmentError.self) {
            try await handler.handle(RegisterAppointmentCommand(
                patientId: UUID().uuidString,
                professionalId: UUID().uuidString,
                summary: "Resumo",
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: atendimentos concorrentes em pacientes distintos")
    func concurrentAppointments() async throws {
        let repo = InMemoryPatientRepository()

        let p1 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        let p2 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        await repo.seed(p1)
        await repo.seed(p2)

        let handler = RegisterAppointmentCommandHandler(repository: repo)

        async let r1 = handler.handle(RegisterAppointmentCommand(
            patientId: p1.id.description,
            professionalId: UUID().uuidString,
            summary: "Visita A",
            type: "HOME_VISIT",
            actorId: "actor-1"
        ))
        async let r2 = handler.handle(RegisterAppointmentCommand(
            patientId: p2.id.description,
            professionalId: UUID().uuidString,
            summary: "Atendimento B",
            type: "OFFICE_APPOINTMENT",
            actorId: "actor-2"
        ))

        let id1 = try await r1
        let id2 = try await r2

        #expect(!id1.isEmpty)
        #expect(!id2.isEmpty)
        #expect(id1 != id2)
    }
}
