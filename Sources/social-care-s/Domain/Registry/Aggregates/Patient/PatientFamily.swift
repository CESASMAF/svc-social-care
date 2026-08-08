import Foundation

extension Patient {

    // MARK: - Family Management

    /// Adiciona um novo membro familiar ao agregado do paciente.
    ///
    /// - Parameters:
    ///   - member: A entidade FamilyMember a ser adicionada.
    ///   - actorId: Identificador do ator que realizou a operação.
    ///   - date: O instante da operação para fins de registro de evento.
    ///   - primaryReferenceId: O ID que identifica a Pessoa de Referência para validação.
    /// - Throws: `PatientError.familyMemberAlreadyExists` se a pessoa já estiver registrada na família.
    public mutating func addMember(_ member: FamilyMember, actorId: String, at date: TimeStamp = .now, primaryReferenceId: LookupId) throws {
        try requireActive()
        let exists = familyMembers.contains { $0.personId == member.personId }

        guard !exists else {
            throw PatientError.familyMemberAlreadyExists(memberId: member.personId.description)
        }

        // Se o novo membro for uma PR, validar se já existe uma
        if member.relationshipId == primaryReferenceId {
            let hasPR = familyMembers.contains { $0.relationshipId == primaryReferenceId }
            if hasPR { throw PatientError.multiplePrimaryReferencesNotAllowed }
        }

        // "Principal" so faz sentido se for UM: `assignPrimaryCaregiver` revoga os demais, mas quem
        // entrava JA marcado como cuidador escapava dessa regra — bastava marcar "e cuidador(a)" ao
        // adicionar e o paciente ficava com dois cuidadores principais ao mesmo tempo. A invariante
        // vale agora em todo caminho de escrita, nao so no que passa pela rota dedicada.
        if member.isPrimaryCaregiver {
            for index in familyMembers.indices {
                familyMembers[index].revokePrimaryCaregiver()
            }
        }

        self.familyMembers.append(member)

        self.recordEvent(FamilyMemberAddedEvent(
            patientId: id.description,
            memberId: member.personId.description,
            relationship: member.relationshipId.description,
            actorId: actorId,
            occurredAt: date.date
        ))
    }

    /// Remove um membro familiar do agregado através do seu PersonId.
    ///
    /// - Parameters:
    ///   - personId: O identificador da pessoa a ser removida.
    ///   - actorId: Identificador do ator que realizou a operação.
    ///   - date: O instante da operação.
    /// - Throws: `PatientError.familyMemberNotFound` se o membro não pertencer à família.
    public mutating func removeMember(identifiedBy personId: PersonId, actorId: String, at date: TimeStamp = .now) throws {
        try requireActive()
        guard let index = familyMembers.firstIndex(where: { $0.personId == personId }) else {
            throw PatientError.familyMemberNotFound(personId: personId.description)
        }

        let removed = self.familyMembers.remove(at: index)

        self.recordEvent(FamilyMemberRemovedEvent(
            patientId: id.description,
            memberId: removed.personId.description,
            actorId: actorId,
            occurredAt: date.date
        ))
    }

    /// Atribui uma pessoa como cuidador principal, revogando o status dos demais.
    ///
    /// - Parameters:
    ///   - personId: O identificador da pessoa que assumirá o cuidado.
    ///   - actorId: Identificador do ator que realizou a operação.
    ///   - date: O instante da operação.
    /// - Throws: `PatientError.familyMemberNotFound` se a pessoa não pertencer à família.
    public mutating func assignPrimaryCaregiver(identifiedBy personId: PersonId, actorId: String, at date: TimeStamp = .now) throws {
        try requireActive()
        guard familyMembers.contains(where: { $0.personId == personId }) else {
            throw PatientError.familyMemberNotFound(personId: personId.description)
        }

        // Mutação In-Place idiomática
        for index in familyMembers.indices {
            if familyMembers[index].personId == personId {
                familyMembers[index].assignAsPrimaryCaregiver()
            } else {
                familyMembers[index].revokePrimaryCaregiver()
            }
        }

        self.recordEvent(PrimaryCaregiverAssignedEvent(
            patientId: id.description,
            caregiverId: personId.description,
            actorId: actorId,
            occurredAt: date.date
        ))
    }
}
