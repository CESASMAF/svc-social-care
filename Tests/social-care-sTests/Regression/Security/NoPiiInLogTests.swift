import Testing
import Foundation

/// Suite de regressão — Achado S-H-IO5 / S-H-P6 (Senior Code Review).
///
/// Logar `"\(error)"` bruto em camadas IO/HTTP/EventBus/Persistence vaza PII.
/// `DecodingError`, `PSQLError`, `URLError` e similares incluem o **payload
/// causador** no `description` por design — útil em dev, catastrófico em prod
/// com dados de paciente (CPF, NIS, RG, endereço, diagnóstico).
///
/// Exemplo do bug original (`SQLKitOutboxRelay.swift` pré-fix):
/// ```swift
/// logger.error("Outbox relay poll failed", metadata: ["error": "\(error)"])
///                                                              ↑
///                              Se error é DecodingError, vaza payload.
/// ```
///
/// Fix:
/// 1. Helper `LogSanitizer.metadata(for: Error)` em `shared/Error/` que retorna
///    `["errorType": tipo, "errorMessage": localizedDescription]` — nunca o
///    `description` cru.
/// 2. Substituir TODOS os `"\(error)"` em IO/HTTP/EventBus/Persistence por
///    chamada ao sanitizer.
/// 3. Anti-pattern enforcement via lint estrutural neste suite.
///
/// **Camadas exigidas a usar sanitizer:**
/// - `Sources/.../IO/Persistence/` — recebe error do PostgresKit (PSQLError com SQL fragments).
/// - `Sources/.../IO/EventBus/` — recebe DecodingError com bytes do payload.
/// - `Sources/.../IO/HTTP/Middleware/` — recebe error que pode ter body do request.
/// - `Sources/.../IO/HTTP/Controllers/` — recebe error de DB/upstream.
///
/// **Camadas isentas (com justificativa):**
/// - `Sources/.../IO/HTTP/Bootstrap/` — startup time, sem PII fluindo ainda.
/// - `Sources/.../social_care_s.swift` — bootstrap entry point.
@Suite("Regression: Security — S-H-IO5 no PII in logs")
struct NoPiiInLogTests {

