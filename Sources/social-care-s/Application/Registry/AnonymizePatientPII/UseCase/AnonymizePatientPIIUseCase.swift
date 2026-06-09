import Foundation

/// Contrato do use case que anonimiza a PII direta de um `Patient` (erasure
/// LGPD — ADR-039).
public protocol AnonymizePatientPIIUseCase: CommandHandling where C == AnonymizePatientPIICommand {}
