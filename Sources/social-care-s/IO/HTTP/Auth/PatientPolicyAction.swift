/// Ações do recurso `patient` no Cerbos.
///
/// **Espelha** a policy versionada em
/// `infra:stack/cells/idp/config/cerbos/policies/social-care/patient.yaml`.
/// Os dois lados precisam mudar juntos — `CerbosGuardTests` falha se divergirem.
///
/// **Por que um tipo e não `String`.** A ação é a chave da decisão do PDP, e o
/// Cerbos é *default deny*: pedir uma ação que a policy não declara não é erro,
/// é **negação silenciosa**. Foi o que aconteceu no wiring original, que pedia
/// `read` e `create` — nomes plausíveis, inexistentes na policy — e teria
/// respondido 403 em 9 das 12 rotas de paciente assim que `CERBOS_URL` fosse
/// definido. String não é conferida por compilador nem por review; enum é.
enum PatientPolicyAction: String, Sendable, CaseIterable {
    // Leitura e trilha de auditoria — worker, owner, admin.
    case list
    case getById
    case getByPersonId
    case auditTrail

    // Escrita cadastral/clínica/assistencial/proteção — só worker.
    case register
    case family
    case caregiver
    case socialIdentity
    case appointments
    case intake
    case assessments
    case placement
    case violation
    case referral

    // Ciclo de vida — worker e admin.
    case admit
    case discharge
    case readmit
    case withdraw

    // Anonimização (LGPD/erasure, ADR-039) — só admin.
    case anonymize
}
