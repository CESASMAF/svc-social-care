import Foundation

extension RemoveFamilyMemberCommandHandler {
    /// Mapeia erros genéricos ou de domínio para o erro específico do Caso de Uso.
    public func mapError(_ error: Error, patientId: String? = nil) -> RemoveFamilyMemberError {
        if let e = error as? RemoveFamilyMemberError {
            return e
        }

        // ADR-010: PersistenceConflictError universal — fallback preserva detail.
        if let conflict = error as? PersistenceConflictError {
            return .persistenceMappingFailure(issues: [String(describing: conflict)])
        }

        if let e = error as? PatientError {
            switch e {
            case .familyMemberNotFound(let personId):
                return .familyMemberNotFound(personId: personId)
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
