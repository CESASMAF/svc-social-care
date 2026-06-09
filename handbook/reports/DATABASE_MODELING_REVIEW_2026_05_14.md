# Revisão Teórica de Modelagem de Banco — `social-care` (2026-05-14)

> **Tipo:** Snapshot de sessão / Code review focado em schema relacional.
> **Skills ativas (acdg-skills MCP, lidas do disco):** `database-tutor`,
> `database-theorist`, `database-engineer`.
> **Referência canônica:** Ramakrishnan & Gehrke, *Database Management Systems*
> (livro da vaca). Foco em princípios de modelo relacional — sem entrar em
> particularidades de PostgreSQL/MySQL/InnoDB.
> **Status:** Insumo para futura grande atualização. Não é decisão fechada;
> achados marcados como Crítico/Maior/Menor são candidatos a virar ADRs.
> **Solicitante:** revisão pediu **alta granularidade** porque está sendo
> cruzada com revisões de outras camadas.

---

## Sumário executivo

O time já fez um movimento teoricamente correto na migration
`2026_03_08_NormalizeSchema`: saiu de colunas `JSONB` monolíticas para
**colunas escalares + tabelas filhas normalizadas**. Esse é exatamente o
caminho que Ramakrishnan defende em direção à 1NF e, parcialmente, à 3NF.

A revisão abaixo aponta o que **ainda falta** para o schema ser
*genuinamente* relacional segundo o livro:

1. Há **tabelas sem chave primária** (`patient_diagnoses`, `family_members`)
   — o que, no rigor do modelo, significa que **não são relações**.
2. Há **integridade referencial declarada apenas na camada de aplicação**
   (8+ colunas `*_id` sem `REFERENCES` no schema).
3. Há **controle de concorrência otimista presente em nome** (`version`)
   mas **não enforçado** no UPDATE.
4. Há **regressão de tipos** dirigida por ergonomia de driver (`JSONB → TEXT`
   na migration `2026_03_13_ConvertJsonbToText`).
5. Há **mistura de identidade vs valor** em tabelas filhas — operadas via
   "delete-and-insert", o que apaga identidade física.
6. Há **dinheiro armazenado/manipulado como `Double`** no Domain (apesar de
   `NUMERIC(12,2)` no schema).
7. Há **tabela ultra-larga** `patients` (~85 colunas) com módulos opcionais
   que ficam quase totalmente nulos para a maioria dos registros.

Os 7 itens acima são, na linguagem dos eixos do `database-theorist`:

- **Eixo 1 (Ratio legis):** entender *por que* o livro define cada regra.
- **Eixo 2 (Comparações):** decidir conscientemente onde aceitar trade-off
  (DDD prefere agregado coeso, normalização pura prefere decomposição).
- **Eixo 3 (Crítica):** sinalizar quando uma decisão antiga (JSONB→TEXT)
  precisa ser revisitada.

Cada decisão de "como corrigir" cabe a um ADR. Esta nota documenta o **achado**
e o **princípio violado** — não prescreve solução SQL específica.

---

## Como esta revisão foi conduzida

1. Mapeamento das 13 migrations em
   `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/`.
2. Mapeamento dos agregados, entidades e VOs em `Sources/social-care-s/Domain/`.
3. Verificação de correspondência via
   `IO/Persistence/SQLKit/Models/PatientDatabaseModels.swift`,
   `Mappers/PatientDatabaseMapper.swift`,
   `SQLKitPatientRepository.swift`.
4. Aplicação dos workflows das três skills do MCP `acdg-skills`
   (`database-tutor`, `database-theorist`, `database-engineer`).

**Cobertura:**

- Patient aggregate (Registry BC) — coberto.
- Assessment VOs (HousingCondition, SocialBenefit*, WorkAndIncome,
  HealthStatus, etc.) — coberto.
- Care (Appointment, Diagnosis) — coberto.
- Protection (Referral, RightsViolationReport, PlacementHistory) — coberto.
- Configuration (lookup tables, lookup_requests) — coberto.
- Outbox + Audit Trail — coberto.

---

## Inventário do schema (estado em 2026-05-14)

### Tabelas principais

| Tabela | PK declarada? | FKs ausentes | Observação |
|---|:-:|---|---|
| `patients` | ✅ `id` (UUID) | `person_id` (cross-service, intencional) | ~85 colunas. UNIQUE em `person_id`. UNIQUE parcial em `cpf WHERE NOT NULL`. |
| `patient_diagnoses` | ❌ **sem PK** | tem FK p/ patients | Modelado como tabela mas é multi-set. |
| `family_members` | ❌ **sem PK** | tem FK p/ patients; **falta FK p/ `dominio_parentesco`** | `relationship` é TEXT armazenando UUID. |
| `social_care_appointments` | ✅ `id` | `professional_in_charge_id` sem FK (cross-service) | OK. |
| `referrals` | ✅ `id` | `requesting_professional_id`, `referred_person_id` (cross-service) | OK. |
| `rights_violation_reports` | ✅ `id` | `victim_id` (cross-service) | `incident_date TIMESTAMP` sem TZ. |
| `outbox_messages` | ✅ `id` | n/a | `payload` regredido para TEXT (era JSONB). |
| `audit_trail` | ✅ `id` | n/a | `payload` regredido para TEXT. `occurred_at` é TIMESTAMPTZ (inconsistente). |
| `lookup_requests` | ✅ `id` | `requested_by`, `reviewed_by` são TEXT (deveriam ser ProfessionalId UUID?) | `status` default em PT ('pendente'). |

### Tabelas de domínio (lookup)

Todas seguem o mesmo schema: `id UUID PK`, `codigo TEXT UNIQUE`, `descricao TEXT`, `ativo BOOLEAN`.

- `dominio_parentesco`, `dominio_tipo_identidade`, `dominio_condicao_ocupacao`,
  `dominio_escolaridade`, `dominio_efeito_condicionalidade`,
  `dominio_tipo_deficiencia`, `dominio_tipo_ingresso`, `dominio_programa_social`
- `dominio_tipo_beneficio` (+ `exige_registro_nascimento`, `exige_cpf_falecido`)
- `dominio_tipo_violacao` (+ `exige_descricao`)
- `dominio_servico_vinculo`, `dominio_tipo_medida`, `dominio_unidade_realizacao`

Nomenclatura em **português** enquanto o restante do schema é em **inglês**.

### Tabelas filhas normalizadas (criadas em `2026_03_08`)

