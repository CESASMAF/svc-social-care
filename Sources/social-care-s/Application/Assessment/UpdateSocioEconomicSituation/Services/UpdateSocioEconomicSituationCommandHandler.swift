import Foundation

/// Implementação do serviço Maestro para atualização da situação socioeconômica.
public actor UpdateSocioEconomicSituationCommandHandler: UpdateSocioEconomicSituationUseCase {
    private let repository: any PatientRepository
    private let assessmentRepository: any PatientAssessmentRepository

    public init(
        repository: any PatientRepository,
        assessmentRepository: any PatientAssessmentRepository
    ) {
        self.repository = repository
        self.assessmentRepository = assessmentRepository
    }
    
    public func handle(_ command: UpdateSocioEconomicSituationCommand) async throws {
        do {
            // 1. Parse
            let patientId = try PatientId(command.patientId)
            
            let benefits = try command.situation.socialBenefits.map { draft in
                let beneficiaryId = try PersonId(draft.beneficiaryId)
                return try SocialBenefit(
                    benefitName: draft.benefitName,
                    // ADR-009: Double do Command → Money no domínio
                    amount: try Money(valorReal: draft.amount),
                    beneficiaryId: beneficiaryId
                )
            }

            let collection = try SocialBenefitsCollection(benefits)

            let situation = try SocioEconomicSituation(
                // ADR-009: Double do Command → Money no domínio
                totalFamilyIncome: try Money(valorReal: command.situation.totalFamilyIncome),
                incomePerCapita: try Money(valorReal: command.situation.incomePerCapita),
                receivesSocialBenefit: command.situation.receivesSocialBenefit,
                socialBenefits: collection,
                mainSourceOfIncome: command.situation.mainSourceOfIncome,
                hasUnemployed: command.situation.hasUnemployed
            )
            
            // 2. Fetch
            guard var patient = try await repository.find(byId: patientId) else {
                throw UpdateSocioEconomicSituationError.patientNotFound
            }
            
            // 3. Domain Logic
            try patient.updateSocioEconomicSituation(situation, actorId: command.actorId)
            
            // 4. Persistence & Events
            try await repository.save(patient)
            // 5. ADR-025 DUAL-WRITE.
            try await assessmentRepository.dualWriteUpsert(PatientAssessmentBuilder.from(patient))

        } catch {
            throw mapError(error, patientId: command.patientId)
        }
    }
}
