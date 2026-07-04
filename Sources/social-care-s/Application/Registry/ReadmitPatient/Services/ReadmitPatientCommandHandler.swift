import Foundation

/// Implementação do serviço para readmissão de pacientes.
public actor ReadmitPatientCommandHandler: ReadmitPatientUseCase {
    private let repository: any PatientRepository

    public init(repository: any PatientRepository) {
        self.repository = repository
    }

    public func handle(_ command: ReadmitPatientCommand) async throws {
        do {
            // 1. Parse
            let patientId = try PatientId(command.patientId)

            // 2. Fetch
            guard var patient = try await repository.find(byId: patientId) else {
                throw ReadmitPatientError.patientNotFound(command.patientId)
            }

            // 3. Domain
            try patient.readmit(notes: command.notes, actorId: command.actorId)

            // 4. Persist
            try await repository.save(patient)

            // 5. Publish events

        } catch {
            throw mapError(error, patientId: command.patientId)
        }
    }
}
