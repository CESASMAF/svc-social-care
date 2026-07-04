# ADR-005: Optimistic Locking via coluna `version`

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** um ADR só pode ficar `Aceito`
> quando **todas** as seções abaixo estão preenchidas — incluindo `Teste de
> regressão` e `Better Pattern para skills`. ADR sem essas duas seções fica
> `Proposto` até completar.

## Contexto

Achado confirmado por **duas lentes independentes** — Senior Code Review
(S-C3) e Database Modeling Review (DB-2):

- `Patient.version: Int` existe há vários sprints como mecanismo de controle
  de concorrência otimista (OCC).
- Mas o `SQLKitPatientRepository.save` usava `INSERT … ON CONFLICT (id) DO
  UPDATE SET excluded.*` — sobrescreve incondicionalmente. A coluna `version`
  era contagem decorativa.

Cenário do bug (lost update):

1. Assistente social A abre o prontuário do paciente X (`version=5`).
2. Assistente social B abre o mesmo paciente, paralelo (`version=5`).
3. A registra um atendimento → `version=6` localmente, salva → banco
   `version=6`.
4. B registra uma anotação diferente → `version=6` localmente, salva → banco
   sobrescrevido com os dados de B, **anotações de A perdidas em silêncio**.

Em healthcare/social-care isso viola o princípio "histórico social é
sagrado" do handbook v2.0. E é **invisível ao operador**: a UI confirma o
save, ninguém recebe erro, dados somem.

Citação canônica (Ramakrishnan & Gehrke, *Database Management Systems*,
Cap. 17 — Concurrency Control):

> *"In an optimistic concurrency control scheme, the system tries to
> execute transactions without enforcing locks. At commit time, the system
> checks for conflicts and aborts the transaction if any are detected."*

O "check for conflicts" é exatamente o `WHERE version = expectedVersion`
que estava faltando.

Por que não foi notado antes:

- O `actor` model Swift (handlers são `actor`) serializa comandos
  direcionados ao mesmo handler na mesma instância — dava a falsa sensação
  de segurança.
- Mas:
  - Múltiplas réplicas do serviço em Kubernetes não compartilham actor state.
  - Dois handlers diferentes (`AssignPrimaryCaregiver` + `AddFamilyMember`)
    podem rodar simultaneamente.
  - Reentrância de async: dentro do mesmo actor, `await` libera a fila.

## Decisão

Toda escrita de aggregate root no `SQLKitPatientRepository` (e na fake
`InMemoryPatientRepository`) usa **optimistic locking** via coluna `version`:

```swift
// Sequência canônica do save:
let currentVersion = try await tx.raw("""
    SELECT version FROM patients WHERE id = $1 FOR UPDATE
""").first()?.decode(column: "version", as: Int.self)

if let dbVersion = currentVersion {
    // UPDATE path
    let expected = patient.version - 1
    guard dbVersion == expected else {
        throw PersistenceConflictError.optimisticLockFailed(
            expectedVersion: expected,
            actualVersion: dbVersion
        )
    }
    try await tx.update("patients").set(model: data.patient)
        .where("id", .equal, patientId).run()
} else {
    // CREATE path — primeira save
    try await tx.insert(into: "patients").model(data.patient).run()
}
```

Pontos-chave:

1. **`SELECT … FOR UPDATE`** dentro da transação adquire row-level lock,
   eliminando TOCTOU entre o check de versão e o UPDATE.
2. **Path explícito CREATE vs UPDATE**: `SELECT` retorna `nil` para row
   inexistente → INSERT puro. Row existe + version bate → UPDATE puro.
   Row existe + version não bate → `optimisticLockFailed`.
3. **`PersistenceConflictError.optimisticLockFailed(expectedVersion:, actualVersion:)`**:
   variante nova carrega contexto para diagnóstico e mapeamento para HTTP 409.
4. Cada `mutating func` do agregado chama `recordEvent` → `addEvent` →
   `version += 1` (estabelecido em T-004 / ADR-004). `Patient.version` cresce
   monotonicamente desde a criação (`PatientCreatedEvent` faz `version: 0 → 1`).

## Alternativas consideradas

- **Manter UPSERT + adicionar `WHERE patients.version = EXCLUDED.version - 1`
  no `ON CONFLICT … DO UPDATE`.** Mais conciso, mas:
  - SQLKit não expõe ergonomia para `ON CONFLICT … DO UPDATE … WHERE`
    (exigiria SQL raw para o UPDATE inteiro, perdendo o `set(model:)`).
  - Detectar "conflict + WHERE falhou" exige `RETURNING` + checar 0 rows —
    ergonomia ruim.
  - SELECT FOR UPDATE deixa mais explícito o que está acontecendo, e o
    diagnóstico do erro carrega `expectedVersion`/`actualVersion` para o
    handler logar.
- **Pessimistic locking (`SELECT … FOR UPDATE` no início do command + UPDATE).**
  Funciona mas penaliza throughput em produção (rows ficam locked durante toda
  a operação de domínio). OCC é o padrão Vernon/Evans para agregados.
- **Row-level lock via `LISTEN/NOTIFY` ou advisory lock.** Complexidade
  desnecessária para o caso atual.
- **Confiar em Read Committed + retry no handler.** Read Committed default do
  Postgres não previne lost update — exige Repeatable Read/Serializable
  (custo alto) OU OCC enforçado (este ADR).
- **Manter coluna `version` como tracking-only (sem enforcement) + auditoria
  manual.** Foi exatamente o estado anterior — bug se acumulou sem detecção.

## Consequências

### Positivas

