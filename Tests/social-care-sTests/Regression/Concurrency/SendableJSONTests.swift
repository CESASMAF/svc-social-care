import Testing
import Foundation
@testable import social_care_s

/// Suite de regressão — Achado S-H-IO6 (Senior Code Review § IO6) e S-M-P2.
///
/// Pré-fix:
/// ```swift
/// // shared/Error/AppError.swift
/// public struct AnySendable: @unchecked Sendable, Codable {
///     public let value: Any  // ← `Any` interno; @unchecked é mentira
/// }
///
/// // IO/HTTP/DTOs/ResponseDTOs.swift
/// struct AnyJSON: Content, @unchecked Sendable {
///     let value: Any  // ← idem
/// }
/// ```
///
/// `@unchecked Sendable` desliga a verificação do compilador. Strict
/// concurrency (Swift 6) não pega data race em `Any` interno — se duas tasks
/// acessarem o `value` simultaneamente em valores compartilhados, race
/// condition silenciosa. O contrato `Sendable` está sendo prometido sem
/// verificação real.
///
/// Fix (ADR-018):
/// 1. `AnySendable` vira enum fechado com cases tipados (string/int/double/
///    bool/array/object/null). Sendable VERDADEIRO.
/// 2. `AnyJSON` vira enum análogo. Sendable + Content (Vapor) sem unchecked.
/// 3. Compatibilidade: construtor `init(_ any: Any)` e getter `value: Any`
///    mantidos para back-compat (24 handlers usam).
///
/// Suite cobre:
/// - Lint estrutural: nenhum dos dois tipos contém `@unchecked Sendable`.
/// - Sanity runtime: round-trip Codable preserva valores.
/// - Sanity runtime: cases construídos diretamente são corretamente
///   sendable (compila se Task captura).
@Suite("Regression: Concurrency — S-H-IO6 Sendable JSON without @unchecked")
struct SendableJSONTests {

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

    private func appErrorSource() -> String {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/shared/Error/AppError.swift")
        return stripComments((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    private func responseDTOsSource() -> String {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/IO/HTTP/DTOs/ResponseDTOs.swift")
        return stripComments((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// Remove linhas que são puramente comentário (começam com `//` ou `///`),
    /// para o lint não pegar menções de `@unchecked Sendable` em docstrings
    /// que documentam a história do refactor.
    private func stripComments(_ source: String) -> String {
        source.components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//")
            }
            .joined(separator: "\n")
    }

    // MARK: - Lints estruturais

    @Test("S-H-IO6 — AnySendable não usa @unchecked Sendable")
    func test_S_H_IO6_anysendable_no_unchecked() {
        let source = appErrorSource()
        // Procura especificamente a declaração de AnySendable com @unchecked.
        // Aceita variações de spacing.
        let hasUnchecked = source.contains("AnySendable: @unchecked Sendable")
            || source.contains("AnySendable :  @unchecked Sendable")
            || source.contains("@unchecked Sendable, Codable") // antiga combinação típica
            && source.contains("AnySendable")
        // Forma narrow: enquanto a declaração for `enum AnySendable: Sendable`
        // ou similar sem `@unchecked`, passa.
        let declaresAsEnum = source.contains("enum AnySendable")
        #expect(declaresAsEnum,
                "S-H-IO6: AnySendable deve ser declarado como enum Sendable fechado (sem @unchecked).")
        #expect(!hasUnchecked,
                "S-H-IO6: AnySendable ainda usa @unchecked Sendable — Sendable está sendo prometido sem verificação.")
    }

    @Test("S-H-IO6 — AnyJSON (ResponseDTOs) não usa @unchecked Sendable")
    func test_S_H_IO6_anyjson_no_unchecked() {
        let source = responseDTOsSource()
        let hasUnchecked = source.contains("AnyJSON: Content, @unchecked Sendable")
            || source.contains("AnyJSON: @unchecked Sendable")
        let declaresAsEnum = source.contains("enum AnyJSON")
        #expect(declaresAsEnum,
                "S-H-IO6: AnyJSON deve ser declarado como enum Sendable+Content fechado (sem @unchecked).")
        #expect(!hasUnchecked,
                "S-H-IO6: AnyJSON ainda usa @unchecked Sendable.")
    }

    @Test("S-H-IO6 — nenhum source em shared/ ou IO/HTTP/DTOs/ usa @unchecked Sendable")
    func test_S_H_IO6_no_unchecked_in_boundary_layers() {
        let dirs = [
            "Sources/social-care-s/shared",
            "Sources/social-care-s/IO/HTTP/DTOs"
        ]
        var offenders: [String] = []
        for dirPath in dirs {
            let dir = projectRoot().appendingPathComponent(dirPath)
            guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let content = stripComments(raw)
                if content.contains("@unchecked Sendable") {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        #expect(offenders.isEmpty,
                "S-H-IO6: tipos de fronteira ainda têm @unchecked Sendable: \(offenders). Refatorar para enum Sendable fechado.")
    }

    // MARK: - Sanity runtime

    @Test("S-H-IO6 — AnySendable é Sendable de verdade (compila em Task)")
    func test_S_H_IO6_anysendable_is_truly_sendable() async {
        // Compilação prova: se AnySendable não fosse Sendable, capturar em
        // Task daria erro do compilador em strict concurrency.
        let value = AnySendable("test")
        let captured = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            Task {
                cont.resume(returning: "\(value.value)")
            }
        }
        #expect(captured.contains("test"))
    }

    @Test("S-H-IO6 — AnySendable round-trip Codable preserva string")
    func test_S_H_IO6_anysendable_codable_string() throws {
        let original = AnySendable("hello")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnySendable.self, from: data)
        #expect("\(decoded.value)" == "hello")
    }

    @Test("S-H-IO6 — AnySendable round-trip Codable preserva int")
    func test_S_H_IO6_anysendable_codable_int() throws {
        let original = AnySendable(42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnySendable.self, from: data)
        // Após round-trip pode chegar como Int ou Double dependendo do JSON.
        let str = "\(decoded.value)"
        #expect(str == "42" || str == "42.0")
    }

    @Test("S-H-IO6 — AnySendable round-trip Codable preserva bool")
    func test_S_H_IO6_anysendable_codable_bool() throws {
        let original = AnySendable(true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnySendable.self, from: data)
        #expect("\(decoded.value)" == "true")
    }
}
