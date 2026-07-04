# Regression / EventPublication

Previne falhas no contrato **Transactional Outbox** e na propagação de eventos.

## Classe de bugs prevenidos

- **Evento publicado antes do save** — race com falha de persistência deixa downstream sabendo de algo que não persistiu.
- **`recordEvent` no-op silencioso** — agregado conforma protocolo errado e evento some sem erro.
- **Outbox duplica** — mesmo evento publicado N vezes pelo relay.
- **Audit trail corrompido** — PK colide, batch inteiro aborta.
- **Aggregate type confundido** — query por UUID vaza eventos de outro agregado.

## Tickets que adicionam testes aqui

| Ticket | Teste | Achado |
|---|---|---|
| T-004 | `RecordEventSilentNoopTest` | S-C7 |
| T-012 | `OutboxNoDuplicationTest` | S-C2 |
| T-013 | `RepositoryPersistsEventsWithAggregateTest` | S-C4 |
| T-015 | `AuditTrailDeduplicatesTest` | S-C10 |
| T-016 | `EventCarriesAggregateMetadataTest` | S-M-P10 + S-H-IO4 |
| T-017 | `NATSPublisherSurvivesPingTest` | S-C9 |

## Invariantes garantidos

1. `repository.save(agg)` persiste agregado **E** `agg.uncommittedEvents` na mesma transação. Falha do save = nenhum evento publicado.
2. `agg.recordEvent(e)` NUNCA é no-op silencioso — protocolo composto garante storage.
3. Relay multi-instância nunca emite o mesmo evento duas vezes (via `FOR UPDATE SKIP LOCKED` + `Nats-Msg-Id`).
4. `audit_trail.id` é independente de `outbox_messages.id` — reprocesso não mata batch.
5. Cada `DomainEvent` carrega `aggregateType` + `aggregateId` por contrato (não hardcoded no relay).

## Padrão típico

```swift
@Test("S-C4 — save persists events in same transaction")
func test_S_C4_save_persists_events_in_same_transaction() async throws {
    let fixture = RegressionFixture.default
    var patient = try PatientFixture.registered()
    patient.recordEvent(PatientRegisteredEvent.fixture)
    try await fixture.repo.save(patient)

    let outboxCount = try await fixture.db.raw("""
        SELECT COUNT(*) FROM outbox_messages WHERE aggregate_id = \(bind: patient.id)
    """).first().decode(...)
    #expect(outboxCount == 1)
}
```