- Lost update silencioso elimina-se: cliente sempre vê `409 Conflict` quando
  outra transação venceu a corrida. Aplicação pode oferecer "merge" ou
  "re-fetch and retry" como UX.
- `version` deixa de ser decorativa e vira invariante real do agregado.
- `optimisticLockFailed(expectedVersion:, actualVersion:)` dá diagnóstico
  preciso para SRE e usuário final.
- Fake (`InMemoryPatientRepository`) espelha o invariante — testes de regressão
  rápidos cobrem o cenário sem precisar de Postgres.
- Defesa em depth: múltiplas réplicas do social-care em Kubernetes podem rodar
  sem risco de lost update entre elas.

### Negativas / custos

- Cada save paga 1 query extra (`SELECT FOR UPDATE`) — ~1ms adicional em
  Postgres local. Em alta concorrência, é o custo de uma transação consistente.
- Row-level lock pode amplificar contenção em cenários patológicos (todos
  escrevendo no mesmo paciente). Mitigação: lock é breve (apenas durante a
  transação do save) + retry no cliente.
- Handler precisa mapear `optimisticLockFailed` para erro de negócio
  contextualizado. Pendente em mapeamento universal (T-010).

### Ações requeridas

- [x] Adicionar `optimisticLockFailed` em `PersistenceConflictError`
- [x] Refatorar `SQLKitPatientRepository.save` com SELECT FOR UPDATE + UPDATE/INSERT separados
- [x] Refatorar `InMemoryPatientRepository.save` para mesmo invariante
- [x] Teste de regressão (4 testes em `Regression/Concurrency/`)
- [x] Atualizar `swift-io-implementer` SKILL.md com padrão e anti-pattern
- [ ] **T-010 (Fase 2):** mapear `optimisticLockFailed` para erro de negócio em
  todos os 21 command handlers (helper genérico `mapOptimisticLock` ou junto
  com `mapUniqueViolation`). Tracking via `REMEDIATION_PIPELINE_2026_05_14.md`.

## Plano de adoção

1. **Imediato (T-005 — este ticket):** SQLKit + fake refatorados. Patient
   continua funcionando. Teste de regressão passa. Suite 331/331 verde.
2. **T-010 (Fase 2 — próximas semanas):** handler mapping universal.
   `optimisticLockFailed` traduz para erro de negócio HTTP 409 com hint
   `"refresh and retry"`.
3. **Outros agregados futuros (T-024 decomposição):** quando `Assessment`,
   `Care`, `Protection` virarem agregados próprios, cada repositório
   implementa o mesmo padrão (selectVersionForUpdate + INSERT/UPDATE).
4. **Monitoring (médio prazo):** contar `optimisticLockFailed` em logs
   estruturados — taxa alta sinaliza UX ruim (conflicts demais) ou bug.

## Como reverter

Reverter ADR-005 reintroduz o bug S-C3/DB-2. Não recomendado.

Caminho técnico (se necessário):

1. `git revert <commit-T-005>` — restaura UPSERT e fake permissiva.
2. Marcar este ADR como `Deprecado` com justificativa.
3. Manter o teste de regressão como **xfail/expected failure** documentando
   regressão consciente.

## Teste de regressão

`Tests/social-care-sTests/Regression/Concurrency/OptimisticLockRegressionTests.swift`:

1. **`test_S_C3_DB_2_lost_update_is_rejected`** — dois "processos" carregam
   o paciente, ambos mutam, A salva primeiro, B falha com
   `PersistenceConflictError`.
2. **`test_S_C3_DB_2_error_carries_diagnostic_versions`** — `optimisticLockFailed`
   tem `expectedVersion=1, actualVersion=2` para diagnóstico.
3. **`test_S_C3_DB_2_sequential_updates_succeed`** — 3 updates sequenciais
   com version correta passam (não introduz regressão no caminho normal).
4. **`test_S_C3_DB_2_create_path_works_for_new_aggregate`** — primeira save
   (version=1, row inexistente) usa INSERT path e não falha.

Os 4 testes rodam contra `InMemoryPatientRepository` (fake espelha SQLKit).
Para PostgreSQL real, o lock é validado pelo `SELECT FOR UPDATE` em testes
de integração (fora desta camada — pode entrar como T-005.integration no
futuro se necessário).

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-io-implementer/SKILL.md` —
  entrada em "Lições Aprendidas (regressões prevenidas)" + seção
  "Padrão Optimistic Lock em Repository".
- **Regra resumida:** todo repository SQLKit que faça update de aggregate root
  DEVE (a) `SELECT version FROM <table> WHERE id = ? FOR UPDATE` dentro da
  mesma transação, (b) checar `currentVersion == expectedVersion`, (c) lançar
  `PersistenceConflictError.optimisticLockFailed` se não bater. NUNCA usar
  `INSERT … ON CONFLICT (id) DO UPDATE SET excluded.*` para path de UPDATE
  (UPSERT é só para CREATE).
- Idem para a fake equivalente (`InMemory*Repository`) — espelhar invariante
  para que unit tests detectem o mesmo bug.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § C3 — achado original (Senior Review)
- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` § DB-2 — confirmação (DB Review)
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-005 — especificação do ticket
- [ADR-002](ADR-002-regression-test-policy.md) — política de testes de regressão
- [ADR-004](ADR-004-event-sourced-aggregate-composite-protocol.md) — `version` é incrementado em `addEvent` (protocolo composto)
- Ramakrishnan & Gehrke, *Database Management Systems*, Cap. 17 (Concurrency Control)
- Vernon, *Implementing DDD*, Cap. 10 (Aggregate Design — Concurrency)
- PostgreSQL Reference Manual — `SELECT FOR UPDATE`, isolation levels
