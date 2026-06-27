import Testing
import Foundation
@testable import social_care_s

@Suite("RegisterIntakeInfo Command Handler")
struct RegisterIntakeInfoTests {

    @Test("Deve registrar info de ingresso com sucesso")
    func successfulRegistration() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let ingressTypeId = UUID().uuidString
        let programId = UUID().uuidString

        let handler = RegisterIntakeInfoCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        try await handler.handle(RegisterIntakeInfoCommand(
            patientId: patient.id.description,
            ingressTypeId: ingressTypeId,
            originName: "CRAS Norte",
            originContact: "3333-4444",
            serviceReason: "Vulnerabilidade social",
            linkedSocialPrograms: [
                .init(programId: programId, observation: "Cadastrado em 2024")
            ],
            actorId: "actor-1"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.intakeInfo != nil)
        #expect(saved?.intakeInfo?.originName == "CRAS Norte")
        #expect(saved?.intakeInfo?.linkedSocialPrograms.count == 1)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar com lookup de tipo de ingresso invalido")
    func invalidIngressTypeLookup() async throws {
        let repo = InMemoryPatientRepository()
        let lookup = InMemoryLookupValidator()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = RegisterIntakeInfoCommandHandler(
            repository: repo, lookupValidator: lookup
        )

        await #expect(throws: RegisterIntakeInfoError.self) {
            try await handler.handle(RegisterIntakeInfoCommand(
                patientId: patient.id.description,
                ingressTypeId: UUID().uuidString,
                originName: "CRAS",
                originContact: nil,
                serviceReason: "Motivo",
                linkedSocialPrograms: [],
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar com lookup de programa social invalido")
    func invalidProgramLookup() async throws {
        let repo = InMemoryPatientRepository()
        let lookup = InMemoryLookupValidator()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let ingressTypeId = try LookupId(UUID().uuidString)
        await lookup.register(id: ingressTypeId, in: "dominio_tipo_ingresso")

        let handler = RegisterIntakeInfoCommandHandler(
            repository: repo, lookupValidator: lookup
        )

        await #expect(throws: RegisterIntakeInfoError.self) {
            try await handler.handle(RegisterIntakeInfoCommand(
                patientId: patient.id.description,
                ingressTypeId: ingressTypeId.description,
                originName: "CRAS",
                originContact: nil,
                serviceReason: "Motivo",
                linkedSocialPrograms: [
                    .init(programId: UUID().uuidString, observation: nil)
                ],
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = RegisterIntakeInfoCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        await #expect(throws: RegisterIntakeInfoError.self) {
            try await handler.handle(RegisterIntakeInfoCommand(
                patientId: UUID().uuidString,
                ingressTypeId: UUID().uuidString,
                originName: "CRAS",
                originContact: nil,
                serviceReason: "Motivo",
                linkedSocialPrograms: [],
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: multiplos handlers concorrentes")
    func concurrentHandlers() async throws {
        let repo = InMemoryPatientRepository()

        let p1 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        let p2 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        await repo.seed(p1)
        await repo.seed(p2)

        let handler1 = RegisterIntakeInfoCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )
        let handler2 = RegisterIntakeInfoCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        async let r1: Void = handler1.handle(RegisterIntakeInfoCommand(
            patientId: p1.id.description,
            ingressTypeId: UUID().uuidString,
            originName: "CRAS A", originContact: nil,
            serviceReason: "Motivo A", linkedSocialPrograms: [],
            actorId: "actor-1"
        ))
        async let r2: Void = handler2.handle(RegisterIntakeInfoCommand(
            patientId: p2.id.description,
            ingressTypeId: UUID().uuidString,
            originName: "CRAS B", originContact: nil,
            serviceReason: "Motivo B", linkedSocialPrograms: [],
            actorId: "actor-2"
        ))

        try await r1
        try await r2

        let saved1 = try await repo.find(byPersonId: p1.personId)
        let saved2 = try await repo.find(byPersonId: p2.personId)
        #expect(saved1?.intakeInfo?.originName == "CRAS A")
        #expect(saved2?.intakeInfo?.originName == "CRAS B")
    }
}
