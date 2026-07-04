import Foundation

public actor UpdateHealthStatusCommandHandler: UpdateHealthStatusUseCase {
    private let repository: any PatientRepository
    private let assessmentRepository: any PatientAssessmentRepository
    private let lookupValidator: any LookupValidating

    public init(
        repository: any PatientRepository,
        assessmentRepository: any PatientAssessmentRepository,
        lookupValidator: any LookupValidating
    ) {
        self.repository = repository
        self.assessmentRepository = assessmentRepository
        self.lookupValidator = lookupValidator
    }

    public func handle(_ command: UpdateHealthStatusCommand) async throws {
        do {
            // 1. Parse
            let patientId = try PatientId(command.patientId)

            // 2. Lookup Validation
            for draft in command.deficiencies {
                let typeId = try LookupId(draft.deficiencyTypeId)
                guard try await lookupValidator.exists(id: typeId, in: "dominio_tipo_deficiencia") else {
                    throw UpdateHealthStatusError.invalidLookupId(table: "dominio_tipo_deficiencia", id: typeId.description)
                }
            }

            // 3. Build VOs
            let deficiencies = try command.deficiencies.map { draft in
                MemberDeficiency(
                    memberId: try PersonId(draft.memberId),
                    deficiencyTypeId: try LookupId(draft.deficiencyTypeId),
                    needsConstantCare: draft.needsConstantCare,
                    responsibleCaregiverName: draft.responsibleCaregiverName
                )
            }

            let pregnants = try command.gestatingMembers.map { draft in
                PregnantMember(
                    memberId: try PersonId(draft.memberId),
                    monthsGestation: draft.monthsGestation,
                    startedPrenatalCare: draft.startedPrenatalCare
                )
            }

            let careNeeds = try command.constantCareNeeds.map { try PersonId($0) }

            // 4. Fetch
            guard var patient = try await repository.find(byId: patientId) else {
                throw UpdateHealthStatusError.patientNotFound
            }

            let healthStatus = HealthStatus(
                familyId: patient.id,
                deficiencies: deficiencies,
                gestatingMembers: pregnants,
                constantCareNeeds: careNeeds,
                foodInsecurity: command.foodInsecurity
            )

            // 5. Domain Logic
            try patient.updateHealthStatus(healthStatus, actorId: command.actorId)

            // 6. Persistence & Events
            try await repository.save(patient)
            // 7. ADR-025 DUAL-WRITE.
            try await assessmentRepository.dualWriteUpsert(PatientAssessmentBuilder.from(patient))

        } catch {
            throw mapError(error, patientId: command.patientId)
        }
    }
}
