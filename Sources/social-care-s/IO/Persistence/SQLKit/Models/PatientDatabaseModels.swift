import Foundation
import SQLKit

// MARK: - Aggregate Root

struct PatientModel: Codable {
    let id: UUID
    let person_id: UUID
    let version: Int

    // personal_data
    let first_name: String?
    let last_name: String?
    let mother_name: String?
    let nationality: String?
    let sex: String?
    let social_name: String?
    let birth_date: Date?
    let phone: String?

    // civil_documents
    let cpf: String?
    let nis: String?
    let rg_number: String?
    let rg_issuing_state: String?
    let rg_issuing_agency: String?
    let rg_issue_date: Date?
    let cns_number: String?
    let cns_cpf: String?
    let cns_qr_code: String?

    // address
    let address_cep: String?
    let address_is_shelter: Bool?
    let address_is_homeless: Bool?
    let address_location: String?
    let address_street: String?
    let address_neighborhood: String?
    let address_number: String?
    let address_complement: String?
    let address_state: String?
    let address_city: String?

    // housing_condition
    let hc_type: String?
    let hc_wall_material: String?
    let hc_number_of_rooms: Int?
    let hc_number_of_bedrooms: Int?
    let hc_number_of_bathrooms: Int?
    let hc_water_supply: String?
    let hc_has_piped_water: Bool?
    let hc_electricity_access: String?
    let hc_sewage_disposal: String?
    let hc_waste_collection: String?
    let hc_accessibility_level: String?
    let hc_is_in_geographic_risk_area: Bool?
    let hc_has_difficult_access: Bool?
    let hc_is_in_social_conflict_area: Bool?
    let hc_has_diagnostic_observations: Bool?

    // social_identity
    let social_identity_type_id: UUID?
    let social_identity_other_desc: String?

    // community_support_network
    let csn_has_relative_support: Bool?
    let csn_has_neighbor_support: Bool?
    let csn_family_conflicts: String?
    let csn_patient_participates_in_groups: Bool?
    let csn_family_participates_in_groups: Bool?
    let csn_patient_has_access_to_leisure: Bool?
    let csn_faces_discrimination: Bool?

    // social_health_summary
    let shs_requires_constant_care: Bool?
    let shs_has_mobility_impairment: Bool?
    let shs_functional_dependencies: String?
    let shs_has_relevant_drug_therapy: Bool?

    // socioeconomic_situation
    let ses_total_family_income: Double?
    let ses_income_per_capita: Double?
    let ses_receives_social_benefit: Bool?
    let ses_main_source_of_income: String?
    let ses_has_unemployed: Bool?

    // work_and_income
    let wi_has_retired_members: Bool?

    // health_status
    let hs_food_insecurity: Bool?
    let hs_constant_care_member_ids: String?

    // placement_history
    let ph_home_loss_report: String?
    let ph_third_party_guard_report: String?
    let ph_adult_in_prison: Bool?
    let ph_adolescent_in_internment: Bool?

    // ingress_info
    let ii_ingress_type_id: UUID?
    let ii_origin_name: String?
    let ii_origin_contact: String?
    let ii_service_reason: String?

    // discharge
    let status: String
    let discharge_reason: String?
    let discharge_notes: String?
    let discharged_at: Date?
    let discharged_by: String?

    // withdraw
    let withdraw_reason: String?
    let withdraw_notes: String?
    let withdrawn_at: Date?
    let withdrawn_by: String?
}

// MARK: - Existing Child Tables

struct FamilyMemberModel: Codable {
    let patient_id: UUID
    let person_id: UUID
    /// FK tipada para `dominio_parentesco(id)` (ADR-007). Antes era `relationship: String`
    /// aceitando UUID stringificado ou qualquer texto livre — anti-pattern de
    /// Primitive Obsession + falta de FK declarada.
    let relationship_id: UUID
    let is_primary_caregiver: Bool
    let resides_with_patient: Bool
    let has_disability: Bool
    let birth_date: Date
}

