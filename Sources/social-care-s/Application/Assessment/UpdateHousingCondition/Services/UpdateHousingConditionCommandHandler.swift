import Foundation

/// Implementação do serviço Maestro para atualização das condições de moradia.
public actor UpdateHousingConditionCommandHandler: UpdateHousingConditionUseCase {
    private let repository: any PatientRepository
    private let assessmentRepository: any PatientAssessmentRepository

    public init(
        repository: any PatientRepository,
        assessmentRepository: any PatientAssessmentRepository
    ) {
        self.repository = repository
        self.assessmentRepository = assessmentRepository
    }

    public func handle(_ command: UpdateHousingConditionCommand) async throws {
        do {
            // 1. Parse
            let patientId = try PatientId(command.patientId)
            
            guard let type = HousingCondition.ConditionType(rawValue: command.condition.type) else {
                throw UpdateHousingConditionError.invalidHousingType(command.condition.type)
            }
            guard let wall = HousingCondition.WallMaterial(rawValue: command.condition.wallMaterial) else {
                throw UpdateHousingConditionError.invalidWallMaterial(command.condition.wallMaterial)
            }
            guard let water = HousingCondition.WaterSupply(rawValue: command.condition.waterSupply) else {
                throw UpdateHousingConditionError.invalidWaterSupply(command.condition.waterSupply)
            }
            guard let electricity = HousingCondition.ElectricityAccess(rawValue: command.condition.electricityAccess) else {
                throw UpdateHousingConditionError.invalidElectricityAccess(command.condition.electricityAccess)
            }
            guard let sewage = HousingCondition.SewageDisposal(rawValue: command.condition.sewageDisposal) else {
                throw UpdateHousingConditionError.invalidSewageDisposal(command.condition.sewageDisposal)
            }
            guard let waste = HousingCondition.WasteCollection(rawValue: command.condition.wasteCollection) else {
                throw UpdateHousingConditionError.invalidWasteCollection(command.condition.wasteCollection)
            }
            guard let access = HousingCondition.AccessibilityLevel(rawValue: command.condition.accessibilityLevel) else {
                throw UpdateHousingConditionError.invalidAccessibilityLevel(command.condition.accessibilityLevel)
            }
            
            let condition = try HousingCondition(
                type: type,
                wallMaterial: wall,
                numberOfRooms: command.condition.numberOfRooms,
                numberOfBedrooms: command.condition.numberOfBedrooms,
                numberOfBathrooms: command.condition.numberOfBathrooms,
                waterSupply: water,
                hasPipedWater: command.condition.hasPipedWater,
                electricityAccess: electricity,
                sewageDisposal: sewage,
                wasteCollection: waste,
                accessibilityLevel: access,
                isInGeographicRiskArea: command.condition.isInGeographicRiskArea,
                hasDifficultAccess: command.condition.hasDifficultAccess,
                isInSocialConflictArea: command.condition.isInSocialConflictArea,
                hasDiagnosticObservations: command.condition.hasDiagnosticObservations
            )
            
            // 2. Fetch
            guard var patient = try await repository.find(byId: patientId) else {
                throw UpdateHousingConditionError.patientNotFound
            }
            
            // 3. Domain Logic
            try patient.updateHousingCondition(condition, actorId: command.actorId)
            
            // 4. Persistence & Events (escrita primária — outbox + lock)
            try await repository.save(patient)

            // 5. ADR-025 DUAL-WRITE: escrita secundária no novo agregado.
            // Sem optimistic lock; UPSERT idempotente. Falha aqui NÃO
            // reverte (4) — handler do CUTOVER fará compensação. Por
            // agora, log apenas se útil; trade-off documentado.
            try await assessmentRepository.dualWriteUpsert(
                PatientAssessmentBuilder.from(patient)
            )

        } catch {
            throw mapError(error, patientId: command.patientId)
        }
    }
}
