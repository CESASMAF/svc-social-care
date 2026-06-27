import Testing
import Foundation
@testable import social_care_s

@Suite("UpdateHealthStatus Command Handler")
struct UpdateHealthStatusTests {

    @Test("Deve atualizar status de saude com sucesso")
    func successfulUpdate() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let memberId = patient.personId.description
        let defTypeId = UUID().uuidString

        let handler = UpdateHealthStatusCommandHandler(
            repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository(), lookupValidator: AllowAllLookupValidator()
        )

        try await handler.handle(UpdateHealthStatusCommand(
            patientId: patient.id.description,
            deficiencies: [
                .init(memberId: memberId, deficiencyTypeId: defTypeId,
                      needsConstantCare: true, responsibleCaregiverName: "Joao")
            ],
            gestatingMembers: [],
            constantCareNeeds: [memberId],
            foodInsecurity: true,
            actorId: "actor-1"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.healthStatus != nil)
        #expect(saved?.healthStatus?.deficiencies.count == 1)
        #expect(saved?.healthStatus?.foodInsecurity == true)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar com lookup de tipo de deficiencia invalido")
    func invalidDeficiencyTypeLookup() async throws {
        let repo = InMemoryPatientRepository()
        let lookup = InMemoryLookupValidator()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateHealthStatusCommandHandler(
            repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository(), lookupValidator: lookup
        )

        await #expect(throws: UpdateHealthStatusError.self) {
            try await handler.handle(UpdateHealthStatusCommand(
                patientId: patient.id.description,
                deficiencies: [
                    .init(memberId: patient.personId.description,
                          deficiencyTypeId: UUID().uuidString,
                          needsConstantCare: false, responsibleCaregiverName: nil)
                ],
                gestatingMembers: [],
                constantCareNeeds: [],
                foodInsecurity: false,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = UpdateHealthStatusCommandHandler(
            repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository(), lookupValidator: AllowAllLookupValidator()
        )

        await #expect(throws: UpdateHealthStatusError.self) {
            try await handler.handle(UpdateHealthStatusCommand(
                patientId: UUID().uuidString,
                deficiencies: [],
                gestatingMembers: [],
                constantCareNeeds: [],
                foodInsecurity: false,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: handler e um actor que serializa acesso")
    func actorSerializesAccess() async throws {
        let repo = InMemoryPatientRepository()
        let handler = UpdateHealthStatusCommandHandler(
            repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository(), lookupValidator: AllowAllLookupValidator()
        )

        let p1 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        let p2 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        await repo.seed(p1)
        await repo.seed(p2)

        async let r1: Void = handler.handle(UpdateHealthStatusCommand(
            patientId: p1.id.description,
            deficiencies: [], gestatingMembers: [],
            constantCareNeeds: [], foodInsecurity: true,
            actorId: "actor-1"
        ))
        async let r2: Void = handler.handle(UpdateHealthStatusCommand(
            patientId: p2.id.description,
            deficiencies: [], gestatingMembers: [],
            constantCareNeeds: [], foodInsecurity: false,
            actorId: "actor-2"
        ))

        try await r1
        try await r2

        let saved1 = try await repo.find(byPersonId: p1.personId)
        let saved2 = try await repo.find(byPersonId: p2.personId)
        #expect(saved1?.healthStatus?.foodInsecurity == true)
        #expect(saved2?.healthStatus?.foodInsecurity == false)
    }
}
