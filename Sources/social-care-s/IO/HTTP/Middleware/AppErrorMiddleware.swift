import Vapor

struct AppErrorMiddleware: AsyncMiddleware {
    private static let verboseErrors: Bool = {
        let isProduction = Environment.get("ENVIRONMENT") == "production"
        return !isProduction && Environment.get("VERBOSE_ERRORS") == "true"
    }()

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            let response = try await next.respond(to: request)
            return response
        } catch let appError as AppError {
            logAppError(appError, request: request)
            return makeResponse(
                status: HTTPResponseStatus(statusCode: appError.http ?? 500),
                code: appError.code,
                message: appError.message,
                safeContext: appError.safeContext,
                request: request
            )
        } catch let convertible as AppErrorConvertible {
            let appError = convertible.asAppError
            logAppError(appError, request: request)
            return makeResponse(
                status: HTTPResponseStatus(statusCode: appError.http ?? 500),
                code: appError.code,
                message: appError.message,
                safeContext: appError.safeContext,
                request: request
            )
        } catch let abort as AbortError {
            return makeResponse(
                status: abort.status,
                code: "HTTP-\(abort.status.code)",
                message: abort.reason,
                request: request
            )
        } catch {
            request.logger.error("Unhandled error", metadata: LogSanitizer.metadata(for: error))
            return makeResponse(
                status: .internalServerError,
                code: "SYS-500",
                message: "Erro interno do servidor.",
                request: request
            )
        }
    }

    private func logAppError(_ appError: AppError, request: Request) {
        let safeDescription = appError.safeContext.map { "\($0.key): \($0.value.value)" }.joined(separator: ", ")
        request.logger.error("\(appError.code) [\(appError.kind)] \(appError.message) safeContext: {\(safeDescription)}")
    }

    private func makeResponse(
        status: HTTPResponseStatus,
        code: String,
        message: String,
        safeContext: [String: AnySendable] = [:],
        request: Request
    ) -> Response {
        var body: [String: String] = [
            "code": code,
            "message": message
        ]
        if Self.verboseErrors && !safeContext.isEmpty {
            body["details"] = safeContext.map { "\($0.key): \($0.value.value)" }.joined(separator: "; ")
        }
        do {
            let data = try JSONEncoder().encode(["error": body])
            var headers = HTTPHeaders()
            headers.contentType = .json
            return Response(status: status, headers: headers, body: .init(data: data))
        } catch {
            return Response(status: .internalServerError)
        }
    }
}
