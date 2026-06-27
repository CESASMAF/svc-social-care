import Foundation

extension UpdateSocioEconomicSituationCommandHandler {
    /// Mapeia erros genéricos ou de domínio para o erro específico do Caso de Uso.
    public func mapError(_ error: Error, patientId: String? = nil) -> UpdateSocioEconomicSituationError {
        if let e = error as? UpdateSocioEconomicSituationError {
            return e
        }

        // ADR-010: PersistenceConflictError universal — fallback preserva detail.
        if let conflict = error as? PersistenceConflictError {
            return .persistenceMappingFailure(issues: [String(describing: conflict)])
        }

        if let e = error as? SocioEconomicSituationError {
            switch e {
            case .inconsistentSocialBenefit: return .inconsistentSocialBenefit
            case .missingSocialBenefits: return .missingSocialBenefits
            // ADR-009: negativeFamilyIncome/negativeIncomePerCapita eliminados (Money valida).
            case .emptyMainSourceOfIncome: return .emptyMainSourceOfIncome
            case .inconsistentIncomePerCapita(let perCapitaCentavos, let totalCentavos):
                return .inconsistentIncomePerCapita(perCapitaCentavos: perCapitaCentavos, totalCentavos: totalCentavos)
            }
        }

        if let e = error as? SocialBenefitError {
            switch e {
            case .benefitNameEmpty: return .benefitNameEmpty
            case .amountInvalid(let centavos): return .amountInvalid(centavos: centavos)
            }
        }

        // ADR-009: Money pode lançar ao construir a partir do Command (currency
        // inválida do DTO, ou valorReal que arredonda para negativo).
        if let e = error as? MoneyError {
            return .invalidMoneyValue(detail: String(describing: e))
        }
        
        if let e = error as? SocialBenefitsCollectionError {
            switch e {
            case .benefitsArrayNullOrUndefined: return .persistenceMappingFailure(issues: ["Benefits array is null"])
            case .duplicateBenefitNotAllowed(let name): return .duplicateBenefitNotAllowed(name: name)
            }
        }
        
        if let e = error as? PatientError {
            switch e {
            case .patientIsWaitlisted:
                return .patientNotActive(reason: "PATIENT_IS_WAITLISTED")
            case .patientIsDischarged:
                return .patientNotActive(reason: "PATIENT_IS_DISCHARGED")
            default:
                return .persistenceMappingFailure(issues: [String(describing: e)])
            }
        }

        if let e = error as? PatientIdError {
            switch e {
            case .invalidFormat(let value):
                return .invalidPersonIdFormat(value)
            }
        }

        if let e = error as? PIDError {
            switch e {
            case .invalidFormat(let value):
                return .invalidPersonIdFormat(value)
            }
        }
        
        return .persistenceMappingFailure(issues: [String(describing: error)])
    }
}
