import Testing
import Foundation
@testable import social_care_s

@Suite("UpdateWorkAndIncome Command Handler")
struct UpdateWorkAndIncomeTests {

    private func makeHandler(
        repo: InMemoryPatientRepository,
        lookup: any LookupValidating = AllowAllLookupValidator()
    ) -> UpdateWorkAndIncomeCommandHandler {
        UpdateWorkAndIncomeCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository(), lookupValidator: lookup)
    }

    @Test("Deve atualizar trabalho e renda com sucesso")
    func successfulUpdate() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let memberId = patient.personId.description
        let occId = UUID().uuidString

        let handler = makeHandler(repo: repo)

        try await handler.handle(UpdateWorkAndIncomeCommand(
            patientId: patient.id.description,
            individualIncomes: [
                .init(memberId: memberId, occupationId: occId, hasWorkCard: true, monthlyAmount: 2500.0)
            ],
            socialBenefits: [
                .init(benefitName: "Bolsa Familia", amount: 600.0, beneficiaryId: memberId)
            ],
            hasRetiredMembers: false,
            actorId: "actor-1"
        ))

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.workAndIncome != nil)
        #expect(saved?.workAndIncome?.individualIncomes.count == 1)
        #expect(saved?.workAndIncome?.socialBenefits.count == 1)
        #expect(saved?.workAndIncome?.hasRetiredMembers == false)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar com lookup invalido")
    func invalidLookup() async throws {
        let repo = InMemoryPatientRepository()
        let lookup = InMemoryLookupValidator()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdateWorkAndIncomeCommandHandler(repository: repo, assessmentRepository: InMemoryPatientAssessmentRepository(), lookupValidator: lookup)

        await #expect(throws: UpdateWorkAndIncomeError.self) {
            try await handler.handle(UpdateWorkAndIncomeCommand(
                patientId: patient.id.description,
                individualIncomes: [
                    .init(memberId: patient.personId.description,
                          occupationId: UUID().uuidString,
                          hasWorkCard: false, monthlyAmount: 1000.0)
                ],
                socialBenefits: [],
                hasRetiredMembers: false,
                actorId: "actor-1"
            ))
        }

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount == 0)
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = makeHandler(repo: repo)

        await #expect(throws: UpdateWorkAndIncomeError.self) {
            try await handler.handle(UpdateWorkAndIncomeCommand(
                patientId: UUID().uuidString,
                individualIncomes: [],
                socialBenefits: [],
                hasRetiredMembers: false,
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: atualizacoes concorrentes em patients distintos")
    func concurrentUpdates() async throws {
        let repo = InMemoryPatientRepository()
        let handler = makeHandler(repo: repo)

        let p1 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        let p2 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        await repo.seed(p1)
        await repo.seed(p2)

        let occ = UUID().uuidString

        async let r1: Void = handler.handle(UpdateWorkAndIncomeCommand(
            patientId: p1.id.description,
            individualIncomes: [.init(memberId: p1.personId.description, occupationId: occ, hasWorkCard: true, monthlyAmount: 3000)],
            socialBenefits: [],
            hasRetiredMembers: false,
            actorId: "actor-1"
        ))
        async let r2: Void = handler.handle(UpdateWorkAndIncomeCommand(
            patientId: p2.id.description,
            individualIncomes: [.init(memberId: p2.personId.description, occupationId: occ, hasWorkCard: false, monthlyAmount: 1500)],
            socialBenefits: [],
            hasRetiredMembers: true,
            actorId: "actor-2"
        ))

        try await r1
        try await r2

        let saved1 = try await repo.find(byPersonId: p1.personId)
        let saved2 = try await repo.find(byPersonId: p2.personId)
        #expect(saved1?.workAndIncome?.individualIncomes.first?.hasWorkCard == true)
        #expect(saved2?.workAndIncome?.hasRetiredMembers == true)
    }
}
