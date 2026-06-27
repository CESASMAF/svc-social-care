import Foundation
import Logging

/// Anonimiza a PII direta de um `Patient` ao consumir `people.person.deleted`
/// (erasure LGPD — ADR-039).
///
/// Fluxo:
/// 1. Parse do `PersonId`.
/// 2. Busca o `Patient` correlato por `personId`.
/// 3. Se não houver prontuário correlato → no-op (nada a anonimizar).
/// 4. `anonymizePII` (idempotente no domínio).
/// 5. Persiste **apenas** se houve mutação (`uncommittedEvents` não vazio) —
///    evita conflito de optimistic lock em reentrega at-least-once.
public actor AnonymizePatientPIICommandHandler: AnonymizePatientPIIUseCase {
    private let patientRepository: any PatientRepository
    private let logger: Logger

    public init(patientRepository: any PatientRepository) {
        self.patientRepository = patientRepository
        self.logger = Logger(label: "anonymize-patient-pii")
    }

    public func handle(_ command: AnonymizePatientPIICommand) async throws {
        // 1. Parse
        let personId: PersonId
        do {
            personId = try PersonId(command.personId)
        } catch {
            logger.warning("Invalid PersonId in person.deleted event: \(command.personId)")
            throw AnonymizePatientPIIError.invalidPersonId(command.personId)
        }

        // 2. Busca o Patient correlato por personId
        guard var patient = try await patientRepository.find(byPersonId: personId) else {
            logger.info(
                "No patient correlated to PersonId — erasure no-op",
                metadata: ["personId": "\(command.personId)"]
            )
            return
        }

        // 3. Idempotência por ESTADO (seguro para entrega at-least-once): se a PII
        //    direta já foi removida (ou nunca existiu), nada a fazer — evita save
        //    redundante e conflito de optimistic lock em reentrega.
        let hasDirectPII = patient.personalData != nil
            || patient.civilDocuments != nil
            || patient.address != nil
        guard hasDirectPII else {
            logger.info(
                "Patient has no direct PII — erasure no-op",
                metadata: ["patientId": "\(patient.id.description)"]
            )
            return
        }

        // 4. Anonimiza + 5. persiste (PatientPIIAnonymizedEvent vai ao Outbox).
        patient.anonymizePII(actorId: command.actorId)
        try await patientRepository.save(patient)
        logger.info(
            "Patient PII anonymized (LGPD erasure)",
            metadata: ["patientId": "\(patient.id.description)"]
        )
    }
}
