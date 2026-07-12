# Casos de Teste — Registry (cadastro e ciclo de vida do paciente)

> Convenção Gherkin deste documento, conforme a referência canônica:
>
> "`Given` steps are used to describe the initial context of the system - the *scene* of the scenario.
> It is typically something that happened in the *past*.
> When Cucumber executes a `Given` step, it will configure the system to be in a well-defined state,
> such as creating and configuring objects or adding data to a test database."
> — *(Linha 319, p. ?, Cucumber (SmartBear), *Gherkin Reference*)*
>
> Todo `Dado` abaixo descreve estado pré-existente (token emitido, paciente já cadastrado); todo `Quando` é a chamada HTTP; todo `Então` é asserção sobre status + corpo.

## Funcionalidade: Cadastrar paciente — `POST /api/v1/patients` (role: `worker`)

```gherkin
Funcionalidade: Cadastro de paciente
  Contexto:
    Dado um token JWT válido com role "worker"
    E o serviço people-context disponível

  Cenário: REG-001 Cadastro mínimo com sucesso
    Dado um personId existente no people-context
    Quando envio POST /api/v1/patients com personId, prRelationshipId
      e initialDiagnoses contendo 1 diagnóstico com icdCode, date passada e description
    Então recebo 201 Created
    E o corpo segue StandardResponse com data.patientId (UUID) e meta.timestamp

  Cenário: REG-002 Cadastro completo (dados pessoais, documentos, endereço, identidade social)
    Quando envio POST /api/v1/patients com personalData (sex "feminino"),
      civilDocuments (cpf válido, nis 11 dígitos, rgDocument, cns com cpf coincidente),
      address (cep coerente com state, isShelter false, residenceLocation "URBAN")
      e socialIdentity (typeId de dominio_tipo_identidade)
    Então recebo 201 Created
    E GET /api/v1/patients/{patientId} devolve cpf formatado "XXX.XXX.XXX-XX"
      e cep formatado "XXXXX-XXX"

  Esquema do Cenário: REG-003 CPF inválido é rejeitado
    Quando envio POST /api/v1/patients com civilDocuments.cpf "<cpf>"
    Então recebo 422 e error.code "<codigo>"
    Exemplos:
      | cpf            | codigo  |
      | 11111111111    | CPF-003 |
      | 12345678900    | CPF-004 |
      | 123            | CPF-002 |
      | 123abc456de    | CPF-005 |

  Cenário: REG-004 CPF duplicado gera conflito
    Dado um paciente já cadastrado com o CPF X
    Quando envio POST /api/v1/patients com civilDocuments.cpf X
    Então recebo 409 Conflict e error.code "REGP-030"

  Cenário: REG-005 personId já registrado gera conflito
    Dado um paciente já cadastrado para o personId P
    Quando envio POST /api/v1/patients com personId P
    Então recebo 409 Conflict e error.code "REGP-001"

  Cenário: REG-006 Diagnóstico com data futura é rejeitado
    Quando envio POST /api/v1/patients com initialDiagnoses[0].date = amanhã
    Então recebo 422 Unprocessable Entity

  Cenário: REG-007 CNS com CPF divergente é rejeitado
    Quando envio POST com civilDocuments.cpf = A e civilDocuments.cns.cpf = B (A ≠ B)
    Então recebo 422 e error.code "REGP-028"

  Cenário: REG-008 people-context indisponível
    Dado o people-context fora do ar ou em timeout
    Quando envio POST /api/v1/patients válido
    Então recebo 503 Service Unavailable e error.code "REGP-031"
    E o frontend deve oferecer retry (ver 05-fluxo-frontend.md)

  Cenário: REG-009 CEP fora da faixa da UF
    Quando envio address.cep de São Paulo com address.state "CE"
    Então recebo 422 e error.code "CEP-004"
```

## Funcionalidade: Consulta e listagem

