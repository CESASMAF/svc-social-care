import Foundation

public actor UpdateWorkAndIncomeCommandHandler: UpdateWorkAndIncomeUseCase {
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

    public func handle(_ command: UpdateWorkAndIncomeCommand) async throws {
        do {
            // 1. Parse
            let patientId = try PatientId(command.patientId)

            // 2. Lookup Validation
            for draft in command.individualIncomes {
                let occId = try LookupId(draft.occupationId)
                guard try await lookupValidator.exists(id: occId, in: "dominio_condicao_ocupacao") else {
                    throw UpdateWorkAndIncomeError.invalidLookupId(table: "dominio_condicao_ocupacao", id: occId.description)
                }
            }

            // 3. Build VOs (ADR-009 — converte Double do Command para Money no domínio)
            let incomes = try command.individualIncomes.map { draft in
                WorkIncomeVO(
                    memberId: try PersonId(draft.memberId),
                    occupationId: try LookupId(draft.occupationId),
                    hasWorkCard: draft.hasWorkCard,
                    monthlyAmount: try Money(valorReal: draft.monthlyAmount)
                )
            }

            let benefits = try command.socialBenefits.map { draft in
                try SocialBenefit(
                    benefitName: draft.benefitName,
                    amount: try Money(valorReal: draft.amount),
                    beneficiaryId: try PersonId(draft.beneficiaryId)
                )
            }

            // 4. Fetch
            guard var patient = try await repository.find(byId: patientId) else {
                throw UpdateWorkAndIncomeError.patientNotFound
            }

            let workAndIncome = WorkAndIncome(
                familyId: patient.id,
                individualIncomes: incomes,
                socialBenefits: benefits,
                hasRetiredMembers: command.hasRetiredMembers
            )

            // 5. Domain Logic
            try patient.updateWorkAndIncome(workAndIncome, actorId: command.actorId)

            // 6. Persistence & Events
            try await repository.save(patient)
            // 7. ADR-025 DUAL-WRITE.
            try await assessmentRepository.dualWriteUpsert(PatientAssessmentBuilder.from(patient))

        } catch {
            throw mapError(error, patientId: command.patientId)
        }
    }
}
