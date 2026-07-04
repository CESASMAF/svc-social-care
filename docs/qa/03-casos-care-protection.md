# Casos de Teste — Care e Protection

## Funcionalidade: Atendimentos — `POST /api/v1/patients/:id/appointments` (role: `worker`)

```gherkin
Funcionalidade: Registrar atendimento socioassistencial
  Contexto:
    Dado um token JWT com role "worker" e um paciente ACTIVE

  Cenário: CAR-001 Atendimento mínimo
    Quando envio POST .../appointments com professionalId (UUID)
    Então recebo 2xx e o atendimento aparece em appointments no GET do paciente
    E date assume o instante atual quando omitida

  Cenário: CAR-002 Atendimento completo
    Quando envio POST .../appointments com professionalId, summary, actionPlan,
      type (valor de enum válido) e date ISO-8601
    Então recebo 2xx e todos os campos voltam no AppointmentResponse

  Cenário: CAR-003 professionalId malformado
    Quando envio POST .../appointments com professionalId "abc"
    Então recebo 400/422, não 500
```

## Funcionalidade: Acolhida (intake) — `PUT /api/v1/patients/:id/intake-info` (role: `worker`)

```gherkin
Funcionalidade: Registrar informações de ingresso
  Contexto:
    Dado um token JWT com role "worker" e um paciente ACTIVE

  Cenário: ACO-001 Ingresso com programas vinculados
    Quando envio PUT .../intake-info com ingressTypeId (dominio_tipo_ingresso),
      serviceReason e linkedSocialPrograms
      [{ programId: id de dominio_programa_social, observation }]
    Então recebo 2xx e o GET reflete intakeInfo

  Cenário: ACO-002 ingressTypeId não cadastrado
    Quando envio PUT .../intake-info com ingressTypeId aleatório
    Então recebo 4xx de consistência de dados

  Cenário: ACO-003 serviceReason ausente
    Quando envio PUT .../intake-info sem serviceReason
    Então recebo 400 indicando o campo obrigatório
```

## Funcionalidade: Encaminhamentos — `POST /api/v1/patients/:id/referrals` (role: `worker`)

```gherkin
Funcionalidade: Criar encaminhamento
  Contexto:
    Dado um token JWT com role "worker" e um paciente ACTIVE

  Cenário: ENC-001 Encaminhamento válido
    Quando envio POST .../referrals com referredPersonId, destinationService
      (valor de enum) e reason
    Então recebo 2xx e o encaminhamento aparece em referrals no GET

  Cenário: ENC-002 destinationService fora do enum
    Quando envio destinationService "SERVICO_INVENTADO"
    Então recebo 400/422 com mensagem listando os valores aceitos
```

## Funcionalidade: Violação de direitos — `POST /api/v1/patients/:id/violation-reports` (role: `worker`)

A tabela `dominio_tipo_violacao` carrega a flag `exige_descricao` (validada pelo `MetadataValidator`).

```gherkin
Funcionalidade: Reportar violação de direitos
  Contexto:
    Dado um token JWT com role "worker"
    E um paciente com membro V na família
    E a tabela dominio_tipo_violacao contém:
      | codigo            | exige_descricao |
      | VIOLENCIA_FISICA  | true            |
      | NEGLIGENCIA       | false           |

  Cenário: VIO-001 Violação com descrição obrigatória presente
    Quando envio POST .../violation-reports com victimId V,
      violationType "VIOLENCIA_FISICA", violationTypeId correspondente
      e descriptionOfFact preenchido
    Então recebo 2xx e o relato aparece em violationReports no GET

  Cenário: VIO-002 Violação sem descrição quando exigida
    Quando envio violationTypeId de VIOLENCIA_FISICA com descriptionOfFact vazio
    Então recebo 422

  Cenário: VIO-003 reportDate default
    Quando envio o relato sem reportDate
    Então o relato é gravado com reportDate = agora

  Cenário: VIO-004 Audit trail do relato
    Quando o relato VIO-001 é criado pelo usuário com JWT.sub = S
    Então GET .../audit-trail contém um evento de violação com actorId = S
```

## Funcionalidade: Histórico de acolhimento — `PUT /api/v1/patients/:id/placement-history` (role: `worker`)

Regras inter-campo do `CrossValidator` — as mais fáceis de o frontend errar:

```gherkin
Funcionalidade: Atualizar histórico de acolhimento institucional
  Contexto:
    Dado um token JWT com role "worker"
    E um paciente com membros: A (30 anos), B (15 anos), C (5 anos)

  Cenário: PLA-001 Registro de acolhimento válido
    Quando envio PUT .../placement-history com registries
      [{ memberId: C, startDate: 2024-01-10, endDate: 2024-06-10, reason }]
      e collectiveSituations/separationChecklist coerentes
    Então recebo 2xx

  Cenário: PLA-002 endDate anterior a startDate
    Quando envio registry com startDate 2024-06-10 e endDate 2024-01-10
    Então recebo 422

  Cenário: PLA-003 Guarda de terceiros exige menor de 18
    Dado uma família SEM membros menores de 18 anos
    Quando envio collectiveSituations.thirdPartyGuardReport preenchido
    Então recebo 422

  Cenário: PLA-004 Internação de adolescente exige membro de 12–17 anos
    Dado uma família cujos membros têm 30 e 5 anos (nenhum entre 12 e 17)
    Quando envio separationChecklist.adolescentInInternment = true
    Então recebo 422

  Cenário: PLA-005 Internação de adolescente com membro elegível
    Dado o membro B (15 anos) na família
    Quando envio separationChecklist.adolescentInInternment = true
    Então recebo 2xx
```
