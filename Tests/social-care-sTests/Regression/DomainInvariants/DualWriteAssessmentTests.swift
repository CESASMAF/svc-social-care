import Testing
import Foundation
@testable import social_care_s

/// Suite de regressão — Achados S-H-D1 + DB-7 (estágio (b) DUAL-WRITE da
/// decomposição de Patient — sub-aggregate `PatientAssessment`).
///
/// **Pré-fix (após T-024.a EXPAND):** infra criada, mas handlers de
/// assessment ainda escrevem **só** em `Patient.<modulo>?` via
/// `PatientRepository.save`. Tabela `patient_assessments` permanece com
/// row vazia (apenas `patient_id` populado pelo backfill; JSONB NULL).
///
/// **Pós-fix (este PR — DUAL-WRITE):** cada handler de assessment, depois
/// de chamar `patientRepository.save(patient)`, também chama
/// `assessmentRepository.dualWriteUpsert(_:)` com `PatientAssessment`
/// reconstruído a partir do `Patient`. Estado real passa a viver em
/// **ambos** os lados.
///
/// **Próximo estágio (CUTOVER):** leitura migra para
/// `patient_assessments` via `GetFullPatientProfileQuery` que faz JOIN.
/// **CONTRACT:** drop colunas `hc_*`/`csn_*`/etc. em `patients` + drop
/// campos no `Patient.swift` + remove `dualWriteUpsert` do protocol.
///
/// Suite cobre lints estruturais — runtime de DB exige Postgres real.
@Suite("Regression: Domain Invariants — T-024.a DUAL-WRITE assessment")
struct DualWriteAssessmentTests {

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

