import Testing
@testable import social_care_s

/// Tests para `AuthenticatedUser` apos extensao com claims ACDG (org_id,
/// person_id, legacy_sub conforme ADR-031). ADR-023 preservado: `userId`
/// continua sendo `JWT.sub` (actorId do audit trail).
@Suite("AuthenticatedUser — ADR-023 + ADR-031 (legacy_sub correlation)")
struct AuthenticatedUserTests {

    // MARK: - Construtor + defaults

    @Test("Construtor com defaults nos campos ACDG opcionais")
    func constructorDefaults() {
        let user = AuthenticatedUser(userId: "uid-1", roles: ["social_worker"])
        #expect(user.userId == "uid-1")
        #expect(user.roles == ["social_worker"])
        #expect(user.orgId == nil)
        #expect(user.personId == nil)
        #expect(user.legacySub == nil)
    }

    @Test("Construtor com claims ACDG completos (Authentik com acdg-roles property mapping)")
    func constructorWithACDGClaims() {
        let user = AuthenticatedUser(
            userId: "fe025d9c...",
            roles: ["social-care:admin"],
            orgId: "acdg-default",
            personId: "01HXYABCDEF",
            legacySub: "270366461930766336"
        )
        #expect(user.userId == "fe025d9c...")
        #expect(user.orgId == "acdg-default")
        #expect(user.personId == "01HXYABCDEF")
        #expect(user.legacySub == "270366461930766336")
    }

    // MARK: - ADR-023 preservado: userId E sempre o sub do JWT

    @Test("ADR-023: userId nao e afetado por legacySub (sub Authentik atual e canonico)")
    func userIdRemainsCanonicalSub() {
        let user = AuthenticatedUser(
            userId: "novo-sub-authentik",
            roles: [],
            legacySub: "sub-zitadel-antigo"
        )
        // userId DEVE ser o sub Authentik atual. legacySub e apenas
        // metadado de correlacao para queries historicas.
        #expect(user.userId == "novo-sub-authentik")
        #expect(user.userId != user.legacySub)
    }

    // MARK: - hasRole continua funcionando (compat existente)

    @Test("hasRole continua suportando composite keys e superadmin")
    func hasRoleStillWorks() {
        let regular = AuthenticatedUser(
            userId: "u",
            roles: ["social-care:worker"]
        )
        #expect(regular.hasRole("worker"))
        #expect(!regular.hasRole("admin"))

        let admin = AuthenticatedUser(userId: "u", roles: ["superadmin"])
        #expect(admin.hasRole("worker"))
        #expect(admin.hasRole("admin"))
        #expect(admin.isSuperAdmin)
    }
}
