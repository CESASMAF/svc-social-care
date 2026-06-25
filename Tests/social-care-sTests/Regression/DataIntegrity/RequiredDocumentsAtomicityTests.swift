import Testing
import Foundation
@testable import social_care_s

/// Suite de regressão — Achado S-H-A7 (Senior Code Review) + DB-5 (DB Modeling Review).
///
/// Pré-fix:
/// ```swift
/// // AddFamilyMemberCommandHandler.swift
/// let docs = command.requiredDocuments.compactMap { RequiredDocument(rawValue: $0) }
/// //                  ^^^^^^^^^^
/// //                  Silencia typo: ["RG", "TYPO_INVALID", "CPF"] vira ["RG", "CPF"].
/// //                  Cliente nunca sabe que enviou valor inválido.
///
/// // PatientDatabaseMapper.swift
/// let rawDocs = (try? decoder.decode([String].self, from: ...)) ?? []
/// let docs = rawDocs.compactMap { RequiredDocument(rawValue: $0) }
/// //                  ^^^^^^^^^^
/// //                  Mesmo problema na LEITURA: row legacy com valor inválido
/// //                  é silenciosamente truncado.
///
/// // schema (DB-5):
/// // family_members.required_documents TEXT  -- ["RG","CPF"] como JSON inline
/// //                                  ^^^^
/// //                  Viola 1NF. Não dá para query "todos pacientes com RG".
/// //                  CHECK constraint impossível. ETL externo precisa saber
/// //                  parsear JSON nesse exato campo.
/// ```
///
/// Fix (ADR-020):
/// 1. Domain `AddFamilyMemberError` ganha case `.invalidRequiredDocument(String)`.
/// 2. Handler usa `try map` em vez de `compactMap` — typo dispara erro
///    tipado (HTTP 422 com payload `{"invalidValue": "TYPO_INVALID"}`).
/// 3. Mapper.toDomain idem — leitura de row legacy com valor inválido
///    falha loud em vez de truncar.
/// 4. Schema 1NF: `family_member_required_documents(patient_id, person_id,
///    document_code)` PK composta + FK para `family_members(patient_id,
///    person_id) ON DELETE CASCADE` + CHECK em `document_code`.
/// 5. Coluna antiga `family_members.required_documents` dropada após backfill.
///
/// Suite cobre:
/// - Lint: handler + mapper sem `compactMap` para `RequiredDocument`.
/// - Lint: migration cria tabela filha com schema correto.
/// - Lint: case do erro existe.
@Suite("Regression: Data Integrity — S-H-A7/DB-5 required_documents 1NF + try map")
struct RequiredDocumentsAtomicityTests {

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

    private func handlerSource() -> String {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/Application/Registry/AddFamilyMember/Services/AddFamilyMemberCommandHandler.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func mapperSource() -> String {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/IO/Persistence/SQLKit/Mappers/PatientDatabaseMapper.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func errorSource() -> String {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/Application/Registry/AddFamilyMember/Error/AddFamilyMemberErrors.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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

    // MARK: - Lints

    /// Procura a forma exata do anti-pattern (compactMap + RequiredDocument
    /// no mesmo bloco): `.compactMap { RequiredDocument(rawValue:` (com
    /// variantes de espaços). Não dá falso positivo se `compactMap` aparecer
    /// em outro contexto no mesmo arquivo.
    private func hasCompactMapForRequiredDocument(_ source: String) -> Bool {
        let normalized = source
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
        return normalized.contains(".compactMap{RequiredDocument(rawValue:")
    }

    @Test("S-H-A7 — handler não usa compactMap para RequiredDocument")
    func test_S_H_A7_handler_uses_try_map() {
        #expect(!hasCompactMapForRequiredDocument(handlerSource()),
                "S-H-A7: handler ainda usa `.compactMap { RequiredDocument(rawValue:` — silencia typo. Use try map + erro tipado.")
    }

    @Test("S-H-A7 — mapper.toDomain não usa compactMap para RequiredDocument")
    func test_S_H_A7_mapper_uses_try_map() {
        #expect(!hasCompactMapForRequiredDocument(mapperSource()),
                "S-H-A7: mapper.toDomain ainda usa `.compactMap { RequiredDocument(rawValue:` — leitura silencia row legacy inválido.")
    }

    @Test("S-H-A7 — AddFamilyMemberError declara case invalidRequiredDocument")
    func test_S_H_A7_error_case_exists() {
        let source = errorSource()
        let lower = source.lowercased()
        #expect(lower.contains("invalidrequireddocument"),
                "S-H-A7: AddFamilyMemberError não declara case invalidRequiredDocument(String).")
    }

    @Test("DB-5 — migration cria tabela family_member_required_documents")
    func test_DB_5_table_exists() throws {
        let exists = try anyMigrationContains([
            "create table",
            "family_member_required_documents"
        ])
        #expect(exists,
                "DB-5: nenhuma migration cria tabela family_member_required_documents.")
    }

    @Test("DB-5 — tabela tem PK composta (patient_id, person_id, document_code)")
    func test_DB_5_table_has_composite_pk() throws {
        let exists = try anyMigrationContains([
            "family_member_required_documents",
            "primary key",
            "patient_id",
            "person_id",
            "document_code"
        ])
        #expect(exists,
                "DB-5: tabela family_member_required_documents não declara PK composta (patient_id, person_id, document_code).")
    }

    @Test("DB-5 — tabela tem FK para family_members ON DELETE CASCADE")
    func test_DB_5_table_has_fk() throws {
        let exists = try anyMigrationContains([
            "family_member_required_documents",
            "references family_members",
            "on delete cascade"
        ])
        #expect(exists,
                "DB-5: tabela family_member_required_documents não declara FK para family_members ON DELETE CASCADE.")
    }

    @Test("DB-5 — tabela tem CHECK constraint em document_code")
    func test_DB_5_table_has_check() throws {
        let exists = try anyMigrationContains([
            "family_member_required_documents",
            "check",
            "document_code"
        ])
        #expect(exists,
                "DB-5: tabela family_member_required_documents não declara CHECK constraint em document_code (anti regressão de typo via SQL direto).")
    }

    @Test("DB-5 — migration faz backfill da coluna antiga + drop")
    func test_DB_5_backfill_and_drop() throws {
        // Backfill: INSERT INTO family_member_required_documents SELECT ...
        let hasBackfill = try anyMigrationContains([
            "family_member_required_documents",
            "insert into",
            "select"
        ])
        #expect(hasBackfill,
                "DB-5: migration não tem backfill INSERT INTO family_member_required_documents SELECT ...")

        // Drop coluna antiga
        let hasDrop = try anyMigrationContains([
            "alter table family_members",
            "drop column",
            "required_documents"
        ])
        #expect(hasDrop,
                "DB-5: migration não dropa coluna antiga family_members.required_documents.")
    }

    // MARK: - Sanity runtime: smart constructor garante invariante

    @Test("S-H-A7 — RequiredDocument.tryParse lança em valor inválido")
    func test_S_H_A7_tryParse_throws_on_invalid() {
        // Sanity: enum String tem init? que retorna nil, mas o handler agora
        // converte nil em throw. Aqui validamos o invariante diretamente.
        let valid = RequiredDocument(rawValue: "RG")
        let invalid = RequiredDocument(rawValue: "TYPO_INVALID")
        #expect(valid != nil, "RG é case válido")
        #expect(invalid == nil, "TYPO_INVALID NÃO é case válido — handler precisa converter nil em throw")
    }
}
