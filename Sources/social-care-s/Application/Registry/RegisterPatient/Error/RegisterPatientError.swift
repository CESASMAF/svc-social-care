import Foundation

/// Erros específicos para o caso de uso de registro de paciente.
public enum RegisterPatientError: Error, Sendable, Equatable {
    // PersonId
    case personIdAlreadyExists
    // CPF
    case cpfAlreadyExists(String)
    case invalidPersonIdFormat(String)
    case personIdNotFoundInPeopleContext(String)
    /// People-context indisponível (timeout, 5xx, DNS, 401). ADR-011 fail-secure:
    /// bloqueia registro com HTTP 503 — operador retenta. NÃO passa silencioso.
    case personValidationUnavailable(reason: String)
    // Diagnósticos
    case invalidIcdCode(String)
    case invalidDiagnosisDate(date: String, now: String)
    case emptyDiagnosisDescription
    case initialDiagnosesRequired
    // Dados pessoais
    case invalidFirstName
    case invalidLastName
    case invalidMotherName
    case invalidNationality
    case invalidSex(String)
    case invalidBirthDate(date: String, now: String)
    // Documentos civis
    case invalidCPF(String)
    case invalidNIS(String)
    case invalidRGDocument(String)
    case invalidCNS(String)
    case cpfMismatchWithCNS
    case atLeastOneDocumentRequired
    // Endereço
    case invalidResidenceLocation(String)
    case invalidAddress(String)
    // Identidade social
    case indigenousInVillageMissingDescription
    case indigenousOutsideVillageMissingDescription
    case descriptionRequiredForOtherType
    // Lookup
    case invalidLookupId(table: String, id: String)
    // Infraestrutura
    case repositoryNotAvailable
    case persistenceMappingFailure(issues: [String])
}

extension RegisterPatientError: AppErrorConvertible {
    private static let bc = "SOCIAL"
    private static let module = "social-care/application"
    private static let codePrefix = "REGP"

    public var asAppError: AppError {
        switch self {
        case .personIdAlreadyExists:
            return appFailure("001", kind: "PersonIdAlreadyExists", "O paciente com este PersonId já está registrado.", category: .conflict, severity: .warning, http: 409)
        case .cpfAlreadyExists:
            return appFailure("030", kind: "CpfAlreadyExists", "Já existe um paciente registrado com o CPF informado.", category: .conflict, severity: .warning, http: 409)
        case .invalidPersonIdFormat(let value):
            return appFailure("002", kind: "InvalidPersonIdFormat", "ID de pessoa inválido: \(value)", category: .dataConsistencyIncident, severity: .error, http: 400)
        case .personIdNotFoundInPeopleContext(let value):
            return appFailure("029", kind: "PersonIdNotFoundInPeopleContext", "PersonId \(value) não encontrado no people-context. Registre a pessoa antes de criar o prontuário.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .personValidationUnavailable(let reason):
            // ADR-011 fail-secure: HTTP 503 sinaliza ao cliente que precisa retentar.
            return appFailure("031", kind: "PersonValidationUnavailable", "Validação de pessoa no people-context indisponível (\(reason)). Tente novamente em alguns instantes.", category: .infrastructureDependencyFailure, severity: .error, http: 503)
        case .invalidIcdCode(let value):
            return appFailure("003", kind: "InvalidIcdCode", "Código CID inválido: \(value)", category: .domainRuleViolation, severity: .error, http: 400)
        case .invalidDiagnosisDate(let date, let now):
            return appFailure("004", kind: "InvalidDiagnosisDate", "Data do diagnóstico (\(date)) não pode ser futura (\(now)).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .emptyDiagnosisDescription:
            return appFailure("005", kind: "EmptyDiagnosisDescription", "A descrição do diagnóstico é obrigatória.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .initialDiagnosesRequired:
            return appFailure("006", kind: "InitialDiagnosesRequired", "Ao menos um diagnóstico inicial deve ser informado.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidFirstName:
            return appFailure("009", kind: "InvalidFirstName", "O primeiro nome não pode ser vazio.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidLastName:
            return appFailure("010", kind: "InvalidLastName", "O sobrenome não pode ser vazio.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidMotherName:
            return appFailure("011", kind: "InvalidMotherName", "O nome da mãe não pode ser vazio.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidNationality:
            return appFailure("012", kind: "InvalidNationality", "A nacionalidade não pode ser vazia.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidSex(let value):
            return appFailure("013", kind: "InvalidSex", "Sexo inválido: \(value).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidBirthDate(let date, let now):
            return appFailure("014", kind: "InvalidBirthDate", "Data de nascimento (\(date)) não pode ser futura (\(now)).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidCPF(let value):
            return appFailure("015", kind: "InvalidCPF", "CPF inválido: \(value).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidNIS(let value):
            return appFailure("016", kind: "InvalidNIS", "NIS inválido: \(value).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidRGDocument(let value):
            return appFailure("017", kind: "InvalidRGDocument", "RG inválido: \(value).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidCNS(let value):
            return appFailure("027", kind: "InvalidCNS", "CNS (Cartao do SUS) invalido: \(value).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .cpfMismatchWithCNS:
            return appFailure("028", kind: "CpfMismatchWithCNS", "O CPF informado nao corresponde ao CPF do Cartao do SUS (CNS).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .atLeastOneDocumentRequired:
            return appFailure("018", kind: "AtLeastOneDocumentRequired", "Ao menos um documento civil deve ser informado.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidResidenceLocation(let value):
            return appFailure("019", kind: "InvalidResidenceLocation", "Localização de residência inválida: \(value).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidAddress(let value):
            return appFailure("020", kind: "InvalidAddress", "Endereço inválido: \(value).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .indigenousInVillageMissingDescription:
            return appFailure("021", kind: "IndigenousInVillageMissingDescription", "Família indígena em aldeia requer descrição.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .indigenousOutsideVillageMissingDescription:
            return appFailure("022", kind: "IndigenousOutsideVillageMissingDescription", "Família indígena fora de aldeia requer descrição complementar.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .descriptionRequiredForOtherType:
            return appFailure("025", kind: "DescriptionRequiredForOtherType", "Descrição detalhada é obrigatória para este tipo de identidade social.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidLookupId(let table, let id):
            return appFailure("026", kind: "InvalidLookupId", "ID '\(id)' nao encontrado na tabela '\(table)'.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .repositoryNotAvailable:
            return appFailure("023", kind: "RepositoryNotAvailable", "O repositório não está disponível.", category: .infrastructureDependencyFailure, severity: .critical, http: 503)
        case .persistenceMappingFailure(let issues):
            return appFailure("024", kind: "PersistenceMappingFailure", "Falha de infraestrutura ao salvar o paciente.", category: .infrastructureDependencyFailure, severity: .critical, http: 500, context: ["issues": issues])
        }
    }

    private func appFailure(_ subCode: String, kind: String, _ message: String, category: AppError.Category, severity: AppError.Severity, http: Int, context: [String: Any] = [:]) -> AppError {
        AppError(
            code: "\(Self.codePrefix)-\(subCode)",
            message: message,
            bc: Self.bc, module: Self.module, kind: kind,
            context: context.mapValues { AnySendable($0) },
            safeContext: [:],
            observability: .init(category: category, severity: severity, fingerprint: ["\(Self.codePrefix)-\(subCode)"], tags: ["use_case": "register_patient"]),
            http: http
        )
    }
}
