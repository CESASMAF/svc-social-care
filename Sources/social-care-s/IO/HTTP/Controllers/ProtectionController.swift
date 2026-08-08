import Vapor

struct ProtectionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let patient = routes.grouped("api", "v1", "patients", ":patientId")
            .grouped(RoleGuardMiddleware("worker"))

        patient.put("placement-history", use: updatePlacementHistory)
        patient.post("violation-reports", use: reportRightsViolation)
        patient.post("referrals", use: createReferral)
    }

    @Sendable
    private func updatePlacementHistory(req: Request) async throws -> HTTPStatus {
        let actorId = try req.extractActorId()
        let patientId = try req.parameters.require("patientId")
        let body = try req.content.decode(UpdatePlacementHistoryRequest.self)

        guard let pid = try? PatientId(patientId),
              let patient = try await req.services.patientRepository.find(byId: pid) else {
            throw Abort(.notFound, reason: "Patient not found.")
        }
        let crossValidator = CrossValidator(patient: patient)
        try crossValidator.validatePlacementHistory(
            registries: body.registries,
            thirdPartyGuardReport: body.collectiveSituations.thirdPartyGuardReport,
            adolescentInInternment: body.separationChecklist.adolescentInInternment
        )

        let command = UpdatePlacementHistoryCommand(
            patientId: patientId,
            registries: body.registries.map {
                .init(memberId: $0.memberId, startDate: $0.startDate,
                      endDate: $0.endDate, reason: $0.reason)
            },
            collectiveSituations: .init(
                homeLossReport: body.collectiveSituations.homeLossReport,
                thirdPartyGuardReport: body.collectiveSituations.thirdPartyGuardReport
            ),
            separationChecklist: .init(
                adultInPrison: body.separationChecklist.adultInPrison,
                adolescentInInternment: body.separationChecklist.adolescentInInternment
            ),
            actorId: actorId
        )
        try await req.services.updatePlacementHistory.handle(command)
        return .noContent
    }

    @Sendable
    private func reportRightsViolation(req: Request) async throws -> Response {
        let actorId = try req.extractActorId()
        let patientId = try req.parameters.require("patientId")
        let body = try req.content.decode(ReportRightsViolationRequest.self)

        let validator = MetadataValidator(db: req.services.db)
        // O catalogo manda: quando vem `violationTypeId` (o que a tela envia), a categoria de dominio
        // e DERIVADA dele — o `violationType` do corpo vira fallback do contrato legado. Assim os dois
        // vocabularios nao podem mais divergir.
        let derivedType = try await validator.validateViolationType(
            typeId: body.violationTypeId,
            descriptionOfFact: body.descriptionOfFact
        )

        let command = ReportRightsViolationCommand(
            patientId: patientId,
            victimId: body.victimId,
            violationType: derivedType?.rawValue ?? body.violationType,
            reportDate: body.reportDate,
            incidentDate: body.incidentDate,
            descriptionOfFact: body.descriptionOfFact,
            actionsTaken: body.actionsTaken,
            actorId: actorId
        )
        let id = try await req.services.reportRightsViolation.handle(command)
        let response = StandardResponse(data: IdResponse(id: id))
        return try await response.encodeResponse(status: .created, for: req)
    }

    @Sendable
    private func createReferral(req: Request) async throws -> Response {
        let actorId = try req.extractActorId()
        let patientId = try req.parameters.require("patientId")
        let body = try req.content.decode(CreateReferralRequest.self)
        let command = CreateReferralCommand(
            patientId: patientId,
            referredPersonId: body.referredPersonId,
            professionalId: body.professionalId,
            destinationService: body.destinationService,
            reason: body.reason,
            date: body.date,
            actorId: actorId
        )
        let id = try await req.services.createReferral.handle(command)
        let response = StandardResponse(data: IdResponse(id: id))
        return try await response.encodeResponse(status: .created, for: req)
    }
}
