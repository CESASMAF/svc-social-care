import Foundation

/// Encoder/decoder JSON padronizados (ADR-022).
///
/// **Problema (S-H-P7):** `JSONEncoder()` ad-hoc espalhado por mappers,
/// HTTP handlers, NATS publisher e outros sites. Encoder default usa
/// `dateEncodingStrategy = .deferredToDate` (Double desde 2001 — formato
/// Apple não-portável). Audit trail acumulou eventos com Date em formatos
/// distintos:
///
/// - Mapper antigo: Date como Double (`746409600.0`).
/// - HTTP body: Date como ISO 8601 (`"2024-01-26T12:00:00Z"`).
/// - NATS publisher: Date como ISO 8601 (`.iso8601` configurado local).
///
/// **Solução:** porta única `JSONCodec.encoder` / `JSONCodec.decoder` com
/// `dateEncodingStrategy = .iso8601` em ambos. Toda camada IO/HTTP usa o
/// helper. Encoders ad-hoc viram lint failure.
///
/// **Por que ISO 8601?** Padrão internacional, lexicograficamente
/// ordenável, legível, suportado por todos os parsers JSON do mercado.
/// Default JS `JSON.stringify(new Date())` também produz ISO 8601 — zero
/// fricção com BFF/cliente.
public enum JSONCodec {

    /// Encoder JSON padronizado: Date como ISO 8601, Data como base64,
    /// chaves em camelCase (default Swift).
    ///
    /// Reuso seguro: `JSONEncoder` em Swift 6.3 é `Sendable` no nível de
    /// uso (cada chamada `encode(_:)` é independente).
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        return encoder
    }()

    /// Decoder JSON padronizado, simétrico ao encoder.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return decoder
    }()
}
