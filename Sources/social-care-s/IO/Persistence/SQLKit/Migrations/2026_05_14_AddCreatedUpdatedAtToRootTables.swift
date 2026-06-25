import Foundation
import SQLKit

/// Auditoria operacional via colunas automáticas `created_at`/`updated_at`
/// em todas as tabelas raiz (ADR-023).
///
/// ## Estado pré-fix (DB-17 / S-H-P5)
///
/// Tabelas raiz (`patients`, `patient_diagnoses`,
/// `social_care_appointments`, `referrals`, `rights_violation_reports`)
/// não tinham timestamps de criação/atualização. Toda pergunta operacional
/// ("quando esta row foi modificada pela última vez?") dependia de
/// cruzar `audit_trail` por `aggregate_id` — caro (full scan + JOIN) e
/// indireto. Pior: `audit_trail` registra **eventos de domínio**; correções
/// manuais via SQL, restores parciais, ETL e qualquer manipulação fora do
/// app não geram event — invisíveis na auditoria.
///
/// ## Estado pós-fix
///
/// Cada tabela raiz ganha:
/// - `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` — banco preenche em
///   INSERT; app não envia.
/// - `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` — banco preenche em
///   INSERT; **trigger** atualiza em todo UPDATE.
/// - TRIGGER `<table>_updated_at` BEFORE UPDATE FOR EACH ROW EXECUTE
///   FUNCTION `touch_updated_at()`.
///
/// Função PL/pgSQL única é declarada no início (`CREATE OR REPLACE`):
///
/// ```sql
/// CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS TRIGGER AS $$
/// BEGIN
///     NEW.updated_at = NOW();
///     RETURN NEW;
/// END;
/// $$ LANGUAGE plpgsql;
/// ```
///
/// ## Por que tabelas raiz apenas?
///
/// - Filhas associativas/normalizadas (`member_incomes`, `social_benefits`,
///   `family_member_required_documents`) são **regeneradas** a cada save
///   do agregado. `created_at` ali não tem semântica útil — seria
///   sempre o momento da última save do parent.
/// - Operacionais com semântica temporal própria (`outbox_messages`,
///   `audit_trail`) já têm `occurred_at`/`processed_at`/`recorded_at`.
///   Adicionar `created_at` seria redundante.
/// - Raízes incluem `patient_diagnoses`/`appointments`/`referrals`/
///   `violations` (entidades-filhas com identidade própria — PK surrogate,
///   audit operacional vale).
///
/// ## Por que models Swift NÃO declaram essas colunas?
///
/// `PostgresKit.model()` e Mirror-based upsert (T-021) iteram as
/// propriedades do struct. Se model declarasse `created_at` como `Date?`
/// e o app não setasse, INSERT mandaria NULL → contraria
/// `NOT NULL DEFAULT NOW()` → erro. Manter colunas só no banco preserva
/// o invariante "banco gerencia" sem bloquear `.model()`.
///
/// Para consultas que precisem ler esses campos (futuro endpoint
/// administrativo), criar query dedicada com SELECT explícito —
/// não decodificar via `PatientModel`.
///
/// ## Estratégia de conversão
///
/// `ADD COLUMN ... NOT NULL DEFAULT NOW()` é seguro em PostgreSQL 11+ —
/// usa fast-path "ALTER TABLE without a rewrite" quando a expressão
/// default é volátil/non-volatile. Backfill é instantâneo.
///
/// Trigger é por tabela (não global) para evitar ativação acidental em
/// tabelas que não têm `updated_at`.
///
/// Ticket: T-023. ADR: ADR-023.
struct AddCreatedUpdatedAtToRootTables: Migration {
    let name = "2026_05_14_AddCreatedUpdatedAtToRootTables"

    private let rootTables: [String] = [
        "patients",
        "patient_diagnoses",
        "social_care_appointments",
        "referrals",
        "rights_violation_reports"
    ]

    func prepare(on db: any SQLDatabase) async throws {
        // PASSO 1 — Função PL/pgSQL reusável.
        try await db.raw("""
            CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS TRIGGER AS $$
            BEGIN
                NEW.updated_at = NOW();
                RETURN NEW;
            END;
            $$ LANGUAGE plpgsql
        """).run()

        // PASSO 2 — Para cada tabela raiz: ADD COLUMN created_at + updated_at + TRIGGER.
        for table in rootTables {
            try await db.raw("""
                ALTER TABLE \(unsafeRaw: table)
                ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            """).run()

            try await db.raw("""
                ALTER TABLE \(unsafeRaw: table)
                ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            """).run()

            // Trigger por tabela. Nome `<table>_updated_at` é único por table
            // (constraint do PostgreSQL).
            try await db.raw("""
                CREATE TRIGGER \(unsafeRaw: table)_updated_at
                BEFORE UPDATE ON \(unsafeRaw: table)
                FOR EACH ROW
                EXECUTE FUNCTION touch_updated_at()
            """).run()
        }
    }

    func revert(on db: any SQLDatabase) async throws {
        // Ordem inversa: drop trigger → drop column → drop function.
        for table in rootTables.reversed() {
            try await db.raw("""
                DROP TRIGGER IF EXISTS \(unsafeRaw: table)_updated_at ON \(unsafeRaw: table)
            """).run()

            try await db.raw("""
                ALTER TABLE \(unsafeRaw: table) DROP COLUMN IF EXISTS updated_at
            """).run()

            try await db.raw("""
                ALTER TABLE \(unsafeRaw: table) DROP COLUMN IF EXISTS created_at
            """).run()
        }

        try await db.raw("""
            DROP FUNCTION IF EXISTS touch_updated_at()
        """).run()
    }
}
