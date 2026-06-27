import Testing
import Foundation
@testable import social_care_s

/// Suite de regressão — Achados S-H-P5 (Senior Code Review § P5) +
/// DB-17 (DB Modeling Review).
///
/// Pré-fix:
/// - Tabelas raiz (`patients`, `patient_diagnoses`,
///   `social_care_appointments`, `referrals`, `rights_violation_reports`)
///   não tinham `created_at` / `updated_at`. Toda auditoria operacional
///   ("quando esta row foi criada/atualizada pela última vez?") dependia
///   de cruzar `audit_trail` por agregado_id — caro e indireto.
/// - `audit_trail` registra eventos de domínio. Não cobre operações de
///   manutenção (correção manual via SQL, restore parcial, ETL).
///
/// Fix (ADR-023):
/// 1. Função PL/pgSQL `touch_updated_at()` em uma migration única; reusada
///    por todos os triggers.
/// 2. Cada tabela raiz ganha:
///    - `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` (banco preenche
///      em INSERT; app não toca).
///    - `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` (banco preenche
///      em INSERT; trigger atualiza em UPDATE).
///    - TRIGGER `<table>_updated_at` BEFORE UPDATE FOR EACH ROW EXECUTE
///      FUNCTION touch_updated_at().
/// 3. Models Swift permanecem sem essas colunas (banco gerencia; app
///    não envia em INSERT/UPDATE — comportamento natural com `.model()`
///    e Mirror-based upsert do T-021).
///
/// Suite cobre lints estruturais (existência da migration + DDL correta)
/// e referência runtime ao invariante "banco gerencia colunas".
@Suite("Regression: Data Integrity — S-H-P5/DB-17 created_at/updated_at em raízes")
struct TemporalAuditTests {

    // MARK: - File discovery

    private func projectRoot(file: StaticString = #filePath) -> URL {
        let thisFile = URL(fileURLWithPath: "\(file)")
        return thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func migrationsDir() -> URL {
        projectRoot()
            .appendingPathComponent("Sources/social-care-s/IO/Persistence/SQLKit/Migrations")
    }

    private func anyMigrationContains(_ needles: [String]) throws -> Bool {
        let dir = migrationsDir()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let needlesLower = needles.map { $0.lowercased() }
        for file in files {
            let content = (try? String(contentsOf: file, encoding: .utf8))?.lowercased() ?? ""
            if needlesLower.allSatisfy(content.contains) {
                return true
            }
        }
        return false
    }

    // MARK: - Lints — função e estrutura

    @Test("DB-17 — função touch_updated_at() declarada (CREATE OR REPLACE FUNCTION)")
    func test_DB_17_function_declared() throws {
        let exists = try anyMigrationContains([
            "create or replace function touch_updated_at",
            "$$ language plpgsql"
        ])
        #expect(exists,
                "DB-17: nenhuma migration declara CREATE OR REPLACE FUNCTION touch_updated_at(). Sem ela, triggers BEFORE UPDATE não têm o que executar.")
    }

    // MARK: - Lints — por tabela raiz

    private let rootTables: [String] = [
        "patients",
        "patient_diagnoses",
        "social_care_appointments",
        "referrals",
        "rights_violation_reports"
    ]

    @Test("DB-17 — DDL ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT NOW() existe")
    func test_DB_17_created_at_added() throws {
        // Migration aplica em loop (`for table in rootTables`); lint verifica
        // que a DDL existe (uma vez) E que cada tabela é mencionada no array.
        let hasDDL = try anyMigrationContains([
            "add column created_at",
            "timestamptz",
            "default now()"
        ])
        #expect(hasDDL,
                "DB-17: nenhuma migration tem `ADD COLUMN created_at TIMESTAMPTZ ... DEFAULT NOW()`.")
        try assertAllRootTablesListed()
    }

    @Test("DB-17 — DDL ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW() existe")
    func test_DB_17_updated_at_added() throws {
        let hasDDL = try anyMigrationContains([
            "add column updated_at",
            "timestamptz",
            "default now()"
        ])
        #expect(hasDDL,
                "DB-17: nenhuma migration tem `ADD COLUMN updated_at TIMESTAMPTZ ... DEFAULT NOW()`.")
        try assertAllRootTablesListed()
    }

    @Test("DB-17 — DDL CREATE TRIGGER ... BEFORE UPDATE EXECUTE FUNCTION touch_updated_at existe")
    func test_DB_17_trigger_created() throws {
        let hasDDL = try anyMigrationContains([
            "create trigger",
            "_updated_at",
            "before update on",
            "execute function touch_updated_at"
        ])
        #expect(hasDDL,
                "DB-17: nenhuma migration tem `CREATE TRIGGER <table>_updated_at BEFORE UPDATE ... EXECUTE FUNCTION touch_updated_at()`.")
        try assertAllRootTablesListed()
    }

    /// Verifica que a migration declara explicitamente os nomes das tabelas
    /// raiz (em array/lista que será iterada pelo loop). Garante que nenhuma
    /// raiz foi esquecida.
    private func assertAllRootTablesListed() throws {
        var missing: [String] = []
        for table in rootTables {
            let has = try anyMigrationContains([
                "rootTables:".lowercased(),
                "\"\(table)\""
            ])
            if !has { missing.append(table) }
        }
        #expect(missing.isEmpty,
                "DB-17: tabelas raiz NÃO listadas em `rootTables` da migration: \(missing).")
    }

    @Test("DB-17 — migration tem revert() simétrico (DROP TRIGGER + DROP COLUMN + DROP FUNCTION)")
    func test_DB_17_revert_symmetric() throws {
        // Heurística: alguma migration tem `func revert` + as palavras DROP TRIGGER e DROP COLUMN
        // e DROP FUNCTION touch_updated_at.
        let hasRevertCore = try anyMigrationContains([
            "func revert",
            "drop trigger",
            "drop column",
            "drop function",
            "touch_updated_at"
        ])
        #expect(hasRevertCore,
                "DB-17: migration sem revert() simétrico (DROP TRIGGER + DROP COLUMN + DROP FUNCTION).")
    }

    // MARK: - Sanity: invariante de design

    @Test("DB-17 — PatientModel NÃO declara created_at/updated_at (banco gerencia)")
    func test_DB_17_patient_model_does_not_carry_audit_columns() {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/IO/Persistence/SQLKit/Models/PatientDatabaseModels.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // Heurística: `let created_at` ou `let updated_at` não devem aparecer
        // no PatientModel struct (todo modelo). Se aparecerem, INSERT
        // mandaria NULL → contraria DEFAULT NOW() (NOT NULL → erro).
        #expect(!source.contains("let created_at"),
                "DB-17: algum model declara `let created_at` — banco deve gerenciar (DEFAULT NOW()). App não envia em INSERT.")
        #expect(!source.contains("let updated_at"),
                "DB-17: algum model declara `let updated_at` — banco deve gerenciar (DEFAULT NOW() + trigger).")
    }
}
