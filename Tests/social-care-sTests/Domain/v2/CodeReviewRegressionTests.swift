import Testing
@testable import social_care_s
import Foundation

@Suite("Code Review Regression Tests (2026-03-06)")
struct CodeReviewRegressionTests {

    // MARK: - C1: HousingCondition error semantics

    @Test("C1: Negative bedrooms throws .negativeBedrooms, not .negativeRooms")
    func negativeBedrooms() {
        #expect(throws: HousingConditionError.negativeBedrooms) {
            try HousingCondition(
                type: .owned, wallMaterial: .masonry,
                numberOfRooms: 3, numberOfBedrooms: -1, numberOfBathrooms: 1,
                waterSupply: .publicNetwork, hasPipedWater: true,
                electricityAccess: .meteredConnection, sewageDisposal: .publicSewer,
                wasteCollection: .directCollection, accessibilityLevel: .fullyAccessible,
                isInGeographicRiskArea: false, hasDifficultAccess: false,
                isInSocialConflictArea: false, hasDiagnosticObservations: false
            )
        }
    }

    @Test("C1: Bedrooms exceeding rooms throws .bedroomsExceedRooms")
    func bedroomsExceedRooms() {
        #expect(throws: HousingConditionError.bedroomsExceedRooms) {
            try HousingCondition(
                type: .owned, wallMaterial: .masonry,
                numberOfRooms: 2, numberOfBedrooms: 5, numberOfBathrooms: 1,
                waterSupply: .publicNetwork, hasPipedWater: true,
                electricityAccess: .meteredConnection, sewageDisposal: .publicSewer,
                wasteCollection: .directCollection, accessibilityLevel: .fullyAccessible,
                isInGeographicRiskArea: false, hasDifficultAccess: false,
                isInSocialConflictArea: false, hasDiagnosticObservations: false
            )
        }
    }

    @Test("C1: HousingCondition error AppErrorConvertible for new cases")
    func housingConditionErrorConvertible() {
        let err1 = HousingConditionError.negativeBedrooms.asAppError
        #expect(err1.code == "HC-002")

        let err2 = HousingConditionError.bedroomsExceedRooms.asAppError
        #expect(err2.code == "HC-004")
    }

    // MARK: - C2: validatePlacementCompatibility now throws

    @Test("C2: validatePlacementCompatibility throws when adolescent internment but no adolescent")
    func placementIncompatibleAdolescent() throws {
        let patient = try createPatientWithAdultOnly()
        let history = PlacementHistory(
            familyId: patient.id,
            individualPlacements: [],
            collectiveSituations: CollectiveSituations(homeLossReport: nil, thirdPartyGuardReport: nil),
            separationChecklist: SeparationChecklist(adultInPrison: false, adolescentInInternment: true)
        )
        #expect(throws: PatientError.incompatiblePlacementSituation) {
            try patient.validatePlacementCompatibility(history)
        }
    }

    @Test("C2: validatePlacementCompatibility throws when guardianship but no minor")
    func placementIncompatibleGuardianship() throws {
        let patient = try createPatientWithAdultOnly()
        let history = PlacementHistory(
            familyId: patient.id,
            individualPlacements: [],
            collectiveSituations: CollectiveSituations(homeLossReport: nil, thirdPartyGuardReport: "report"),
            separationChecklist: SeparationChecklist(adultInPrison: false, adolescentInInternment: false)
        )
        #expect(throws: PatientError.incompatibleGuardianshipSituation) {
            try patient.validatePlacementCompatibility(history)
        }
    }

    @Test("C2: validatePlacementCompatibility succeeds with compatible family")
    func placementCompatible() throws {
        let patient = try createPatientWithMinor()
        let history = PlacementHistory(
            familyId: patient.id,
            individualPlacements: [],
            collectiveSituations: CollectiveSituations(homeLossReport: nil, thirdPartyGuardReport: "report"),
            separationChecklist: SeparationChecklist(adultInPrison: false, adolescentInInternment: true)
        )
        // Should not throw
        try patient.validatePlacementCompatibility(history)
    }

    // MARK: - C3: PlacementError conformances

    @Test("C3: PlacementError conforms to AppErrorConvertible")
    func placementErrorConvertible() {
        let err = PlacementError.invalidDateRange.asAppError
        #expect(err.code == "PLC-001")
        #expect(err.http == 422)
    }

    @Test("C3: PlacementError is Sendable and Equatable")
    func placementErrorEquatable() {
        let a = PlacementError.invalidDateRange
        let b = PlacementError.invalidDateRange
        #expect(a == b)
    }

    // MARK: - C4: Error cases renamed to English

    @Test("C4: PatientError uses English-only case names")
    func patientErrorEnglishNames() {
        let err1 = PatientError.incompatiblePlacementSituation.asAppError
        #expect(err1.code == "PAT-010")

        let err2 = PatientError.incompatibleGuardianshipSituation.asAppError
        #expect(err2.code == "PAT-011")
    }

    // MARK: - M3: IngressInfo validation

    @Test("M3: IngressInfo rejects empty serviceReason")
    func ingressInfoEmptyReason() {
        #expect(throws: IngressInfoError.emptyServiceReason) {
            try IngressInfo(
                ingressTypeId: try LookupId(UUID().uuidString),
                originName: nil, originContact: nil,
                serviceReason: "   ",
                linkedSocialPrograms: []
            )
        }
    }

    @Test("M3: IngressInfo accepts valid serviceReason")
    func ingressInfoValidReason() throws {
        let info = try IngressInfo(
            ingressTypeId: try LookupId(UUID().uuidString),
            originName: nil, originContact: nil,
            serviceReason: "Family needs assistance",
            linkedSocialPrograms: []
        )
        #expect(info.serviceReason == "Family needs assistance")
    }

    @Test("M3: IngressInfoError conforms to AppErrorConvertible")
    func ingressInfoErrorConvertible() {
        let err = IngressInfoError.emptyServiceReason.asAppError
        #expect(err.code == "ING-001")
    }

    // MARK: - M4: WorkIncomeVO validation

    @Test("M4: WorkIncomeVO rejects negative monthlyAmount via Money.init (ADR-009)")
    func workIncomeNegativeAmount() {
        // ADR-009: validação de negativo agora vive em Money.init, não no
        // WorkIncomeVO. WorkIncomeError.negativeMonthlyAmount continua existindo
        // mas ninguém o lança — aqui validamos que o caminho real (Money) bloqueia.
        #expect(throws: MoneyError.self) {
            _ = WorkIncomeVO(
                memberId: PersonId(),
                occupationId: try LookupId(UUID().uuidString),
                hasWorkCard: true,
                monthlyAmount: try Money(centavos: -10000)  // -R$ 100,00
            )
        }
    }

    @Test("M4: WorkIncomeVO accepts zero monthlyAmount")
    func workIncomeZeroAmount() throws {
        let vo = WorkIncomeVO(
            memberId: PersonId(),
            occupationId: try LookupId(UUID().uuidString),
            hasWorkCard: false,
            monthlyAmount: .zero  // ADR-009: Money.zero
        )
        #expect(vo.monthlyAmount == .zero)
    }

    @Test("M4: WorkIncomeError conforms to AppErrorConvertible")
    func workIncomeErrorConvertible() {
        let err = WorkIncomeError.negativeMonthlyAmount.asAppError
        #expect(err.code == "WI-001")
    }

    // MARK: - S4: FamilyMember.init does not throw

    @Test("S4: FamilyMember.init succeeds without try")
    func familyMemberInitNoThrow() {
        let member = FamilyMember(
            personId: PersonId(),
            relationshipId: try! LookupId(UUID().uuidString),
            isPrimaryCaregiver: false,
            residesWithPatient: true,
            birthDate: .now
        )
        #expect(member.residesWithPatient == true)
    }
}

