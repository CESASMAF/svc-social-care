import Foundation

/// Porta de persistência do agregado `PatientAssessment` (ADR-024).
///
/// Mantém invariante de Outbox Pattern (ADR-014): `save(_:)` escreve
/// agregado + `uncommittedEvents` na **mesma transação** — a única porta
/// de publicação de eventos do BC Assessment.
///
/// Repositório é **independente** de `PatientRepository`. Operações
/// cross-aggregate (criar `Patient` + `PatientAssessment` no mesmo
/// fluxo) são responsabilidade da Application via order-of-operations
/// explícito (UoW cross-aggregate é Phase 5 — T-031).
public protocol PatientAssessmentRepository: Sendable {

    /// Salva ou atualiza o agregado inteiro. Inclui optimistic lock
    /// (ADR-005) e persistência atômica de eventos (ADR-014).
    ///
    /// - Throws: `PersistenceConflictError.optimisticLockFailed` se
    ///   `version` divergir do banco;
    ///   `PersistenceConflictError.uniqueViolation` em violação de
    ///   constraint.
    func save(_ assessment: PatientAssessment) async throws

    /// Recupera o agregado pelo ID do paciente. Retorna `nil` se ainda
    /// não há row (paciente sem nenhum módulo preenchido).
    ///
    /// **Nota (Fase 4 EXPAND):** durante o período expand-contract,
    /// pacientes que existem em `patients` mas que nunca tiveram nenhum
    /// módulo preenchido NÃO terão row em `patient_assessments`.
    /// Backfill da migration popula apenas pacientes com algum módulo
    /// não-nulo.
    func find(byPatientId patientId: PatientId) async throws -> PatientAssessment?

    /// **Estágio (b) DUAL-WRITE da decomposição (ADR-024 + ADR-025).**
    ///
    /// Persiste/atualiza o agregado **sem optimistic lock**. Usado
    /// pelos handlers de assessment durante a fase de transição quando
    /// estado real ainda vive em `Patient.<modulo>?` (escrita primária)
    /// + `PatientAssessment` (escrita secundária para validar a infra
    /// nova).
    ///
    /// Implementação típica: `INSERT ... ON CONFLICT (patient_id) DO
    /// UPDATE SET <todas colunas JSONB> = excluded.<...>`.
    ///
    /// **Eventos NÃO são persistidos** por este método (`save(_:)`
    /// continua sendo a porta de outbox quando handlers migrarem
    /// completamente para o novo repo no CUTOVER). Eventos do agregado
    /// `Patient` ainda saem pelo outbox via `PatientRepository.save`.
    ///
    /// Será **deprecado e removido** quando T-024.a chegar ao CUTOVER
    /// + CONTRACT (release N+3).
    func dualWriteUpsert(_ assessment: PatientAssessment) async throws
}
