import Foundation
import Testing

@testable import social_care_s

@Suite("DemographicGeneralization — PII vira quase-identificador na origem")
struct DemographicGeneralizationTests {

    // MARK: - Faixa etária

    @Test(
        "faixa etária cobre os cortes de 5 anos",
        arguments: [
            (birth: "2024-06-01", reference: "2025-06-15", expected: "0-4"),
            (birth: "2018-03-15", reference: "2025-06-15", expected: "5-9"),
            (birth: "2010-01-01", reference: "2025-06-15", expected: "15-19"),
            (birth: "1990-07-20", reference: "2025-06-15", expected: "30-34"),
            (birth: "1940-12-25", reference: "2025-06-15", expected: "80+"),
        ]
    )
    func ageBandBuckets(birth: String, reference: String, expected: String) throws {
        let band = DemographicGeneralization.ageBand(
            birthDate: try date(birth), reference: try date(reference)
        )
        #expect(band == expected)
    }

    @Test("aniversário ainda não feito conta o ano anterior")
    func ageBandUsesCompletedYears() throws {
        // Nasceu em dezembro; em junho ainda não fez 20 — tem que cair em 15-19.
        // Errar isto move gente inteira de faixa e enviesa todo indicador etário.
        let band = DemographicGeneralization.ageBand(
            birthDate: try date("2005-12-31"), reference: try date("2025-06-15")
        )
        #expect(band == "15-19")
    }

    @Test("a referência é o momento do evento, não 'hoje'")
    func ageBandIsStableAcrossReprocessing() throws {
        // Reprocessar um evento antigo não pode mudar a faixa: o cubo do BI é
        // histórico. Mesma data de nascimento, referências diferentes, faixas
        // diferentes — por isso o handler passa o `occurredAt`, nunca `Date()`.
        let birth = try date("1990-07-20")
        #expect(DemographicGeneralization.ageBand(birthDate: birth, reference: try date("2025-06-15")) == "30-34")
        #expect(DemographicGeneralization.ageBand(birthDate: birth, reference: try date("2035-06-15")) == "40-44")
    }

    @Test("nascimento no futuro não produz faixa")
    func ageBandRejectsFutureBirth() throws {
        let band = DemographicGeneralization.ageBand(
            birthDate: try date("2030-01-01"), reference: try date("2025-06-15")
        )
        #expect(band == nil)
    }

    @Test("o topo é aberto — 80+ absorve o resto")
    func ageBandTopIsOpen() throws {
        // Faixas de 5 anos acima de 80 formariam grupos pequenos demais e o
        // próprio quase-identificador viraria identificador.
        let band = DemographicGeneralization.ageBand(
            birthDate: try date("1900-01-01"), reference: try date("2025-06-15")
        )
        #expect(band == "80+")
    }

    // MARK: - Geografia

    @Test("CEP resolve para mesorregião")
    func mesoregionFromCEP() {
        let meso = DemographicGeneralization.mesoregion(cep: "01310100")
        #expect(meso?.stateCode == "35")
        #expect(meso?.code.isEmpty == false)
        #expect(meso?.name.isEmpty == false)
    }

    @Test("aceita CEP com máscara")
    func mesoregionAcceptsMask() {
        let masked = DemographicGeneralization.mesoregion(cep: "01310-100")
        let plain = DemographicGeneralization.mesoregion(cep: "01310100")
        #expect(masked == plain)
    }

    @Test(
        "CEP inválido não produz mesorregião",
        arguments: ["", "123", "1234567", "123456789", "abcdefgh"]
    )
    func mesoregionRejectsInvalid(cep: String) {
        #expect(DemographicGeneralization.mesoregion(cep: cep) == nil)
    }

    @Test("resolve por FAIXA, não por prefixo exato")
    func mesoregionResolvesByRange() {
        // Regressão do bug que o `analysis-bi` carregava: 01310 não está na
        // tabela (só 01000 está), e casamento de prefixo devolveria nil para a
        // Av. Paulista. A tabela é de faixas — 01310 cai na faixa 01000.
        let paulista = DemographicGeneralization.mesoregion(cep: "01310100")
        #expect(paulista?.name == "Metropolitana de Sao Paulo")

        // Faixa que não começa em 000, para garantir que não é sorte:
        // 29150 cai em 29100 (Litoral Norte), não em 29200 (Central).
        let litoralNorte = DemographicGeneralization.mesoregion(cep: "29150000")
        #expect(litoralNorte?.name == "Litoral Norte Espírito-santense")
    }

    @Test("CEP abaixo da primeira faixa devolve nil")
    func mesoregionBelowFirstRangeIsNil() {
        // Antes de 01000 não há faixa. Devolver a primeira poria pacientes numa
        // região onde não estão — pior que não saber.
        #expect(DemographicGeneralization.mesoregion(cep: "00500000") == nil)
    }

    // MARK: - Helper

    private func date(_ iso: String) throws -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.calendar = Calendar(identifier: .gregorian)
        return try #require(fmt.date(from: iso), "data inválida no teste: \(iso)")
    }
}
