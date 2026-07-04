import Testing
@testable import social_care_s

/// Regressão de segurança/compliance do erasure LGPD (ADR-039).
///
/// Garante o contrato cross-service: ao consumir `people.person.deleted` do
/// people-context, o social-care APAGA a PII direta do titular MAS PRESERVA o
/// registro clínico e emite o evento de auditoria — equilibrando o direito à
/// eliminação (LGPD Art. 18) com a retenção obrigatória (Art. 16, I; Art. 11).
@Suite("Regression: Security — erasure LGPD (ADR-039)")
struct ErasureRegressionTests {

    @Test("PEO-DELETE — anonimiza PII e preserva registro clínico + audit trail")
    func test_PEO_DELETE_anonymizes_pii_and_preserves_audit() async throws {
        // Arrange — Patient com PII (nome, CPF, endereço) + diagnóstico clínico.
        let repo = InMemoryPatientRepository()
        try await repo.seed(PatientFixture.createWithFullPII())
        let handler = AnonymizePatientPIICommandHandler(patientRepository: repo)

        // Act — consumir o evento de eliminação emitido pelo people-context.
        try await handler.handle(AnonymizePatientPIICommand(
            personId: PatientFixture.defaultPersonId,
            actorId: "superadmin"
        ))

        // Assert — PII direta apagada...
        let stored = try #require(try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId)))
        #expect(stored.personalData == nil)
        #expect(stored.civilDocuments == nil)   // CPF/NIS/RG/CNS apagados
        #expect(stored.address == nil)
        // ...registro clínico retido (obrigação legal — Art. 16, I)...
        #expect(!stored.diagnoses.isEmpty)
        // ...e a operação auditada: o agregado persistido carrega o
        // PatientPIIAnonymizedEvent que o Outbox relay publica.
        #expect(stored.uncommittedEvents.contains { $0 is PatientPIIAnonymizedEvent })
    }
}
