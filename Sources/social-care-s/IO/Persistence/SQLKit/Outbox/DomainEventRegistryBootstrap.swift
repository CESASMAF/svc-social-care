import Foundation

extension DomainEventRegistry {
    /// Registra todos os eventos de domínio conhecidos do Bounded Context.
    public func bootstrap() async {
        self.register(PatientCreatedEvent.self)
        self.register(FamilyMemberAddedEvent.self)
        self.register(FamilyMemberRemovedEvent.self)
        self.register(PrimaryCaregiverAssignedEvent.self)
        self.register(ReferralCreatedEvent.self)
        self.register(RightsViolationReportedEvent.self)
        self.register(SocialCareAppointmentRegisteredEvent.self)
        self.register(HousingConditionUpdatedEvent.self)
        self.register(SocioEconomicSituationUpdatedEvent.self)
        self.register(WorkAndIncomeUpdatedEvent.self)
        self.register(EducationalStatusUpdatedEvent.self)
        self.register(HealthStatusUpdatedEvent.self)
        self.register(CommunitySupportNetworkUpdatedEvent.self)
        self.register(SocialHealthSummaryUpdatedEvent.self)
        self.register(SocialIdentityUpdatedEvent.self)
        self.register(PlacementHistoryUpdatedEvent.self)
        self.register(IntakeInfoUpdatedEvent.self)
        self.register(PatientDischargedEvent.self)
        self.register(PatientReadmittedEvent.self)
        self.register(PatientAdmittedEvent.self)
        self.register(PatientWithdrawnFromWaitlistEvent.self)
    }
}