    private func projectRoot(file: StaticString = #filePath) -> URL {
        let thisFile = URL(fileURLWithPath: "\(file)")
        return thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourcesAt(_ subpath: String) -> [URL] {
        let dir = projectRoot().appendingPathComponent("Sources/social-care-s/\(subpath)")
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    private func contains(_ url: URL, _ needle: String) -> Bool {
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return content.contains(needle)
    }

    @Test("S-H-IO5 — LogSanitizer existe em shared/Error/")
    func test_S_H_IO5_log_sanitizer_exists() {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/shared/Error/LogSanitizer.swift")
        #expect(FileManager.default.fileExists(atPath: url.path),
                "S-H-IO5: shared/Error/LogSanitizer.swift não existe. Necessário para política universal de log sem PII.")
    }

    @Test("S-H-IO5 — LogSanitizer expõe API metadata(for:)")
    func test_S_H_IO5_sanitizer_exposes_metadata() {
        let url = projectRoot()
            .appendingPathComponent("Sources/social-care-s/shared/Error/LogSanitizer.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lower = source.lowercased()
        #expect(lower.contains("logsanitizer"),
                "S-H-IO5: arquivo não declara enum/struct LogSanitizer.")
        #expect(lower.contains("metadata"),
                "S-H-IO5: LogSanitizer não expõe método `metadata(for:)`.")
        #expect(source.contains("String(reflecting: type(of:"),
                "S-H-IO5: LogSanitizer deve usar `String(reflecting: type(of: error))` para serializar tipo do erro.")
    }

    @Test("S-H-IO5 — IO/Persistence/ não loga \"(error)\" bruto")
    func test_S_H_IO5_persistence_no_raw_error() {
        let files = sourcesAt("IO/Persistence")
        let offenders = files.filter { contains($0, "\"\\(error)\"") }
        let names = offenders.map { $0.lastPathComponent }
        #expect(offenders.isEmpty,
                "S-H-IO5: arquivos em IO/Persistence ainda logam \"\\(error)\" bruto: \(names). Use LogSanitizer.")
    }

    @Test("S-H-IO5 — IO/EventBus/ não loga \"(error)\" bruto")
    func test_S_H_IO5_eventbus_no_raw_error() {
        let files = sourcesAt("IO/EventBus")
        let offenders = files.filter { contains($0, "\"\\(error)\"") }
        let names = offenders.map { $0.lastPathComponent }
        #expect(offenders.isEmpty,
                "S-H-IO5: arquivos em IO/EventBus ainda logam \"\\(error)\" bruto: \(names). Use LogSanitizer.")
    }

    @Test("S-H-IO5 — IO/HTTP/Middleware/ não loga \"(error)\" bruto")
    func test_S_H_IO5_middleware_no_raw_error() {
        let files = sourcesAt("IO/HTTP/Middleware")
        let offenders = files.filter { contains($0, "\"\\(error)\"") }
        let names = offenders.map { $0.lastPathComponent }
        #expect(offenders.isEmpty,
                "S-H-IO5: middlewares ainda logam \"\\(error)\" bruto: \(names). Use LogSanitizer.")
    }

    @Test("S-H-IO5 — IO/HTTP/Controllers/ não loga \"(error)\" bruto")
    func test_S_H_IO5_controllers_no_raw_error() {
        let files = sourcesAt("IO/HTTP/Controllers")
        let offenders = files.filter { contains($0, "\"\\(error)\"") }
        let names = offenders.map { $0.lastPathComponent }
        #expect(offenders.isEmpty,
                "S-H-IO5: controllers ainda logam \"\\(error)\" bruto: \(names). Use LogSanitizer.")
    }

    @Test("S-H-IO5 — IO/HTTP/Middleware/ não interpola \"\\(error)\" em mensagem")
    func test_S_H_IO5_middleware_no_interpolated_error_in_message() {
        let offenders = interpolatedErrorOffenders(in: sourcesAt("IO/HTTP/Middleware"))
        #expect(offenders.isEmpty,
                "S-H-IO5: middlewares interpolam \\(error) na mensagem do log: \(offenders). Use LogSanitizer.")
    }

    @Test("S-H-IO5 — IO/EventBus/ não interpola \"\\(error)\" em mensagem")
    func test_S_H_IO5_eventbus_no_interpolated_error_in_message() {
        let offenders = interpolatedErrorOffenders(in: sourcesAt("IO/EventBus"))
        #expect(offenders.isEmpty,
                "S-H-IO5: EventBus interpola \\(error) na mensagem do log: \(offenders). Use LogSanitizer.")
    }

    @Test("S-H-IO5 — IO/HTTP/Controllers/ não interpola \"\\(error)\" em mensagem")
    func test_S_H_IO5_controllers_no_interpolated_error_in_message() {
        let offenders = interpolatedErrorOffenders(in: sourcesAt("IO/HTTP/Controllers"))
        #expect(offenders.isEmpty,
                "S-H-IO5: controllers interpolam \\(error) na mensagem do log: \(offenders). Use LogSanitizer.")
    }

    /// Caso S-H-IO5b: `logger.error("...: \(error)")` direto na mensagem
    /// (não em metadata). Vaza igual ao caso `metadata: ["error": "\(error)"]`.
    private func interpolatedErrorOffenders(in files: [URL]) -> [String] {
        var offenders: [String] = []
        for file in files {
            let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isLoggerCall = trimmed.hasPrefix("logger.")
                    || trimmed.hasPrefix("request.logger.")
                    || trimmed.hasPrefix("req.logger.")
                    || trimmed.hasPrefix("app.logger.")
                if isLoggerCall, trimmed.contains("\\(error)") {
                    offenders.append(file.lastPathComponent + " :: " + trimmed.prefix(80).description)
                }
            }
        }
        return offenders
    }
}
