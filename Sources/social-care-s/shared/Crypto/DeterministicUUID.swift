import Foundation
import Crypto

/// Deriva um `UUID` **determinístico** a partir de uma string de chave
/// natural (ADR-021).
///
/// **Problema:** mapper que usa `id: UUID()` inline gera ID novo a cada
/// chamada. Combinado com `deleteAndInsert`, destrói identidade física da
/// row no banco a cada save (S-H-P1/DB-6) — audit trail mente, triggers
/// `ON UPDATE` nunca disparam, FKs externas viáveis ficam impossíveis.
///
/// **Solução:** o `id` surrogate de uma row filha é derivado
/// criptograficamente da chave natural do domínio. Mesmas inputs →
/// mesmo UUID → mesma row no banco a cada save.
///
/// **Algoritmo:** SHA256 dos bytes da chave; usa os primeiros 16 bytes.
/// Bits da versão e variante são forçados para indicar UUIDv8 (custom)
/// conforme RFC 9562 — evita confusão com UUIDv4 (random) ou UUIDv5
/// (name-based SHA-1).
///
/// **Por que não UUIDv5?** RFC 4122 v5 usa SHA-1 (deprecado por colisões
/// teóricas) e exige um namespace UUID. SHA256 é mais robusto e nossa
/// chave já carrega o "namespace" implicitamente (`patient_diagnoses|...`).
///
/// **Uso:** sempre incluir o nome da tabela no início da chave (defesa
/// contra colisão entre tabelas com chaves naturais coincidentes):
///
/// ```swift
/// let id = DeterministicUUID.from("patient_diagnoses|\(patientId)|\(icdCode)|\(date.iso)")
/// ```
public enum DeterministicUUID {

    /// Constrói UUID determinístico de uma string de chave natural.
    ///
    /// - Parameter key: chave natural do domínio (incluir nome da tabela
    ///   como prefixo para evitar colisão entre tabelas).
    public static func from(_ key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        // SHA256 retorna 32 bytes; pegamos os 16 primeiros como base do UUID.
        var bytes = Array(digest.prefix(16))
        // RFC 9562 — UUIDv8 (custom): bits 4-7 do byte 6 = 0b1000.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        // RFC 4122 — variant: bits 6-7 do byte 8 = 0b10.
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
