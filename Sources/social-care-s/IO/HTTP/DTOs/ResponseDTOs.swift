import Vapor

// MARK: - Generic Envelope

struct StandardResponse<T: Content>: Content {
    let data: T
    let meta: ResponseMeta

    init(data: T) {
        self.data = data
        self.meta = ResponseMeta(timestamp: Date())
    }
}

struct ResponseMeta: Content {
    let timestamp: Date
}

struct PaginatedMeta: Content {
    let timestamp: Date
    let pageSize: Int
    let totalCount: Int
    let hasMore: Bool
    let nextCursor: String?
}

struct PaginatedResponse<T: Content>: Content {
    let data: T
    let meta: PaginatedMeta

    init(data: T, pageSize: Int, totalCount: Int, hasMore: Bool, nextCursor: String?) {
        self.data = data
        self.meta = PaginatedMeta(
            timestamp: Date(),
            pageSize: pageSize,
            totalCount: totalCount,
            hasMore: hasMore,
            nextCursor: nextCursor
        )
    }
}

struct IdResponse: Content {
    let id: String
}

// MARK: - Patient Response (GET completo)

struct PatientResponse: Content {
    let patientId: String
    let personId: String
    let version: Int
    let status: String
    let dischargeInfo: DischargeInfoResponse?
    let withdrawInfo: WithdrawInfoResponse?
    let personalData: PersonalDataResponse?
    let civilDocuments: CivilDocumentsResponse?
    let address: AddressResponse?
    let socialIdentity: SocialIdentityResponse?
    let familyMembers: [FamilyMemberResponse]
    let diagnoses: [DiagnosisResponse]
    let housingCondition: HousingConditionResponse?
    let socioeconomicSituation: SocioEconomicResponse?
    let workAndIncome: WorkAndIncomeResponse?
    let educationalStatus: EducationalStatusResponse?
    let healthStatus: HealthStatusResponse?
    let communitySupportNetwork: CommunitySupportNetworkResponse?
    let socialHealthSummary: SocialHealthSummaryResponse?
    let placementHistory: PlacementHistoryResponse?
    let intakeInfo: IngressInfoResponse?
    let appointments: [AppointmentResponse]
    let referrals: [ReferralResponse]
    let violationReports: [ViolationReportResponse]
    let computedAnalytics: ComputedAnalyticsResponse

    init(from p: Patient) {
        self.patientId = p.id.description
        self.personId = p.personId.description
        self.version = p.version
        self.status = p.status.rawValue
        self.dischargeInfo = p.dischargeInfo.map { DischargeInfoResponse(from: $0) }
        self.withdrawInfo = p.withdrawInfo.map { WithdrawInfoResponse(from: $0) }
        self.personalData = p.personalData.map { PersonalDataResponse(from: $0) }
        self.civilDocuments = p.civilDocuments.map { CivilDocumentsResponse(from: $0) }
        self.address = p.address.map { AddressResponse(from: $0) }
        self.socialIdentity = p.socialIdentity.map { SocialIdentityResponse(from: $0) }
        self.familyMembers = p.familyMembers.map { FamilyMemberResponse(from: $0) }
        self.diagnoses = p.diagnoses.map { DiagnosisResponse(from: $0) }
        self.housingCondition = p.housingCondition.map { HousingConditionResponse(from: $0) }
        self.socioeconomicSituation = p.socioeconomicSituation.map { SocioEconomicResponse(from: $0) }
        self.workAndIncome = p.workAndIncome.map { WorkAndIncomeResponse(from: $0) }
        self.educationalStatus = p.educationalStatus.map { EducationalStatusResponse(from: $0) }
        self.healthStatus = p.healthStatus.map { HealthStatusResponse(from: $0) }
        self.communitySupportNetwork = p.communitySupportNetwork.map { CommunitySupportNetworkResponse(from: $0) }
        self.socialHealthSummary = p.socialHealthSummary.map { SocialHealthSummaryResponse(from: $0) }
        self.placementHistory = p.placementHistory.map { PlacementHistoryResponse(from: $0) }
        self.intakeInfo = p.intakeInfo.map { IngressInfoResponse(from: $0) }
        self.appointments = p.appointments.map { AppointmentResponse(from: $0) }
        self.referrals = p.referrals.map { ReferralResponse(from: $0) }
        self.violationReports = p.violationReports.map { ViolationReportResponse(from: $0) }
        self.computedAnalytics = ComputedAnalyticsResponse(from: p)
    }
}

