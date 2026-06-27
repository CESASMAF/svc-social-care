import Testing
import Foundation
@testable import social_care_s

/// Suite de regressão — Achados S-H-P1 (Senior Code Review § P1) + DB-6
/// (DB Modeling Review).
///
/// Pré-fix:
/// ```swift
/// // PatientDatabaseMapper.swift — pré-fix
/// let diagnoses = patient.diagnoses.map { d in
///     DiagnosisModel(
///         id: UUID(),  // ← NOVO UUID a cada save
///         patient_id: patientId,
///         icd_code: d.id.value,
///         ...
///     )
/// }
///
/// // SQLKitPatientRepository.swift — pré-fix
/// try await deleteAndInsert(tx, table: "patient_diagnoses", patientId: patientId, models: data.diagnoses)
/// // DELETE FROM patient_diagnoses WHERE patient_id = ?
/// // INSERT cada row com id NOVO  ← identidade física destruída a cada save
/// ```
///
/// Efeitos colaterais do anti-pattern:
/// 1. **Audit trail mente** — ID de `patient_diagnoses` muda a cada save,
///    mesmo que o diagnóstico semanticamente seja o mesmo. Quem audita não
///    consegue rastrear "este diagnóstico ao longo do tempo".
/// 2. **Triggers `ON UPDATE` nunca disparam** — sempre INSERT, nunca UPDATE.
///    `updated_at` automático fica congelado.
/// 3. **FKs externas viáveis ficam impossíveis** — uma tabela futura
///    `diagnosis_attachments(diagnosis_id, ...)` referenciaria um ID que
///    pode mudar entre saves; FK quebraria.
/// 4. **Replicação row-based fica não-determinística** — cada save é
///    DELETE+INSERT de N rows; logical replication consome muito mais
///    eventos do que necessário.
///
/// Fix (ADR-021):
/// 1. Helper `DeterministicUUID.from(_ key: String) -> UUID` em
///    `shared/Crypto/` — SHA256 dos primeiros 16 bytes (RFC 4122 UUIDv8
///    bits ajustados). Mesmas inputs → mesmo UUID.
/// 2. Mapper deriva `id` deterministicamente de chave natural do domínio
///    (`patient_id|<descriminador-natural>`). NUNCA `UUID()` inline.
/// 3. Repository: `deleteAndInsert` substituído por `upsertChildren` que
///    faz diff: SELECT existing IDs → calcula `toDelete = existing -
///    desired` → DELETE só removidos → INSERT cada desired com ON CONFLICT
///    (chave) DO UPDATE SET excluded.*.
///
/// Suite cobre:
/// - Lint: mapper sem `UUID()` em construção de model com id surrogate.
/// - Lint: helper `DeterministicUUID` existe.
/// - Lint: repository tem método `upsertChildren` (não só `deleteAndInsert`).
/// - Runtime: `DeterministicUUID.from` é determinístico (mesma chave →
///   mesmo UUID; chaves diferentes → UUIDs diferentes).
/// - Runtime: `PatientDatabaseMapper.toDatabase` chamado duas vezes no
///   mesmo Patient produz **mesmos IDs** em diagnoses (e demais filhas
///   com surrogate ID).
@Suite("Regression: Domain Invariants — S-H-P1/DB-6 child identity preserved across saves")
struct ChildIdentityPreservedTests {

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

