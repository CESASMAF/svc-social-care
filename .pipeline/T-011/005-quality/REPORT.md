# T-011 — W3 Quality Gates

**Data:** 2026-05-14
**Achado:** S-C1 (Senior Code Review — mais grave da lista CRITICAL)

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 44.88s, 0 warnings novos |
| Full test suite | ✅ **361/361** passam, 0.084s |
| Regression suite | ✅ 57 testes em 10 suites (+4 do T-011) |
| Testes T-011 | ✅ **4/4** passam |
| ADR-011 | ✅ |
| DECISIONS.md index | próximo ID = 012 | ✅ |
| Skill `swift-io-implementer` | entrada 5 em "Lições Aprendidas" | ✅ |

## Arquivos criados

- `Tests/.../Regression/Security/PeopleContextNoFailOpenRegressionTests.swift` — **NOVO** (4 testes)
- `handbook/architecture/DECISIONS/ADR-011-*.md` — **NOVO**

## Arquivos modificados

**Domain port:**
- `Application/Registry/RegisterPatient/Services/PersonExistenceValidating.swift` — porta refatorada: enum `PersonExistence` tri-state + método `validate(personId:bearer:) async` (não-throws)

**IO adapter:**
- `IO/PeopleContext/PeopleContextPersonValidator.swift` — fail-secure + Bearer forwarding + URLComponents + log sanitizado

**Application:**
- `Application/Registry/RegisterPatient/Command/RegisterPatientCommand.swift` — campo `bearer: String?` adicionado
- `Application/Registry/RegisterPatient/Services/RegisterPatientCommandHandler.swift` — switch sobre tri-state, lança `personValidationUnavailable` em `.unknown`
- `Application/Registry/RegisterPatient/Error/RegisterPatientError.swift` — novo case `personValidationUnavailable(reason:)` → HTTP 503

**HTTP layer:**
- `IO/HTTP/DTOs/RequestDTOs.swift` — `RegisterPatientRequest.toCommand(actorId:bearer:)`
- `IO/HTTP/Controllers/PatientController.swift` — extrai `req.headers.bearerAuthorization?.token` e passa para o Command

**Handbook + skill:**
- `handbook/architecture/DECISIONS.md` — ADR-011 indexado; próximo ID = **012**
- `.claude/skills/swift-io-implementer/SKILL.md` — entrada 5 em "Lições Aprendidas"

## Comportamentos antes e depois

| Cenário | Pré-ADR-011 | Pós-ADR-011 |
|---|---|---|
| People-context responde 200 | OK, prossegue | OK, prossegue (`.exists`) |
| People-context responde 404 | erro `personIdNotFoundInPeopleContext` (422) | erro `personIdNotFoundInPeopleContext` (422) |
| People-context responde 500 | **fail-open, registra paciente** ⚠️ | erro `personValidationUnavailable` (503) ✅ |
| People-context responde 401 | **fail-open, registra paciente** ⚠️ | erro `personValidationUnavailable` (503) ✅ |
| Timeout | **fail-open, registra paciente** ⚠️ | erro `personValidationUnavailable` (503) ✅ |
| DNS falha | **fail-open, registra paciente** ⚠️ | erro `personValidationUnavailable` (503) ✅ |
| Bearer não encaminhado | sempre | encaminhado quando presente no Command |

## Cumulativo da pipeline

| Ticket | Achados | ADR | Testes regressão |
|---|---|---|---|
| T-001 | Foundations | ADR-002 | 5 |
| T-002 | Estrutura ADR | ADR-003 | meta |
| T-004 | S-C7 | ADR-004 | 2 |
| T-005 | S-C3 + DB-2 | ADR-005 | 4 |
| T-006 | DB-1 | ADR-006 | 4 |
| T-007 | DB-4 + S-H-D5 | ADR-007 | 5 |
| T-008 | DB-3 | ADR-008 | 8 |
| T-009 | DB-8 | ADR-009 | 6 |
| T-010 | S-C6 | ADR-010 | 3 + lint |
| T-011 | S-C1 (mais grave) | ADR-011 | 4 |
| **Total** | **10 fechados** | **11 ADRs** | **41 regression tests** |

## Próximos tickets sugeridos

- **T-014** — Security headers + body size limit (S-C5, CRITICAL) — pequeno escopo, alto impacto.
- **T-012** — Outbox `FOR UPDATE SKIP LOCKED` (S-C2, CRITICAL) — toca Outbox relay.
- **T-013** — Remover `OutboxEventBus.publish` dead code (S-C4, CRITICAL).
