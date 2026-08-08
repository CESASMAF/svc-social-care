import Foundation

/// Entidade que representa um relato de violação de direitos.
///
/// Consolida informações críticas sobre incidentes de violência ou negligência,
/// servindo como base para intervenções protetivas e monitoramento de persistência.
public struct RightsViolationReport: Codable, Equatable, Sendable {
    
    // MARK: - Properties
    
    /// Identificador único do relato.
    public let id: ViolationReportId
    
    /// Data em que o relato foi registrado no sistema.
    public let reportDate: TimeStamp
    
    /// Data (opcional) da ocorrência do fato.
    public let incidentDate: TimeStamp?
    
    /// Identificador da pessoa vítima da violação.
    public let victimId: PersonId
    
    /// A tipificação da violação ocorrida.
    public let violationType: ViolationType
    
    /// Descrição detalhada e factual do ocorrido.
    public let descriptionOfFact: String
    
    /// Providências e ações imediatas tomadas após a ciência do fato.
    public private(set) var actionsTaken: String

    // MARK: - Nested Types
    
    /// Catálogo de tipos de violação de direitos previstos no SUAS.
    public enum ViolationType: String, Codable, Sendable, CaseIterable {
        case neglect = "NEGLECT"
        case psychologicalViolence = "PSYCHOLOGICAL_VIOLENCE"
        case physicalViolence = "PHYSICAL_VIOLENCE"
        case sexualAbuse = "SEXUAL_ABUSE"
        case sexualExploitation = "SEXUAL_EXPLOITATION"
        case childLabor = "CHILD_LABOR"
        case financialExploitation = "FINANCIAL_EXPLOITATION"
        case discrimination = "DISCRIMINATION"
        // Tipificacoes que o catalogo operacional (`dominio_tipo_violacao`) ja reconhece e o dominio
        // nao tinha. Sem elas, TORTURA / TRAFICO_PESSOAS / VIOLENCIA_INSTITUCIONAL so poderiam ser
        // registradas como `other` — e como a tabela NAO persiste o id do catalogo, so o enum, o tipo
        // real se perderia para sempre. Num servico de protecao e justamente o dado que importa.
        case torture = "TORTURE"
        case humanTrafficking = "HUMAN_TRAFFICKING"
        case institutionalViolence = "INSTITUTIONAL_VIOLENCE"
        case other = "OTHER"

        /// Traducao do `codigo` do catalogo operacional (pt-BR) para a categoria de dominio (en).
        ///
        /// Os dois vocabularios convivem de proposito: o catalogo e configuravel e carrega metadados
        /// (ex.: `exige_descricao`), o enum e fechado e sustenta regra e analytics. O que NAO podia
        /// continuar e a divergencia silenciosa — nenhum dos 11 codigos casava com os 9 casos, entao
        /// NENHUM tipo escolhido na tela era aceito (RRV-004).
        ///
        /// VIOLENCIA_SEXUAL mapeia para `sexualAbuse`: `sexualExploitation` e um recorte mais especifico
        /// que o catalogo nao distingue hoje; quando distinguir, ganha `codigo` proprio.
        public static func fromCatalogCode(_ codigo: String) -> ViolationType? {
            switch codigo.uppercased() {
            case "NEGLIGENCIA_ABANDONO": return .neglect
            case "VIOLENCIA_PSICOLOGICA": return .psychologicalViolence
            case "VIOLENCIA_FISICA": return .physicalViolence
            case "VIOLENCIA_SEXUAL": return .sexualAbuse
            case "TRABALHO_INFANTIL": return .childLabor
            case "VIOLENCIA_PATRIMONIAL": return .financialExploitation
            case "DISCRIMINACAO": return .discrimination
            case "TORTURA": return .torture
            case "TRAFICO_PESSOAS": return .humanTrafficking
            case "VIOLENCIA_INSTITUCIONAL": return .institutionalViolence
            case "OUTRA": return .other
            default: return nil
            }
        }
    }


    // MARK: - Initializer

    /// Cria uma instância validada de um relato de violação.
    ///
    /// - Throws: `RightsViolationReportError` se datas forem futuras ou descrição estiver vazia.
    public init(
        id: ViolationReportId,
        reportDate: TimeStamp,
        incidentDate: TimeStamp?,
        victimId: PersonId,
        violationType: ViolationType,
        descriptionOfFact: String,
        actionsTaken: String,
        now: TimeStamp = .now
    ) throws {
        guard reportDate <= now else {
            throw RightsViolationReportError.reportDateInFuture
        }

        if let incident = incidentDate {
            guard incident <= reportDate else {
                throw RightsViolationReportError.incidentAfterReport
            }
        }

        let trimmedDescription = descriptionOfFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            throw RightsViolationReportError.emptyDescription
        }

        self.id = id
        self.reportDate = reportDate
        self.incidentDate = incidentDate
        self.victimId = victimId
        self.violationType = violationType
        self.descriptionOfFact = trimmedDescription
        self.actionsTaken = actionsTaken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Mutators (Functional)

    /// Atualiza o registro das providências tomadas.
    ///
    /// - Parameter newActions: O novo texto descritivo das ações.
    public mutating func updateActions(_ newActions: String) {
        self.actionsTaken = newActions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Equatable
    
    public static func == (lhs: RightsViolationReport, rhs: RightsViolationReport) -> Bool {
        return lhs.id == rhs.id
    }
}
