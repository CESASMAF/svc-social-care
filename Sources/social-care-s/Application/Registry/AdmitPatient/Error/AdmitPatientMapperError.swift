import Foundation

extension AdmitPatientCommandHandler {
    /// Mapeia erros de domínio para o erro específico do Caso de Uso.
    /// Erros não reconhecidos são propagados sem mascaramento.
    public func mapError(_ error: Error, patientId: String) -> any Error {
        if error is AdmitPatientError { return error }
        // ADR-010: PersistenceConflictError propagado sem mascarar (handler lifecycle).
        if error is PersistenceConflictError { return error }

        if let e = error as? PatientError {
            switch e {
            case .alreadyActive:
                return AdmitPatientError.alreadyActive(patientId)
            case .cannotAdmitDischarged:
                return AdmitPatientError.cannotAdmitDischarged(patientId)
            default:
                return error
            }
        }

        if error is PatientIdError {
            return AdmitPatientError.invalidPatientIdFormat(patientId)
        }

        return error
    }
}
