import Foundation

/// Implementação do serviço Maestro para criação de encaminhamentos.
public actor CreateReferralCommandHandler: CreateReferralUseCase {
    private let repository: any PatientRepository
    
    public init(repository: any PatientRepository) {
        self.repository = repository
    }
    
    public func handle(_ command: CreateReferralCommand) async throws -> String {
        do {
            // 1. Parse
            let patientId = try PatientId(command.patientId)
            let referredPersonId = try PersonId(command.referredPersonId)
            
            let requestingProfessionalId = try command.professionalId.map { try ProfessionalId($0) } ?? ProfessionalId()
            let date = try command.date.map { try TimeStamp($0) } ?? TimeStamp.now
            
            guard let destinationService = Referral.DestinationService(rawValue: command.destinationService) else {
                throw CreateReferralError.invalidDestinationService(command.destinationService)
            }
            
            // 2. Fetch
            guard var patient = try await repository.find(byId: patientId) else {
                throw CreateReferralError.patientNotFound
            }
            
            // 3. Domain Logic
            let referralId = ReferralId()
            try patient.addReferral(
                id: referralId,
                date: date,
                requestingProfessionalId: requestingProfessionalId,
                referredPersonId: referredPersonId,
                destinationService: destinationService,
                reason: command.reason,
                actorId: command.actorId,
                now: .now
            )
            
            // 4. Persistence & Events
            try await repository.save(patient)
            
            return referralId.description
            
        } catch {
            throw mapError(error, patientId: command.patientId)
        }
    }
}
