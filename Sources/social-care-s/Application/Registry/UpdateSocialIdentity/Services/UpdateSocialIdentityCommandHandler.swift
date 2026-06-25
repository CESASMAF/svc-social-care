import Foundation

public actor UpdateSocialIdentityCommandHandler: UpdateSocialIdentityUseCase {
    private let repository: any PatientRepository
    private let lookupValidator: any LookupValidating

    public init(repository: any PatientRepository, lookupValidator: any LookupValidating) {
        self.repository = repository
        self.lookupValidator = lookupValidator
    }

    public func handle(_ command: UpdateSocialIdentityCommand) async throws {
        do {
            let patientId = try PatientId(command.patientId)
            let typeId = try LookupId(command.typeId)
            guard try await lookupValidator.exists(id: typeId, in: "dominio_tipo_identidade") else {
                throw UpdateSocialIdentityError.invalidLookupId(table: "dominio_tipo_identidade", id: typeId.description)
            }

            let newIdentity = try SocialIdentity(
                typeId: typeId,
                otherDescription: command.description
            )

            guard var patient = try await repository.find(byId: patientId) else {
                throw UpdateSocialIdentityError.patientNotFound
            }

            try patient.updateSocialIdentity(newIdentity, actorId: command.actorId)

            try await repository.save(patient)

        } catch {
            throw mapError(error, patientId: command.patientId)
        }
    }
}
