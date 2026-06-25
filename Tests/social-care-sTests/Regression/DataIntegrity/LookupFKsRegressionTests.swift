import Foundation
import Testing
@testable import social_care_s

// ticket: T-008 — achado DB-3 (Database Modeling Review)
// ADR: ADR-008 — FK declarada para toda coluna *_id que aponta para lookup table

/// Regressão estrutural para o achado **DB-3**: 7 colunas tipo `*_id`
/// apontam **conceitualmente** para `dominio_*(id)` mas **não têm
/// `REFERENCES`** declarada no schema.
///
/// Ramakrishnan, Cap. 3.3 (Foreign Keys):
///
/// > *"All foreign key constraints must be declared in the schema. They
/// > express semantic relationships that the DBMS will enforce on every
/// > insert, update, and delete."*
///
/// Validação na Application (`LookupValidating`) só vale para a via canônica.
/// ETL direto, fix manual via SQL, ou outra réplica que não passa pela
/// Application bypassa silenciosamente.
///
/// Política `ON DELETE RESTRICT` em todas as 7 FKs: lookup table só pode
/// ser desativada via flag `ativo: false`, nunca DELETE físico. Restrict
/// força tratamento explícito de tentativas equivocadas.
///
/// Este teste é estrutural — inspeciona arquivos de Migration. T-007 já
/// cobriu `relationship_id` separadamente (semântica de tipo + FK).
@Suite("Regression: DataIntegrity — DB-3 lookup FKs declared")
struct LookupFKsRegressionTests {

    // MARK: - File discovery

    private func migrationsDirectory(file: StaticString = #filePath) throws -> URL {
        let thisFile = URL(fileURLWithPath: "\(file)")
        let projectRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return projectRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("social-care-s")
            .appendingPathComponent("IO")
            .appendingPathComponent("Persistence")
            .appendingPathComponent("SQLKit")
            .appendingPathComponent("Migrations")
    }

    private func anyMigrationContains(_ needles: [String]) throws -> Bool {
        let dir = try migrationsDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let needlesLower = needles.map { $0.lowercased() }
        for file in files {
            let content = (try? String(contentsOf: file, encoding: .utf8))?.lowercased() ?? ""
            if needlesLower.allSatisfy({ content.contains($0) }) { return true }
        }
        return false
    }

    // MARK: - Tests (uma FK por teste, padronizado)

    @Test("DB-3 — patients.social_identity_type_id tem FK para dominio_tipo_identidade")
    func test_DB_3_social_identity_type_id_has_FK() throws {
        let found = try anyMigrationContains([
            "social_identity_type_id",
            "references",
            "dominio_tipo_identidade",
            "on delete restrict"
        ])
        #expect(found, "DB-3: social_identity_type_id sem FK declarada. ETL direto pode inserir UUID inventado.")
    }

    @Test("DB-3 — patients.ii_ingress_type_id tem FK para dominio_tipo_ingresso")
    func test_DB_3_ii_ingress_type_id_has_FK() throws {
        let found = try anyMigrationContains([
            "ii_ingress_type_id",
            "references",
            "dominio_tipo_ingresso",
            "on delete restrict"
        ])
        #expect(found, "DB-3: ii_ingress_type_id sem FK declarada.")
    }

    @Test("DB-3 — member_incomes.occupation_id tem FK para dominio_condicao_ocupacao")
    func test_DB_3_occupation_id_has_FK() throws {
        let found = try anyMigrationContains([
            "occupation_id",
            "references",
            "dominio_condicao_ocupacao",
            "on delete restrict"
        ])
        #expect(found, "DB-3: member_incomes.occupation_id sem FK declarada.")
    }

    @Test("DB-3 — member_educational_profiles.education_level_id tem FK para dominio_escolaridade")
    func test_DB_3_education_level_id_has_FK() throws {
        let found = try anyMigrationContains([
            "education_level_id",
            "references",
            "dominio_escolaridade",
            "on delete restrict"
        ])
        #expect(found, "DB-3: education_level_id sem FK declarada.")
    }

    @Test("DB-3 — program_occurrences.effect_id tem FK para dominio_efeito_condicionalidade")
    func test_DB_3_effect_id_has_FK() throws {
        let found = try anyMigrationContains([
            "effect_id",
            "references",
            "dominio_efeito_condicionalidade",
            "on delete restrict"
        ])
        #expect(found, "DB-3: program_occurrences.effect_id sem FK declarada.")
    }

    @Test("DB-3 — member_deficiencies.deficiency_type_id tem FK para dominio_tipo_deficiencia")
    func test_DB_3_deficiency_type_id_has_FK() throws {
        let found = try anyMigrationContains([
            "deficiency_type_id",
            "references",
            "dominio_tipo_deficiencia",
            "on delete restrict"
        ])
        #expect(found, "DB-3: member_deficiencies.deficiency_type_id sem FK declarada.")
    }

    @Test("DB-3 — ingress_linked_programs.program_id tem FK para dominio_programa_social")
    func test_DB_3_program_id_has_FK() throws {
        let found = try anyMigrationContains([
            "program_id",
            "references",
            "dominio_programa_social",
            "on delete restrict"
        ])
        #expect(found, "DB-3: ingress_linked_programs.program_id sem FK declarada.")
    }

    @Test("DB-3 — migration de FKs tem revert simétrico (DROP CONSTRAINT)")
    func test_DB_3_lookup_fks_migration_has_revert() throws {
        let found = try anyMigrationContains([
            "fk_patients_social_identity_type",
            "drop constraint",
            "func revert"
        ])
        #expect(found, "DB-3: migration de lookup FKs sem revert simétrico (DROP CONSTRAINT). ADR-002 + handbook G17 exigem forward+rollback.")
    }
}
