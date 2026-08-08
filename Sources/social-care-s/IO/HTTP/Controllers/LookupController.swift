import Vapor
import SQLKit

struct LookupController: RouteCollection {
    private static let allowedTables = AllowedLookupTables.all

    func boot(routes: any RoutesBuilder) throws {
        let dominios = routes.grouped("api", "v1", "dominios")

        // Read: list lookup items (worker, owner, admin)
        let read = dominios.grouped(RoleGuardMiddleware("worker", "owner", "admin"))
        read.get(":tableName", use: list)

        // Lookup Requests: rotas registradas ANTES de :tableName para evitar captura
        let requestsRead = dominios.grouped("requests")
            .grouped(RoleGuardMiddleware("worker", "owner", "admin"))
        requestsRead.get(use: listRequests)

        let requestsWrite = dominios.grouped("requests")
            .grouped(RoleGuardMiddleware("worker", "admin"))
        requestsWrite.post(use: createRequest)

        let requestsAdmin = dominios.grouped("requests")
            .grouped(RoleGuardMiddleware("admin"))
        requestsAdmin.put(":requestId", "approve", use: approveRequest)
        requestsAdmin.put(":requestId", "reject", use: rejectRequest)

        // Admin CRUD: create, update, toggle items
        let admin = dominios.grouped(RoleGuardMiddleware("admin"))
        admin.post(":tableName", use: createItem)
        admin.put(":tableName", ":itemId", use: updateItem)
        admin.patch(":tableName", ":itemId", "toggle", use: toggleItem)
    }

    // MARK: - Read (existing)

    @Sendable
    private func list(req: Request) async throws -> StandardResponse<[LookupItemResponse]> {
        let tableName = try req.parameters.require("tableName")

        guard Self.allowedTables.contains(tableName) else {
            throw Abort(.notFound, reason: "Requested domain table not found.")
        }

        let db = req.services.db
        let rows = try await db.select()
            .column("id")
            .column("codigo")
            .column("descricao")
            .from(tableName)
            .where("ativo", .equal, true)
            .orderBy("codigo")
            .all()

        // `LookupId` normaliza todo id de dominio para MINUSCULO (ver LookupId.init) — essa e a forma
        // canonica com que os ids saem dentro dos agregados de paciente. `UUID.uuidString` devolve
        // MAIUSCULO, entao o catalogo saia num formato e o valor salvo em outro: no <select> do front
        // nenhum <option value> casava com o valor gravado e o campo caia na primeira opcao, mostrando
        // ao profissional um dado que nao era o registrado. Sai pelo mesmo value object do dominio.
        let items = try rows.map { row in
            LookupItemResponse(
                id: try LookupId(row.decode(column: "id", as: UUID.self).uuidString).description,
                codigo: try row.decode(column: "codigo", as: String.self),
                descricao: try row.decode(column: "descricao", as: String.self)
            )
        }

        return StandardResponse(data: items)
    }

    // MARK: - Admin CRUD

    @Sendable
    private func createItem(req: Request) async throws -> Response {
        let actorId = try req.extractActorId()
        let tableName = try req.parameters.require("tableName")
        let body = try req.content.decode(CreateLookupItemRequest.self)

        let metadata = LookupItemMetadata(
            exigeRegistroNascimento: body.exigeRegistroNascimento,
            exigeCpfFalecido: body.exigeCpfFalecido,
            exigeDescricao: body.exigeDescricao
        )

        let command = CreateLookupItemCommand(
            tableName: tableName,
            codigo: body.codigo,
            descricao: body.descricao,
            metadata: metadata,
            actorId: actorId
        )

        let id = try await req.services.createLookupItem.handle(command)
        let response = StandardResponse(data: IdResponse(id: id))
        return try await response.encodeResponse(status: .created, for: req)
    }

    @Sendable
    private func updateItem(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let tableName = try req.parameters.require("tableName")
        let itemId = try req.parameters.require("itemId")
        let body = try req.content.decode(UpdateLookupItemRequest.self)

        let command = UpdateLookupItemCommand(
            tableName: tableName, itemId: itemId, descricao: body.descricao, actorId: actorId
        )
        try await req.services.updateLookupItem.handle(command)
        return .noContent
    }

    @Sendable
    private func toggleItem(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let tableName = try req.parameters.require("tableName")
        let itemId = try req.parameters.require("itemId")

        let command = ToggleLookupItemCommand(
            tableName: tableName, itemId: itemId, actorId: actorId
        )
        try await req.services.toggleLookupItem.handle(command)
        return .noContent
    }

    // MARK: - Lookup Requests

    @Sendable
    private func createRequest(req: Request) async throws -> Response {
        let actorId = try req.extractActorId()
        let body = try req.content.decode(CreateLookupRequestRequest.self)

        let command = CreateLookupRequestCommand(
            tableName: body.tableName,
            codigo: body.codigo,
            descricao: body.descricao,
            justificativa: body.justificativa,
            actorId: actorId
        )

        let id = try await req.services.createLookupRequest.handle(command)
        let response = StandardResponse(data: IdResponse(id: id))
        return try await response.encodeResponse(status: .created, for: req)
    }

    @Sendable
    private func listRequests(req: Request) async throws -> StandardResponse<[LookupRequestResponse]> {
        let user = try req.requireAuthenticatedUser()
        let status: String? = req.query[String.self, at: "status"]

        // Admin vê todas; worker vê apenas as próprias
        let requestedBy: String? = user.hasAnyRole(Set(["admin"])) ? nil : user.userId

        let query = ListLookupRequestsQuery(status: status, requestedBy: requestedBy)
        let results = try await req.services.listLookupRequests.handle(query)

        let items = results.map { LookupRequestResponse(from: $0) }
        return StandardResponse(data: items)
    }

    @Sendable
    private func approveRequest(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let requestId = try req.parameters.require("requestId")

        let command = ApproveLookupRequestCommand(requestId: requestId, actorId: actorId)
        try await req.services.approveLookupRequest.handle(command)
        return .noContent
    }

    @Sendable
    private func rejectRequest(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let requestId = try req.parameters.require("requestId")
        let body = try req.content.decode(RejectLookupRequestRequest.self)

        let command = RejectLookupRequestCommand(
            requestId: requestId, reviewNote: body.reviewNote, actorId: actorId
        )
        try await req.services.rejectLookupRequest.handle(command)
        return .noContent
    }
}
