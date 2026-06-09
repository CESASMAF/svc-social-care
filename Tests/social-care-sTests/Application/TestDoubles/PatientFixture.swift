import Foundation
@testable import social_care_s

enum PatientFixture {
    static let defaultPersonId = "550e8400-e29b-41d4-a716-446655440000"
    static let defaultActorId = "test-actor"
    static let defaultMemberId = "660e8400-e29b-41d4-a716-446655440001"

    static func createMinimal(
        personId: String = defaultPersonId,
        actorId: String = defaultActorId
    ) throws -> Patient {
        let pid = try PersonId(personId)
        let prId = try LookupId(UUID().uuidString)
        let prMember = FamilyMember(
            personId: pid,
            relationshipId: prId,
            isPrimaryCaregiver: true,
            residesWithPatient: true,
            birthDate: .now
        )
        return try Patient(
            id: PatientId(),
            personId: pid,
            diagnoses: [createDiagnosis()],
            familyMembers: [prMember],
            prRelationshipId: prId,
            actorId: actorId
        )
    }

    /// Creates a minimal patient with status = .waitlisted, for testing waitlist flows.
    static func createMinimalWaitlisted(
        personId: String = defaultPersonId,
        actorId: String = defaultActorId
    ) throws -> Patient {
        var patient = try createMinimal(personId: personId, actorId: actorId)
        patient.status = .waitlisted
        patient.clearEvents()
        return patient
    }

    /// Creates a minimal patient (status = .active by default), clearing setup events.
    static func createMinimalActive(
        personId: String = defaultPersonId,
        actorId: String = defaultActorId
    ) throws -> Patient {
        var patient = try createMinimal(personId: personId, actorId: actorId)
        patient.clearEvents()
        return patient
    }

    /// Creates a patient with a female PR (status = .active by default), clearing setup events.
    static func createWithFemalePRActive(
        personId: String = defaultPersonId,
        actorId: String = defaultActorId
    ) throws -> Patient {
        var patient = try createWithFemalePR(personId: personId, actorId: actorId)
        patient.clearEvents()
        return patient
    }

    static func createWithFemalePR(
        personId: String = defaultPersonId,
        actorId: String = defaultActorId
    ) throws -> Patient {
        let pid = try PersonId(personId)
        let prId = try LookupId(UUID().uuidString)
        let prMember = FamilyMember(
            personId: pid,
            relationshipId: prId,
            isPrimaryCaregiver: true,
            residesWithPatient: true,
            birthDate: .now
        )
        let personalData = try PersonalData(
            firstName: "Maria",
            lastName: "Silva",
            motherName: "Ana",
            nationality: "Brasileira",
            sex: .feminino,
            socialName: nil,
            birthDate: try TimeStamp(iso: "1990-01-01T00:00:00Z"),
            phone: nil
        )
        return try Patient(
            id: PatientId(),
            personId: pid,
            personalData: personalData,
            diagnoses: [createDiagnosis()],
            familyMembers: [prMember],
            prRelationshipId: prId,
            actorId: actorId
        )
    }

    /// Creates a patient with an additional member (status = .active by default), clearing setup events.
    static func createWithAdditionalMemberActive(
        personId: String = defaultPersonId,
        memberId: String = defaultMemberId,
        memberBirthDate: String = "2010-06-15T00:00:00Z",
        actorId: String = defaultActorId
    ) throws -> Patient {
        var patient = try createWithAdditionalMember(personId: personId, memberId: memberId, memberBirthDate: memberBirthDate, actorId: actorId)
        patient.clearEvents()
        return patient
    }

    static func createWithAdditionalMember(
        personId: String = defaultPersonId,
        memberId: String = defaultMemberId,
        memberBirthDate: String = "2010-06-15T00:00:00Z",
        actorId: String = defaultActorId
    ) throws -> Patient {
        let pid = try PersonId(personId)
        let memberPid = try PersonId(memberId)
        let prId = try LookupId(UUID().uuidString)
        let memberRelId = try LookupId(UUID().uuidString)

        let prMember = FamilyMember(
            personId: pid,
            relationshipId: prId,
            isPrimaryCaregiver: true,
            residesWithPatient: true,
            birthDate: try TimeStamp(iso: "1985-01-01T00:00:00Z")
        )
        let additionalMember = FamilyMember(
            personId: memberPid,
            relationshipId: memberRelId,
            isPrimaryCaregiver: false,
            residesWithPatient: true,
            birthDate: try TimeStamp(iso: memberBirthDate)
        )

        return try Patient(
            id: PatientId(),
            personId: pid,
            diagnoses: [createDiagnosis()],
            familyMembers: [prMember, additionalMember],
            prRelationshipId: prId,
            actorId: actorId
        )
    }

    static func createDiagnosis() throws -> Diagnosis {
        try Diagnosis(id: try ICDCode("B201"), date: .now, description: "Test diagnosis", now: .now)
    }
}