// MARK: - Test Helpers

private func createPatientWithAdultOnly() throws -> Patient {
    let pId = PersonId()
    let prId = try LookupId(UUID().uuidString)
    let adultBirth = try TimeStamp(iso: "1990-01-01T00:00:00Z")
    let prMember = FamilyMember(personId: pId, relationshipId: prId, isPrimaryCaregiver: true, residesWithPatient: true, birthDate: adultBirth)
    return try Patient(
        id: PatientId(), personId: pId,
        diagnoses: [try Diagnosis(id: try ICDCode("B201"), date: .now, description: "D", now: .now)],
        familyMembers: [prMember],
        prRelationshipId: prId,
        actorId: "test-actor"
    )
}

private func createPatientWithMinor() throws -> Patient {
    let pId = PersonId()
    let prId = try LookupId(UUID().uuidString)
    let otherId = try LookupId(UUID().uuidString)
    let adultBirth = try TimeStamp(iso: "1990-01-01T00:00:00Z")
    let minorBirth = try TimeStamp(iso: "2012-01-01T00:00:00Z")
    let prMember = FamilyMember(personId: pId, relationshipId: prId, isPrimaryCaregiver: true, residesWithPatient: true, birthDate: adultBirth)
    let minor = FamilyMember(personId: PersonId(), relationshipId: otherId, isPrimaryCaregiver: false, residesWithPatient: true, birthDate: minorBirth)
    return try Patient(
        id: PatientId(), personId: pId,
        diagnoses: [try Diagnosis(id: try ICDCode("B201"), date: .now, description: "D", now: .now)],
        familyMembers: [prMember, minor],
        prRelationshipId: prId,
        actorId: "test-actor"
    )
}
