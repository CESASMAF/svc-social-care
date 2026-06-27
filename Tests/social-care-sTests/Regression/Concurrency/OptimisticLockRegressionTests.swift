import Foundation
import Testing
@testable import social_care_s

// ticket: T-005 — achado S-C3 + DB-2 (lost update sem optimistic lock)
// ADR: ADR-005 — Optimistic locking enforçado via coluna `version`

/// Regressão para os achados **S-C3** (Senior Code Review) e **DB-2**
/// (Database Modeling Review), que apontaram o mesmo bug sob lentes
/// diferentes:
///
/// - `SQLKitPatientRepository.save` usa `INSERT ... ON CONFLICT (id) DO UPDATE
///   SET excluded.*` sem checar `version` — duas requisições concorrentes que
///   leiam `version=N` e ambas gravem `version=N+1` se sobrescrevem em
///   silêncio. Em healthcare/social-care isso significa perder anotações de
///   atendimento concorrentes.
/// - A coluna `version: Int` existia mas não era enforçada — "controle de
///   concorrência otimista presente em nome mas não no UPDATE".
///
/// Este suite garante:
/// 1. Save com `version` obsoleta é rejeitado com `optimisticLockFailed`.
/// 2. Save com `version` correta é aceito (caminho normal de update).
/// 3. CREATE (primeira save) funciona — `version=1` é aceito quando row não existe.
/// 4. Erro `optimisticLockFailed` carrega `expectedVersion`/`actualVersion`
///    para o handler diagnosticar e mapear para `409 Conflict`.
///
/// Os testes usam `InMemoryPatientRepository` — a fake foi atualizada para
/// espelhar o invariante do repositório real (ADR-005). Sem isso, os bugs
/// ficariam invisíveis em unit tests e só apareceriam em produção.
@Suite("Regression: Concurrency — S-C3/DB-2 optimistic lock")
struct OptimisticLockRegressionTests {

    // MARK: - Helpers

    /// Cria um paciente seedado no repo, com version=1 e events limpos.
    /// Devolve `(repo, patient)` prontos para o cenário concorrente.
    private func seedRepo() async throws -> (InMemoryPatientRepository, Patient) {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        try await repo.save(patient)
        return (repo, patient)
    }

    /// Aplica uma mutação inócua que incrementa `version` via `addEvent`.
    /// Usar `updateSocialIdentity(nil, …)` deliberadamente — não exige
    /// SocialIdentity válida e mantém o teste focado na concorrência.
    private func mutate(_ p: Patient, actor: String) throws -> Patient {
        var copy = p
        try copy.updateSocialIdentity(nil, actorId: actor)
        return copy
    }

    // MARK: - Tests

    @Test("S-C3 / DB-2 — lost update concorrente é rejeitado com optimisticLockFailed")
    func test_S_C3_DB_2_lost_update_is_rejected() async throws {
        let (repo, initial) = try await seedRepo()
        #expect(initial.version == 1)

        // Dois processos carregam a mesma version=1
        let a = try await repo.find(byId: initial.id)
        let b = try await repo.find(byId: initial.id)
        let pa = try #require(a)
        let pb = try #require(b)
        #expect(pa.version == 1)
        #expect(pb.version == 1)

        // A muta + salva primeiro → banco vai pra version=2
        let aMutated = try mutate(pa, actor: "userA")
        #expect(aMutated.version == 2)
        try await repo.save(aMutated)

        // B muta a cópia antiga + tenta salvar → deve falhar
        // (B também passou de 1 para 2 localmente, mas o banco já está em 2 — B é stale)
        let bMutated = try mutate(pb, actor: "userB")
        #expect(bMutated.version == 2)

        await #expect(throws: PersistenceConflictError.self) {
            try await repo.save(bMutated)
        }
    }

    @Test("S-C3 / DB-2 — optimisticLockFailed carrega expected/actual version para diagnóstico")
    func test_S_C3_DB_2_error_carries_diagnostic_versions() async throws {
        let (repo, initial) = try await seedRepo()
        let pa = try #require(try await repo.find(byId: initial.id))
        let pb = try #require(try await repo.find(byId: initial.id))

        try await repo.save(try mutate(pa, actor: "userA"))  // db agora em version=2

        let bStale = try mutate(pb, actor: "userB")  // local version=2, mas expected db=1

        do {
            try await repo.save(bStale)
            Issue.record("Expected throw, got success")
        } catch let PersistenceConflictError.optimisticLockFailed(expected, actual) {
            #expect(expected == 1,
                    "B esperava encontrar o banco em version=1 (sua leitura inicial)")
            #expect(actual == 2,
                    "Banco já estava em version=2 (A salvou primeiro)")
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("S-C3 / DB-2 — save sucessivo com version correta funciona (caminho normal de update)")
    func test_S_C3_DB_2_sequential_updates_succeed() async throws {
        let (repo, initial) = try await seedRepo()
        var current = try #require(try await repo.find(byId: initial.id))
        #expect(current.version == 1)

        // Três updates em sequência, cada um com version correta — todos devem passar.
        for tick in 1...3 {
            current = try mutate(current, actor: "userA")
            #expect(current.version == tick + 1)
            try await repo.save(current)

            let reloaded = try #require(try await repo.find(byId: initial.id))
            #expect(reloaded.version == tick + 1)
            current = reloaded
        }
    }

    @Test("S-C3 / DB-2 — primeira save (CREATE path) com version=1 funciona quando row não existe")
    func test_S_C3_DB_2_create_path_works_for_new_aggregate() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        #expect(patient.version == 1, "Patient.init dispara PatientCreatedEvent → version vai de 0 para 1")

        // Nenhum row no banco — INSERT path. Não deve falhar com optimistic lock.
        try await repo.save(patient)

        let stored = try #require(try await repo.find(byId: patient.id))
        #expect(stored.version == 1)
    }
}
