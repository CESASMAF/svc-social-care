# Casos de Teste — Configuration (tabelas de domínio) e Segurança RBAC

## 1. Matriz RBAC (verificar endpoint × role)

Roles vêm do JWT (claim `roles`, fallback `groups`, fallback Zitadel `urn:zitadel:iam:org:project:roles`). `superadmin` ignora todos os guards. Chaves compostas valem: `social-care:worker` satisfaz `worker`.

| Endpoint | worker | owner | admin | sem role |
|---|---|---|---|---|
| `GET /health`, `GET /ready` | ✅ (sem JWT) | ✅ | ✅ | ✅ |
| `GET /api/v1/patients*` (todas as leituras) | ✅ | ✅ | ✅ | 403 |
| `POST /api/v1/patients` | ✅ | 403 | 403 | 403 |
| Mutações de família / identidade social / caregiver | ✅ | 403 | 403 | 403 |
| `PUT` de assessment (7 endpoints) | ✅ | 403 | 403 | 403 |
| Care (`appointments`, `intake-info`) | ✅ | 403 | 403 | 403 |
| Protection (`referrals`, `violation-reports`, `placement-history`) | ✅ | 403 | 403 | 403 |
| Lifecycle (`discharge`, `readmit`, `admit`, `withdraw`) | ✅ | 403 | ✅ | 403 |
| `GET /api/v1/dominios/:tableName` | ✅ | ✅ | ✅ | 403 |
| `POST/PUT/PATCH /api/v1/dominios/:tableName...` | 403 | 403 | ✅ | 403 |
| `GET /api/v1/dominios/requests` | ✅ (só as suas) | ✅ | ✅ (todas) | 403 |
| `POST /api/v1/dominios/requests` | ✅ | 403 | ✅ | 403 |
| `PUT .../requests/:id/approve` e `/reject` | 403 | 403 | ✅ | 403 |

```gherkin
Funcionalidade: Autenticação e autorização
  Cenário: SEC-001 Sem header Authorization
    Quando chamo qualquer endpoint /api/v1/* sem Authorization
    Então recebo 401 Unauthorized

  Esquema do Cenário: SEC-002 Tokens inválidos
    Quando chamo GET /api/v1/patients com <token>
    Então recebo 401
    Exemplos:
      | token                                  |
      | JWT expirado (exp no passado)          |
      | JWT com assinatura adulterada          |
      | JWT de issuer fora de OIDC_ISSUERS     |
      | JWT com aud fora de OIDC_AUDIENCES     |
      | string que não é JWT                   |

  Cenário: SEC-003 nbf no futuro
    Quando chamo a API com JWT cujo nbf é amanhã
    Então recebo 401

  Cenário: SEC-004 Cada célula da matriz RBAC
    Quando executo cada endpoint da matriz com cada um dos 4 tokens
    Então o status corresponde exatamente à célula (✅ = 2xx/404, demais = 403)

  Cenário: SEC-005 actorId não é forjável por header
    Quando envio POST /api/v1/patients com header customizado "X-Actor-Id: outro-usuario"
    Então o audit trail registra actorId = JWT.sub, ignorando o header (ADR-023)

  Cenário: SEC-006 Body acima do limite
    Quando envio POST com corpo > 256 KB (ADR-012)
    Então recebo 413 Payload Too Large

  Cenário: SEC-007 Headers de segurança
    Quando recebo qualquer resposta da API
    Então os security headers (SecurityHeadersMiddleware) estão presentes
```

## 2. Tabelas de domínio — `/api/v1/dominios/:tableName`

13 tabelas permitidas (`AllowedLookupTables.all`): `dominio_tipo_identidade`, `dominio_parentesco`, `dominio_condicao_ocupacao`, `dominio_escolaridade`, `dominio_efeito_condicionalidade`, `dominio_tipo_deficiencia`, `dominio_programa_social`, `dominio_tipo_ingresso`, `dominio_tipo_beneficio`, `dominio_tipo_violacao`, `dominio_servico_vinculo`, `dominio_tipo_medida`, `dominio_unidade_realizacao`.

