import Foundation

/// Implementação do serviço Maestro para registro de novos pacientes.
public actor RegisterPatientCommandHandler: RegisterPatientUseCase {
    private let repository: any PatientRepository
    private let lookupValidator: any LookupValidating
    private let personValidator: (any PersonExistenceValidating)?

    public init(
        repository: any PatientRepository,
        lookupValidator: any LookupValidating,
        personValidator: (any PersonExistenceValidating)? = nil
    ) {
        self.repository = repository
        self.lookupValidator = lookupValidator
        self.personValidator = personValidator
    }

    public func handle(_ command: RegisterPatientCommand) async throws -> String {
        do {
            // 1. Parse — identificador e diagnósticos (obrigatórios)
            let personId = try PersonId(command.personId)
            let diagnoses = try command.initialDiagnoses.map { draft in
                let icd = try ICDCode(draft.icdCode)
                let date = try TimeStamp(draft.date)
                return try Diagnosis(id: icd, date: date, description: draft.description, now: .now)
            }

            // 2. Parse — dados pessoais (opcional)
            let personalData: PersonalData? = try command.personalData.map { draft in
                guard let sex = PersonalData.Sex(rawValue: draft.sex) else {
                    throw RegisterPatientError.invalidSex(draft.sex)
                }
                return try PersonalData(
                    firstName: draft.firstName,
                    lastName: draft.lastName,
                    motherName: draft.motherName,
                    nationality: draft.nationality,
                    sex: sex,
                    socialName: draft.socialName,
                    birthDate: try TimeStamp(draft.birthDate),
                    phone: draft.phone
                )
            }

            // 3. Parse — documentos civis (opcional)
            let civilDocuments: CivilDocuments? = try command.civilDocuments.map { draft in
                let cpf: CPF? = try draft.cpf.map { try CPF($0) }
                let nis: NIS? = try draft.nis.map { try NIS($0) }
                let rg: RGDocument? = try draft.rgDocument.map { rg in
                    try RGDocument(
                        number: rg.number,
                        issuingState: rg.issuingState,
                        issuingAgency: rg.issuingAgency,
                        issueDate: try TimeStamp(rg.issueDate)
                    )
                }
                let cns: CNS? = try draft.cns.map { cnsDraft in
                    try CNS(
                        number: cnsDraft.number,
                        cpf: try CPF(cnsDraft.cpf),
                        qrCode: cnsDraft.qrCode
                    )
                }
                return try CivilDocuments(cpf: cpf, nis: nis, rgDocument: rg, cns: cns)
            }

            // 4. Parse — endereço (opcional)
            let address: Address? = try command.address.map { draft in
                guard let location = Address.ResidenceLocation(rawValue: draft.residenceLocation) else {
                    throw RegisterPatientError.invalidResidenceLocation(draft.residenceLocation)
                }
                return try Address(
                    cep: draft.cep,
                    isShelter: draft.isShelter,
                    isHomeless: draft.isHomeless,
                    residenceLocation: location,
                    street: draft.street,
                    neighborhood: draft.neighborhood,
                    number: draft.number,
                    complement: draft.complement,
                    state: draft.state,
                    city: draft.city
                )
            }

            // 5. Parse — identidade social (opcional)
            let socialIdentity: SocialIdentity? = try command.socialIdentity.map { draft in
                try SocialIdentity(
                    typeId: try LookupId(draft.typeId), 
                    otherDescription: draft.description
                )
            }

            // 6. PersonId Validation (people-context) — tri-state ADR-011
            if let validator = personValidator {
                switch await validator.validate(personId: personId, bearer: command.bearer) {
                case .exists:
                    break  // OK, prossegue
                case .notFound:
                    throw RegisterPatientError.personIdNotFoundInPeopleContext(command.personId)
                case .unknown(let reason):
                    // S-C1 fail-secure: upstream indisponível bloqueia registro
                    // com HTTP 503 — operador retenta, NÃO passa silencioso.
                    throw RegisterPatientError.personValidationUnavailable(reason: reason)
                }
            }

            // 7. Lookup Validation
            let prId = try LookupId(command.prRelationshipId)
            guard try await lookupValidator.exists(id: prId, in: "dominio_parentesco") else {
                throw RegisterPatientError.invalidLookupId(table: "dominio_parentesco", id: prId.description)
            }
            if let identity = socialIdentity {
                guard try await lookupValidator.exists(id: identity.typeId, in: "dominio_tipo_identidade") else {
                    throw RegisterPatientError.invalidLookupId(table: "dominio_tipo_identidade", id: identity.typeId.description)
                }
            }

            // 8. Existence Check — PersonId
            if try await repository.exists(byPersonId: personId) {
                throw RegisterPatientError.personIdAlreadyExists
            }

            // 9. Existence Check — CPF
            if let cpf = civilDocuments?.cpf {
                if try await repository.exists(byCpf: cpf) {
                    throw RegisterPatientError.cpfAlreadyExists("***")
                }
            }

            // 10. Domain Logic
            // O titular do prontuário é automaticamente inserido como o primeiro membro da família (a PR)
            let holderAsMember = try FamilyMember(
                personId: personId,
                relationshipId: prId,
                isPrimaryCaregiver: true,
                residesWithPatient: true,
                birthDate: personalData?.birthDate ?? TimeStamp.now
            )

            var patient = try Patient(
                id: PatientId(),
                personId: personId,
                personalData: personalData,
                civilDocuments: civilDocuments,
                address: address,
                diagnoses: diagnoses,
                familyMembers: [holderAsMember],
                prRelationshipId: prId,
                actorId: command.actorId
            )

            if let identity = socialIdentity {
                try patient.updateSocialIdentity(identity, actorId: command.actorId)
            }

            // 11. Persistence & Events
            try await repository.save(patient)

            return patient.id.description

        } catch {
            throw mapError(error, patientId: command.personId)
        }
    }
}
