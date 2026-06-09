import Foundation
import JWT
import Testing
@testable import social_care_s

/// Tests para `OIDCJWTPayload` — multi-issuer (Authentik atual + Zitadel legado
/// durante migração, ADR-027/031). Cobre derivação de roles a partir de:
/// - `roles` claim (Authentik com property mapping `acdg-roles` — ADR-029)
/// - `groups` claim (Authentik default)
/// - `urn:zitadel:iam:org:project:roles` (Zitadel legado, durante migracao)
///
/// Audit trail (ADR-023) preservado: `sub` continua sendo o actorId.
/// Claims adicionais: `org_id`, `person_id`, `legacy_sub` (ADR-031).
/// `.serialized` é obrigatório: vários testes deste suite mutam o singleton
/// global `OIDCJWTPayloadBootstrap.shared` (defense-in-depth do
/// `verify(using:)`). Em execução paralela default do swift-testing, dois
/// testes podem sobrescrever o singleton concorrentemente e provocar
/// `claimVerificationFailure` aleatório (sintoma: `verifyUsingConsultsGlobalBootstrap`
/// falhando intermitente com aud/iss de outro teste). Ver T-004.fix /
/// fix colateral durante T-004.
@Suite("OIDCJWTPayload — multi-issuer (Authentik + Zitadel legado)", .serialized)
struct OIDCJWTPayloadTests {

    // MARK: - Helpers

    /// `decode(_:)` é usado SOMENTE pelos testes de **mapeamento de claim**
    /// (derivação de `roleNames`/`orgId`/`personId`/`legacySub` a partir do JSON
    /// do token), onde o que importa é o `CodingKeys` — não o valor temporal de
    /// `exp`. Usa `.secondsSince1970` (mesma estratégia do JWTKit interno,
    /// `CustomizedJSONCoders.swift:47`).
    ///
    /// ⚠️ NÃO use `decode(_:)` para asserts sobre `exp`/`nbf`. A decodificação de
    /// `Date` via `JSONDecoder.dateDecodingStrategy` num container aninhado
    /// (`JWTUnixEpochClaim`) diverge entre Darwin `Foundation` (macOS) e
    /// `FoundationEssentials` (Linux/CI): no Linux a estratégia não se aplica e o
    /// epoch é lido como segundos-desde-2001, deslocando `exp` ~31 anos para o
    /// futuro (CI vermelho). Testes temporais usam `makePayload(...)` (construção
    /// determinística) e o caminho real assinar+verificar é coberto por
    /// `OIDCJWTSigningE2ETests`.
    private func decode(_ json: String) throws -> OIDCJWTPayload {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(OIDCJWTPayload.self, from: data)
    }

