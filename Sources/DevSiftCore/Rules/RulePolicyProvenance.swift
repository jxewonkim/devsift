/// Bounded, classifier-owned version metadata for one policy decision.
///
/// Provenance is not an authenticity proof or cleanup authority. Each revision
/// owner must increment its version whenever the corresponding semantics
/// change, including changes that do not alter an individual rule revision.
public struct RulePolicyProvenance: Hashable, Sendable {
  public let classificationContractRevision: RuleRevision
  public let catalogRevision: RuleRevision
  public let ruleRevisions: [RuleRevision]

  public init(
    classificationContractRevision: RuleRevision,
    catalogRevision: RuleRevision,
    ruleRevisions: [RuleRevision]
  ) throws {
    guard ruleRevisions.count <= RuleCatalogLimits.maximumRules else {
      throw RulePolicyProvenanceValidationError.tooManyRuleRevisions(
        maximum: RuleCatalogLimits.maximumRules,
        actual: ruleRevisions.count
      )
    }

    var identifiers = Set<RuleIdentifier>()
    for revision in ruleRevisions {
      guard identifiers.insert(revision.identifier).inserted else {
        throw RulePolicyProvenanceValidationError.duplicateRuleIdentifier(
          revision.identifier
        )
      }
    }

    self.classificationContractRevision = classificationContractRevision
    self.catalogRevision = catalogRevision
    self.ruleRevisions = ruleRevisions.sorted()
  }
}

public enum RulePolicyProvenanceValidationError: Error, Equatable, Sendable {
  case tooManyRuleRevisions(maximum: Int, actual: Int)
  case duplicateRuleIdentifier(RuleIdentifier)
}
