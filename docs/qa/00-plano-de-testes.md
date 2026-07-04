# Plano de Testes — social-care

> Persona: especialista de QA (ACDG Agent Skills). Metodologia ancorada nos livros canônicos de `skills_base/shared-references/tdd/` e `requirements/`.

## 1. Fundamentação canônica

### 1.1 Pirâmide de testes

> "If you want to get serious about automated tests for your software there
> is one key concept you should know about: the **test pyramid**. Mike
> Cohn came up with this concept in his book *Succeeding with Agile*.
> It's a great visual metaphor telling you to think about different layers
> of testing. It also tells you how much testing to do on each layer."
> — *(Linha 67, p. ?, Ham Vocke, *The Practical Test Pyramid (martinfowler.com)*)*

Aplicação ao social-care:

| Camada | O que já existe | O que este plano adiciona |
|---|---|---|
| **Unidade** (base, maior volume) | `Tests/Domain/v2/` (16 arquivos: VOs, analytics) + `Tests/Application/` (20 arquivos, 17 use cases) com gate de 95% no CI | Nada a adicionar — base sólida; manter o gate |
| **Integração/Serviço** (meio) | `Tests/IO/` (audit trail) | Casos de API documentados nos arquivos `01`–`04` (Gherkin), executáveis contra o serviço rodando com Postgres do `docker-compose` |
| **E2E/UI** (topo, menor volume) | — (frontend ainda será construído) | Fluxos de jornada do documento `05-fluxo-frontend.md`, que devem virar os poucos testes E2E do app Flutter |

A consequência prática da pirâmide para este projeto: **não** replicar no E2E as validações já cobertas por unidade (dígito verificador de CPF, analytics de família etc.). O E2E cobre jornadas (login → cadastrar → avaliar → consultar prontuário); a API cobre contratos e regras inter-campo; a unidade cobre regra de domínio.

### 1.2 Quadrantes ágeis (o que testar além do funcional)

> "The agile testing quadrants model helps teams think through test-
> ing activities that are needed to give confidence to the product they
> are building. It also helps to build a common testing language with
> the team and with the organization if used to help communicate
> across teams. Janet's favorite thing about this model is that it not
> only represents a holistic view into testing but also makes the whole"
> — *(Linha 1693, p. ?, Janet Gregory, Lisa Crispin, *Agile Testing Condensed*)*

Mapeamento dos quadrantes para o social-care:

| Quadrante | Atividade neste projeto |
|---|---|
| Q1 — tecnologia, suporte ao time | Testes de unidade/integração existentes (swift-testing, 95% gate) |
| Q2 — negócio, suporte ao time | Os cenários Gherkin dos arquivos `01`–`04` deste diretório — escritos ANTES do frontend existir, servem de critério de aceite para as telas |
| Q3 — negócio, crítica ao produto | Testes exploratórios (seção 3) e validação com as assistentes sociais da ACDG usando dados realistas |
| Q4 — tecnologia, crítica ao produto | Segurança (RBAC — arquivo `04`), limites (body 256 KB, paginação `limit` 1–100), resiliência (people-context fora → 503) |

### 1.3 Testes exploratórios

> "Include Exploratory Testing in your testing portfolio. It is a manual testing approach that emphasises the tester's freedom and creativity to spot quality issues in a running system. Simply take some time on a regular schedule, roll up your sleeves and try to break your application. Use a destructive mindset and come up with ways to provoke issues and errors in your application. Document everything you find for later. Watch out for bugs, design issues, slow response times, missing or misleading error messages and everything else that would annoy you as a user of your software."
> — *(Linha 957, p. ?, Ham Vocke, *The Practical Test Pyramid (martinfowler.com)*)*

Sessões exploratórias sugeridas (charters de ~60 min cada, registrar achados em issue):

1. **Charter "cadastro hostil"** — cadastrar pacientes com nomes com emoji/surrogates, CPFs limítrofes, datas 29/02, CEPs de fronteira de faixa de UF.
2. **Charter "estado impossível"** — tentar discharge de paciente já DISCHARGED, readmit de ACTIVE, withdraw de ADMITTED; observar se os 409 fazem sentido para o usuário.
3. **Charter "concorrência"** — duas sessões editando o mesmo paciente (campo `version` no `PatientResponse`); verificar comportamento de conflito.
4. **Charter "mensagens de erro"** — provocar cada família de erro (CPF-*, REGP-*, LKP-*) e avaliar se `error.message` é acionável para a assistente social, não só para o dev.

## 2. Escopo e ambientes

- **Sob teste**: API HTTP do `social-care` (34 endpoints, 6 controllers) atrás de JWT OIDC.
- **Ambiente local**: `docker compose up postgres -d` + `make dev` (porta 3000). Tokens de teste emitidos pelo Authentik/Zitadel de DEV.
- **Dependência externa**: `people-context` (validação de `personId`). Em ambiente isolado, simular indisponibilidade para os casos 503 (`REGP-031`).
- **Fora de escopo deste plano**: testes de carga e de migração de dados.

## 3. Dados de teste

| Massa | Valor |
|---|---|
| CPF válido | gerar com dígito verificador correto (mod 11) |
| CPF inválido (checksum) | `123.456.789-00` → `CPF-004` |
| CPF inválido (repetido) | `111.111.111-11` → `CPF-003` |
| NIS | 11 dígitos (sem checksum) |
| CEP válido | dentro da faixa da UF declarada no endereço |
| CEP fora de faixa | CEP de SP com `state: "CE"` → `CEP-004` |
| Datas | diagnóstico com data futura deve ser rejeitado |
| JWT | três tokens: `worker`, `admin`, sem role; + um expirado |

## 4. Critérios de saída

- 100% dos cenários dos arquivos `01`–`04` executados e com veredito.
- Zero falha aberta de severidade alta nas categorias `SECURITY_BOUNDARY_VIOLATION` e `DATA_CONSISTENCY_INCIDENT`.
- Matriz RBAC (arquivo `04`) integralmente verificada — cada endpoint × cada role.
- Sessões exploratórias 1–4 realizadas com achados registrados.
