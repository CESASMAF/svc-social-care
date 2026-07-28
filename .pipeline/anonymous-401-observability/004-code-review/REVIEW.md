# anonymous-401-observability · W2 — REVIEW (code-reviewer)

**Status:** DONE · **Veredito:** APPROVED (round 1) · **Data:** 2026-07-28

## Rastreabilidade achado → correção

| Achado | Severidade | Status | Onde |
|---|---|---|---|
| B1 — `debug` cria ponto cego de segurança | 🟠 | **RESOLVIDO** | contagem sempre + `notice` em marcos, com total no metadata |
| B2 — mudança de comportamento sem teste | 🟠 | **RESOLVIDO** | 6 casos, incluindo o que afirma ausência de log `error` |
| B3 — `throw Abort(...)` repetido 3× | 🟡 | **RESOLVIDO** | `Self.unauthorized` |
| B4 — divergência com o upstream | 🔵 | **REGISTRADO** | fora de escopo deste repo; ver nota abaixo |

## Checklist

- [x] `struct` para o middleware, `final class Sendable` para o monitor
- [x] `Sendable` em tipo que cruza concurrency domain (`AnonymousAccessMonitor`)
- [x] Estado mutável protegido por `NIOLockedValueBox` — sem `@unchecked Sendable` no código de produção
- [x] `private` no que não é usado externamente (`counter`, `unauthorized`)
- [x] Booleano soa como asserção (`isMilestone`)
- [x] Nomeação por papel (`AnonymousAccessMonitor`, `record`)
- [x] Docs em API pública, explicando o **porquê** (os dois lados do OWASP: log obrigatório × log como vetor de DoS)
- [x] Zero `try!`, zero `Any`, zero `print`
- [x] Resposta ao cliente inalterada: mesmo 401, mesma razão genérica
- [x] `swift build -c release`: **nenhum warning nos arquivos do ticket**

## Achados do próprio W2

### 1. Contador é por réplica (aceito, documentado)

`AnonymousAccessMonitor.shared` conta no processo. Com N réplicas, cada uma tem
seu contador e seus marcos. Para detecção de varredura distribuída, a agregação é
trabalho do coletor de logs — o que o serviço precisa garantir é que o evento
**chegue** ao coletor, e agora chega. Documentado no próprio tipo.

### 2. 26 warnings pré-existentes no build release

`swift build -c release` acusa 26 warnings (`try` sem função throwing, uso de
`appendInterpolation(raw:)` deprecado). **Verifiquei um a um: nenhum vem deste
ticket.** O gate do orchestrator pede zero warnings; a dívida é anterior e
corrigi-la aqui afogaria o diff. Fica registrado para um chore.

### 3. Marco logarítmico perde granularidade em volume alto (aceito)

Entre 65.536 e 131.072 ocorrências não há registro novo. É o preço de não inundar
o log; o contador continua exato e disponível. Se um dia houver métrica de
verdade, o monitor é o ponto único a trocar.

## Veredito

**APPROVED.** Os testes fixam as duas regressões opostas (voltar ao ruído,
ou silenciar), e o que não foi feito está registrado com a razão.
