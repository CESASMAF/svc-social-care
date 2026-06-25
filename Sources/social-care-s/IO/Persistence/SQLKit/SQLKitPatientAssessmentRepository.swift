import Foundation
import PostgresNIO
import SQLKit

/// Implementação SQLKit do `PatientAssessmentRepository` (ADR-024).
///
/// **Status: Fase 4 EXPAND.**
///
/// - `save(_:)`: implementa optimistic lock (ADR-005), upsert via
///   ON CONFLICT (patient_id) DO UPDATE (PK natural, alinhado com
///   ADR-021 sobre `family_members`). Outbox segue ADR-014/ADR-022.
/// - `find(byPatientId:)`: SELECT direto. Decodifica módulos JSONB via
///   `JSONCodec.decoder` (ADR-022).
///
/// **Limitação atual (expand stage):** módulos JSONB armazenados aqui
/// ficam NULL até o dual-write entrar em produção. Quando handlers
/// migrarem (próximo PR), eles começam a preencher os campos. Até lá,
/// `find(byPatientId:)` retorna agregado vazio quando a row existe (do
/// backfill) — útil para validar a infra de save sem mexer no fluxo
/// existente.
///
/// **TODO (próximo sub-PR — dual-write):**
/// - Implementar serialização/deserialização real de cada módulo JSONB.
/// - Bind via SQL raw com cast `::jsonb` (ADR-022).
struct SQLKitPatientAssessmentRepository: PatientAssessmentRepository {
    private let db: any SQLDatabase

    init(db: any SQLDatabase) {
        self.db = db
    }

    func save(_ assessment: PatientAssessment) async throws {
        let patientId = UUID(uuidString: assessment.patientId.description)!
        let outboxMessages = try PatientDatabaseMapper.toOutbox(assessment.uncommittedEvents)

        do {
            try await db.transaction { tx in
                // 1. Optimistic lock (ADR-005). Mesma lógica de
                //    SQLKitPatientRepository.save: SELECT version FOR UPDATE
                //    serializa transações concorrentes; CREATE vs UPDATE
                //    explícito.
                let currentVersion: Int? = try await tx.raw("""
                    SELECT version FROM patient_assessments WHERE patient_id = \(bind: patientId) FOR UPDATE
                """).first()?.decode(column: "version", as: Int.self)

                if let dbVersion = currentVersion {
                    let expected = assessment.version - 1
                    guard dbVersion == expected else {
                        throw PersistenceConflictError.optimisticLockFailed(
                            expectedVersion: expected,
                            actualVersion: dbVersion
                        )
                    }
                    try await tx.raw("""
                        UPDATE patient_assessments
                           SET version = \(bind: assessment.version)
                         WHERE patient_id = \(bind: patientId)
                    """).run()
                } else {
                    try await tx.raw("""
                        INSERT INTO patient_assessments (patient_id, version)
                        VALUES (\(bind: patientId), \(bind: assessment.version))
                    """).run()
                }

                // 2. Outbox events na MESMA transação (ADR-014 + ADR-022).
                //    Cast `::jsonb` explícito porque PostgresKit envia
                //    String mas a coluna é JSONB.
                for message in outboxMessages {
                    try await tx.raw("""
                        INSERT INTO outbox_messages (id, event_type, payload, occurred_at, processed_at)
                        VALUES (\(bind: message.id), \(bind: message.event_type), \(bind: message.payload)::jsonb, \(bind: message.occurred_at), \(bind: message.processed_at))
                    """).run()
                }
            }
        } catch let error as PSQLError where error.code == .server {
            // ADR-010: PSQLError 23505 → PersistenceConflictError.uniqueViolation.
            if let sqlState = error.serverInfo?[.sqlState], sqlState == "23505",
               let constraint = error.serverInfo?[.constraintName] {
                throw PersistenceConflictError.uniqueViolation(
                    constraint: constraint,
                    detail: error.serverInfo?[.detail]
                )
            }
            throw error
        }
    }

