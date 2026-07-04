import Foundation

extension UpdateSocialIdentityCommandHandler {
    public func mapError(_ error: Error, patientId: String? = nil) -> UpdateSocialIdentityError {
        if let e = error as? UpdateSocialIdentityError { return e }
        // ADR-010: PersistenceConflictError universal — fallback preserva detail.
        if let conflict = error as? PersistenceConflictError {
            return .persistenceMappingFailure(issues: [String(describing: conflict)])
        }

        if let e = error as? SocialIdentityError {
            switch e {
            case .indigenousInVillageMissingDescription:
                return .indigenousInVillageMissingDescription
            case .indigenousOutsideVillageMissingDescription:
                return .indigenousOutsideVillageMissingDescription
            case .descriptionRequiredForOtherType:
                return .descriptionRequiredForOtherType
            }
        }

        if let e = error as? PatientError {
            switch e {
            case .patientIsWaitlisted:
                return .patientNotActive(reason: "PATIENT_IS_WAITLISTED")
            case .patientIsDischarged:
                return .patientNotActive(reason: "PATIENT_IS_DISCHARGED")
            default:
                return .persistenceMappingFailure(issues: [String(describing: e)])
            }
        }

        if let e = error as? PIDError {
            switch e {
            case .invalidFormat(let value):
                return .invalidPersonIdFormat(value)
            }
        }

        return .persistenceMappingFailure(issues: [String(describing: error)])
    }
}