struct DischargeInfoResponse: Content {
    let reason: String
    let notes: String?
    let dischargedAt: Date
    let dischargedBy: String

    init(from d: DischargeInfo) {
        self.reason = d.reason.rawValue
        self.notes = d.notes
        self.dischargedAt = d.dischargedAt.date
        self.dischargedBy = d.dischargedBy
    }
}

struct WithdrawInfoResponse: Content {
    let reason: String
    let notes: String?
    let withdrawnAt: Date
    let withdrawnBy: String

    init(from w: WithdrawInfo) {
        self.reason = w.reason.rawValue
        self.notes = w.notes
        self.withdrawnAt = w.withdrawnAt.date
        self.withdrawnBy = w.withdrawnBy
    }
}

// MARK: - Patient Summary Response (listagem leve)

struct PatientSummaryResponse: Content {
    let patientId: String
    let personId: String
    let firstName: String?
    let lastName: String?
    let fullName: String?
    let primaryDiagnosis: String?
    let memberCount: Int
    let status: String

    init(from dto: PatientSummaryDTO) {
        self.patientId = dto.patientId
        self.personId = dto.personId
        self.firstName = dto.firstName
        self.lastName = dto.lastName
        self.fullName = dto.fullName
        self.primaryDiagnosis = dto.primaryDiagnosis
        self.memberCount = dto.memberCount
        self.status = dto.status
    }
}

// MARK: - Computed Analytics (calculated on GET)

struct ComputedAnalyticsResponse: Content {
    let housing: HousingAnalyticsResponse?
    let financial: FinancialIndicatorsResponse?
    let ageProfile: AgeProfileResponse
    let educationalVulnerabilities: EducationalVulnerabilityResponse?

    init(from p: Patient) {
        let memberCount = p.familyMembers.count + 1
        let now = TimeStamp.now

        // Housing density
        if let hc = p.housingCondition {
            let density = HousingAnalyticsService.density(
                forMembers: memberCount, inBedrooms: hc.numberOfBedrooms
            )
            self.housing = HousingAnalyticsResponse(
                density: density,
                isOvercrowded: density > 3.0
            )
        } else {
            self.housing = nil
        }

        // Financial indicators
        if let wi = p.workAndIncome {
            let indicators = FinancialAnalyticsService.calculate(
                workIncomes: wi.individualIncomes.map {
                    WorkIncome(memberId: $0.memberId, monthlyAmount: $0.monthlyAmount)
                },
                socialBenefits: wi.socialBenefits,
                memberCount: memberCount
            )
            self.financial = FinancialIndicatorsResponse(
                // ADR-009: indicators são Money — DTO HTTP serializa como Double (valorReal).
                totalWorkIncome: indicators.totalWorkIncome.valorReal,
                perCapitaWorkIncome: indicators.perCapitaWorkIncome.valorReal,
                totalGlobalIncome: indicators.totalGlobalIncome.valorReal,
                perCapitaGlobalIncome: indicators.perCapitaGlobalIncome.valorReal
            )
        } else {
            self.financial = nil
        }

        // Family age profile
        let profile = FamilyAnalytics.calculateAgeProfile(from: p.familyMembers, at: now)
        self.ageProfile = AgeProfileResponse(
            range0to6: profile.count(for: .range0to6),
            range7to14: profile.count(for: .range7to14),
            range15to17: profile.count(for: .range15to17),
            range18to29: profile.count(for: .range18to29),
            range30to59: profile.count(for: .range30to59),
            range60to64: profile.count(for: .range60to64),
            range65to69: profile.count(for: .range65to69),
            range70Plus: profile.count(for: .range70Plus),
            totalMembers: memberCount
        )

        // Educational vulnerabilities
        if let edu = p.educationalStatus {
            let eduMembers: [EducationalMember] = edu.memberProfiles.compactMap { profile -> EducationalMember? in
                guard let fm = p.familyMembers.first(where: { $0.personId == profile.memberId }) else {
                    return nil
                }
                return EducationalMember(
                    personId: profile.memberId,
                    birthDate: fm.birthDate,
                    attendsSchool: profile.attendsSchool,
                    canReadWrite: profile.canReadWrite
                )
            }
            let report = EducationAnalyticsService.calculateVulnerabilities(for: eduMembers, at: now)
            self.educationalVulnerabilities = EducationalVulnerabilityResponse(
                notInSchool0to5: report.count(vulnerability: .notInSchool, ageRange: .range0to5),
                notInSchool6to14: report.count(vulnerability: .notInSchool, ageRange: .range6to14),
                notInSchool15to17: report.count(vulnerability: .notInSchool, ageRange: .range15to17),
                illiteracy10to17: report.count(vulnerability: .illiteracy, ageRange: .range10to17),
                illiteracy18to59: report.count(vulnerability: .illiteracy, ageRange: .range18to59),
                illiteracy60Plus: report.count(vulnerability: .illiteracy, ageRange: .range60Plus)
            )
        } else {
            self.educationalVulnerabilities = nil
        }
    }
}

