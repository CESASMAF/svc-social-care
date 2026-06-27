import Foundation
import PostgresNIO
import SQLKit

struct SQLKitPatientRepository: PatientRepository {
    private let db: any SQLDatabase

    init(db: any SQLDatabase) {
        self.db = db
    }

    func save(_ patient: Patient) async throws {
        do {
            try await db.transaction { tx in
                let data = try PatientDatabaseMapper.toDatabase(patient)
                let outboxMessages = try PatientDatabaseMapper.toOutbox(patient.uncommittedEvents)
                let patientId = data.patient.id

                // 1. Optimistic lock (ADR-005).
                //
                // `SELECT … FOR UPDATE` adquire row-level lock dentro da transação para
                // evitar TOCTOU entre o version check e o UPDATE. Sem o lock, duas
                // transações concorrentes podem ler `version=N`, ambas aceitar o
                // check, e ambas escrever `version=N+1` — exatamente o bug
                // S-C3/DB-2. Em PostgreSQL, transações que tentem o mesmo
                // `FOR UPDATE` em paralelo serializam.
                let currentVersion: Int? = try await tx.raw("""
                    SELECT version FROM patients WHERE id = \(bind: patientId) FOR UPDATE
                """).first()?.decode(column: "version", as: Int.self)

                if let dbVersion = currentVersion {
                    // UPDATE path — agregado já existe.
                    let expected = patient.version - 1
                    guard dbVersion == expected else {
                        throw PersistenceConflictError.optimisticLockFailed(
                            expectedVersion: expected,
                            actualVersion: dbVersion
                        )
                    }
                    try await tx.update("patients")
                        .set(model: data.patient)
                        .where("id", .equal, patientId)
                        .run()
                } else {
                    // CREATE path — primeira save deste agregado.
                    try await tx.insert(into: "patients").model(data.patient).run()
                }

                // 2. Tabelas filhas com PK surrogate `id UUID` (ADR-021):
                //    diff-based upsert via INSERT ... ON CONFLICT (id) DO UPDATE.
                //    IDs determinísticos (mapper ADR-021) garantem mesma chave
                //    a cada save → UPDATE in-place em vez de DELETE+INSERT.
                //    Triggers ON UPDATE disparam, audit trail é fiel.
                try await upsertChildren(tx, table: "patient_diagnoses", patientId: patientId, models: data.diagnoses, idExtractor: \.id)
                try await upsertChildren(tx, table: "social_care_appointments", patientId: patientId, models: data.appointments, idExtractor: \.id)
                try await upsertChildren(tx, table: "referrals", patientId: patientId, models: data.referrals, idExtractor: \.id)
                try await upsertChildren(tx, table: "rights_violation_reports", patientId: patientId, models: data.reports, idExtractor: \.id)

                // 3. Tabelas filhas com PK composta natural (ADR-006):
                //    `family_members(patient_id, person_id)` e
                //    `family_member_required_documents(patient_id, person_id, document_code)`.
                //    A tupla é a identidade — delete-and-insert é semanticamente
                //    upsert (PK não muda). Migração para ON CONFLICT em chave composta
                //    fica como melhoria incremental quando triggers ON UPDATE forem
                //    introduzidos (T-023). Ordem: family_members → required_documents
                //    (FK exige parent existir antes do filho).
                try await deleteAndInsert(tx, table: "family_members", patientId: patientId, models: data.familyMembers)
                try await deleteAndInsert(tx, table: "family_member_required_documents", patientId: patientId, models: data.familyMemberRequiredDocuments)

                // 4. Tabelas normalizadas com PK surrogate `id UUID` (ADR-021).
                try await upsertChildren(tx, table: "member_incomes", patientId: patientId, models: data.memberIncomes, idExtractor: \.id)
                try await upsertChildren(tx, table: "social_benefits", patientId: patientId, models: data.socialBenefits, idExtractor: \.id)
                try await upsertChildren(tx, table: "member_educational_profiles", patientId: patientId, models: data.educationalProfiles, idExtractor: \.id)
                try await upsertChildren(tx, table: "program_occurrences", patientId: patientId, models: data.programOccurrences, idExtractor: \.id)
                try await upsertChildren(tx, table: "member_deficiencies", patientId: patientId, models: data.memberDeficiencies, idExtractor: \.id)
                try await upsertChildren(tx, table: "gestating_members", patientId: patientId, models: data.gestatingMembers, idExtractor: \.id)
                try await upsertChildren(tx, table: "placement_registries", patientId: patientId, models: data.placementRegistries, idExtractor: \.id)
                try await upsertChildren(tx, table: "ingress_linked_programs", patientId: patientId, models: data.ingressLinkedPrograms, idExtractor: \.id)

                // 4. Outbox — ADR-022: payload é JSONB, exige cast `::jsonb`
                // explícito no bind (PostgresKit envia String). SQL raw é a
                // única forma de fazer o cast; `.model()` daria erro de tipo
                // (TEXT → JSONB no banco). Demais colunas usam binds normais.
                for message in outboxMessages {
                    try await tx.raw("""
                        INSERT INTO outbox_messages (id, event_type, payload, occurred_at, processed_at)
                        VALUES (\(bind: message.id), \(bind: message.event_type), \(bind: message.payload)::jsonb, \(bind: message.occurred_at), \(bind: message.processed_at))
                    """).run()
                }
            }
        } catch let error as PSQLError where error.code == .server {
            if let sqlState = error.serverInfo?[.sqlState], sqlState == "23505",
               let constraint = error.serverInfo?[.constraintName] {
                throw PersistenceConflictError.uniqueViolation(
                    constraint: constraint,
                    detail: error.serverInfo?[.detail]
                )
            }
            throw error
        }
    }

