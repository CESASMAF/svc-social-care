import Foundation

public actor UpdateCommunitySupportNetworkCommandHandler: UpdateCommunitySupportNetworkUseCase {
    private let repository: any PatientRepository
    private let assessmentRepository: any PatientAssessmentRepository

    public init(
        repository: any PatientRepository,
        assessmentRepository: any PatientAssessmentRepository
    ) {
        self.repository = repository
        self.assessmentRepository = assessmentRepository
    }

    public func handle(_ command: UpdateCommunitySupportNetworkCommand) async throws {
        do {
            let patientId = try PatientId(command.patientId)

            let network = try CommunitySupportNetwork(
                hasRelativeSupport: command.hasRelativeSupport,
                hasNeighborSupport: command.hasNeighborSupport,
                familyConflicts: command.familyConflicts,
                patientParticipatesInGroups: command.patientParticipatesInGroups,
                familyParticipatesInGroups: command.familyParticipatesInGroups,
                patientHasAccessToLeisure: command.patientHasAccessToLeisure,
                facesDiscrimination: command.facesDiscrimination
            )

            guard var patient = try await repository.find(byId: patientId) else {
                throw UpdateCommunitySupportNetworkError.patientNotFound
            }

            try patient.updateCommunitySupportNetwork(network, actorId: command.actorId)

            try await repository.save(patient)
            // ADR-025 DUAL-WRITE.
            try await assessmentRepository.dualWriteUpsert(PatientAssessmentBuilder.from(patient))
        } catch {
            throw mapError(error)
        }
    }

    private func mapError(_ error: Error) -> UpdateCommunitySupportNetworkError {
        if let e = error as? UpdateCommunitySupportNetworkError { return e }
        if let e = error as? CommunitySupportNetworkError {
            switch e {
            case .familyConflictsWhitespace: return .familyConflictsWhitespace
            case .familyConflictsTooLong(let limit): return .familyConflictsTooLong(limit: limit)
            }
        }
        if let e = error as? PatientError {
            switch e {
            case .patientIsWaitlisted:
                return .patientNotActive(reason: "PATIENT_IS_WAITLISTED")
            case .patientIsDischarged:
                return .patientNotActive(reason: "PATIENT_IS_DISCHARGED")
            default:
                return .unexpectedFailure(String(describing: e))
            }
        }
        if let e = error as? PatientIdError {
            switch e { case .invalidFormat(let v): return .invalidPersonIdFormat(v) }
        }
        if let e = error as? PIDError {
            switch e { case .invalidFormat(let v): return .invalidPersonIdFormat(v) }
        }
        return .unexpectedFailure(String(describing: error))
    }
}
