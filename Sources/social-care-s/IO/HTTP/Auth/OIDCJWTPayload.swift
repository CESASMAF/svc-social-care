import Foundation
import JWT
import Vapor

/// Payload JWT OIDC agnostico de IdP (Authentik atual + Zitadel legado).
///
/// ADR-027 + ADR-031: durante a migracao Zitadel → Authentik, o `social-care`
/// aceita tokens de ambos os issuers (multi-issuer JWKS). Roles sao derivadas
/// dos claims customizados conforme a ordem:
///
///   1. `roles` (Authentik com property mapping `acdg-roles` — ADR-029)
///   2. `groups` (Authentik default, sem property mapping custom)
///   3. `urn:zitadel:iam:org:project:roles` (Zitadel legado)
///
/// Apos Sprint 6 (cleanup), apenas os items 1 e 2 sobrevivem.
///
/// ADR-023: `sub` continua sendo o actorId do audit trail. `legacySub`
/// e metadado de correlacao (eventos antigos referenciam `sub` Zitadel).
struct OIDCJWTPayload: JWTPayload {
    var sub: SubjectClaim
    var exp: ExpirationClaim
    var iss: IssuerClaim
    var aud: AudienceClaim

    // not-before: AppSec HIGH-A (review 2026-05-14) — Authentik emite por
    // default. RFC 7519 obriga validar quando presente.
    var nbf: NotBeforeClaim?

    // Claim ACDG (property mapping `acdg-roles` — Authentik)
    var roles: [String]?

    // Authentik default
    var groups: [String]?

    // Zitadel legado (urn-prefixed claim)
    var projectRoles: [String: [String: String]]?

    // Claims ACDG opcionais (ADR-031 — Sprint 3-4 migration)
    var orgId: String?
    var personId: String?
    var legacySub: String?

    enum CodingKeys: String, CodingKey {
        case sub, exp, iss, aud, nbf, roles, groups
        case projectRoles = "urn:zitadel:iam:org:project:roles"
        case orgId = "org_id"
        case personId = "person_id"
        case legacySub = "legacy_sub"
    }

    /// AppSec CRITICAL-1 (review 2026-05-14): defense-in-depth. O protocolo
    /// `JWTPayload.verify(using:)` e chamado por `request.jwt.verify(as:)`
    /// apos checar assinatura RS256. Esta implementacao consulta o storage
    /// global `OIDCJWTPayloadBootstrap` registrado no boot — qualquer
    /// codepath que verifique JWT (middleware, jobs, integrations) executa
    /// validacao COMPLETA de iss/aud/exp/nbf sem precisar lembrar de chamar
    /// `verify(validators:)` em sequencia. Fail-closed se boot nao registrou.
    func verify(using _: some JWTAlgorithm) async throws {
        guard let validators = OIDCJWTPayloadBootstrap.shared.get() else {
            throw JWTError.claimVerificationFailure(
                failedClaim: iss,
                reason: "OIDCJWTPayloadBootstrap nao registrado — chame OIDCJWTPayloadBootstrap.shared.set(validators) no boot"
            )
        }
        try await verify(validators: validators)
    }

    /// Verifica issuer + audience + expiracao + nbf contra `validators`.
    /// Chamado pelo `JWTAuthMiddleware` apos `request.jwt.verify` (que ja
    /// fez verificacao de assinatura RS256 contra o JWKS).
    func verify(validators: OIDCJWTValidators) async throws {
        try exp.verifyNotExpired()
        // HIGH-A: validar nbf quando presente (Authentik emite default).
        try nbf?.verifyNotBefore()

        guard validators.allowedIssuers.contains(iss.value) else {
            throw JWTError.claimVerificationFailure(
                failedClaim: iss,
                reason: "token issuer '\(iss.value)' nao esta na lista permitida"
            )
        }

        // aud pode ser string ou array — `AudienceClaim` ja decodifica ambos.
        // Verificamos interseccao com a lista permitida.
        let intersection = Set(aud.value).intersection(validators.allowedAudiences)
        guard !intersection.isEmpty else {
            throw JWTError.claimVerificationFailure(
                failedClaim: aud,
                reason: "token audience \(aud.value) nao intersecta lista permitida"
            )
        }
    }

    /// Roles derivadas. Code-review M5 (2026-05-14): `roles` presente (mesmo
    /// que vazio) e sinal explicito de "property mapping aplicada com zero
    /// roles" — NAO fazemos fallback para `groups`. Fallback so quando `roles`
    /// e ausente. Evita escalation silenciosa se mapping retornar [] por bug.
    var roleNames: Set<String> {
        if let roles {
            return Set(roles)
        }
        if let groups {
            return Set(groups)
        }
        if let projectRoles {
            return Set(projectRoles.keys)
        }
        return []
    }
}

// MARK: - Decodificacao defensiva do `aud`