| Tabela | PK | FK para patients | FKs lógicas faltando |
|---|:-:|:-:|---|
| `member_incomes` | ✅ `id` | ✅ | `occupation_id` → `dominio_condicao_ocupacao`; `member_id` → `family_members` |
| `social_benefits` | ✅ `id` | ✅ | `beneficiary_id` (cross-service); `benefit_name` poderia virar FK p/ `dominio_tipo_beneficio` |
| `member_educational_profiles` | ✅ `id` | ✅ | `education_level_id` → `dominio_escolaridade`; `member_id` → `family_members` |
| `program_occurrences` | ✅ `id` | ✅ | `effect_id` → `dominio_efeito_condicionalidade`; `member_id` |
| `member_deficiencies` | ✅ `id` | ✅ | `deficiency_type_id` → `dominio_tipo_deficiencia`; `member_id` |
| `gestating_members` | ✅ `id` | ✅ | `member_id` |
| `placement_registries` | ✅ `id` | ✅ | `member_id` |
| `ingress_linked_programs` | ✅ `id` | ✅ | `program_id` → `dominio_programa_social` |

**Observação:** todas têm PK surrogate (UUID `id`) — boa prática — mas nenhuma
declara FK para as lookup tables que conceitualmente já são vinculadas pelo
nome da coluna (`*_id`).

---

## Quadro consolidado de severidades

| # | Severidade | Achado | Princípio do livro violado |
|---|---|---|---|
| 1 | **Crítico** | `patient_diagnoses` e `family_members` **sem PK** | Modelo relacional — tuplas precisam de identidade |
| 2 | **Crítico** | `patients.version` armazenado mas **não checado em UPDATE** | Controle de concorrência otimista (Cap. 17) |
| 3 | **Crítico** | 8+ colunas `*_id` para `dominio_*` **sem FK declarada** | Integridade referencial (Cap. 3.3) |
| 4 | **Crítico** | `family_members.relationship` guarda UUID como TEXT, sem FK | Domínio de coluna + integridade referencial |
| 5 | **Maior** | `family_members.required_documents` armazenado como TEXT (JSON serializado) | 1NF — atomicidade |
| 6 | **Maior** | "Delete-and-insert" em todas as filhas no `save()` | Identidade de entidade + auditoria |
| 7 | **Maior** | `patients` com ~85 colunas, módulos opcionais largamente NULL | Schema design para esparsidade (Cap. 19.6) |
| 8 | **Maior** | Dinheiro como `Double` no Domain | Domínio de tipo numérico — precisão financeira |
| 9 | **Maior** | Migration `2026_03_13` regride JSONB → TEXT por ergonomia do driver | Independência física da representação |
| 10 | **Menor** | Mistura `TIMESTAMP` vs `TIMESTAMPTZ` entre tabelas | Consistência de domínio temporal |
| 11 | **Menor** | UF validada em código Swift, não no schema | Domínio de atributo deveria viver no schema |
| 12 | **Menor** | Naming misto PT (`dominio_*`) / EN | Convenção / cognitive load |
| 13 | **Sugestão** | `member_id` em filhas sem FK lógica para `family_members` | Integridade referencial transitiva |
| 14 | **Sugestão** | `actor_id` em `audit_trail` é TEXT | Tipos consistentes para identidade |
| 15 | **Sugestão** | `outbox_messages` sem índice em `event_type` | Acesso para subscribers seletivos no futuro |
| 16 | **Sugestão** | Datas conceituais (nascimento, diagnóstico) armazenadas como TIMESTAMP | Tipo carrega precisão a mais e risco de TZ |
| 17 | **Sugestão** | Não há `created_at`/`updated_at` em `patients` | Auditoria operacional básica |

---

## Achado 1 — **Crítico** — Tabelas sem chave primária

### Onde

- `patient_diagnoses` — criada em `2026_02_24_CreateInitialSchema.swift:26-31`.
  Colunas: `patient_id UUID FK NOT NULL`, `icd_code TEXT NOT NULL`,
  `date TIMESTAMP NOT NULL`, `description TEXT NOT NULL`.
- `family_members` — criada em `2026_02_24_CreateInitialSchema.swift:34-40`.
  Colunas: `patient_id UUID FK NOT NULL`, `person_id UUID NOT NULL`,
  `relationship TEXT NOT NULL`, `is_primary_caregiver BOOLEAN NOT NULL`,
  `resides_with_patient BOOLEAN NOT NULL` (+ colunas adicionadas em
  `2026_03_04_AddRegistrationFields`).

### Princípio violado (Ramakrishnan & Gehrke, Cap. 3)

Uma **relação** é, por definição matemática, um conjunto de tuplas
distintas. O livro estabelece:

> "Each row in a relation represents a unique tuple. A relation has a
> primary key, which is a minimal subset of attributes that uniquely
> identifies each tuple."

Sem PK, o que está na tabela **não é tecnicamente uma relação** — é um
*multi-set*. SQL aceita por permissividade histórica; o modelo relacional
não admite.

### Evidências no domínio

`FamilyMember.swift:60-63` define identidade lógica:

```swift
public static func == (lhs: FamilyMember, rhs: FamilyMember) -> Bool {
    return lhs.personId == rhs.personId
}
```

Ou seja: **o domínio sabe** que dois `FamilyMember` com o mesmo `personId`
são "o mesmo". Mas o schema permite duas linhas com mesmo
`(patient_id, person_id)`. O Repositório "esconde" isso fazendo
`DELETE WHERE patient_id = ?` + `INSERT` (achado 6) a cada save —
mascarando a ausência de unicidade.

### Cenários quebrados pela ausência de PK

1. **Importação externa / ETL / fix manual via SQL:** nada impede dois
   diagnósticos idênticos para o mesmo paciente no mesmo dia.
2. **Replicação row-based:** sem PK explícita, replicadores não conseguem
   localizar a tupla a replicar de forma determinística.
3. **Referências futuras:** se algum dia uma tabela quiser referenciar
   um `family_member` específico (ex.: `member_incomes.member_id`
   amarrado a `family_members`), não há alvo de FK.
4. **DELETE seletivo via SQL puro:** "deletar só o cônjuge" é
   impossível sem critério extra ou inspeção tupla a tupla.

### Recomendação abstrata (não prescreve DDL específico)

- `patient_diagnoses`: PK natural composta `(patient_id, icd_code)` **se** a
  regra de negócio for "um diagnóstico ativo por CID"; caso múltiplas
  ocorrências do mesmo CID em datas distintas sejam válidas, adicionar
  `(patient_id, icd_code, date)` ou surrogate `id UUID`.
