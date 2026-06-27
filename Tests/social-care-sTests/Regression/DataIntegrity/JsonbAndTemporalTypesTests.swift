import Testing
import Foundation
@testable import social_care_s

/// Suite de regressão — Achados S-H-P7 (Senior Code Review § P7) +
/// DB-9, DB-10, DB-16 (DB Modeling Review).
///
/// Pré-fix:
/// 1. **DB-9** — `outbox_messages.payload` e `audit_trail.payload` foram
///    convertidos para TEXT em `ConvertJsonbToText` (2026-03-13) para
///    contornar mismatch de bind do PostgresKit. Custo: queries
///    `WHERE payload->>'eventType' = 'X'` deixam de ser indexáveis;
///    operadores JSONB (`->`, `->>`, `@>`) não funcionam em TEXT.
/// 2. **DB-10** — várias colunas usam `TIMESTAMP` (sem timezone). PostgreSQL
///    armazena sem TZ assumindo o TZ do servidor, causando ambiguidade em
///    deploy multi-região e em migração entre staging (UTC) e prod (BRT).
/// 3. **DB-16** — colunas que carregam **data conceitual** (sem hora) como
///    `birth_date`, `rg_issue_date` usam `TIMESTAMP`. Confunde o domínio
///    (TimeStamp tem hora; data de nascimento não tem).
/// 4. **S-H-P7** — JSON encoder ad-hoc em vários lugares com
///    `dateEncodingStrategy` default (`.deferredToDate` = Double desde
///    2001). Audit trail mistura formatos.
///
/// Fix (ADR-022):
/// 1. Migration `2026_05_14_RestoreJsonbAndTemporalTypes`:
///    - `outbox_messages.payload` + `audit_trail.payload` → JSONB.
///    - Colunas operacionais → TIMESTAMPTZ.
///    - Colunas conceituais (`birth_date`, `rg_issue_date`,
///      `patient_diagnoses.date`) → DATE.
/// 2. Helper `shared/JSON/JSONCodec.swift` com encoder/decoder padronizado
///    (`dateEncodingStrategy = .iso8601`, `dataEncodingStrategy = .base64`).
/// 3. Repository INSERT no outbox usa cast `::jsonb` explícito no SQL raw
///    (PostgresKit envia String; coluna espera JSONB).
@Suite("Regression: Data Integrity — S-H-P7/DB-9/DB-10/DB-16 JSONB + temporal types")
struct JsonbAndTemporalTypesTests {

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

    // MARK: - Lints — migration

