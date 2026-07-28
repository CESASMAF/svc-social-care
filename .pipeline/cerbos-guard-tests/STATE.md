# cerbos-guard-tests Pipeline State

| Wave | Agent | Status | Started | Completed |
|------|-------|--------|---------|-----------|
| W0 | swift-test-writer (RED) | DONE | 2026-07-28 | 2026-07-28 |
| W1 | implementer (GREEN) | DONE | 2026-07-28 | 2026-07-28 |
| W2 | code-reviewer | DONE (R1: APPROVED) | 2026-07-28 | 2026-07-28 |
| W3 | quality-checker | DONE (PASSED) | 2026-07-28 | 2026-07-28 |

## Notes

- Origem: PR #2 entregou 167 linhas de wiring Cerbos sem nenhum teste.
- **A investigação achou um bug crítico**: o controller pedia as ações `read` e
  `create`, que não existem na policy. Cerbos é default deny → 9 das 12 rotas de
  paciente responderiam 403 assim que `CERBOS_URL` fosse definido. Provado contra
  Cerbos 0.53.0 real na x99.
- Correção: `PatientPolicyAction` (enum espelhando a policy) + init tipado no
  middleware + ações corrigidas para `list`/`register`/`admit`.
- Três camadas contra a regressão: compilador, teste de contrato (enum × policy) e
  lint estrutural sobre o fonte do controller.
- 477 testes verdes; nenhum warning novo no release.
- COMPLETE
