import Foundation
@testable import social_care_s

/// Fixture centralizada para testes de regressão (`Tests/.../Regression/`).
///
/// Centraliza helpers determinísticos para que testes de regressão sejam
/// reproduzíveis bit-a-bit em CI. Foi introduzida pelo ticket T-001 da
/// `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` e é coberta pela
/// política ADR-002.
///
/// Princípio: testes de regressão não podem ser flaky. Toda dependência de
/// tempo, identidade ou estado externo passa por aqui — nunca pelo `.now`
/// global ou `UUID()` direto.
enum RegressionFixture {

    // MARK: - Determinístico: clock

    /// Retorna uma closure que sempre devolve o mesmo `TimeStamp`, simulando
    /// um relógio congelado para o teste.
    ///
    /// Uso típico em handlers que precisam de `clock: () -> TimeStamp`:
    ///
    /// ```swift
    /// let clock = RegressionFixture.frozenClock(at: "2026-05-14T12:00:00Z")
    /// let handler = RegisterPatientCommandHandler(clock: clock, ...)
    /// ```
    ///
    /// - Parameter iso: Instante a congelar em formato ISO8601. Default é
    ///   `2026-05-14T12:00:00Z` (data de criação desta fixture).
    static func frozenClock(at iso: String = "2026-05-14T12:00:00Z") -> @Sendable () -> TimeStamp {
        guard let frozen = try? TimeStamp(iso: iso) else {
            preconditionFailure("RegressionFixture.frozenClock recebeu ISO inválido: \(iso)")
        }
        return { frozen }
    }

    /// Retorna um `TimeStamp` determinístico — versão eager para testes que
    /// precisam do valor direto, não da closure.
    static func frozenTimestamp(at iso: String = "2026-05-14T12:00:00Z") -> TimeStamp {
        guard let frozen = try? TimeStamp(iso: iso) else {
            preconditionFailure("RegressionFixture.frozenTimestamp recebeu ISO inválido: \(iso)")
        }
        return frozen
    }

    // MARK: - Lookups pre-populados

    /// Retorna um `InMemoryLookupValidator` já com os IDs informados
    /// registrados nas tabelas correspondentes — evita boilerplate de
    /// `await validator.register(...)` em cada teste.
    ///
    /// - Parameter entries: Mapa `tabela → [LookupId]` a registrar.
    static func prepopulatedLookupValidator(
        _ entries: [String: [LookupId]] = [:]
    ) async -> InMemoryLookupValidator {
        let validator = InMemoryLookupValidator()
        for (table, ids) in entries {
            await validator.registerAll(ids: ids, in: table)
        }
        return validator
    }

    /// Atalho: validator que aceita qualquer ID em qualquer tabela. Usar
    /// somente quando o teste **não** está exercitando validação de lookup
    /// — caso contrário, prepopular com `prepopulatedLookupValidator`.
    static func permissiveLookupValidator() -> AllowAllLookupValidator {
        AllowAllLookupValidator()
    }

    // MARK: - UnitOfWork (placeholder até T-030)

    /// Stub de Unit-of-Work que executa o bloco sem transação real.
    ///
    /// - Important: este stub existe para que testes de regressão que
    ///   dependem de UoW possam ser escritos **antes** da implementação
    ///   real (ticket T-030, ADR-030). Quando T-030 fechar, este stub é
    ///   substituído por implementação que respeita rollback.
    ///
    /// - Warning: stub NÃO testa atomicidade. Testes que precisam validar
    ///   rollback cross-repository devem aguardar T-030 ou usar o
    ///   `FailingUnitOfWork` (futuro).
    struct StubUnitOfWork: Sendable {
        init() {}

        func transaction<T: Sendable>(
            _ work: @Sendable () async throws -> T
        ) async throws -> T {
            try await work()
        }
    }

    static func stubUnitOfWork() -> StubUnitOfWork {
        StubUnitOfWork()
    }

    // MARK: - UUID determinístico

    /// Gera um UUID determinístico a partir de uma seed numérica. Útil para
    /// testes que precisam de IDs estáveis sem depender de fixtures
    /// hardcoded em string.
    ///
    /// ```swift
    /// let patientId = RegressionFixture.uuid(seed: 1)
    /// // → 00000000-0000-0000-0000-000000000001
    /// ```
    static func uuid(seed: UInt64) -> UUID {
        let bytes: [UInt8] = [
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            UInt8((seed >> 24) & 0xFF),
            UInt8((seed >> 16) & 0xFF),
            UInt8((seed >> 8)  & 0xFF),
            UInt8(seed         & 0xFF),
        ]
        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
