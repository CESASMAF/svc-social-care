import Foundation

/// Helper de construção de `PatientAssessment` a partir do estado atual
/// de `Patient` (ADR-025 — fase DUAL-WRITE).
///
/// Durante a fase DUAL-WRITE da decomposição de Patient (T-024.a), o
/// estado real dos 7 módulos opcionais ainda vive em `Patient.<modulo>?`.
/// Cada handler de assessment, depois de chamar
/// `patientRepository.save(patient)`, copia o snapshot para um
/// `PatientAssessment` e chama `assessmentRepository.dualWriteUpsert(_:)`.
///
/// **Por que `version: 0`?** Repository.dualWriteUpsert ignora
/// optimistic lock — UPSERT puro. O lock real continua acontecendo no
/// `PatientRepository.save` (escrita primária da fase DUAL-WRITE).
/// Quando o CUTOVER chegar, este helper deixa de ser usado e os
/// handlers passam a chamar `assessmentRepository.save` com lock real.
///
/// Helper localizado em **Application** layer — composição cross-BC
/// (Registry → Assessment) é responsabilidade da Application, não do
/// Domain.
public enum PatientAssessmentBuilder {

    /// Snapshot dos 7 módulos opcionais do Patient como
    /// `PatientAssessment` desacoplado.
    public static func from(_ patient: Patient) -> PatientAssessment {
        PatientAssessment(
            patientId: patient.id,
            version: 0,
            housingCondition: patient.housingCondition,
            socioeconomicSituation: patient.socioeconomicSituation,
            workAndIncome: patient.workAndIncome,
            educationalStatus: patient.educationalStatus,
            healthStatus: patient.healthStatus,
            communitySupportNetwork: patient.communitySupportNetwork,
            socialHealthSummary: patient.socialHealthSummary
        )
    }
}
