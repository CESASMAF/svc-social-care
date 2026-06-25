import Foundation

/// Aggregate root do bounded context **Assessment** (ADR-019 + ADR-024).
///
/// **Pré-fix:** os 7 módulos opcionais de Assessment viviam dentro de
/// `Patient` (god aggregate). Editores concorrentes em módulos diferentes
/// competiam pelo mesmo `Patient.version` — optimistic lock falhava sem
/// conflito real. Save reescrevia o agregado inteiro.
///
/// **Pós-fix (Fase 4 — T-024.a EXPAND):** módulos migram para este
/// agregado próprio. Referencia o paciente por **identidade**
/// (`patientId: PatientId`) — Vernon Rule "Reference Other Aggregates by
/// Identity" (Implementing DDD, p. 365).
///
/// **Estado da migração (este PR):** apenas EXPAND.
/// - `Patient.housingCondition?` etc. **continuam existindo** —
///   handlers atuais preservam comportamento.
/// - `PatientAssessmentRepository` foi criado e está disponível, mas
///   ainda não é chamado pelos use cases existentes.
/// - Migration cria a tabela `patient_assessments` vazia + backfill
///   idempotente — dados ficam disponíveis em ambos os lados.
///
/// **Próximos PRs (release N+1, N+2):**
/// - DUAL-WRITE: handlers `UpdateHousingCondition*`, etc., escrevem em
///   ambos os repositórios.
/// - CUTOVER: leitura migra para `patient_assessments` via
///   `GetFullPatientProfileQuery` que faz JOIN.
/// - CONTRACT: drop colunas `hc_*`/`csn_*`/`shs_*`/`ses_*` em `patients`.
///
/// ## Por que `PatientAssessment` e não outro nome?
///
/// Termo do glossário: "avaliação social do paciente" — conjunto de
/// observações sobre moradia, renda, educação, saúde, rede de apoio.
/// Mantém familiaridade com `Application/Assessment/` que já existe.
public struct PatientAssessment: EventSourcedAggregate, EventSourcedAggregateInternal {

    // MARK: - EventSourcedAggregate Conformance

    /// Identidade própria do agregado. **Coincide** com `patientId` —
    /// relação 1:0..1 com `Patient`. Usar tipo `PatientId` (não criar
    /// `AssessmentId` próprio) reflete a invariante.
    public var id: PatientId { patientId }

    public internal(set) var version: Int

    public internal(set) var uncommittedEvents: [any DomainEvent] = []

    // MARK: - Identity

    /// Referência ao paciente por identidade (Vernon Rule). NUNCA compor
    /// `Patient` aqui — agregados não compõem outros agregados.
    public let patientId: PatientId

    // MARK: - Modules (7 módulos opcionais)

    public internal(set) var housingCondition: HousingCondition?
    public internal(set) var socioeconomicSituation: SocioEconomicSituation?
    public internal(set) var workAndIncome: WorkAndIncome?
    public internal(set) var educationalStatus: EducationalStatus?
    public internal(set) var healthStatus: HealthStatus?
    public internal(set) var communitySupportNetwork: CommunitySupportNetwork?
    public internal(set) var socialHealthSummary: SocialHealthSummary?

    // MARK: - Initializer

    /// Construtor para novo agregado vazio (sem nenhum módulo preenchido).
    /// `version` começa em 0; primeira save sem mudança gera apenas a row.
    public init(
        patientId: PatientId,
        version: Int = 0,
        housingCondition: HousingCondition? = nil,
        socioeconomicSituation: SocioEconomicSituation? = nil,
        workAndIncome: WorkAndIncome? = nil,
        educationalStatus: EducationalStatus? = nil,
        healthStatus: HealthStatus? = nil,
        communitySupportNetwork: CommunitySupportNetwork? = nil,
        socialHealthSummary: SocialHealthSummary? = nil
    ) {
        self.patientId = patientId
        self.version = version
        self.housingCondition = housingCondition
        self.socioeconomicSituation = socioeconomicSituation
        self.workAndIncome = workAndIncome
        self.educationalStatus = educationalStatus
        self.healthStatus = healthStatus
        self.communitySupportNetwork = communitySupportNetwork
        self.socialHealthSummary = socialHealthSummary
    }

    // MARK: - Internal Mutation (Outbox Pattern via EventSourcedAggregate)

    public mutating func addEvent(_ event: any DomainEvent) {
        self.uncommittedEvents.append(event)
        self.version += 1
    }

    public mutating func clearEvents() {
        self.uncommittedEvents.removeAll()
    }
}