- `family_members`: PK natural composta `(patient_id, person_id)` reflete
  exatamente o `==` do domínio. Decisão alternativa: surrogate `id UUID` +
  UNIQUE em `(patient_id, person_id)` — esta forma é melhor se outras
  tabelas vierem a referenciar `member_id` (caso da família `member_*`).

### Conexão com outros achados

- Achado 6 (delete-and-insert) é a consequência operacional dessa
  ausência: o repositório não tem como fazer "update do membro X"
  determinístico, então atomiza apagando tudo.
- Achado 13 (`member_id` sem FK) só fica viável **depois** de fechar este.

---

## Achado 2 — **Crítico** — `version` não enforçado no UPDATE

### Onde

- Schema: `patients.version INT NOT NULL` (`CreateInitialSchema:18`).
- Domain: `Patient.swift:18` declara `var version: Int`; `Patient.swift:144-147`
  incrementa em `addEvent`.
- Repositório: `SQLKitPatientRepository.swift:19-22` faz UPSERT
  (`ON CONFLICT (id) DO UPDATE SET excludedContentOf...`) **sem condição em
  `WHERE version = ?`**.

### Princípio violado (Ramakrishnan & Gehrke, Cap. 17 — Concurrency Control)

Controle de concorrência otimista (OCC) funciona em três fases:
Read → Validate → Write. A fase Validate **exige** verificar que a versão
no banco ainda é a versão lida. Sem essa verificação, o esquema é só
uma contagem decorativa.

> "In an optimistic concurrency control scheme, the system tries to
> execute transactions without enforcing locks. At commit time, the
> system checks for conflicts and aborts the transaction if any are
> detected."

O "check for conflicts" é exatamente o `WHERE version = old_version`
que está faltando.

### Cenário quebrado

1. Processo A lê `Patient(id=X, version=5)`.
2. Processo B lê `Patient(id=X, version=5)`.
3. A faz comando 1, novo state version=6, salva → banco fica version=6.
4. B faz comando 2 (sobre o state antigo), novo state version=6, salva →
   banco fica version=6 com **dados de B sobrescrevendo dados de A**.

Esse é o **Lost Update Problem** em sua forma canônica. Read Committed
(default Postgres) não previne — exige Repeatable Read/Serializable
**ou** OCC enforçado.

### Por que não foi notado até agora

O `actor model` Swift (cada handler é `actor`) serializa **comandos
direcionados ao mesmo handler na mesma instância**. Mas:

- Múltiplas réplicas do serviço em Kubernetes não compartilham actor
  state.
- Dois handlers diferentes (`AssignPrimaryCaregiver` + `AddFamilyMember`)
  podem rodar simultaneamente.
- Reentrância de async: dentro do mesmo actor, await libera a fila.

### Recomendação abstrata

Transformar o write em UPDATE condicional:

```
UPDATE patients
SET <cols> = <values>, version = :newVersion
WHERE id = :id AND version = :oldVersion
```

Se `rowsAffected = 0` → conflito → lançar `OptimisticLockError`.
Application traduz para `AppError` de conflito (HTTP 409).

Isso é SQL padrão, não depende de SGBD.

---

## Achado 3 — **Crítico** — FKs lógicas para lookups não declaradas

### Onde

Colunas que **conceitualmente** apontam para `dominio_*` mas **não têm
`REFERENCES`** no schema:

| Coluna | Tabela | Aponta logicamente para |
|---|---|---|
| `social_identity_type_id` | `patients` | `dominio_tipo_identidade` |
| `ii_ingress_type_id` | `patients` | `dominio_tipo_ingresso` |
| `occupation_id` | `member_incomes` | `dominio_condicao_ocupacao` |
| `education_level_id` | `member_educational_profiles` | `dominio_escolaridade` |
| `effect_id` | `program_occurrences` | `dominio_efeito_condicionalidade` |
| `deficiency_type_id` | `member_deficiencies` | `dominio_tipo_deficiencia` |
| `program_id` | `ingress_linked_programs` | `dominio_programa_social` |
| `relationship` | `family_members` | `dominio_parentesco` (e ainda é TEXT — ver Achado 4) |

### Princípio violado (Ramakrishnan & Gehrke, Cap. 3.3)

> "All foreign key constraints must be declared in the schema. They
> express semantic relationships that the DBMS will enforce on every
> insert, update, and delete."

O livro é categórico: integridade declarada no schema vale para **todas
as vias de acesso**. Validação em camada de aplicação só vale para a via
canônica.

### Eixo theorist — comparativa com a decisão atual

A defesa "o `LookupValidating` da Application valida antes de salvar"
é honesta, mas constitui uma **escolha arquitetural**:

| Estratégia | Garantia | Custo |
|---|---|---|
| FK declarada no schema | Universal — toda escrita validada pelo banco | Latência de validação por INSERT, requer lookup existir antes |
| Validação na Application | Vale só para a via canônica | Zero custo no banco; bypass total se houver outra via |
| Híbrido (FK + validação semântica) | Universal + erro de negócio bonito | Dobra de validação |

O `database-theorist` resumiria isso citando **Codd vs. caso prático**:
Codd via integridade como parte do schema porque era o único contrato
estável. A Application moderna (DDD) inverte: o agregado é o contrato,
o banco é detalhe. Essa inversão **é legítima**, mas tem que ser
**decisão consciente** com ADR — não omissão.

### Cenários quebrados pela ausência

1. Importação direta via SQL com IDs inventados → dados órfãos.
2. Soft-delete de um item de `dominio_*` (cancelar um programa social):
   sem FK, registros existentes apontando para ele **continuam ativos
   silenciosamente**. Com FK `ON DELETE RESTRICT`, o banco bloqueia o
   delete e força tratamento explícito.
3. Renomeação de `dominio_*`: sem FK, nada amarra o nome — a string
   `social_identity_type_id` é só uma convenção visual.

### Recomendação abstrata

Para cada coluna acima, adicionar `REFERENCES dominio_<tabela>(id) ON
DELETE RESTRICT`. A política `RESTRICT` é a única segura — `CASCADE`
ou `SET NULL` em lookup table seria catastrófico.

**Pré-requisito:** validar que dados existentes estão íntegros antes da
migration. Se houver órfãos (provável após meses sem FK), backfill ou
quarentena precisam acontecer primeiro.

---

## Achado 4 — **Crítico** — `family_members.relationship` é TEXT armazenando UUID

### Onde

- Schema: `family_members.relationship TEXT NOT NULL`
  (`CreateInitialSchema:37`).
