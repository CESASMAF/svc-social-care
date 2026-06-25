import Foundation
import Testing
@testable import social_care_s

/// Suite meta que valida que a infra de regressão está discoverable e
/// funcional. Criado pelo ticket T-001 (Foundations).
///
/// Esses testes NÃO cobrem bug específico — cobrem a própria infra:
/// `make regression` deve ter ao menos UM teste para discovery do filtro
/// `swift test --filter "Regression:"` funcionar.
///
/// Quando os primeiros testes de regressão reais entrarem (T-004, T-005, ...),
/// estes sentinels permanecem como guarda-chuva da infra.
@Suite("Regression: Meta")
struct RegressionMetaTests {

    @Test("Sentinel — RegressionFixture.frozenClock retorna timestamp estável")
    func sentinelFrozenClockIsStable() async throws {
        let clock = RegressionFixture.frozenClock(at: "2026-05-14T12:00:00Z")
        let first = clock()
        let second = clock()
        #expect(first == second, "frozenClock DEVE retornar o mesmo valor em chamadas sucessivas")

        let expected = try TimeStamp(iso: "2026-05-14T12:00:00Z")
        #expect(first == expected)
    }

    @Test("Sentinel — RegressionFixture.uuid(seed:) é determinístico")
    func sentinelUUIDIsDeterministic() {
        let a = RegressionFixture.uuid(seed: 42)
        let b = RegressionFixture.uuid(seed: 42)
        #expect(a == b, "uuid(seed:) com mesma seed DEVE retornar mesmo UUID")

        let c = RegressionFixture.uuid(seed: 43)
        #expect(a != c, "uuid(seed:) com seeds diferentes DEVE retornar UUIDs diferentes")
    }

    @Test("Sentinel — prepopulatedLookupValidator aceita IDs registrados")
    func sentinelPrepopulatedLookupValidator() async throws {
        let lookupId = try LookupId(UUID().uuidString)
        let validator = await RegressionFixture.prepopulatedLookupValidator([
            "dominio_parentesco": [lookupId]
        ])

        let exists = try await validator.exists(id: lookupId, in: "dominio_parentesco")
        #expect(exists, "Lookup pre-populado DEVE existir")

        let other = try LookupId(UUID().uuidString)
        let unknown = try await validator.exists(id: other, in: "dominio_parentesco")
        #expect(!unknown, "Lookup não pre-populado NÃO DEVE existir")
    }

    @Test("Sentinel — StubUnitOfWork executa o bloco e propaga resultado")
    func sentinelStubUoW() async throws {
        let uow = RegressionFixture.stubUnitOfWork()
        let result = try await uow.transaction { "ok" }
        #expect(result == "ok")
    }

    @Test("Sentinel — StubUnitOfWork propaga erro lançado dentro do bloco")
    func sentinelStubUoWPropagatesError() async throws {
        struct Boom: Error {}
        let uow = RegressionFixture.stubUnitOfWork()
        await #expect(throws: Boom.self) {
            try await uow.transaction { throw Boom() }
        }
    }
}
