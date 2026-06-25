import Testing
import Foundation
@testable import social_care_s

@Suite("UpdatePlacementHistory Command Handler")
struct UpdatePlacementHistoryTests {

    private static let startDate = ISO8601DateFormatter().date(from: "2024-01-01T00:00:00Z")!
    private static let endDate = ISO8601DateFormatter().date(from: "2024-06-01T00:00:00Z")!

    @Test("Deve atualizar historico de acolhimento com sucesso")
    func successfulUpdate() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createWithAdditionalMemberActive()
        await repo.seed(patient)

        let memberId = PatientFixture.defaultMemberId

        let handler = UpdatePlacementHistoryCommandHandler(repository: repo)

        try await handler.handle(UpdatePlacementHistoryCommand(
            patientId: patient.id.description,
            registries: [
                .init(memberId: memberId,
                      startDate: Self.startDate,
                      endDate: Self.endDate,
                      reason: "Situacao de risco")
            ],
            collectiveSituations: .init(homeLossReport: nil, thirdPartyGuardReport: nil),
            separationChecklist: .init(adultInPrison: false, adolescentInInternment: false),
            actorId: "actor-1"
        ))

        let saved = await repo.stored(byId: patient.id)
        #expect(saved?.placementHistory != nil)
        #expect(saved?.placementHistory?.individualPlacements.count == 1)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar quando membro nao pertence a familia")
    func memberNotInFamily() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = UpdatePlacementHistoryCommandHandler(repository: repo)

        await #expect(throws: UpdatePlacementHistoryError.self) {
            try await handler.handle(UpdatePlacementHistoryCommand(
                patientId: patient.id.description,
                registries: [
                    .init(memberId: UUID().uuidString,
                          startDate: Self.startDate,
                          endDate: nil,
                          reason: "Motivo")
                ],
                collectiveSituations: .init(homeLossReport: nil, thirdPartyGuardReport: nil),
                separationChecklist: .init(adultInPrison: false, adolescentInInternment: false),
                actorId: "actor-1"
            ))
        }

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount == 0)
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = UpdatePlacementHistoryCommandHandler(repository: repo)

        await #expect(throws: UpdatePlacementHistoryError.self) {
            try await handler.handle(UpdatePlacementHistoryCommand(
                patientId: UUID().uuidString,
                registries: [],
                collectiveSituations: .init(homeLossReport: nil, thirdPartyGuardReport: nil),
                separationChecklist: .init(adultInPrison: false, adolescentInInternment: false),
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: handler serializa operacoes no mesmo actor")
    func actorSerialization() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createWithAdditionalMemberActive()
        await repo.seed(patient)

        let handler = UpdatePlacementHistoryCommandHandler(repository: repo)
        let memberId = PatientFixture.defaultMemberId

        // Primeira chamada
        try await handler.handle(UpdatePlacementHistoryCommand(
            patientId: patient.id.description,
            registries: [
                .init(memberId: memberId, startDate: Self.startDate, endDate: nil, reason: "Motivo 1")
            ],
            collectiveSituations: .init(homeLossReport: nil, thirdPartyGuardReport: nil),
            separationChecklist: .init(adultInPrison: false, adolescentInInternment: false),
            actorId: "actor-1"
        ))

        // Segunda chamada sobrescreve
        try await handler.handle(UpdatePlacementHistoryCommand(
            patientId: patient.id.description,
            registries: [
                .init(memberId: memberId, startDate: Self.startDate, endDate: Self.endDate, reason: "Motivo 2")
            ],
            collectiveSituations: .init(homeLossReport: "Relato", thirdPartyGuardReport: nil),
            separationChecklist: .init(adultInPrison: true, adolescentInInternment: false),
            actorId: "actor-2"
        ))

        let saved = await repo.stored(byId: patient.id)
        #expect(saved?.placementHistory?.individualPlacements.first?.reason == "Motivo 2")

        let saveCount = await repo.saveCallCount
        #expect(saveCount == 2)
    }
}
