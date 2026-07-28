import NIOConcurrencyHelpers

/// Contabiliza requisições que chegam sem credencial (`Authorization: Bearer`
/// ausente) e decide quando o fato merece uma linha de log.
///
/// **Por que existe.** Requisição anônima é evento *esperado* num serviço
/// autenticado — scanner, health check mal configurado, browser numa rota
/// protegida. Logar cada uma em `error` transforma o nível ERROR em ruído e,
/// como alerta o OWASP Logging Cheat Sheet, log irrestrito é vetor de exaustão de
/// recurso. Mas silenciar (`debug`, desligado em produção) é o extremo oposto: o
/// mesmo documento lista "Authentication successes and failures" entre os eventos
/// que devem ser registrados, porque falhas de autenticação são indicador precoce
/// de brute-force e credential-stuffing (ASVS 7.1.1).
///
/// **Como resolve os dois lados.** Conta *todas* as ocorrências — o número está
/// sempre disponível — e sinaliza para log apenas em **marcos** (1, 2, 4, 8, 16…).
/// O volume de log cresce logaritmicamente: uma varredura de 100 mil requisições
/// produz ~17 linhas, cada uma carregando o total acumulado. O sinal sobrevive em
/// produção sem que o ruído volte.
///
/// Thread-safe via `NIOLockedValueBox` (mesmo padrão do `NATSEventSubscriber`).
final class AnonymousAccessMonitor: Sendable {
    /// Instância do processo. O contador é por réplica — o agregado entre réplicas
    /// é trabalho do coletor de logs, não deste tipo.
    static let shared = AnonymousAccessMonitor()

    private let counter = NIOLockedValueBox<UInt64>(0)

    /// Total de requisições anônimas observadas desde o boot (ou desde o último
    /// `reset()`).
    var count: UInt64 {
        counter.withLockedValue { $0 }
    }

    /// Registra uma ocorrência.
    ///
    /// - Returns: `total` acumulado e `isMilestone`, que é `true` quando o total é
    ///   potência de 2 — o gatilho de log. O total acompanha o retorno para que a
    ///   linha registrada diga *quantas* houve, e não apenas que houve mais uma:
    ///   sem isso o registro não é acionável.
    @discardableResult
    func record() -> (total: UInt64, isMilestone: Bool) {
        counter.withLockedValue { value in
            value += 1
            // Potência de 2: apenas um bit ligado. Vale para 1, 2, 4, 8, …
            let isMilestone = (value & (value - 1)) == 0
            return (value, isMilestone)
        }
    }

    /// Zera o contador. Existe para isolamento entre testes — em produção o
    /// contador é monotônico durante a vida do processo.
    func reset() {
        counter.withLockedValue { $0 = 0 }
    }
}
