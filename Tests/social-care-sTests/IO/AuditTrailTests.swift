import Testing
import Foundation
@testable import social_care_s

@Suite("Audit Trail Pipeline")
struct AuditTrailTests {

    // MARK: - DomainEventRegistry

    @Test("Registry deve decodificar evento registrado")
    func registryDecodesRegisteredEvent() async throws {
        let registry = DomainEventRegistry.shared
        await registry.bootstrap()

        let event = PatientCreatedEvent(
            patientId: UUID().uuidString,
            personId: UUID().uuidString,
            actorId: "actor-test",
            occurredAt: Date()
        )
        let payload = try JSONEncoder().encode(event)

        let decoded = try await registry.decode(typeName: "PatientCreatedEvent", data: payload)
        #expect(decoded.id == event.id)
        #expect(decoded.occurredAt.timeIntervalSince1970 == event.occurredAt.timeIntervalSince1970)
    }

    @Test("Registry deve falhar para tipo nao registrado")
    func registryFailsForUnknownType() async throws {
        let registry = DomainEventRegistry.shared
        let fakePayload = Data("{}".utf8)

        await #expect(throws: DomainEventError.self) {
            try await registry.decode(typeName: "TipoInexistente", data: fakePayload)
        }
    }

    // MARK: - Outbox Mapper

    @Test("toOutbox deve gerar modelo correto a partir de evento de dominio")
    func toOutboxGeneratesCorrectModel() throws {
        let patient = try PatientFixture.createMinimal()
        let events = patient.uncommittedEvents
        #expect(!events.isEmpty)

        let outboxModels = try PatientDatabaseMapper.toOutbox(events)
        #expect(outboxModels.count == events.count)

        let first = outboxModels[0]
        #expect(first.event_type == "PatientCreatedEvent")
        #expect(first.processed_at == nil)
        #expect(first.id == events[0].id)
    }

    @Test("Payload do outbox deve conter actorId e patientId para extractFields")
    func outboxPayloadContainsRequiredFields() throws {
        let patient = try PatientFixture.createMinimal(actorId: "audit-actor-42")
        let outboxModels = try PatientDatabaseMapper.toOutbox(patient.uncommittedEvents)
        let payload = outboxModels[0].payload

        let json = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        #expect(json?["actorId"] as? String == "audit-actor-42")
        #expect(json?["patientId"] != nil)
    }

    @Test("toOutbox com lista vazia deve retornar lista vazia")
    func toOutboxEmptyEvents() throws {
        let outboxModels = try PatientDatabaseMapper.toOutbox([])
        #expect(outboxModels.isEmpty)
    }

    @Test("toOutbox deve preservar event_type para cada tipo de evento")
    func toOutboxPreservesEventTypes() throws {
        let patient = try PatientFixture.createWithAdditionalMember()

        var mutated = patient
        try mutated.updateHousingCondition(
            HousingCondition(
                type: .owned, wallMaterial: .masonry,
                numberOfRooms: 3, numberOfBedrooms: 1, numberOfBathrooms: 1,
                waterSupply: .publicNetwork, hasPipedWater: true,
                electricityAccess: .meteredConnection, sewageDisposal: .publicSewer,
                wasteCollection: .directCollection, accessibilityLevel: .fullyAccessible,
                isInGeographicRiskArea: false, hasDifficultAccess: false,
                isInSocialConflictArea: false, hasDiagnosticObservations: false
            ),
            actorId: "actor-multi"
        )

        let outboxModels = try PatientDatabaseMapper.toOutbox(mutated.uncommittedEvents)
        let eventTypes = outboxModels.map(\.event_type)
        #expect(eventTypes.contains("PatientCreatedEvent"))
        #expect(eventTypes.contains("HousingConditionUpdatedEvent"))
    }

    // MARK: - AuditTrailEntryResponse

    @Test("AuditTrailEntryResponse deve mapear campos corretamente do model")
    func auditTrailEntryResponseMapping() {
        let id = UUID()
        let aggregateId = UUID()
        let occurred = Date(timeIntervalSince1970: 1_700_000_000)
        let recorded = Date(timeIntervalSince1970: 1_700_000_001)

        let model = AuditTrailModel(
            id: id,
            outbox_message_id: UUID(),
            aggregate_type: "Patient",
            aggregate_id: aggregateId,
            event_type: "HousingConditionUpdatedEvent",
            actor_id: "actor-42",
            payload: "{\"test\":true}",
            occurred_at: occurred,
            recorded_at: recorded
        )

        let response = AuditTrailEntryResponse(from: model)

        #expect(response.id == id.uuidString)
        #expect(response.aggregateId == aggregateId.uuidString)
        #expect(response.eventType == "HousingConditionUpdatedEvent")
        #expect(response.actorId == "actor-42")
        #expect(response.occurredAt == occurred)
        #expect(response.recordedAt == recorded)
    }

    @Test("AuditTrailEntryResponse deve suportar actor_id nil")
    func auditTrailEntryResponseNilActorId() {
        let model = AuditTrailModel(
            id: UUID(),
            outbox_message_id: UUID(),
            aggregate_type: "Patient",
            aggregate_id: UUID(),
            event_type: "PatientCreatedEvent",
            actor_id: nil,
            payload: "{}",
            occurred_at: Date(),
            recorded_at: Date()
        )

        let response = AuditTrailEntryResponse(from: model)
        #expect(response.actorId == nil)
    }

    // MARK: - Round-trip: Evento -> Outbox -> Decode

    @Test("Round-trip: evento codificado no outbox deve ser decodificavel pelo registry")
    func roundTripOutboxToRegistry() async throws {
        let registry = DomainEventRegistry.shared
        await registry.bootstrap()

        let patient = try PatientFixture.createMinimal(actorId: "roundtrip-actor")
        let outboxModels = try PatientDatabaseMapper.toOutbox(patient.uncommittedEvents)

        for model in outboxModels {
            let decoded = try await registry.decode(typeName: model.event_type, data: Data(model.payload.utf8))
            #expect(decoded.id == model.id)
        }
    }

    @Test("Round-trip: multiplos tipos de evento devem ser decodificaveis")
    func roundTripMultipleEventTypes() async throws {
        let registry = DomainEventRegistry.shared
        await registry.bootstrap()

        let patient = try PatientFixture.createWithAdditionalMember()
        var mutated = patient

        try mutated.updateCommunitySupportNetwork(
            CommunitySupportNetwork(
                hasRelativeSupport: true, hasNeighborSupport: false,
                familyConflicts: "", patientParticipatesInGroups: false,
                familyParticipatesInGroups: false, patientHasAccessToLeisure: true,
                facesDiscrimination: false
            ),
            actorId: "multi-event-actor"
        )

        let outboxModels = try PatientDatabaseMapper.toOutbox(mutated.uncommittedEvents)
        #expect(outboxModels.count >= 2)

        for model in outboxModels {
            let decoded = try await registry.decode(typeName: model.event_type, data: Data(model.payload.utf8))
            #expect(decoded.id == model.id)
        }
    }
}
