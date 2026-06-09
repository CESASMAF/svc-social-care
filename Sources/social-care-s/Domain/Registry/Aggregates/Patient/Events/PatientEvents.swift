import Foundation

// MARK: - Lifecycle Events

public struct PatientCreatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let personId: String
    public let actorId: String
    public let occurredAt: Date

    public init(patientId: String, personId: String, actorId: String, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.personId = personId
        self.actorId = actorId; self.occurredAt = occurredAt
    }
}

// MARK: - Family Events

public struct FamilyMemberAddedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let memberId: String
    public let relationship: String
    public let actorId: String
    public let occurredAt: Date

    public init(patientId: String, memberId: String, relationship: String, actorId: String, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.memberId = memberId
        self.relationship = relationship; self.actorId = actorId; self.occurredAt = occurredAt
    }
}

public struct FamilyMemberRemovedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let memberId: String
    public let actorId: String
    public let occurredAt: Date

    public init(patientId: String, memberId: String, actorId: String, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.memberId = memberId
        self.actorId = actorId; self.occurredAt = occurredAt
    }
}

public struct PrimaryCaregiverAssignedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let caregiverId: String
    public let actorId: String
    public let occurredAt: Date

    public init(patientId: String, caregiverId: String, actorId: String, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.caregiverId = caregiverId
        self.actorId = actorId; self.occurredAt = occurredAt
    }
}

// MARK: - Intervention Events

public struct ReferralCreatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let referralId: String
    public let referredPersonId: String
    public let destinationService: String
    public let status: String
    public let actorId: String
    public let occurredAt: Date

    public init(patientId: String, referralId: String, referredPersonId: String, destinationService: String, status: String, actorId: String, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.referralId = referralId
        self.referredPersonId = referredPersonId; self.destinationService = destinationService
        self.status = status; self.actorId = actorId; self.occurredAt = occurredAt
    }
}

public struct RightsViolationReportedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let reportId: String
    public let victimId: String
    public let violationType: String
    public let actorId: String
    public let occurredAt: Date

    public init(patientId: String, reportId: String, victimId: String, violationType: String, actorId: String, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.reportId = reportId
        self.victimId = victimId; self.violationType = violationType
        self.actorId = actorId; self.occurredAt = occurredAt
    }
}

public struct SocialCareAppointmentRegisteredEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let appointmentId: String
    public let professionalInChargeId: String
    public let type: String
    public let actorId: String
    public let occurredAt: Date

    public init(patientId: String, appointmentId: String, professionalInChargeId: String, type: String, actorId: String, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.appointmentId = appointmentId
        self.professionalInChargeId = professionalInChargeId; self.type = type
        self.actorId = actorId; self.occurredAt = occurredAt
    }
}

// MARK: - Assessment Events (with before/after diff)

public struct HousingConditionUpdatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let actorId: String
    public let before: HousingCondition?
    public let after: HousingCondition?
    public let occurredAt: Date

    public init(patientId: String, actorId: String, before: HousingCondition?, after: HousingCondition?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.actorId = actorId
        self.before = before; self.after = after; self.occurredAt = occurredAt
    }
}

public struct SocioEconomicSituationUpdatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let actorId: String
    public let before: SocioEconomicSituation?
    public let after: SocioEconomicSituation?
    public let occurredAt: Date

    public init(patientId: String, actorId: String, before: SocioEconomicSituation?, after: SocioEconomicSituation?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.actorId = actorId
        self.before = before; self.after = after; self.occurredAt = occurredAt
    }
}

public struct WorkAndIncomeUpdatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let actorId: String
    public let before: WorkAndIncome?
    public let after: WorkAndIncome?
    public let occurredAt: Date

    public init(patientId: String, actorId: String, before: WorkAndIncome?, after: WorkAndIncome?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.actorId = actorId
        self.before = before; self.after = after; self.occurredAt = occurredAt
    }
}