    /// ADR-025 — escrita secundária da fase DUAL-WRITE. Faz INSERT ...
    /// ON CONFLICT (patient_id) DO UPDATE SET com todos os 7 módulos
    /// JSONB. Sem optimistic lock (handlers de assessment continuam
    /// usando `PatientRepository.save` como escrita primária com lock).
    /// Eventos NÃO são gravados aqui — saem via `PatientRepository.save`
    /// como sempre.
    func dualWriteUpsert(_ assessment: PatientAssessment) async throws {
        let patientId = UUID(uuidString: assessment.patientId.description)!

        // Serializa cada módulo via JSONCodec (ADR-022). `nil` vira NULL
        // no banco — coluna JSONB aceita.
        let encoder = JSONCodec.encoder
        func jsonString<T: Encodable>(_ value: T?) throws -> String? {
            guard let value = value else { return nil }
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8)
        }

        let hcJson = try jsonString(assessment.housingCondition)
        let sesJson = try jsonString(assessment.socioeconomicSituation)
        let waiJson = try jsonString(assessment.workAndIncome)
        let esJson = try jsonString(assessment.educationalStatus)
        let hsJson = try jsonString(assessment.healthStatus)
        let csnJson = try jsonString(assessment.communitySupportNetwork)
        let shsJson = try jsonString(assessment.socialHealthSummary)

        do {
            // INSERT ... ON CONFLICT (patient_id) DO UPDATE.
            // Cast `::jsonb` no bind explícito (ADR-022) — PostgresKit
            // envia String, coluna espera JSONB. Para colunas que podem
            // ser NULL, usar `::jsonb` ainda funciona (NULL passa por
            // qualquer cast).
            try await db.raw("""
                INSERT INTO patient_assessments (
                    patient_id, version,
                    housing_condition, socioeconomic_situation, work_and_income,
                    educational_status, health_status, community_support_network,
                    social_health_summary
                ) VALUES (
                    \(bind: patientId), \(bind: assessment.version),
                    \(bind: hcJson)::jsonb, \(bind: sesJson)::jsonb, \(bind: waiJson)::jsonb,
                    \(bind: esJson)::jsonb, \(bind: hsJson)::jsonb, \(bind: csnJson)::jsonb,
                    \(bind: shsJson)::jsonb
                )
                ON CONFLICT (patient_id) DO UPDATE SET
                    version                   = excluded.version,
                    housing_condition         = excluded.housing_condition,
                    socioeconomic_situation   = excluded.socioeconomic_situation,
                    work_and_income           = excluded.work_and_income,
                    educational_status        = excluded.educational_status,
                    health_status             = excluded.health_status,
                    community_support_network = excluded.community_support_network,
                    social_health_summary     = excluded.social_health_summary
            """).run()
        } catch let error as PSQLError where error.code == .server {
            if let sqlState = error.serverInfo?[.sqlState], sqlState == "23505",
               let constraint = error.serverInfo?[.constraintName] {
                throw PersistenceConflictError.uniqueViolation(
                    constraint: constraint,
                    detail: error.serverInfo?[.detail]
                )
            }
            throw error
        }
    }

    func find(byPatientId patientId: PatientId) async throws -> PatientAssessment? {
        let uuid = UUID(uuidString: patientId.description)!

        struct AssessmentRow: Codable {
            let patient_id: UUID
            let version: Int
        }

        guard let row = try await db.select()
            .column("patient_id")
            .column("version")
            .from("patient_assessments")
            .where("patient_id", .equal, uuid)
            .first(decoding: AssessmentRow.self) else { return nil }

        // Reconstrução mínima — módulos ficam NULL até o dual-write entrar.
        // Quando handlers migrarem, este método decodifica os JSONB.
        return PatientAssessment(
            patientId: try PatientId(row.patient_id.uuidString),
            version: row.version
        )
    }
}
