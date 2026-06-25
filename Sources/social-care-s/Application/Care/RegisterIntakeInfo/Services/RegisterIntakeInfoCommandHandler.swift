import Foundation

public actor RegisterIntakeInfoCommandHandler: RegisterIntakeInfoUseCase {
    private let repository: any PatientRepository
    private let lookupValidator: any LookupValidating

    public init(repository: any PatientRepository, lookupValidator: any LookupValidating) {
        self.repository = repository
        self.lookupValidator = lookupValidator
    }

    public func handle(_ command: RegisterIntakeInfoCommand) async throws {
        do {
            // 1. Parse
            let patientId = try PatientId(command.patientId)
            let ingressTypeId = try LookupId(command.ingressTypeId)

            // 2. Lookup Validation
            guard try await lookupValidator.exists(id: ingressTypeId, in: "dominio_tipo_ingresso") else {
                throw RegisterIntakeInfoError.invalidLookupId(table: "dominio_tipo_ingresso", id: ingressTypeId.description)
            }

            for draft in command.linkedSocialPrograms {
                let progId = try LookupId(draft.programId)
                guard try await lookupValidator.exists(id: progId, in: "dominio_programa_social") else {
                    throw RegisterIntakeInfoError.invalidLookupId(table: "dominio_programa_social", id: progId.description)
                }
            }

            // 3. Build VOs
            let programs = try command.linkedSocialPrograms.map { draft in
                ProgramLink(
                    programId: try LookupId(draft.programId),
                    observation: draft.observation
                )
            }

            let intakeInfo = try IngressInfo(
                ingressTypeId: ingressTypeId,
                originName: command.originName,
                originContact: command.originContact,
                serviceReason: command.serviceReason,
                linkedSocialPrograms: programs
            )

            // 4. Fetch
            guard var patient = try await repository.find(byId: patientId) else {
                throw RegisterIntakeInfoError.patientNotFound
            }

            // 5. Domain Logic
            try patient.updateIntakeInfo(intakeInfo, actorId: command.actorId)

            // 6. Persistence & Events
            try await repository.save(patient)

        } catch {
            if let e = error as? RegisterIntakeInfoError { throw e }
            throw mapError(error, patientId: command.patientId)
        }
    }
}
