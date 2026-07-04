import Foundation

/// DTO for decoding `people.person.deleted` events from people-context via NATS
/// (LGPD erasure — Art. 18). The payload carries only `personId` (no PII);
/// consumers anonymize/erase their correlated projections. See ADR-039.
///
/// Payload format:
/// ```json
/// {
///   "metadata": { "eventId": "...", "occurredAt": "...", "schemaVersion": "1.0.0" },
///   "actorId": "...",
///   "data": { "personId": "..." }
/// }
/// ```
struct PersonDeletedEvent: Codable, Sendable {
    let metadata: Metadata
    let actorId: String
    let data: PersonData

    struct Metadata: Codable, Sendable {
        let eventId: String
        let occurredAt: String
        let schemaVersion: String
    }

    struct PersonData: Codable, Sendable {
        let personId: String
    }
}