```gherkin
Funcionalidade: CRUD de itens de domínio (admin)
  Contexto:
    Dado um token JWT com role "admin"

  Cenário: LKP-T001 Listar itens ativos
    Quando envio GET /api/v1/dominios/dominio_parentesco com token worker
    Então recebo 200 com itens { id, codigo, descricao } apenas com ativo=true,
      ordenados por codigo

  Cenário: LKP-T002 Tabela fora da allowlist
    Quando envio GET /api/v1/dominios/usuarios
    Então recebo 400 e error.code "LKP-001" (proteção contra SQL injection por tableName)

  Cenário: LKP-T003 Criar item
    Quando envio POST /api/v1/dominios/dominio_tipo_beneficio
      com codigo "AUXILIO_GAS" e descricao
    Então recebo 201 com o id criado

  Esquema do Cenário: LKP-T004 Código deve ser UPPER_SNAKE_CASE
    Quando envio POST com codigo "<codigo>"
    Então recebo <resultado>
    Exemplos:
      | codigo       | resultado            |
      | AUXILIO_GAS  | 201                  |
      | auxilio-gas  | 400 LKP-002          |
      | Auxílio Gás  | 400 LKP-002          |

  Cenário: LKP-T005 Código duplicado
    Dado o codigo "BPC" já existente na tabela
    Quando envio POST com codigo "BPC"
    Então recebo 409 e error.code "LKP-003"

  Cenário: LKP-T006 Atualizar descrição
    Quando envio PUT /api/v1/dominios/{tabela}/{itemId} com nova descricao
    Então recebo 204

  Cenário: LKP-T007 Desativar item sem referências
    Quando envio PATCH /api/v1/dominios/{tabela}/{itemId}/toggle
    Então recebo 204 e o item some do GET (que filtra ativo=true)

  Cenário: LKP-T008 Desativar item referenciado por paciente
    Dado um item de dominio_tipo_beneficio usado em um benefício de paciente
    Quando envio PATCH .../toggle
    Então recebo 409 e error.code "LKP-005"

  Cenário: LKP-T009 Item inexistente
    Quando envio PUT/PATCH com itemId aleatório
    Então recebo 404 e error.code "LKP-004"

  Cenário: LKP-T010 Flags de metadado na criação
    Quando envio POST em dominio_tipo_beneficio com exigeRegistroNascimento=true
    Então o item criado força a exigência no MetadataValidator (ver SOC-002)
```

## 3. Workflow de solicitações — `/api/v1/dominios/requests`

```gherkin
Funcionalidade: Solicitação de novo item de domínio (worker propõe, admin decide)
  Cenário: REQ-001 Worker cria solicitação
    Dado um token com role "worker"
    Quando envio POST /api/v1/dominios/requests com tableName permitida,
      codigo UPPER_SNAKE_CASE, descricao e justificativa
    Então recebo 201 e a solicitação nasce com status "PENDING"

  Cenário: REQ-002 Worker só vê as próprias solicitações
    Dado solicitações criadas por W1 e W2
    Quando W1 envia GET /api/v1/dominios/requests
    Então a resposta contém apenas as solicitações de W1

  Cenário: REQ-003 Admin vê todas e filtra por status
    Dado um token admin
    Quando envio GET /api/v1/dominios/requests?status=PENDING
    Então recebo todas as solicitações PENDING de todos os workers

  Cenário: REQ-004 Aprovação cria o item
    Dado uma solicitação PENDING para dominio_parentesco com codigo "PADRASTO"
    Quando admin envia PUT .../requests/{id}/approve
    Então recebo 204, a solicitação fica "APPROVED"
    E GET /api/v1/dominios/dominio_parentesco passa a conter "PADRASTO"

  Cenário: REQ-005 Rejeição exige reviewNote
    Quando admin envia PUT .../requests/{id}/reject sem reviewNote
    Então recebo 400
    Quando reenvia com reviewNote "Duplicado de ENTEADO"
    Então recebo 204 e a solicitação fica "REJECTED" com o note visível ao worker

  Cenário: REQ-006 Worker não aprova
    Dado um token worker
    Quando envio PUT .../requests/{id}/approve
    Então recebo 403
```
