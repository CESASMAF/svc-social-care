import Foundation

public struct PatientQueryDTO: Codable, Sendable {
    public let patientId: String
    public let personId: String
    public let version: Int
    public let familyMembers: [FamilyMemberDTO]
    public let diagnoses: [DiagnosisDTO]
    public let personalData: PersonalDataDTO?
    public let housingCondition: HousingConditionDTO?
    public let workAndIncome: WorkAndIncomeDTO?
    
    public init(from patient: Patient) {
        self.patientId = patient.id.description
        self.personId = patient.personId.description
        self.version = patient.version
        
        self.familyMembers = patient.familyMembers.map { FamilyMemberDTO(from: $0) }
        self.diagnoses = patient.diagnoses.map { DiagnosisDTO(from: $0) }
        
        self.personalData = patient.personalData.map { PersonalDataDTO(from: $0) }
        self.housingCondition = patient.housingCondition.map { HousingConditionDTO(from: $0) }
        self.workAndIncome = patient.workAndIncome.map { WorkAndIncomeDTO(from: $0) }
    }
}

public struct FamilyMemberDTO: Codable, Sendable {
    public let personId: String
    public let relationship: String
    
    public init(from member: FamilyMember) {
        self.personId = member.personId.description
        self.relationship = member.relationshipId.description
    }
}

public struct DiagnosisDTO: Codable, Sendable {
    public let icdCode: String
    public let description: String
    
    public init(from diagnosis: Diagnosis) {
        self.icdCode = diagnosis.id.value
        self.description = diagnosis.description
    }
}

public struct PersonalDataDTO: Codable, Sendable {
    public let firstName: String
    public let lastName: String
    public init(from data: PersonalData) { 
        self.firstName = data.firstName 
        self.lastName = data.lastName
    }
}

public struct HousingConditionDTO: Codable, Sendable {
    public let type: String
    public init(from data: HousingCondition) { self.type = data.type.rawValue }
}

public struct WorkAndIncomeDTO: Codable, Sendable {
    /// Total agregado em valor real (ex: `1234.56`). ADR-009: cálculo usa
    /// soma exata de `Money` (centavos), e só na fronteira HTTP serializa
    /// como Double para JSON.
    public let totalWorkIncome: Double
    public init(from data: WorkAndIncome) {
        let totalCentavos = data.individualIncomes.reduce(Int64(0)) { $0 + $1.monthlyAmount.centavos }
        self.totalWorkIncome = Double(totalCentavos) / 100.0
    }
}
