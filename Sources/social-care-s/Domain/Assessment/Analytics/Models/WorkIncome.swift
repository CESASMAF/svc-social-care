import Foundation

/// Modelo auxiliar para processamento analítico de renda no domínio.
///
/// ADR-009: `monthlyAmount: Money` substitui Double para soma exata.
public struct WorkIncome: Sendable {
    public let memberId: PersonId
    public let monthlyAmount: Money

    public init(memberId: PersonId, monthlyAmount: Money) {
        self.memberId = memberId
        self.monthlyAmount = monthlyAmount
    }
}