struct HousingAnalyticsResponse: Content {
    let density: Double
    let isOvercrowded: Bool
}

struct FinancialIndicatorsResponse: Content {
    let totalWorkIncome: Double
    let perCapitaWorkIncome: Double
    let totalGlobalIncome: Double
    let perCapitaGlobalIncome: Double
}

struct AgeProfileResponse: Content {
    let range0to6, range7to14, range15to17: Int
    let range18to29, range30to59: Int
    let range60to64, range65to69, range70Plus: Int
    let totalMembers: Int
}

struct EducationalVulnerabilityResponse: Content {
    let notInSchool0to5, notInSchool6to14, notInSchool15to17: Int
    let illiteracy10to17, illiteracy18to59, illiteracy60Plus: Int
}

// MARK: - Sub-responses

struct PersonalDataResponse: Content {
    let firstName, lastName, motherName, nationality, sex: String
    let socialName, phone: String?
    let birthDate: Date
    init(from d: PersonalData) {
        firstName = d.firstName; lastName = d.lastName; motherName = d.motherName
        nationality = d.nationality; sex = d.sex.rawValue; socialName = d.socialName
        birthDate = d.birthDate.date; phone = d.phone
    }
}

struct CivilDocumentsResponse: Content {
    let cpf, nis: String?
    let rgDocument: RGDocumentResponse?
    let cns: CNSResponse?
    init(from d: CivilDocuments) {
        cpf = d.cpf?.formatted; nis = d.nis?.value
        rgDocument = d.rgDocument.map { RGDocumentResponse(from: $0) }
        cns = d.cns.map { CNSResponse(from: $0) }
    }
}

struct CNSResponse: Content {
    let number: String
    let cpf: String
    let qrCode: String?
    init(from d: CNS) {
        number = d.formatted; cpf = d.cpf.formatted; qrCode = d.qrCode
    }
}

struct RGDocumentResponse: Content {
    let number, issuingState, issuingAgency: String
    let issueDate: Date
    init(from d: RGDocument) {
        number = d.number; issuingState = d.issuingState
        issuingAgency = d.issuingAgency; issueDate = d.issueDate.date
    }
}

struct AddressResponse: Content {
    let cep: String?
    let isShelter: Bool
    let isHomeless: Bool
    let residenceLocation: String
    let street, neighborhood, number, complement: String?
    let state, city: String
    init(from d: Address) {
        cep = d.cep?.formatted; isShelter = d.isShelter; isHomeless = d.isHomeless
        residenceLocation = d.residenceLocation.rawValue
        street = d.street; neighborhood = d.neighborhood; number = d.number
        complement = d.complement; state = d.state; city = d.city
    }
}

struct SocialIdentityResponse: Content {
    let typeId: String
    let otherDescription: String?
    init(from d: SocialIdentity) {
        typeId = d.typeId.description; otherDescription = d.otherDescription
    }
}

struct FamilyMemberResponse: Content {
    let personId, relationshipId: String
    let isPrimaryCaregiver, residesWithPatient, hasDisability: Bool
    let requiredDocuments: [String]
    let birthDate: Date
    init(from m: FamilyMember) {
        personId = m.personId.description; relationshipId = m.relationshipId.description
        isPrimaryCaregiver = m.isPrimaryCaregiver; residesWithPatient = m.residesWithPatient
        hasDisability = m.hasDisability
        requiredDocuments = m.requiredDocuments.map { $0.rawValue }
        birthDate = m.birthDate.date
    }
}

