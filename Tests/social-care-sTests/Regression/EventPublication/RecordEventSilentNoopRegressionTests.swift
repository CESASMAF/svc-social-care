import Foundation
import Testing
@testable import social_care_s

// ticket: T-004 — achado S-C7 (recordEvent no-op silencioso)
// ADR: ADR-004 (a criar) — Eventos de domínio via protocolo composto sem cast dinâmico

/// Regressão para o achado **S-C7**: a extension default `recordEvent` em
/// `EventSourcedAggregate` faz cast dinâmico para `EventSourcedAggregateInternal`
/// e — antes do ADR-004 — engole o evento silenciosamente quando o agregado
/// não conformar `Internal`.
///
/// Como `EventSourcedAggregate` não exigia `Internal` por herança, qualquer
/// agregado novo escrito sem `addEvent`/`clearEvents` virava bug invisível
/// em produção: `recordEvent` retornava sem fazer nada e o evento sumia.
///
/// Após ADR-004 (`EventSourcedAggregate: EventSourcedAggregateInternal`),
/// agregado sem `addEvent` **não compila**. O bug torna-se impossível em
/// compile-time.
///
/// Este suite garante:
/// 1. **Runtime:** um agregado conforme armazena evento via `recordEvent`.
/// 2. **Compile-time guard:** `Patient` (agregado real) conforma `Internal`
///    via composição do protocolo. Se alguém remover a herança no protocolo
///    ou remover `EventSourcedAggregateInternal` de `Patient`, o cast
///    abaixo falha em tempo de compilação ou link.
@Suite("Regression: Event Publication — S-C7 recordEvent silent no-op")
struct RecordEventSilentNoopRegressionTests {

    // MARK: - Fixtures

    struct TestEvent: DomainEvent {
        let id: UUID = UUID()
        let occurredAt: Date = RegressionFixture.frozenTimestamp().date
    }

    /// Mínimo agregado para exercitar `recordEvent`.
    ///
    /// **Pré-ADR-004 (bug C7):** este struct podia conformar apenas
    /// `EventSourcedAggregate` (sem `addEvent`). O cast dinâmico em
    /// `recordEvent` falhava silenciosamente e o evento sumia.
    ///
    /// **Pós-ADR-004 (este código):** o protocolo composto exige `addEvent`
    /// e `clearEvents` por herança. O compilador rejeita um struct que omita
    /// esses métodos — o bug torna-se impossível em compile-time. A presença
    /// dos dois métodos abaixo é, portanto, **enforcement automático**: se
    /// alguém reverter a herança do protocolo, este arquivo continua
    /// compilando, mas o teste `test_S_C7_recordEvent_actually_appends`
    /// passaria a falhar em runtime — sinalizando a regressão.
    struct TestAggregate: EventSourcedAggregate {
        typealias ID = UUID
        let id: UUID
        var version: Int = 0
        var uncommittedEvents: [any DomainEvent] = []

        mutating func addEvent(_ event: any DomainEvent) {
            uncommittedEvents.append(event)
            version += 1
        }

        mutating func clearEvents() {
            uncommittedEvents.removeAll()
        }
    }

    // MARK: - Tests

    @Test("S-C7 — recordEvent armazena evento (não é mais no-op silencioso)")
    func test_S_C7_recordEvent_actually_appends() {
        var agg = TestAggregate(id: RegressionFixture.uuid(seed: 1))
        #expect(agg.uncommittedEvents.isEmpty)

        agg.recordEvent(TestEvent())
        agg.recordEvent(TestEvent())

        #expect(agg.uncommittedEvents.count == 2,
                "Aggregate que conforma EventSourcedAggregate (composto com Internal por ADR-004) deve armazenar eventos via recordEvent. Se count != 2, o cast dinâmico voltou e recordEvent virou no-op silencioso (bug C7).")
    }

    @Test("S-C7 — Patient conforma EventSourcedAggregateInternal por composição do protocolo")
    func test_S_C7_patient_conforms_internal_via_composition() {
        // Após ADR-004, o cast sempre sucede em compile-time porque
        // EventSourcedAggregate compõe Internal por herança. Esta atribuição
        // direta (sem `as?`) é o **guard de compilação**: se alguém quebrar
        // a herança no protocolo OU remover Internal de Patient, este arquivo
        // deixa de compilar — o bug C7 é detectado antes do PR.
        let patientType: any EventSourcedAggregate.Type = Patient.self
        let internalType: any EventSourcedAggregateInternal.Type = patientType
        // Confirmação semântica: o tipo derivado é o mesmo (Patient).
        #expect("\(internalType)" == "\(patientType)",
                "Patient conforma EventSourcedAggregateInternal via composição do protocolo (ADR-004). Se este arquivo deixar de compilar, o bug C7 voltou.")
    }
}
