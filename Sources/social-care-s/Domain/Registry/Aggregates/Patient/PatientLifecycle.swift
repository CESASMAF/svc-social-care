import Foundation

extension Patient {

    // MARK: - Lifecycle & Factory

    /// Inicializa um novo agregado `Patient` com validações de integridade v2.0.
    ///
    /// - Parameters:
    ///   - id: Identificador único do prontuário.
    ///   - personId: Identificador global da pessoa titular.
    ///   - personalData: Dados de identificação civil.
    ///   - civilDocuments: Documentos agrupados (CPF, NIS, RG).
    ///   - address: Endereço principal.
    ///   - diagnoses: Lista inicial de diagnósticos (obrigatória).
    ///   - familyMembers: Lista de membros da família.
    ///   - prRelationshipId: O identificador de lookup que define a Pessoa de Referência (PR).
    ///   - now: Instante da criação para fins de auditoria.
    /// - Throws: `PatientError.initialDiagnosesCantBeEmpty` ou erros de PR.
    public init(
        id: PatientId,
        personId: PersonId,
        personalData: PersonalData? = nil,
        civilDocuments: CivilDocuments? = nil,
        address: Address? = nil,
        diagnoses: [Diagnosis],
        familyMembers: [FamilyMember] = [],
        prRelationshipId: LookupId,
        actorId: String,
        now: TimeStamp = .now
    ) throws {

        guard !diagnoses.isEmpty else {
            throw PatientError.initialDiagnosesCantBeEmpty
        }

        // Validação Versão 2.0: Exatamente uma Pessoa de Referência (PR)
        let prCount = familyMembers.filter { $0.relationshipId == prRelationshipId }.count
        guard prCount == 1 else {
            if prCount == 0 { throw PatientError.mustHaveExactlyOnePrimaryReference }
            throw PatientError.multiplePrimaryReferencesNotAllowed
        }

        self = Patient(
            id: id,
            version: 0,
            personId: personId,
            personalData: personalData,
            civilDocuments: civilDocuments,
            address: address,
            diagnoses: diagnoses
        )
        self.familyMembers = familyMembers

        self.recordEvent(PatientCreatedEvent(
            patientId: id.description,
            personId: personId.description,
            actorId: actorId,
            occurredAt: now.date
        ))
    }

    /// Reconstitui o agregado `Patient` a partir de um estado persistido.
    ///
    /// Usado pelos adaptadores de infraestrutura (IO) para carregar o agregado do banco.
    /// - Note: Este método não gera eventos de domínio nem valida regras de negócio mutáveis.
    public static func reconstitute(
        id: PatientId,
        version: Int,
        personId: PersonId,
        personalData: PersonalData? = nil,
        civilDocuments: CivilDocuments? = nil,
        address: Address? = nil,
        diagnoses: [Diagnosis],
        familyMembers: [FamilyMember] = [],
        appointments: [SocialCareAppointment] = [],
        referrals: [Referral] = [],
        violationReports: [RightsViolationReport] = [],
        housingCondition: HousingCondition? = nil,
        socioeconomicSituation: SocioEconomicSituation? = nil,
        workAndIncome: WorkAndIncome? = nil,
        educationalStatus: EducationalStatus? = nil,
        healthStatus: HealthStatus? = nil,
        communitySupportNetwork: CommunitySupportNetwork? = nil,
        socialHealthSummary: SocialHealthSummary? = nil,
        socialIdentity: SocialIdentity? = nil,
        placementHistory: PlacementHistory? = nil,
        intakeInfo: IngressInfo? = nil,
        status: PatientStatus = .waitlisted,
        dischargeInfo: DischargeInfo? = nil,
        withdrawInfo: WithdrawInfo? = nil
    ) -> Patient {
        var patient = Patient(
            id: id,
            version: version,
            personId: personId,
            personalData: personalData,
            civilDocuments: civilDocuments,
            address: address,
            diagnoses: diagnoses
        )

        patient.familyMembers = familyMembers
        patient.appointments = appointments
        patient.referrals = referrals
        patient.violationReports = violationReports
        patient.housingCondition = housingCondition
        patient.socioeconomicSituation = socioeconomicSituation
        patient.workAndIncome = workAndIncome
        patient.educationalStatus = educationalStatus
        patient.healthStatus = healthStatus
        patient.communitySupportNetwork = communitySupportNetwork
        patient.socialHealthSummary = socialHealthSummary
        patient.socialIdentity = socialIdentity
        patient.placementHistory = placementHistory
        patient.intakeInfo = intakeInfo
        patient.status = status
        patient.dischargeInfo = dischargeInfo
        patient.withdrawInfo = withdrawInfo

        return patient
    }

    // MARK: - Discharge & Readmit

    /// Desliga formalmente o paciente do acompanhamento.
    ///
    /// - Throws: `PatientError.alreadyDischarged` se o status atual não for `.active`.
    /// - Throws: `DischargeInfoError` se a validação do `DischargeInfo` falhar.
    public mutating func discharge(reason: DischargeReason, notes: String?, actorId: String, now: TimeStamp = .now) throws {
        switch status {
        case .active:
            break
        case .discharged:
            throw PatientError.alreadyDischarged
        case .waitlisted:
            throw PatientError.cannotDischargeWaitlisted
        }
        let info = try DischargeInfo(reason: reason, notes: notes, dischargedAt: now, dischargedBy: actorId)
        self.status = .discharged
        self.dischargeInfo = info
        self.recordEvent(PatientDischargedEvent(
            patientId: id.description,
            personId: personId.description,
            actorId: actorId,
            reason: reason.rawValue,
            notes: info.notes,
            occurredAt: now.date
        ))
    }