```gherkin
Funcionalidade: Listagem e consulta de pacientes
  Contexto:
    Dado um token JWT válido com role "worker"

  Cenário: REG-010 Listagem paginada default
    Dado 25 pacientes cadastrados
    Quando envio GET /api/v1/patients
    Então recebo 200 com no máximo 20 itens (PatientSummaryResponse)
    E meta.pageSize=20, meta.totalCount=25, meta.hasMore=true e meta.nextCursor presente

  Cenário: REG-011 Paginação por cursor
    Quando envio GET /api/v1/patients?cursor={meta.nextCursor da página anterior}
    Então recebo os 5 itens restantes e meta.hasMore=false

  Esquema do Cenário: REG-012 Limite de paginação
    Quando envio GET /api/v1/patients?limit=<limit>
    Então recebo <resultado>
    Exemplos:
      | limit | resultado                  |
      | 1     | 200 com 1 item             |
      | 100   | 200 com até 100 itens      |
      | 0     | 400 (fora do range 1-100)  |
      | 101   | 400 (fora do range 1-100)  |

  Cenário: REG-013 Filtros de busca
    Quando envio GET /api/v1/patients?search=Maria&status=ACTIVE
    Então todos os itens retornados têm status "ACTIVE" e nome contendo "Maria"

  Cenário: REG-014 Paciente inexistente
    Quando envio GET /api/v1/patients/{uuid aleatório}
    Então recebo 404 Not Found

  Cenário: REG-015 Busca por personId
    Dado um paciente cadastrado para o personId P
    Quando envio GET /api/v1/patients/by-person/P
    Então recebo 200 com o PatientResponse completo (incluindo computedAnalytics)

  Cenário: REG-016 Audit trail registra o ator
    Dado um paciente cadastrado pelo usuário cujo JWT.sub = S
    Quando envio GET /api/v1/patients/{patientId}/audit-trail
    Então recebo 200 com entradas onde actorId = S e eventType do registro
```

## Funcionalidade: Composição familiar

```gherkin
Funcionalidade: Membros da família e cuidador principal
  Contexto:
    Dado um token JWT válido com role "worker"
    E um paciente ACTIVE cadastrado

  Cenário: FAM-001 Adicionar membro
    Quando envio POST /api/v1/patients/{id}/family-members com memberPersonId,
      relationship "FILHO", isResiding, isCaregiver, hasDisability,
      requiredDocuments, birthDate e prRelationshipId
    Então recebo 2xx e o membro aparece em familyMembers no GET do paciente
    E computedAnalytics.ageProfile.totalMembers é incrementado

  Cenário: FAM-002 Remover membro
    Dado um membro M na família do paciente
    Quando envio DELETE /api/v1/patients/{id}/family-members/{M}
    Então recebo 2xx e M não aparece mais em familyMembers

  Cenário: FAM-003 Designar cuidador principal
    Dado um membro M na família do paciente
    Quando envio PUT /api/v1/patients/{id}/primary-caregiver com memberPersonId M
    Então recebo 2xx e familyMembers[M].isPrimaryCaregiver = true

  Cenário: FAM-004 Cuidador que não é membro
    Quando envio PUT /api/v1/patients/{id}/primary-caregiver
      com memberPersonId que não pertence à família
    Então recebo 4xx com erro de regra de domínio (não 500)
```

## Funcionalidade: Ciclo de vida do paciente

Estados: `ACTIVE` | `DISCHARGED` | `WITHDRAWN` | `WAITLISTED` | `ADMITTED`. Roles: `worker` e `admin`.

```gherkin
Funcionalidade: Transições de estado
  Contexto:
    Dado um token JWT válido com role "worker"

  Cenário: LIF-001 Desligamento (discharge)
    Dado um paciente ACTIVE
    Quando envio POST /api/v1/patients/{id}/discharge com reason "Mudança de município"
    Então recebo 2xx
    E o GET devolve status "DISCHARGED" e dischargeInfo com reason, dischargedAt
      e dischargedBy igual ao JWT.sub do solicitante

  Cenário: LIF-002 Readmissão
    Dado um paciente DISCHARGED
    Quando envio POST /api/v1/patients/{id}/readmit
    Então recebo 2xx e o status volta a "ACTIVE"

  Cenário: LIF-003 Discharge duplo é conflito
    Dado um paciente DISCHARGED
    Quando envio POST /api/v1/patients/{id}/discharge novamente
    Então recebo 409 Conflict (não 500)

  Cenário: LIF-004 Withdraw exige reason
    Dado um paciente WAITLISTED
    Quando envio POST /api/v1/patients/{id}/withdraw sem reason
    Então recebo 400/422 indicando campo obrigatório

  Cenário: LIF-005 Admit a partir da fila
    Dado um paciente WAITLISTED
    Quando envio POST /api/v1/patients/{id}/admit
    Então recebo 2xx e o status passa a "ADMITTED"
```
