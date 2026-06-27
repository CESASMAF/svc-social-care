import Foundation

extension AddFamilyMemberCommandHandler {
    /// Mapeia erros genéricos ou de domínio para o erro específico do Caso de Uso.
    public func mapError(_ error: Error, patientId: String? = nil) -> AddFamilyMemberError {
        if let e = error as? AddFamilyMemberError {
            return e
        }

        // ADR-010: PersistenceConflictError tratado universalmente.
        // family_members_pkey (PK composta após ADR-006) → memberAlreadyExists.
        if let conflict = error as? PersistenceConflictError {
            if let mapped: AddFamilyMemberError = conflict.mapUniqueViolation({ constraint in
                switch constraint {
                case "family_members_pkey": return .memberAlreadyExists("(unknown)")
                default: return nil
                }
            }) {
                return mapped
            }
            return .persistenceMappingFailure(patientId: patientId, issues: [String(describing: conflict)], issueCount: 1)
        }

        if error is PatientIdError {
            return .invalidPersonIdFormat
        }

        if error is PIDError {
            return .invalidPersonIdFormat
        }

        if let e = error as? PatientError {
            switch e {
            case .patientIsWaitlisted:
                return .patientNotActive(reason: "PATIENT_IS_WAITLISTED")
            case .patientIsDischarged:
                return .patientNotActive(reason: "PATIENT_IS_DISCHARGED")
            case .familyMemberAlreadyExists(let memberId):
                return .memberAlreadyExists(memberId)
            default:
                return .persistenceMappingFailure(patientId: patientId, issues: [String(describing: e)], issueCount: 1)
            }
        }

        return .persistenceMappingFailure(
            patientId: patientId,
            issues: [String(describing: error)],
            issueCount: 1
        )
    }
}