    private let expFuture = Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970)

    /// Constrói `OIDCJWTPayload` programaticamente: `exp`/`nbf` entram como `Date`
    /// direto, sem passar pelo `JSONDecoder`. Determinístico em qualquer
    /// plataforma — usado pelos testes de `verify(...)` (iss/aud/exp/nbf).
    private func makePayload(
        sub: String = "a",
        iss: String = "https://auth.acdgbrasil.com.br",
        aud: [String] = ["y"],
        exp: Date = Date(timeIntervalSinceNow: 3600),
        nbf: Date? = nil,
        roles: [String]? = nil,
        groups: [String]? = nil,
        projectRoles: [String: [String: String]]? = nil,
        orgId: String? = nil,
        personId: String? = nil,
        legacySub: String? = nil
    ) -> OIDCJWTPayload {
        OIDCJWTPayload(
            sub: SubjectClaim(value: sub),
            exp: ExpirationClaim(value: exp),
            iss: IssuerClaim(value: iss),
            aud: AudienceClaim(value: aud),
            nbf: nbf.map { NotBeforeClaim(value: $0) },
            roles: roles,
            groups: groups,
            projectRoles: projectRoles,
            orgId: orgId,
            personId: personId,
            legacySub: legacySub
        )
    }

    // MARK: - Authentik shape (default — `groups` claim)

    @Test("Authentik default: derive roles do claim 'groups'")
    func authentikGroups() throws {
        // `groups` no formato REAL emitido pelo people-context #6 (idp-sync.ts):
        // system="social-care" + role → "social-care:<role>". Ver também a seção
        // "Contrato people-context #6" abaixo (RBAC end-to-end).
        let json = """
        {
          "sub": "fe025d9c8429d445f0d18e2380c17ec5",
          "iss": "http://authentik:9000/application/o/social-care/",
          "aud": "OBEiWNx12lS0KTDXPmDgcm6AwpmlY4MtiQcpaeLc",
          "exp": \(expFuture),
          "groups": ["social-care:worker", "social-care:admin"]
        }
        """
        let payload = try decode(json)
        #expect(payload.roleNames == ["social-care:worker", "social-care:admin"])
        #expect(payload.sub.value == "fe025d9c8429d445f0d18e2380c17ec5")
    }

    // MARK: - Authentik shape (com property mapping `acdg-roles` — ADR-029)

    @Test("Authentik com acdg-roles: derive roles + org_id + person_id + legacy_sub")
    func authentikAcdgRolesMapping() throws {
        let json = """
        {
          "sub": "fe025d9c8429d445f0d18e2380c17ec5",
          "iss": "http://authentik:9000/application/o/social-care/",
          "aud": "OBEiWNx12lS0KTDXPmDgcm6AwpmlY4MtiQcpaeLc",
          "exp": \(expFuture),
          "roles": ["social-care:admin", "social_worker"],
          "org_id": "acdg-default",
          "person_id": "01HXYABCDEF",
          "legacy_sub": "270366461930766336"
        }
        """
        let payload = try decode(json)
        #expect(payload.roleNames == ["social-care:admin", "social_worker"])
        #expect(payload.orgId == "acdg-default")
        #expect(payload.personId == "01HXYABCDEF")
        #expect(payload.legacySub == "270366461930766336")
    }

    @Test("`roles` claim tem precedencia sobre `groups` (ADR-029 property mapping ativa)")
    func rolesTakesPrecedenceOverGroups() throws {
        let json = """
        {
          "sub": "abc", "iss": "http://x/", "aud": "y", "exp": \(expFuture),
          "roles": ["from-roles"],
          "groups": ["from-groups"]
        }
        """
        let payload = try decode(json)
        #expect(payload.roleNames == ["from-roles"])
    }

    // MARK: - Zitadel legado (durante migracao Sprint 3-4 — multi-issuer)

    @Test("Zitadel legado: derive roles do claim `urn:zitadel:iam:org:project:roles`")
    func zitadelLegacyProjectRoles() throws {
        let json = """
        {
          "sub": "270366461930766336",
          "iss": "https://auth.acdgbrasil.com.br",
          "aud": "270366461930766336@social-care",
          "exp": \(expFuture),
          "urn:zitadel:iam:org:project:roles": {
            "social_worker": {"270366000000000000": "acdg.org"},
            "social-care:admin": {"270366000000000000": "acdg.org"}
          }
        }
        """
        let payload = try decode(json)
        #expect(payload.roleNames == ["social_worker", "social-care:admin"])
    }

    // MARK: - Edge cases

    @Test("Token sem nenhum claim de roles tem roleNames vazio")
    func emptyRoles() throws {
        let json = """
        {"sub": "a", "iss": "http://x/", "aud": "y", "exp": \(expFuture)}
        """
        let payload = try decode(json)
        #expect(payload.roleNames.isEmpty)
    }

    @Test("Token sem org_id retorna nil (sem fallback aqui — fallback fica em AuthenticatedUser)")
    func missingOrgIdReturnsNil() throws {
        let json = """
        {"sub": "a", "iss": "http://x/", "aud": "y", "exp": \(expFuture)}
        """
        let payload = try decode(json)
        #expect(payload.orgId == nil)
    }

    // MARK: - verify(): issuer validation (multi-issuer)

    @Test("verify aceita issuer presente na lista OIDC_ISSUERS")
    func verifyAcceptsListedIssuer() async throws {
        let payload = makePayload(
            iss: "http://authentik:9000/application/o/social-care/",
            aud: ["client-id-x"]
        )
        // Stub multi-issuer + multi-audience
        let validators = OIDCJWTValidators(
            allowedIssuers: [
                "https://auth.acdgbrasil.com.br",
                "http://authentik:9000/application/o/social-care/"
            ],
            allowedAudiences: ["client-id-x", "270366461930766336@social-care"]
        )
        try await payload.verify(validators: validators)
    }

    @Test("verify rejeita issuer fora da lista (JWTError.claimVerificationFailure)")
    func verifyRejectsUnknownIssuer() async throws {
        let payload = makePayload(iss: "https://malicious.example.com", aud: ["y"])
        let validators = OIDCJWTValidators(
            allowedIssuers: ["https://auth.acdgbrasil.com.br"],
            allowedAudiences: ["y"]
        )
        await #expect(throws: JWTError.self) {
            try await payload.verify(validators: validators)
        }
    }

    @Test("verify rejeita audience fora da lista")
    func verifyRejectsUnknownAudience() async throws {
        let payload = makePayload(iss: "https://auth.acdgbrasil.com.br", aud: ["wrong-aud"])
        let validators = OIDCJWTValidators(
            allowedIssuers: ["https://auth.acdgbrasil.com.br"],
            allowedAudiences: ["expected-aud"]
        )
        await #expect(throws: JWTError.self) {
            try await payload.verify(validators: validators)
        }
    }

    @Test("verify rejeita token expirado")
    func verifyRejectsExpiredToken() async throws {
        // exp 1h no passado, construído como `Date` (determinístico cross-platform,
        // sem depender de JSONDecoder.dateDecodingStrategy — ver makePayload).
        let payload = makePayload(
            iss: "https://auth.acdgbrasil.com.br",
            aud: ["y"],
            exp: Date(timeIntervalSinceNow: -3600)
        )
        let validators = OIDCJWTValidators(
            allowedIssuers: ["https://auth.acdgbrasil.com.br"],
            allowedAudiences: ["y"]
        )
        await #expect(throws: JWTError.self) {
            try await payload.verify(validators: validators)
        }
    }

    // MARK: - Multi-audience: aud como array

    @Test("verify aceita aud como array com pelo menos um valor da lista")
    func verifyAcceptsAudArrayIntersect() async throws {
        let payload = makePayload(
            iss: "https://auth.acdgbrasil.com.br",
            aud: ["aud-1", "aud-2"]
        )
        let validators = OIDCJWTValidators(
            allowedIssuers: ["https://auth.acdgbrasil.com.br"],
            allowedAudiences: ["aud-2", "aud-3"]
        )
        try await payload.verify(validators: validators)
    }

    // MARK: - OIDCJWTValidators (factory a partir de env)

    @Test("OIDCJWTValidators.fromValues: divide CSV por virgula com trim")
    func validatorsFromCsv() throws {
        let validators = try #require(OIDCJWTValidators.fromValues(
            issuersCsv: "https://a.example.com, https://b.example.com ,https://c.example.com",
            audiencesCsv: "aud1,aud2"
        ))
        #expect(validators.allowedIssuers == [
            "https://a.example.com",
            "https://b.example.com",
            "https://c.example.com"
        ])
        #expect(validators.allowedAudiences == ["aud1", "aud2"])
    }

    @Test("OIDCJWTValidators.fromValues: rejeita lista vazia (fail-fast no boot)")
    func validatorsRejectsEmpty() {
        #expect(OIDCJWTValidators.fromValues(issuersCsv: "", audiencesCsv: "y") == nil)
        #expect(OIDCJWTValidators.fromValues(issuersCsv: "x", audiencesCsv: "") == nil)
    }

    // MARK: - AppSec CRITICAL-1 (review 2026-05-14): defense-in-depth

    @Test("verify(using:) consulta storage global e valida iss/aud sem segunda passada manual")
    func verifyUsingConsultsGlobalBootstrap() async throws {
        defer { OIDCJWTPayloadBootstrap.shared.reset() }
        let validators = try #require(OIDCJWTValidators.fromValues(
            issuersCsv: "https://auth.acdgbrasil.com.br",
            audiencesCsv: "expected-aud"
        ))
        OIDCJWTPayloadBootstrap.shared.set(validators)

        let payload = makePayload(
            iss: "https://auth.acdgbrasil.com.br",
            aud: ["expected-aud"]
        )
        try await payload.verify(using: TestAlgorithm())
    }

    @Test("verify(using:) FALHA se OIDCJWTPayloadBootstrap nao registrado (fail-closed)")
    func verifyUsingFailsClosedWithoutBootstrap() async throws {
        OIDCJWTPayloadBootstrap.shared.reset()
        defer { OIDCJWTPayloadBootstrap.shared.reset() }

        let payload = makePayload(iss: "https://auth.acdgbrasil.com.br", aud: ["y"])
        await #expect(throws: JWTError.self) {
            try await payload.verify(using: TestAlgorithm())
        }
    }

    @Test("verify(using:) rejeita issuer fora da whitelist mesmo com signature valida (CRIT-2 mitigation)")
    func verifyUsingRejectsCrossIssuer() async throws {
        defer { OIDCJWTPayloadBootstrap.shared.reset() }
        OIDCJWTPayloadBootstrap.shared.set(try #require(OIDCJWTValidators.fromValues(
            issuersCsv: "https://auth.acdgbrasil.com.br",
            audiencesCsv: "y"
        )))

        let payload = makePayload(iss: "https://malicious.example.com", aud: ["y"])
        await #expect(throws: JWTError.self) {
            try await payload.verify(using: TestAlgorithm())
        }
    }

    // MARK: - AppSec HIGH-A: nbf (not-before) validation

    @Test("verify rejeita token com nbf no futuro")
    func verifyRejectsNbfFuture() async throws {
        let validators = try #require(OIDCJWTValidators.fromValues(
            issuersCsv: "https://auth.acdgbrasil.com.br",
            audiencesCsv: "y"
        ))

        // nbf 30min no futuro → "too soon" (RFC 7519). Date direto: determinístico.
        let nbfFuture = makePayload(nbf: Date(timeIntervalSinceNow: 1800))
        await #expect(throws: JWTError.self) {
            try await nbfFuture.verify(validators: validators)
        }

        // Token sem nbf passa.
        let noNbf = makePayload()
        try await noNbf.verify(validators: validators)
    }

    // MARK: - M5: roles vazio NAO faz fallback para groups

    @Test("M5: roles vazio explicito retorna [] (sem fallback para groups)")
    func emptyRolesDoesNotFallbackToGroups() throws {
        let json = """
        {"sub":"a","iss":"x","aud":"y","exp":\(expFuture),
         "roles":[],"groups":["from-groups"]}
        """
        let payload = try decode(json)
        #expect(payload.roleNames.isEmpty)
    }

    // MARK: - Contrato people-context #6 (RBAC end-to-end)
    //
    // Garante o acoplamento cross-service: o people-context (idp-sync.ts) modela
    // papéis como GRUPOS no formato `<system>:<role>` (ex.: "social-care:worker")
    // + "superadmin", entregues na claim `groups` do Authentik. O caminho real do
    // `JWTAuthMiddleware` é: `payload.roleNames` → `AuthenticatedUser(roles:)` →
    // `RoleGuardMiddleware("worker"/"admin"/...)`. Estes testes provam que os
    // nomes emitidos lá satisfazem os guards daqui (composite key via `hasRole`).

    @Test("Contrato #6: groups 'social-care:<role>' satisfazem os RoleGuards do social-care")
    func authentikGroupsSatisfyRoleGuard() throws {
        let json = """
        {
          "sub": "fe025d9c8429d445f0d18e2380c17ec5",
          "iss": "http://authentik:9000/application/o/social-care/",
          "aud": "OBEiWNx12lS0KTDXPmDgcm6AwpmlY4MtiQcpaeLc",
          "exp": \(expFuture),
          "groups": ["social-care:worker", "social-care:admin"]
        }
        """
        let payload = try decode(json)
        // Mesmo caminho que o JWTAuthMiddleware monta.
        let user = AuthenticatedUser(userId: payload.sub.value, roles: payload.roleNames)
        #expect(user.hasRole("worker"))   // social-care:worker → guard "worker"
        #expect(user.hasRole("admin"))    // social-care:admin  → guard "admin"
        #expect(!user.hasRole("owner"))   // não concedido
    }

    @Test("Contrato #6: group 'superadmin' faz bypass de todos os guards")
    func superadminGroupBypassesGuards() throws {
        let json = """
        {"sub":"a","iss":"http://authentik:9000/application/o/social-care/",
         "aud":"y","exp":\(expFuture),"groups":["superadmin"]}
        """
        let payload = try decode(json)
        let user = AuthenticatedUser(userId: payload.sub.value, roles: payload.roleNames)
        #expect(user.isSuperAdmin)
        #expect(user.hasRole("worker"))
        #expect(user.hasRole("admin"))
        #expect(user.hasRole("owner"))
    }
}

// Stub minimo de JWTAlgorithm para invocar verify(using:) em tests
// (a verificacao de assinatura ja aconteceu na producao via JWKS keystore).
private struct TestAlgorithm: JWTAlgorithm {
    var name: String { "none" }
    func sign<Plaintext: DataProtocol>(_: Plaintext) throws -> [UInt8] { [] }
    func verify<Signature: DataProtocol, Plaintext: DataProtocol>(
        _: Signature, signs _: Plaintext
    ) throws -> Bool { true }
}
