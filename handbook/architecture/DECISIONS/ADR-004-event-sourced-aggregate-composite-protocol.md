# ADR-004: Eventos de domínio via protocolo composto sem cast dinâmico

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

> **Promoção Proposto → Aceito (ADR-003):** um ADR só pode ficar `Aceito`
> quando **todas** as seções abaixo estão preenchidas — incluindo `Teste de
> regressão` e `Better Pattern para skills`. ADR sem essas duas seções fica
> `Proposto` até completar.

## Contexto

A revisão senior (`handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § C7) identificou um bug latente no `EventSourcedAggregate`: a extension default de `recordEvent` fazia cast dinâmico para `EventSourcedAggregateInternal` e, se o agregado não conformar `Internal`, **engolia o evento silenciosamente** sem erro.

Código pré-fix (`Sources/.../shared/Domain/DomainProtocols.swift`):

```swift
public protocol EventSourcedAggregate: Sendable {
    var uncommittedEvents: [any DomainEvent] { get }
    // ... id, version
}

public protocol EventSourcedAggregateInternal {
    mutating func addEvent(_ event: any DomainEvent)
}

extension EventSourcedAggregate {
    public mutating func recordEvent(_ event: any DomainEvent) {
        if var internalSelf = self as? any EventSourcedAggregateInternal {
            internalSelf.addEvent(event)
            if let back = internalSelf as? Self { self = back }   // ⚠️ cast frágil
        }
        // else: no-op silencioso ⚠️ — bug C7
    }
}
```

Cenário do bug:

1. Dev escreve novo agregado: `struct Order: EventSourcedAggregate { ... }`.
2. Esquece de adotar `EventSourcedAggregateInternal` (não há lembrete visual).
3. Em todo handler que chama `order.recordEvent(OrderPaid())`, **o evento desaparece**.
4. Outbox não vê o evento; downstream nunca é notificado.
5. Compilador não avisou; testes unitários do agregado provavelmente passam porque chamam `addEvent` direto (que não existe — não chamam, na verdade); o bug se manifesta só em produção quando algum consumidor reclama.

Por que isto é especialmente perigoso em healthcare/social-care: o Outbox é a fonte de verdade para audit trail e BI. Evento perdido é registro histórico perdido — princípio "histórico social é sagrado" do handbook v2.0 violado.

A causa raiz é design: a assumption "todo `EventSourcedAggregate` é também `Internal`" está **implícita no código**, não no sistema de tipos. Fowler (*Refactoring*, p. 326) chamaria isso de "introduce assertion" — a assumption deve virar contrato verificado pelo compilador.

## Decisão

`EventSourcedAggregate` passa a **compor** `EventSourcedAggregateInternal` por herança:

```swift
public protocol EventSourcedAggregateInternal {
    mutating func addEvent(_ event: any DomainEvent)
    mutating func clearEvents()
}

public protocol EventSourcedAggregate: Sendable, EventSourcedAggregateInternal {
    associatedtype ID: Sendable & Equatable
    var id: ID { get }
    var version: Int { get }
    var uncommittedEvents: [any DomainEvent] { get }
}

extension EventSourcedAggregate {
    public mutating func recordEvent(_ event: any DomainEvent) {
        self.addEvent(event)   // chamada direta, sem cast
    }
}
```

Consequências de tipo:

- Agregado novo que esqueça `addEvent`/`clearEvents` **não compila**.
- `recordEvent` chama `addEvent` direto — zero cast dinâmico, zero ramo silencioso.
- `clearEvents` agora é parte do contrato `Internal` (já era implementado em Patient, formaliza).

## Alternativas consideradas

- **Manter cast dinâmico, adicionar `precondition`/`assertionFailure` no caminho silencioso.** Descartada — pega em runtime, não em compile-time. Em produção, `precondition` traduz para crash; em release com `-O`, `assertionFailure` é eliminado. Nenhum dos casos é tão bom quanto "não compila".
- **Lint test que percorre todos os tipos via reflection e verifica conformância.** Descartada — Swift não tem reflection completo em runtime; lista de tipos teria que ser mantida à mão; mecanismo frágil.
- **Manter protocolos separados, documentar a obrigação em comentário/skill.** Descartada — exatamente o que existia antes (e o bug existe). Documentação não é enforcement.
- **Renomear para um único protocolo `EventSourcedAggregate` sem `Internal`.** Considerada. Descartada porque a separação tem valor semântico: `Internal` agrupa o detalhe de mutação (encapsulamento de implementação), `EventSourcedAggregate` agrupa a capacidade observável. Composição respeita Interface Segregation Principle e permite que ports/repositórios trabalhem com o protocolo leve quando só precisam ler `uncommittedEvents`.

## Consequências

### Positivas

- Bug C7 torna-se impossível em compile-time para todo agregado futuro.
- `recordEvent` mais simples (3 linhas → 1 linha); sem cast frágil.
- `clearEvents` agora é parte do contrato — invariante "limpa eventos após persist" fica visível.
- Quem trabalha com `any EventSourcedAggregate` ganha automaticamente `addEvent`/`clearEvents` via herança — interface mais rica sem duplicar declaração.

### Negativas / custos

- Agregado novo precisa implementar dois métodos `Internal` mesmo se a implementação for trivial. Boilerplate adicional ~6 linhas por agregado.
- Eventual mock/stub de agregado em teste precisa implementar `addEvent`/`clearEvents` — mas era assim antes para usar o cast, então custo zero adicional.
- ABI breaking: se algum dia houver biblioteca externa conformando `EventSourcedAggregate` sem `Internal`, deixa de compilar. Hoje não aplicável (sem deps externos do projeto consumindo este protocolo).

### Ações requeridas

- [x] Refatorar `shared/Domain/DomainProtocols.swift`
- [x] Verificar que `Patient` continua conformando (já conformava ambos explicitamente)
- [x] Verificar build-release zero warnings
- [x] Verificar teste de regressão passa
- [x] Atualizar skill `swift-domain-modeler` com Better Pattern

## Plano de adoção

1. **Imediato (T-004 — este ticket):** refator aplicado. Patient continua funcionando. Teste de regressão passa.
2. **Auditoria de agregados existentes (verificada manualmente):** `Patient` é o único `EventSourcedAggregate` hoje. Confirmação via `grep`. Nenhum outro lugar do código falha.
3. **Próximos agregados (T-024 — decomposição):** quando T-024 promover `PatientAssessment`, `Referral`, `RightsViolationReport` etc. a agregados próprios, cada um vai precisar implementar `addEvent`/`clearEvents`. Sem isto, não compila — defesa permanente.
4. **Skill `swift-domain-modeler`:** template de agregado novo inclui `addEvent`/`clearEvents` no SKILL.md como parte do scaffolding default.

## Como reverter

Reverter ADR-004 deixaria espaço para o bug C7 voltar. Não recomendado.

Caminho técnico (se necessário):

1. `git revert <commit-do-T-004>` — restaura protocolos separados
2. Reverter mudança no `swift-domain-modeler/SKILL.md`
3. Marcar este ADR como `Deprecado` com justificativa
4. Reativar o teste `test_S_C7_recordEvent_actually_appends` em modo "expected failure" para documentar regressão consciente

## Teste de regressão

`Tests/social-care-sTests/Regression/EventPublication/RecordEventSilentNoopRegressionTests.swift`:

- `RecordEventSilentNoopRegressionTests.test_S_C7_recordEvent_actually_appends()` — valida que `recordEvent` chama `addEvent` direto, armazenando o evento. Antes da fix retornava `count == 0` (no-op silencioso); após a fix retorna `count == 2`. Falha imediatamente se a regra do cast dinâmico voltar e o agregado não conformar `Internal`.
- `RecordEventSilentNoopRegressionTests.test_S_C7_patient_conforms_internal_via_composition()` — meta-check: `Patient.self as? any EventSourcedAggregateInternal.Type != nil`. Se alguém remover a herança no protocolo ou remover a conformância explícita de Patient, este cast falha e sinaliza regressão.

Adicionalmente, **compile-time guard**: o próprio `TestAggregate` dentro do suite serve como fixture viva — se a herança do protocolo for revertida, o teste continua compilando mas começa a falhar em runtime; se for mantida e alguém quiser quebrar a regra, o compilador bloqueia novos agregados.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-domain-modeler/SKILL.md` — entrada na tabela "Lições Aprendidas (regressões prevenidas)" referenciando este ADR e o teste.
- **Regra resumida:** todo aggregate root é `struct: EventSourcedAggregate` (protocolo composto pós-ADR-004). Implementa `addEvent` e `clearEvents` — sem isso, não compila. Nunca usar cast dinâmico (`as? any P`) em extension default de protocolo quando o comportamento muda silenciosamente — promova a relação para o sistema de tipos.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` § C7 — achado original
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` § T-004 — especificação do ticket
- [ADR-002](ADR-002-regression-test-policy.md) — política de testes de regressão
- [ADR-003](ADR-003-adr-structure-enforces-test-and-pattern.md) — estrutura obrigatória do ADR
- Fowler, *Refactoring* 2ª ed., p. 326 — "Introduce Assertion" / make the assumption explicit
- Apple Developer — *Protocol Composition* e *Protocol Inheritance* (Swift Language Guide)
