import Testing
import Foundation
@testable import social_care_s

@Suite("UpdateEducationalStatus Command Handler")
struct UpdateEducationalStatusTests {

    @Test("Deve atualizar status educacional com sucesso")
    func successfulUpdate() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let memberId = patient.personId.description
        let levelId = UUID().uuidString
        let effectId = UUID().uuidString

        let handler = UpdateEducationalStatusCommandHandler(
            repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository(), lookupValidator: AllowAllLookupValidator()
        )

        try await handler.handle(UpdateEducationalStatusCommand(
            patientId: patient.id.description,
            memberProfiles: [
                .init(memberId: memberId, canReadWrite: true, attendsSchool: true, educationLevelId: levelId)
            ],
            programOccurrences: [
                .init(memberId: memberId, date: Date(), effectId: effectId, isSuspensionRequested: false)
            ],
            actorId: "actor-1"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.educationalStatus != nil)
        #expect(saved?.educationalStatus?.memberProfiles.count == 1)
        #expect(saved?.educationalStatus?.programOccurrences.count == 1)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar com lookup de escolaridade invalido")
    func invalidEducationLevelLookup() async throws {
        let repo = InMemoryPatientRepository()
        let lookup = InMemoryLookupValidator()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateEducationalStatusCommandHandler(
            repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository(), lookupValidator: lookup
        )

        await #expect(throws: UpdateEducationalStatusError.self) {
            try await handler.handle(UpdateEducationalStatusCommand(
                patientId: patient.id.description,
                memberProfiles: [
                    .init(memberId: patient.personId.description,
                          canReadWrite: true, attendsSchool: false,
                          educationLevelId: UUID().uuidString)
                ],
                programOccurrences: [],
                actorId: "actor-1"
            ))
        }

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount == 0)
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = UpdateEducationalStatusCommandHandler(
            repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository(), lookupValidator: AllowAllLookupValidator()
        )

        await #expect(throws: UpdateEducationalStatusError.self) {
            try await handler.handle(UpdateEducationalStatusCommand(
                patientId: UUID().uuidString,
                memberProfiles: [],
                programOccurrences: [],
                actorId: "actor-1"
            ))
        }
    }
}