- Domain: `FamilyMember.relationshipId: LookupId` — VO que envolve UUID.
- Mapper escreve `m.relationshipId.description` (UUID stringificado):
  `PatientDatabaseMapper.swift:27`.
- Mapper decodifica `try LookupId(m.relationship)`:
  `PatientDatabaseMapper.swift:135`.

### Princípio violado

**Domínio de coluna** (Ramakrishnan, Cap. 3.1):

> "Each attribute has a name and a domain, which is a set of allowed
> values. The domain restricts what values can appear in that attribute."

Declarar `relationship TEXT` quando o valor real é um UUID semântico que
aponta para `dominio_parentesco.id` é declarar o tipo errado. O banco
aceita qualquer string — inclusive `'irmão'`, `'foo bar'`, ou um UUID que
não existe na lookup table.

### Análise didática (tutor)

A diferença prática entre `TEXT` e `UUID + FK`:

```
Cenário: alguém insere via SQL direto
INSERT INTO family_members (patient_id, person_id, relationship, ...)
VALUES ('uuid1', 'uuid2', 'cônjuge', ...);

Schema atual (TEXT, sem FK): aceita silenciosamente. Domain quebra na leitura.
Schema corrigido (UUID + FK): banco rejeita imediatamente com erro de
tipo ou FK violation.
```

### Recomendação abstrata

1. Adicionar coluna nova `relationship_id UUID NOT NULL` com FK para
   `dominio_parentesco(id)`.
2. Backfill: `UPDATE family_members SET relationship_id = relationship::UUID`
   (com tratamento de erros se houver linhas mal-formadas).
3. Drop da coluna antiga `relationship`.
4. Atualizar mapper para usar `relationship_id` direto como UUID.

Reflete simultaneamente Achado 3 (FK) e Achado 4 (tipo correto).

---

## Achado 5 — **Maior** — `required_documents` viola 1NF

### Onde

- Schema atual: `family_members.required_documents TEXT NOT NULL DEFAULT ''`
  (após `2026_03_13_ConvertJsonbToText`). Antes era JSONB.
- Domain: `FamilyMember.requiredDocuments: [RequiredDocument]` — array do
  enum `RequiredDocument`.
- Mapper:
  - Escreve: `String(data: try encoder.encode(m.requiredDocuments.map { $0.rawValue }), encoding: .utf8)!`
  - Lê: `try? decoder.decode([String].self, from: Data(m.required_documents.utf8))`

Ou seja: o array é serializado como JSON e guardado em TEXT.

### Princípio violado (Ramakrishnan, Cap. 19 — Normalization)

**Primeira Forma Normal:**

> "A relation is in 1NF if every attribute value is atomic
> (indivisible) from the point of view of the database. Multi-valued
> attributes and composite attributes are not permitted."

Um conjunto de documentos é, por definição, **multivalorado**. Guardar
como JSON em TEXT é exatamente o caso que 1NF proíbe.

### Eixo theorist — defesa moderna do JSON

A escola NoSQL defende: "se o agregado é a fronteira de consistência,
JSON dentro da linha do agregado é OK". Mas:

1. JSON em **JSONB** ao menos preserva validação sintática + indexação
   `WHERE payload @> '{"foo": "bar"}'`. JSONB é a defesa híbrida.
2. JSON em **TEXT** perde tudo: qualquer string passa, nenhuma indexação
   estruturada possível.

A migration `2026_03_13_ConvertJsonbToText` regrediu de JSONB para TEXT
**por ergonomia do driver `PostgresKit`** — Achado 9 trata desse motivo.

### Caminho 1NF estrito

Tabela filha:

```
family_member_required_documents (
  patient_id UUID,
  person_id UUID,
  document_type_id UUID  -- FK para dominio_tipo_documento (a criar)
  -- OU: document_code TEXT com CHECK em valores permitidos
  PK (patient_id, person_id, document_type_id)
  FK (patient_id, person_id) -> family_members
)
```

Trade-off: cada `FamilyMember.requiredDocuments` vira N rows. Read
fica com 1 query extra (ou 1 LEFT JOIN). Mas habilita análises do
tipo "quantos pacientes precisam de RG?" sem function-on-column.

### Recomendação

- Curto prazo: **se** o atributo nunca for usado como critério de busca,
  reverter de TEXT para JSONB é melhoria parcial (volta indexação JSONB).
- Médio prazo: extrair para tabela filha (1NF pleno) quando alguém
  precisar consultar.

---

## Achado 6 — **Maior** — Delete-and-insert em todas as filhas a cada save

### Onde

`SQLKitPatientRepository.swift:256-266`:

```swift
private func deleteAndInsert<T: Codable>(
    _ tx: any SQLDatabase,
    table: String,
    patientId: UUID,
    models: [T]
) async throws {
    try await tx.delete(from: table).where("patient_id", .equal, patientId).run()
    for model in models {
        try await tx.insert(into: table).model(model).run()
    }
}
```

Invocado para **13 tabelas filhas** a cada `save()` do agregado.

### Princípio violado

**Identidade de entidade** (DDD + relacional clássico).

- Para **Value Objects imutáveis** (`Diagnosis`), delete-and-insert é
  semanticamente equivalente à substituição. OK.
- Para **Entidades com identidade** (`FamilyMember`, `Appointment`,
  `Referral`, `RightsViolationReport`, `PlacementHistory`), apagar e
  recriar **destrói a identidade física** da entidade. Consequências:
  1. Audit trail externo (row-level audit do banco, replicação) vê
     fluxo `DELETE` + `INSERT` ao invés de `UPDATE` semântico.
  2. Triggers `ON UPDATE` jamais disparam — só `ON DELETE` + `ON INSERT`.
  3. Caso uma tabela venha a referenciar `family_members.id`, FK quebra a
     cada save (ou só funciona com `ON DELETE CASCADE`, escalando o
     problema para mais filhas).
  4. `created_at` (se algum dia for adicionado a `family_members`) fica
     atualizado a cada save — perdendo a semântica de "quando essa
     entidade nasceu".

### Justificativa atual implícita

O time provavelmente fez delete-and-insert porque:
- `family_members` não tem PK estável (Achado 1) — não dá pra UPSERT.
- Diff (calcular added/updated/removed) exigiria carregar o estado
  anterior do banco e comparar — mais código.

### Caminho correto teórico

1. Garantir PK estável em todas as filhas (Achado 1 resolve).
2. Trocar `deleteAndInsert` por `diff + upsert + delete dos removidos`:
   - Para cada filha: carregar IDs existentes.
   - Para cada item no agregado: UPSERT (`ON CONFLICT (id)`).
   - Para cada ID existente que não está mais no agregado: DELETE.

