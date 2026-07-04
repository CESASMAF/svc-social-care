import Foundation

/// Resultado da consulta ao people-context para um `PersonId` (ADR-011).
///
/// Tri-state explícito substitui o `Bool` pré-ADR-011 que fazia fail-open:
/// qualquer erro de upstream (timeout, 5xx, DNS) virava `true` silenciosamente,
/// permitindo registrar paciente com personId não-verificado.
///
/// Em healthcare/social-care esse fail-open era classificado como CRITICAL
/// (S-C1) — atacante derrubava o people-context e cadastrava personId
/// arbitrário sem rastro de segurança.
///
/// Tri-state força o handler a decidir explicitamente:
/// - `.exists` ⇒ prosseguir com registro
/// - `.notFound` ⇒ erro de negócio "pessoa não cadastrada" (HTTP 404)
/// - `.unknown(reason:)` ⇒ erro de negócio "validação indisponível" (HTTP 503)
public enum PersonExistence: Sendable, Equatable {
    case exists
    case notFound
    case unknown(reason: String)
}

/// Port for validating that a PersonId exists in the people-context service.
///
/// Injected into `RegisterPatientCommandHandler` (optional). Implementação
/// concreta em `IO/PeopleContext/PeopleContextPersonValidator`.
///
/// O método é **não-throws** porque o tri-state cobre todos os caminhos —
/// "erro de rede" vira `.unknown(reason:)`, não `throw`. Isso elimina o
/// padrão de `catch { return true }` que era a raiz do fail-open.
///
/// O parâmetro `bearer` permite Bearer forwarding (ADR-023): handlers que
/// vêm de request HTTP autenticado passam o JWT do usuário; handler que
/// roda em contexto não-autenticado (cron, integração) passa `nil`.
public protocol PersonExistenceValidating: Sendable {
    /// Consulta o people-context para verificar a existência de `personId`.
    ///
    /// - Parameters:
    ///   - personId: ID a verificar.
    ///   - bearer: JWT do request original (ADR-023). Pode ser `nil` em
    ///     contextos não-autenticados.
    /// - Returns: `PersonExistence` tri-state explícito. Nunca lança.
    func validate(personId: PersonId, bearer: String?) async -> PersonExistence
}