    private func source(at relPath: String) -> String {
        let url = projectRoot().appendingPathComponent(relPath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private let assessmentHandlers: [String] = [
        "Application/Assessment/UpdateHousingCondition/Services/UpdateHousingConditionCommandHandler.swift",
        "Application/Assessment/UpdateSocioEconomicSituation/Services/UpdateSocioEconomicSituationCommandHandler.swift",
        "Application/Assessment/UpdateWorkAndIncome/Services/UpdateWorkAndIncomeCommandHandler.swift",
        "Application/Assessment/UpdateEducationalStatus/Services/UpdateEducationalStatusCommandHandler.swift",
        "Application/Assessment/UpdateHealthStatus/Services/UpdateHealthStatusCommandHandler.swift",
        "Application/Assessment/UpdateCommunitySupportNetwork/Services/UpdateCommunitySupportNetworkCommandHandler.swift",
        "Application/Assessment/UpdateSocialHealthSummary/Services/UpdateSocialHealthSummaryCommandHandler.swift"
    ]

    // MARK: - Lints — protocol e repo SQLKit

    @Test("S-H-D1 DW — PatientAssessmentRepository declara dualWriteUpsert")
    func test_protocol_declares_dual_write_upsert() {
        let src = source(at: "Sources/social-care-s/Domain/Assessment/Repository/PatientAssessmentRepository.swift")
        #expect(src.contains("dualWriteUpsert"),
                "DUAL-WRITE: PatientAssessmentRepository não declara método `dualWriteUpsert(_:)`.")
    }

    @Test("S-H-D1 DW — SQLKitPatientAssessmentRepository implementa dualWriteUpsert com cast ::jsonb")
    func test_sqlkit_repo_implements_dual_write() {
        let src = source(at: "Sources/social-care-s/IO/Persistence/SQLKit/SQLKitPatientAssessmentRepository.swift")
        #expect(src.contains("dualWriteUpsert"),
                "DUAL-WRITE: SQLKitPatientAssessmentRepository não implementa `dualWriteUpsert(_:)`.")
        #expect(src.contains("on conflict") || src.contains("ON CONFLICT"),
                "DUAL-WRITE: dualWriteUpsert deve usar INSERT ... ON CONFLICT (patient_id) DO UPDATE.")
        #expect(src.contains("::jsonb"),
                "DUAL-WRITE: dualWriteUpsert deve usar cast `::jsonb` no bind dos módulos (ADR-022).")
    }

    // MARK: - Lints — cada handler chama dualWriteUpsert após save

    @Test("S-H-D1 DW — todos os 7 handlers de assessment chamam assessmentRepository.dualWriteUpsert")
    func test_handlers_call_dual_write() {
        var missing: [String] = []
        for path in assessmentHandlers {
            let src = source(at: "Sources/social-care-s/\(path)")
            // Padrão esperado: `try await assessmentRepository.dualWriteUpsert(`
            // (o argumento pode ser `assessment`, `patient.toAssessment()`, etc.)
            let hasCall = src.contains("dualWriteUpsert(") && src.contains("assessmentRepository")
            if !hasCall {
                missing.append((path as NSString).lastPathComponent)
            }
        }
        #expect(missing.isEmpty,
                "DUAL-WRITE: handlers que NÃO chamam assessmentRepository.dualWriteUpsert: \(missing).")
    }

    @Test("S-H-D1 DW — todos os 7 handlers recebem assessmentRepository no init")
    func test_handlers_inject_assessment_repository() {
        var missing: [String] = []
        for path in assessmentHandlers {
            let src = source(at: "Sources/social-care-s/\(path)")
            let hasInit = src.contains("assessmentRepository: any PatientAssessmentRepository")
            if !hasInit {
                missing.append((path as NSString).lastPathComponent)
            }
        }
        #expect(missing.isEmpty,
                "DUAL-WRITE: handlers SEM `assessmentRepository: any PatientAssessmentRepository` no init: \(missing).")
    }

    // MARK: - Lints — ServiceContainer DI

    @Test("S-H-D1 DW — ServiceContainer instancia SQLKitPatientAssessmentRepository e injeta nos 7 handlers")
    func test_service_container_wires_assessment_repo() {
        let src = source(at: "Sources/social-care-s/IO/HTTP/Bootstrap/ServiceContainer.swift")
        #expect(src.contains("SQLKitPatientAssessmentRepository"),
                "DUAL-WRITE: ServiceContainer não instancia SQLKitPatientAssessmentRepository.")
        // Cada uma das 7 instanciações deve passar `assessmentRepository:`.
        let assessmentInits = [
            "UpdateHousingConditionCommandHandler(",
            "UpdateSocioEconomicSituationCommandHandler(",
            "UpdateWorkAndIncomeCommandHandler(",
            "UpdateEducationalStatusCommandHandler(",
            "UpdateHealthStatusCommandHandler(",
            "UpdateCommunitySupportNetworkCommandHandler(",
            "UpdateSocialHealthSummaryCommandHandler("
        ]
        var missingInjection: [String] = []
        for handlerInit in assessmentInits {
            // Estratégia: depois do handlerInit deve haver "assessmentRepository:"
            // em até ~600 chars (margem para múltiplas linhas).
            guard let range = src.range(of: handlerInit) else {
                missingInjection.append("\(handlerInit) (init não encontrado)")
                continue
            }
            let after = src[range.upperBound...]
            let snippet = String(after.prefix(600))
            if !snippet.contains("assessmentRepository:") {
                missingInjection.append(handlerInit)
            }
        }
        #expect(missingInjection.isEmpty,
                "DUAL-WRITE: ServiceContainer NÃO passa `assessmentRepository:` nestes handlers: \(missingInjection).")
    }

    // MARK: - Lints — TestDouble

    @Test("S-H-D1 DW — InMemoryPatientAssessmentRepository existe em TestDoubles")
    func test_in_memory_assessment_repo_exists() {
        let url = projectRoot()
            .appendingPathComponent("Tests/social-care-sTests/Application/TestDoubles/InMemoryPatientAssessmentRepository.swift")
        #expect(FileManager.default.fileExists(atPath: url.path),
                "DUAL-WRITE: TestDoubles/InMemoryPatientAssessmentRepository.swift não existe — testes precisam de fake.")
    }
}
