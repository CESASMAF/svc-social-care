# T-010 — W3 Quality Gates

**Data:** 2026-05-14
**Achado:** S-C6 (Senior Code Review — apenas 1/21 handlers mapeava PersistenceConflictError)

## Gates

| Gate | Resultado |
|---|---|
| Build debug | ✅ exit 0 |
| Build release | ✅ exit 0, 40.99s, 0 warnings novos |
| Full test suite | ✅ **357/357** passam, 0.104s |
| Regression suite | ✅ 53 testes em 9 suites (+3 do T-010) |
| Testes T-010 | ✅ **3/3** passam |
| ADR-010 | ✅ |
| DECISIONS.md index | próximo ID = 011 | ✅ |
| Skill `swift-application-orchestrator` | seção "Padrão mapError" + Lições Aprendidas (entrada 1) | ✅ |

## Arquivos criados

- `Sources/.../shared/Error/PersistenceConflictMapping.swift` — **NOVO** (helper genérico)
- `Tests/.../Regression/ErrorMapping/UniqueViolationMappingRegressionTests.swift` — **NOVO** (3 testes: helper runtime, optimistic lock helper, lint estrutural)
- `handbook/architecture/DECISIONS/ADR-010-universal-persistence-conflict-mapping.md` — **NOVO**

## Arquivos modificados (18 handlers)

Todos os 18 handlers que faltavam ganharam bloco padronizado `if let conflict = error as? PersistenceConflictError`. RegisterPatient já tinha tratamento específico (preservado).

**Padrão genérico (16 handlers `-> XError`):**
- `RegisterIntakeInfoMapperError.swift`
- `RegisterAppointmentMapperError.swift`
- `UpdateHealthStatusMapperError.swift`
- `UpdateEducationalStatusMapperError.swift`
- `UpdateHousingConditionMapperError.swift`
- `UpdateWorkAndIncomeMapperError.swift`
- `UpdateSocioEconomicSituationMapperError.swift`
- `UpdatePlacementHistoryMapperError.swift`
- `ReportRightsViolationMapperError.swift`
- `CreateReferralMapperError.swift`
- `RemoveFamilyMemberMapperError.swift`
- `UpdateSocialIdentityMapperError.swift`
- `AssignPrimaryCaregiverMapperError.swift`

**Padrão lifecycle (4 handlers `-> any Error`):**
- `DischargePatientMapperError.swift`
- `WithdrawFromWaitlistMapperError.swift`
- `AdmitPatientMapperError.swift`
- `ReadmitPatientMapperError.swift`

**Mapping específico (1 handler):**
- `AddFamilyMemberMapperError.swift` — `family_members_pkey` (PK composta de ADR-006) → `memberAlreadyExists`

**Outros:**
- `handbook/architecture/DECISIONS.md` — ADR-010 indexado; próximo ID = **011**
- `.claude/skills/swift-application-orchestrator/SKILL.md` — nova seção "Padrão mapError" + Lições Aprendidas

## Decisões arquiteturais

1. **Helper extension** em `PersistenceConflictError` — `mapUniqueViolation<E: Error>` recebe closure que retorna erro de negócio ou nil. Idiomático Swift.
2. **`mapOptimisticLockFailed` companheiro** — para ADR-005, mesmo padrão.
3. **Handlers lifecycle propagam direto** — `if error is PersistenceConflictError { return error }`. Controller/middleware lida.
4. **Lint test estrutural** — percorre `*MapperError.swift`, exige menção a `PersistenceConflictError`. Próximo handler novo é bloqueado em CI se esquecer.
5. **Mapping específico evolui incrementalmente** — só AddFamilyMember tem mapping de `family_members_pkey` agora; outros handlers ganham mapping específico conforme features pedirem.

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
| T-010 | S-C6 | ADR-010 | 3 (+ lint) |
| **Total** | **9 fechados** | **10 ADRs** | **37 regression tests** |

## Próximos tickets sugeridos

Da Fase 2 (Segurança crítica):
- **T-011** — PeopleContext tri-state + Bearer forwarding (S-C1, CRITICAL).
- **T-014** — Security headers + body size limit (S-C5, CRITICAL).

Da Fase 3 (Outbox/Eventos):
- **T-012** — Outbox FOR UPDATE SKIP LOCKED (S-C2, CRITICAL).
- **T-013** — Remover OutboxEventBus dead code (S-C4, CRITICAL).
