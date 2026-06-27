import Foundation

/// Erro genérico lançado por repositórios quando uma constraint de banco é violada.
///
/// Permite que a camada de Application mapeie para o erro específico do caso de
/// uso sem que o repositório conheça erros de negócio.
///
/// Variantes:
/// - `uniqueViolation`: PostgreSQL SQLSTATE 23505. Handler mapeia para erro de
///   negócio contextualizado (ex: `personIdAlreadyRegistered`, HTTP 409).
/// - `optimisticLockFailed`: detectado quando o save tenta atualizar um agregado
///   cuja versão no banco não bate com a esperada (outra transação venceu a
///   corrida entre `find` e `save`). Handler deve mapear para HTTP 409 com
///   hint para o cliente "re-fetch and retry" (ADR-005).
public enum PersistenceConflictError: Error, Sendable {
    case uniqueViolation(constraint: String, detail: String?)

    /// O save tentou atualizar um agregado em `expectedVersion` mas o banco
    /// já estava em `actualVersion`.
    ///
    /// - Parameters:
    ///   - expectedVersion: versão do agregado no banco que o save esperava
    ///     encontrar (geralmente `aggregate.version - 1`).
    ///   - actualVersion: versão real do agregado no banco no momento do save.
    case optimisticLockFailed(expectedVersion: Int, actualVersion: Int)
}

/// Erro lançado por mappers quando dados persistidos estão em estado inconsistente.
/// Indica corrupção ou evolução de schema sem migração.
public enum PersistenceDataIntegrityError: Error, Sendable {
    case invalidEnumValue(column: String, value: String, expected: String)
}
