import Foundation

/// Command para anonimizar (erasure LGPD) a PII direta de um `Patient`.
///
/// Disparado ao consumir `people.person.deleted` do people-context (eliminação a
/// pedido do titular, LGPD Art. 18). Carrega apenas identificadores de correlação
/// — sem PII. Ver ADR-039.
public struct AnonymizePatientPIICommand: Command, Sendable {
    /// O `PersonId` canônico cujo titular foi eliminado no people-context.
    public let personId: String

    /// Ator que originou a eliminação (propagado do evento; geralmente o
    /// `superadmin` que executou o erasure no people-context).
    public let actorId: String

    public init(personId: String, actorId: String) {
        self.personId = personId
        self.actorId = actorId
    }
}
