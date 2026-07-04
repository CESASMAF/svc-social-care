# Regression / DataIntegrity

Previne bugs onde o **schema aceita estado inválido** que o domínio acha que rejeitou.

## Classe de bugs prevenidos

- **PK ausente** — tabela aceita duplicatas que o domínio considera "mesma entidade".
- **FK ausente** — coluna `*_id` aceita UUID órfão (sem registro alvo).
- **Tipo errado** — UUID guardado como `TEXT`, JSONB regredido para TEXT.
- **1NF violado** — array serializado em coluna escalar (e.g. `required_documents` em JSON dentro de TEXT).
- **CHECK ausente** — UF aceita "XX", status aceita string aleatória.
- **TIMESTAMP sem TZ** em coluna operacional.
- **`created_at`/`updated_at` ausente** em tabela de auditoria operacional.

## Tickets que adicionam testes aqui

| Ticket | Teste | Achado |
|---|---|---|
| T-006 | `AggregateTableHasPKTest` | DB-1 |
| T-007 | `RelationshipIdIsTypedTest` | DB-4 + S-H-D5 |
| T-008 | `LookupFKsTest` | DB-3 |
| T-020 | `RequiredDocumentsAtomicityTest` | DB-5 + S-H-A7 |
| T-022 | `JSONBQueryableTest`, `TimestampTZTest`, `DateTest` | DB-9 + DB-10 + DB-16 |
| T-023 | `TemporalAuditTest` | DB-17 |
| T-026 | `InvalidStateRejectedTest` | DB-11 |
| T-027 | `SchemaNamingTest` | DB-12 |
| T-033 | `SchemaSnapshotTest` | drift detection |

## Padrão típico

Quase todos os testes aqui fazem **assert via SQL puro** que o banco rejeita o estado inválido:

```swift
@Test("DB-1 — family_members rejects duplicate (patient_id, person_id)")
func test_DB_1_family_members_rejects_duplicate() async throws {
    let db = try await RegressionFixture.testDatabase()
    try await db.raw("INSERT INTO family_members ... VALUES (...)").run()

    await #expect(throws: PersistenceConflictError.uniqueViolation.self) {
        try await db.raw("INSERT INTO family_members ... VALUES (mesma combinação)").run()
    }
}
```

> **Por que via SQL puro:** o domínio rejeita pela API canônica, mas o banco precisa rejeitar mesmo se alguém entrar via ETL/fix manual. É o que ADR-009 chama de "integridade declarada vale para todas as vias de acesso".
