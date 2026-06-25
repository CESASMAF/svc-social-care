import Foundation
@testable import social_care_s

/// Test double do `PatientAssessmentRepository` (ADR-024 / ADR-025).
///
/// Espelha os invariantes do `SQLKitPatientAssessmentRepository`:
/// - `save(_:)`: optimistic lock por `patientId.version`.
/// - `dualWriteUpsert(_:)`: idempotente, sem lock.
/// - `find(byPatientId:)`: retorna o último estado salvo (ou nil).
///
/// Mantém histórico de chamadas para asserts em testes:
/// - `dualWriteCalls`: lista ordenada de assessments enviados ao
///   `dualWriteUpsert`. Permite `#expect(repo.dualWriteCalls.count == 1)`
///   após handler de assessment rodar.
actor InMemoryPatientAssessmentRepository: PatientAssessmentRepository {

    private var store: [PatientId: PatientAssessment] = [:]
    private(set) var dualWriteCalls: [PatientAssessment] = []

    func save(_ assessment: PatientAssessment) async throws {
        // Optimistic lock simulado: se já existe, version do incoming
        // deve ser exactly existing.version + 1.
        if let existing = store[assessment.patientId] {
            let expected = assessment.version - 1
            guard existing.version == expected else {
                throw PersistenceConflictError.optimisticLockFailed(
                    expectedVersion: expected,
                    actualVersion: existing.version
                )
            }
        }
        store[assessment.patientId] = assessment
    }

    func find(byPatientId patientId: PatientId) async throws -> PatientAssessment? {
        store[patientId]
    }

    func dualWriteUpsert(_ assessment: PatientAssessment) async throws {
        // Idempotente; sem lock.
        store[assessment.patientId] = assessment
        dualWriteCalls.append(assessment)
    }
}
