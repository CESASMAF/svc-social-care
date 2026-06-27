# ADR-002: Política de Testes de Regressão

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

## Contexto

A revisão senior cross-camada (`handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md`) e a revisão de schema (`handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md`) identificaram ~117 achados, dos quais 14 são CRITICAL. Cada um descreve um bug latente que existe **hoje**, em produção potencial.

O problema é estrutural, não circunstancial: bugs corrigidos sem teste-de-regressão voltam. Os reports em `handbook/reports/CODE_REVIEW_*_2026_03_*.md` já mostram que vários achados antigos foram corrigidos, mas alguns reapareceram em forma ligeiramente diferente (e.g. force-unwrap saiu de `SQLKitPatientRepository.swift` linha 61 em março, voltou em outro local em maio).

A causa raiz é a ausência de **mecanismo permanente** que enforce a correção. PR review pega no momento, mas não escala: 3 meses depois, alguém escreve código novo e regrede sem perceber.

Adicionalmente, este projeto vai usar IA-gerada (Claude Code + skills) cada vez mais para implementação. Sem testes que descrevam o invariante específico, IA não tem como saber que "este pattern já deu errado uma vez".

## Decisão

Toda fix de achado de severidade **HIGH** ou **CRITICAL** documentado em report DEVE ser acompanhada de teste de regressão antes do merge.

Os testes vivem em `Tests/social-care-sTests/Regression/`, organizados em 6 subpastas por classe de bug:

- `Concurrency/` — race conditions, lost updates, outbox duplication
- `DataIntegrity/` — PK/FK/types ausentes, 1NF, CHECK constraints
- `EventPublication/` — outbox contract, publish-after-persist, recordEvent
- `Security/` — fail-open, headers, PII em log, JWT bypass
- `DomainInvariants/` — VO state inválido, identidade, Money, force-unwrap
- `ErrorMapping/` — PersistenceConflictError, erro genérico vazando

Cada teste:
1. Carrega o **ID do achado** no nome (`test_S_C3_…` ou `test_DB_2_…`)
2. Reproduz o estado que era aceito antes da fix (assert do bug)
3. Asserta o invariante garantido pela fix
4. Usa `RegressionFixture` em `Application/TestDoubles/` para determinismo

Comando: `make regression` filtra por `swift test --filter "Regression"` e roda em < 10ms (execução pura). Wall-clock incluindo SwiftPM build cache: ~5s a frio.

## Alternativas consideradas

- **Confiar em PR review.** Descartada — não escala. Review pega bugs *novos* específicos, não regressões de bugs antigos que ninguém lembra mais.
- **Tests unitários genéricos.** Descartada — testes unitários cobrem comportamento normal. Testes de regressão cobrem o que *já deu errado* ou *pode dar errado* sob condições específicas (concorrência, schema, segurança). São complementares, não substitutos.
- **Suite único `Regression/` sem subpastas.** Descartada — em 6 meses, com ~80 testes esperados, fica impossível navegar. Subpastas por classe de bug servem como índice mental.
- **Carry-along: cada teste fica perto do código testado.** Descartada — agrupar por classe de bug (não por arquivo testado) facilita auditoria de cobertura ("temos todos os testes de Concurrency necessários?").

## Consequências

### Positivas

- Bugs reportados em handbook/reports/ ganham mecanismo automatizado de não-regressão.
- IA-gerada (Claude Code + skills) pode ler `Regression/<tema>/README.md` para entender invariantes do projeto antes de gerar código.
- Cada teste é auditoria viva: `grep S_C3` localiza o teste, o report e o ADR correspondente.
- `make regression` no pre-commit ou em PR pequeno = sanity check rápido (< 5s wall-clock).

### Negativas / custos

- Suite cresce indefinidamente. Mitigação: tag de CI por subpasta permite rodar só temas relevantes a uma mudança.
- Custo de escrita de teste adiciona ~30% ao tempo de fix de bug.
- Risco de testes flaky se mal desenhados (especialmente `Concurrency/`). Mitigação: `RegressionFixture` centraliza determinismo.

### Ações requeridas

- [x] `Tests/social-care-sTests/Regression/` criado com 6 subpastas + READMEs por subpasta
- [x] `Tests/social-care-sTests/Application/TestDoubles/RegressionFixture.swift` criado
- [x] `make regression` adicionado ao Makefile
- [x] `Tests/social-care-sTests/Regression/RegressionMeta.swift` valida a infra com 5 sentinels
- [ ] Próximos tickets (T-004 em diante) começam pela camada W0 → adicionam teste em `Regression/<subpasta>/` ANTES da fix em `Sources/`
- [ ] Quando o suite passar de 30 testes, considerar tag CI por subpasta

## Plano de adoção

1. **Imediato (T-001 — este ticket):** infra criada e validada. `make regression` retorna 21 testes em 0.007s (5 novos sentinels + 16 testes antigos com "Regression" no nome).
2. **Curto prazo (T-004 a T-019):** cada ticket de Fase 1/2/3 do `REMEDIATION_PIPELINE_2026_05_14.md` adiciona seu teste de regressão antes do GREEN.
3. **Médio prazo (sprint 2-3):** suite cresce para ~25 testes. Avaliar tempo de execução; se > 5s, separar por subpasta.
4. **Longo prazo:** convenção firmada — toda nova fix de bug HIGH/CRITICAL passa pelo `Regression/`. PR sem teste correspondente bloqueado em review.

## Como reverter

Reverter este ADR significaria aceitar que bugs corrigidos podem voltar. Não é recomendado. Se necessário (custo de manutenção excede valor), substituir por ADR posterior que documente nova estratégia (e.g. property-based testing, mutation testing).

Tecnicamente: deletar `Tests/.../Regression/` e remover target `regression` do Makefile.

## Teste de regressão

Identificador: `Tests/social-care-sTests/Regression/RegressionMeta.swift::RegressionMetaTests` — 5 sentinels que validam:

1. `frozenClock` retorna timestamp estável
2. `uuid(seed:)` é determinístico
3. `prepopulatedLookupValidator` aceita IDs registrados e rejeita não-registrados
4. `StubUnitOfWork` executa bloco e propaga retorno
5. `StubUnitOfWork` propaga erro lançado

Esses sentinels garantem que a infra de regressão está discoverable via `make regression` e que `RegressionFixture` funciona.

## Better Pattern para skills

- **Skill atualizada:** `.claude/skills/swift-test-writer/SKILL.md` — adicionada seção "Lições Aprendidas (regressões prevenidas)" + padrão de nomenclatura `test_<ACHADO_ID>_<descrição>()`.
- **Handbook:** `handbook/tooling/swift/testing/regression-pattern.md` — padrão completo de teste de regressão (estrutura, anatomia, anti-patterns).

Regra resumida: todo `@Test` de regressão tem ID do achado no nome, vive em `Tests/.../Regression/<subpasta>/`, e usa `RegressionFixture` para determinismo.

## Referências

- `handbook/reports/SENIOR_CODE_REVIEW_2026_05_14.md` — fonte 1 dos achados
- `handbook/reports/DATABASE_MODELING_REVIEW_2026_05_14.md` — fonte 2 dos achados
- `handbook/reports/REMEDIATION_PIPELINE_2026_05_14.md` — pipeline T-001 a T-038
- Martin, Robert C. *Código Limpo*, cap. 9 (Testes Unitários) — princípio TDD e o ciclo Red-Green-Refactor
- Fowler, Martin. *Refactoring*, 2ª ed. — "Self-Testing Code" como prerequisito para refactoring seguro
