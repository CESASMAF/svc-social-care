import Foundation

/// Value Object que representa um benefício social individual recebido por um membro da família.
///
/// Encapsula a identificação do benefício, seu valor monetário e o vínculo com um beneficiário.
public struct SocialBenefit: Codable, Equatable, Hashable, Sendable {
    
    // MARK: - Properties
    
    /// O nome descritivo do benefício (ex: "Bolsa Família").
    public let benefitName: String

    /// O valor monetário atual do benefício (ADR-009 — Money substitui Double).
    public let amount: Money

    /// O identificador único do membro da família que recebe o auxílio.
    public let beneficiaryId: PersonId

    // MARK: - Initializer

    /// Inicializa uma instância validada de benefício social.
    ///
    /// - Throws: `SocialBenefitError.benefitNameEmpty` se o nome estiver vazio,
    ///   ou `SocialBenefitError.amountInvalid` se o valor for não-positivo.
    public init(
        benefitName: String,
        amount: Money,
        beneficiaryId: PersonId
    ) throws {
        let normalizedName = benefitName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        guard !normalizedName.isEmpty else {
            throw SocialBenefitError.benefitNameEmpty
        }

        // Money já garante centavos >= 0; aqui validamos > 0 (benefício deve ter valor).
        guard amount.centavos > 0 else {
            throw SocialBenefitError.amountInvalid(centavos: amount.centavos)
        }

        self.benefitName = normalizedName
        self.amount = amount
        self.beneficiaryId = beneficiaryId
    }
}
