import Foundation

/// Payload de entrada para o registro de um novo paciente.
public struct RegisterPatientCommand: ResultCommand {
    public typealias Result = String

    public struct DiagnosisDraft: Sendable {
        public let icdCode: String
        public let date: Date
        public let description: String
        
        public init(icdCode: String, date: Date, description: String) {
            self.icdCode = icdCode
            self.date = date
            self.description = description
        }
    }

    public struct PersonalDataDraft: Sendable {
        public let firstName: String
        public let lastName: String
        public let motherName: String
        public let nationality: String
        public let sex: String
        public let socialName: String?
        public let birthDate: Date
        public let phone: String?
        
        public init(firstName: String, lastName: String, motherName: String, nationality: String, sex: String, socialName: String?, birthDate: Date, phone: String?) {
            self.firstName = firstName
            self.lastName = lastName
            self.motherName = motherName
            self.nationality = nationality
            self.sex = sex
            self.socialName = socialName
            self.birthDate = birthDate
            self.phone = phone
        }
    }

    public struct RGDocumentDraft: Sendable {
        public let number: String
        public let issuingState: String
        public let issuingAgency: String
        public let issueDate: Date
        
        public init(number: String, issuingState: String, issuingAgency: String, issueDate: Date) {
            self.number = number
            self.issuingState = issuingState
            self.issuingAgency = issuingAgency
            self.issueDate = issueDate
        }
    }

    public struct CNSDraft: Sendable {
        public let number: String
        public let cpf: String
        public let qrCode: String?

        public init(number: String, cpf: String, qrCode: String?) {
            self.number = number
            self.cpf = cpf
            self.qrCode = qrCode
        }
    }

    public struct CivilDocumentsDraft: Sendable {
        public let cpf: String?
        public let nis: String?
        public let rgDocument: RGDocumentDraft?
        public let cns: CNSDraft?

        public init(cpf: String?, nis: String?, rgDocument: RGDocumentDraft?, cns: CNSDraft? = nil) {
            self.cpf = cpf
            self.nis = nis
            self.rgDocument = rgDocument
            self.cns = cns
        }
    }

    public struct AddressDraft: Sendable {
        public let cep: String?
        public let isShelter: Bool
        public let isHomeless: Bool
        public let residenceLocation: String
        public let street: String?
        public let neighborhood: String?
        public let number: String?
        public let complement: String?
        public let state: String
        public let city: String

        public init(cep: String?, isShelter: Bool, isHomeless: Bool = false, residenceLocation: String, street: String?, neighborhood: String?, number: String?, complement: String?, state: String, city: String) {
            self.cep = cep
            self.isShelter = isShelter
            self.isHomeless = isHomeless
            self.residenceLocation = residenceLocation
            self.street = street
            self.neighborhood = neighborhood
            self.number = number
            self.complement = complement
            self.state = state
            self.city = city
        }
    }

    public struct SocialIdentityDraft: Sendable {
        public let typeId: String
        public let description: String?
        
        public init(typeId: String, description: String?) {
            self.typeId = typeId
            self.description = description
        }
    }

    public let personId: String
    public let initialDiagnoses: [DiagnosisDraft]
    public let personalData: PersonalDataDraft?
    public let civilDocuments: CivilDocumentsDraft?
    public let address: AddressDraft?
    public let socialIdentity: SocialIdentityDraft?
    public let prRelationshipId: String
    public let actorId: String

    /// JWT do request original encaminhado para validators outbound
    /// (ADR-023 / ADR-011). `nil` em contextos não-autenticados
    /// (cron, integração interna, testes).
    public let bearer: String?

    public init(
        personId: String,
        initialDiagnoses: [DiagnosisDraft],
        personalData: PersonalDataDraft? = nil,
        civilDocuments: CivilDocumentsDraft? = nil,
        address: AddressDraft? = nil,
        socialIdentity: SocialIdentityDraft? = nil,
        prRelationshipId: String,
        actorId: String,
        bearer: String? = nil
    ) {
        self.personId = personId
        self.initialDiagnoses = initialDiagnoses
        self.personalData = personalData
        self.civilDocuments = civilDocuments
        self.address = address
        self.socialIdentity = socialIdentity
        self.prRelationshipId = prRelationshipId
        self.actorId = actorId
        self.bearer = bearer
    }
}
