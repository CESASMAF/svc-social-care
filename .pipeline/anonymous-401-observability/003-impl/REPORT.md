# anonymous-401-observability · W1 — GREEN (implementer)

**Status:** DONE · **Data:** 2026-07-28

## Mudanças

### 1. `AnonymousAccessMonitor` (novo)

`Sources/social-care-s/IO/HTTP/Auth/AnonymousAccessMonitor.swift`

Contador thread-safe (`NIOLockedValueBox`, mesmo padrão do `NATSEventSubscriber`)
com marco logarítmico:

```swift
func record() -> (total: UInt64, isMilestone: Bool)
```

`isMilestone` é `true` quando o total é potência de 2 — teste `value & (value - 1) == 0`.
Uma varredura de 100 mil requisições produz ~17 linhas de log, cada uma com o
total acumulado, em vez de 100 mil linhas ou de nenhuma.

### 2. `JWTAuthMiddleware` — o registro sai de `debug`

`debug` é desligado em produção; manter ali significava não ter como responder
"estamos sob varredura?". Agora conta sempre e loga em `notice` **nos marcos**,
com `totalDesdeOBoot` no metadata.

### 3. B3 — saídas 401 unificadas

As três ocorrências de `throw Abort(.unauthorized, reason: Self.unauthorizedReason)`
viraram `throw Self.unauthorized`. O doc comment registra o porquê: a mensagem
genérica é defesa contra oráculo de runtime (AppSec HIGH-B), e centralizar impede
que alguém diferencie as mensagens sem querer e reabra o vazamento.

## Testes W0

6/6 GREEN. Suíte completa: **470 testes em 87 suites**, todos passando.

## Decisão registrada: por que não métrica

O review pediu contador de métrica. O repo **não tem** swift-metrics nem backend
de coleta — introduzir isso seria mudança de infraestrutura, não correção de
achado. O contador em memória + log por marco entrega o sinal hoje, sem
dependência nova, e não impede migrar para swift-metrics depois: o ponto de
instrumentação já está isolado num tipo próprio.
