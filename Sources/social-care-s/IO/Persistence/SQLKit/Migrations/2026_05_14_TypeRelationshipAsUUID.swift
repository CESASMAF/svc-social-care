import Foundation
import SQLKit

/// Tipifica `family_members.relationship` como `UUID` + FK para `dominio_parentesco`.
///
/// **Achados:** DB-4 (Database Modeling Review) + S-H-D5 (Senior Code Review).
///
/// A coluna foi criada em `2026_02_24_CreateInitialSchema` como `TEXT`, mas o
/// valor sempre foi UUID stringificado de `dominio_parentesco.id`. Resultado:
/// banco aceita qualquer string (`"cônjuge"`, `"foo"`, UUID inválido) e nada
/// amarra o ID a um item de lookup válido. Ramakrishnan, Cap. 3.1 — Column
/// Domain: o tipo declarado deve corresponder ao significado do dado.
///
/// ## Estratégia: expand-contract
///
/// Migração não-destrutiva em 5 passos:
///
/// 1. **Add nova coluna** `relationship_id UUID NULL`.
/// 2. **Pré-flight**: detectar linhas com `relationship` que não é UUID válido
///    (mal-formado ou string livre). Aborta com mensagem útil — cleanup
///    manual exigido (princípio CRU/No Delete: não deletamos linhas).
/// 3. **Backfill**: `UPDATE family_members SET relationship_id = relationship::UUID`.
/// 4. **SET NOT NULL** + **ADD FOREIGN KEY** → `dominio_parentesco(id) ON DELETE RESTRICT`.
/// 5. **DROP coluna antiga** `relationship` (contract phase).
///
/// O revert recria a coluna `relationship TEXT` e backfilla com
/// `relationship_id::text`. ADR-006 pré-requisito (a PK composta de
/// `family_members` precisa existir para que UPDATE seja indexável).
///
/// ## Pré-flight: detecção de não-UUIDs
///
/// PostgreSQL regex `^[0-9a-f]{8}-...$` detecta UUIDs canônicos
/// (case-insensitive). Linhas que não casam são listadas para cleanup manual.
///
/// Ticket: T-007. ADR: ADR-007.
struct TypeRelationshipAsUUID: Migration {
    let name = "2026_05_14_TypeRelationshipAsUUID"

    func prepare(on db: any SQLDatabase) async throws {
        // PASSO 1 — Add coluna nova (nullable durante migração)
        try await db.raw("""
            ALTER TABLE family_members
            ADD COLUMN IF NOT EXISTS relationship_id UUID NULL
        """).run()

        // PASSO 2 — Pré-flight: rejeitar relationships não-UUID
        if let invalid = try await firstNonUUIDRelationship(on: db) {
            throw MigrationError.duplicatesFound(
                table: "family_members",
                example: "relationship='\(invalid)' não é UUID válido",
                hint: "Limpe ou converta manualmente: UPDATE family_members SET relationship='<uuid-real>' WHERE relationship='<string-livre>'."
            )
        }

        // PASSO 3 — Backfill
        try await db.raw("""
            UPDATE family_members
            SET relationship_id = relationship::UUID
            WHERE relationship_id IS NULL
        """).run()

        // PASSO 4a — SET NOT NULL
        try await db.raw("""
            ALTER TABLE family_members
            ALTER COLUMN relationship_id SET NOT NULL
        """).run()

        // PASSO 4b — FK para dominio_parentesco
        try await db.raw("""
            ALTER TABLE family_members
            ADD CONSTRAINT fk_family_member_relationship
            FOREIGN KEY (relationship_id)
            REFERENCES dominio_parentesco(id)
            ON DELETE RESTRICT
        """).run()

        // PASSO 5 — Contract: drop coluna antiga
        try await db.raw("""
            ALTER TABLE family_members
            DROP COLUMN IF EXISTS relationship
        """).run()
    }

    func revert(on db: any SQLDatabase) async throws {
        // Recriar coluna antiga
        try await db.raw("""
            ALTER TABLE family_members
            ADD COLUMN IF NOT EXISTS relationship TEXT
        """).run()

        // Backfill reverso: relationship_id::text → relationship
        try await db.raw("""
            UPDATE family_members
            SET relationship = relationship_id::text
            WHERE relationship IS NULL
        """).run()

        try await db.raw("""
            ALTER TABLE family_members
            ALTER COLUMN relationship SET NOT NULL
        """).run()

        // Drop FK e coluna nova
        try await db.raw("""
            ALTER TABLE family_members
            DROP CONSTRAINT IF EXISTS fk_family_member_relationship
        """).run()

        try await db.raw("""
            ALTER TABLE family_members
            DROP COLUMN IF EXISTS relationship_id
        """).run()
    }

    // MARK: - Pré-flight helper

    /// Retorna o primeiro valor de `relationship` que **não** é UUID canônico.
    /// `nil` significa todas as linhas estão prontas para o backfill.
    private func firstNonUUIDRelationship(on db: any SQLDatabase) async throws -> String? {
        // Regex Postgres: 8-4-4-4-12 hex chars (UUID v4 canônico, case-insensitive)
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        let row = try await db.raw("""
            SELECT relationship
              FROM family_members
              WHERE relationship !~* \(bind: pattern)
              LIMIT 1
        """).first()
        guard let row else { return nil }
        return try row.decode(column: "relationship", as: String.self)
    }
}
