import Foundation

extension DischargePatientCommandHandler {
    /// Mapeia erros de domínio para o erro específico do Caso de Uso.
    /// Erros não reconhecidos são propagados sem mascaramento.
    public func mapError(_ error: Error, patientId: String) -> any Error {
        if error is DischargePatientError { return error }

        // ADR-010: PersistenceConflictError universal — propaga sem mascarar
        // (handler de discharge não tem unique constraint próprio).
        if error is PersistenceConflictError { return error }

        if let e = error as? PatientError {
            switch e {
            case .alreadyDischarged:
                return DischargePatientError.alreadyDischarged(patientId)
            case .cannotDischargeWaitlisted:
                return DischargePatientError.cannotDischargeWaitlisted(patientId)
            default:
                return error
            }
        }

        if let e = error as? DischargeInfoError {
            switch e {
            case .notesRequiredWhenReasonIsOther:
                return DischargePatientError.notesRequiredForOtherReason
            case .notesExceedMaxLength(let length):
                return DischargePatientError.notesExceedMaxLength(length)
            }
        }

        if error is PatientIdError {
            return DischargePatientError.invalidPatientIdFormat(patientId)
        }

        return error
    }
}
