import Foundation

/// Implementação do serviço Maestro para atribuição de cuidador principal.
public actor AssignPrimaryCaregiverCommandHandler: AssignPrimaryCaregiverUseCase {
    private let repository: any PatientRepository
    
    public init(repository: any PatientRepository) {
        self.repository = repository
    }
    
    public func handle(_ command: AssignPrimaryCaregiverCommand) async throws {
        do {
            // 1. Parse
            let patientId = try PatientId(command.patientId)
            let memberPersonId = try PersonId(command.memberPersonId)
            
            // 2. Fetch
            guard var patient = try await repository.find(byId: patientId) else {
                throw AssignPrimaryCaregiverError.patientNotFound
            }
            
            // 3. Domain Logic
            try patient.assignPrimaryCaregiver(identifiedBy: memberPersonId, actorId: command.actorId, at: TimeStamp.now)
            
            // 4. Persistence & Events
            try await repository.save(patient)
            
        } catch {
            throw mapError(error, patientId: command.patientId)
        }
    }
}
