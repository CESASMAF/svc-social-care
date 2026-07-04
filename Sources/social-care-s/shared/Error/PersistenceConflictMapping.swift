import Foundation

/// Helper universal para mapear `PersistenceConflictError.uniqueViolation` em
/// um erro de negócio específico do caso de uso (ADR-010).
///
/// Padrão de uso no `*MapperError.swift`:
///
/// ```swift
/// extension AddFamilyMemberCommandHandler {
///     func mapError(_ error: Error, ...) -> AddFamilyMemberError {
///         if let conflict = error as? PersistenceConflictError,
///            let mapped: AddFamilyMemberError = conflict.mapUniqueViolation({ constraint in
///                switch constraint {
///                case "family_members_pkey":      return .memberAlreadyInFamily
///                case "uq_family_member_per_pid": return .duplicatePersonId
///                default:                          return nil
///                }
///            }) {
///             return mapped
///         }
///         // ... resto do mapping
///     }
///  }
/// ```
///
/// Razão (S-C6 + ADR-010): sem este helper, cada handler reescreve a mesma
/// estrutura `if case .uniqueViolation(let constraint, _) = ...` e 20 dos
/// 21 handlers esquecem. Helper centralizado deixa o padrão idiomático e
/// 1 linha por mapping conhecido.
public extension PersistenceConflictError {
    /// Tenta mapear esta `PersistenceConflictError` em um erro de negócio
    /// específico, baseado no nome do constraint que disparou.
    ///
    /// - Parameter mapping: Closure que recebe o nome do constraint
    ///   (ex: `"idx_patients_cpf_unique"`) e retorna o erro de negócio
    ///   correspondente, ou `nil` se este handler não conhece esse constraint.
    /// - Returns: Erro de negócio mapeado, ou `nil` se:
    ///   1. Esta variante não é `.uniqueViolation` (ex: `.optimisticLockFailed`), OU
    ///   2. O `mapping` retornou `nil` (constraint desconhecido por este handler).
    ///
    /// Quando o retorno é `nil`, o handler tipicamente cai num branch fallback
    /// (`persistenceMappingFailure`) — mas o helper força a decisão a ser
    /// explícita por constraint, não silenciosa.
    func mapUniqueViolation<E: Error>(_ mapping: (String) -> E?) -> E? {
        guard case .uniqueViolation(let constraint, _) = self else { return nil }
        return mapping(constraint)
    }

    /// Variante para `.optimisticLockFailed` (ADR-005). Mesma lógica:
    /// handler decide o erro de negócio com base nos versions detectados.
    func mapOptimisticLockFailed<E: Error>(_ mapping: (_ expected: Int, _ actual: Int) -> E?) -> E? {
        guard case .optimisticLockFailed(let expected, let actual) = self else { return nil }
        return mapping(expected, actual)
    }
}
