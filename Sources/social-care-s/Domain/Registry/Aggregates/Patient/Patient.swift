import Foundation

/// O Agregado Raiz (Root Aggregate) que centraliza todas as informações de um cidadão e seu núcleo familiar.
///
/// O `Patient` é o coração do sistema `social-care`. Ele garante a integridade de todas as intervenções,
/// diagnósticos e avaliações socioeconômicas vinculadas a uma pessoa e sua família.
///
/// - Note: Implementado como um tipo de valor (`struct`) para garantir segurança de concorrência
///   e imutabilidade previsível através de `EventSourcedAggregate`.
public struct Patient: EventSourcedAggregate, EventSourcedAggregateInternal {
    
    // MARK: - EventSourcedAggregate Conformance
    
    /// O identificador único do prontuário (Aggregate ID).
    public let id: PatientId
    
    /// A versão atual do agregado para controle de concorrência otimista.
    public internal(set) var version: Int
    
    /// Lista de eventos de domínio pendentes de persistência.
    public internal(set) var uncommittedEvents: [any DomainEvent] = []

    // MARK: - Core Identity
    
    /// O identificador global da pessoa associada a este prontuário.
    public let personId: PersonId

    /// Dados pessoais de identificação civil (nome, nascimento, etc).
    public let personalData: PersonalData?

    /// Documentos civis agrupados (CPF, NIS, RG).
    public let civilDocuments: CivilDocuments?

    /// O endereço principal de residência da família.
    public let address: Address?
    
    // MARK: - Collective Data (Family)
    
    /// Lista de membros que compõem o núcleo familiar.
    public internal(set) var familyMembers: [FamilyMember] = []
    
    /// Identidade étnica e social da família (Cigana, Quilombola, etc).
    public internal(set) var socialIdentity: SocialIdentity?

    // MARK: - Analytics & Assessment (v2.0)
    
    /// Condições de moradia e habitabilidade.
    public internal(set) var housingCondition: HousingCondition?
    
    /// Situação socioeconômica consolidada (rendas e benefícios).
    public internal(set) var socioeconomicSituation: SocioEconomicSituation?
    
    /// Novo módulo v2.0: Trabalho e Rendimento detalhado.
    public internal(set) var workAndIncome: WorkAndIncome?
    
    /// Novo módulo v2.0: Histórico educacional e condicionalidades.
    public internal(set) var educationalStatus: EducationalStatus?
    
    /// Novo módulo v2.0: Estado de saúde, deficiências e gestação.
    public internal(set) var healthStatus: HealthStatus?
    
    /// Rede de apoio comunitário e social.
    public internal(set) var communitySupportNetwork: CommunitySupportNetwork?
    
    /// Resumo de saúde social para fins de triagem rápida.
    public internal(set) var socialHealthSummary: SocialHealthSummary?

    // MARK: - Interventions & History
    
    /// Histórico de atendimentos realizados por profissionais.
    public internal(set) var appointments: [SocialCareAppointment] = []
    
    /// Encaminhamentos para a rede de proteção ou saúde.
    public internal(set) var referrals: [Referral] = []
    
    /// Relatórios de violação de direitos registrados.
    public internal(set) var violationReports: [RightsViolationReport] = []
    
    /// Novo módulo v2.0: Histórico de acolhimento e afastamento familiar.
    public internal(set) var placementHistory: PlacementHistory?
    
    /// Novo módulo v2.0: Informações de ingresso e atendimento inicial.
    public internal(set) var intakeInfo: IngressInfo?

    // MARK: - Lifecycle Status

    /// Status do paciente no sistema (lista de espera, ativo ou desligado).
    public internal(set) var status: PatientStatus = .active

    /// Informações do desligamento, preenchidas apenas quando status == .discharged.
    public internal(set) var dischargeInfo: DischargeInfo?

    /// Informações da desistência/retirada da fila, preenchidas quando saiu da fila sem ser admitido.
    public internal(set) var withdrawInfo: WithdrawInfo?

    // MARK: - Clinical Data
    
    /// Lista de diagnósticos clínicos (CIDs) do titular do prontuário.
    public internal(set) var diagnoses: [Diagnosis]

    // MARK: - Computed Analytics (Domain Projections)

    /// Conta quantos membros estão em uma determinada faixa etária.
    public func countMembers(inAgeRange range: ClosedRange<Int>, at date: TimeStamp = .now) -> Int {
        return familyMembers.filter { member in
            let age = member.birthDate.years(at: date)
            return range.contains(age)
        }.count
    }

    /// Verifica se há pelo menos um membro na faixa etária especificada.
    public func hasAnyMember(inAgeRange range: ClosedRange<Int>, at date: TimeStamp = .now) -> Bool {
        return familyMembers.contains { member in
            let age = member.birthDate.years(at: date)
            return range.contains(age)
        }
    }

    /// Verifica se um PersonId pertence à fronteira do agregado (titular ou familiares).
    public func containsPerson(_ targetId: PersonId) -> Bool {
        if self.personId == targetId { return true }
        return familyMembers.contains { $0.personId == targetId }
    }

    // MARK: - Lifecycle Guard

    /// Verifica se o paciente está ativo. Lança erro apropriado se estiver desligado ou na lista de espera.
    public func requireActive() throws {
        switch status {
        case .active:
            return
        case .discharged:
            throw PatientError.patientIsDischarged
        case .waitlisted:
            throw PatientError.patientIsWaitlisted
        }
    }

    // MARK: - Internal Mutation (Outbox Pattern)
    
    /// Adiciona um evento de domínio à lista de não persistidos.
    ///
    /// - Note: Detalhe de implementacao de `EventSourcedAggregateInternal`. Prefira usar `recordEvent(_:)`.
    public mutating func addEvent(_ event: any DomainEvent) {
        self.uncommittedEvents.append(event)
        self.version += 1
    }
    
    /// Limpa a lista de eventos pendentes após a persistência bem-sucedida.
    public mutating func clearEvents() {
        self.uncommittedEvents.removeAll()
    }
}
