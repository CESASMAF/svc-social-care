import Foundation

/// Erros do use case AnonymizePatientPII.
///
/// `patientNotFound` e "já anonimizado" NÃO são erros — são no-ops idempotentes
/// (o evento pode chegar para um `personId` sem prontuário correlato, ou ser
/// reentregue at-least-once).
public enum AnonymizePatientPIIError: Error, Sendable {
    case invalidPersonId(String)
}