public struct EducationalStatusUpdatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let actorId: String
    public let before: EducationalStatus?
    public let after: EducationalStatus?
    public let occurredAt: Date

    public init(patientId: String, actorId: String, before: EducationalStatus?, after: EducationalStatus?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.actorId = actorId
        self.before = before; self.after = after; self.occurredAt = occurredAt
    }
}

public struct HealthStatusUpdatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let actorId: String
    public let before: HealthStatus?
    public let after: HealthStatus?
    public let occurredAt: Date

    public init(patientId: String, actorId: String, before: HealthStatus?, after: HealthStatus?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.actorId = actorId
        self.before = before; self.after = after; self.occurredAt = occurredAt
    }
}

public struct CommunitySupportNetworkUpdatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let actorId: String
    public let before: CommunitySupportNetwork?
    public let after: CommunitySupportNetwork?
    public let occurredAt: Date

    public init(patientId: String, actorId: String, before: CommunitySupportNetwork?, after: CommunitySupportNetwork?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.actorId = actorId
        self.before = before; self.after = after; self.occurredAt = occurredAt
    }
}

public struct SocialHealthSummaryUpdatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let actorId: String
    public let before: SocialHealthSummary?
    public let after: SocialHealthSummary?
    public let occurredAt: Date

    public init(patientId: String, actorId: String, before: SocialHealthSummary?, after: SocialHealthSummary?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.actorId = actorId
        self.before = before; self.after = after; self.occurredAt = occurredAt
    }
}

public struct SocialIdentityUpdatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let actorId: String
    public let before: SocialIdentity?
    public let after: SocialIdentity?
    public let occurredAt: Date

    public init(patientId: String, actorId: String, before: SocialIdentity?, after: SocialIdentity?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.actorId = actorId
        self.before = before; self.after = after; self.occurredAt = occurredAt
    }
}

public struct PlacementHistoryUpdatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let actorId: String
    public let before: PlacementHistory?
    public let after: PlacementHistory?
    public let occurredAt: Date

    public init(patientId: String, actorId: String, before: PlacementHistory?, after: PlacementHistory?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.actorId = actorId
        self.before = before; self.after = after; self.occurredAt = occurredAt
    }
}

public struct IntakeInfoUpdatedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let actorId: String
    public let before: IngressInfo?
    public let after: IngressInfo?
    public let occurredAt: Date

    public init(patientId: String, actorId: String, before: IngressInfo?, after: IngressInfo?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.actorId = actorId
        self.before = before; self.after = after; self.occurredAt = occurredAt
    }
}

// MARK: - Discharge Events

public struct PatientDischargedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let personId: String
    public let actorId: String
    public let reason: String
    public let notes: String?
    public let occurredAt: Date

    public init(patientId: String, personId: String, actorId: String, reason: String, notes: String?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.personId = personId
        self.actorId = actorId; self.reason = reason; self.notes = notes; self.occurredAt = occurredAt
    }
}

public struct PatientReadmittedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let personId: String
    public let actorId: String
    public let notes: String?
    public let occurredAt: Date

    public init(patientId: String, personId: String, actorId: String, notes: String?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.personId = personId
        self.actorId = actorId; self.notes = notes; self.occurredAt = occurredAt
    }
}

// MARK: - Waitlist Events

public struct PatientAdmittedEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let personId: String
    public let actorId: String
    public let occurredAt: Date

    public init(patientId: String, personId: String, actorId: String, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.personId = personId
        self.actorId = actorId; self.occurredAt = occurredAt
    }
}

public struct PatientWithdrawnFromWaitlistEvent: DomainEvent, Codable {
    public let id: UUID
    public let patientId: String
    public let personId: String
    public let actorId: String
    public let reason: String
    public let notes: String?
    public let occurredAt: Date

    public init(patientId: String, personId: String, actorId: String, reason: String, notes: String?, occurredAt: Date) {
        self.id = UUID(); self.patientId = patientId; self.personId = personId
        self.actorId = actorId; self.reason = reason; self.notes = notes; self.occurredAt = occurredAt
    }
}
