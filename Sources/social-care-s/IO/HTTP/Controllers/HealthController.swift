import Vapor
import SQLKit

struct HealthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("health", use: liveness)
        routes.get("ready", use: readiness)
    }

    @Sendable
    private func liveness(req: Request) async throws -> HTTPStatus {
        .ok
    }

    @Sendable
    private func readiness(req: Request) async throws -> Response {
        do {
            try await req.services.db.raw("SELECT 1").run()
            let body = ReadinessResponse(status: "ready")
            return try await body.encodeResponse(status: .ok, for: req)
        } catch {
            req.logger.error("Readiness check failed", metadata: LogSanitizer.metadata(for: error))
            let body = ReadinessResponse(status: "unavailable")
            return try await body.encodeResponse(status: .serviceUnavailable, for: req)
        }
    }
}

private struct ReadinessResponse: Content {
    let status: String
}
