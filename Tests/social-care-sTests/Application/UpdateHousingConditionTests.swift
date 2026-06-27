import Testing
import Foundation
@testable import social_care_s

@Suite("UpdateHousingCondition Command Handler")
struct UpdateHousingConditionTests {

    private static func validConditionDraft() -> UpdateHousingConditionCommand.ConditionDraft {
        .init(
            type: "OWNED",
            wallMaterial: "MASONRY",
            numberOfRooms: 5,
            numberOfBedrooms: 2,
            numberOfBathrooms: 1,
            waterSupply: "PUBLIC_NETWORK",
            hasPipedWater: true,
            electricityAccess: "METERED_CONNECTION",
            sewageDisposal: "PUBLIC_SEWER",
            wasteCollection: "DIRECT_COLLECTION",
            accessibilityLevel: "FULLY_ACCESSIBLE",
            isInGeographicRiskArea: false,
            hasDifficultAccess: false,
            isInSocialConflictArea: false,
            hasDiagnosticObservations: false
        )
    }

    @Test("Deve atualizar condicao de moradia com sucesso")
    func successfulUpdate() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateHousingConditionCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        try await handler.handle(UpdateHousingConditionCommand(
            patientId: patient.id.description,
            condition: Self.validConditionDraft(),
            actorId: "actor-1"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.housingCondition != nil)
        #expect(saved?.housingCondition?.numberOfRooms == 5)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar com tipo de moradia invalido")
    func invalidHousingType() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateHousingConditionCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        var draft = Self.validConditionDraft()
        let invalidDraft = UpdateHousingConditionCommand.ConditionDraft(
            type: "INVALIDO",
            wallMaterial: draft.wallMaterial,
            numberOfRooms: draft.numberOfRooms,
            numberOfBedrooms: draft.numberOfBedrooms,
            numberOfBathrooms: draft.numberOfBathrooms,
            waterSupply: draft.waterSupply,
            hasPipedWater: draft.hasPipedWater,
            electricityAccess: draft.electricityAccess,
            sewageDisposal: draft.sewageDisposal,
            wasteCollection: draft.wasteCollection,
            accessibilityLevel: draft.accessibilityLevel,
            isInGeographicRiskArea: false,
            hasDifficultAccess: false,
            isInSocialConflictArea: false,
            hasDiagnosticObservations: false
        )

        await #expect(throws: UpdateHousingConditionError.self) {
            try await handler.handle(UpdateHousingConditionCommand(
                patientId: patient.id.description,
                condition: invalidDraft,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = UpdateHousingConditionCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        await #expect(throws: UpdateHousingConditionError.self) {
            try await handler.handle(UpdateHousingConditionCommand(
                patientId: UUID().uuidString,
                condition: Self.validConditionDraft(),
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: atualizacoes concorrentes em pacientes distintos")
    func concurrentUpdates() async throws {
        let repo = InMemoryPatientRepository()

        let p1 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        let p2 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        await repo.seed(p1)
        await repo.seed(p2)

        let handler = UpdateHousingConditionCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository())

        async let r1: Void = handler.handle(UpdateHousingConditionCommand(
            patientId: p1.id.description,
            condition: Self.validConditionDraft(),
            actorId: "actor-1"
        ))
        async let r2: Void = handler.handle(UpdateHousingConditionCommand(
            patientId: p2.id.description,
            condition: Self.validConditionDraft(),
            actorId: "actor-2"
        ))

        try await r1
        try await r2

        let saved1 = try await repo.find(byPersonId: p1.personId)
        let saved2 = try await repo.find(byPersonId: p2.personId)
        #expect(saved1?.housingCondition != nil)
        #expect(saved2?.housingCondition != nil)
    }
}
