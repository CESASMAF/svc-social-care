# cerbos-guard-tests · W3 — QUALITY (quality-checker)

**Status:** DONE · **Veredito:** PASSED · **Data:** 2026-07-28

## Gates

| Gate | Resultado |
|---|---|
| `swift build --build-tests` | ✅ sem erros |
| `swift test` | ✅ **477 testes em 87 suites, todos passando** |
| Testes do ticket | ✅ 13/13 |
| `swift build -c release` | ✅ exit 0 · 27 warnings, **nenhum dos arquivos do ticket** (pré-existentes) |

## Verificação de comportamento

| Cenário | Esperado | Verificado |
|---|---|---|
| Ação do controller × policy | todas existem | ✅ (3 camadas de defesa) |
| PDP responde ALLOW | segue | ✅ |
| PDP responde DENY | 403 **e handler não executa** | ✅ |
| PDP fora do ar (502) | `nil` → defere ao RoleGuard | ✅ |
| Resposta malformada | `nil`, nunca `false` | ✅ |
| `CERBOS_URL` ausente | pass-through | ✅ |

## Validação externa (manual, fora do CI)

Cerbos 0.53.0 real na x99 com as policies do repo `infra`: confirmou `read`/`create`
como **EFFECT_DENY** e `list`/`register`/`admit` como **EFFECT_ALLOW**. Container e
policies temporárias removidos ao fim.

## Pendências registradas (não bloqueiam)

1. **Contrato por cópia** — o teste espelha a policy em vez de lê-la (repos
   separados). Follow-up: artefato versionado de ações ou job de integração com
   Cerbos real.
2. **Granularidade por rota** — hoje 3 ações representativas para 12 rotas.
3. **Kodus vermelho neste PR** — mesma causa já diagnosticada (`KODUS_TEAM_KEY`
   ausente na org). A remoção do job foi para a branch `fix/anonymous-401-log-noise`;
   ao rebasear nesta branch ou ao mergear aquela primeiro, o check some.