extension OIDCJWTPayload {
    /// Decodificacao explicita do payload — existe por UM motivo: `aud` vazio.
    ///
    /// `AudienceClaim.init(value:)` do JWTKit faz `precondition(!value.isEmpty)`. `precondition` NAO
    /// e capturavel em Swift: um token com `"aud": []` **derruba o processo inteiro** em vez de virar
    /// 401 — disponibilidade acionavel por request, antes de qualquer checagem de role. O Hydra emite
    /// exatamente esse token quando o client nao pede `audience` no `/authorize`.
    ///
    /// Decodificamos `aud` a mao e recusamos com erro (capturavel) ANTES de construir o claim.
    /// Ausente e vazio caem no mesmo caso: token sem audience nao e valido aqui, ja que
    /// `verify(validators:)` exige interseccao com `OIDC_AUDIENCES`.
    ///
    /// Fica em `extension` de proposito: um `init` no corpo do struct apagaria o memberwise init
    /// que os testes usam para montar payloads.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // RFC 7519: `aud` e string OU array de strings. Mesma tolerancia do JWTKit, sem o precondition.
        let audValues: [String] =
            if let single = try? c.decodeIfPresent(String.self, forKey: .aud), !single.isEmpty {
                [single]
            } else if let list = try? c.decodeIfPresent([String].self, forKey: .aud) {
                list
            } else {
                []
            }

        guard !audValues.isEmpty else {
            throw JWTError.claimVerificationFailure(
                failedClaim: nil,
                reason: "token sem audience: claim 'aud' ausente ou vazio"
            )
        }

        self.aud = AudienceClaim(value: audValues)
        self.sub = try c.decode(SubjectClaim.self, forKey: .sub)
        self.exp = try c.decode(ExpirationClaim.self, forKey: .exp)
        self.iss = try c.decode(IssuerClaim.self, forKey: .iss)
        self.nbf = try c.decodeIfPresent(NotBeforeClaim.self, forKey: .nbf)
        self.roles = try c.decodeIfPresent([String].self, forKey: .roles)
        self.groups = try c.decodeIfPresent([String].self, forKey: .groups)
        self.projectRoles = try c.decodeIfPresent([String: [String: String]].self, forKey: .projectRoles)
        self.orgId = try c.decodeIfPresent(String.self, forKey: .orgId)
        self.personId = try c.decodeIfPresent(String.self, forKey: .personId)
        self.legacySub = try c.decodeIfPresent(String.self, forKey: .legacySub)
    }
}

/// Validators de issuer + audience para JWT OIDC (multi-issuer).
///
/// Configurado no boot a partir de `OIDC_ISSUERS` (CSV) e `OIDC_AUDIENCES`
/// (CSV). Durante Sprint 3-4 de migracao, contera 2 entradas em cada
/// lista (Zitadel + Authentik). Apos Sprint 6, apenas Authentik.
struct OIDCJWTValidators: Sendable {
    let allowedIssuers: Set<String>
    let allowedAudiences: Set<String>

    init(allowedIssuers: Set<String>, allowedAudiences: Set<String>) {
        self.allowedIssuers = allowedIssuers
        self.allowedAudiences = allowedAudiences
    }

    /// Constroi a partir de strings CSV (env vars). Retorna `nil` se qualquer
    /// lista vier vazia — fail-fast no boot e o comportamento correto: IdP
    /// mal configurado nao deve passar silent.
    static func fromValues(issuersCsv: String, audiencesCsv: String) -> OIDCJWTValidators? {
        let issuers = issuersCsv
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let audiences = audiencesCsv
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !issuers.isEmpty, !audiences.isEmpty else { return nil }

        return OIDCJWTValidators(
            allowedIssuers: Set(issuers),
            allowedAudiences: Set(audiences)
        )
    }
}

// MARK: - Application storage

/// Storage key para o validator no Application context.
private struct OIDCValidatorsKey: StorageKey {
    typealias Value = OIDCJWTValidators
}

extension Application {
    /// Validators OIDC registrados no boot (configure.swift).
    /// Falha cedo se nao configurado — JWTAuthMiddleware exige presenca.
    var oidcValidators: OIDCJWTValidators? {
        get { storage[OIDCValidatorsKey.self] }
        set { storage[OIDCValidatorsKey.self] = newValue }
    }
}

// MARK: - Bootstrap storage (defense-in-depth para verify(using:))

/// Storage global thread-safe dos validators OIDC, acessivel pelo
/// `OIDCJWTPayload.verify(using:)` que e chamado automaticamente por
/// `request.jwt.verify(as:)` em todo codepath. AppSec CRITICAL-1 (2026-05-14):
/// confiar somente no middleware para chamar `verify(validators:)` viola
/// defense-in-depth. Registrar aqui no boot garante que QUALQUER caminho de
/// verificacao JWT roda a validacao completa de iss/aud/exp/nbf.
final class OIDCJWTPayloadBootstrap: @unchecked Sendable {
    static let shared = OIDCJWTPayloadBootstrap()

    private let lock = NSLock()
    private var validators: OIDCJWTValidators?

    private init() {}

    func get() -> OIDCJWTValidators? {
        lock.lock()
        defer { lock.unlock() }
        return validators
    }

    func set(_ validators: OIDCJWTValidators) {
        lock.lock()
        defer { lock.unlock() }
        self.validators = validators
    }

    // Test-only — permite reset entre testes para evitar leak global.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        validators = nil
    }
}