struct DiagnosisResponse: Content {
    let icdCode, description: String
    let date: Date
    init(from d: Diagnosis) {
        icdCode = d.id.value; description = d.description; date = d.date.date
    }
}

struct HousingConditionResponse: Content {
    let type, wallMaterial, waterSupply, electricityAccess, sewageDisposal, wasteCollection, accessibilityLevel: String
    let numberOfRooms, numberOfBedrooms, numberOfBathrooms: Int
    let hasPipedWater, isInGeographicRiskArea, hasDifficultAccess, isInSocialConflictArea, hasDiagnosticObservations: Bool
    init(from h: HousingCondition) {
        type = h.type.rawValue; wallMaterial = h.wallMaterial.rawValue
        waterSupply = h.waterSupply.rawValue; electricityAccess = h.electricityAccess.rawValue
        sewageDisposal = h.sewageDisposal.rawValue; wasteCollection = h.wasteCollection.rawValue
        accessibilityLevel = h.accessibilityLevel.rawValue
        numberOfRooms = h.numberOfRooms; numberOfBedrooms = h.numberOfBedrooms
        numberOfBathrooms = h.numberOfBathrooms; hasPipedWater = h.hasPipedWater
        isInGeographicRiskArea = h.isInGeographicRiskArea; hasDifficultAccess = h.hasDifficultAccess
        isInSocialConflictArea = h.isInSocialConflictArea; hasDiagnosticObservations = h.hasDiagnosticObservations
    }
}

struct SocioEconomicResponse: Content {
    let totalFamilyIncome, incomePerCapita: Double
    let receivesSocialBenefit, hasUnemployed: Bool
    let mainSourceOfIncome: String
    let socialBenefits: [SocialBenefitResponse]
    init(from s: SocioEconomicSituation) {
        // ADR-009: Money → Double (valorReal) na serialização HTTP.
        totalFamilyIncome = s.totalFamilyIncome.valorReal; incomePerCapita = s.incomePerCapita.valorReal
        receivesSocialBenefit = s.receivesSocialBenefit; hasUnemployed = s.hasUnemployed
        mainSourceOfIncome = s.mainSourceOfIncome
        socialBenefits = s.socialBenefits.items.map { SocialBenefitResponse(from: $0) }
    }
}

struct SocialBenefitResponse: Content {
    let benefitName: String; let amount: Double; let beneficiaryId: String
    init(from b: SocialBenefit) {
        // ADR-009: Money → Double (valorReal) na serialização HTTP.
        benefitName = b.benefitName; amount = b.amount.valorReal; beneficiaryId = b.beneficiaryId.description
    }
}

struct WorkAndIncomeResponse: Content {
    let hasRetiredMembers: Bool
    let individualIncomes: [WorkIncomeResponse]
    let socialBenefits: [SocialBenefitResponse]
    init(from w: WorkAndIncome) {
        hasRetiredMembers = w.hasRetiredMembers
        individualIncomes = w.individualIncomes.map { WorkIncomeResponse(from: $0) }
        socialBenefits = w.socialBenefits.map { SocialBenefitResponse(from: $0) }
    }
}

struct WorkIncomeResponse: Content {
    let memberId, occupationId: String
    let hasWorkCard: Bool; let monthlyAmount: Double
    init(from i: WorkIncomeVO) {
        memberId = i.memberId.description; occupationId = i.occupationId.description
        // ADR-009: Money → Double (valorReal) na serialização HTTP.
        hasWorkCard = i.hasWorkCard; monthlyAmount = i.monthlyAmount.valorReal
    }
}

struct EducationalStatusResponse: Content {
    let memberProfiles: [EducationalProfileResponse]
    let programOccurrences: [ProgramOccurrenceResponse]
    init(from e: EducationalStatus) {
        memberProfiles = e.memberProfiles.map { EducationalProfileResponse(from: $0) }
        programOccurrences = e.programOccurrences.map { ProgramOccurrenceResponse(from: $0) }
    }
}

struct EducationalProfileResponse: Content {
    let memberId: String; let canReadWrite, attendsSchool: Bool; let educationLevelId: String
    init(from p: MemberEducationalProfile) {
        memberId = p.memberId.description; canReadWrite = p.canReadWrite
        attendsSchool = p.attendsSchool; educationLevelId = p.educationLevelId.description
    }
}

