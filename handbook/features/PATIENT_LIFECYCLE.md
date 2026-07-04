# Patient Lifecycle — Ciclo de Vida do Paciente

> Bounded Context: **Registry** | Agregado: **Patient** | Versao: PRs #8, #9, #10, #11

---

## Maquina de Estados

```
                     ┌──────────────┐
  RegisterPatient    │              │
  ─────────────────► │  waitlisted  │
                     │              │
                     └──┬────────┬──┘
                        │        │
                  admit │        │ withdraw
                        ▼        ▼
                  ┌──────────┐  ┌───────────┐
                  │  active   │  │ withdrawn │
                  └─────┬────┘  └───────────┘
                        │
              discharge │
                        ▼
                  ┌────────────┐
                  │ discharged │
                  └──────┬─────┘
                         │
                 readmit │
                         ▼
                  ┌──────────┐
                  │  active   │
                  └──────────┘
```

### Regras de transicao

| De | Para | Operacao | Restricao |
|---|---|---|---|
| `waitlisted` | `active` | admit | — |
| `waitlisted` | `withdrawn` | withdraw | reason obrigatorio |
| `active` | `discharged` | discharge | reason obrigatorio |
| `discharged` | `active` | readmit | — |

### Transicoes proibidas (com orientacao)

| Tentativa | Erro | Orientacao |
|---|---|---|
| discharge em `waitlisted` | DISC-007 (409) | Use **withdraw** |
| readmit em `waitlisted` | READM-005 (409) | Use **admit** |
| admit em `discharged` | ADM-003 (409) | Use **readmit** |
| withdraw em `active` | WDR-003 (409) | Use **discharge** |

---

## Endpoints

Base: `POST /api/v1/patients/:patientId/<acao>`

Todos os endpoints exigem:
- **JWT** com role `social_worker` ou `admin`
- **Header** `X-Actor-Id` (registrado no audit trail)

### POST /admit

Admite paciente da lista de espera.

**Request body:** nenhum

**Response:** `204 No Content`

**Erros:**

| Codigo | Kind | HTTP | Descricao |
|---|---|---|---|
| ADM-001 | PatientNotFound | 404 | Paciente nao encontrado |
| ADM-002 | AlreadyActive | 409 | Paciente ja esta ativo |
| ADM-003 | CannotAdmitDischarged | 409 | Use readmit para pacientes desligados |
| ADM-004 | InvalidPatientIdFormat | 400 | Formato de ID invalido |

---

### POST /withdraw

Retira paciente da lista de espera.

**Request body:**
```json
{
  "reason": "string (obrigatorio)",
  "notes": "string | null (obrigatorio quando reason = 'other', max 1000 chars)"
}
```

**Valores de `reason`:**
`patientDeclined`, `noResponse`, `duplicateRecord`, `ineligible`, `transferredBeforeAdmit`, `other`

**Response:** `204 No Content`

**Erros:**

| Codigo | Kind | HTTP | Descricao |
|---|---|---|---|
| WDR-001 | PatientNotFound | 404 | Paciente nao encontrado |
| WDR-002 | AlreadyDischarged | 409 | Paciente ja esta desligado |
| WDR-003 | PatientIsActive | 409 | Use discharge para pacientes ativos |
| WDR-004 | InvalidReason | 400 | Reason nao reconhecido |
| WDR-005 | NotesRequiredForOtherReason | 400 | Notes obrigatorio quando reason = other |
| WDR-006 | NotesExceedMaxLength | 400 | Notes excede 1000 caracteres |
| WDR-007 | InvalidPatientIdFormat | 400 | Formato de ID invalido |

---

### POST /discharge

Desliga paciente ativo do servico.

**Request body:**
```json
{
  "reason": "string (obrigatorio)",
  "notes": "string | null (obrigatorio quando reason = 'other', max 1000 chars)"
}
```

**Valores de `reason`:**
`caseObjectiveAchieved`, `transferredToAnotherService`, `patientRequestedDischarge`, `lossOfContact`, `relocation`, `death`, `other`

**Response:** `204 No Content`

**Erros:**

