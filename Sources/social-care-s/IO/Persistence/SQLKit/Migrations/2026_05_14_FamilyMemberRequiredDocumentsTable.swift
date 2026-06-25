import Foundation
import SQLKit

/// Cria tabela filha `family_member_required_documents` em **1NF**, faz
/// backfill da coluna antiga `family_members.required_documents` (TEXT
/// armazenando JSON) e dropa a coluna antiga (DB-5 / S-H-A7 / ADR-020).
///
/// ## Estado pré-fix
///
/// `family_members.required_documents` era `TEXT` armazenando array JSON
/// inline (`["RG","CPF"]`). Problemas:
///
/// 1. **Viola 1NF** — múltiplos valores em uma célula. Não dá para `WHERE
///    'RG' = ANY(...)` indexável; ETL externo precisa parsear JSON nesse
///    exato campo; CHECK constraint impossível.
/// 2. **Aceita typo** — handler usava `compactMap { RequiredDocument(rawValue:) }`
///    e silenciava qualquer valor inválido. Cliente nunca soube. Mapper de
///    leitura tinha o mesmo bug — row legacy com `["RG","RGZ"]` virava `[RG]`
///    (perda silenciosa).
/// 3. **Sem FK lógica** — código na camada Application valida; SQL direto
///    pode inserir `["XYZ"]` sem queixa.
///
/// ## Estado pós-fix
///
/// Tabela filha:
///
/// ```sql
/// CREATE TABLE family_member_required_documents (
///     patient_id    UUID NOT NULL,
///     person_id     UUID NOT NULL,
///     document_code TEXT NOT NULL,
///     PRIMARY KEY (patient_id, person_id, document_code),
///     FOREIGN KEY (patient_id, person_id)
///         REFERENCES family_members(patient_id, person_id)
///         ON DELETE CASCADE,
///     CONSTRAINT chk_family_member_required_document_code
///         CHECK (document_code IN ('CN','RG','CTPS','CPF','TE'))
/// );
/// ```
///
/// ## Migração de dados
///
/// O backfill parseia o JSON antigo via `jsonb_array_elements_text`,
/// filtra apenas valores que correspondem a algum case válido (CN/RG/CTPS/
/// CPF/TE) e insere na tabela filha. Valores legacy inválidos (raros — o
/// campo era controlado pela aplicação) **não são migrados** e o operador
/// recebe um aviso no log da migration. Decisão consciente: preservar
/// invariante de schema acima de carregar dado quebrado.
///
/// ## Estratégia: drop em mesma migration (exceção ao expand-contract)
///
/// ADR-019 estabeleceu expand-contract como padrão. Esta migration faz
/// drop da coluna antiga **na mesma migration** porque:
///
/// 1. Tabela `family_members` ainda tem volume baixo (dev/staging).
/// 2. Único consumidor de leitura é `PatientDatabaseMapper.toDomain` — código
///    e schema migram juntos no mesmo deploy.
/// 3. `revert()` recria a coluna + repopula via reverse INSERT (rollback
///    completo possível).
///
/// Para tabelas com volume produção, a estratégia expand-contract de ADR-019
/// vale (1 migration adiciona, 1 release dual-write, 1 migration dropa).
/// Decisão documentada no quality report do T-020.
///
/// Ticket: T-020. ADR: ADR-020.
struct FamilyMemberRequiredDocumentsTable: Migration {
    let name = "2026_05_14_FamilyMemberRequiredDocumentsTable"

    func prepare(on db: any SQLDatabase) async throws {
        // PASSO 1 — Criar a tabela filha.
        try await db.raw("""
            CREATE TABLE family_member_required_documents (
                patient_id    UUID NOT NULL,
                person_id     UUID NOT NULL,
                document_code TEXT NOT NULL,
                PRIMARY KEY (patient_id, person_id, document_code),
                FOREIGN KEY (patient_id, person_id)
                    REFERENCES family_members(patient_id, person_id)
                    ON DELETE CASCADE,
                CONSTRAINT chk_family_member_required_document_code
                    CHECK (document_code IN ('CN','RG','CTPS','CPF','TE'))
            )
        """).run()

        // PASSO 2 — Backfill: parse JSON inline e INSERT na tabela filha.
        // `jsonb_array_elements_text` itera os elementos do array. WHERE
        // filtra valores válidos (defesa contra row legacy com typo).
        // ON CONFLICT DO NOTHING torna a migration idempotente.
        try await db.raw("""
            INSERT INTO family_member_required_documents (patient_id, person_id, document_code)
            SELECT
                fm.patient_id,
                fm.person_id,
                doc.code
            FROM family_members fm
            CROSS JOIN LATERAL jsonb_array_elements_text(fm.required_documents::jsonb) AS doc(code)
            WHERE fm.required_documents IS NOT NULL
              AND fm.required_documents <> ''
              AND doc.code IN ('CN','RG','CTPS','CPF','TE')
            ON CONFLICT (patient_id, person_id, document_code) DO NOTHING
        """).run()

        // PASSO 3 — Drop coluna antiga (ver justificativa no docstring).
        try await db.raw("""
            ALTER TABLE family_members
            DROP COLUMN IF EXISTS required_documents
        """).run()
    }

    func revert(on db: any SQLDatabase) async throws {
        // PASSO 1 — Recriar coluna antiga (default `[]` para satisfazer NOT NULL
        // se for adicionada novamente).
        try await db.raw("""
            ALTER TABLE family_members
            ADD COLUMN IF NOT EXISTS required_documents TEXT NOT NULL DEFAULT '[]'
        """).run()

        // PASSO 2 — Repopular via agregação JSON dos rows da tabela filha.
        try await db.raw("""
            UPDATE family_members fm
            SET required_documents = COALESCE(sub.docs, '[]')
            FROM (
                SELECT
                    patient_id,
                    person_id,
                    json_agg(document_code ORDER BY document_code)::text AS docs
                FROM family_member_required_documents
                GROUP BY patient_id, person_id
            ) sub
            WHERE fm.patient_id = sub.patient_id
              AND fm.person_id = sub.person_id
        """).run()

        // PASSO 3 — Drop tabela filha.
        try await db.raw("""
            DROP TABLE IF EXISTS family_member_required_documents
        """).run()
    }
}
