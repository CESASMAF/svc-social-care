# Casos de Teste — Assessment (avaliações sociais)

Sete endpoints `PUT /api/v1/patients/:patientId/...`, todos role `worker`. As regras críticas aqui são as **validações cruzadas** (`CrossValidator`) e as **validações por metadado de lookup** (`MetadataValidator`) — é onde o frontend mais precisa de feedback claro de formulário.

## Funcionalidade: Condição habitacional — `PUT .../housing-condition`

```gherkin
Funcionalidade: Atualizar condição habitacional
  Contexto:
    Dado um token JWT com role "worker" e um paciente ACTIVE

  Cenário: HAB-001 Atualização completa
    Quando envio PUT .../housing-condition com todos os campos obrigatórios
      (type, wallMaterial, numberOfRooms, numberOfBedrooms, numberOfBathrooms,
       waterSupply, hasPipedWater, electricityAccess, sewageDisposal, wasteCollection,
       accessibilityLevel, isInGeographicRiskArea, hasDifficultAccess,
       isInSocialConflictArea, hasDiagnosticObservations)
    Então recebo 2xx
    E o GET do paciente devolve housingCondition preenchido
    E computedAnalytics.housing.density é recalculada (membros ÷ cômodos)
    E computedAnalytics.housing.isOvercrowded reflete a densidade

  Cenário: HAB-002 Campo obrigatório ausente
    Quando envio PUT .../housing-condition sem numberOfRooms
    Então recebo 400 (falha de decodificação do DTO), não 500

  Cenário: HAB-003 Paciente inexistente
    Quando envio PUT em /api/v1/patients/{uuid aleatório}/housing-condition
    Então recebo 404 Not Found
```

## Funcionalidade: Situação socioeconômica — `PUT .../socioeconomic-situation`

A tabela `dominio_tipo_beneficio` carrega flags de metadado que mudam os campos obrigatórios do formulário (validadas pelo `MetadataValidator`):

```gherkin
Funcionalidade: Atualizar situação socioeconômica
  Contexto:
    Dado um token JWT com role "worker" e um paciente ACTIVE
    E a tabela dominio_tipo_beneficio contém:
      | codigo          | exige_registro_nascimento | exige_cpf_falecido |
      | BPC             | false                     | false              |
      | SALARIO_MATERN  | true                      | false              |
      | PENSAO_MORTE    | false                     | true               |

  Cenário: SOC-001 Benefício simples
    Quando envio PUT .../socioeconomic-situation com socialBenefits contendo
      benefitTypeId de BPC, amount e beneficiaryId
    Então recebo 2xx

  Cenário: SOC-002 Benefício que exige certidão de nascimento
    Quando envio benefício com benefitTypeId de SALARIO_MATERN
      e birthCertificateNumber vazio
    Então recebo 422 com mensagem citando o campo exigido

  Cenário: SOC-003 Benefício que exige CPF do falecido
    Quando envio benefício com benefitTypeId de PENSAO_MORTE e deceasedCpf ausente
    Então recebo 422

  Cenário: SOC-004 benefitTypeId inexistente na lookup
    Quando envio benefício com benefitTypeId aleatório (UUID não cadastrado)
    Então recebo 4xx de consistência de dados (categoria DATA_CONSISTENCY_INCIDENT)
```

## Funcionalidade: Saúde — `PUT .../health-status` (validação cruzada gravidez × sexo)

```gherkin
Funcionalidade: Atualizar status de saúde
  Contexto:
    Dado um token JWT com role "worker"
    E um paciente com membro M1 (sex "masculino") e M2 (sex "feminino") na família

  Cenário: SAU-001 Gestação registrada para membro feminino
    Quando envio PUT .../health-status com gestatingMembers contendo
      { memberId: M2, monthsGestation: 5, startedPrenatalCare: true }
    Então recebo 2xx

  Cenário: SAU-002 Gestação para membro masculino é rejeitada (CrossValidator)
    Quando envio gestatingMembers contendo memberId M1
    Então recebo 422 com mensagem indicando incompatibilidade com sex "masculino"

  Esquema do Cenário: SAU-003 Meses de gestação fora do range
    Quando envio gestatingMembers com monthsGestation <meses>
    Então recebo <resultado>
    Exemplos:
      | meses | resultado |
      | 0     | 2xx       |
      | 9     | 2xx       |
      | 10    | 422       |
      | -1    | 422       |

  Cenário: SAU-004 Deficiência com cuidador
    Quando envio deficiencies com deficiencyTypeId (dominio_tipo_deficiencia),
      needsConstantCare true e responsibleCaregiverName preenchido
    Então recebo 2xx e o GET reflete healthStatus
```

## Funcionalidade: Demais avaliações

```gherkin
Funcionalidade: Trabalho e renda, educação, rede de apoio, resumo social de saúde
  Contexto:
    Dado um token JWT com role "worker" e um paciente ACTIVE com 2 membros

  Cenário: TRA-001 Trabalho e renda alimenta analytics financeiras
    Quando envio PUT .../work-and-income com individualIncomes
      (memberId, occupationId de dominio_condicao_ocupacao, hasWorkCard, monthlyAmount)
    Então recebo 2xx
    E computedAnalytics.financial.totalWorkIncome soma os monthlyAmount
    E perCapitaWorkIncome = total ÷ (paciente + membros)

  Cenário: EDU-001 Perfil educacional alimenta vulnerabilidades
    Dado um membro de 8 anos
    Quando envio PUT .../educational-status com memberProfiles
      ({ memberId, canReadWrite: false, attendsSchool: false, educationLevelId })
    Então recebo 2xx
    E computedAnalytics.educationalVulnerabilities.notInSchool6to14 ≥ 1

  Cenário: RED-001 Rede de apoio comunitário
    Quando envio PUT .../community-support-network com os 7 campos booleanos/string
    Então recebo 2xx e o GET reflete communitySupportNetwork

  Cenário: RES-001 Resumo social de saúde
    Quando envio PUT .../social-health-summary com requiresConstantCare,
      hasMobilityImpairment, functionalDependencies e hasRelevantDrugTherapy
    Então recebo 2xx e o GET reflete socialHealthSummary

  Cenário: ASS-401 Sem token
    Quando envio qualquer PUT de assessment sem header Authorization
    Então recebo 401 Unauthorized

  Cenário: ASS-403 Role insuficiente
    Dado um token com roles vazias
    Quando envio qualquer PUT de assessment
    Então recebo 403 Forbidden
```

## Observação para o frontend

As flags `exigeRegistroNascimento`, `exigeCpfFalecido` e `exigeDescricao` vêm nos itens das tabelas de domínio. O formulário deve **ler essas flags ao montar o select** e tornar os campos condicionais obrigatórios no cliente — o backend rejeitará com 422 de qualquer forma (defesa em profundidade), mas a UX correta valida antes do submit. Ver `05-fluxo-frontend.md`, seção 4.