    func find(byPersonId personId: PersonId) async throws -> Patient? {
        let personUUID = UUID(uuidString: personId.description)!
        guard let patientModel = try await db.select()
            .column("*")
            .from("patients")
            .where("person_id", .equal, personUUID)
            .first(decoding: PatientModel.self) else { return nil }

        return try await loadAggregate(patientModel)
    }

    func find(byId id: PatientId) async throws -> Patient? {
        let uuid = UUID(uuidString: id.description)!
        guard let patientModel = try await db.select()
            .column("*")
            .from("patients")
            .where("id", .equal, uuid)
            .first(decoding: PatientModel.self) else { return nil }

        return try await loadAggregate(patientModel)
    }

    func list(search: String?, status: PatientStatus?, cursor: PatientId?, limit: Int) async throws -> PatientListResult {
        // 1. Total count (com filtro de busca e status se aplicável)
        var countQuery = db.select()
            .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "count")
            .from("patients")

        if let status {
            countQuery = countQuery.where("status", .equal, status.rawValue)
        }

        if let search, !search.isEmpty {
            let pattern = "%\(search)%"
            countQuery = countQuery.where { group in
                group.where(SQLFunction("LOWER", args: SQLColumn("first_name")), .like, SQLBind(pattern.lowercased()))
                    .orWhere(SQLFunction("LOWER", args: SQLColumn("last_name")), .like, SQLBind(pattern.lowercased()))
                    .orWhere(SQLColumn("cpf"), .like, SQLBind(pattern))
            }
        }

        let totalCount = try await countQuery
            .first()
            .map { try $0.decode(column: "count", as: Int.self) } ?? 0

        // 2. Query principal: projeção leve sem loadAggregate
        var query = db.select()
            .column(SQLColumn("id", table: "patients"))
            .column(SQLColumn("person_id", table: "patients"))
            .column(SQLColumn("first_name", table: "patients"))
            .column(SQLColumn("last_name", table: "patients"))
            .column(SQLColumn("status", table: "patients"))
            .from("patients")

        if let status {
            query = query.where("status", .equal, status.rawValue)
        }

        if let search, !search.isEmpty {
            let pattern = "%\(search)%"
            query = query.where { group in
                group.where(SQLFunction("LOWER", args: SQLColumn("first_name")), .like, SQLBind(pattern.lowercased()))
                    .orWhere(SQLFunction("LOWER", args: SQLColumn("last_name")), .like, SQLBind(pattern.lowercased()))
                    .orWhere(SQLColumn("cpf"), .like, SQLBind(pattern))
            }
        }

        if let cursor {
            let cursorUUID = UUID(uuidString: cursor.description)!
            query = query.where("id", .greaterThan, cursorUUID)
        }

        let fetchLimit = limit + 1
        query = query.orderBy("id").limit(fetchLimit)

        struct PatientListRow: Codable {
            let id: UUID
            let person_id: UUID
            let first_name: String?
            let last_name: String?
            let status: String
        }

        let rows = try await query.all(decoding: PatientListRow.self)

        // 3. Buscar diagnóstico primário e contagem de membros para os pacientes retornados
        let patientIds = rows.prefix(limit).map { $0.id }

        var diagnosisMap: [UUID: String] = [:]
        var memberCountMap: [UUID: Int] = [:]

