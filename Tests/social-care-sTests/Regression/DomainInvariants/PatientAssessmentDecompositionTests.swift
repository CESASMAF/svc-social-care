import Testing
import Foundation
@testable import social_care_s

/// Suite de regressão — Achados S-H-D1 (Senior Code Review § D1) +
/// DB-7 (DB Modeling Review).
///
/// Pré-fix:
/// - `Patient` (aggregate root) carrega 8 módulos opcionais de Assessment
///   (`housingCondition?`, `socioeconomicSituation?`, `workAndIncome?`,
///   `educationalStatus?`, `healthStatus?`, `communitySupportNetwork?`,
///   `socialHealthSummary?`, ...).
/// - Tabela `patients` tem ~63 colunas dos 4 BCs colapsados — schema
///   reflete o god aggregate.
/// - Concorrência: dois profissionais editando módulos diferentes
///   competem pelo mesmo `version` do `Patient` inteiro — optimistic
///   lock falha sem conflito real.
/// - Save reescreve o agregado inteiro mesmo para update de 1 campo.
///
/// Fix (Fase 4 — ADR-019 + ADR-024):
///
/// **T-024.a (este ticket): EXPAND** — criar a infraestrutura nova SEM
/// remover a antiga. Estágio (a) do expand-contract de ADR-019.
///
/// 1. Domain: novo aggregate `PatientAssessment` em
///    `Sources/.../Domain/Assessment/Aggregate/`. Referencia
///    `patientId: PatientId` por identidade (Vernon Rule). Carrega os
///    7 módulos opcionais.
/// 2. Domain: protocolo `PatientAssessmentRepository` em
///    `Sources/.../Domain/Assessment/Repository/`.
/// 3. Persistence: tabela `patient_assessments(patient_id PK FK
///    REFERENCES patients(id), <colunas dos módulos>, version,
///    created_at, updated_at)` + trigger `touch_updated_at` (ADR-023).
/// 4. Persistence: `SQLKitPatientAssessmentRepository` em
///    `Sources/.../IO/Persistence/SQLKit/`.
/// 5. Migration: backfill idempotente — para cada paciente com algum
///    módulo preenchido, INSERT na tabela nova.
/// 6. Bootstrap: `ServiceContainer` instancia o novo repository.
///
/// **NÃO incluído neste PR (próximos sub-PRs / releases):**
/// - **(b) DUAL-WRITE**: handlers existentes ainda escrevem só em
///   `Patient.housingCondition` etc. Migrar handlers para também chamar
///   `PatientAssessmentRepository.save` é o próximo PR.
/// - **(c)+(d) CUTOVER**: leitura migrar para `patient_assessments`
///   (via `GetFullPatientProfileQuery` que faz JOIN).
/// - **(e) CONTRACT**: drop colunas `hc_*`/`csn_*`/`shs_*`/`ses_*` em
///   `patients`.
///
/// Este ticket apenas **prepara o terreno**. Backward compat preservada
/// 100% — nenhum handler ou query muda comportamento.
///
/// Suite cobre lints estruturais + sanity runtime do novo agregado.
@Suite("Regression: Domain Invariants — S-H-D1/DB-7 PatientAssessment decomposition (EXPAND)")
struct PatientAssessmentDecompositionTests {

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

    private func file(at path: String) -> URL {
        projectRoot().appendingPathComponent(path)
    }

    private func source(at path: String) -> String {
        (try? String(contentsOf: file(at: path), encoding: .utf8)) ?? ""
    }

    private func anyMigrationContains(_ needles: [String]) throws -> Bool {
        let dir = projectRoot()
            .appendingPathComponent("Sources/social-care-s/IO/Persistence/SQLKit/Migrations")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let needlesLower = needles.map(normalizeWhitespace)
        for f in files {
            let raw = (try? String(contentsOf: f, encoding: .utf8))?.lowercased() ?? ""
            let content = normalizeWhitespace(raw)
            if needlesLower.allSatisfy(content.contains) {
                return true
            }
        }
        return false
    }

    /// Lowercase + colapsa runs de whitespace (espaços múltiplos, tabs,
    /// newlines) em um único espaço. CREATE TABLE com colunas alinhadas
    /// tem padding visual que quebra `contains` literal.
    private func normalizeWhitespace(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        var lastWasSpace = false
        for ch in lower {
            if ch.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }

    // MARK: - Lints — Domain

    @Test("S-H-D1 — PatientAssessment aggregate existe em Domain/Assessment/Aggregate/")
    func test_S_H_D1_aggregate_exists() {
        let url = file(at: "Sources/social-care-s/Domain/Assessment/Aggregate/PatientAssessment.swift")
        #expect(FileManager.default.fileExists(atPath: url.path),
                "S-H-D1: Domain/Assessment/Aggregate/PatientAssessment.swift não existe — pré-requisito da decomposição da Fase 4.")
    }