Custo: ~30 linhas a mais de código, mas preserva identidade e
audit trail correto.

### Conexão

- Depende do Achado 1 (PK).
- Resolve uma classe inteira de "por que `family_members` parece
  estranho?" quando outros sistemas (auditoria externa) lerem o banco.

---

## Achado 7 — **Maior** — Tabela `patients` com ~85 colunas

### Onde

`patients` após todas as migrations contém:

- **Aggregate metadata:** `id`, `person_id`, `version` (3 cols).
- **PersonalData:** `first_name`, `last_name`, `mother_name`,
  `nationality`, `sex`, `social_name`, `birth_date`, `phone` (8 cols).
- **CivilDocuments:** `cpf`, `nis`, `rg_number`, `rg_issuing_state`,
  `rg_issuing_agency`, `rg_issue_date`, `cns_number`, `cns_cpf`,
  `cns_qr_code` (9 cols).
- **Address:** `address_cep`, `address_is_shelter`, `address_is_homeless`,
  `address_location`, `address_street`, `address_neighborhood`,
  `address_number`, `address_complement`, `address_state`,
  `address_city` (10 cols).
- **HousingCondition:** `hc_*` (15 cols).
- **SocialIdentity:** `social_identity_type_id`,
  `social_identity_other_desc` (2 cols).
- **CommunitySupportNetwork:** `csn_*` (7 cols).
- **SocialHealthSummary:** `shs_*` (4 cols).
- **SocioEconomicSituation:** `ses_*` (5 cols).
- **WorkAndIncome:** `wi_has_retired_members` (1 col).
- **HealthStatus:** `hs_food_insecurity`,
  `hs_constant_care_member_ids` (2 cols).
- **PlacementHistory:** `ph_*` (4 cols).
- **IngressInfo:** `ii_*` (4 cols).
- **Discharge:** `status`, `discharge_reason`, `discharge_notes`,
  `discharged_at`, `discharged_by` (5 cols).
- **Withdraw:** `withdraw_reason`, `withdraw_notes`, `withdrawn_at`,
  `withdrawn_by` (4 cols).

**Total: ~83 colunas**, com 14+ módulos conceitualmente independentes
prensados na mesma linha.

### Princípio violado (Ramakrishnan, Cap. 19.6 — Schema Design and Sparse Tables)

> "When a subset of attributes is null for many rows because the
> attributes do not apply to those rows, this suggests that those
> attributes belong in a separate relation linked by foreign key."

A distinção clássica de Codd para NULLs:

| Tipo | Significado | Aceitável? |
|---|---|---|
| (a) Valor desconhecido, mas existente | Ex.: paciente tem CPF, mas ainda não foi coletado | Legítimo |
| (b) Atributo não-aplicável à tupla | Ex.: `ph_adult_in_prison` para paciente sem `PlacementHistory` avaliada | **Sinal de decomposição faltando** |
| (c) Representante explícito de "n/a" | Ex.: `discharge_reason` para paciente ativo | Abuso |

Os módulos `IngressInfo`, `PlacementHistory`, `WorkAndIncome`,
`HealthStatus`, `SocialHealthSummary`, `CommunitySupportNetwork` são
**aspectos opcionais** de um paciente. Para muitos, todos os campos
desses módulos estarão NULL — caso (b).

### Eixo theorist — Date radical vs Ramakrishnan pragmático

- **Date** (extremo): zero NULLs, decompor sempre. Cada aspecto
  opcional vira tabela 1:0..1 com FK.
