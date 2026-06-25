# Review Findings — PRs #8, #9, #10

Consolidado de todos os comentários de Copilot e Kodus AI para correção futura.

---

## PR #8 — feat(registry/discharge)

### F1. Event emite notes raw em vez do trimmed [Copilot]
**File:** `Sources/social-care-s/Domain/Registry/Aggregates/Patient/PatientLifecycle.swift:141`
**Severity:** MEDIUM
**Issue:** `DischargeInfo` faz `notes?.trimmingCharacters(in: .whitespacesAndNewlines)`, mas o `PatientDischargedEvent` recebe o `notes` original (raw) do argumento. Se o assistente social enviar "  texto  ", o state fica "texto" mas o evento fica "  texto  ".
**Fix:** Emitir `info.notes` (já trimmed) no evento em vez de `notes` raw:
```swift
self.recordEvent(PatientDischargedEvent(
    ...
    notes: info.notes,  // usar info.notes em vez de notes
    ...
))
```
**Afeta também:** `withdraw()` com `WithdrawInfo` — mesmo padrão.

### F2. InMemoryPatientRepository.totalCount calculado após cursor [Copilot]
**File:** `Tests/social-care-sTests/Application/TestDoubles/InMemoryPatientRepository.swift:90`
**Severity:** LOW
**Issue:** `totalCount` é calculado depois do filtro de cursor, então diminui em páginas subsequentes. O repo real calcula totalCount antes do cursor/limit.
**Fix:** Computar `totalCount` antes de aplicar cursor:
```swift
let totalCount = patients.count  // ANTES de cursor filter
// ... apply cursor ...
// ... apply limit ...
```

### F3. PatientDatabaseMapper fallback `.active` mascara corrupção [Copilot]
**File:** `Sources/social-care-s/IO/Persistence/SQLKit/Mappers/PatientDatabaseMapper.swift:220`
**Severity:** MEDIUM
**Issue:** `PatientStatus(rawValue: patient.status) ?? .active` silencia valores inválidos no DB. Se o DB tiver "invalid", o paciente é reconstituído como active.
**Fix:** Tratar como erro de consistência:
```swift
guard let status = PatientStatus(rawValue: patient.status) else {
    throw PersistenceError.invalidEnumValue(column: "status", value: patient.status)
}
```

### F4. AuditTrailTests — `try` ausente em HousingCondition/CommunitySupportNetwork [Copilot]
**File:** `Tests/social-care-sTests/IO/AuditTrailTests.swift:81,171`
**Severity:** LOW (FALSO POSITIVO — compila e testa OK, mas Copilot flaggou)
**Status:** Verificar se realmente falta `try`. Os testes passam no CI, então pode ser falso positivo do Copilot.

---

## PR #9 — feat(registry/waitlist)

### F5. Mapper fallback `.active` agora mais perigoso com `.waitlisted` [Copilot]
**File:** `Sources/social-care-s/IO/Persistence/SQLKit/Mappers/PatientDatabaseMapper.swift:222`
**Severity:** MEDIUM
**Issue:** Mesmo que F3, mas agora com 3 estados possíveis. Fallback para `.active` é mais arriscado porque `.waitlisted` é o novo default — um valor corrompido poderia pular a fila de espera.

### F6. readmit() não limpa withdrawInfo [Kodus AI]
**File:** `Sources/social-care-s/Domain/Registry/Aggregates/Patient/PatientLifecycle.swift:156`
**Severity:** MEDIUM
**Issue:** `readmit()` limpa `dischargeInfo = nil` mas não limpa `withdrawInfo`. Se um paciente foi withdrawn (waitlisted->discharged), depois readmitted (discharged->active), o `withdrawInfo` permanece preenchido no agregado reconstituído. Isso é inconsistente — um paciente ativo não deveria ter withdrawInfo.
**Fix:** Adicionar `self.withdrawInfo = nil` em `readmit()`.

### F7. Patient.swift default .waitlisted quebra contrato implícito [Kodus AI]
**File:** `Sources/social-care-s/Domain/Registry/Aggregates/Patient/Patient.swift:88`
**Severity:** LOW (coberto por testes, design intencional)
**Issue:** Mudar o default de `.active` para `.waitlisted` na struct é uma breaking change semântica. Todos os callers que dependiam do default implícito precisaram ser atualizados.
**Status:** Já resolvido — testes foram todos atualizados. Documentar a decisão.

