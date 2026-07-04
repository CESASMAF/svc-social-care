# Regression / ErrorMapping

Previne erros genéricos / não-mapeados vazando para a fronteira HTTP.

## Classe de bugs prevenidos

- **`PersistenceConflictError.uniqueViolation` não mapeado** — handler retorna 500 `persistenceMappingFailure` em vez de 409 com erro de negócio.
- **`PSQLError` cru vaza** — código SQL escapa para o cliente.
- **`DecodingError` com payload PII** — log/response vaza dados pessoais.
- **`AbortError.reason` vaza estrutura interna** — `Cannot get value of type Int from "abc"` chega ao cliente.
- **Erro de adapter sem tradução** — `try` em adapter não mapeado para `AppError` antes da fronteira.
- **Prefixo de código de erro colidente** — dois bounded contexts usam `PAT-` ou ambos `APP-`.

## Tickets que adicionam testes aqui

| Ticket | Teste | Achado |
|---|---|---|
| T-010 | `UniqueViolationMappingTest` + lint `AllHandlersMapConflictTest` | S-C6 |
| T-036 | `ErrorCodePrefixesTest` | S-M-A2 |

## Lint test crucial (T-010)

O teste mais importante desta subpasta é o **lint test** que percorre todos os handlers de comando via reflection e falha se algum não chama `mapUniqueViolation`:

```swift
@Test("Lint — all command handlers map PersistenceConflictError")
func test_S_C6_all_command_handlers_map_persistence_conflict() {
    let mappers = HandlerMapperRegistry.allMappers
    for mapper in mappers {
        #expect(mapper.handlesPersistenceConflict,
                "\(mapper.handlerName) does not map PersistenceConflictError — regrede o achado S-C6")
    }
}
```

Esse lint é o **mecanismo de prevenção contínua**: novo handler escrito por humano ou IA será bloqueado em CI até cumprir o contrato.

## Padrão típico

```swift
@Test("S-C6 — AddFamilyMember maps duplicate member to business error (HTTP 409)")
func test_S_C6_addFamilyMember_maps_duplicate_to_business_error() async throws {
    let cmd = AddFamilyMemberCommand.fixture()
    try await handler.handle(cmd)  // 1ª vez OK

    await #expect(throws: AddFamilyMemberError.memberAlreadyInFamily.self) {
        try await handler.handle(cmd)  // 2ª deve mapear, não vazar genérico
    }
}
```
