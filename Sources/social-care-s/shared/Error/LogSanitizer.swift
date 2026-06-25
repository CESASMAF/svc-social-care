import Foundation
import Logging

/// Política universal de sanitização de logs (ADR-017).
///
/// **Problema (S-H-IO5):** Logar `"\(error)"` em camadas que processam dados
/// pessoais (LGPD scope) vaza PII. Tipos comuns que incluem o payload no
/// `description`:
/// - `DecodingError` — inclui o JSON ofensor.
/// - `PSQLError` / `PSQLError.serverInfo` — inclui fragmento de SQL com valores
///   bound.
/// - `URLError` / `URLError.failingURL` — inclui URL com query string.
/// - Erros customizados que carregam contexto do request.
///
/// **Política:** logs em camadas IO/HTTP/EventBus/Persistence usam
/// `LogSanitizer` em vez de interpolar `error` direto. O sanitizer expõe
/// duas APIs:
///
/// 1. `metadata(for:)` — retorna `Logger.Metadata` com `errorType` (qualified
///    type name via `String(reflecting: type(of:))`) e `errorDescription`
///    (uma sentence sanitizada do `localizedDescription`, truncada e com
///    `\n`/`\r` neutralizados para evitar log injection).
/// 2. `summary(for:)` — string curta do tipo, para usar inline em mensagem.
///
/// **Quando NÃO sanitizar:**
/// - Bootstrap (startup time, sem PII fluindo).
/// - Erros de domínio que já implementam `AppErrorConvertible` — `safeContext`
///   já filtrou os campos sensíveis.
public enum LogSanitizer {

    /// Comprimento máximo da `errorDescription` no metadata sanitizado.
    /// Trunca para evitar payload gigante no log mesmo se o erro tentar
    /// vazar bytes.
    public static let maxDescriptionLength: Int = 200

    /// Constrói `Logger.Metadata` segura para um `Error`.
    ///
    /// - `errorType`: nome qualificado do tipo (ex.: `Foundation.DecodingError`).
    /// - `errorDescription`: `localizedDescription` truncada e com control
    ///   chars neutralizados.
    ///
    /// Pode receber `extra` para adicionar campos contextuais já sanitizados
    /// pelo caller (ex.: `eventId`, `route`).
    public static func metadata(
        for error: Error,
        extra: Logger.Metadata = [:]
    ) -> Logger.Metadata {
        var meta: Logger.Metadata = [
            "errorType": .string(String(reflecting: type(of: error))),
            "errorDescription": .string(safeDescription(error))
        ]
        for (k, v) in extra { meta[k] = v }
        return meta
    }

    /// Sumário curto seguro: apenas o tipo qualificado.
    /// Use para interpolação inline em mensagem do log
    /// (`logger.error("Pipeline failed: \(LogSanitizer.summary(for: error))")`).
    public static func summary(for error: Error) -> String {
        String(reflecting: type(of: error))
    }

    /// `localizedDescription` truncada, com `\n`/`\r`/`\t` neutralizados para
    /// frustrar log injection (atacante consegue emitir linha falsa em log).
    private static func safeDescription(_ error: Error) -> String {
        let raw = error.localizedDescription
        let neutralized = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if neutralized.count <= maxDescriptionLength {
            return neutralized
        }
        let endIndex = neutralized.index(neutralized.startIndex, offsetBy: maxDescriptionLength)
        return String(neutralized[..<endIndex]) + "…"
    }
}
