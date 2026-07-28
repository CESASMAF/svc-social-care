# anonymous-401-observability · W3 — QUALITY (quality-checker)

**Status:** DONE · **Veredito:** PASSED · **Data:** 2026-07-28

## Gates

| Gate | Resultado |
|---|---|
| `swift build --build-tests` | ✅ sem erros |
| `swift build -c release` | ✅ exit 0 · 26 warnings **todos pré-existentes** (verificado arquivo a arquivo após recompilação forçada dos arquivos do ticket) |
| `swift test` | ✅ **470 testes em 87 suites, todos passando** |
| Testes do ticket | ✅ 6/6 |

## Verificação de comportamento

| Cenário | Esperado | Verificado |
|---|---|---|
| Sem Bearer | 401 | ✅ |
| Sem Bearer | nenhum log `level >= .error` | ✅ |
| Sem Bearer | contabilizado | ✅ |
| 8 ocorrências | log nas de nº 1, 2, 4 e 8 apenas | ✅ |
| Marco | carrega o total acumulado | ✅ |

## Pendências registradas (não bloqueiam)

1. **swift-metrics** — quando o serviço ganhar backend de métricas, trocar o log
   por marco por um counter. O ponto de instrumentação já está isolado.
2. **26 warnings pré-existentes** no build release — chore separado.
3. **B4: portar o fix para o upstream** (`acdgbrasil/svc-social-care`). O ruído de
   ERROR existe lá igual e o arquivo é tocado pelo PR #34; manter só no fork
   significa carregar a divergência em todo sync.
