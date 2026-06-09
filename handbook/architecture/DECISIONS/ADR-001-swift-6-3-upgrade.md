# ADR-001: Upgrade para Swift 6.3

**Data:** 2026-05-14
**Status:** Aceito
**Supersedes:** —

## Contexto

`Package.swift` declarava `swift-tools-version: 6.2` enquanto o Dockerfile
de produção já usava `swift:6.3-jammy`. O descompasso significava:

- Build local em macOS rodava com Swift 6.2.3, enquanto CI/produção
  rodava em Swift 6.3 — janela para "funciona local, quebra no CI".
- Swift 6.3 (2026-03) trouxe SwiftBuild preview opcional, C interop via
  plugin, `swift package show-traits` e ajustes em symbol-graph.
- Swift 6.3.1 (2026-04) fixa stack-allocation em `swift_asyncLet_finish`
  ("freed pointer was not the last allocation") — crítico para handlers
  com `async let` paralelos (parse + validação em `RegisterPatient`).
- Swift 6.3.2 (release mais recente) traz fixes adicionais em diagnostics
  e barrier sequence trimming.

Adicionalmente, `swift-testing` era declarada como dependência externa em
`Package.swift`. A partir de Swift 6.0 ela vem embutida no toolchain;
manter como dep externa funcionava em 6.2 mas é **proibido no SPM 6.3** —
trait system novo rejeita "default traits disabled on a package that
declares no traits".

## Decisão

1. **Bumpar `swift-tools-version: 6.2` → `6.3`** no `Package.swift`.
2. **Remover `swift-testing`** da lista de `dependencies` e do testTarget.
   Testes continuam funcionando com `import Testing` (módulo embutido).
3. **Bumpar Vapor `from: "4.0.0"` → `from: "4.118.0"`** (versão que
   estabeleceu Swift 6.0 como mínimo — alinha contrato).
4. **Local dev:** instalar Swift 6.3.2 via Swiftly e fixar com
   `.swift-version` no repo. Swiftly respeita esse arquivo automaticamente
   ao entrar no diretório.

## Alternativas consideradas

- **Manter Swift 6.2 e reverter Dockerfile para `swift:6.2-jammy`:**
  descartado. Aceitar a versão mais antiga atrasa fix do `async let` e
  perde melhorias do toolchain.
- **Pular para Swift 6.4 (próxima):** ainda não lançada estavelmente em
  2026-05-14. Manter na 6.3.2 estável.
- **Manter `swift-testing` como dep externa fixando em 6.2.x:** funciona
  no curto prazo, mas vira blocker assim que o toolchain 6.3 for canônico
  no CI. Custo maior depois.

## Consequências

**Positivas:**

- Local e produção alinhados no mesmo toolchain (6.3.x).
- `async let` em handlers ganha fix do compilador 6.3.1.
- `swift-testing` segue automaticamente o que o toolchain entrega — sem
  pin manual para upgradear.

**Negativas / custos:**

- Devs precisam instalar Swift 6.3.x localmente (`swiftly install 6.3.2`).
  Mitigado pelo `.swift-version` que orienta o Swiftly.
- `Package.resolved` foi regenerado (versões transitivas podem ter movido
  para releases mais recentes — revisar diff antes de mergear).

**Ações requeridas (todas concluídas):**

- [x] Bump `swift-tools-version` no `Package.swift`.
- [x] Remover dep externa `swift-testing` + entry no testTarget.
- [x] Bump `vapor` `from:` para 4.118.0.
- [x] Apagar e regenerar `Package.resolved`.
- [x] Atualizar `CLAUDE.md` (raiz + social-care).
- [x] Atualizar agent/skills (`swift-orchestrator`, `swift-expert`).
- [x] Verificar via Swiftly que `.swift-version` ativa 6.3.2 no diretório.

## Plano de adoção

Concluído na própria sessão de criação deste ADR. Para outros devs do time:

1. Instalar Swiftly se ainda não tiver: `curl -O https://download.swift.org/swiftly/darwin/swiftly.pkg && installer -pkg swiftly.pkg -target CurrentUserHomeDirectory && ~/.swiftly/bin/swiftly init --quiet-shell-followup`.
2. Entrar no diretório `social-care/`. Swiftly detecta `.swift-version` e
   pede para instalar 6.3.2 se ausente.
3. `swiftly install 6.3.2` (~500 MB).
4. `make ci` para validar build + tests.

## Como reverter

Caso 6.3.x apresente regressão bloqueante:

1. Reverter este commit (`git revert <hash>`).
2. `rm Package.resolved && swift package resolve` com toolchain 6.2.
3. Reverter Dockerfile para `swift:6.2-jammy` (verificar tag exata em
   `ghcr.io/swiftlang`).
4. Comunicar no time — fix do `async let` deixa de aplicar.

## Referências

- [Swift 6.3 Release Notes (SPM)](https://github.com/swiftlang/swift-package-manager/blob/main/Documentation/ReleaseNotes/6.3.md)
- [Announcing Swift 6.3.1 — forums.swift.org](https://forums.swift.org/t/announcing-swift-6-3-1/86080)
- [swift-testing releases](https://github.com/swiftlang/swift-testing/releases)
- `handbook/architecture/IMPROVEMENT_BACKLOG.md` — backlog de propostas
  ainda não promovidas a ADR.
