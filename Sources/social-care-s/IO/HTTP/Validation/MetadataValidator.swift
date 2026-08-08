import Foundation
import Vapor
import SQLKit

/// Validador metadata-driven que consulta flags em tabelas de dominio
/// para aplicar validacoes condicionais nos requests.
///
/// Beneficios: valida `birthCertificateNumber` e `deceasedCpf` baseado
/// nos flags `exige_registro_nascimento` e `exige_cpf_falecido`.
///
/// Violacoes: valida `descriptionOfFact` baseado no flag `exige_descricao`.
struct MetadataValidator: Sendable {
    private let db: any SQLDatabase

    init(db: any SQLDatabase) {
        self.db = db
    }

    // MARK: - Benefit Type Validation

    struct BenefitTypeMetadata: Codable, Sendable {
        let id: UUID
        let exige_registro_nascimento: Bool
        let exige_cpf_falecido: Bool
    }

    func validateBenefits(_ benefits: [UpdateSocioEconomicSituationRequest.SocialBenefitDraftDTO]) async throws {
        for benefit in benefits {
            guard let typeId = benefit.benefitTypeId,
                  let uuid = UUID(uuidString: typeId) else { continue }

            guard let meta = try await fetchBenefitMetadata(uuid) else {
                throw Abort(.unprocessableEntity,
                            reason: "Benefit type '\(typeId)' not found in dominio_tipo_beneficio.")
            }

            if meta.exige_registro_nascimento && (benefit.birthCertificateNumber ?? "").isEmpty {
                throw Abort(.unprocessableEntity,
                            reason: "Benefit type requires 'birthCertificateNumber' (registro de nascimento).")
            }

            if meta.exige_cpf_falecido && (benefit.deceasedCpf ?? "").isEmpty {
                throw Abort(.unprocessableEntity,
                            reason: "Benefit type requires 'deceasedCpf' (CPF da pessoa falecida).")
            }
        }
    }

    func validateWorkBenefits(_ benefits: [UpdateWorkAndIncomeRequest.BenefitDraftDTO]) async throws {
        for benefit in benefits {
            guard let typeId = benefit.benefitTypeId,
                  let uuid = UUID(uuidString: typeId) else { continue }

            guard let meta = try await fetchBenefitMetadata(uuid) else {
                throw Abort(.unprocessableEntity,
                            reason: "Benefit type '\(typeId)' not found in dominio_tipo_beneficio.")
            }

            if meta.exige_registro_nascimento && (benefit.birthCertificateNumber ?? "").isEmpty {
                throw Abort(.unprocessableEntity,
                            reason: "Benefit type requires 'birthCertificateNumber' (registro de nascimento).")
            }

            if meta.exige_cpf_falecido && (benefit.deceasedCpf ?? "").isEmpty {
                throw Abort(.unprocessableEntity,
                            reason: "Benefit type requires 'deceasedCpf' (CPF da pessoa falecida).")
            }
        }
    }

    private func fetchBenefitMetadata(_ id: UUID) async throws -> BenefitTypeMetadata? {
        try await db.select()
            .column("id")
            .column("exige_registro_nascimento")
            .column("exige_cpf_falecido")
            .from("dominio_tipo_beneficio")
            .where("id", .equal, id)
            .where("ativo", .equal, true)
            .first(decoding: BenefitTypeMetadata.self)
    }

    // MARK: - Violation Type Validation

    struct ViolationTypeMetadata: Codable, Sendable {
        let id: UUID
        // `codigo` (pt-BR) e a chave que traduz o item do catalogo para a categoria de dominio.
        let codigo: String
        let exige_descricao: Bool
    }

    /// Valida o item do catalogo e DEVOLVE a categoria de dominio correspondente.
    ///
    /// Devolver o tipo aqui (em vez de so validar) faz do catalogo a fonte: o cliente escolhe um item
    /// — que e o que a tela oferece — e o dominio deriva a categoria. Antes, o cliente mandava os dois
    /// e eles podiam divergir; como os vocabularios nunca casaram, na pratica NENHUM tipo escolhido na
    /// tela era aceito. `nil` = nao ha `violationTypeId` (contrato legado: usa o `violationType` cru).
    func validateViolationType(typeId: String?, descriptionOfFact: String) async throws -> RightsViolationReport.ViolationType? {
        guard let typeId, let uuid = UUID(uuidString: typeId) else { return nil }

        guard let meta = try await fetchViolationMetadata(uuid) else {
            throw Abort(.unprocessableEntity,
                        reason: "Violation type '\(typeId)' not found in dominio_tipo_violacao.")
        }

        if meta.exige_descricao && descriptionOfFact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Abort(.unprocessableEntity,
                        reason: "Violation type requires 'descriptionOfFact' (descricao detalhada obrigatoria para este tipo).")
        }

        guard let mapped = RightsViolationReport.ViolationType.fromCatalogCode(meta.codigo) else {
            throw Abort(.unprocessableEntity,
                        reason: "Violation type code '\(meta.codigo)' has no domain category. Add it to ViolationType.fromCatalogCode.")
        }
        return mapped
    }

    private func fetchViolationMetadata(_ id: UUID) async throws -> ViolationTypeMetadata? {
        try await db.select()
            .column("id")
            .column("codigo")
            .column("exige_descricao")
            .from("dominio_tipo_violacao")
            .where("id", .equal, id)
            .where("ativo", .equal, true)
            .first(decoding: ViolationTypeMetadata.self)
    }
}
