import Foundation
import SQLKit

/// Cria tabela `patient_assessments` (Fase 4 EXPAND — ADR-024).
///
/// **Estado expand-contract:**
/// - **(a) EXPAND** ← este ticket: tabela criada + backfill idempotente.
///   Colunas correspondentes em `patients` permanecem (não são dropadas).
/// - **(b) DUAL-WRITE**: próximo PR — handlers `UpdateHousingCondition*`
///   etc. escrevem em ambos os repositórios.
/// - **(c) CUTOVER**: leitura migra para `patient_assessments` via
///   `GetFullPatientProfileQuery`.
/// - **(d) CONTRACT**: drop colunas `hc_*`/`csn_*`/`shs_*`/`ses_*` em
///   `patients`.
///
/// ## Schema
///
/// ```sql
/// CREATE TABLE patient_assessments (
///     patient_id  UUID PRIMARY KEY REFERENCES patients(id) ON DELETE CASCADE,
///     version     INT  NOT NULL DEFAULT 0,
///
///     -- 7 módulos serializados como JSONB (compatível com decoder atual
///     -- do Patient via PatientDatabaseMapper). Migração completa para
///     -- colunas explícitas é trabalho de release N+2 (CONTRACT) — agora
///     -- mantemos a forma serializada para reduzir complexidade do
///     -- backfill.
///     housing_condition          JSONB,
///     socioeconomic_situation    JSONB,
///     work_and_income            JSONB,
///     educational_status         JSONB,
///     health_status              JSONB,
///     community_support_network  JSONB,
///     social_health_summary      JSONB,
///
///     created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
///     updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
/// );
/// CREATE TRIGGER patient_assessments_updated_at
///   BEFORE UPDATE ON patient_assessments
///   FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
/// ```
///
/// ## Backfill
///
/// `INSERT INTO patient_assessments (patient_id) SELECT id FROM
/// patients WHERE qualquer_módulo IS NOT NULL ON CONFLICT (patient_id)
/// DO NOTHING`. Idempotente — re-rodar não duplica.
///
/// **Nota:** colunas JSONB ficam NULL inicialmente. Estado real dos
/// módulos continua em `patients.hc_*` etc. até o estágio CONTRACT.
/// Esta tabela é "shadow" durante a expand phase. A leitura via
/// `SQLKitPatientAssessmentRepository.find(byPatientId:)` retorna
/// agregado VAZIO (todos os módulos nil) durante essa fase — útil para
/// validar a infra antes do dual-write.
///
/// Trigger `patient_assessments_updated_at` segue o padrão ADR-023
/// (função `touch_updated_at()` já existe — declarada por
/// `AddCreatedUpdatedAtToRootTables`).
///
/// Ticket: T-024.a. ADR: ADR-024.
struct CreatePatientAssessmentsTable: Migration {
    let name = "2026_05_14_CreatePatientAssessmentsTable"

    func prepare(on db: any SQLDatabase) async throws {
        // PASSO 1 — CREATE TABLE.
        try await db.raw("""
            CREATE TABLE patient_assessments (
                patient_id                UUID PRIMARY KEY REFERENCES patients(id) ON DELETE CASCADE,
                version                   INT  NOT NULL DEFAULT 0,
                housing_condition         JSONB,
                socioeconomic_situation   JSONB,
                work_and_income           JSONB,
                educational_status        JSONB,
                health_status             JSONB,
                community_support_network JSONB,
                social_health_summary     JSONB,
                created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """).run()

        // PASSO 2 — TRIGGER updated_at (ADR-023).
        try await db.raw("""
            CREATE TRIGGER patient_assessments_updated_at
            BEFORE UPDATE ON patient_assessments
            FOR EACH ROW
            EXECUTE FUNCTION touch_updated_at()
        """).run()

        // PASSO 3 — Backfill idempotente: para cada paciente com algum
        // módulo de assessment preenchido, INSERT linha em
        // `patient_assessments` (somente patient_id; módulos JSONB ficam
        // NULL — preenchimento real virá no dual-write).
        //
        // Estamos populando o "índice" da tabela (patient_id) — a
        // existência da row torna find(byPatientId) → não-nil quando o
        // paciente já tem qualquer módulo. Isso permite que a próxima
        // fase (dual-write) faça UPDATE em vez de INSERT, evitando race
        // entre dois handlers concorrentes.
        //
        // ⚠️ Schema real (estado 2026-04-12): `NormalizeSchema` (03_08)
        // achatou os 3 módulos agrupados — `work_and_income`,
        // `educational_status`, `health_status` — em colunas escalares
        // normalizadas + tabelas filhas, e DROPOU as colunas JSONB
        // homônimas. Referenciá-las aqui causava
        // `column "work_and_income" does not exist (42703)`. O predicado
        // abaixo usa exatamente os "gates de presença" que
        // `PatientDatabaseMapper.reconstruct*` adota para decidir se cada
        // módulo existe — preservando a intenção original (1 linha por
        // paciente com QUALQUER dado de assessment):
        //
        //   - housing_condition          → `hc_type`
        //   - socioeconomic_situation    → `ses_total_family_income`
        //   - community_support_network  → `csn_has_relative_support`
        //   - social_health_summary      → `shs_requires_constant_care`
        //   - work_and_income            → `wi_has_retired_members`
        //     (Mapper.reconstructWorkAndIncome gate)
        //   - health_status              → `hs_food_insecurity`
        //     (Mapper.reconstructHealthStatus gate)
        //   - educational_status         → NÃO tem coluna escalar em
        //     `patients`; vive nas tabelas filhas
        //     `member_educational_profiles` / `program_occurrences`
        //     (Mapper.reconstructEducationalStatus gate:
        //     `!profiles.isEmpty || !occurrences.isEmpty`). Usamos EXISTS.
        try await db.raw("""
            INSERT INTO patient_assessments (patient_id)
            SELECT p.id
              FROM patients p
             WHERE p.hc_type IS NOT NULL
                OR p.ses_total_family_income IS NOT NULL
                OR p.csn_has_relative_support IS NOT NULL
                OR p.shs_requires_constant_care IS NOT NULL
                OR p.wi_has_retired_members IS NOT NULL
                OR p.hs_food_insecurity IS NOT NULL
                OR EXISTS (
                       SELECT 1 FROM member_educational_profiles mep
                        WHERE mep.patient_id = p.id
                   )
                OR EXISTS (
                       SELECT 1 FROM program_occurrences po
                        WHERE po.patient_id = p.id
                   )
            ON CONFLICT (patient_id) DO NOTHING
        """).run()
    }

    func revert(on db: any SQLDatabase) async throws {
        // Drop trigger antes da tabela (boa prática).
        try await db.raw("""
            DROP TRIGGER IF EXISTS patient_assessments_updated_at ON patient_assessments
        """).run()
        try await db.raw("""
            DROP TABLE IF EXISTS patient_assessments
        """).run()
    }
}
