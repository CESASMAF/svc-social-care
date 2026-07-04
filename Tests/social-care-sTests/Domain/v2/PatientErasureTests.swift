import Testing
@testable import social_care_s

/// Erasure LGPD (ADR-039): `Patient.anonymizePII` remove a PII direta do titular
/// (`personalData`, `civilDocuments`, `address`) e preserva o registro clínico +
/// audit trail. Idempotente (seguro para entrega NATS at-least-once).
@Suite("Patient — anonymizePII (erasure LGPD · ADR-039)")
struct PatientErasureTests {

    @Test("Remove personalData, civilDocuments e address (PII direta)")
    func anonymizesDirectPII() throws {
        var patient = try PatientFixture.createWithFullPII()
        #expect(patient.personalData != nil)
        #expect(patient.civilDocuments != nil)
        #expect(patient.address != nil)

        patient.anonymizePII(actorId: "dpo-actor")

        #expect(patient.personalData == nil)
        #expect(patient.civilDocuments == nil)
        #expect(patient.address == nil)
    }

    @Test("Preserva registro clínico, status e identidade do agregado")
    func preservesClinicalAndIdentity() throws {
        var patient = try PatientFixture.createWithFullPII()
        let personIdBefore = patient.personId
        let idBefore = patient.id
        let diagnosesCount = patient.diagnoses.count
        let statusBefore = patient.status

        patient.anonymizePII(actorId: "dpo-actor")

        #expect(patient.personId == personIdBefore)   // correlação preservada
        #expect(patient.id == idBefore)
        #expect(patient.diagnoses.count == diagnosesCount)
        #expect(!patient.diagnoses.isEmpty)            // registro clínico retido
        #expect(patient.status == statusBefore)
    }

    @Test("Registra PatientPIIAnonymizedEvent e incrementa version")
    func recordsEventAndBumpsVersion() throws {
        var patient = try PatientFixture.createWithFullPII()
        let versionBefore = patient.version

        patient.anonymizePII(actorId: "dpo-actor")

        #expect(patient.version == versionBefore + 1)
        #expect(patient.uncommittedEvents.count == 1)
        #expect(patient.uncommittedEvents.first is PatientPIIAnonymizedEvent)
    }

    @Test("Idempotente — segunda chamada é no-op (sem evento, sem version bump)")
    func idempotent() throws {
        var patient = try PatientFixture.createWithFullPII()
        patient.anonymizePII(actorId: "dpo-actor")
        patient.clearEvents()
        let versionAfterFirst = patient.version

        patient.anonymizePII(actorId: "dpo-actor")   // já anonimizado

        #expect(patient.version == versionAfterFirst)
        #expect(patient.uncommittedEvents.isEmpty)
        #expect(patient.personalData == nil)
    }
}
