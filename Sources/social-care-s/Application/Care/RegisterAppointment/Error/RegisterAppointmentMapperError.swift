import Foundation

extension RegisterAppointmentCommandHandler {
    /// Mapeia erros genéricos ou de domínio para o erro específico do Caso de Uso.
    public func mapError(_ error: Error, patientId: String? = nil) -> RegisterAppointmentError {
        if let e = error as? RegisterAppointmentError {
            return e
        }

        // ADR-010: PersistenceConflictError universal — fallback preserva detail.
        if let conflict = error as? PersistenceConflictError {
            return .persistenceMappingFailure(issues: [String(describing: conflict)])
        }

        if let e = error as? SocialCareAppointmentError {
            switch e {
            case .dateInFuture:
                return .dateInFuture
            case .invalidType(let received, let expected):
                return .invalidType(received: received, expected: expected)
            case .missingNarrative:
                return .missingNarrative
            case .summaryTooLong(let limit):
                return .summaryTooLong(limit: limit)
            case .actionPlanTooLong(let limit):
                return .actionPlanTooLong(limit: limit)
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
        
        if let e = error as? ProfessionalIdError {
            switch e {
            case .invalidFormat(let value):
                return .invalidProfessionalIdFormat(value)
            }
        }
        
        return .persistenceMappingFailure(issues: [String(describing: error)])
    }
}