- **Ramakrishnan** (pragmático): NULLs são aceitáveis quando o atributo
  é universalmente aplicável mas o valor pode faltar; decomposição é
  exigida quando há **partição de população** (paciente "tem" ou "não
  tem" o módulo todo).

A modelagem atual fica no pior dos dois mundos: aceita NULLs (Date
discordaria) **e** não decompõe (Ramakrishnan discordaria).

### Caminho da decomposição

Cada VO 0..1 vira tabela 1:0..1:

```
patient_placement_history(patient_id PK FK, home_loss_report, ...)
patient_ingress_info(patient_id PK FK, ingress_type_id FK, ...)
patient_work_and_income(patient_id PK FK, has_retired_members)
patient_health_status(patient_id PK FK, food_insecurity, ...)
patient_social_health_summary(patient_id PK FK, ...)
patient_community_support_network(patient_id PK FK, ...)
```

**Vantagens:**
1. Existência de linha **é a informação** "o módulo foi avaliado".
2. Cada módulo vira sub-agregado natural — Domain pode manter como
   `Optional` (presença de row = `.some`, ausência = `.none`).
3. Read individual de paciente faz JOIN seletivo (só os módulos
   que importam).
4. Backups / dumps menores quando a maioria dos pacientes não tem o
   módulo.

**Trade-off:** save() do agregado fica mais complexo (lida com mais
tabelas); read full-aggregate exige 6 JOINs extras. Mas o full-aggregate
read **já** faz 14 queries (Achado relacionado em `loadAggregate`),
então o impacto marginal é pequeno.

### Conexão com bounded contexts

Os módulos `WorkAndIncome`, `HealthStatus`, `SocialHealthSummary`,
etc. pertencem ao BC **Assessment**, não **Registry**. Decompor física
e logicamente alinha schema com bounded contexts — o que reforça a
arquitetura DDD do handbook.

---

## Achado 8 — **Maior** — Dinheiro como `Double`

### Onde

- Domain: `SocialBenefit.amount: Double`
  (`Assessment/ValueObjects/SocialBenefit/SocialBenefit.swift:14`).
- Domain: `MemberIncome.monthlyAmount: Double` (estrutura análoga).
- Domain: `SocioEconomicSituation.totalFamilyIncome: Double`,
  `incomePerCapita: Double` (provável — segue padrão).
- Schema: `NUMERIC(12,2)` em todas as colunas correspondentes.
- Mapper: bind direto `Swift Double` → `Postgres NUMERIC`.

### Princípio violado (Ramakrishnan, Cap. 3.1; Date, *Type Inheritance and Relational Theory*)

Domínio numérico: tipos com aritmética binária inexata (IEEE 754
`Double`) **não preservam** somas decimais.

**Demonstração canônica:**

```swift
let total = (1...100).reduce(0.0) { $0 + 0.1 }
// Esperado: 10.0
// Real: 9.99999999999998
```

Para auditoria PBF/BPC, isso é inaceitável. Ramakrishnan e Date
convergem aqui: dinheiro é decimal, não float.

### Cenários quebrados

1. `SocialBenefitsCollection.totalAmount` (linha 47):
   `items.reduce(0.0) { $0 + $1.amount }` — soma sobre Double.
2. Persistência: `NUMERIC(12,2)` no banco arredonda para 2 casas, mas o
   round-trip Swift Double → Postgres NUMERIC → Swift Double tem perda
   acumulada.
3. Comparação em queries: `WHERE amount = 600.00` pode falhar para
   valores que **foram** 600.00 mas viraram 599.9999... em alguma
   iteração.

### Recomendação abstrata

Introduzir VO `Money`:

```swift
public struct Money: Codable, Equatable, Hashable, Sendable {
    public let centavos: Int64   // ou Decimal nativo do Swift
    public let currency: String  // "BRL"
}
```

Toda aritmética sobre dinheiro vai pelo `Money`. Mapper converte para
`NUMERIC` sem perda. Para `Decimal` Swift, a conversão é trivial e
mantida.

**Migration:** zero. O schema já está correto. A mudança é no Domain.

---

## Achado 9 — **Maior** — Regressão JSONB → TEXT por ergonomia do driver

### Onde

Migration `2026_03_13_ConvertJsonbToText.swift`:

```swift
// "Converte colunas JSONB que são tratadas como String no Swift para
// TEXT, eliminando o mismatch de tipo no bind do PostgresKit
// (.model() envia TEXT, coluna espera JSONB)."

try await db.raw("ALTER TABLE family_members ALTER COLUMN required_documents TYPE TEXT USING required_documents::text").run()
try await db.raw("ALTER TABLE patients ALTER COLUMN shs_functional_dependencies TYPE TEXT USING shs_functional_dependencies::text").run()
try await db.raw("ALTER TABLE patients ALTER COLUMN hs_constant_care_member_ids TYPE TEXT USING hs_constant_care_member_ids::text").run()
try await db.raw("ALTER TABLE outbox_messages ALTER COLUMN payload TYPE TEXT USING payload::text").run()
try await db.raw("ALTER TABLE audit_trail ALTER COLUMN payload TYPE TEXT USING payload::text").run()
```

### Princípio violado

**Independência física da representação** (Ramakrishnan, Cap. 1.2):

> "A key benefit of using a DBMS is data independence: applications
> are insulated from changes in the storage details."

E o corolário oposto: decisões de schema devem ser guiadas pela
**semântica do dado**, não pela ergonomia do driver. Aqui aconteceu o
inverso — o schema foi rebaixado porque o driver era inconveniente.

### Eixo theorist — crítica histórica

A indústria tem precedente: na era 2005-2015 muitos schemas foram
desnormalizados para "facilitar ORM". Stonebraker (One Size Fits All)
e a comunidade NewSQL reagiram: a abstração relacional é tão valiosa
que vale resolver o problema do driver, não o do schema.

A defesa "PostgresKit envia TEXT, JSONB rejeita" é o sintoma. A solução
não-regressiva seria:

1. **Cast explícito no INSERT**: `INSERT INTO ... payload::jsonb`. SQLKit
   permite SQL bruto onde necessário.
2. **Tipo wrapper no Swift**: `PostgresJSON<T>` que serializa para JSONB
   diretamente.
3. **Trocar driver** se a fricção for crônica.

Nenhuma das três foi escolhida; o schema foi rebaixado.

### Custo da regressão

- `outbox_messages.payload`: era JSONB indexável. Agora TEXT opaco.
  Subscribers que filtram por `payload->>'eventType'` (futuro provável)
  fazem function-on-column.
- `audit_trail.payload`: idem. Query "todos os eventos com `patient_id
  = X`" não pode usar índice JSONB.
- `family_members.required_documents`: cobre a 1NF (Achado 5)
  paralelamente.

### Recomendação

Issue separada: reverter para JSONB com cast explícito no INSERT/UPDATE
do driver. Custo de migration: baixo (`ALTER COLUMN TYPE JSONB USING
payload::jsonb`).

---

## Achado 10 — **Menor** — Mistura TIMESTAMP vs TIMESTAMPTZ

### Onde

- `TIMESTAMP` (sem TZ): `patient_diagnoses.date`, `family_members.birth_date`,
  `social_care_appointments.date`, `referrals.date`,
  `rights_violation_reports.report_date` / `incident_date`,
  `outbox_messages.occurred_at` / `processed_at`,
  `lookup_requests.requested_at` / `reviewed_at`, `patients.birth_date`,
  `patients.rg_issue_date`, `member_*.date`, `placement_registries.start_date`
  / `end_date`.
- `TIMESTAMP WITH TIME ZONE`: `audit_trail.occurred_at` /
  `recorded_at`, `patients.discharged_at`, `patients.withdrawn_at`.

### Princípio

Date é categórico:

> "A timestamp without timezone is a timestamp without meaning."

Ramakrishnan é mais brando, mas reconhece que mistura no mesmo banco
é fonte de bugs sutis quando o serviço atravessa fusos (deploy em
multi-região, dados importados de fonte em UTC, etc.).

### Recomendação

Convergir para `TIMESTAMPTZ` em todos os timestamps **operacionais**
(ocorrências, persistência). Para datas conceituais sem hora (nascimento,
diagnóstico), considerar `DATE` puro (Achado 16).

---

## Achado 11 — **Menor** — UF validada em código Swift

### Onde

`Domain/Kernel/Address/Address.swift:121-125`:

```swift
private static let validStates: Set<String> = [
    "AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO",
    "MA", "MT", "MS", "MG", "PA", "PB", "PR", "PE", "PI",
    "RJ", "RN", "RS", "RO", "RR", "SC", "SP", "SE", "TO"
]
```

Schema `address_state TEXT` aceita qualquer string.

### Princípio

Domínio de coluna deveria viver no schema. O livro:

> "Constraints that must hold on every access to the data should be
> declared in the schema, not enforced solely in application code."

### Recomendação

Duas opções:

1. **Lookup table `dominio_uf(codigo TEXT PK, nome TEXT)` + FK em
   `address_state`** — cara, mas reaproveita o padrão `dominio_*`.
2. **CHECK constraint**: `CHECK (address_state IN ('AC', 'AL', ...))` —
   mais leve, mas duplica a lista entre code e schema.

Decisão depende de "UF é dado de domínio que pode mudar?" — não muda
desde 1988 (Tocantins). Provavelmente CHECK basta.

---

## Achado 12 — **Menor** — Nomenclatura mista PT/EN

`dominio_parentesco`, `dominio_tipo_identidade`, etc. em PT.
`family_members`, `social_care_appointments`, `patient_diagnoses` em EN.
Colunas dentro de `dominio_*`: `codigo`, `descricao`, `ativo` em PT.

Ramakrishnan, Cap. 4 (Schema Design): "Consistency of naming reduces
cognitive load on every future reader."

**Recomendação:** padronizar (provavelmente EN — segue resto do schema
e match com convenção do código Swift). Custo de migration: médio,
exige updates em queries e mappers.

---

## Achado 13 — **Sugestão** — `member_id` em filhas sem FK lógica

Tabelas `member_incomes`, `member_educational_profiles`,
`member_deficiencies`, `gestating_members`, `placement_registries` têm
coluna `member_id UUID` que **deveria** referenciar um `FamilyMember` do
mesmo `patient`. Nenhuma tem FK.

Hoje, `member_id` pode ser qualquer UUID — não há garantia de que
aquela pessoa esteja na família do paciente.

**Pré-requisito:** Achado 1 (PK em `family_members`). Depois, FK
composta: `FOREIGN KEY (patient_id, member_id) REFERENCES
family_members(patient_id, person_id)`.

---

## Achado 14 — **Sugestão** — `audit_trail.actor_id` como TEXT

`audit_trail.actor_id TEXT` armazena o `JWT.sub` (atualmente um string
UUID-like vindo do Authentik/Zitadel). Outras colunas do tipo
"professional/user id" no schema são `UUID`. Padronizar para `UUID` ou
documentar por que essa é TEXT (ex.: IDs externos podem variar de
formato entre IdPs).

---

## Achado 15 — **Sugestão** — Outbox sem índice em `event_type`

`outbox_messages` tem índice parcial `idx_outbox_unprocessed
(occurred_at ASC) WHERE processed_at IS NULL` — bom para o relay.

Quando vier o primeiro subscriber externo filtrando por
`event_type` específico (ex.: `PatientRegistered`), não terá índice.
Considerar `(event_type, occurred_at) WHERE processed_at IS NULL` se
o pattern de consumo for seletivo.

---

## Achado 16 — **Sugestão** — Datas conceituais como TIMESTAMP

`birth_date`, `rg_issue_date`, `patient_diagnoses.date` semanticamente
são **DATE** (não têm hora). Armazenar como TIMESTAMP:
- Sempre tem hora 00:00:00 — informação desnecessária.
- Risco de TZ-shift se TIMESTAMPTZ for adotado (Achado 10): "nasceu
  dia 15" pode virar "nasceu dia 14 às 23:00" em fuso negativo.

Tipo correto é `DATE`. Recomendação: revisar caso a caso.

---

## Achado 17 — **Sugestão** — Ausência de `created_at`/`updated_at` em `patients`

`patients` tem timestamps de eventos específicos (`discharged_at`,
`withdrawn_at`) mas não de criação/última atualização da row.

Auditoria operacional básica (Ramakrishnan trata em Cap. 18 de Recovery
e Cap. 19 de Schema):

> "Timestamps of creation and modification are conventional metadata
> attributes that allow ad-hoc auditing without consulting an event
> log."

Hoje, descobrir "quando esse paciente foi criado" exige consultar
`audit_trail` ou `outbox_messages` por `event_type = 'PatientRegistered'`.
Funciona, mas custa JOIN/leitura adicional.

**Recomendação:** colunas `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
e `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` em todas as tabelas
de entidades raiz (não em filhas — herdam do agregado).

---

## Análise das 3 personas (síntese para cruzamento futuro)

### `database-tutor` (didática)

> "O time já fez o passo mais difícil: sair de JSONB monolítico e
> normalizar em colunas escalares + tabelas filhas. Isso é exatamente o
> que 1NF e 3NF pedem.
>
> O próximo passo de aprendizado é completar o trabalho:
> 1. **Toda tabela é uma relação.** Relação tem PK. Sem PK, é
>    multi-set — o banco aceita, mas você não tem identidade de tupla
>    (e isso quebra muita coisa em cascata).
> 2. **FK é parte do schema, não da aplicação.** Quando você declara
>    `member_id UUID` sem FK, está dizendo 'confiamos que a aplicação
>    valida'. Codd dizia 'integridade declarada vale para todas as
>    vias de acesso'.
> 3. **Dinheiro nunca é float.** Sempre Decimal/NUMERIC. Soma de
>    Double não-associativa quebra auditoria.
>
> Sem isso, o schema parece relacional mas é um conjunto de tabelas
> que confiam na boa-fé da camada de aplicação."

### `database-theorist` (ratio legis)

> "Há uma tensão genuína aqui que vale virar ADR:
>
> **A premissa DDD** é que o aggregate root é a fronteira de
> consistência. O banco é detalhe de persistência. Logo, validação
> semântica fica no Domain/Application, e o schema só precisa
> persistir bits.
>
> **A premissa Codd/relacional** é oposta: integridade declarada no
> schema é o único contrato estável. Toda via de acesso a respeita.
> Aplicação pode mudar; o schema é a verdade.
>
> Cada escola tem custo:
>
> - DDD puro: omitir FKs/PKs é coerente, mas paga em data orphans
>   sempre que algo acessa fora da via canônica.
> - Codd puro: declarar tudo aumenta acoplamento entre Domain e
>   schema; mudanças em lookup tables ficam politicamente caras.
>
> A solução pragmática que Ramakrishnan defende é **híbrida**:
> integridade declarada para invariantes universais (existência de
> FK target, atomicidade), validação semântica na aplicação para
> regras de negócio (esse `IngressType` faz sentido aqui? esse paciente
> pode ser desligado?).
>
> A revisão acima encontra o serviço **no extremo DDD puro** — quase
> nenhuma integridade declarada além de PKs primárias. Mover para o
> meio (declarar FKs lógicas como Achado 3 lista) é movimento de baixo
> custo e alto ganho. **Vale ADR explícito** sobre por que outras
> integridades (validação de existência de paciente cross-service,
> RBAC) **continuam** na Application."

### `database-engineer` (severidades e ação)

> "**Críticos a corrigir antes do PROD ou próxima janela:**
>
> 1. PK em `family_members` (`(patient_id, person_id)`) e
>    `patient_diagnoses` — destrava todos os outros achados.
> 2. UPDATE condicional usando `version` — implementação no
>    `SQLKitPatientRepository.save()`. ~20 linhas.
> 3. FKs declaradas para colunas `*_id` listadas no Achado 3. Migration
>    nova com forward + rollback. Pré-validar dados existentes.
> 4. `relationship` virando `relationship_id UUID + FK`. Migration de
>    expand-contract (add nova col, backfill, drop antiga).
>
> **Maiores em sprint dedicada:**
>
> 5. Reverter JSONB → TEXT nos `payload` (Outbox, Audit) com cast
>    explícito no driver.
> 6. Diff-based upsert em filhas (depende de Achado 1).
> 7. Decompor módulos opcionais em tabelas 1:0..1 (`PlacementHistory`,
>    `IngressInfo`, `WorkAndIncome`, `HealthStatus`,
>    `SocialHealthSummary`, `CommunitySupportNetwork`) — mexe em
>    bounded context alignment.
> 8. VO `Money` no Domain — mexe em Domain + Mapper + tests.
>
> **Menores oportunistas (quando tocar a tabela):**
>
> 9-16. Naming, TIMESTAMPTZ unificado, CHECK em UF,
>    `created_at`/`updated_at`, índices marginais."

---

## ADRs sugeridos (rascunhos para próxima sessão)

| Tema | Justificativa |
|---|---|
| ADR — Política de integridade: schema vs aplicação | Decisão fundadora; afeta todos os achados Críticos 3-4 |
| ADR — Controle de concorrência otimista enforçado | Resolve Achado 2; padrão para todos agregados futuros |
| ADR — Money como VO de domínio | Resolve Achado 8; afeta SocialBenefit, MemberIncome, futuras assessments financeiras |
| ADR — Decomposição de patient em sub-agregados persistidos | Resolve Achado 7; tem implicações de read perf (JOINs) que merecem decisão consciente |
| ADR — Diff-based save para entidades com identidade | Resolve Achado 6; sucessor do delete-and-insert |
| ADR — JSONB padrão para payloads (reverte Achado 9) | Anula a decisão de `2026_03_13` |
| ADR — Padronização de timestamps em TIMESTAMPTZ | Resolve Achado 10 |

---

## Conexões com o restante do handbook

- `IMPLEMENTATION_PLAN.md` gaps G1-G17: verificar se algum gap já cobre
  pedaços disso (especialmente G2 OutboxRelay, que toca em `outbox_messages`).
- `architecture/README.md` v2.0 — 5 princípios: este relatório está
  alinhado com "Inteligência no Domínio" mas questiona se a decisão de
  "integridade no Domain" foi explícita (Achado 3 + ADR sugerido).
- `architecture/IMPROVEMENT_BACKLOG.md`: o item #10 (Encryption at rest
  LGPD) tem relação tangencial — colunas CPF/NIS são as primeiras
  candidatas a encryption se algum dia for column-level.
