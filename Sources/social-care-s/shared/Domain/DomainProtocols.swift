import Foundation

// MARK: - Core Domain Events

/// Protocolo que todo evento de domínio deve assinar. Representa um fato ocorrido no passado.
public protocol DomainEvent: Sendable {
    var id: UUID { get }
    var occurredAt: Date { get }
}

// `EventBus` foi removido em ADR-014. Eventos são persistidos pelo
// `PatientRepository.save(_:)` na mesma transação do agregado (Outbox
// Pattern). Handlers conhecem apenas o repository — não há porta paralela
// de publicação. O relay (`SQLKitOutboxRelay`) lê a tabela `outbox_messages`
// e publica via NATS.

// MARK: - CQRS: Commands

/// Marca uma intenção de mudança de estado. Deve ser uma struct imutável.
public protocol Command: Sendable {}

/// Marca um comando que produz um resultado simples (ex: UUID do recurso criado).
public protocol ResultCommand: Command {
    associatedtype Result: Sendable
}

/// Handler para processamento de comandos. Sempre um Actor para garantir exclusão mútua.
public protocol CommandHandling<C>: Actor {
    associatedtype C: Command
    /// Processa o comando. Falhas devem ser comunicadas via throws.
    func handle(_ command: C) async throws
}

/// Handler para comandos que retornam um resultado.
public protocol ResultCommandHandling<C>: Actor {
    associatedtype C: ResultCommand
    /// Processa o comando e retorna o resultado.
    func handle(_ command: C) async throws -> C.Result
}

// MARK: - CQRS: Queries

/// Marca uma intenção de leitura de dados. Não deve ter efeitos colaterais.
public protocol Query: Sendable {
    associatedtype Result: Sendable
}

/// Handler para execução de consultas. Geralmente uma struct pura (sem estado mutável).
public protocol QueryHandling<Q>: Sendable {
    associatedtype Q: Query
    /// Executa a consulta e retorna o resultado otimizado para leitura.
    func handle(_ query: Q) async throws -> Q.Result
}

// MARK: - Domain Aggregates

/// Mutações controladas para agregados Event-Sourced.
///
/// Toda implementação concreta deve apropriar `uncommittedEvents` em
/// `addEvent` e zerá-lo em `clearEvents`. Faz parte do contrato exigido por
/// `EventSourcedAggregate` por composição (ADR-004).
public protocol EventSourcedAggregateInternal {
    mutating func addEvent(_ event: any DomainEvent)
    mutating func clearEvents()
}

/// Define as capacidades de um Agregado que utiliza Event Sourcing/Outbox Pattern.
///
/// Compõe `EventSourcedAggregateInternal` por herança (ADR-004) — agregado
/// que não implementa `addEvent`/`clearEvents` não compila. Isso elimina a
/// classe de bug onde `recordEvent` virava no-op silencioso ao falhar no
/// cast dinâmico para `Internal` (achado S-C7).
public protocol EventSourcedAggregate: Sendable, EventSourcedAggregateInternal {
    associatedtype ID: Sendable & Equatable

    var id: ID { get }
    var version: Int { get }
    var uncommittedEvents: [any DomainEvent] { get }
}

// MARK: - Default Implementation (PoP)
extension EventSourcedAggregate {

    /// Registra um novo evento via `addEvent`.
    ///
    /// Versão pós-ADR-004: chamada direta, sem cast dinâmico. A garantia de
    /// que `addEvent` existe vem do protocolo composto — não há mais "caminho
    /// silencioso" onde o cast falha.
    public mutating func recordEvent(_ event: any DomainEvent) {
        self.addEvent(event)
    }
}
