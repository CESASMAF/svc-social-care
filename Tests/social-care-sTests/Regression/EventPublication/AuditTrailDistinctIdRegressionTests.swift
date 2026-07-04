import Foundation
import Testing
@testable import social_care_s

// ticket: T-015 — achado S-C10 (Senior Code Review)
// ADR: ADR-015 — audit_trail.id distinto de outbox_messages.id

/// Regressão para o achado **S-C10**: o `SQLKitOutboxRelay` populava
/// `AuditTrailModel(id: message.id, ...)` — reusava o **PK do outbox**
/// como PK do `audit_trail`. Quando T-012 ainda permitia re-leitura
/// (ou em qualquer cenário de re-processamento — at-least-once),
/// a tentativa de inserir o **mesmo** `audit_trail.id` violava unique
/// constraint da PK e abortava a transação inteira do batch.
///
/// **Resultado:** **49 mensagens válidas no batch** voltavam para
/// `processed_at IS NULL` por causa de **1 duplicata** — loop de falha.
///
/// Fix:
/// 1. `audit_trail.id` ganha `DEFAULT gen_random_uuid()` no schema.
/// 2. Nova coluna `audit_trail.outbox_message_id UUID NOT NULL` rastreia
///    a relação 1:1 (audit referencia o outbox que originou).
/// 3. `SQLKitOutboxRelay` popula `id: UUID()` (novo) +
///    `outbox_message_id: message.id` (rastreio).
/// 4. Index em `outbox_message_id` para join futuro.
///
/// Mesmo que duas instâncias do relay re-leiam (improvável pós-T-012,
/// mas teoricamente possível em janela de race), `audit_trail` aceita
/// **N rows distintos** por `outbox_message_id` — auditoria registra
/// re-processamentos em vez de travar batch.
///
/// Este suite é **estrutural**: inspeciona migration + relay + model.
@Suite("Regression: Event Publication — S-C10 audit_trail.id distinct from outbox.id")
struct AuditTrailDistinctIdRegressionTests {

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

    private func relaySource() -> String {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/IO/Persistence/SQLKit/Outbox/SQLKitOutboxRelay.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func modelSource() -> String {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/IO/Persistence/SQLKit/Models/PatientDatabaseModels.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func anyMigrationContains(_ needles: [String]) throws -> Bool {
        let dir = migrationsDir()
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

    @Test("S-C10 — alguma migration declara coluna outbox_message_id em audit_trail")
    func test_S_C10_audit_trail_has_outbox_message_id_column() throws {
        let found = try anyMigrationContains([
            "audit_trail",
            "add column",
            "outbox_message_id",
            "uuid"
        ])
        #expect(found, "S-C10: nenhuma migration declara audit_trail.outbox_message_id. Sem essa coluna, audit não rastreia origem da entrada — perde-se a relação 1:1 com o outbox.")
    }

    @Test("S-C10 — alguma migration aplica DEFAULT gen_random_uuid() em audit_trail.id")
    func test_S_C10_audit_trail_id_has_default_random() throws {
        let found = try anyMigrationContains([
            "audit_trail",
            "id",
            "gen_random_uuid"
        ])
        #expect(found, "S-C10: audit_trail.id não tem DEFAULT gen_random_uuid(). Sem isso, conflict com message.id reused trava batch inteiro.")
    }

    @Test("S-C10 — alguma migration cria index em outbox_message_id")
    func test_S_C10_outbox_message_id_indexed() throws {
        let found = try anyMigrationContains([
            "audit_trail",
            "create index",
            "outbox_message_id"
        ])
        #expect(found, "S-C10: outbox_message_id sem index. Join audit_trail ↔ outbox_messages fica caro.")
    }

    @Test("S-C10 — AuditTrailModel declara outbox_message_id: UUID")
    func test_S_C10_model_has_outbox_message_id() {
        let source = modelSource()
        let lower = source.lowercased()
        #expect(lower.contains("outbox_message_id"),
                "S-C10: AuditTrailModel não declara outbox_message_id. Mapper não popula a coluna nova.")
    }

    @Test("S-C10 — relay popula audit_trail.id com UUID() novo (não message.id)")
    func test_S_C10_relay_uses_distinct_id() {
        let source = relaySource()
        // Sinal: o construtor de AuditTrailModel deve ter `id: UUID()` em vez de `id: message.id`.
        // Buscamos co-ocorrência: AuditTrailModel próximo de UUID() + outbox_message_id.
        let lower = source.lowercased()
        guard lower.contains("audittrailmodel") else {
            Issue.record("S-C10: relay não cria AuditTrailModel — mudança estrutural inesperada.")
            return
        }
        #expect(lower.contains("outbox_message_id"),
                "S-C10: SQLKitOutboxRelay não popula outbox_message_id no AuditTrailModel. ADR-015 exige rastreio explícito da origem.")
        // Procura `id: UUID()` no construtor do AuditTrailModel.
        // Sem isto, o relay reusa message.id e re-processamento vira PK conflict.
        #expect(lower.contains("id: uuid()"),
                "S-C10: SQLKitOutboxRelay deve usar `id: UUID()` no AuditTrailModel — e não reusar message.id como antes.")
    }
}