| Codigo | Kind | HTTP | Descricao |
|---|---|---|---|
| DISC-001 | AlreadyDischarged | 409 | Paciente ja esta desligado |
| DISC-002 | InvalidReason | 400 | Reason nao reconhecido |
| DISC-003 | NotesRequiredForOtherReason | 400 | Notes obrigatorio quando reason = other |
| DISC-004 | PatientNotFound | 404 | Paciente nao encontrado |
| DISC-005 | NotesExceedMaxLength | 400 | Notes excede 1000 caracteres |
| DISC-006 | InvalidPatientIdFormat | 400 | Formato de ID invalido |
| DISC-007 | CannotDischargeWaitlisted | 409 | Use withdraw para pacientes em lista de espera |

---

### POST /readmit

Readmite paciente previamente desligado.

**Request body:**
```json
{
  "notes": "string | null (max 1000 chars)"
}
```

**Response:** `204 No Content`

**Erros:**

| Codigo | Kind | HTTP | Descricao |
|---|---|---|---|
| READM-001 | AlreadyActive | 409 | Paciente ja esta ativo |
| READM-002 | PatientNotFound | 404 | Paciente nao encontrado |
| READM-003 | InvalidPatientIdFormat | 400 | Formato de ID invalido |
| READM-004 | NotesExceedMaxLength | 400 | Notes excede 1000 caracteres |
| READM-005 | CannotReadmitWaitlisted | 409 | Use admit para pacientes em lista de espera |

---

## Formato de Resposta de Erro

Todos os erros seguem o `StandardResponse`:

```json
{
  "error": {
    "code": "DISC-004",
    "message": "Paciente nao encontrado.",
    "kind": "PatientNotFound"
  },
  "meta": {
    "timestamp": "2026-04-13T12:00:00Z"
  }
}
```

O `patientId` nunca aparece no corpo da resposta de erro — e armazenado em `safeContext` para observabilidade interna.

---

## Response DTOs (consulta de paciente)

Ao consultar um paciente via GET, o `PatientResponse` inclui:

```json
{
  "status": "waitlisted | active | discharged",
  "dischargeInfo": {
    "reason": "caseObjectiveAchieved",
    "notes": "Texto opcional",
    "dischargedAt": "2026-04-13T12:00:00Z",
    "dischargedBy": "actor-uuid"
  },
  "withdrawInfo": {
    "reason": "patientDeclined",
    "notes": "Texto opcional",
    "withdrawnAt": "2026-04-13T12:00:00Z",
    "withdrawnBy": "actor-uuid"
  }
}
```

- `dischargeInfo` presente apenas quando `status = discharged`
- `withdrawInfo` presente apenas quando paciente foi retirado da fila

---

## Migrations

| Migration | Descricao |
|---|---|
| `2026_04_12_AddPatientDischarge` | Adiciona colunas `status`, `discharge_reason`, `discharge_notes`, `discharged_at`, `discharged_by` + indice `idx_patients_status` |
| `2026_04_12_AddWaitlistSupport` | Altera default de status para `waitlisted`, adiciona `withdraw_reason`, `withdraw_notes`, `withdrawn_at`, `withdrawn_by` |

---

## Seguranca

- **PII protegido:** `patientId` vai para `safeContext`, nunca exposto em respostas de erro ou logs
- **Autenticacao:** JWT via Zitadel OIDC obrigatorio
- **Autorizacao:** Role guard (`social_worker` ou `admin`)
- **Audit trail:** `actorId` registrado em cada transicao de estado (`dischargedBy`, `withdrawnBy`)
- **Eventos de dominio:** publicados via Transactional Outbox apos persistencia

---

## Arquivos Relevantes

| Camada | Arquivo |
|---|---|
| Controller | `IO/HTTP/Controllers/PatientController.swift` |
| DTOs Request | `IO/HTTP/DTOs/RequestDTOs.swift` |
| DTOs Response | `IO/HTTP/DTOs/ResponseDTOs.swift` |
| Use Cases | `Application/Registry/{AdmitPatient,DischargePatient,ReadmitPatient,WithdrawFromWaitlist}/` |
| Domain VOs | `Domain/Registry/ValueObjects/{DischargeInfo,DischargeReason,WithdrawInfo,WithdrawReason}.swift` |
| Migrations | `IO/Persistence/SQLKit/Migrations/2026_04_12_*.swift` |
| Testes | `Tests/.../Application/{DischargePatient,ReadmitPatient,AdmitPatient,WithdrawFromWaitlist}*.swift` |
