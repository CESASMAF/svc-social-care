import Foundation

extension UpdateHousingConditionCommandHandler {
    /// Mapeia erros genéricos ou de domínio para o erro específico do Caso de Uso.
    public func mapError(_ error: Error, patientId: String? = nil) -> UpdateHousingConditionError {
        if let e = error as? UpdateHousingConditionError {
            return e
        }

        // ADR-010: PersistenceConflictError universal — fallback preserva detail.
        if let conflict = error as? PersistenceConflictError {
            return .persistenceMappingFailure(issues: [String(describing: conflict)])
        }

        if let e = error as? HousingConditionError {
            switch e {
            case .negativeRooms: return .negativeRooms
            case .negativeBedrooms: return .negativeBedrooms
            case .negativeBathrooms: return .negativeBathrooms
            case .bedroomsExceedRooms: return .bedroomsExceedRooms
            case .bathroomsExceedRooms: return .bathroomsExceedRooms
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

        if let e = error as? PatientIdError {
            switch e {
            case .invalidFormat(let value):
                return .invalidPersonIdFormat(value)
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
