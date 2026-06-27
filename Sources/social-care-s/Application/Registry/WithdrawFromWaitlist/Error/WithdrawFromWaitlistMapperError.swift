import Foundation

extension WithdrawFromWaitlistCommandHandler {
    /// Mapeia erros de domínio para o erro específico do Caso de Uso.
    /// Erros não reconhecidos são propagados sem mascaramento.
    public func mapError(_ error: Error, patientId: String) -> any Error {
        if error is WithdrawFromWaitlistError { return error }
        // ADR-010: PersistenceConflictError propagado sem mascarar (handler lifecycle).
        if error is PersistenceConflictError { return error }

        if let e = error as? PatientError {
            switch e {
            case .alreadyDischarged:
                return WithdrawFromWaitlistError.alreadyDischarged(patientId)
            case .alreadyActive:
                return WithdrawFromWaitlistError.patientIsActive(patientId)
            default:
                return error
            }
        }

        if let e = error as? WithdrawInfoError {
            switch e {
            case .notesRequiredWhenReasonIsOther:
                return WithdrawFromWaitlistError.notesRequiredForOtherReason
            case .notesExceedMaxLength(let length):
                return WithdrawFromWaitlistError.notesExceedMaxLength(length)
            }
        }

        if error is PatientIdError {
            return WithdrawFromWaitlistError.invalidPatientIdFormat(patientId)
        }

        return error
    }
}
