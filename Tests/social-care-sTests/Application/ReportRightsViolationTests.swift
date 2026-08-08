import Testing
import Foundation
@testable import social_care_s

@Suite("ReportRightsViolation Command Handler")
struct ReportRightsViolationTests {

    @Test("Deve registrar violacao de direitos com sucesso")
    func successfulReport() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = ReportRightsViolationCommandHandler(repository: repo)

        let reportId = try await handler.handle(ReportRightsViolationCommand(
            patientId: patient.id.description,
            victimId: PatientFixture.defaultPersonId,
            violationType: "NEGLECT",
            descriptionOfFact: "Descricao detalhada do fato ocorrido",
            actorId: "actor-1"
        ))

        #expect(!reportId.isEmpty)

        let saved = try await repo.find(byPersonId: PersonId(PatientFixture.defaultPersonId))
        #expect(saved?.violationReports.count == 1)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve falhar com tipo de violacao invalido")
    func invalidViolationType() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimalActive()
        await repo.seed(patient)

        let handler = ReportRightsViolationCommandHandler(repository: repo)

        await #expect(throws: ReportRightsViolationError.self) {
            try await handler.handle(ReportRightsViolationCommand(
                patientId: patient.id.description,
                victimId: PatientFixture.defaultPersonId,
                violationType: "TIPO_INVALIDO",
                descriptionOfFact: "Descricao",
                actorId: "actor-1"
            ))
        }
    }

    @Test("Deve falhar quando paciente nao encontrado")
    func patientNotFound() async throws {
        let repo = InMemoryPatientRepository()
        let handler = ReportRightsViolationCommandHandler(repository: repo)

        await #expect(throws: ReportRightsViolationError.self) {
            try await handler.handle(ReportRightsViolationCommand(
                patientId: UUID().uuidString,
                victimId: UUID().uuidString,
                violationType: "NEGLECT",
                descriptionOfFact: "Descricao",
                actorId: "actor-1"
            ))
        }
    }

    @Test("Actor isolation: relatos concorrentes em pacientes distintos")
    func concurrentReports() async throws {
        let repo = InMemoryPatientRepository()

        let p1 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        let p2 = try PatientFixture.createMinimalActive(personId: UUID().uuidString)
        await repo.seed(p1)
        await repo.seed(p2)

        let handler = ReportRightsViolationCommandHandler(repository: repo)

        async let r1 = handler.handle(ReportRightsViolationCommand(
            patientId: p1.id.description,
            victimId: p1.personId.description,
            violationType: "NEGLECT",
            descriptionOfFact: "Fato A",
            actorId: "actor-1"
        ))
        async let r2 = handler.handle(ReportRightsViolationCommand(
            patientId: p2.id.description,
            victimId: p2.personId.description,
            violationType: "DISCRIMINATION",
            descriptionOfFact: "Fato B",
            actorId: "actor-2"
        ))

        let id1 = try await r1
        let id2 = try await r2

        #expect(!id1.isEmpty)
        #expect(!id2.isEmpty)
    }
}

// MARK: - Catalogo (pt-BR) -> categoria de dominio (en)
//
// O catalogo `dominio_tipo_violacao` esta em portugues e o enum do dominio em ingles. Nenhum dos 11
// codigos casava com os 9 casos, entao NENHUM tipo escolhido na tela era aceito (RRV-004) — o
// formulario de violacao de direitos era inteiramente inoperante. Estes testes fixam a traducao;
// se o catalogo ganhar um codigo novo, o ultimo teste quebra e obriga a decidir a categoria.
@Suite("ViolationType — traducao do catalogo operacional")
struct ViolationTypeCatalogMappingTests {
    typealias VT = RightsViolationReport.ViolationType

    @Test("todo codigo do catalogo tem categoria de dominio")
    func todosOsCodigosMapeiam() {
        // Os 11 codigos semeados em `dominio_tipo_violacao`.
        let catalogo = [
            "NEGLIGENCIA_ABANDONO", "VIOLENCIA_PSICOLOGICA", "VIOLENCIA_FISICA", "VIOLENCIA_SEXUAL",
            "TRABALHO_INFANTIL", "VIOLENCIA_PATRIMONIAL", "DISCRIMINACAO", "TORTURA",
            "TRAFICO_PESSOAS", "VIOLENCIA_INSTITUCIONAL", "OUTRA",
        ]
        for codigo in catalogo {
            #expect(VT.fromCatalogCode(codigo) != nil, "codigo '\(codigo)' ficou sem categoria de dominio")
        }
    }

    @Test("tipos graves NAO caem em `other` — a tabela nao guarda o id do catalogo, o dado se perderia")
    func tiposGravesTemCategoriaPropria() {
        #expect(VT.fromCatalogCode("TORTURA") == .torture)
        #expect(VT.fromCatalogCode("TRAFICO_PESSOAS") == .humanTrafficking)
        #expect(VT.fromCatalogCode("VIOLENCIA_INSTITUCIONAL") == .institutionalViolence)
        #expect(VT.fromCatalogCode("DISCRIMINACAO") == .discrimination)
    }

    @Test("codigo desconhecido devolve nil — vira 422 explicito, nao um `other` silencioso")
    func codigoDesconhecido() {
        #expect(VT.fromCatalogCode("CODIGO_QUE_NAO_EXISTE") == nil)
    }

    @Test("comparacao e case-insensitive")
    func caseInsensitive() {
        #expect(VT.fromCatalogCode("tortura") == .torture)
    }
}
