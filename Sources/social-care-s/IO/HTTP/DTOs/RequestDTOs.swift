import Vapor

// MARK: - Configuration (Lookup Admin)

struct CreateLookupItemRequest: Content {
    let codigo: String
    let descricao: String
    let exigeRegistroNascimento: Bool?
    let exigeCpfFalecido: Bool?
    let exigeDescricao: Bool?
}

struct UpdateLookupItemRequest: Content {
    let descricao: String
}

struct CreateLookupRequestRequest: Content {
    let tableName: String
    let codigo: String
    let descricao: String
    let justificativa: String
}

struct RejectLookupRequestRequest: Content {
    let reviewNote: String
}

// MARK: - Registry

struct RegisterPatientRequest: Content {
    let personId: String
    let initialDiagnoses: [DiagnosisDraftDTO]
    let personalData: PersonalDataDraftDTO?
    let civilDocuments: CivilDocumentsDraftDTO?
    let address: AddressDraftDTO?
    let socialIdentity: SocialIdentityDraftDTO?
    let prRelationshipId: String

    struct DiagnosisDraftDTO: Content {
        let icdCode: String
        let date: Date
        let description: String
    }

    struct PersonalDataDraftDTO: Content {
        let firstName: String
        let lastName: String
        let motherName: String
        let nationality: String
        let sex: String
        let socialName: String?
        let birthDate: Date
        let phone: String?
    }

    struct CivilDocumentsDraftDTO: Content {
        let cpf: String?
        let nis: String?
        let rgDocument: RGDocumentDraftDTO?
        let cns: CNSDraftDTO?

        struct RGDocumentDraftDTO: Content {
            let number: String
            let issuingState: String
            let issuingAgency: String
            let issueDate: Date
        }

        struct CNSDraftDTO: Content {
            let number: String
            let cpf: String
            let qrCode: String?
        }
    }

    struct AddressDraftDTO: Content {
        let cep: String?
        let isShelter: Bool
        let isHomeless: Bool?
        let residenceLocation: String
        let street: String?
        let neighborhood: String?
        let number: String?
        let complement: String?
        let state: String
        let city: String
    }

    struct SocialIdentityDraftDTO: Content {
        let typeId: String
        let description: String?
    }

    func toCommand(actorId: String, bearer: String? = nil) -> RegisterPatientCommand {
        RegisterPatientCommand(
            personId: personId,
            initialDiagnoses: initialDiagnoses.map {
                .init(icdCode: $0.icdCode, date: $0.date, description: $0.description)
            },
            personalData: personalData.map {
                .init(firstName: $0.firstName, lastName: $0.lastName, motherName: $0.motherName,
                      nationality: $0.nationality, sex: $0.sex, socialName: $0.socialName,
                      birthDate: $0.birthDate, phone: $0.phone)
            },
            civilDocuments: civilDocuments.map {
                .init(cpf: $0.cpf, nis: $0.nis,
                      rgDocument: $0.rgDocument.map {
                          .init(number: $0.number, issuingState: $0.issuingState,
                                issuingAgency: $0.issuingAgency, issueDate: $0.issueDate)
                      },
                      cns: $0.cns.map {
                          .init(number: $0.number, cpf: $0.cpf, qrCode: $0.qrCode)
                      })
            },
            address: address.map {
                .init(cep: $0.cep, isShelter: $0.isShelter, isHomeless: $0.isHomeless ?? false,
                      residenceLocation: $0.residenceLocation,
                      street: $0.street, neighborhood: $0.neighborhood, number: $0.number,
                      complement: $0.complement, state: $0.state, city: $0.city)
            },
            socialIdentity: socialIdentity.map {
                .init(typeId: $0.typeId, description: $0.description)
            },
            prRelationshipId: prRelationshipId,
            actorId: actorId,
            // ADR-011 / ADR-023: bearer propagado para validator outbound.
            bearer: bearer
        )
    }
}

struct AddFamilyMemberRequest: Content {
    let memberPersonId: String
    let relationship: String
    let isResiding: Bool
    let isCaregiver: Bool
    let hasDisability: Bool
    let requiredDocuments: [String]
    let birthDate: Date
    let prRelationshipId: String
}

struct AssignPrimaryCaregiverRequest: Content {
    let memberPersonId: String
}

struct UpdateSocialIdentityRequest: Content {
    let typeId: String
    let description: String?
}

// MARK: - Assessment

struct UpdateHousingConditionRequest: Content {
    let type: String
    let wallMaterial: String
    let numberOfRooms: Int
    let numberOfBedrooms: Int
    let numberOfBathrooms: Int
    let waterSupply: String
    let hasPipedWater: Bool
    let electricityAccess: String
    let sewageDisposal: String
    let wasteCollection: String
    let accessibilityLevel: String
    let isInGeographicRiskArea: Bool
    let hasDifficultAccess: Bool
    let isInSocialConflictArea: Bool
    let hasDiagnosticObservations: Bool
}