struct ProgramOccurrenceResponse: Content {
    let memberId: String; let date: Date; let effectId: String; let isSuspensionRequested: Bool
    init(from o: ProgramOccurrence) {
        memberId = o.memberId.description; date = o.date.date
        effectId = o.effectId.description; isSuspensionRequested = o.isSuspensionRequested
    }
}

struct HealthStatusResponse: Content {
    let foodInsecurity: Bool
    let deficiencies: [MemberDeficiencyResponse]
    let gestatingMembers: [PregnantMemberResponse]
    let constantCareNeeds: [String]
    init(from h: HealthStatus) {
        foodInsecurity = h.foodInsecurity
        deficiencies = h.deficiencies.map { MemberDeficiencyResponse(from: $0) }
        gestatingMembers = h.gestatingMembers.map { PregnantMemberResponse(from: $0) }
        constantCareNeeds = h.constantCareNeeds.map { $0.description }
    }
}

struct MemberDeficiencyResponse: Content {
    let memberId, deficiencyTypeId: String
    let needsConstantCare: Bool; let responsibleCaregiverName: String?
    init(from d: MemberDeficiency) {
        memberId = d.memberId.description; deficiencyTypeId = d.deficiencyTypeId.description
        needsConstantCare = d.needsConstantCare; responsibleCaregiverName = d.responsibleCaregiverName
    }
}

struct PregnantMemberResponse: Content {
    let memberId: String; let monthsGestation: Int; let startedPrenatalCare: Bool
    init(from g: PregnantMember) {
        memberId = g.memberId.description; monthsGestation = g.monthsGestation
        startedPrenatalCare = g.startedPrenatalCare
    }
}

struct CommunitySupportNetworkResponse: Content {
    let hasRelativeSupport, hasNeighborSupport: Bool
    let familyConflicts: String
    let patientParticipatesInGroups, familyParticipatesInGroups, patientHasAccessToLeisure, facesDiscrimination: Bool
    init(from c: CommunitySupportNetwork) {
        hasRelativeSupport = c.hasRelativeSupport; hasNeighborSupport = c.hasNeighborSupport
        familyConflicts = c.familyConflicts
        patientParticipatesInGroups = c.patientParticipatesInGroups
        familyParticipatesInGroups = c.familyParticipatesInGroups
        patientHasAccessToLeisure = c.patientHasAccessToLeisure
        facesDiscrimination = c.facesDiscrimination
    }
}

struct SocialHealthSummaryResponse: Content {
    let requiresConstantCare, hasMobilityImpairment, hasRelevantDrugTherapy: Bool
    let functionalDependencies: [String]
    init(from s: SocialHealthSummary) {
        requiresConstantCare = s.requiresConstantCare; hasMobilityImpairment = s.hasMobilityImpairment
        hasRelevantDrugTherapy = s.hasRelevantDrugTherapy; functionalDependencies = s.functionalDependencies
    }
}

struct PlacementHistoryResponse: Content {
    let individualPlacements: [PlacementRegistryResponse]
    let homeLossReport, thirdPartyGuardReport: String?
    let adultInPrison, adolescentInInternment: Bool
    init(from p: PlacementHistory) {
        individualPlacements = p.individualPlacements.map { PlacementRegistryResponse(from: $0) }
        homeLossReport = p.collectiveSituations.homeLossReport
        thirdPartyGuardReport = p.collectiveSituations.thirdPartyGuardReport
        adultInPrison = p.separationChecklist.adultInPrison
        adolescentInInternment = p.separationChecklist.adolescentInInternment
    }
}

struct PlacementRegistryResponse: Content {
    let id, memberId: String; let startDate: Date; let endDate: Date?; let reason: String
    init(from r: PlacementRegistry) {
        id = r.id.uuidString; memberId = r.memberId.description
        startDate = r.startDate.date; endDate = r.endDate?.date; reason = r.reason
    }
}

