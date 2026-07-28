# anonymous-401-observability Pipeline State

| Wave | Agent | Status | Started | Completed |
|------|-------|--------|---------|-----------|
| W0 | swift-test-writer (RED) | DONE | 2026-07-28 | 2026-07-28 |
| W1 | implementer (GREEN) | DONE | 2026-07-28 | 2026-07-28 |
| W2 | code-reviewer | DONE (R1: APPROVED) | 2026-07-28 | 2026-07-28 |
| W3 | quality-checker | DONE (PASSED) | 2026-07-28 | 2026-07-28 |

## Notes

- Origem: code review do PR #3 (`fix/anonymous-401-log-noise`), 4 achados.
- O PR estava certo em tirar o registro de `error` (a lib vapor/jwt logava isso em
  toda tentativa anônima) e errado em mandá-lo para `debug`, que é desligado em
  produção — trocou ruído por cegueira.
- Solução: contar sempre, logar em marcos (potências de 2) com o total acumulado.
  Atende os dois lados do OWASP: falha de autenticação é evento que deve ser
  registrado (ASVS 7.1.1), e log irrestrito é vetor de exaustão de recurso.
- O teste central afirma **ausência de log `level >= .error`** — o 401 sozinho
  passaria antes da mudança e não provaria nada.
- W0 RED verificado por falha de compilação.
- 470 testes verdes; nenhum warning novo no build release.
- COMPLETE
