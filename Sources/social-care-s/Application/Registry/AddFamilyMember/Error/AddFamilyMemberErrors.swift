import Foundation

/// Erros específicos para o caso de uso de adição de membros familiares.
public enum AddFamilyMemberError: Error, Sendable, Equatable {
    case useCaseNotImplemented
    case repositoryNotAvailable
    case personIdAlreadyExists
    case invalidDiagnosisListFormat
    case invalidPersonIdFormat
    case persistenceMappingFailure(patientId: String? = nil, issues: [String] = [], issueCount: Int? = nil)
    case patientNotFound
    case memberAlreadyExists(String)
    case invalidLookupId(table: String, id: String)
    case patientNotActive(reason: String)
    /// ADR-020 (S-H-A7): valor recebido em `requiredDocuments` não corresponde
    /// a nenhum case de `RequiredDocument`. Pré-fix, o handler usava
    /// `compactMap` e silenciosamente descartava o valor — agora é erro tipado
    /// (HTTP 422 com payload `{"invalidValue": "..."}`).
    case invalidRequiredDocument(String)
}

extension AddFamilyMemberError: AppErrorConvertible {
    private static let bc = "SOCIAL"
    private static let module = "social-care/application"
    private static let codePrefix = "APP"

    /// Converte o erro interno no formato padronizado AppError.
    public var asAppError: AppError {
        switch self {
        case .memberAlreadyExists(let id):
            return appFailure("008", kind: "MemberAlreadyExists", "Membro familiar já existe nesta família: \(id)", category: .conflict, severity: .warning, http: 409)
        case .useCaseNotImplemented:
            return appFailure(
                "001",
                kind: "UseCaseNotImplemented",
                "O caso de uso não foi implementado.",
                category: .infrastructureDependencyFailure,
                severity: .critical,
                http: 500
            )
        case .repositoryNotAvailable:
            return appFailure(
                "002",
                kind: "RepositoryNotAvailable",
                "O repositório não está disponível no momento.",
                category: .infrastructureDependencyFailure,
                severity: .error,
                http: 503
            )
        case .personIdAlreadyExists:
            return appFailure(
                "003",
                kind: "PersonIdAlreadyExists",
                "O PersonId já existe.",
                category: .conflict,
                severity: .warning,
                http: 409
            )
        case .invalidDiagnosisListFormat:
            return appFailure(
                "004",
                kind: "InvalidDiagnosisListFormat",
                "Falha ao converter a lista de diagnósticos.",
                category: .dataConsistencyIncident,
                severity: .error,
                http: 400
            )
        case .invalidPersonIdFormat:
            return appFailure(
                "005",
                kind: "InvalidPersonIdFormat",
                "O formato do ID de pessoa é inválido.",
                category: .dataConsistencyIncident,
                severity: .error,
                http: 400
            )
        case .persistenceMappingFailure(let patientId, let issues, let issueCount):
            let resolvedIssueCount = issueCount ?? (issues.isEmpty ? nil : issues.count)
            let countLabel = resolvedIssueCount.map(String.init) ?? "?"
            var context: [String: Any] = [:]
            if let patientId {
                context["patientId"] = patientId
            }
            if !issues.isEmpty {
                context["issues"] = issues
            }
            if let resolvedIssueCount {
                context["issueCount"] = resolvedIssueCount
            }

            return appFailure(
                "006",
                kind: "PersistenceMappingFailure",
                "Falha ao mapear dados persistidos do paciente. (\(countLabel) erro(s))",
                category: .dataConsistencyIncident,
                severity: .error,
                http: 500,
                context: context
            )
        case .invalidLookupId(let table, let id):
            return appFailure("009", kind: "InvalidLookupId", "ID '\(id)' nao encontrado na tabela '\(table)'.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .patientNotActive(let reason):
            let message = reason == "PATIENT_IS_WAITLISTED"
                ? "Operação não permitida: o paciente está na lista de espera. Admita o paciente antes de realizar alterações."
                : "Operação não permitida: o paciente está desligado. Readmita o paciente antes de realizar alterações."
            return appFailure("010", kind: "PatientNotActive", message, category: .conflict, severity: .warning, http: 409, context: ["reason": reason])
        case .patientNotFound:
           return appFailure(
                "007",
                kind: "PatientNotFound",
                "Não foi encontrado nenhum paciente com o ID fornecido.",
                category: .dataConsistencyIncident,
                severity: .error,
                http: 400
            )
        case .invalidRequiredDocument(let value):
            return appFailure(
                "011",
                kind: "InvalidRequiredDocument",
                "Documento solicitado inválido: '\(value)'. Valores aceitos: CN, RG, CTPS, CPF, TE.",
                category: .domainRuleViolation,
                severity: .warning,
                http: 422,
                context: ["invalidValue": value]
            )
        }
    }

    private func appFailure(
        _ subCode: String,
        kind: String,
        _ message: String,
        category: AppError.Category,
        severity: AppError.Severity,
        http: Int,
        context: [String: Any] = [:]
    ) -> AppError {
        AppError(
            code: "\(Self.codePrefix)-\(subCode)",
            message: message,
            bc: Self.bc,
            module: Self.module,
            kind: kind,
            context: context.mapValues { AnySendable($0) },
            safeContext: [:],
            observability: .init(
                category: category,
                severity: severity,
                fingerprint: ["\(Self.codePrefix)-\(subCode)", Self.module],
                tags: ["layer": "application", "use_case": "add_family_member"]
            ),
            http: http
        )
    }
}
