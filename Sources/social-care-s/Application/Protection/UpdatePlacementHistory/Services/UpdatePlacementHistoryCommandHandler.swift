import Foundation

public actor UpdatePlacementHistoryCommandHandler: UpdatePlacementHistoryUseCase {
    private let repository: any PatientRepository

    public init(repository: any PatientRepository) {
        self.repository = repository
    }

    public func handle(_ command: UpdatePlacementHistoryCommand) async throws {
        do {
            let patientId = try PatientId(command.patientId)
            guard var patient = try await repository.find(byId: patientId) else {
                throw UpdatePlacementHistoryError.patientNotFound
            }

            let registries = try command.registries.map { draft in
                let memberId = try PersonId(draft.memberId)
                guard patient.familyMembers.contains(where: { $0.personId == memberId }) else {
                    throw UpdatePlacementHistoryError.memberNotFound(draft.memberId)
                }

                let start = try TimeStamp(draft.startDate)
                let end = try draft.endDate.map { try TimeStamp($0) }

                return try PlacementRegistry(
                    memberId: memberId,
                    startDate: start,
                    endDate: end,
                    reason: draft.reason
                )
            }

            let history = PlacementHistory(
                familyId: patient.id,
                individualPlacements: registries,
                collectiveSituations: CollectiveSituations(
                    homeLossReport: command.collectiveSituations.homeLossReport,
                    thirdPartyGuardReport: command.collectiveSituations.thirdPartyGuardReport
                ),
                separationChecklist: SeparationChecklist(
                    adultInPrison: command.separationChecklist.adultInPrison,
                    adolescentInInternment: command.separationChecklist.adolescentInInternment
                )
            )

            try patient.validatePlacementCompatibility(history)
            try patient.updatePlacementHistory(history, actorId: command.actorId)

            try await repository.save(patient)

        } catch {
            throw mapError(error)
        }
    }
}
