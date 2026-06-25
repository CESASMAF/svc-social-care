import Foundation

/// Value Object que representa uma quantia monetária no domínio do social-care.
///
/// Substitui `Double` em todo valor financeiro (BPC, Bolsa Família,
/// rendimentos, renda per capita) para eliminar a classe de bugs de soma
/// não-exata em IEEE 754. ADR-009.
///
/// **Por que centavos como `Int64`:**
///
/// `Double` não é fechado em soma de decimais — `0.1 + 0.2 != 0.3`. Em
/// auditoria PBF/BPC, o erro acumulado em soma de benefícios sociais
/// gera divergência consistente com a fonte oficial. `Int64` em centavos
/// aceita qualquer valor monetário até ~92 quatrilhões — muito além de
/// qualquer agregado realista — sem perder precisão.
///
/// **Conversão para banco (`NUMERIC(12,2)`):**
///
/// O mapper converte `Money.centavos` para `Double` via `valorReal`
/// (`Double(centavos) / 100.0`) na fronteira IO. NUMERIC tem precisão
/// arbitrária; round-trip preserva 2 casas decimais com segurança.
public struct Money: Codable, Equatable, Hashable, Sendable, Comparable {

    // MARK: - Properties

    /// Quantia em centavos (menor unidade da moeda). Sempre não-negativo.
    public let centavos: Int64

    /// Código ISO 4217 da moeda (ex: "BRL", "USD"). Sempre 3 caracteres.
    public let currency: String

    // MARK: - Constants

    /// Quantia zero. Único valor pré-construído porque é elemento neutro
    /// de soma e é referenciado em reduce.
    public static let zero = Money(unsafe: 0, currency: "BRL")

    // MARK: - Initializers

    /// Construtor canônico. Valida centavos não-negativos e currency com
    /// formato ISO 4217 (3 caracteres alfabéticos).
    ///
    /// - Parameters:
    ///   - centavos: Quantia em centavos. Deve ser >= 0.
    ///   - currency: Código ISO 4217 (default "BRL"). Deve ter 3 caracteres.
    /// - Throws: `MoneyError.negativeAmount` ou `MoneyError.invalidCurrency`.
    public init(centavos: Int64, currency: String = "BRL") throws {
        guard centavos >= 0 else {
            throw MoneyError.negativeAmount(centavos: centavos)
        }
        let normalizedCurrency = currency.uppercased()
        guard normalizedCurrency.count == 3,
              normalizedCurrency.allSatisfy({ $0.isLetter && $0.isASCII }) else {
            throw MoneyError.invalidCurrency(received: currency)
        }
        self.centavos = centavos
        self.currency = normalizedCurrency
    }

    /// Construtor por valor real (formato `Double`, ex: `600.99`).
    ///
    /// Útil quando o input vem de DTO HTTP ou planilha. O valor é
    /// arredondado para o centavo mais próximo (banker's rounding).
    ///
    /// - Parameters:
    ///   - valorReal: Quantia no formato decimal (ex: 600.99 = R$ 600,99).
    ///   - currency: Código ISO 4217 (default "BRL").
    public init(valorReal: Double, currency: String = "BRL") throws {
        let centavosRounded = Int64((valorReal * 100).rounded())
        try self.init(centavos: centavosRounded, currency: currency)
    }

    /// Construtor interno sem validação. Usado APENAS para o singleton
    /// `Money.zero` evitando `try!` em static let.
    private init(unsafe centavos: Int64, currency: String) {
        self.centavos = centavos
        self.currency = currency
    }

    // MARK: - Computed

    /// Representação `Double` para encoding em NUMERIC. Conversão
    /// determinística e segura para 2 casas decimais.
    ///
    /// Exemplo: `Money(centavos: 60099).valorReal == 600.99`.
    public var valorReal: Double {
        Double(centavos) / 100.0
    }

    /// Representação textual canônica brasileira: `"R$ 600,99"`.
    public var formatted: String {
        let inteiros = centavos / 100
        let fracao = abs(centavos % 100)
        let prefixo: String
        switch currency {
        case "BRL": prefixo = "R$ "
        case "USD": prefixo = "$ "
        case "EUR": prefixo = "€ "
        default:    prefixo = "\(currency) "
        }
        return String(format: "\(prefixo)%lld,%02lld", inteiros, fracao)
    }

    // MARK: - Aritmética (currency-safe)

    /// Soma duas quantias da mesma moeda. Lança `currencyMismatch` se moedas
    /// diferem — princípio "BRL + USD" só faz sentido com câmbio explícito.
    public static func + (lhs: Money, rhs: Money) throws -> Money {
        try checkCurrencyMatch(lhs, rhs)
        return try Money(centavos: lhs.centavos + rhs.centavos, currency: lhs.currency)
    }

    /// Subtrai. Resultado deve ser não-negativo (`init` valida).
    public static func - (lhs: Money, rhs: Money) throws -> Money {
        try checkCurrencyMatch(lhs, rhs)
        return try Money(centavos: lhs.centavos - rhs.centavos, currency: lhs.currency)
    }

    /// Multiplica por inteiro (ex: `salario * 13` para 13º salário).
    public static func * (lhs: Money, rhs: Int) throws -> Money {
        try Money(centavos: lhs.centavos * Int64(rhs), currency: lhs.currency)
    }

    private static func checkCurrencyMatch(_ a: Money, _ b: Money) throws {
        guard a.currency == b.currency else {
            throw MoneyError.currencyMismatch(left: a.currency, right: b.currency)
        }
    }

    // MARK: - Comparable

    /// Compara quantias da mesma moeda. Comparação entre moedas distintas
    /// é semanticamente indefinida — mas Comparable não pode lançar, então
    /// retornamos `false` para currency mismatch (operador `<`).
    /// Use `try lhs - rhs > .zero` para compare strict com erro.
    public static func < (lhs: Money, rhs: Money) -> Bool {
        guard lhs.currency == rhs.currency else { return false }
        return lhs.centavos < rhs.centavos
    }
}

// MARK: - Error

/// Erros lançados por `Money` em construção e aritmética.
public enum MoneyError: Error, Equatable, Sendable {
    case negativeAmount(centavos: Int64)
    case invalidCurrency(received: String)
    case currencyMismatch(left: String, right: String)
}
