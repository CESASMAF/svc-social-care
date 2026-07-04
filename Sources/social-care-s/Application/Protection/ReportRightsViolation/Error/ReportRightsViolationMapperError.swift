import Foundation

extension ReportRightsViolationCommandHandler {
    /// Mapeia erros genéricos ou de domínio para o erro específico do Caso de Uso.
    public func mapError(_ error: Error, patientId: String? = nil) -> ReportRightsViolationError {
        if let e = error as? ReportRightsViolationError {
            return e
        }

        // ADR-010: PersistenceConflictError universal — fallback preserva detail.
        if let conflict = error as? PersistenceConflictError {
            return .persistenceMappingFailure(issues: [String(describing: conflict)])
        }

        if let e = error as? PatientError {
            switch e {
            case .violationTargetOutsideBoundary(let targetId):
                return .targetOutsideBoundary(targetId)
            case .patientIsWaitlisted:
                return .patientNotActive(reason: "PATIENT_IS_WAITLISTED")
            case .patientIsDischarged:
                return .patientNotActive(reason: "PATIENT_IS_DISCHARGED")
            default:
                return .persistenceMappingFailure(issues: [String(describing: e)])
            }
        }

        if let e = error as? RightsViolationReportError {
            switch e {
            case .reportDateInFuture:
                return .reportDateInFuture
            case .incidentAfterReport:
                return .incidentAfterReport
            case .emptyDescription:
                return .emptyDescription
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
        
        if let e = error as? ViolationReportIdError {
            switch e {
            case .invalidFormat(let value):
                return .invalidViolationReportIdFormat(value)
            }
        }
        
        return .persistenceMappingFailure(issues: [String(describing: error)])
    }
}
