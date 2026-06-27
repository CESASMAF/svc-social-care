import Vapor
import SQLKit

struct PatientController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let patients = routes.grouped("api", "v1", "patients")

        let read = patients.grouped(RoleGuardMiddleware("worker", "owner", "admin"))
        read.get(use: list)
        read.get(":patientId", use: getById)
        read.get("by-person", ":personId", use: getByPersonId)
        read.get(":patientId", "audit-trail", use: getAuditTrail)

        let write = patients.grouped(RoleGuardMiddleware("worker"))
        write.post(use: register)
        write.post(":patientId", "family-members", use: addFamilyMember)
        write.delete(":patientId", "family-members", ":memberId", use: removeFamilyMember)
        write.put(":patientId", "primary-caregiver", use: assignPrimaryCaregiver)
        write.put(":patientId", "social-identity", use: updateSocialIdentity)

        let lifecycle = patients.grouped(RoleGuardMiddleware("worker", "admin"))
        lifecycle.post(":patientId", "discharge", use: discharge)
        lifecycle.post(":patientId", "readmit", use: readmit)
        lifecycle.post(":patientId", "admit", use: admit)
        lifecycle.post(":patientId", "withdraw", use: withdraw)
    }

    // MARK: - Patient List

    @Sendable
    private func list(req: Request) async throws -> PaginatedResponse<[PatientSummaryResponse]> {
        let search: String? = req.query[String.self, at: "search"]
        let status: String? = req.query[String.self, at: "status"]
        let cursor: String? = req.query[String.self, at: "cursor"]
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 20, 1), 100)

        let query = ListPatientsQuery(search: search, status: status, cursor: cursor, limit: limit)
        let result = try await req.services.listPatients.handle(query)

        let items = result.items.map { PatientSummaryResponse(from: $0) }
        return PaginatedResponse(
            data: items,
            pageSize: limit,
            totalCount: result.totalCount,
            hasMore: result.hasMore,
            nextCursor: result.nextCursor
        )
    }

    // MARK: - Patient CRUD

    @Sendable
    private func register(req: Request) async throws -> Response {
        let actorId = try req.extractActorId()
        // ADR-011 / ADR-023: extrai Bearer do request para forwarding ao people-context.
        let bearer = req.headers.bearerAuthorization?.token
        let body = try req.content.decode(RegisterPatientRequest.self)
        let id = try await req.services.registerPatient.handle(body.toCommand(actorId: actorId, bearer: bearer))
        let response = StandardResponse(data: IdResponse(id: id))
        return try await response.encodeResponse(status: .created, for: req)
    }

    @Sendable
    private func getById(req: Request) async throws -> StandardResponse<PatientResponse> {
        let patientIdStr = try req.parameters.require("patientId")
        let patientId: PatientId
        do { patientId = try PatientId(patientIdStr) }
        catch { throw Abort(.badRequest, reason: "Invalid patient ID format.") }
        guard let patient = try await req.services.patientRepository.find(byId: patientId) else {
            throw Abort(.notFound, reason: "Patient not found.")
        }
        return StandardResponse(data: PatientResponse(from: patient))
    }

    @Sendable
    private func getByPersonId(req: Request) async throws -> StandardResponse<PatientResponse> {
        let personId = try req.parameters.require("personId")
        guard let validPersonId = try? PersonId(personId) else {
            throw Abort(.badRequest, reason: "Invalid person ID format.")
        }
        guard let patient = try await req.services.patientRepository.find(byPersonId: validPersonId) else {
            throw Abort(.notFound, reason: "Patient not found.")
        }
        return StandardResponse(data: PatientResponse(from: patient))
    }

    // MARK: - Family Members

    @Sendable
    private func addFamilyMember(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let patientId = try req.parameters.require("patientId")
        let body = try req.content.decode(AddFamilyMemberRequest.self)
        let command = AddFamilyMemberCommand(
            patientId: patientId,
            memberPersonId: body.memberPersonId,
            relationship: body.relationship,
            isResiding: body.isResiding,
            isCaregiver: body.isCaregiver,
            hasDisability: body.hasDisability,
            requiredDocuments: body.requiredDocuments,
            birthDate: body.birthDate,
            prRelationshipId: body.prRelationshipId,
            actorId: actorId
        )
        try await req.services.addFamilyMember.handle(command)
        return .noContent
    }

    @Sendable
    private func removeFamilyMember(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let patientId = try req.parameters.require("patientId")
        let memberId = try req.parameters.require("memberId")
        let command = RemoveFamilyMemberCommand(patientId: patientId, memberId: memberId, actorId: actorId)
        try await req.services.removeFamilyMember.handle(command)
        return .noContent
    }

    @Sendable
    private func assignPrimaryCaregiver(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let patientId = try req.parameters.require("patientId")
        let body = try req.content.decode(AssignPrimaryCaregiverRequest.self)
        let command = AssignPrimaryCaregiverCommand(
            patientId: patientId, memberPersonId: body.memberPersonId, actorId: actorId
        )
        try await req.services.assignPrimaryCaregiver.handle(command)
        return .noContent
    }

    @Sendable
    private func updateSocialIdentity(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let patientId = try req.parameters.require("patientId")
        let body = try req.content.decode(UpdateSocialIdentityRequest.self)
        let command = UpdateSocialIdentityCommand(
            patientId: patientId, typeId: body.typeId, description: body.description, actorId: actorId
        )
        try await req.services.updateSocialIdentity.handle(command)
        return .noContent
    }

    // MARK: - Patient Lifecycle (Discharge / Readmit)

    @Sendable
    private func discharge(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let patientId = try req.parameters.require("patientId")
        let body = try req.content.decode(DischargePatientRequest.self)
        let command = DischargePatientCommand(
            patientId: patientId,
            reason: body.reason,
            notes: body.notes,
            actorId: actorId
        )
        try await req.services.dischargePatient.handle(command)
        return .noContent
    }

    @Sendable
    private func readmit(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let patientId = try req.parameters.require("patientId")
        let body = try req.content.decode(ReadmitPatientRequest.self)
        let command = ReadmitPatientCommand(
            patientId: patientId,
            notes: body.notes,
            actorId: actorId
        )
        try await req.services.readmitPatient.handle(command)
        return .noContent
    }

    // MARK: - Waitlist Lifecycle (Admit / Withdraw)

    @Sendable
    private func admit(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let patientId = try req.parameters.require("patientId")
        let command = AdmitPatientCommand(patientId: patientId, actorId: actorId)
        try await req.services.admitPatient.handle(command)
        return .noContent
    }

    @Sendable
    private func withdraw(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let patientId = try req.parameters.require("patientId")
        let body = try req.content.decode(WithdrawPatientRequest.self)
        let command = WithdrawFromWaitlistCommand(
            patientId: patientId,
            reason: body.reason,
            notes: body.notes,
            actorId: actorId
        )
        try await req.services.withdrawFromWaitlist.handle(command)
        return .noContent
    }

    // MARK: - Audit Trail

    @Sendable
    private func getAuditTrail(req: Request) async throws -> StandardResponse<[AuditTrailEntryResponse]> {
        let patientIdStr = try req.parameters.require("patientId")
        guard let patientUUID = UUID(uuidString: patientIdStr) else {
            throw Abort(.badRequest, reason: "Invalid patient ID format.")
        }

        let eventType = req.query[String.self, at: "eventType"]
        let limit = min(req.query[Int.self, at: "limit"] ?? 50, 200)
        let offset = max(req.query[Int.self, at: "offset"] ?? 0, 0)

        let db = req.services.db
        var query = db.select()
            .column(SQLColumn("*"))
            .from("audit_trail")
            .where("aggregate_id", .equal, patientUUID)

        if let eventType {
            query = query.where("event_type", .equal, eventType)
        }

        let rows = try await query
            .orderBy("occurred_at", .descending)
            .limit(limit)
            .offset(offset)
            .all(decoding: AuditTrailModel.self)

        let entries = rows.map { AuditTrailEntryResponse(from: $0) }
        return StandardResponse(data: entries)
    }
}
