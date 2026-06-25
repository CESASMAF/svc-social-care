import Foundation

/// Erros específicos para o Value Object SocioEconomicSituation.
///
/// Após ADR-009, valores monetários são `Money` (centavos `Int64`). Os
/// erros de "negativo" foram removidos porque `Money.init(centavos:)` já
/// rejeita centavos negativos. Sobra apenas o erro de inconsistência
/// per-capita > total.
public enum SocioEconomicSituationError: Error, Sendable, Equatable {
    case inconsistentSocialBenefit
    case missingSocialBenefits
    case emptyMainSourceOfIncome
    case inconsistentIncomePerCapita(perCapitaCentavos: Int64, totalCentavos: Int64)
}

extension SocioEconomicSituationError: AppErrorConvertible {
    private static let bc = "SOCIAL"
    private static let module = "social-care/socio-economic-situation"
    private static let codePrefix = "SES"

    public var asAppError: AppError {
        switch self {
        case .inconsistentSocialBenefit:
            return AppError(
                code: "\(Self.codePrefix)-001",
                message: "Inconsistência: Indicado que não recebe benefícios, mas a lista de benefícios não está vazia.",
                bc: Self.bc, module: Self.module, kind: "InconsistentSocialBenefit",
                context: [:], safeContext: [:],
                observability: .init(category: .domainRuleViolation, severity: .warning, fingerprint: ["\(Self.codePrefix)-001"], tags: ["vo": "socio_economic_situation"]),
                http: 422
            )
        case .missingSocialBenefits:
            return AppError(
                code: "\(Self.codePrefix)-002",
                message: "Inconsistência: Indicado que recebe benefícios, mas a lista de benefícios está vazia.",
                bc: Self.bc, module: Self.module, kind: "MissingSocialBenefits",
                context: [:], safeContext: [:],
                observability: .init(category: .domainRuleViolation, severity: .warning, fingerprint: ["\(Self.codePrefix)-002"], tags: ["vo": "socio_economic_situation"]),
                http: 422
            )
        // SES-003 (negativeFamilyIncome) e SES-004 (negativeIncomePerCapita)
        // foram removidos com ADR-009 — Money rejeita centavos negativos no init.
        case .emptyMainSourceOfIncome:
            return AppError(
                code: "\(Self.codePrefix)-005",
                message: "A principal fonte de renda deve ser informada.",
                bc: Self.bc, module: Self.module, kind: "EmptyMainSourceOfIncome",
                context: [:], safeContext: [:],
                observability: .init(category: .domainRuleViolation, severity: .warning, fingerprint: ["\(Self.codePrefix)-005"], tags: ["vo": "socio_economic_situation"]),
                http: 422
            )
        case .inconsistentIncomePerCapita(let perCapitaCentavos, let totalCentavos):
            return AppError(
                code: "\(Self.codePrefix)-006",
                message: "A renda per capita (\(perCapitaCentavos) centavos) não pode ser maior que a renda familiar total (\(totalCentavos) centavos).",
                bc: Self.bc, module: Self.module, kind: "InconsistentIncomePerCapita",
                context: ["perCapitaCentavos": AnySendable(perCapitaCentavos), "totalCentavos": AnySendable(totalCentavos)],
                safeContext: ["perCapitaCentavos": AnySendable(perCapitaCentavos), "totalCentavos": AnySendable(totalCentavos)],
                observability: .init(category: .domainRuleViolation, severity: .error, fingerprint: ["\(Self.codePrefix)-006"], tags: ["vo": "socio_economic_situation"]),
                http: 422
            )
        }
    }
}
