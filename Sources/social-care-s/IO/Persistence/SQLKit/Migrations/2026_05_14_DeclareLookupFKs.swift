import Foundation
import SQLKit

/// Declara as 7 FKs ausentes entre colunas `*_id` e suas `dominio_*`
/// correspondentes (DB-3).
///
/// Ramakrishnan, Cap. 3.3: integridade referencial é parte do schema, não da
/// aplicação. Validação na camada `LookupValidating` só vale para a via
/// canônica — ETL/replicação/fix manual bypassam. Com FK declarada, o banco
/// rejeita inserções com IDs inventados em qualquer via.
///
/// Política `ON DELETE RESTRICT` universal para lookup tables: item de
/// lookup só pode ser "desativado" via flag `ativo: false` (soft-delete).
/// Tentativa de DELETE físico de item ainda referenciado é rejeitada.
///
/// Pré-requisitos:
/// - ADR-006 (T-006): PKs declaradas em `family_members` e `patient_diagnoses`.
/// - ADR-007 (T-007): `relationship_id` tipificado (FK já declarada lá).
///
/// Mapeamento das 7 FKs (relationship_id já está em T-007):
///
/// | Coluna | Tabela | Lookup target |
/// |---|---|---|
/// | `social_identity_type_id` | `patients` | `dominio_tipo_identidade` |
/// | `ii_ingress_type_id` | `patients` | `dominio_tipo_ingresso` |
/// | `occupation_id` | `member_incomes` | `dominio_condicao_ocupacao` |
/// | `education_level_id` | `member_educational_profiles` | `dominio_escolaridade` |
/// | `effect_id` | `program_occurrences` | `dominio_efeito_condicionalidade` |
/// | `deficiency_type_id` | `member_deficiencies` | `dominio_tipo_deficiencia` |
/// | `program_id` | `ingress_linked_programs` | `dominio_programa_social` |
///
/// Ticket: T-008. ADR: ADR-008.
struct DeclareLookupFKs: Migration {
    let name = "2026_05_14_DeclareLookupFKs"

    private struct FKSpec {
        let constraintName: String
        let sourceTable: String
        let sourceColumn: String
        let targetTable: String
        // Coluna source é nullable? (FK nullable é OK — rejeita só valores não-NULL órfãos)
        let nullable: Bool
    }

    private var specs: [FKSpec] {
        [
            FKSpec(constraintName: "fk_patients_social_identity_type",
                   sourceTable: "patients", sourceColumn: "social_identity_type_id",
                   targetTable: "dominio_tipo_identidade", nullable: true),
            FKSpec(constraintName: "fk_patients_ii_ingress_type",
                   sourceTable: "patients", sourceColumn: "ii_ingress_type_id",
                   targetTable: "dominio_tipo_ingresso", nullable: true),
            FKSpec(constraintName: "fk_member_incomes_occupation",
                   sourceTable: "member_incomes", sourceColumn: "occupation_id",
                   targetTable: "dominio_condicao_ocupacao", nullable: false),
            FKSpec(constraintName: "fk_member_educational_profiles_education_level",
                   sourceTable: "member_educational_profiles", sourceColumn: "education_level_id",
                   targetTable: "dominio_escolaridade", nullable: false),
            FKSpec(constraintName: "fk_program_occurrences_effect",
                   sourceTable: "program_occurrences", sourceColumn: "effect_id",
                   targetTable: "dominio_efeito_condicionalidade", nullable: false),
            FKSpec(constraintName: "fk_member_deficiencies_deficiency_type",
                   sourceTable: "member_deficiencies", sourceColumn: "deficiency_type_id",
                   targetTable: "dominio_tipo_deficiencia", nullable: false),
            FKSpec(constraintName: "fk_ingress_linked_programs_program",
                   sourceTable: "ingress_linked_programs", sourceColumn: "program_id",
                   targetTable: "dominio_programa_social", nullable: false),
        ]
    }

    func prepare(on db: any SQLDatabase) async throws {
        // PASSO 1 — Pré-flight: para cada FK, detectar órfãos (linhas com
        // valor não-NULL que não tem alvo correspondente no lookup).
        for spec in specs {
            if let orphan = try await firstOrphan(on: db, spec: spec) {
                throw MigrationError.duplicatesFound(
                    table: spec.sourceTable,
                    example: "\(spec.sourceColumn)=\(orphan) sem alvo em \(spec.targetTable)",
                    hint: "Limpe ou ajuste a linha órfã antes de aplicar a FK. Ver SELECT de diagnóstico no comentário."
                )
            }
        }

        // PASSO 2 — Adicionar as 7 FKs.
        for spec in specs {
            try await db.raw("""
                ALTER TABLE \(raw: spec.sourceTable)
                ADD CONSTRAINT \(raw: spec.constraintName)
                FOREIGN KEY (\(raw: spec.sourceColumn))
                REFERENCES \(raw: spec.targetTable)(id)
                ON DELETE RESTRICT
            """).run()
        }
    }

    func revert(on db: any SQLDatabase) async throws {
        // Ordem inversa, IF EXISTS para idempotência.
        for spec in specs.reversed() {
            try await db.raw("""
                ALTER TABLE \(raw: spec.sourceTable)
                DROP CONSTRAINT IF EXISTS \(raw: spec.constraintName)
            """).run()
        }
    }

    // MARK: - Pré-flight helper

    /// Retorna o primeiro `id` órfão (existe na source mas não em target),
    /// ou `nil` se a coluna está íntegra. Ignora NULLs em colunas nullable.
    ///
    /// Diagnóstico operacional:
    /// ```sql
    /// SELECT s.<col> FROM <source> s
    ///   LEFT JOIN <target> t ON s.<col> = t.id
    ///   WHERE s.<col> IS NOT NULL AND t.id IS NULL
    ///   LIMIT 1;
    /// ```
    private func firstOrphan(on db: any SQLDatabase, spec: FKSpec) async throws -> String? {
        let nullClause = spec.nullable ? "AND s.\(spec.sourceColumn) IS NOT NULL" : ""
        let row = try await db.raw("""
            SELECT s.\(raw: spec.sourceColumn) AS orphan_id
              FROM \(raw: spec.sourceTable) s
              LEFT JOIN \(raw: spec.targetTable) t ON s.\(raw: spec.sourceColumn) = t.id
              WHERE t.id IS NULL \(raw: nullClause)
              LIMIT 1
        """).first()
        guard let row else { return nil }
        if let uuid = try? row.decode(column: "orphan_id", as: UUID.self) {
            return uuid.uuidString
        }
        return "<valor não-UUID>"
    }
}