- `features/PATIENT_LIFECYCLE.md` (se existir): Achado 17 (`created_at`)
  aparece como gap de auditoria operacional.

---

## Material de origem para cruzamento

Arquivos lidos para esta revisão (caso seja necessário re-verificar):

**Migrations:**
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_02_24_CreateInitialSchema.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_03_04_AddRegistrationFields.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_03_05_CreateLookupTables.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_03_06_AddV2AssessmentFields.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_03_07_AddPerformanceIndexes.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_03_08_NormalizeSchema.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_03_09_CreateAuditTrail.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_03_13_ConvertJsonbToText.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_03_30_CreateLookupRequests.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_03_31_AddCNSAndHomeless.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_04_08_AddUniqueCpfConstraint.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_04_12_AddPatientDischarge.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Migrations/2026_04_12_AddWaitlistSupport.swift`

**Domain:**
- `Sources/social-care-s/Domain/Registry/Aggregates/Patient/Patient.swift`
- `Sources/social-care-s/Domain/Registry/Entities/FamilyMember/FamilyMember.swift`
- `Sources/social-care-s/Domain/Care/ValueObjects/Diagnosis/Diagnosis.swift`
- `Sources/social-care-s/Domain/Assessment/ValueObjects/SocialBenefit/SocialBenefit.swift`
- `Sources/social-care-s/Domain/Assessment/ValueObjects/SocialBenefitsCollection/SocialBenefitsCollection.swift`
- `Sources/social-care-s/Domain/Assessment/ValueObjects/HousingCondition/HousingCondition.swift`
- `Sources/social-care-s/Domain/Kernel/Address/Address.swift`

**IO Mapping:**
- `Sources/social-care-s/IO/Persistence/SQLKit/Models/PatientDatabaseModels.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/Mappers/PatientDatabaseMapper.swift`
- `Sources/social-care-s/IO/Persistence/SQLKit/SQLKitPatientRepository.swift`

**Skills consultadas (`acdg-skills` MCP, lidas do disco):**
- `~/Desktop/Projetos/dev/envolve/acdg/skills_base/database-engineer/`
- `~/Desktop/Projetos/dev/envolve/acdg/skills_base/database-theorist/`
- `~/Desktop/Projetos/dev/envolve/acdg/skills_base/database-tutor/`

---

## Pendências desta revisão

- [ ] Não foi feita análise de **performance/EXPLAIN** — fora do escopo
  ("teoria, não particularidades de cada banco"). Quando for feita,
  verificar especialmente:
  - `loadAggregate` em `SQLKitPatientRepository:268-302` faz 14 queries
    sequenciais — candidato a JOIN ou queries paralelas.
  - `list()` em `SQLKitPatientRepository:82-212` faz 2 queries de
    contagem/principal + 2 lookups (diagnosis + member count) —
    razoável, mas LIKE `%search%` impede uso de índice.
- [ ] Não foi avaliado o **isolamento de transação** explícito —
  Postgres default Read Committed. Para os agregados, vale verificar
  se algum read precisa de Repeatable Read.
- [ ] Não foi avaliado **outbox relay** (G2 do IMPLEMENTATION_PLAN) —
  apenas o schema da tabela.
- [ ] Não foi avaliada a **estratégia de soft delete vs hard delete**
  no contexto LGPD — o `status = 'discharged'` é soft, mas há
  pendência regulatória a considerar.
- [ ] Não foi avaliado se `dominio_*` precisaria de versionamento /
  histórico (ex.: tipo de benefício que existia em 2024 e foi extinto).

---

> **Próximo passo sugerido:** quando o usuário voltar com revisões de
> outras camadas (Application, IO/HTTP, Domain analytics), cruzar com
> este documento para identificar:
> - Onde a Application já validamundo coisas que poderiam estar no
>   schema (e onde **deveriam** continuar lá por design).
> - Onde a Application **não** valida coisas que o schema também não
>   captura — esses são os bugs latentes.
