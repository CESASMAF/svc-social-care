import Testing
@testable import social_care_s

/// Handler de erasure (ADR-039): consome `people.person.deleted` → anonimiza a
/// PII do `Patient` correlato. Idempotente e seguro para entrega at-least-once.
@Suite("AnonymizePatientPIICommandHandler (erasure LGPD · ADR-039)")
struct AnonymizePatientPIITests {

    @Test("Anonimiza a PII do Patient correlato e persiste")
    func anonymizesCorrelatedPatient() async throws {
        let repo = InMemoryPatientRepository()
        try await repo.seed(PatientFixture.createWithFullPII())
        let sut = AnonymizePatientPIICommandHandler(patientRepository: repo)

        try await sut.handle(AnonymizePatientPIICommand(
            personId: PatientFixture.defaultPersonId,
            actorId: "superadmin"
        ))

        let stored = try #require(try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId)))
        #expect(stored.personalData == nil)
        #expect(stored.civilDocuments == nil)
        #expect(stored.address == nil)
        #expect(!stored.diagnoses.isEmpty)   // registro clínico preservado
    }

    @Test("PersonId sem Patient correlato → no-op (não lança, não persiste)")
    func noOpWhenNoCorrelatedPatient() async throws {
        let repo = InMemoryPatientRepository()
        let sut = AnonymizePatientPIICommandHandler(patientRepository: repo)

        try await sut.handle(AnonymizePatientPIICommand(
            personId: PatientFixture.defaultPersonId,
            actorId: "superadmin"
        ))

        #expect(await repo.saveCallCount == 0)
    }

    @Test("Reentrega (já anonimizado) → no-op idempotente, sem segundo save")
    func idempotentOnRedelivery() async throws {
        let repo = InMemoryPatientRepository()
        try await repo.seed(PatientFixture.createWithFullPII())
        let sut = AnonymizePatientPIICommandHandler(patientRepository: repo)
        let command = AnonymizePatientPIICommand(
            personId: PatientFixture.defaultPersonId,
            actorId: "superadmin"
        )

        try await sut.handle(command)
        let savesAfterFirst = await repo.saveCallCount
        try await sut.handle(command)   // reentrega at-least-once
        let savesAfterSecond = await repo.saveCallCount

        #expect(savesAfterFirst == 1)
        #expect(savesAfterSecond == 1)   // não salvou de novo
    }

    @Test("PersonId inválido lança invalidPersonId")
    func invalidPersonIdThrows() async throws {
        let repo = InMemoryPatientRepository()
        let sut = AnonymizePatientPIICommandHandler(patientRepository: repo)

        await #expect(throws: AnonymizePatientPIIError.self) {
            try await sut.handle(AnonymizePatientPIICommand(personId: "not-a-uuid", actorId: "x"))
        }
    }
}