        if !patientIds.isEmpty {
            struct DiagRow: Codable {
                let patient_id: UUID
                let description: String
            }

            // Diagnóstico: primeiro por patient_id
            let diagRows = try await db.select()
                .column("patient_id")
                .column("description")
                .from("patient_diagnoses")
                .where("patient_id", .in, patientIds)
                .all(decoding: DiagRow.self)

            for row in diagRows {
                if diagnosisMap[row.patient_id] == nil {
                    diagnosisMap[row.patient_id] = row.description
                }
            }

            // Member count por patient_id
            struct CountRow: Codable {
                let patient_id: UUID
                let cnt: Int
            }

            let countRows = try await db.select()
                .column("patient_id")
                .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "cnt")
                .from("family_members")
                .where("patient_id", .in, patientIds)
                .groupBy("patient_id")
                .all(decoding: CountRow.self)

            for row in countRows {
                memberCountMap[row.patient_id] = row.cnt
            }
        }

        // 4. Montar resultado
        let hasMore = rows.count > limit
        let items: [PatientSummary] = try rows.prefix(limit).map { row in
            PatientSummary(
                patientId: try PatientId(row.id.uuidString),
                personId: try PersonId(row.person_id.uuidString),
                firstName: row.first_name,
                lastName: row.last_name,
                primaryDiagnosis: diagnosisMap[row.id],
                memberCount: memberCountMap[row.id] ?? 0,
                status: PatientStatus(rawValue: row.status) ?? .active
            )
        }

        let nextCursor = hasMore ? items.last?.patientId : nil

        return PatientListResult(
            items: items,
            totalCount: totalCount,
            hasMore: hasMore,
            nextCursor: nextCursor
        )
    }

    func find(byCpf cpf: CPF) async throws -> Patient? {
        guard let patientModel = try await db.select()
            .column("*")
            .from("patients")
            .where("cpf", .equal, cpf.value)
            .first(decoding: PatientModel.self) else { return nil }

        return try await loadAggregate(patientModel)
    }

    func exists(byCpf cpf: CPF) async throws -> Bool {
        let count = try await db.select()
            .column(SQLFunction("COUNT", args: SQLLiteral.all))
            .from("patients")
            .where("cpf", .equal, cpf.value)
            .first()
            .map { try $0.decode(column: "count", as: Int.self) } ?? 0
        return count > 0
    }

    func updatePersonId(patientId: PatientId, newPersonId: PersonId) async throws {
        let patientUUID = UUID(uuidString: patientId.description)!
        let personUUID = UUID(uuidString: newPersonId.description)!
        try await db.update("patients")
            .set("person_id", to: personUUID)
            .where("id", .equal, patientUUID)
            .run()
    }

    func exists(byPersonId personId: PersonId) async throws -> Bool {
        let personUUID = UUID(uuidString: personId.description)!
        let count = try await db.select()
            .column(SQLFunction("COUNT", args: SQLLiteral.all))
            .from("patients")
            .where("person_id", .equal, personUUID)
            .first()
            .map { try $0.decode(column: "count", as: Int.self) } ?? 0
        return count > 0
    }

    // MARK: - Private

    private func deleteAndInsert<T: Codable>(
        _ tx: any SQLDatabase,
        table: String,
        patientId: UUID,
        models: [T]
    ) async throws {
        try await tx.delete(from: table).where("patient_id", .equal, patientId).run()
        for model in models {
            try await tx.insert(into: table).model(model).run()
        }
    }

    /// Diff-based upsert para tabelas filhas com PK surrogate `id UUID`
    /// (ADR-021).
    ///
    /// Algoritmo:
    /// 1. SELECT `id` FROM <table> WHERE patient_id = ? (existing).
    /// 2. desiredIds = models.map(idExtractor).
    /// 3. toRemove = existing - desired (set difference).
    /// 4. DELETE FROM <table> WHERE id IN (toRemove) — só os removidos.
    /// 5. Para cada model: INSERT ... ON CONFLICT (id) DO UPDATE SET excluded.*.
    ///    Usa SQLKit `.onConflict(with:["id"]) { ... .set(excludedValueOf:) }`.
    ///    Colunas extraídas via Mirror do primeiro model do batch.
    ///
    /// Pré-condição: `models[*].id` é determinístico em relação ao domínio
    /// (mapper usa `DeterministicUUID.from(...)`). Sem isso, cada save
    /// gera ID novo e o ON CONFLICT nunca dispara — UPDATE vira INSERT
    /// e a tabela cresce sem limite.
    private func upsertChildren<T: Codable & Sendable>(
        _ tx: any SQLDatabase,
        table: String,
        patientId: UUID,
        models: [T],
        idExtractor: (T) -> UUID
    ) async throws {
        // 1. Coleta IDs existentes.
        let existingRows = try await tx.select()
            .column("id")
            .from(table)
            .where("patient_id", .equal, patientId)
            .all(decoding: ExistingIdRow.self)
        let existingIds = Set(existingRows.map(\.id))

        // 2. IDs desejados após este save.
        let desiredIds = Set(models.map(idExtractor))

        // 3. DELETE seletivo dos removidos.
        let toRemove = existingIds.subtracting(desiredIds)
        if !toRemove.isEmpty {
            try await tx.delete(from: table)
                .where("id", .in, Array(toRemove))
                .run()
        }

        // 4. UPSERT atômico via INSERT ... ON CONFLICT (id) DO UPDATE.
        // Colunas extraídas via reflection do primeiro model — todos os
        // models do batch têm a mesma forma (são instâncias do mesmo tipo).
        guard let sample = models.first else { return }
        let nonIdColumns = Mirror(reflecting: sample).children
            .compactMap(\.label)
            .filter { $0 != "id" }

        for model in models {
            try await tx.insert(into: table)
                .model(model)
                .onConflict(with: ["id"]) { update in
                    var u = update
                    for col in nonIdColumns {
                        u = u.set(excludedValueOf: col)
                    }
                    return u
                }
                .run()
        }
    }

    private func loadAggregate(_ patientModel: PatientModel) async throws -> Patient {
        let id = patientModel.id

        let diagnoses = try await db.select().column("*").from("patient_diagnoses").where("patient_id", .equal, id).all(decoding: DiagnosisModel.self)
        let family = try await db.select().column("*").from("family_members").where("patient_id", .equal, id).all(decoding: FamilyMemberModel.self)
        // ADR-020: tabela filha 1NF para required_documents.
        let familyMemberRequiredDocuments = try await db.select().column("*").from("family_member_required_documents").where("patient_id", .equal, id).all(decoding: FamilyMemberRequiredDocumentModel.self)
        let appointments = try await db.select().column("*").from("social_care_appointments").where("patient_id", .equal, id).all(decoding: AppointmentModel.self)
        let referrals = try await db.select().column("*").from("referrals").where("patient_id", .equal, id).all(decoding: ReferralModel.self)
        let reports = try await db.select().column("*").from("rights_violation_reports").where("patient_id", .equal, id).all(decoding: ViolationReportModel.self)

        let memberIncomes = try await db.select().column("*").from("member_incomes").where("patient_id", .equal, id).all(decoding: MemberIncomeModel.self)
        let socialBenefits = try await db.select().column("*").from("social_benefits").where("patient_id", .equal, id).all(decoding: SocialBenefitModel.self)
        let educationalProfiles = try await db.select().column("*").from("member_educational_profiles").where("patient_id", .equal, id).all(decoding: MemberEducationalProfileModel.self)
        let programOccurrences = try await db.select().column("*").from("program_occurrences").where("patient_id", .equal, id).all(decoding: ProgramOccurrenceModel.self)
        let memberDeficiencies = try await db.select().column("*").from("member_deficiencies").where("patient_id", .equal, id).all(decoding: MemberDeficiencyModel.self)
        let gestatingMembers = try await db.select().column("*").from("gestating_members").where("patient_id", .equal, id).all(decoding: GestatingMemberModel.self)
        let placementRegistries = try await db.select().column("*").from("placement_registries").where("patient_id", .equal, id).all(decoding: PlacementRegistryModel.self)
        let ingressLinkedPrograms = try await db.select().column("*").from("ingress_linked_programs").where("patient_id", .equal, id).all(decoding: IngressLinkedProgramModel.self)

        return try PatientDatabaseMapper.toDomain(
            patient: patientModel,
            diagnoses: diagnoses,
            familyMembers: family,
            familyMemberRequiredDocuments: familyMemberRequiredDocuments,
            appointments: appointments,
            referrals: referrals,
            reports: reports,
            memberIncomes: memberIncomes,
            socialBenefits: socialBenefits,
            educationalProfiles: educationalProfiles,
            programOccurrences: programOccurrences,
            memberDeficiencies: memberDeficiencies,
            gestatingMembers: gestatingMembers,
            placementRegistries: placementRegistries,
            ingressLinkedPrograms: ingressLinkedPrograms
        )
    }
}

/// Helper privado de leitura — usado por `upsertChildren` para descobrir IDs
/// existentes antes do diff. Definido fora do struct para satisfazer Swift
/// 6.3 (tipos aninhados em função genérica não são permitidos).
private struct ExistingIdRow: Codable { let id: UUID }