    @Test("DB-9 — migration restaura outbox_messages.payload para JSONB")
    func test_DB_9_outbox_payload_jsonb() throws {
        let exists = try anyMigrationContains([
            "alter table outbox_messages",
            "alter column payload",
            "type jsonb"
        ])
        #expect(exists,
                "DB-9: nenhuma migration converte outbox_messages.payload para JSONB. Operadores `->`/`->>` indexáveis ficam indisponíveis em TEXT.")
    }

    @Test("DB-9 — migration restaura audit_trail.payload para JSONB")
    func test_DB_9_audit_payload_jsonb() throws {
        let exists = try anyMigrationContains([
            "alter table audit_trail",
            "alter column payload",
            "type jsonb"
        ])
        #expect(exists,
                "DB-9: nenhuma migration converte audit_trail.payload para JSONB.")
    }

    @Test("DB-10 — migração de colunas TIMESTAMP para TIMESTAMPTZ existe")
    func test_DB_10_timestamptz_migration_exists() throws {
        // Heurística: alguma migration usa AT TIME ZONE para fazer
        // promoção segura de TIMESTAMP → TIMESTAMPTZ.
        let exists = try anyMigrationContains([
            "type timestamptz",
            "at time zone"
        ])
        #expect(exists,
                "DB-10: nenhuma migration promove colunas TIMESTAMP → TIMESTAMPTZ com AT TIME ZONE.")
    }

    @Test("DB-16 — migration converte birth_date para DATE")
    func test_DB_16_birth_date_to_date() throws {
        let exists = try anyMigrationContains([
            "alter column birth_date",
            "type date"
        ])
        #expect(exists,
                "DB-16: nenhuma migration converte birth_date para DATE — continua TIMESTAMP (com hora 00:00 espúria).")
    }

    @Test("DB-16 — migration converte rg_issue_date para DATE")
    func test_DB_16_rg_issue_date_to_date() throws {
        let exists = try anyMigrationContains([
            "alter column rg_issue_date",
            "type date"
        ])
        #expect(exists,
                "DB-16: nenhuma migration converte rg_issue_date para DATE.")
    }

    @Test("DB-16 — migration converte patient_diagnoses.date para DATE")
    func test_DB_16_diagnosis_date_to_date() throws {
        // Diagnóstico tem data conceitual (dia que o médico atribuiu),
        // não instante. Coluna `date` em patient_diagnoses → DATE.
        let exists = try anyMigrationContains([
            "alter table patient_diagnoses",
            "alter column date",
            "type date"
        ])
        #expect(exists,
                "DB-16: nenhuma migration converte patient_diagnoses.date para DATE.")
    }

    // MARK: - Lints — JSONCodec helper

    @Test("S-H-P7 — JSONCodec helper existe em shared/JSON/")
    func test_S_H_P7_jsoncodec_exists() {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/shared/JSON/JSONCodec.swift")
        #expect(FileManager.default.fileExists(atPath: url.path),
                "S-H-P7: shared/JSON/JSONCodec.swift não existe. Necessário para encoder/decoder padronizado com .iso8601.")
    }

    @Test("S-H-P7 — JSONCodec expõe encoder/decoder padronizados")
    func test_S_H_P7_jsoncodec_api() {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/shared/JSON/JSONCodec.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lower = source.lowercased()
        #expect(lower.contains("jsoncodec"),
                "S-H-P7: arquivo não declara enum/struct JSONCodec.")
        #expect(source.contains(".iso8601"),
                "S-H-P7: JSONCodec não força dateEncoding/Decoding = .iso8601 — encoder default usa Double (.deferredToDate) que confunde audit trail.")
        #expect(lower.contains("encoder") && lower.contains("decoder"),
                "S-H-P7: JSONCodec deve expor encoder e decoder.")
    }

    // MARK: - Sanity runtime

    @Test("S-H-P7 — JSONCodec encode/decode preserva Date com .iso8601")
    func test_S_H_P7_jsoncodec_iso8601_round_trip() throws {
        struct Sample: Codable, Equatable {
            let label: String
            let when: Date
        }
        let original = Sample(label: "audit", when: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONCodec.encoder.encode(original)
        // Sanity: a representação deve ser ISO 8601 string, não Double.
        let asString = String(data: data, encoding: .utf8) ?? ""
        #expect(asString.contains("2023-"),
                "S-H-P7: JSON encoder não está usando .iso8601 — Date saiu como número/Double. Verifique JSONCodec.encoder.")

        let decoded = try JSONCodec.decoder.decode(Sample.self, from: data)
        #expect(decoded == original,
                "S-H-P7: round-trip JSONCodec não preservou Sample (encoder e decoder devem ser simétricos).")
    }

    @Test("DB-9 — repository INSERT outbox usa cast ::jsonb no SQL")
    func test_DB_9_repo_inserts_jsonb_with_cast() {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/IO/Persistence/SQLKit/SQLKitPatientRepository.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // Pré-fix usava `tx.insert(into: "outbox_messages").model(message)` —
        // PostgresKit envia String e a coluna agora é JSONB → erro de tipo.
        // Pós-fix: SQL raw com `?::jsonb` explícito no payload.
        #expect(source.contains("::jsonb"),
                "DB-9: repository INSERT outbox não usa cast ::jsonb explícito. Bind String → coluna JSONB falha.")
    }
}