    private func mapperSource() -> String {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/IO/Persistence/SQLKit/Mappers/PatientDatabaseMapper.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func repoSource() -> String {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/IO/Persistence/SQLKit/SQLKitPatientRepository.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func deterministicUUIDFile() -> URL {
        projectRoot()
            .appendingPathComponent("Sources/social-care-s/shared/Crypto/DeterministicUUID.swift")
    }

    // MARK: - Lints estruturais

    @Test("S-H-P1 — DeterministicUUID helper existe em shared/Crypto/")
    func test_S_H_P1_helper_exists() {
        let url = deterministicUUIDFile()
        #expect(FileManager.default.fileExists(atPath: url.path),
                "S-H-P1: shared/Crypto/DeterministicUUID.swift não existe — necessário para derivar IDs estáveis no mapper.")
    }

    @Test("S-H-P1 — DeterministicUUID expõe API from(_ key: String)")
    func test_S_H_P1_helper_exposes_from() {
        let url = deterministicUUIDFile()
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lower = source.lowercased()
        #expect(lower.contains("deterministicuuid"),
                "S-H-P1: arquivo não declara enum/struct DeterministicUUID.")
        #expect(source.contains("static func from"),
                "S-H-P1: DeterministicUUID não expõe método estático `from(_:)`.")
        #expect(lower.contains("sha256") || lower.contains("hashedstring"),
                "S-H-P1: DeterministicUUID deve usar SHA256 (ou similar criptográfico) para derivar bytes do UUID.")
    }

    @Test("S-H-P1 — mapper não tem `id: UUID()` (anti-pattern de id surrogate volátil)")
    func test_S_H_P1_mapper_no_inline_uuid_for_id() {
        let source = mapperSource()
        // Conta ocorrências da forma exata `id: UUID(),` que aparece em
        // construção de model com PK surrogate. Não tem falso positivo
        // porque o mapper não cria UUIDs para outros propósitos —
        // identidades vêm do domínio (`UUID(uuidString: x.id.description)`).
        let occurrences = source.components(separatedBy: "id: UUID(),").count - 1
        #expect(occurrences == 0,
                "S-H-P1: mapper tem \(occurrences) ocorrência(s) de `id: UUID(),` — gera ID novo a cada save (identidade física destruída). Use DeterministicUUID.from(\"<table>|<chave-natural>\").")
    }

    @Test("S-H-P1/DB-6 — repository declara upsertChildren (diff-based)")
    func test_S_H_P1_repo_has_upsert() {
        let source = repoSource()
        let lower = source.lowercased()
        #expect(lower.contains("upsertchildren") || lower.contains("upsertchild") || lower.contains("upsert("),
                "S-H-P1/DB-6: SQLKitPatientRepository não declara helper de upsert (diff + ON CONFLICT). Delete-and-insert ainda é o único caminho.")
    }

    @Test("S-H-P1/DB-6 — repository chama ON CONFLICT na cláusula SQL (diff-based upsert)")
    func test_S_H_P1_repo_uses_on_conflict() {
        let source = repoSource()
        let lower = source.lowercased()
        #expect(lower.contains("on conflict"),
                "S-H-P1/DB-6: repository não usa ON CONFLICT no SQL — diff-based upsert exige UPSERT atômico via INSERT ... ON CONFLICT (...) DO UPDATE.")
    }

    // MARK: - Sanity runtime

    @Test("S-H-P1 — DeterministicUUID.from é determinístico")
    func test_S_H_P1_helper_is_deterministic() {
        let a = DeterministicUUID.from("patient_diagnoses|abc|CID-X|2025-01-01")
        let b = DeterministicUUID.from("patient_diagnoses|abc|CID-X|2025-01-01")
        let c = DeterministicUUID.from("patient_diagnoses|abc|CID-Y|2025-01-01")
        #expect(a == b, "DeterministicUUID com mesma chave DEVE retornar mesmo UUID")
        #expect(a != c, "DeterministicUUID com chaves diferentes DEVE retornar UUIDs diferentes")
    }

    @Test("S-H-P1 — mapper.toDatabase produz IDs determinísticos para o mesmo Patient")
    func test_S_H_P1_mapper_is_deterministic() throws {
        let patient = try PatientFixture.createMinimal()

        let snap1 = try PatientDatabaseMapper.toDatabase(patient)
        let snap2 = try PatientDatabaseMapper.toDatabase(patient)

        let ids1 = snap1.diagnoses.map(\.id).sorted()
        let ids2 = snap2.diagnoses.map(\.id).sorted()

        #expect(ids1 == ids2,
                "S-H-P1: mapper.toDatabase produziu IDs DIFERENTES para o mesmo Patient em chamadas consecutivas — identidade física destruída a cada save. Use DeterministicUUID.from(...).")
    }
}
