import Foundation

/// Representa um erro padronizado dentro do Bounded Context, seguindo o contrato definido no JSON Schema.
public struct AppError: Error, Sendable, Equatable {
    
    // Manual Equatable implementation since cause (any Error) is not Equatable
    public static func == (lhs: AppError, rhs: AppError) -> Bool {
        return lhs.id == rhs.id || (lhs.code == rhs.code && lhs.bc == rhs.bc && lhs.module == rhs.module)
    }

    // MARK: - Required Properties
    
    /// Identificador único gerado na criação do erro.
    public let id: String
    
    /// Código de erro estável para suporte (ex: PAT-001).
    public let code: String
    
    /// Mensagem de erro final para o usuário.
    public let message: String
    
    /// Bounded Context onde o erro se originou.
    public let bc: String
    
    /// Módulo ou subdomínio de origem.
    public let module: String
    
    /// Tipo específico de erro dentro do catálogo do módulo.
    public let kind: String
    
    /// Dados contextuais brutos capturados na criação.
    public let context: [String: AnySendable]
    
    /// Contexto sanitizado, seguro para logs externos e respostas.
    public let safeContext: [String: AnySendable]
    
    /// Dados de observabilidade para telemetria.
    public let observability: Observability
    
    // MARK: - Optional Properties
    
    /// Status HTTP sugerido para camadas de entrega.
    public let http: Int?
    
    /// Stack trace original, se disponível.
    public let stackTrace: String?
    
    /// Causa raiz associada a este erro.
    public let cause: (any Error)?

    // MARK: - Nested Types
    
    public struct Observability: Sendable, Equatable {
        public let category: Category
        public let severity: Severity
        public let fingerprint: [String]
        public let tags: [String: String]
        
        public init(
            category: Category,
            severity: Severity,
            fingerprint: [String],
            tags: [String: String]
        ) {
            self.category = category
            self.severity = severity
            self.fingerprint = fingerprint
            self.tags = tags
        }
    }
    
    public enum Category: String, Sendable {
        case domainRuleViolation = "DOMAIN_RULE_VIOLATION"
        case externalApiFailure = "EXTERNAL_API_FAILURE"
        case externalContractMismatch = "EXTERNAL_CONTRACT_MISMATCH"
        case crossLayerCommunicationFailure = "CROSS_LAYER_COMMUNICATION_FAILURE"
        case dataConsistencyIncident = "DATA_CONSISTENCY_INCIDENT"
        case securityBoundaryViolation = "SECURITY_BOUNDARY_VIOLATION"
        case infrastructureDependencyFailure = "INFRASTRUCTURE_DEPENDENCY_FAILURE"
        case observabilityPipelineFailure = "OBSERVABILITY_PIPELINE_FAILURE"
        case unexpectedSystemState = "UNEXPECTED_SYSTEM_STATE"
        case conflict = "CONFLICT"
    }
    
    public enum Severity: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        case critical = "CRITICAL"
    }

    // MARK: - Initializer
    
    public init(
        id: String = UUID().uuidString,
        code: String,
        message: String,
        bc: String,
        module: String,
        kind: String,
        context: [String: AnySendable],
        safeContext: [String: AnySendable],
        observability: Observability,
        http: Int? = nil,
        stackTrace: String? = nil,
        cause: (any Error)? = nil
    ) {
        self.id = id
        self.code = code
        self.message = message
        self.bc = bc
        self.module = module
        self.kind = kind
        self.context = context
        self.safeContext = safeContext
        self.observability = observability
        self.http = http
        self.stackTrace = stackTrace
        self.cause = cause
    }
}

/// Helper para permitir que dicionários de contexto sejam Sendable e
/// armazenem valores diversos.
///
/// **ADR-018 — Banimento de `@unchecked Sendable` em estruturas de fronteira.**
/// Pré-fix era `struct AnySendable: @unchecked Sendable` armazenando `Any`.
/// `@unchecked` desliga a verificação do compilador; `Any` pode armazenar
/// qualquer coisa (incluindo classes mutáveis não-thread-safe). O contrato
/// `Sendable` estava sendo prometido sem verificação real.
///
/// Pós-fix: enum fechado com cases tipados — Sendable de verdade. `init(_:Any)`
/// e `value: Any` getter mantidos para back-compat com 24 handlers que ainda
/// usam o pattern `context.mapValues { AnySendable($0) }`. A migração desses
/// handlers para usar cases tipados explicitamente fica como melhoria
/// incremental — o invariante "Sendable verdadeiro" já está garantido.
public enum AnySendable: Sendable, Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnySendable])
    case object([String: AnySendable])
    case null

    /// Construtor best-effort que mapeia `Any` para um case fechado.
    /// Mantido para back-compat com call sites de Application que passam
    /// `context.mapValues { AnySendable($0) }`.
    /// Valores não suportados (UUID, Date, etc.) viram `.string("\(value)")`.
    public init(_ value: Any) {
        switch value {
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Double: self = .double(v)
        case let v as [Any]: self = .array(v.map { AnySendable($0) })
        case let v as [String: Any]: self = .object(v.mapValues { AnySendable($0) })
        case let v as AnySendable: self = v
        case is NSNull: self = .null
        default: self = .string("\(value)")
        }
    }

    /// Getter de back-compat: retorna o valor como `Any` para call sites
    /// que ainda inspecionam `.value` direto.
    public var value: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .array(let v): return v.map(\.value)
        case .object(let v): return v.mapValues(\.value)
        case .null: return NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([AnySendable].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: AnySendable].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }
}

// Extensões para facilitar o uso do Result pattern
public extension Result where Failure == AppError {
    static func appFailure(
        code: String,
        message: String,
        bc: String,
        module: String,
        kind: String,
        category: AppError.Category,
        severity: AppError.Severity,
        context: [String: Any] = [:],
        http: Int? = nil
    ) -> Self {
        let error = AppError(
            code: code,
            message: message,
            bc: bc,
            module: module,
            kind: kind,
            context: context.mapValues { AnySendable($0) },
            safeContext: [:],
            observability: .init(
                category: category,
                severity: severity,
                fingerprint: [code],
                tags: [:]
            ),
            http: http
        )
        return .failure(error)
    }
}

// MARK: - AppErrorConvertible

/// Protocolo que todo erro de domínio deve assinar para ser traduzido para o contrato de AppError do microserviço.
public protocol AppErrorConvertible: Error {
    /// A representação do erro no formato padronizado AppError.
    var asAppError: AppError { get }
}