struct UpdateSocioEconomicSituationRequest: Content {
    let totalFamilyIncome: Double
    let incomePerCapita: Double
    let receivesSocialBenefit: Bool
    let socialBenefits: [SocialBenefitDraftDTO]
    let mainSourceOfIncome: String
    let hasUnemployed: Bool

    struct SocialBenefitDraftDTO: Content {
        let benefitName: String
        let amount: Double
        let beneficiaryId: String
        let benefitTypeId: String?
        let birthCertificateNumber: String?
        let deceasedCpf: String?
    }
}

struct UpdateWorkAndIncomeRequest: Content {
    let individualIncomes: [IncomeDraftDTO]
    let socialBenefits: [BenefitDraftDTO]
    let hasRetiredMembers: Bool

    struct IncomeDraftDTO: Content {
        let memberId: String
        let occupationId: String
        let hasWorkCard: Bool
        let monthlyAmount: Double
    }

    struct BenefitDraftDTO: Content {
        let benefitName: String
        let amount: Double
        let beneficiaryId: String
        let benefitTypeId: String?
        let birthCertificateNumber: String?
        let deceasedCpf: String?
    }
}

struct UpdateEducationalStatusRequest: Content {
    let memberProfiles: [ProfileDraftDTO]
    let programOccurrences: [OccurrenceDraftDTO]

    struct ProfileDraftDTO: Content {
        let memberId: String
        let canReadWrite: Bool
        let attendsSchool: Bool
        let educationLevelId: String
    }

    struct OccurrenceDraftDTO: Content {
        let memberId: String
        let date: Date
        let effectId: String
        let isSuspensionRequested: Bool
    }
}

struct UpdateHealthStatusRequest: Content {
    let deficiencies: [DeficiencyDraftDTO]
    let gestatingMembers: [PregnantDraftDTO]
    let constantCareNeeds: [String]
    let foodInsecurity: Bool

    struct DeficiencyDraftDTO: Content {
        let memberId: String
        let deficiencyTypeId: String
        let needsConstantCare: Bool
        let responsibleCaregiverName: String?
    }

    struct PregnantDraftDTO: Content {
        let memberId: String
        let monthsGestation: Int
        let startedPrenatalCare: Bool
    }
}

struct UpdateCommunitySupportNetworkRequest: Content {
    let hasRelativeSupport: Bool
    let hasNeighborSupport: Bool
    let familyConflicts: String
    let patientParticipatesInGroups: Bool
    let familyParticipatesInGroups: Bool
    let patientHasAccessToLeisure: Bool
    let facesDiscrimination: Bool
}

struct UpdateSocialHealthSummaryRequest: Content {
    let requiresConstantCare: Bool
    let hasMobilityImpairment: Bool
    let functionalDependencies: [String]
    let hasRelevantDrugTherapy: Bool
}

// MARK: - Protection

struct UpdatePlacementHistoryRequest: Content {
    let registries: [RegistryDraftDTO]
    let collectiveSituations: CollectiveDraftDTO
    let separationChecklist: SeparationDraftDTO

    struct RegistryDraftDTO: Content {
        let memberId: String
        let startDate: Date
        let endDate: Date?
        let reason: String
    }

    struct CollectiveDraftDTO: Content {
        let homeLossReport: String?
        let thirdPartyGuardReport: String?
    }

    struct SeparationDraftDTO: Content {
        let adultInPrison: Bool
        let adolescentInInternment: Bool
    }
}

struct ReportRightsViolationRequest: Content {
    let victimId: String
    let violationType: String
    let violationTypeId: String?
    let reportDate: Date?
    let incidentDate: Date?
    let descriptionOfFact: String
    let actionsTaken: String?
}

struct CreateReferralRequest: Content {
    let referredPersonId: String
    let professionalId: String?
    let destinationService: String
    let reason: String
    let date: Date?
}

// MARK: - Patient Lifecycle

struct DischargePatientRequest: Content {
    let reason: String
    let notes: String?
}

struct ReadmitPatientRequest: Content {
    let notes: String?
}

struct WithdrawPatientRequest: Content {
    let reason: String
    let notes: String?
}

// MARK: - Care

struct RegisterAppointmentRequest: Content {
    let professionalId: String
    let summary: String?
    let actionPlan: String?
    let type: String?
    let date: Date?
}

struct RegisterIntakeInfoRequest: Content {
    let ingressTypeId: String
    let originName: String?
    let originContact: String?
    let serviceReason: String
    let linkedSocialPrograms: [ProgramLinkDraftDTO]

    struct ProgramLinkDraftDTO: Content {
        let programId: String
        let observation: String?
    }
}
