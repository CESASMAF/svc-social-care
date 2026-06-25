import Testing
import Foundation
@testable import social_care_s

@Suite("RegisterPatient Command Handler")
struct RegisterPatientTests {

    private static let personId = "770e8400-e29b-41d4-a716-446655440099"
    private static let prRelationshipId = UUID().uuidString

    private static func makeCommand(
        personId: String = RegisterPatientTests.personId,
        icdCode: String = "B201",
        prRelationshipId: String = RegisterPatientTests.prRelationshipId,
        personalData: RegisterPatientCommand.PersonalDataDraft? = nil,
        civilDocuments: RegisterPatientCommand.CivilDocumentsDraft? = nil,
        address: RegisterPatientCommand.AddressDraft? = nil,
        socialIdentity: RegisterPatientCommand.SocialIdentityDraft? = nil,
        actorId: String = "actor-1"
    ) -> RegisterPatientCommand {
        RegisterPatientCommand(
            personId: personId,
            initialDiagnoses: [
                .init(icdCode: icdCode, date: Date(), description: "Diagnostico teste")
            ],
            personalData: personalData,
            civilDocuments: civilDocuments,
            address: address,
            socialIdentity: socialIdentity,
            prRelationshipId: prRelationshipId,
            actorId: actorId
        )
    }

    @Test("Deve registrar paciente com dados minimos")
    func successfulMinimalRegistration() async throws {
        let repo = InMemoryPatientRepository()
        let handler = RegisterPatientCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        let patientId = try await handler.handle(Self.makeCommand())

        #expect(!patientId.isEmpty)
        let patients = await repo.allPatients
        #expect(patients.count == 1)
        #expect(patients.first?.personId.description == Self.personId)

        let eventCount = await repo.publishedEvents.count
        #expect(eventCount >= 1)
    }

    @Test("Deve registrar paciente com dados pessoais completos")
    func registrationWithPersonalData() async throws {
        let repo = InMemoryPatientRepository()
        let handler = RegisterPatientCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        let personalData = RegisterPatientCommand.PersonalDataDraft(
            firstName: "Maria", lastName: "Silva", motherName: "Ana",
            nationality: "Brasileira", sex: "feminino", socialName: nil,
            birthDate: Date(timeIntervalSince1970: 631152000), phone: nil
        )

        let patientId = try await handler.handle(Self.makeCommand(personalData: personalData))
        #expect(!patientId.isEmpty)

        let patients = await repo.allPatients
        #expect(patients.first?.personalData?.firstName == "Maria")
    }

    @Test("Deve falhar quando personId ja existe")
    func duplicatePersonId() async throws {
        let repo = InMemoryPatientRepository()
        let patient = try PatientFixture.createMinimal(personId: Self.personId)
        await repo.seed(patient)

        let handler = RegisterPatientCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        await #expect(throws: RegisterPatientError.self) {
            try await handler.handle(Self.makeCommand())
        }
    }

    @Test("Deve falhar com lookup de parentesco invalido")
    func invalidRelationshipLookup() async throws {
        let repo = InMemoryPatientRepository()
        let lookup = InMemoryLookupValidator()

        let handler = RegisterPatientCommandHandler(
            repository: repo, lookupValidator: lookup
        )

        await #expect(throws: RegisterPatientError.self) {
            try await handler.handle(Self.makeCommand())
        }
    }

    @Test("Deve falhar com codigo ICD vazio")
    func emptyIcdCode() async throws {
        let repo = InMemoryPatientRepository()
        let handler = RegisterPatientCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        await #expect(throws: RegisterPatientError.self) {
            try await handler.handle(Self.makeCommand(icdCode: ""))
        }
    }

    @Test("Deve falhar quando CPF ja existe em outro paciente")
    func duplicateCpf() async throws {
        let repo = InMemoryPatientRepository()
        let handler = RegisterPatientCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        let cpf = "12345678909"
        let civilDocs = RegisterPatientCommand.CivilDocumentsDraft(cpf: cpf, nis: nil, rgDocument: nil)

        // Primeiro registro com CPF — deve funcionar
        let pid1 = UUID().uuidString
        _ = try await handler.handle(Self.makeCommand(personId: pid1, civilDocuments: civilDocs))

        // Segundo registro com mesmo CPF, personId diferente — deve falhar
        let pid2 = UUID().uuidString
        await #expect(throws: RegisterPatientError.cpfAlreadyExists("***")) {
            try await handler.handle(Self.makeCommand(personId: pid2, civilDocuments: civilDocs))
        }

        let patients = await repo.allPatients
        #expect(patients.count == 1)
    }

    @Test("Deve permitir registros sem CPF (CPF eh opcional)")
    func multiplePatientsWithoutCpf() async throws {
        let repo = InMemoryPatientRepository()
        let handler = RegisterPatientCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        let pid1 = UUID().uuidString
        let pid2 = UUID().uuidString

        _ = try await handler.handle(Self.makeCommand(personId: pid1))
        _ = try await handler.handle(Self.makeCommand(personId: pid2))

        let patients = await repo.allPatients
        #expect(patients.count == 2)
    }

    @Test("Actor isolation: registros concorrentes de pacientes distintos")
    func concurrentRegistrations() async throws {
        let repo = InMemoryPatientRepository()
        let handler = RegisterPatientCommandHandler(
            repository: repo, lookupValidator: AllowAllLookupValidator()
        )

        let pid1 = UUID().uuidString
        let pid2 = UUID().uuidString

        async let r1 = handler.handle(Self.makeCommand(personId: pid1, actorId: "actor-1"))
        async let r2 = handler.handle(Self.makeCommand(personId: pid2, actorId: "actor-2"))

        let id1 = try await r1
        let id2 = try await r2

        #expect(!id1.isEmpty)
        #expect(!id2.isEmpty)
        #expect(id1 != id2)

        let patients = await repo.allPatients
        #expect(patients.count == 2)
    }
}
