# ADR-010: Mapeamento universal de PersistenceConflictError nos handlers

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** um ADR só pode ficar `Aceito`
> quando **todas** as seções abaixo estão preenchidas — incluindo `Teste de
> regressão` e `Better Pattern para skills`. ADR sem essas duas seções fica
> `Proposto` até completar.

## Contexto

Achado **S-C6** (Senior Code Review § Achado C6): dos **21 command handlers**, apenas **1** (`RegisterPatientMapperError`) mapeava `PersistenceConflictError.uniqueViolation` para erro de negócio HTTP 409. Os outros 20 deixavam o erro genérico vazar:

- Cliente HTTP recebia **500 Internal Server Error** com `persistenceMappingFailure`.
- Mensagem nesse erro genérico tipicamente expõe `String(describing: error)` que pode incluir constraint name, schema, payload truncado — leak de informação interna.
- Cliente não recebe hint para corrigir (ex: "esse CPF já existe — escolha outro").

`CLAUDE.md` é explícito sobre o invariante:

> *"`PersistenceConflictError.uniqueViolation`: repositórios lançam este erro genérico para violações de unicidade; o handler de Application mapeia para o erro de negócio específico."*

Mas o invariante existia só na documentação — sem **enforcement**. Conforme novos handlers eram criados (T-024 decomposição vai criar mais ainda), nenhum dev/IA via lembrete e a regra ficava letra morta.

Citação canônica:

> *"Tratamento de erro é uma coisa só."* — Robert C. Martin, *Código Limpo*, p. 48

Cada handler é responsável por traduzir erros de baixo nível (banco) em erros de alto nível (negócio). Sem helper compartilhado, cada um reinventa a estrutura `if case .uniqueViolation(let constraint, _)` — DRY violado, e **20 dos 21 esquecem**.

## Decisão

Duas peças complementares:

### 1. Helper genérico em `shared/Error/PersistenceConflictMapping.swift`

```swift
public extension PersistenceConflictError {
    /// Mapeia .uniqueViolation para erro de negócio via constraint name.
    func mapUniqueViolation<E: Error>(_ mapping: (String) -> E?) -> E? {
        guard case .uniqueViolation(let constraint, _) = self else { return nil }
        return mapping(constraint)
    }

    /// Mapeia .optimisticLockFailed (ADR-005) com expected/actual versions.
    func mapOptimisticLockFailed<E: Error>(_ mapping: (Int, Int) -> E?) -> E? {
        guard case .optimisticLockFailed(let exp, let act) = self else { return nil }
        return mapping(exp, act)
    }
}
```

### 2. Retrofit nos 21 handlers

Cada `*MapperError.swift` recebe um bloco padronizado **logo após o early-return** do erro do próprio caso de uso:

```swift
public func mapError(_ error: Error, ...) -> XError {
    if let e = error as? XError { return e }

    // ADR-010: PersistenceConflictError universal.
    if let conflict = error as? PersistenceConflictError {
        // Handlers com unique constraint de negócio fazem mapping específico:
        if let mapped: XError = conflict.mapUniqueViolation({ constraint in
            switch constraint {
            case "uq_meu_constraint": return .meuErroDeNegocio
            default: return nil
            }
        }) { return mapped }

        // Fallback: preserva detail no erro genérico
        return .persistenceMappingFailure(issues: [String(describing: conflict)])
    }

    // ... outros mappings de domínio
}
```

Para handlers de **lifecycle** (Discharge, Admit, Readmit, Withdraw — assinatura `-> any Error`), o tratamento é simplesmente propagar o conflict sem mascarar:

```swift
if error is PersistenceConflictError { return error }
```

Esse padrão deixa o erro original visível para o caller (Controller), que pode mapear para `AppError` apropriado via middleware de erros.

### 3. Lint test em `Regression/ErrorMapping/`

Teste estrutural percorre todos os `*MapperError.swift` da Application e **falha** se algum não cita `PersistenceConflictError`. Próximo handler novo escrito sem o tratamento é bloqueado em CI.

## Alternativas consideradas

- **Manter cada handler reinventando o tratamento.** Descartada — exatamente o que motivou o ADR. 20/21 esqueciam.
- **Adicionar `mapPersistenceConflict` como método required em um protocolo `MapperError`.** Considerada. Descartada porque exigiria refactor maior em todos os handlers + padrão de protocolos com associated types complexo. Helper extension é mais ergonômico.
- **Tratar `PersistenceConflictError` no `AppErrorMiddleware` (camada IO).** Descartada — middleware HTTP não conhece o contexto de negócio (qual unique constraint = qual erro). Tradução pertence ao handler que tem o contexto.
- **Mapping específico de constraint para todos os 21 handlers já neste ticket.** Descartada por escopo — handlers que NÃO têm unique constraint de negócio próprio (e.g. UpdateHealthStatus que só faz update do agregado) recebem fallback genérico. Mappings específicos podem evoluir incrementalmente nos tickets de feature.

