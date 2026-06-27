import Foundation
import Testing
@testable import social_care_s

// ticket: T-013 — achado S-C4 (Senior Code Review)
// ADR: ADR-014 — Outbox Pattern: persistência atômica de eventos via repository (não via EventBus)

/// Regressão para o achado **S-C4**: `OutboxEventBus.publish(_:)` era
/// **dead code**. A função recebia eventos e retornava — comentava que
/// "eventos já foram escritos pelo repository" — sem fazer nada.
///
/// Mas os 21 handlers chamavam `try await eventBus.publish(patient.uncommittedEvents)`
/// achando que controlavam a publicação. O efeito real (escrever na tabela
/// `outbox_messages` na mesma transação do agregado) acontecia DENTRO de
/// `SQLKitPatientRepository.save()`. Acoplamento implícito + interface
/// enganosa.
///
/// **Riscos pré-fix:**
/// 1. Se algum dia outro repository não inserir no outbox interno,
///    eventos somem sem warning.
/// 2. Se alguém trocar `OutboxEventBus` por implementação que **realmente**
///    publica, os mesmos eventos viram **publicados duas vezes**
///    (uma via Outbox interno do save, outra via EventBus externo).
///
/// **Decisão (ADR-014, Opção A):** remover `eventBus.publish` dos handlers.
/// `repository.save(aggregate)` é a porta única de persistência de eventos.
/// O `InMemoryPatientRepository` (fake) espelha o invariante:
/// expõe `publishedEvents` populado pelo save.
///
/// Este suite garante:
/// 1. **Runtime:** `InMemoryPatientRepository.save(patient)` registra
///    `patient.uncommittedEvents` em `publishedEvents`.
/// 2. **Lint estrutural:** nenhum handler em `Application/` chama
///    `eventBus.publish` (regressão do invariante).
/// 3. **Lint estrutural:** nenhum handler tem parâmetro `eventBus` no init
///    (interface limpa).
@Suite("Regression: Event Publication — S-C4 OutboxEventBus dead code")
struct OutboxEventBusDeadCodeRegressionTests {

    // MARK: - File discovery

    private func applicationDirectory(file: StaticString = #filePath) throws -> URL {
        let thisFile = URL(fileURLWithPath: "\(file)")
        let projectRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return projectRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("social-care-s")
            .appendingPathComponent("Application")
    }

    private func allHandlerFiles() throws -> [URL] {
        let dir = try applicationDirectory()
        var results: [URL] = []
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.hasSuffix("CommandHandler.swift") {
                results.append(url)
            }
        }
        return results
    }

    // MARK: - Tests

    @Test("S-C4 — InMemoryPatientRepository.save registra uncommittedEvents em publishedEvents")
    func test_S_C4_repository_save_registers_events() async throws {
        let repo = InMemoryPatientRepository()
        var patient = try PatientFixture.createMinimalActive()
        patient.recordEvent(TestDomainEvent.fixture)

        try await repo.save(patient)

        let published = await repo.publishedEvents
        #expect(published.count >= 1, "S-C4: InMemoryPatientRepository.save DEVE espelhar o invariante real — events ficam na save, não em chamada separada.")
    }

    @Test("S-C4 — nenhum *CommandHandler.swift chama eventBus.publish")
    func test_S_C4_no_handler_calls_eventbus_publish() throws {
        let handlers = try allHandlerFiles()
        var offenders: [String] = []
        for url in handlers {
            let content = (try? String(contentsOf: url, encoding: .utf8))?.lowercased() ?? ""
            if content.contains("eventbus.publish") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "S-C4: handlers ainda chamam eventBus.publish: \(offenders.joined(separator: ", ")). ADR-014: repository.save é a porta única de eventos.")
    }

    @Test("S-C4 — nenhum *CommandHandler.swift tem parâmetro eventBus no init")
    func test_S_C4_no_handler_has_eventbus_in_init() throws {
        let handlers = try allHandlerFiles()
        var offenders: [String] = []
        for url in handlers {
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            // Match `eventBus:` em parâmetro de init OU em `private let eventBus`.
            if content.contains("eventBus:") || content.contains("eventBus ") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "S-C4: handlers ainda têm eventBus no init/property: \(offenders.joined(separator: ", ")). ADR-014: handler conhece apenas o repository.")
    }
}

// MARK: - Test fixture

/// Evento de domínio mínimo apenas para exercitar o invariante.
private struct TestDomainEvent: DomainEvent {
    let id: UUID
    let occurredAt: Date

    static let fixture = TestDomainEvent(
        id: RegressionFixture.uuid(seed: 999),
        occurredAt: RegressionFixture.frozenTimestamp().date
    )
}
