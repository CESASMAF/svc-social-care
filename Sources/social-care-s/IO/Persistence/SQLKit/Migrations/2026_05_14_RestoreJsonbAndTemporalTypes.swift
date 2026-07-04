import Foundation
import SQLKit

/// Restaura tipos corretos no schema (ADR-022):
///
/// 1. **`outbox_messages.payload`** e **`audit_trail.payload`** voltam a ser
///    JSONB. Foram demoted para TEXT em `ConvertJsonbToText` (2026-03-13)
///    para contornar mismatch de bind do PostgresKit (`.model()` envia String).
///    O fix correto é cast `::jsonb` explícito no INSERT — implementado em
///    `SQLKitPatientRepository` neste mesmo ticket.
///
/// 2. **Colunas operacionais** (instante de evento) são promovidas
///    `TIMESTAMP` → `TIMESTAMPTZ`. Em PostgreSQL, `TIMESTAMP` (sem TZ)
///    armazena o valor literal sem informação de zona — torna-se ambíguo
///    em deploy multi-região e em migração entre staging/prod com TZ
///    diferentes. `TIMESTAMPTZ` armazena UTC internamente e converte na
///    apresentação.
///
/// 3. **Colunas conceituais** (data sem hora) são demovidas `TIMESTAMP` →
///    `DATE`. `birth_date`, `rg_issue_date`, `patient_diagnoses.date` são
///    datas — não instantes. Schema explicita o invariante.
///
/// ## Estratégia de conversão
///
/// - `TIMESTAMP → TIMESTAMPTZ`: `USING <col> AT TIME ZONE 'UTC'`. Decisão
///   conservadora — assume valores antigos foram gravados em UTC. Se
///   algum deploy gravou em BRT (raro), valor desloca em ±3h. Pré-prod
///   não tem dados sensíveis a esse delta.
/// - `TIMESTAMP → DATE`: `USING <col>::date` — descarta a parte de hora
///   (sempre era `00:00:00` espúrio).
/// - `TEXT → JSONB`: `USING <col>::jsonb` — parse JSON; falha alta se
///   row legacy não for JSON válido (por design, não silencia).
///
/// ## Trade-off: drop em mesma migration vs expand-contract
///
/// Esta migration faz alterações in-place (não expand-contract) por:
/// - Volume baixo dev/staging.
/// - Conversão é compatível: TIMESTAMPTZ pode receber TIMESTAMP via cast
///   (drop reverte se preciso).
/// - Único consumidor é o app, que migra junto no mesmo deploy.
/// - `revert()` simétrico restaura tipos antigos.
///
/// Para volume produção, executar em duas migrations
/// (ALTER NULLABLE + backfill + ALTER NOT NULL) caso o ALTER bloqueie
/// reads. PostgreSQL ALTER COLUMN TYPE adquire ACCESS EXCLUSIVE lock —
/// para tabelas ativas, considerar pg_repack ou shadow column.
///
/// Ticket: T-022. ADR: ADR-022.
struct RestoreJsonbAndTemporalTypes: Migration {
    let name = "2026_05_14_RestoreJsonbAndTemporalTypes"