### F8. Kodus: Falta de consentimento LGPD nos handlers [Kodus AI]
**File:** Múltiplos handlers (AdmitPatient, WithdrawFromWaitlist)
**Severity:** INFO (não aplicável no escopo atual)
**Issue:** Kodus flaggou falta de verificação de consentimento explícito e verificação de idade. Este é um concern de produto/compliance, não de código. O consentimento é gerenciado pelo fluxo de registro (RegisterPatient), não por operações de lifecycle.
**Status:** Não acionável — decisão de produto.

### F9. Kodus: Vazamento de PII nas mensagens de erro [Kodus AI]
**File:** `Sources/social-care-s/Application/Registry/WithdrawFromWaitlist/Error/WithdrawFromWaitlistError.swift:26,34`
**Severity:** LOW
**Issue:** Patient ID (UUID) é interpolado nas mensagens de erro. O Kodus considera UUID como PII.
**Fix:** Mover IDs para `context` em vez de interpolar no `message`:
```swift
// Antes:
"Paciente não encontrado: \(id)."
// Depois:
"Paciente não encontrado."
// Com context: ["patientId": id]
```
**Afeta também:** DischargePatientError, ReadmitPatientError, AdmitPatientError — mesmo padrão em todos.

### F10. Kodus: appFailure duplicada em múltiplos error files [Kodus AI]
**File:** Cross-file (AdmitPatientError, WithdrawFromWaitlistError, DischargePatientError, ReadmitPatientError)
**Severity:** LOW (refactor)
**Issue:** A private func `appFailure` e as constantes `bc`/`module` são idênticas em todos os error files. Poderia ser extraída para um helper compartilhado.
**Status:** Refactor futuro — não bloqueia.

### F11. Kodus: HTTPStatus bruto em vez de StandardResponse [Kodus AI]
**File:** `Sources/social-care-s/IO/HTTP/Controllers/PatientController.swift:182,197`
**Severity:** LOW
**Issue:** Os endpoints admit/withdraw retornam `HTTPStatus.noContent` (204) diretamente. Kodus sugere usar `StandardResponse` para consistência com o padrão da API. Porém, 204 No Content por definição não tem body — o padrão está correto para operações de state change.
**Status:** Design choice — 204 é correto para mutations sem retorno de dados.

### F12. Kodus: Inconsistência de estado se eventBus.publish falhar [Kodus AI]
**File:** `Sources/social-care-s/Application/Registry/WithdrawFromWaitlist/Services/WithdrawFromWaitlistCommandHandler.swift:34`
**Severity:** LOW (mitigado pelo Outbox pattern)
**Issue:** Se `eventBus.publish()` falhar após `repository.save()`, o state está salvo mas eventos não foram sinalizados. Na prática, os eventos já foram escritos na tabela `outbox_messages` dentro da transação do `save()`, e o OutboxRelay os processará. O `publish()` explícito é redundante.
**Fix possível:** Remover a chamada `eventBus.publish()` se o Outbox Relay já garante delivery. Ou documentar que é um signal, não a entrega real.

---

## PR #10 — fix(registry): error mappers

### F13. cannotDischargeWaitlisted mapeado para alreadyDischarged [Copilot + Kodus]
**File:** `Sources/social-care-s/Application/Registry/DischargePatient/Error/DischargePatientMapperError.swift:14`
**Severity:** HIGH
**Issue:** `PatientError.cannotDischargeWaitlisted` é mapeado para `DischargePatientError.alreadyDischarged`, que tem mensagem "O paciente já está desligado" — errado! O paciente está waitlisted, não discharged.
**Fix:** Adicionar case dedicado ao `DischargePatientError`:
```swift
case cannotDischargeWaitlisted(String)
// AppError: DISC-007, 409, conflict
// Mensagem: "Paciente em lista de espera não pode ser desligado. Use withdraw."
```
E mapear corretamente:
```swift
case .cannotDischargeWaitlisted:
    return .cannotDischargeWaitlisted(patientId)
```

