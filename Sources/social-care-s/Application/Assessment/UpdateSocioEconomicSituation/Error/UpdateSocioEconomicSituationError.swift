import Foundation

/// Erros específicos para o caso de uso de atualização da situação socioeconômica.
///
/// ADR-009: valores monetários transitam como `Int64 centavos` quando precisam
/// ir até o cliente HTTP — o `Money` cuida da exatidão; quando precisamos
/// expor o valor para diagnóstico, mostramos centavos e o cliente formata.
public enum UpdateSocioEconomicSituationError: Error, Sendable, Equatable {
    case patientNotFound
    case invalidPersonIdFormat(String)
    case inconsistentSocialBenefit
    case missingSocialBenefits
    case emptyMainSourceOfIncome
    case inconsistentIncomePerCapita(perCapitaCentavos: Int64, totalCentavos: Int64)
    case benefitNameEmpty
    case amountInvalid(centavos: Int64)
    case duplicateBenefitNotAllowed(name: String)
    case persistenceMappingFailure(issues: [String])
    case patientNotActive(reason: String)
    /// Money rejeitou o valor recebido (ex: currency vazia, formato inválido).
    /// Mantém detail para diagnóstico do cliente.
    case invalidMoneyValue(detail: String)
}

extension UpdateSocioEconomicSituationError: AppErrorConvertible {
    private static let bc = "SOCIAL"
    private static let module = "social-care/application"
    private static let codePrefix = "USES"

    public var asAppError: AppError {
        switch self {
        case .patientNotFound:
            return appFailure("001", kind: "PatientNotFound", "O paciente não foi encontrado.", category: .dataConsistencyIncident, severity: .error, http: 404)
        case .invalidPersonIdFormat(let value):
            return appFailure("002", kind: "InvalidPersonIdFormat", "ID de pessoa inválido: \(value)", category: .dataConsistencyIncident, severity: .error, http: 400)
        case .inconsistentSocialBenefit:
            return appFailure("003", kind: "InconsistentSocialBenefit", "Inconsistência nos benefícios sociais informados.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .missingSocialBenefits:
            return appFailure("004", kind: "MissingSocialBenefits", "Benefícios sociais obrigatórios não informados.", category: .domainRuleViolation, severity: .warning, http: 422)
        // SES-005/006 (negative*) eliminados pelo ADR-009 — Money rejeita centavos < 0
        case .emptyMainSourceOfIncome:
            return appFailure("007", kind: "EmptyMainSourceOfIncome", "A principal fonte de renda é obrigatória.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .inconsistentIncomePerCapita(let perCapitaCentavos, let totalCentavos):
            return appFailure("008", kind: "InconsistentIncomePerCapita", "Renda per capita (\(perCapitaCentavos) centavos) não pode ser maior que a total (\(totalCentavos) centavos).", category: .domainRuleViolation, severity: .error, http: 422)
        case .benefitNameEmpty:
            return appFailure("009", kind: "BenefitNameEmpty", "O nome do benefício social não pode ser vazio.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .amountInvalid(let centavos):
            return appFailure("010", kind: "AmountInvalid", "Valor de benefício inválido: \(centavos) centavos.", category: .domainRuleViolation, severity: .warning, http: 422)
        case .invalidMoneyValue(let detail):
            return appFailure("014", kind: "InvalidMoneyValue", "Valor monetário inválido: \(detail).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .duplicateBenefitNotAllowed(let name):
            return appFailure("011", kind: "DuplicateBenefitNotAllowed", "Benefício duplicado: \(name).", category: .domainRuleViolation, severity: .warning, http: 422)
        case .patientNotActive(let reason):
            let message = reason == "PATIENT_IS_WAITLISTED"
                ? "Operação não permitida: o paciente está na lista de espera. Admita o paciente antes de realizar alterações."
                : "Operação não permitida: o paciente está desligado. Readmita o paciente antes de realizar alterações."
            return appFailure("013", kind: "PatientNotActive", message, category: .conflict, severity: .warning, http: 409, context: ["reason": reason])
        case .persistenceMappingFailure(let issues):
            return appFailure("012", kind: "PersistenceMappingFailure", "Falha de infraestrutura ao salvar a situação socioeconômica.", category: .infrastructureDependencyFailure, severity: .critical, http: 500, context: ["issues": issues])
        }
    }

    private func appFailure(_ subCode: String, kind: String, _ message: String, category: AppError.Category, severity: AppError.Severity, http: Int, context: [String: Any] = [:]) -> AppError {
        AppError(
            code: "\(Self.codePrefix)-\(subCode)",
            message: message,
            bc: Self.bc, module: Self.module, kind: kind,
            context: context.mapValues { AnySendable($0) },
            safeContext: [:],
            observability: .init(category: category, severity: severity, fingerprint: ["\(Self.codePrefix)-\(subCode)"], tags: ["use_case": "update_socioeconomic_situation"]),
            http: http
        )
    }
}