    func prepare(on db: any SQLDatabase) async throws {
        // PASSO 1 — Payload JSONB (DB-9).
        try await db.raw("""
            ALTER TABLE outbox_messages
            ALTER COLUMN payload TYPE JSONB USING payload::jsonb
        """).run()
        try await db.raw("""
            ALTER TABLE audit_trail
            ALTER COLUMN payload TYPE JSONB USING payload::jsonb
        """).run()

        // PASSO 2 — Operacionais TIMESTAMPTZ (DB-10).
        // social_care_appointments.date — instante do atendimento.
        try await db.raw("""
            ALTER TABLE social_care_appointments
            ALTER COLUMN date TYPE TIMESTAMPTZ USING date AT TIME ZONE 'UTC'
        """).run()
        // referrals.date — instante do encaminhamento.
        try await db.raw("""
            ALTER TABLE referrals
            ALTER COLUMN date TYPE TIMESTAMPTZ USING date AT TIME ZONE 'UTC'
        """).run()
        // rights_violation_reports — instantes (relatório e incidente).
        try await db.raw("""
            ALTER TABLE rights_violation_reports
            ALTER COLUMN report_date TYPE TIMESTAMPTZ USING report_date AT TIME ZONE 'UTC'
        """).run()
        try await db.raw("""
            ALTER TABLE rights_violation_reports
            ALTER COLUMN incident_date TYPE TIMESTAMPTZ USING incident_date AT TIME ZONE 'UTC'
        """).run()
        // outbox_messages.occurred_at + processed_at — instantes do evento.
        try await db.raw("""
            ALTER TABLE outbox_messages
            ALTER COLUMN occurred_at TYPE TIMESTAMPTZ USING occurred_at AT TIME ZONE 'UTC'
        """).run()
        try await db.raw("""
            ALTER TABLE outbox_messages
            ALTER COLUMN processed_at TYPE TIMESTAMPTZ USING processed_at AT TIME ZONE 'UTC'
        """).run()

        // PASSO 3 — Conceituais DATE (DB-16).
        try await db.raw("""
            ALTER TABLE patients
            ALTER COLUMN birth_date TYPE DATE USING birth_date::date
        """).run()
        try await db.raw("""
            ALTER TABLE patients
            ALTER COLUMN rg_issue_date TYPE DATE USING rg_issue_date::date
        """).run()
        try await db.raw("""
            ALTER TABLE family_members
            ALTER COLUMN birth_date TYPE DATE USING birth_date::date
        """).run()
        try await db.raw("""
            ALTER TABLE patient_diagnoses
            ALTER COLUMN date TYPE DATE USING date::date
        """).run()
    }

    func revert(on db: any SQLDatabase) async throws {
        // Reverte para TEXT/TIMESTAMP. AT TIME ZONE 'UTC' na ida → reverter
        // arranca a TZ assumindo que o valor estava em UTC (consistente).
        try await db.raw("""
            ALTER TABLE patient_diagnoses
            ALTER COLUMN date TYPE TIMESTAMP USING date::timestamp
        """).run()
        try await db.raw("""
            ALTER TABLE family_members
            ALTER COLUMN birth_date TYPE TIMESTAMP USING birth_date::timestamp
        """).run()
        try await db.raw("""
            ALTER TABLE patients
            ALTER COLUMN rg_issue_date TYPE TIMESTAMP USING rg_issue_date::timestamp
        """).run()
        try await db.raw("""
            ALTER TABLE patients
            ALTER COLUMN birth_date TYPE TIMESTAMP USING birth_date::timestamp
        """).run()

        try await db.raw("""
            ALTER TABLE outbox_messages
            ALTER COLUMN processed_at TYPE TIMESTAMP USING processed_at AT TIME ZONE 'UTC'
        """).run()
        try await db.raw("""
            ALTER TABLE outbox_messages
            ALTER COLUMN occurred_at TYPE TIMESTAMP USING occurred_at AT TIME ZONE 'UTC'
        """).run()
        try await db.raw("""
            ALTER TABLE rights_violation_reports
            ALTER COLUMN incident_date TYPE TIMESTAMP USING incident_date AT TIME ZONE 'UTC'
        """).run()
        try await db.raw("""
            ALTER TABLE rights_violation_reports
            ALTER COLUMN report_date TYPE TIMESTAMP USING report_date AT TIME ZONE 'UTC'
        """).run()
        try await db.raw("""
            ALTER TABLE referrals
            ALTER COLUMN date TYPE TIMESTAMP USING date AT TIME ZONE 'UTC'
        """).run()
        try await db.raw("""
            ALTER TABLE social_care_appointments
            ALTER COLUMN date TYPE TIMESTAMP USING date AT TIME ZONE 'UTC'
        """).run()

        try await db.raw("""
            ALTER TABLE audit_trail
            ALTER COLUMN payload TYPE TEXT USING payload::text
        """).run()
        try await db.raw("""
            ALTER TABLE outbox_messages
            ALTER COLUMN payload TYPE TEXT USING payload::text
        """).run()
    }
}
