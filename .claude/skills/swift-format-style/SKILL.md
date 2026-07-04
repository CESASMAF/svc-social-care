---
name: swift-format-style
description: >
  Aprofundamento técnico (horizontal) das APIs modernas de FormatStyle aplicado
  ao backend `social-care` — formatação de números, datas, durações, medidas,
  listas, nomes, byte counts e URLs via `.formatted()` em vez de `Formatter`
  legado ou `String(format:)`. Foco server-side: serialização de respostas JSON,
  logs e relatórios. Use para escolher/revisar estilo de formatação de valores.
license: MIT
metadata:
  author: Anton Novoselov
  version: "1.1-social-care"
---
# Swift FormatStyle — aprofundamento técnico (social-care)

> **Contexto deste serviço:** `social-care` é backend Swift 6.3 / Vapor — **sem
> UI**. FormatStyle aqui serve **serialização de resposta**, **logs** e
> **relatórios**, não `Text` de SwiftUI. Pontos de atenção do projeto:
>
> - **Datas no boundary HTTP/SQL são ISO-8601.** O encoder/decoder canônico é porta única `JSONCodec.encoder`/`.decoder` em `shared/JSON/` com `.iso8601` em ambos (ADR-022) — não reconfigure formatação de data ad-hoc por endpoint.
> - **Tipos temporais:** instante operacional → `TIMESTAMPTZ`; data conceitual sem hora (`birth_date`, `diagnosis.date`) → `DATE` (ADR-022). Formate conforme a semântica, não "tudo como datetime".
> - **Dinheiro é `Money` (`centavos: Int64`)**, nunca `Double` (ADR-009 do domain-modeler). Converta para apresentação só no boundary (`valorReal`); use `Decimal` + `.currency` na borda, nunca `Float`/`Double` em cálculo.
> - **PII em log/JSON** segue `LogSanitizer` / `safeContext` (ADR-017) — formatar não é desculpa para vazar CPF/NIS.
>
> A seção `references/swiftui.md` foi **removida** (irrelevante para este
> backend). Esta skill é horizontal; em conflito, **ADRs do projeto prevalecem**.

Escreva e revise código que formata valores, garantindo APIs modernas de
FormatStyle em vez de `Formatter` legado ou formatação C-style.

## Review process

1. Substitua padrões legados por FormatStyle moderno — `references/anti-patterns.md`.
2. Valide número/percent/currency — `references/numeric-styles.md`.
3. Valide data/hora — `references/date-styles.md` (alinhe ISO-8601 ao `JSONCodec`/ADR-022).
4. Valide duração — `references/duration-styles.md` (timeouts, janelas de SLA em relatórios).
5. Valide medida/lista/nome/byte count/URL — `references/other-styles.md`.

Para trabalho parcial, carregue só os references relevantes.

## Core Instructions

- **Nunca** use `Formatter` legado: `DateFormatter`, `NumberFormatter`, `MeasurementFormatter`, `DateComponentsFormatter`, `DateIntervalFormatter`, `PersonNameComponentsFormatter`, `ByteCountFormatter`.
- **Nunca** use `String(format:)` C-style para número/data — use `.formatted()` ou o `FormatStyle` direto.
- FormatStyle são **value types thread-safe** — não use `DispatchQueue` para "formatar em background" (e neste backend, estado mutável vai para `actor`, não fila).
- Prefira `.formatted()` para casos simples; `FormatStyle` explícito para configs reutilizáveis/complexas.
- **`Decimal`/`Money`** para valores monetários — nunca `Float`/`Double`. No social-care, o valor vive como `Money` e só vira `Decimal` na apresentação.
- FormatStyle são locale-aware por default. Defina locale explícito só quando precisar de um específico (ex.: `pt_BR` para relatório fixo) diferente do corrente.
- FormatStyle conformam `Codable`/`Hashable` — seguros para armazenar/comparar.

## Exemplo backend (não-UI)

```swift
// Duração de atendimento em relatório (sem String(format:))
let elapsed = Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))

// Renda per capita para um payload de resposta (Money → Decimal só no boundary)
let perCapita: Decimal = financial.perCapita(family).valorReal
let label = perCapita.formatted(.currency(code: "BRL").locale(Locale(identifier: "pt_BR")))

// Data conceitual (DATE) — sem plantar 00:00:00 espúrio
let birth = birthDate.formatted(.iso8601.year().month().day())
```

## Output Format (quando o usuário pede review)

Organize por arquivo. Para cada issue: (1) arquivo + linha(s); (2) nome do
anti-pattern; (3) before/after curto. Pule arquivos sem issues; termine com
resumo priorizado.

## References
- `references/anti-patterns.md` — padrões legados a substituir (`String(format:)`, `DateFormatter`, `NumberFormatter`, etc.)
- `references/numeric-styles.md` — número/percent/currency: rounding, precisão, sinal, notação, escala, agrupamento
- `references/date-styles.md` — data/hora, ISO-8601, relative, verbatim, HTTP, interval, components
- `references/duration-styles.md` — `Duration.TimeFormatStyle`/`UnitsFormatStyle`: patterns, unidades, width, segundos fracionários
- `references/other-styles.md` — measurement, list, person name, byte count, URL e `FormatStyle` custom