/// Tabela filha 1NF para `family_members.required_documents` (ADR-020).
///
/// Pré-fix: array JSON inline em coluna TEXT (`["RG","CPF"]`). Violava 1NF;
/// `compactMap { RequiredDocument(rawValue:) }` silenciava typo na app e
/// na leitura.
///
/// Pós-fix: cada documento é uma row. PK composta `(patient_id, person_id,
/// document_code)`; FK composta para `family_members(patient_id, person_id)
/// ON DELETE CASCADE`; CHECK `document_code IN ('CN','RG','CTPS','CPF','TE')`
/// no schema (defesa adicional contra SQL direto).
struct FamilyMemberRequiredDocumentModel: Codable {
    let patient_id: UUID
    let person_id: UUID
    let document_code: String
}

struct DiagnosisModel: Codable {
    /// PK surrogate (ADR-006). Gerada pela aplicação em `toDatabase`; o banco
    /// também tem `DEFAULT gen_random_uuid()` como rede de segurança.
    let id: UUID
    let patient_id: UUID
    let icd_code: String
    let date: Date
    let description: String
}

struct AppointmentModel: Codable {
    let id: UUID
    let patient_id: UUID
    let date: Date
    let professional_in_charge_id: UUID
    let type: String
    let summary: String
    let action_plan: String
}

struct ReferralModel: Codable {
    let id: UUID
    let patient_id: UUID
    let date: Date
    let requesting_professional_id: UUID
    let referred_person_id: UUID
    let destination_service: String
    let reason: String
    let status: String
}

struct ViolationReportModel: Codable {
    let id: UUID
    let patient_id: UUID
    let report_date: Date
    let incident_date: Date?
    let victim_id: UUID
    let violation_type: String
    let description_of_fact: String
    let actions_taken: String
}

// MARK: - Normalized Child Tables (arrays extraidos de JSONB)

struct MemberIncomeModel: Codable {
    let id: UUID
    let patient_id: UUID
    let member_id: UUID
    let occupation_id: UUID?
    let has_work_card: Bool
    let monthly_amount: Double
}

struct SocialBenefitModel: Codable {
    let id: UUID
    let patient_id: UUID
    let source: String
    let benefit_name: String
    let amount: Double
    let beneficiary_id: UUID
}

struct MemberEducationalProfileModel: Codable {
    let id: UUID
    let patient_id: UUID
    let member_id: UUID
    let can_read_write: Bool
    let attends_school: Bool
    let education_level_id: UUID?
}

struct ProgramOccurrenceModel: Codable {
    let id: UUID
    let patient_id: UUID
    let member_id: UUID
    let date: Date
    let effect_id: UUID?
    let is_suspension_requested: Bool
}

struct MemberDeficiencyModel: Codable {
    let id: UUID
    let patient_id: UUID
    let member_id: UUID
    let deficiency_type_id: UUID?
    let needs_constant_care: Bool
    let responsible_caregiver_name: String?
}

struct GestatingMemberModel: Codable {
    let id: UUID
    let patient_id: UUID
    let member_id: UUID
    let months_gestation: Int
    let started_prenatal_care: Bool
}

struct PlacementRegistryModel: Codable {
    let id: UUID
    let patient_id: UUID
    let member_id: UUID
    let start_date: Date
    let end_date: Date?
    let reason: String
}

struct IngressLinkedProgramModel: Codable {
    let id: UUID
    let patient_id: UUID
    let program_id: UUID?
    let observation: String?
}

// MARK: - Outbox

struct OutboxMessageModel: Codable {
    let id: UUID
    let event_type: String
    let payload: String
    let occurred_at: Date
    let processed_at: Date?
}

// MARK: - Audit Trail

struct AuditTrailModel: Codable {
    /// PK própria — gen_random_uuid no banco como fallback (ADR-015).
    /// Application popula com UUID() novo a cada entry.
    let id: UUID
    /// Rastreio para o `outbox_messages.id` que originou esta entry (ADR-015).
    /// Permite N entries para o mesmo outbox em caso de re-processamento.
    let outbox_message_id: UUID
    let aggregate_type: String
    let aggregate_id: UUID
    let event_type: String
    let actor_id: String?
    let payload: String
    let occurred_at: Date
    let recorded_at: Date
}
