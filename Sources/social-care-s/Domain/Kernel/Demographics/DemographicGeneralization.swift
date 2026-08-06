import Foundation

/// Generalização demográfica — transforma PII em quase-identificadores.
///
/// **Por que isto vive no `social-care` e não no `analysis-bi`.** O BI promete
/// que PII nunca chega até ele, e data de nascimento e CEP são PII. Enquanto a
/// generalização acontecia lá, a promessa dependia de o dado atravessar o NATS
/// em claro — ou seja, era falsa. Generalizando na origem, o que sai deste
/// serviço já é faixa etária e mesorregião, e a promessa passa a valer no
/// código.
///
/// **Equivalência.** As faixas e a regra de prefixo de CEP são as mesmas que o
/// `analysis-bi` aplicava (`internal/domain/anonymizer.go`,
/// `internal/domain/geography_csv.go`). Se mudarem aqui, mudam o eixo dos
/// indicadores — não altere sem ADR.
public enum DemographicGeneralization {

    // MARK: - Faixa etária

    /// Faixas de 5 anos até 79, e `80+` no topo — o mesmo corte usado pelo BI.
    ///
    /// O topo aberto existe por privacidade: acima de 80 os grupos ficam
    /// pequenos e uma faixa de 5 anos viraria quase-identificador.
    public static let ageBands: [(label: String, min: Int, max: Int)] = [
        ("0-4", 0, 4), ("5-9", 5, 9), ("10-14", 10, 14), ("15-19", 15, 19),
        ("20-24", 20, 24), ("25-29", 25, 29), ("30-34", 30, 34), ("35-39", 35, 39),
        ("40-44", 40, 44), ("45-49", 45, 49), ("50-54", 50, 54), ("55-59", 55, 59),
        ("60-64", 60, 64), ("65-69", 65, 69), ("70-74", 70, 74), ("75-79", 75, 79),
        ("80+", 80, 199),
    ]

    /// Devolve o rótulo da faixa etária, ou `nil` quando não há como calcular.
    ///
    /// `nil` em vez de uma faixa "desconhecida": um rótulo inventado entraria no
    /// cubo como se fosse dado, e o BI não teria como distinguir "não sabemos"
    /// de "faixa X". Ausência é informação.
    ///
    /// - Parameters:
    ///   - birthDate: data de nascimento (PII — não sai deste serviço).
    ///   - reference: data de referência do cálculo (normalmente o `occurredAt`
    ///     do evento, não `now`, para que reprocessar não mude o resultado).
    public static func ageBand(birthDate: Date, reference: Date) -> String? {
        guard birthDate <= reference else { return nil }   // nascimento no futuro

        let years = Calendar(identifier: .gregorian)
            .dateComponents([.year], from: birthDate, to: reference).year
        guard let age = years, age >= 0 else { return nil }

        return ageBands.first { age >= $0.min && age <= $0.max }?.label
    }

    // MARK: - Geografia

    /// Resolve um CEP para a mesorregião do IBGE, ou `nil` se não mapear.
    ///
    /// Aceita CEP com ou sem máscara.
    ///
    /// **Busca por FAIXA, não por prefixo.** A tabela do IBGE lista o CEP
    /// *inicial* de cada faixa (`01000`, `02000`, `28600`, `29100`…), e cada
    /// faixa vale até o início da seguinte. A resolução correta é "a maior
    /// faixa ≤ o CEP consultado".
    ///
    /// O `analysis-bi` fazia casamento de prefixo decrescente (8→5 dígitos), o
    /// que **não resolve quase nenhum CEP real**: `01310100` (Av. Paulista)
    /// tentaria `01310` e desistiria, porque só `01000` está na tabela. O bug
    /// nunca apareceu porque os testes de lá usavam um lookup falso — e porque
    /// CEP nenhum chegava a ser enviado.
    public static func mesoregion(cep: String) -> Mesoregion? {
        let digits = cep.filter(\.isNumber)
        guard digits.count == 8 else { return nil }

        let key = String(digits.prefix(5))
        let ranges = IBGEMesoregionTable.ranges
        guard let first = ranges.first, key >= first.start else { return nil }

        // Busca binária pela última faixa cujo início é <= key.
        var low = 0
        var high = ranges.count - 1
        var match = 0
        while low <= high {
            let mid = (low + high) / 2
            if ranges[mid].start <= key {
                match = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return ranges[match].meso
    }
}
