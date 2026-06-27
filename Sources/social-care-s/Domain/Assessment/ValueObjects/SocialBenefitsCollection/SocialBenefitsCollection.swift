import Foundation

/// Value Object que representa uma coleção de benefícios sociais recebidos pela família.
///
/// Este objeto garante a integridade da lista de benefícios, impedindo duplicatas
/// e fornecendo métodos utilitários para agregação financeira.
public struct SocialBenefitsCollection: Codable, Equatable, Hashable, Sendable {
    
    // MARK: - Properties
    
    /// A lista imutável de itens da coleção.
    public let items: [SocialBenefit]

    // MARK: - Initializer

    /// Inicializa uma coleção validada de benefícios.
    ///
    /// - Parameter benefits: Array de benefícios (não pode conter nomes duplicados).
    /// - Throws: `SocialBenefitsCollectionError.duplicateBenefitNotAllowed` se houver colisão de nomes.
    public init(_ benefits: [SocialBenefit]) throws {
        if benefits.isEmpty {
            self.items = []
            return
        }

        var seenNames = Set<String>()
        for benefit in benefits {
            guard !seenNames.contains(benefit.benefitName) else {
                throw SocialBenefitsCollectionError.duplicateBenefitNotAllowed(name: benefit.benefitName)
            }
            seenNames.insert(benefit.benefitName)
        }

        self.items = benefits
    }

    // MARK: - Computed Analytics
    
    /// Indica se a coleção está vazia.
    public var isEmpty: Bool { items.isEmpty }

    /// O número total de benefícios registrados.
    public var count: Int { items.count }

    /// A soma monetária total de todos os benefícios da coleção (ADR-009).
    ///
    /// Soma exata em `Money` (centavos `Int64`) — sem perda IEEE 754.
    /// Retorna `Money.zero` quando a coleção está vazia.
    ///
    /// Soma assume currency uniforme (BRL no projeto). Se `Money + Money`
    /// lançar (currency mismatch), entendemos como bug de modelagem upstream
    /// — propagamos como precondition para falhar loudly.
    public var totalAmount: Money {
        do {
            return try items.reduce(Money.zero) { (acc: Money, item: SocialBenefit) -> Money in
                try acc + item.amount
            }
        } catch {
            preconditionFailure("ADR-009: SocialBenefitsCollection com currency mistas não é suportado. Bug upstream: \(error)")
        }
    }
}
