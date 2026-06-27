import Testing
import Foundation
@testable import social_care_s

@Suite("AddFamilyMember Command Handler")
struct AddFamilyMemberTests {

    private static let newMemberId = "880e8400-e29b-41d4-a716-446655440002"

    @Test("Deve adicionar membro familiar com sucesso")
    func successfulAddition() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = AddFamilyMemberCommandHandler(
            patientRepository: repo, lookupValidator: AllowAllLookupValidator()
        )

        let prRelId = patient.familyMembers.first!.relationshipId.description

        try await handler.handle(AddFamilyMemberCommand(
            patientId: patient.id.description,
            memberPersonId: Self.newMemberId,
            relationship: UUID().uuidString,
            isResiding: true,
            isCaregiver: false,
            hasDisability: false,
            requiredDocuments: [],
            birthDate: Date(timeIntervalSince1970: 1_000_000_000),
            prRelationshipId: prRelId,
            actorId: "actor-1"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.familyMembers.count == 2)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar quando membro ja existe na familia")
    func duplicateMember() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = AddFamilyMemberCommandHandler(
            patientRepository: repo, lookupValidator: AllowAllLookupValidator()
        )

        let prRelId = patient.familyMembers.first!.relationshipId.description

        await #expect(throws: AddFamilyMemberError.self) {
            try await handler.handle(AddFamilyMemberCommand(
                patientId: patient.id.description,
                memberPersonId: PatientFixture.defaultPersonId,
                relationship: UUID().uuidString,
                isResiding: true,
                isCaregiver: false,
                hasDisability: false,
                requiredDocuments: [],
                birthDate: Date(),
                prRelationshipId: prRelId,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = AddFamilyMemberCommandHandler(
            patientRepository: repo, lookupValidator: AllowAllLookupValidator()
        )

        await #expect(throws: AddFamilyMemberError.self) {
            try await handler.handle(AddFamilyMemberCommand(
                patientId: UUID().uuidString,
                memberPersonId: UUID().uuidString,
                relationship: UUID().uuidString,
                isResiding: true,
                isCaregiver: false,
                hasDisability: false,
                requiredDocuments: [],
                birthDate: Date(),
                prRelationshipId: UUID().uuidString,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente esta na lista de espera")
    func patientIsWaitlisted() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalWaitlisted()
        await repo.seed(patient)

        let handler = AddFamilyMemberCommandHandler(
            patientRepository: repo, lookupValidator: AllowAllLookupValidator()
        )

        let prRelId = patient.familyMembers.first!.relationshipId.description

        await #expect(throws: AddFamilyMemberError.patientNotActive(reason: "PATIENT_IS_WAITLISTED")) {
            try await handler.handle(AddFamilyMemberCommand(
                patientId: patient.id.description,
                memberPersonId: Self.newMemberId,
                relationship: UUID().uuidString,
                isResiding: true,
                isCaregiver: false,
                hasDisability: false,
                requiredDocuments: [],
                birthDate: Date(timeIntervalSince1970: 1_000_000_000),
                prRelationshipId: prRelId,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar com lookup de parentesco invalido")
    func invalidRelationshipLookup() async throws {
        let repo = InMemoryPatientRepository()
        let lookup = InMemoryLookupValidator()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = AddFamilyMemberCommandHandler(
            patientRepository: repo, lookupValidator: lookup
        )

        await #expect(throws: AddFamilyMemberError.self) {
            try await handler.handle(AddFamilyMemberCommand(
                patientId: patient.id.description,
                memberPersonId: Self.newMemberId,
                relationship: UUID().uuidString,
                isResiding: true,
                isCaregiver: false,
                hasDisability: false,
                requiredDocuments: [],
                birthDate: Date(),
                prRelationshipId: UUID().uuidString,
                actorId: "actor-1"
            ))
        }
    }
}
