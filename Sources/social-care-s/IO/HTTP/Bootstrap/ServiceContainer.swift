import Foundation
import Vapor
import SQLKit

/// Container de dependências que conecta a camada HTTP aos use cases da Application.
struct ServiceContainer: Sendable {
    let db: any SQLDatabase
    let registerPatient: RegisterPatientCommandHandler
    let addFamilyMember: AddFamilyMemberCommandHandler
    let removeFamilyMember: RemoveFamilyMemberCommandHandler
    let assignPrimaryCaregiver: AssignPrimaryCaregiverCommandHandler
    let updateSocialIdentity: UpdateSocialIdentityCommandHandler
    let updateHousingCondition: UpdateHousingConditionCommandHandler
    let updateSocioEconomicSituation: UpdateSocioEconomicSituationCommandHandler
    let updateWorkAndIncome: UpdateWorkAndIncomeCommandHandler
    let updateEducationalStatus: UpdateEducationalStatusCommandHandler
    let updateHealthStatus: UpdateHealthStatusCommandHandler
    let updateCommunitySupportNetwork: UpdateCommunitySupportNetworkCommandHandler
    let updateSocialHealthSummary: UpdateSocialHealthSummaryCommandHandler
    let updatePlacementHistory: UpdatePlacementHistoryCommandHandler
    let reportRightsViolation: ReportRightsViolationCommandHandler
    let createReferral: CreateReferralCommandHandler
    let registerAppointment: RegisterAppointmentCommandHandler
    let registerIntakeInfo: RegisterIntakeInfoCommandHandler
    let dischargePatient: DischargePatientCommandHandler
    let readmitPatient: ReadmitPatientCommandHandler
    let admitPatient: AdmitPatientCommandHandler
    let withdrawFromWaitlist: WithdrawFromWaitlistCommandHandler
    let listPatients: ListPatientsQueryHandler
    let createLookupItem: CreateLookupItemCommandHandler
    let updateLookupItem: UpdateLookupItemCommandHandler
    let toggleLookupItem: ToggleLookupItemCommandHandler
    let createLookupRequest: CreateLookupRequestCommandHandler
    let approveLookupRequest: ApproveLookupRequestCommandHandler
    let rejectLookupRequest: RejectLookupRequestCommandHandler
    let listLookupRequests: ListLookupRequestsQueryHandler
    let patientRepository: any PatientRepository
    let lookupValidator: any LookupValidating

    init(db: any SQLDatabase, personValidator: (any PersonExistenceValidating)? = nil) {
        self.db = db
        let repository = SQLKitPatientRepository(db: db)
        let lookup = SQLKitLookupRepository(db: db)
        // ADR-024/025 — DUAL-WRITE: handlers de assessment escrevem
        // também no novo agregado.
        let assessmentRepo: any PatientAssessmentRepository = SQLKitPatientAssessmentRepository(db: db)

        self.patientRepository = repository
        self.lookupValidator = lookup

        self.registerPatient = RegisterPatientCommandHandler(
            repository: repository, lookupValidator: lookup,
            personValidator: personValidator
        )
        self.addFamilyMember = AddFamilyMemberCommandHandler(
            patientRepository: repository, lookupValidator: lookup
        )
        self.removeFamilyMember = RemoveFamilyMemberCommandHandler(
            repository: repository
        )
        self.assignPrimaryCaregiver = AssignPrimaryCaregiverCommandHandler(
            repository: repository
        )
        self.updateSocialIdentity = UpdateSocialIdentityCommandHandler(
            repository: repository, lookupValidator: lookup
        )
        self.updateHousingCondition = UpdateHousingConditionCommandHandler(
            repository: repository, assessmentRepository: assessmentRepo
        )
        self.updateSocioEconomicSituation = UpdateSocioEconomicSituationCommandHandler(
            repository: repository, assessmentRepository: assessmentRepo
        )
        self.updateWorkAndIncome = UpdateWorkAndIncomeCommandHandler(
            repository: repository, assessmentRepository: assessmentRepo, lookupValidator: lookup
        )
        self.updateEducationalStatus = UpdateEducationalStatusCommandHandler(
            repository: repository, assessmentRepository: assessmentRepo, lookupValidator: lookup
        )
        self.updateHealthStatus = UpdateHealthStatusCommandHandler(
            repository: repository, assessmentRepository: assessmentRepo, lookupValidator: lookup
        )
        self.updateCommunitySupportNetwork = UpdateCommunitySupportNetworkCommandHandler(
            repository: repository, assessmentRepository: assessmentRepo
        )
        self.updateSocialHealthSummary = UpdateSocialHealthSummaryCommandHandler(
            repository: repository, assessmentRepository: assessmentRepo
        )
        self.updatePlacementHistory = UpdatePlacementHistoryCommandHandler(
            repository: repository
        )
        self.reportRightsViolation = ReportRightsViolationCommandHandler(
            repository: repository
        )
        self.createReferral = CreateReferralCommandHandler(
            repository: repository
        )
        self.registerAppointment = RegisterAppointmentCommandHandler(
            repository: repository
        )
        self.registerIntakeInfo = RegisterIntakeInfoCommandHandler(
            repository: repository, lookupValidator: lookup
        )
        self.dischargePatient = DischargePatientCommandHandler(
            repository: repository
        )
        self.readmitPatient = ReadmitPatientCommandHandler(
            repository: repository
        )
        self.admitPatient = AdmitPatientCommandHandler(
            repository: repository
        )
        self.withdrawFromWaitlist = WithdrawFromWaitlistCommandHandler(
            repository: repository
        )
        self.listPatients = ListPatientsQueryHandler(repository: repository)

        let lookupAdmin = SQLKitLookupAdminRepository(db: db)
        let lookupRequests = SQLKitLookupRequestRepository(db: db)
        self.createLookupItem = CreateLookupItemCommandHandler(repository: lookupAdmin)
        self.updateLookupItem = UpdateLookupItemCommandHandler(repository: lookupAdmin)
        self.toggleLookupItem = ToggleLookupItemCommandHandler(repository: lookupAdmin)
        self.createLookupRequest = CreateLookupRequestCommandHandler(repository: lookupRequests)
        self.approveLookupRequest = ApproveLookupRequestCommandHandler(
            requestRepository: lookupRequests, lookupRepository: lookupAdmin
        )
        self.rejectLookupRequest = RejectLookupRequestCommandHandler(repository: lookupRequests)
        self.listLookupRequests = ListLookupRequestsQueryHandler(repository: lookupRequests)
    }
}

// MARK: - Vapor Storage Key

struct ServiceContainerKey: StorageKey {
    typealias Value = ServiceContainer
}

extension Application {
    var services: ServiceContainer {
        get { self.storage[ServiceContainerKey.self]! }
        set { self.storage[ServiceContainerKey.self] = newValue }
    }
}

extension Request {
    var services: ServiceContainer { self.application.services }
}
