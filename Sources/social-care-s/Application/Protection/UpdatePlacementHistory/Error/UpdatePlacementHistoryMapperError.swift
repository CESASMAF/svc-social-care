import Foundation

extension UpdatePlacementHistoryCommandHandler {
    public func mapError(_ error: Error) -> UpdatePlacementHistoryError {
        if let e = error as? UpdatePlacementHistoryError { return e }

        // ADR-010: PersistenceConflictError universal — fallback preserva detail.
        if let conflict = error as? PersistenceConflictError {
            return .persistenceMappingFailure(issues: [String(describing: conflict)])
        }

        if let e = error as? PatientError {
            switch e {
            case .incompatiblePlacementSituation, .incompatibleGuardianshipSituation:
                return .incompatibleSeparationSituation
            case .patientIsWaitlisted:
                return .patientNotActive(reason: "PATIENT_IS_WAITLISTED")
            case .patientIsDischarged:
                return .patientNotActive(reason: "PATIENT_IS_DISCHARGED")
            default:
                return .persistenceMappingFailure(issues: [String(describing: e)])
            }
        }

        if let e = error as? PlacementError {
            switch e {
            case .invalidDateRange:
                return .invalidDateRange(memberId: "unknown")
            }
        }
        
        if let e = error as? PIDError {
            switch e {
            case .invalidFormat(let value):
                return .persistenceMappingFailure(issues: ["Invalid PID format: \(value)"])
            }
        }
        
        return .persistenceMappingFailure(issues: [String(describing: error)])
    }
}
