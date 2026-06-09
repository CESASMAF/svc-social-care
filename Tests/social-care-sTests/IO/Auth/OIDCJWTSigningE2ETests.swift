import Foundation
import JWT
import Testing
@testable import social_care_s

/// Detector de regressão de **segurança**: garante que o `exp` (formato epoch
/// Unix — como o Authentik emite) é decodificado corretamente pelo **caminho de
/// produção** e que um token expirado é REJEITADO.
///
/// Contexto: `request.jwt.verify(as:)` usa `DefaultJWTParser` →
/// `JWTJSONDecoder.defaultForJWT` (um `JSONDecoder` com
/// `dateDecodingStrategy = .secondsSince1970`). O `ExpirationClaim`
/// (`JWTUnixEpochClaim`) decodifica `Date` via `singleValueContainer().decode`,
/// que depende dessa estratégia. Em `FoundationEssentials` do Swift 6.2 a
/// estratégia não era aplicada ao container aninhado e o epoch era lido como
/// segundos-desde-2001 (exp ~31 anos no futuro → token expirado ACEITO). Isso
/// foi corrigido em 6.3 — verificado em `swift:6.3-jammy` (imagem de produção).
///
/// `OIDCJWTPayloadTests` testa a *lógica* de `verify(...)` de forma determinística
/// (sem `JSONDecoder`); este suite cobre o *decode platform-sensitive* do caminho
/// real. Se a toolchain regredir ou o decode quebrar, este teste falha primeiro.
@Suite("OIDC JWT — decode de exp no caminho de produção (regressão de segurança)")
struct OIDCJWTSigningE2ETests {

    /// Decoder IDÊNTICO ao usado por `request.jwt.verify` em produção
    /// (`DefaultJWTParser` / `JWTJSONDecoder.defaultForJWT`).
    private func productionDecode(_ json: String) throws -> OIDCJWTPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(OIDCJWTPayload.self, from: Data(json.utf8))
    }

    private let validators = OIDCJWTValidators(
        allowedIssuers: ["https://auth.acdgbrasil.com.br"],
        allowedAudiences: ["y"]
    )

    // MARK: - Decode de produção (JSON epoch-Unix, como o Authentik emite)

    @Test("token com exp epoch-Unix no passado é REJEITADO (decode de produção)")
    func expiredEpochIsRejected() async throws {
        // Arrange — exp 1h no passado, em epoch Unix literal (shape do Authentik).
        let pastEpoch = Int(Date(timeIntervalSinceNow: -3600).timeIntervalSince1970)
        let payload = try productionDecode("""
        {"sub":"a","iss":"https://auth.acdgbrasil.com.br","aud":"y","exp":\(pastEpoch)}
        """)

        // Act + Assert — verify deve lançar (exp no passado).
        await #expect(throws: JWTError.self) {
            try await payload.verify(validators: validators)
        }
    }

    @Test("token com exp epoch-Unix no futuro é ACEITO (decode de produção)")
    func validEpochIsAccepted() async throws {
        let futureEpoch = Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970)
        let payload = try productionDecode("""
        {"sub":"a","iss":"https://auth.acdgbrasil.com.br","aud":"y","exp":\(futureEpoch)}
        """)

        try await payload.verify(validators: validators)
        #expect(payload.sub.value == "a")
    }

    // MARK: - Round-trip real do JWTKit (encode + decode), igual à serialização de produção

    @Test("round-trip sign+parse do JWTKit preserva exp — token expirado é rejeitado")
    func signRoundTripPreservesExpiredExp() async throws {
        // Arrange — assina com o encoder real do JWTKit (.secondsSince1970).
        let keys = JWTKeyCollection()
        await keys.add(hmac: "test-only-secret-not-used-in-prod-0123456789", digestAlgorithm: .sha256)
        let expired = OIDCJWTPayload(
            sub: "a",
            exp: ExpirationClaim(value: Date(timeIntervalSinceNow: -3600)),
            iss: "https://auth.acdgbrasil.com.br",
            aud: "y",
            nbf: nil, roles: nil, groups: nil, projectRoles: nil,
            orgId: nil, personId: nil, legacySub: nil
        )
        let token = try await keys.sign(expired)

        // Act — decodifica pelo MESMO parser de produção.
        let decoded = try DefaultJWTParser().parse([UInt8](token.utf8), as: OIDCJWTPayload.self).payload

        // Assert — exp preservado como passado → rejeitado.
        await #expect(throws: JWTError.self) {
            try await decoded.verify(validators: validators)
        }
    }
}
