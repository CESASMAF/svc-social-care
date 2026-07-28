# anonymous-401-observability · W0 — RED (swift-test-writer)

**Status:** DONE · **Data:** 2026-07-28

## Objetivo

Fixar por teste o que o PR #3 mudou e o que o code review pediu. O PR entrou sem
nenhum teste: nem o 401, nem — o que de fato importa — a **ausência do log de
erro**, que é a razão de existir da mudança.

## Arquivo

`Tests/social-care-sTests/IO/Auth/AnonymousAccessObservabilityTests.swift` (novo,
6 casos, `.serialized` por compartilhar o contador singleton).

| Teste | Fixa o quê |
|---|---|
| `anonymousRequestIsUnauthorized` | comportamento: sem Bearer → 401 |
| `anonymousRequestEmitsNoErrorLevelLog` | **o teste central**: nenhum registro `level >= .error` é emitido. Sem ele, remover o guard num refactor traria o ruído de volta em silêncio |
| `anonymousRequestIsCounted` | a tentativa é contabilizada (observabilidade) |
| `anonymousAccessLogsOnMilestonesOnly` | log em marcos `[true, true, false, true, false, false, false, true]` — 1, 2, 4, 8 |
| `milestoneCarriesRunningTotal` | o marco carrega o total acumulado; sem isso o alerta não é acionável |
| `resetClearsCounter` | isolamento entre execuções |

## Test doubles

- `LogCollector` + `CollectingLogHandler` — capturam os registros para que o teste
  afirme sobre o **nível** emitido, não só sobre o status code. Injetados via
  `Request(logger:)`, sem tocar no `LoggingSystem` global (que é bootstrap único
  por processo e criaria acoplamento entre suites).
- `PassthroughResponder` — representa "a rota foi alcançada".

## Verificação RED

```
error: cannot find 'AnonymousAccessMonitor' in scope  (4 ocorrências)
```

Falha de compilação por símbolo inexistente — nenhum teste passa sem
implementação.

## Nota de design

O par `anonymousRequestEmitsNoErrorLevelLog` + `anonymousAccessLogsOnMilestonesOnly`
é o que impede as duas regressões opostas: voltar a logar em `error` (ruído) ou
silenciar por completo (cegueira). Um teste sozinho admitiria o outro extremo.