    /// Readmite um paciente previamente desligado, retomando o acompanhamento.
    ///
    /// - Throws: `PatientError.alreadyActive` se o status atual não for `.discharged`.
    /// - Throws: `DischargeInfoError.notesExceedMaxLength` se as notas excederem 1000 caracteres.
    public mutating func readmit(notes: String?, actorId: String, now: TimeStamp = .now) throws {
        switch status {
        case .discharged:
            break
        case .active:
            throw PatientError.alreadyActive
        case .waitlisted:
            throw PatientError.cannotReadmitWaitlisted
        }
        if let notes, notes.count > 1000 {
            throw DischargeInfoError.notesExceedMaxLength(notes.count)
        }
        self.status = .active
        self.dischargeInfo = nil
        self.withdrawInfo = nil
        self.recordEvent(PatientReadmittedEvent(
            patientId: id.description,
            personId: personId.description,
            actorId: actorId,
            notes: notes,
            occurredAt: now.date
        ))
    }

    // MARK: - Waitlist Lifecycle

    /// Admite um paciente da lista de espera para acompanhamento ativo.
    ///
    /// - Throws: `PatientError.alreadyActive` se já estiver ativo.
    /// - Throws: `PatientError.cannotAdmitDischarged` se estiver desligado.
    public mutating func admit(actorId: String, now: TimeStamp = .now) throws {
        switch status {
        case .active:
            throw PatientError.alreadyActive
        case .discharged:
            throw PatientError.cannotAdmitDischarged
        case .waitlisted:
            self.status = .active
            self.recordEvent(PatientAdmittedEvent(
                patientId: id.description,
                personId: personId.description,
                actorId: actorId,
                occurredAt: now.date
            ))
        }
    }

    /// Remove o paciente da lista de espera sem admiti-lo.
    ///
    /// - Throws: `PatientError.alreadyDischarged` se já estiver desligado.
    /// - Throws: `PatientError.alreadyActive` se estiver ativo (use discharge ao invés).
    /// - Throws: `WithdrawInfoError` se a validação do `WithdrawInfo` falhar.
    public mutating func withdraw(reason: WithdrawReason, notes: String?, actorId: String, now: TimeStamp = .now) throws {
        switch status {
        case .discharged:
            throw PatientError.alreadyDischarged
        case .active:
            throw PatientError.alreadyActive
        case .waitlisted:
            let info = try WithdrawInfo(reason: reason, notes: notes, withdrawnAt: now, withdrawnBy: actorId)
            self.status = .discharged
            self.withdrawInfo = info
            self.recordEvent(PatientWithdrawnFromWaitlistEvent(
                patientId: id.description,
                personId: personId.description,
                actorId: actorId,
                reason: reason.rawValue,
                notes: info.notes,
                occurredAt: now.date
            ))
        }
    }

    // MARK: - Erasure (LGPD — ADR-039)

    /// Anonimiza a PII direta do titular ao consumir `people.person.deleted` do
    /// people-context (erasure LGPD, Art. 18). Remove `personalData`,
    /// `civilDocuments` e `address`.
    ///
    /// A anonimização é a **remoção** dos VOs (campos opcionais → `nil`): os VOs
    /// não admitem valor "anonimizado parcial" (ex.: `CPF`/`PersonalData` exigem
    /// valor válido no `init`), então não há placeholder — zerar é a forma correta.
    ///
    /// PRESERVA (retenção sob obrigação legal — LGPD Art. 16, I; Art. 11, II.a/d):
    /// `diagnoses` e assessments (registro clínico), `status`, `id`/`personId`
    /// (correlação) e o audit trail. `familyMembers` (terceiros) também são
    /// preservados — sujeitos a erasure próprio se solicitado.
    ///
    /// Idempotente: se a PII direta já foi removida, é **no-op** — não registra
    /// evento nem incrementa `version`. Seguro para entrega NATS at-least-once.
    ///
    /// - Note: Não é `delete` (CRU/No-Delete preservado) — o prontuário continua
    ///   existindo, apenas sem a PII direta do titular.
    public mutating func anonymizePII(actorId: String, now: TimeStamp = .now) {
        guard personalData != nil || civilDocuments != nil || address != nil else {
            return
        }
        self.personalData = nil
        self.civilDocuments = nil
        self.address = nil
        self.recordEvent(PatientPIIAnonymizedEvent(
            patientId: id.description,
            personId: personId.description,
            actorId: actorId,
            occurredAt: now.date
        ))
    }

    /// Inicializador privado para uso exclusivo em factory e reconstituição.
    private init(
        id: PatientId,
        version: Int,
        personId: PersonId,
        personalData: PersonalData?,
        civilDocuments: CivilDocuments?,
        address: Address?,
        diagnoses: [Diagnosis]
    ) {
        self.id = id
        self.version = version
        self.uncommittedEvents = []
        self.personId = personId
        self.personalData = personalData
        self.civilDocuments = civilDocuments
        self.address = address
        self.diagnoses = diagnoses
    }
}
