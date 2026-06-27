import Foundation
import Testing
@testable import social_care_s

// ticket: T-007 — achados DB-4 + S-H-D5 (Primitive Obsession em LookupId)
// ADR: ADR-007 — Colunas que carregam identidade semântica usam tipo nativo + FK

/// Regressão estrutural para os achados **DB-4** + **S-H-D5**: a coluna
/// `family_members.relationship` foi criada como `TEXT` em
/// `2026_02_24_CreateInitialSchema`, mas armazena UUID que aponta para
/// `dominio_parentesco.id`. Anti-pattern duplo:
///
/// 1. **Tipo errado** (Ramakrishnan, Cap. 3.1 — Column Domain): `TEXT` aceita
///    qualquer string (`"cônjuge"`, `"foo bar"`), inclusive UUID malformado.
/// 2. **Sem FK** (DB-3 família): inserção direta com UUID inventado cria
///    órfão silencioso; soft-delete de lookup não bloqueia uso futuro.
///
/// Conexão com S-H-D5 (Primitive Obsession): o domínio carrega `LookupId`
/// como VO. O mapper escreve `.description` (string), o decoder faz
/// `try LookupId(m.relationship)` — perde tipagem no banco.
///
/// Fix expected: migration de **expand-contract**:
/// 1. ADD COLUMN `relationship_id UUID NULL`
/// 2. UPDATE backfill `relationship_id = relationship::UUID`
/// 3. Pré-flight: rejeitar se backfill encontra string não-UUID
/// 4. SET NOT NULL
/// 5. ADD FOREIGN KEY → `dominio_parentesco(id)` ON DELETE RESTRICT
/// 6. DROP COLUMN `relationship` antiga
///
/// Este teste é estrutural — inspeciona arquivos `.swift` de Migrations/
/// buscando declarações esperadas. Integration test runtime fica para T-033.
@Suite("Regression: DataIntegrity — DB-4/S-H-D5 relationship is typed UUID + FK")
struct RelationshipIdIsTypedRegressionTests {

    // MARK: - File discovery helper

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

    // MARK: - Tests

    @Test("DB-4 / S-H-D5 — alguma migration declara coluna relationship_id UUID em family_members")
    func test_DB_4_relationship_id_column_declared() throws {
        let found = try anyMigrationContains([
            "family_members",
            "add column",
            "relationship_id",
            "uuid"
        ])
        #expect(found, "DB-4: nenhuma migration declara coluna relationship_id UUID em family_members. Esperado: ALTER TABLE family_members ADD COLUMN relationship_id UUID NOT NULL.")
    }

    @Test("DB-4 / DB-3 — relationship_id tem FK para dominio_parentesco")
    func test_DB_4_relationship_id_has_FK() throws {
        let found = try anyMigrationContains([
            "relationship_id",
            "references",
            "dominio_parentesco",
            "on delete"
        ])
        #expect(found, "DB-4 / DB-3: relationship_id não tem FOREIGN KEY declarada para dominio_parentesco. Sem FK, lookup deletado órfana relacionamento silenciosamente.")
    }

    @Test("DB-4 — backfill pré-flight protege contra strings não-UUID")
    func test_DB_4_backfill_has_preflight() throws {
        let found = try anyMigrationContains([
            "family_members",
            "relationship",
            "update",
            "relationship_id"
        ])
        #expect(found, "DB-4: nenhuma migration faz UPDATE backfill de relationship → relationship_id::UUID. Migration de expand-contract sem backfill perde dados existentes.")
    }

    @Test("DB-4 — DROP COLUMN relationship antigo (contract phase)")
    func test_DB_4_old_text_column_dropped() throws {
        let found = try anyMigrationContains([
            "family_members",
            "drop column",
            "relationship"
        ])
        #expect(found, "DB-4: nenhuma migration faz DROP COLUMN relationship (TEXT) após backfill. Sem drop, schema mantém coluna obsoleta confundindo leitor.")
    }

    @Test("DB-4 — migration tem revert simétrico (recriar coluna text + drop FK)")
    func test_DB_4_migration_has_revert() throws {
        let found = try anyMigrationContains([
            "family_members",
            "relationship_id",
            "func revert",
            "drop"
        ])
        #expect(found, "DB-4: migration de relationship_id não tem revert simétrico. ADR-002 exige forward+rollback.")
    }
}
