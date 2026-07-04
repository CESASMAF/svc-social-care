import Foundation
import Testing
@testable import social_care_s

// ticket: T-010 — achado S-C6 (Senior Code Review)
// ADR: ADR-010 — Mapeamento universal de PersistenceConflictError nos handlers

/// Regressão para o achado **S-C6**: dos 21 command handlers, apenas
/// `RegisterPatientMapperError` mapeava `PersistenceConflictError.uniqueViolation`
/// para erro de negócio HTTP 409. Os outros 20 deixavam o erro genérico
/// vazar como `persistenceMappingFailure` (HTTP 500) — UX ruim + leak de
/// stack interno via mensagem.
///
/// Cenário do bug: usuário tenta cadastrar dois benefícios duplicados ou
/// dois lookups com mesmo código. Banco rejeita (`23505 unique_violation`).
/// Repository converte para `PersistenceConflictError.uniqueViolation`.
/// Handler que **não trata** esse caso devolve 500 — operador vê erro
/// genérico, não recebe hint para corrigir.
///
/// Este suite cobre:
/// 1. **Helper runtime** `mapUniqueViolation` funciona corretamente.
/// 2. **Lint estrutural**: cada `*MapperError.swift` cita
///    `PersistenceConflictError` ou `mapUniqueViolation`. Falha se algum
///    handler novo for criado sem o tratamento.
@Suite("Regression: ErrorMapping — S-C6 unique violation universal mapping")
struct UniqueViolationMappingRegressionTests {

    // MARK: - File discovery (lint estrutural)

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

    private func allMapperErrorFiles() throws -> [URL] {
        let dir = try applicationDirectory()
        var results: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.hasSuffix("MapperError.swift") {
                results.append(url)
            }
        }
        return results
    }

    // MARK: - Tests

    /// Erro de negócio fictício para exercitar o helper genérico em isolamento.
    /// Real handlers usam seu próprio `*Error` enum.
    enum FixtureBusinessError: Error, Equatable {
        case mapped, fallback
    }

    @Test("S-C6 — helper runtime PersistenceConflictError.mapUniqueViolation funciona")
    func test_S_C6_helper_runtime_works() {
        let conflict = PersistenceConflictError.uniqueViolation(
            constraint: "uq_test",
            detail: nil
        )
        let mapped: FixtureBusinessError? = conflict.mapUniqueViolation { constraint in
            constraint == "uq_test" ? .mapped : nil
        }
        #expect(mapped == .mapped)

        // Constraint desconhecido → nil (handler decide fallback)
        let unmapped: FixtureBusinessError? = conflict.mapUniqueViolation { _ in nil }
        #expect(unmapped == nil)

        // Não é uniqueViolation → nil
        let other: PersistenceConflictError = .optimisticLockFailed(expectedVersion: 1, actualVersion: 2)
        let nothing: FixtureBusinessError? = other.mapUniqueViolation { _ in .fallback }
        #expect(nothing == nil)
    }

    @Test("S-C6 / S-C3 — helper mapOptimisticLockFailed funciona")
    func test_S_C6_optimistic_lock_helper() {
        let conflict: PersistenceConflictError = .optimisticLockFailed(expectedVersion: 1, actualVersion: 2)
        let mapped: FixtureBusinessError? = conflict.mapOptimisticLockFailed { exp, act in
            exp == 1 && act == 2 ? .mapped : nil
        }
        #expect(mapped == .mapped)

        // Não é optimisticLockFailed → nil
        let other = PersistenceConflictError.uniqueViolation(constraint: "x", detail: nil)
        let nothing: FixtureBusinessError? = other.mapOptimisticLockFailed { _, _ in .fallback }
        #expect(nothing == nil)
    }

    @Test("S-C6 — todo *MapperError.swift na Application cita PersistenceConflictError ou mapUniqueViolation")
    func test_S_C6_all_handlers_handle_conflict() throws {
        let mappers = try allMapperErrorFiles()
        #expect(!mappers.isEmpty, "Esperado encontrar arquivos *MapperError.swift na Application/")

        var missing: [String] = []
        for url in mappers {
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lower = content.lowercased()
            // Aceita qualquer das duas formas: chamada direta ao helper OU
            // tratamento manual por `case .uniqueViolation`.
            let handlesConflict = lower.contains("mapuniqueviolation") ||
                                   lower.contains("uniqueviolation") ||
                                   lower.contains("persistenceconflicterror")
            if !handlesConflict {
                missing.append(url.lastPathComponent)
            }
        }
        #expect(missing.isEmpty, "S-C6: handlers que não tratam PersistenceConflictError: \(missing.joined(separator: ", ")). Use mapUniqueViolation no MapperError correspondente — sem isso, banco rejeita unique e cliente recebe HTTP 500 genérico em vez de 409 com hint.")
    }
}