### F14. cannotReadmitWaitlisted mapeado para alreadyActive [Copilot + Kodus]
**File:** `Sources/social-care-s/Application/Registry/ReadmitPatient/Error/ReadmitPatientMapperError.swift:14`
**Severity:** HIGH
**Issue:** Mesmo problema que F13. `cannotReadmitWaitlisted` vira `alreadyActive` ("O paciente já está ativo") — errado! O paciente está waitlisted.
**Fix:** Adicionar case dedicado ao `ReadmitPatientError`:
```swift
case cannotReadmitWaitlisted(String)
// AppError: READM-005, 409, conflict
// Mensagem: "Paciente em lista de espera não pode ser readmitido. Use admit."
```

### F15. notesRequiredWhenReasonIsOther é unreachable no readmit flow [Copilot]
**File:** `Sources/social-care-s/Application/Registry/ReadmitPatient/Error/ReadmitPatientMapperError.swift:26`
**Severity:** LOW
**Issue:** `Patient.readmit()` nunca cria `DischargeInfo`, então `DischargeInfoError.notesRequiredWhenReasonIsOther` nunca é lançado. O branch é dead code.
**Fix:** Remover o case ou substituir por `return error` para propagar sem mascarar.

### F16. patientIsDischarged/patientIsWaitlisted unreachable no discharge flow [Copilot]
**File:** `Sources/social-care-s/Application/Registry/DischargePatient/Error/DischargePatientMapperError.swift:16`
**Severity:** LOW (defensive code)
**Issue:** `discharge()` lança `.alreadyDischarged` ou `.cannotDischargeWaitlisted` baseado no status, nunca `.patientIsDischarged` ou `.patientIsWaitlisted` (esses vêm de `requireActive()` que não é chamado no discharge flow).
**Status:** Defensive — não causa bugs mas é dead code. Manter ou remover é decision de estilo.

### F17. Kodus: Propagação de erros genéricos arrisca vazamento de PII [Kodus AI]
**File:** `Sources/social-care-s/Application/Registry/ReadmitPatient/Error/ReadmitPatientMapperError.swift:33`
**Severity:** MEDIUM
**Issue:** O fallback `return error` propaga erros inesperados que podem conter detalhes internos. O `AppErrorMiddleware` deveria sanitizar, mas se não o fizer, informações internas vazam.
**Fix:** Em vez de `return error`, criar um erro genérico sanitizado:
```swift
return ReadmitPatientError.patientNotFound(patientId) // ou um novo .internalError
```
**Contradição:** Isso é exatamente o que corrigimos (mascarar como 404). O trade-off é: mascarar (seguro mas opaco) vs propagar (transparente mas potencialmente leaky). A solução ideal é garantir que AppErrorMiddleware sanitize qualquer erro não-AppErrorConvertible.

---

## Prioridade de Correção

### MUST FIX (antes de produção)
1. **F13** — cannotDischargeWaitlisted → alreadyDischarged (mensagem errada)
2. **F14** — cannotReadmitWaitlisted → alreadyActive (mensagem errada)
3. **F1** — Event emite notes raw em vez do trimmed (inconsistência state/event)
4. **F6** — readmit() não limpa withdrawInfo (inconsistência de estado)
5. **F3/F5** — Mapper fallback .active mascara corrupção de dados

### SHOULD FIX (qualidade)
6. **F2** — InMemoryPatientRepository totalCount após cursor
7. **F9** — PII (UUID) nas mensagens de erro
8. **F15** — Dead code no readmit mapper
9. **F16** — Dead code no discharge mapper

### WON'T FIX (design choices / não aplicável)
10. **F4** — Falso positivo do Copilot (testes compilam)
11. **F7** — Breaking change intencional (coberta por testes)
12. **F8** — Consentimento LGPD (concern de produto, não de código)
13. **F10** — appFailure duplicada (refactor futuro)
14. **F11** — 204 No Content (correto para mutations)
15. **F12** — eventBus.publish redundante (mitigado por Outbox)
16. **F17** — Trade-off mascarar vs propagar (requer decisão arquitetural)
