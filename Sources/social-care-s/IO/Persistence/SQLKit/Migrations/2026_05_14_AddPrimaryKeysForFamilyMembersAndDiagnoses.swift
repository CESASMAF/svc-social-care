import Foundation
import SQLKit

/// Adiciona chaves primárias em `family_members` e `patient_diagnoses` (DB-1).
///
/// Estas duas tabelas foram criadas em `2026_02_24_CreateInitialSchema` sem PK
/// — funcionavam porque o ORM amarrava por `patient_id` na via canônica, mas
/// **não eram relações** no sentido formal (Ramakrishnan & Gehrke, Cap. 3).
/// Importação direta via SQL ou ETL podia inserir duplicatas idênticas;
/// tabelas filhas futuras não conseguiam declarar FK para `family_members`;
/// replicação row-based ficava indeterminística.
///
/// **family_members:** PK natural composta `(patient_id, person_id)`. Reflete
/// exatamente o `==` do domínio (`FamilyMember.swift` define igualdade por
/// `personId`) e habilita FK composta para tabelas filhas (`member_incomes`,
/// `member_educational_profiles`, etc. — tickets T-007 e T-013).
///
/// **patient_diagnoses:** PK surrogate `id UUID` (`gen_random_uuid()`) +
/// UNIQUE natural `(patient_id, icd_code, date)`. Surrogate permite que
/// outras tabelas referenciem um diagnóstico específico; UNIQUE preserva
/// a invariante "um diagnóstico por CID/data por paciente".
///
/// ## Pré-flight: detecção de duplicatas
///
/// A migration é **fail-safe**: se houver duplicatas pré-existentes (raro,
/// mas possível em dev/staging), aborta com mensagem útil sem aplicar a PK.
/// Cleanup manual é exigido — não fazemos DELETE automático porque o
/// histórico social é sagrado (princípio CRU/No Delete).
///
/// Comandos de diagnóstico para o operador:
///
/// ```sql
/// -- Duplicatas em family_members
/// SELECT patient_id, person_id, COUNT(*)
///   FROM family_members
///   GROUP BY patient_id, person_id
///   HAVING COUNT(*) > 1;
///
/// -- Duplicatas em patient_diagnoses
/// SELECT patient_id, icd_code, date, COUNT(*)
///   FROM patient_diagnoses
///   GROUP BY patient_id, icd_code, date
///   HAVING COUNT(*) > 1;
/// ```
///
/// Ticket: T-006. ADR: ADR-006.
struct AddPrimaryKeysForFamilyMembersAndDiagnoses: Migration {
    let name = "2026_05_14_AddPrimaryKeysForFamilyMembersAndDiagnoses"

    func prepare(on db: any SQLDatabase) async throws {
        // PASSO 1 — Pré-flight: abortar se houver duplicatas.

        if let dups = try await firstDuplicateInFamilyMembers(on: db) {
            throw MigrationError.duplicatesFound(
                table: "family_members",
                example: dups,
                hint: "Execute o SELECT de diagnóstico no comentário da migration e limpe duplicatas antes de aplicar."
            )
        }

        if let dups = try await firstDuplicateInPatientDiagnoses(on: db) {
            throw MigrationError.duplicatesFound(
                table: "patient_diagnoses",
                example: dups,
                hint: "Execute o SELECT de diagnóstico no comentário da migration e limpe duplicatas antes de aplicar."
            )
        }

        // PASSO 2 — family_members: PK composta (patient_id, person_id).

        try await db.raw("""
            ALTER TABLE family_members
            ADD CONSTRAINT family_members_pkey PRIMARY KEY (patient_id, person_id)
        """).run()

        // PASSO 3 — patient_diagnoses: surrogate id + PK + UNIQUE natural.

        try await db.raw("""
            ALTER TABLE patient_diagnoses
            ADD COLUMN id UUID NOT NULL DEFAULT gen_random_uuid()
        """).run()

        try await db.raw("""
            ALTER TABLE patient_diagnoses
            ADD CONSTRAINT patient_diagnoses_pkey PRIMARY KEY (id)
        """).run()

        try await db.raw("""
            ALTER TABLE patient_diagnoses
            ADD CONSTRAINT uq_patient_diagnosis UNIQUE (patient_id, icd_code, date)
        """).run()
    }

    func revert(on db: any SQLDatabase) async throws {
        // patient_diagnoses
        try await db.raw("""
            ALTER TABLE patient_diagnoses
            DROP CONSTRAINT IF EXISTS uq_patient_diagnosis
        """).run()
        try await db.raw("""
            ALTER TABLE patient_diagnoses
            DROP CONSTRAINT IF EXISTS patient_diagnoses_pkey
        """).run()
        try await db.raw("""
            ALTER TABLE patient_diagnoses
            DROP COLUMN IF EXISTS id
        """).run()

        // family_members
        try await db.raw("""
            ALTER TABLE family_members
            DROP CONSTRAINT IF EXISTS family_members_pkey
        """).run()
    }

    // MARK: - Pré-flight helpers

    /// Retorna a primeira duplicata encontrada em `(patient_id, person_id)`,
    /// como string para logging. `nil` significa zero duplicatas.
    private func firstDuplicateInFamilyMembers(on db: any SQLDatabase) async throws -> String? {
        let row = try await db.raw("""
            SELECT patient_id, person_id, COUNT(*) AS occurrences
              FROM family_members
              GROUP BY patient_id, person_id
              HAVING COUNT(*) > 1
              LIMIT 1
        """).first()
        guard let row else { return nil }
        let patientId = try row.decode(column: "patient_id", as: UUID.self)
        let personId = try row.decode(column: "person_id", as: UUID.self)
        let count = try row.decode(column: "occurrences", as: Int.self)
        return "patient_id=\(patientId), person_id=\(personId) (\(count) ocorrências)"
    }

    /// Retorna a primeira duplicata em `(patient_id, icd_code, date)`.
    private func firstDuplicateInPatientDiagnoses(on db: any SQLDatabase) async throws -> String? {
        let row = try await db.raw("""
            SELECT patient_id, icd_code, date, COUNT(*) AS occurrences
              FROM patient_diagnoses
              GROUP BY patient_id, icd_code, date
              HAVING COUNT(*) > 1
              LIMIT 1
        """).first()
        guard let row else { return nil }
        let patientId = try row.decode(column: "patient_id", as: UUID.self)
        let icdCode = try row.decode(column: "icd_code", as: String.self)
        let count = try row.decode(column: "occurrences", as: Int.self)
        return "patient_id=\(patientId), icd_code=\(icdCode) (\(count) ocorrências)"
    }
}

/// Erro estruturado para migrations que requerem pré-flight check.
///
/// Local a esta migration por enquanto. Se outras migrations adotarem o
/// padrão de pré-flight (provável em T-008 quando FKs forem declaradas),
/// promover para `shared/Error/`.
enum MigrationError: Error, CustomStringConvertible {
    case duplicatesFound(table: String, example: String, hint: String)

    var description: String {
        switch self {
        case .duplicatesFound(let table, let example, let hint):
            return "Migration abortada: duplicatas em '\(table)' impedem ADD PRIMARY KEY. Exemplo: \(example). \(hint)"
        }
    }
}
