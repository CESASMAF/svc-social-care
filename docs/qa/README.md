# QA — social-care

Documentação de testes do serviço `social-care`, produzida sob a persona de **especialista de QA** das ACDG Agent Skills. Toda recomendação metodológica está ancorada em citação literal dos livros canônicos de `skills_base/shared-references/` (Vocke, Gregory & Crispin, Gherkin Reference), conforme a regra inviolável do workspace de skills.

## Índice

| Documento | Conteúdo |
|---|---|
| [00-plano-de-testes.md](00-plano-de-testes.md) | Estratégia geral: pirâmide de testes aplicada ao social-care, quadrantes ágeis, testes exploratórios, ambientes e critérios de saída |
| [01-casos-registry.md](01-casos-registry.md) | Cenários Gherkin do bounded context **Registry**: cadastro de paciente, família, cuidador principal, ciclo de vida (discharge/readmit/admit/withdraw) |
| [02-casos-assessment.md](02-casos-assessment.md) | Cenários Gherkin do bounded context **Assessment**: as 7 avaliações sociais, validações cruzadas (gravidez × sexo) e validações por metadado de lookup |
| [03-casos-care-protection.md](03-casos-care-protection.md) | Cenários Gherkin de **Care** (atendimentos, acolhida) e **Protection** (encaminhamentos, violações de direitos, histórico de acolhimento) |
| [04-casos-lookup-rbac.md](04-casos-lookup-rbac.md) | Cenários de **Configuration** (tabelas de domínio, workflow de solicitações) + matriz RBAC completa e casos de segurança 401/403 |
| [05-fluxo-frontend.md](05-fluxo-frontend.md) | **Guia de integração para o frontend**: ordem de telas, contratos por endpoint, envelopes de resposta, tratamento de erros, paginação e checklist por tela |

## Como ler os cenários

Os casos de teste usam Gherkin (`Funcionalidade` / `Cenário` / `Dado` / `Quando` / `Então`). Cada cenário referencia:

- **Endpoint**: método + path real do backend (ex.: `POST /api/v1/patients`).
- **Código de erro esperado**: catálogo `AppError` (ex.: `CPF-003`, `REGP-030`, `LKP-005`).
- **Status HTTP esperado**: mapeado pelo `AppErrorMiddleware`.

Fontes de verdade no código:

- Rotas e roles: `Sources/social-care-s/IO/HTTP/Controllers/*.swift`
- DTOs: `Sources/social-care-s/IO/HTTP/DTOs/{RequestDTOs,ResponseDTOs}.swift`
- Validações cruzadas: `Sources/social-care-s/IO/HTTP/Validation/CrossValidator.swift`
- Validações por metadado: `Sources/social-care-s/IO/HTTP/Validation/MetadataValidator.swift`
- Erros: `Sources/social-care-s/shared/Error/AppError.swift` + `IO/HTTP/Middleware/AppErrorMiddleware.swift`
