import Foundation
import SQLKit

/// Separa `audit_trail.id` de `outbox_messages.id` (S-C10 / ADR-015).
///
/// **Bug pré-fix:** o relay populava `AuditTrailModel(id: message.id, ...)`,
/// reusando o PK do outbox como PK do audit. Em qualquer cenário de
/// re-processamento (at-least-once é a regra do Outbox Pattern), o INSERT
/// no audit batia em unique violation do PK e abortava a transação inteira
/// — **49 mensagens válidas voltavam a `processed_at IS NULL` por causa de
/// 1 duplicata.**
///
/// **Fix em 3 partes:**
///
/// 1. `audit_trail.id` ganha `DEFAULT gen_random_uuid()` — cada audit entry
///    tem identidade própria, independente do outbox.
/// 2. Nova coluna `outbox_message_id UUID NOT NULL` rastreia a relação 1:1
///    (audit aponta para o outbox que originou).
/// 3. Index em `outbox_message_id` para join eficiente.
///
/// **Pré-flight:** se houver rows existentes em `audit_trail`, populamos
/// `outbox_message_id` com o `id` antigo (preserva relação histórica).
/// Não falha — backfill puro.
///
/// Ticket: T-015. ADR: ADR-015.
struct AuditTrailDistinctId: Migration {
    let name = "2026_05_14_AuditTrailDistinctId"

    func prepare(on db: any SQLDatabase) async throws {
        // 1. Add nova coluna nullable + default temporário (id antigo)
        try await db.raw("""
            ALTER TABLE audit_trail
            ADD COLUMN IF NOT EXISTS outbox_message_id UUID NULL
        """).run()

        // 2. Backfill: rows existentes herdam o id antigo como outbox_message_id
        // (era essa a relação implícita pré-fix).
        try await db.raw("""
            UPDATE audit_trail
            SET outbox_message_id = id
            WHERE outbox_message_id IS NULL
        """).run()

        // 3. SET NOT NULL após backfill
        try await db.raw("""
            ALTER TABLE audit_trail
            ALTER COLUMN outbox_message_id SET NOT NULL
        """).run()

        // 4. DEFAULT gen_random_uuid() na coluna id (a partir daqui, novas
        // entries ganham id aleatório — relay popula outbox_message_id
        // explicitamente com message.id).
        try await db.raw("""
            ALTER TABLE audit_trail
            ALTER COLUMN id SET DEFAULT gen_random_uuid()
        """).run()

        // 5. Index para join audit_trail ↔ outbox_messages
        try await db.raw("""
            CREATE INDEX IF NOT EXISTS idx_audit_trail_outbox_message
            ON audit_trail(outbox_message_id)
        """).run()
    }

    func revert(on db: any SQLDatabase) async throws {
        try await db.raw("""
            DROP INDEX IF EXISTS idx_audit_trail_outbox_message
        """).run()
        try await db.raw("""
            ALTER TABLE audit_trail
            ALTER COLUMN id DROP DEFAULT
        """).run()
        try await db.raw("""
            ALTER TABLE audit_trail
            DROP COLUMN IF EXISTS outbox_message_id
        """).run()
    }
}