## Consequências

### Positivas

- 21/21 handlers tratam `PersistenceConflictError` — bug S-C6 eliminado universalmente.
- Helper centralizado (~30 linhas) substitui duplicação espalhada.
- Lint test impede regressão silenciosa em handler novo.
- Caminho claro para evolução: handlers que ganharem unique constraint de negócio adicionam apenas um `case` no switch interno.
- `mapOptimisticLockFailed` (ADR-005) ganha helper paralelo — preparação para T-024 quando outros agregados usarem optimistic lock.

### Negativas / custos

- Boilerplate adicional ~5-7 linhas por handler. Mitigação: padrão único, fácil de copiar.
- Fallback `persistenceMappingFailure` ainda devolve HTTP 500 quando o constraint é desconhecido — não resolve o problema subjacente, só formaliza o tratamento. Mitigação: handlers de feature evoluem mapping específico conforme necessário.
- Helper `mapUniqueViolation` aceita closure que pode ser confusa para devs novos. Mitigação: doc no helper + exemplos no SKILL.

### Ações requeridas

- [x] Criar `shared/Error/PersistenceConflictMapping.swift`
- [x] Retrofit em 21 handlers (1 já tinha — RegisterPatient; 20 novos blocos)
- [x] Lint test estrutural em `Regression/ErrorMapping/`
- [x] ADR-010 + entrada na skill `swift-application-orchestrator`
- [ ] **Médio prazo (tickets de feature):** handlers ganham mapping específico por constraint conforme regras de negócio surgirem (ex: `family_members_pkey` → `memberAlreadyExists` no AddFamilyMember já está aplicado).
- [ ] **T-024 (decomposição):** novos agregados (Assessment, Care próprios) seguem o mesmo padrão desde a criação.

## Plano de adoção

1. **Imediato (T-010 — este ticket):** helper criado + 21 handlers atualizados + lint test passa. Suite 357/357 verde.
2. **Próximos PRs:** novo handler escrito automaticamente segue o padrão (skill swift-application-orchestrator carrega o template).
3. **Auditoria periódica:** lint test roda em CI a cada PR — handler novo sem tratamento é bloqueado.

## Como reverter

Reverter ADR-010 reintroduz S-C6 — handlers vazando 500 genérico em conflito de unicidade.

Caminho técnico:
1. Deletar `shared/Error/PersistenceConflictMapping.swift`
2. Remover blocos `if let conflict = error as? PersistenceConflictError` dos 21 handlers
3. Remover lint test
4. Marcar este ADR como `Deprecado`

Não recomendado.

## Teste de regressão

`Tests/social-care-sTests/Regression/ErrorMapping/UniqueViolationMappingRegressionTests.swift`:

1. **`test_S_C6_helper_runtime_works`** — `mapUniqueViolation` retorna mapped quando constraint bate, nil para constraint desconhecido, nil para variante diferente.
2. **`test_S_C6_optimistic_lock_helper`** — `mapOptimisticLockFailed` retorna mapped com versions, nil para variante diferente.
3. **`test_S_C6_all_handlers_handle_conflict`** — lint estrutural percorre todos os `*MapperError.swift` na Application e falha se algum não cita `PersistenceConflictError`/`mapUniqueViolation`/`uniqueViolation`.

3/3 passam após retrofit. Falhavam antes (lint listava 18 mappers ausentes).

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-application-orchestrator/SKILL.md` — entrada em "Lições Aprendidas (regressões prevenidas)".
- **Regra resumida:** TODO `*MapperError.swift` que serve handler com `repository.save` ou outra operação de persistência DEVE incluir bloco `if let conflict = error as? PersistenceConflictError { ... }`. Para cases conhecidos, usar `conflict.mapUniqueViolation { constraint in ... }` para mapping de negócio. Fallback `persistenceMappingFailure(issues:)` preserva detail. Lint test no Regression/ErrorMapping/ enforça.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § C6 — origem
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-010 — especificação
- [ADR-002](ADR-002-regression-test-policy.md) — política de testes de regressão
- [ADR-005](ADR-005-optimistic-locking-via-version.md) — `mapOptimisticLockFailed` companheiro
- Robert C. Martin, *Código Limpo*, cap. 7 (Tratamento de erros) e p. 48 (princípio "tratamento de erro é uma coisa só")