struct IngressInfoResponse: Content {
    let ingressTypeId: String; let originName, originContact: String?; let serviceReason: String
    let linkedSocialPrograms: [ProgramLinkResponse]
    init(from i: IngressInfo) {
        ingressTypeId = i.ingressTypeId.description; originName = i.originName
        originContact = i.originContact; serviceReason = i.serviceReason
        linkedSocialPrograms = i.linkedSocialPrograms.map { ProgramLinkResponse(from: $0) }
    }
}

struct ProgramLinkResponse: Content {
    let programId: String; let observation: String?
    init(from l: ProgramLink) {
        programId = l.programId.description; observation = l.observation
    }
}

struct AppointmentResponse: Content {
    let id: String; let date: Date; let professionalId, type, summary, actionPlan: String
    init(from a: SocialCareAppointment) {
        id = a.id.description; date = a.date.date
        professionalId = a.professionalInChargeId.description
        type = a.type.rawValue; summary = a.summary; actionPlan = a.actionPlan
    }
}

struct ReferralResponse: Content {
    let id: String; let date: Date; let professionalId, referredPersonId, destinationService, reason, status: String
    init(from r: Referral) {
        id = r.id.description; date = r.date.date
        professionalId = r.requestingProfessionalId.description
        referredPersonId = r.referredPersonId.description
        destinationService = r.destinationService.rawValue
        reason = r.reason; status = r.status.rawValue
    }
}

struct ViolationReportResponse: Content {
    let id: String; let reportDate: Date; let incidentDate: Date?
    let victimId, violationType, descriptionOfFact, actionsTaken: String
    init(from v: RightsViolationReport) {
        id = v.id.description; reportDate = v.reportDate.date; incidentDate = v.incidentDate?.date
        victimId = v.victimId.description; violationType = v.violationType.rawValue
        descriptionOfFact = v.descriptionOfFact; actionsTaken = v.actionsTaken
    }
}

// MARK: - Lookup

struct LookupItemResponse: Content {
    let id: String
    let codigo: String
    let descricao: String
}

struct LookupRequestResponse: Content {
    let id: String
    let tableName: String
    let codigo: String
    let descricao: String
    let justificativa: String
    let status: String
    let requestedBy: String
    let requestedAt: Date
    let reviewedBy: String?
    let reviewedAt: Date?
    let reviewNote: String?

    init(from dto: LookupRequestDTO) {
        self.id = dto.id
        self.tableName = dto.tableName
        self.codigo = dto.codigo
        self.descricao = dto.descricao
        self.justificativa = dto.justificativa
        self.status = dto.status
        self.requestedBy = dto.requestedBy
        self.requestedAt = dto.requestedAt
        self.reviewedBy = dto.reviewedBy
        self.reviewedAt = dto.reviewedAt
        self.reviewNote = dto.reviewNote
    }
}

// MARK: - Audit Trail

struct AuditTrailEntryResponse: Content {
    let id: String
    let aggregateId: String
    let eventType: String
    let actorId: String?
    let payload: AnyJSON
    let occurredAt: Date
    let recordedAt: Date

    init(from model: AuditTrailModel) {
        self.id = model.id.uuidString
        self.aggregateId = model.aggregate_id.uuidString
        self.eventType = model.event_type
        self.actorId = model.actor_id
        self.occurredAt = model.occurred_at
        self.recordedAt = model.recorded_at

        if let json = try? JSONSerialization.jsonObject(with: Data(model.payload.utf8)) {
            self.payload = AnyJSON(value: json)
        } else {
            self.payload = AnyJSON(value: [:] as [String: Any])
        }
    }
}

/// JSON heterogêneo seguro para Sendable (ADR-018).
///
/// Pré-fix era `struct AnyJSON: Content, @unchecked Sendable` armazenando
/// `Any` — Sendable era promessa sem verificação.
///
/// Pós-fix: enum fechado com cases tipados. `init(value: Any)` mantido para
/// back-compat com `AuditTrailEntryResponse` que decodifica payload JSON
/// genérico via `JSONSerialization.jsonObject`.
enum AnyJSON: Content {
    case object([String: AnyJSON])
    case array([AnyJSON])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(value: Any) {
        switch value {
        case let v as AnyJSON: self = v
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Double: self = .double(v)
        case let v as [Any]: self = .array(v.map { AnyJSON(value: $0) })
        case let v as [String: Any]: self = .object(v.mapValues { AnyJSON(value: $0) })
        default: self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([AnyJSON].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: AnyJSON].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }
}
