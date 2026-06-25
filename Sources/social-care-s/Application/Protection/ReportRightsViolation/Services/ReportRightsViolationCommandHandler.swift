import Foundation

/// Implementação do serviço Maestro para relato de violação de direitos.
public actor ReportRightsViolationCommandHandler: ReportRightsViolationUseCase {
    private let repository: any PatientRepository
    
    public init(repository: any PatientRepository) {
        self.repository = repository
    }
    
    public func handle(_ command: ReportRightsViolationCommand) async throws -> String {
        do {
            // 1. Parse
            let patientId = try PatientId(command.patientId)
            let victimId = try PersonId(command.victimId)
            let violationReportId = try command.id.map { try ViolationReportId($0) } ?? ViolationReportId()
            let reportDate = try command.reportDate.map { try TimeStamp($0) } ?? TimeStamp.now
            let incidentDate = try command.incidentDate.map { try TimeStamp($0) }
            
            guard let violationType = RightsViolationReport.ViolationType(rawValue: command.violationType) else {
                throw ReportRightsViolationError.invalidViolationType(command.violationType)
            }
            
            // 2. Fetch
            guard var patient = try await repository.find(byId: patientId) else {
                throw ReportRightsViolationError.patientNotFound
            }
            
            // 3. Domain Logic
            try patient.addRightsViolationReport(
                id: violationReportId,
                reportDate: reportDate,
                incidentDate: incidentDate,
                victimId: victimId,
                violationType: violationType,
                descriptionOfFact: command.descriptionOfFact,
                actionsTaken: command.actionsTaken ?? "",
                actorId: command.actorId,
                now: .now
            )
            
            // 4. Persistence & Events
            try await repository.save(patient)
            
            return violationReportId.description
            
        } catch {
            throw mapError(error, patientId: command.patientId)
        }
    }
}
