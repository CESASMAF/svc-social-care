import Foundation
import Testing
@testable import social_care_s

// ticket: T-006 — achado DB-1 (Database Modeling Review)
// ADR: ADR-006 — Toda tabela é uma relação com PK declarada

/// Regressão estrutural para o achado **DB-1**: as tabelas `family_members` e
/// `patient_diagnoses` foram criadas em `2026_02_24_CreateInitialSchema.swift`
/// **sem chave primária**. No modelo relacional (Ramakrishnan & Gehrke, Cap. 3),
/// uma relação é por definição um conjunto de tuplas distintas — sem PK, o
/// que está na tabela é um *multi-set* permissivo.
///
/// Consequências do bug original:
/// - Importação via ETL ou fix manual pode inserir duplicatas idênticas.
/// - Replicação row-based não consegue localizar a tupla determinísticamente.
/// - Tabelas futuras não podem declarar FK para `family_members` ou `patient_diagnoses`.
/// - DELETE seletivo por critério natural é inviável.
///
/// Este suite **não roda SQL** (não há Postgres em unit tests). Em vez disso,
/// faz **inspeção estrutural** dos arquivos `.swift` de Migration: garante
/// que uma migration **declara** PK composta para `family_members` e PK
/// surrogate + UNIQUE para `patient_diagnoses`.
///
/// Limitações:
/// - Não detecta se a migration foi efetivamente aplicada em produção
///   (responsabilidade do CI integration test, fora do escopo aqui).
/// - Detecta apenas a **declaração** — alguém pode adicionar a PK e depois
///   remover em migration nova. O teste de schema snapshot do T-033 vai
///   complementar isso.
///
/// Mas para o objetivo de **regressão**, este teste é suficiente: se um dev
/// reverter este ticket (apagar a migration ou as linhas de PK), o teste
/// pega antes do PR.
@Suite("Regression: DataIntegrity — DB-1 aggregate tables need PK")
struct AggregateTableHasPKRegressionTests {

    // MARK: - File discovery helpers

    /// Localiza a pasta `Sources/.../Migrations/` a partir do `#filePath`
    /// deste arquivo de teste. Funciona em qualquer máquina sem depender de
    /// configuração de Bundle.
    private func migrationsDirectory(file: StaticString = #filePath) throws -> URL {
        // #filePath aponta para .../Tests/social-care-sTests/Regression/DataIntegrity/<thisFile>.swift
        // Subimos 4 níveis até a raiz do projeto, depois descemos em Sources/...
        let thisFile = URL(fileURLWithPath: "\(file)")
        let projectRoot = thisFile
            .deletingLastPathComponent()  // DataIntegrity/
            .deletingLastPathComponent()  // Regression/
            .deletingLastPathComponent()  // social-care-sTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // <project root>
        return projectRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("social-care-s")
            .appendingPathComponent("IO")
            .appendingPathComponent("Persistence")
            .appendingPathComponent("SQLKit")
            .appendingPathComponent("Migrations")
    }

    /// Retorna `true` se **alguma** migration `.swift` no diretório contém
    /// **todas** as substrings (ordenadas ou não) — case-insensitive.
    private func anyMigrationContains(_ needles: [String]) throws -> (matched: Bool, file: String?) {
        let dir = try migrationsDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        for file in files {
            let content = (try? String(contentsOf: file, encoding: .utf8))?.lowercased() ?? ""
            let needlesLower = needles.map { $0.lowercased() }
            if needlesLower.allSatisfy({ content.contains($0) }) {
                return (true, file.lastPathComponent)
            }
        }
        return (false, nil)
    }

    // MARK: - Tests

    @Test("DB-1 — alguma migration declara PK composta em family_members")
    func test_DB_1_family_members_has_pk_declared() throws {
        let result = try anyMigrationContains([
            "family_members",
            "primary key",
            "patient_id",
            "person_id"
        ])
        #expect(result.matched, "DB-1: nenhuma migration declara PK em family_members (esperado: ALTER TABLE … ADD PRIMARY KEY (patient_id, person_id)). Sem PK, tabela é multi-set, não relação.")
    }

    @Test("DB-1 — alguma migration declara PK surrogate id em patient_diagnoses")
    func test_DB_1_patient_diagnoses_has_pk_id() throws {
        let result = try anyMigrationContains([
            "patient_diagnoses",
            "add column",
            "id",
            "uuid",
            "primary key"
        ])
        #expect(result.matched, "DB-1: nenhuma migration declara coluna id UUID + PK em patient_diagnoses (esperado: ADD COLUMN id UUID + PRIMARY KEY (id)). Sem PK não pode ser referenciada por FK futura.")
    }

    @Test("DB-1 — alguma migration declara UNIQUE (patient_id, icd_code, date) em patient_diagnoses")
    func test_DB_1_patient_diagnoses_has_natural_unique() throws {
        let result = try anyMigrationContains([
            "patient_diagnoses",
            "unique",
            "patient_id",
            "icd_code",
            "date"
        ])
        #expect(result.matched, "DB-1: nenhuma migration declara UNIQUE (patient_id, icd_code, date). Sem isso, ETL pode inserir duplicatas idênticas que o domínio considera 'o mesmo diagnóstico'.")
    }

    @Test("DB-1 — migration de PK tem rollback simétrico (DROP CONSTRAINT)")
    func test_DB_1_pk_migration_has_rollback() throws {
        let result = try anyMigrationContains([
            "family_members",
            "drop constraint",
            "func revert"
        ])
        #expect(result.matched, "Migration que adiciona PK em family_members não declara rollback simétrico (func revert + DROP CONSTRAINT). ADR-002 + handbook G17 exigem forward+rollback.")
    }
}