    @Test("S-H-D1 — PatientAssessment é struct + EventSourcedAggregate")
    func test_S_H_D1_aggregate_conforms() {
        let src = source(at: "Sources/social-care-s/Domain/Assessment/Aggregate/PatientAssessment.swift")
        #expect(src.contains("public struct PatientAssessment"),
                "S-H-D1: PatientAssessment não é declarado como `public struct` (regra do projeto: agregados são struct Sendable).")
        #expect(src.contains("EventSourcedAggregate"),
                "S-H-D1: PatientAssessment não conforma EventSourcedAggregate — Outbox Pattern não funciona.")
    }

    @Test("S-H-D1 — PatientAssessment referencia patientId por identidade (não compõe Patient)")
    func test_S_H_D1_aggregate_references_by_id() {
        let src = source(at: "Sources/social-care-s/Domain/Assessment/Aggregate/PatientAssessment.swift")
        #expect(src.contains("let patientId: PatientId") || src.contains("public let patientId: PatientId"),
                "S-H-D1: PatientAssessment não declara `patientId: PatientId` — Vernon Rule (referenciar outro agregado por identidade) violada.")
        // NÃO compor `Patient` — checa apenas linhas de código, ignora comentários.
        let nonCommentLines = src.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//")
        }.joined(separator: "\n")
        #expect(!nonCommentLines.contains(": Patient,") && !nonCommentLines.contains(": Patient\n") && !nonCommentLines.contains("var patient: Patient"),
                "S-H-D1: PatientAssessment compõe `Patient` (anti-pattern: agregados não compõem outros agregados).")
    }

    @Test("S-H-D1 — PatientAssessment carrega os 7 módulos opcionais")
    func test_S_H_D1_aggregate_carries_modules() {
        let src = source(at: "Sources/social-care-s/Domain/Assessment/Aggregate/PatientAssessment.swift")
        let modules = [
            "housingCondition",
            "socioeconomicSituation",
            "workAndIncome",
            "educationalStatus",
            "healthStatus",
            "communitySupportNetwork",
            "socialHealthSummary"
        ]
        let missing = modules.filter { !src.contains($0) }
        #expect(missing.isEmpty,
                "S-H-D1: PatientAssessment não declara módulos: \(missing).")
    }

    @Test("S-H-D1 — PatientAssessmentRepository protocol existe")
    func test_S_H_D1_repository_protocol_exists() {
        let url = file(at: "Sources/social-care-s/Domain/Assessment/Repository/PatientAssessmentRepository.swift")
        #expect(FileManager.default.fileExists(atPath: url.path),
                "S-H-D1: Domain/Assessment/Repository/PatientAssessmentRepository.swift não existe.")
        let src = source(at: "Sources/social-care-s/Domain/Assessment/Repository/PatientAssessmentRepository.swift")
        #expect(src.contains("public protocol PatientAssessmentRepository"),
                "S-H-D1: PatientAssessmentRepository não é declarado como public protocol.")
        #expect(src.contains("save"),
                "S-H-D1: PatientAssessmentRepository não declara método `save`.")
        #expect(src.contains("find"),
                "S-H-D1: PatientAssessmentRepository não declara método `find`.")
    }

    // MARK: - Lints — Persistence

    @Test("S-H-D1 — SQLKitPatientAssessmentRepository existe")
    func test_S_H_D1_sqlkit_repo_exists() {
        let url = file(at: "Sources/social-care-s/IO/Persistence/SQLKit/SQLKitPatientAssessmentRepository.swift")
        #expect(FileManager.default.fileExists(atPath: url.path),
                "S-H-D1: SQLKitPatientAssessmentRepository.swift não existe.")
    }

    // MARK: - Lints — Migration

    @Test("DB-7 — migration cria tabela patient_assessments")
    func test_DB_7_table_exists() throws {
        let exists = try anyMigrationContains([
            "create table patient_assessments",
            "patient_id"
        ])
        #expect(exists,
                "DB-7: nenhuma migration cria CREATE TABLE patient_assessments.")
    }

    @Test("DB-7 — patient_assessments tem PK + FK em patient_id REFERENCES patients(id)")
    func test_DB_7_table_pk_fk() throws {
        let exists = try anyMigrationContains([
            "patient_assessments",
            "patient_id uuid",
            "primary key",
            "references patients(id)"
        ])
        #expect(exists,
                "DB-7: patient_assessments sem PK + FK declaradas para patients(id).")
    }

    @Test("DB-7 — patient_assessments tem version + created_at + updated_at")
    func test_DB_7_table_temporal_columns() throws {
        let hasVersion = try anyMigrationContains([
            "create table patient_assessments",
            "version"
        ])
        let hasTemporal = try anyMigrationContains([
            "create table patient_assessments",
            "created_at timestamptz",
            "updated_at timestamptz"
        ])
        #expect(hasVersion,
                "DB-7: patient_assessments sem coluna version (optimistic lock).")
        #expect(hasTemporal,
                "DB-7: patient_assessments sem created_at/updated_at TIMESTAMPTZ (ADR-023).")
    }

    @Test("DB-7 — migration faz backfill idempotente (INSERT ... SELECT FROM patients ...)")
    func test_DB_7_backfill_idempotent() throws {
        let exists = try anyMigrationContains([
            "patient_assessments",
            "insert into patient_assessments",
            "select",
            "from patients",
            "on conflict"
        ])
        #expect(exists,
                "DB-7: migration sem backfill idempotente (INSERT ... SELECT ... ON CONFLICT).")
    }

    @Test("DB-7 — patient_assessments tem trigger ON UPDATE para updated_at")
    func test_DB_7_table_trigger() throws {
        let exists = try anyMigrationContains([
            "create trigger patient_assessments_updated_at",
            "before update on patient_assessments",
            "execute function touch_updated_at"
        ])
        #expect(exists,
                "DB-7: patient_assessments sem TRIGGER BEFORE UPDATE EXECUTE FUNCTION touch_updated_at() (ADR-023).")
    }

    // MARK: - Sanity runtime

    @Test("S-H-D1 — PatientAssessment construtível com módulos vazios")
    func test_S_H_D1_aggregate_buildable_empty() throws {
        let pid = try PatientId()
        let assessment = PatientAssessment(patientId: pid)
        #expect(assessment.patientId == pid)
        #expect(assessment.housingCondition == nil)
        #expect(assessment.uncommittedEvents.isEmpty)
        #expect(assessment.version == 0)
    }
}
