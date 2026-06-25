import Foundation

/// Implementação do serviço Maestro para registro de atendimentos.
public actor RegisterAppointmentCommandHandler: RegisterAppointmentUseCase {
    private let repository: any PatientRepository
    
    public init(repository: any PatientRepository) {
        self.repository = repository
    }
    
    public func handle(_ command: RegisterAppointmentCommand) async throws -> String {
        do {
            // 1. Parse
            let patientId = try PatientId(command.patientId)
            let professionalId = try ProfessionalId(command.professionalId)
            let date = try command.date.map { try TimeStamp($0) } ?? TimeStamp.now
            
            let type: SocialCareAppointment.AppointmentType
            if let typeString = command.type {
                guard let resolvedType = SocialCareAppointment.AppointmentType(rawValue: typeString) else {
                    throw RegisterAppointmentError.invalidType(received: typeString, expected: SocialCareAppointment.AppointmentType.allCases.map { $0.rawValue }.joined(separator: ", "))
                }
                type = resolvedType
            } else {
                type = .other
            }
            
            // 2. Fetch
            guard var patient = try await repository.find(byId: patientId) else {
                throw RegisterAppointmentError.patientNotFound
            }
            
            // 3. Domain Logic
            let appointmentId = AppointmentId()
            try patient.addAppointment(
                id: appointmentId,
                date: date,
                professionalInChargeId: professionalId,
                type: type,
                summary: command.summary ?? "",
                actionPlan: command.actionPlan ?? "",
                actorId: command.actorId,
                now: .now
            )
            
            // 4. Persistence & Events
            try await repository.save(patient)
            
            return appointmentId.description
            
        } catch {
            throw mapError(error, patientId: command.patientId)
        }
    }
}
