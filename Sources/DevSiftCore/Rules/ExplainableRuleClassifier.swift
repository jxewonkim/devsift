import Foundation

public struct ExplainableRuleClassifier: RuleClassifying, Sendable {
  private let rules: [any ExplainableRule]
  private let evidenceObserver: any RuleEvidenceObserving

  public init() {
    let builtIns = BuiltInRuleCatalog.rules
    do {
      try Self.validateCatalog(builtIns)
    } catch {
      preconditionFailure("The built-in rule catalog is invalid: \(error)")
    }
    rules = builtIns.sorted { $0.definition.revision < $1.definition.revision }
    evidenceObserver = DescriptorRuleEvidenceObserver()
  }

  public init(rules: [any ExplainableRule]) throws {
    try Self.validateCatalog(rules)
    self.rules = rules.sorted { $0.definition.revision < $1.definition.revision }
    evidenceObserver = DescriptorRuleEvidenceObserver()
  }

  init(
    rules: [any ExplainableRule],
    evidenceObserver: any RuleEvidenceObserving
  ) throws {
    try Self.validateCatalog(rules)
    self.rules = rules.sorted { $0.definition.revision < $1.definition.revision }
    self.evidenceObserver = evidenceObserver
  }

  public func classify(
    _ request: RuleClassificationRequest
  ) async throws -> RuleClassificationReport {
    try Self.validateObservationCount(request.report.topLevelItems.count)
    try ScanReportPreflight.validate(request.report)
    let evidence = try await evidenceObserver.observe(request)
    let observations = ScanReportRuleAdapter.observations(for: request, evidence: evidence)
    let report = try await classify(
      observations: observations,
      referenceUnixSeconds: request.referenceUnixSeconds
    )
    try report.validate(for: request)
    return report
  }

  func classify(
    observations: [RuleObservation],
    referenceUnixSeconds: Int64
  ) async throws -> RuleClassificationReport {
    try Self.validateObservationCount(observations.count)
    var result: [RuleEvaluation] = []
    let orderedObservations = observations.sorted(by: observationOrder)
    var index = orderedObservations.startIndex

    while index < orderedObservations.endIndex {
      try Task.checkCancellation()
      let path = orderedObservations[index].summary.path
      var endIndex = orderedObservations.index(after: index)
      while endIndex < orderedObservations.endIndex,
        orderedObservations[endIndex].summary.path == path
      {
        endIndex = orderedObservations.index(after: endIndex)
      }

      if orderedObservations.distance(from: index, to: endIndex) > 1 {
        result.append(duplicateObservationEvaluation(for: path))
      } else {
        result.append(
          contentsOf: evaluations(
            for: orderedObservations[index],
            referenceUnixSeconds: referenceUnixSeconds
          )
        )
      }
      index = endIndex
    }

    return RuleClassificationReport(
      referenceUnixSeconds: referenceUnixSeconds,
      evaluations: result
    )
  }

  private func evaluations(
    for observation: RuleObservation,
    referenceUnixSeconds: Int64
  ) -> [RuleEvaluation] {
    let assessments = rules.map { rule in
      AssessedRule(
        rule: rule,
        assessment: rule.assess(observation),
        orderedRuleFindings: nil
      )
    }
    .map { assessed in
      AssessedRule(
        rule: assessed.rule,
        assessment: assessed.assessment,
        orderedRuleFindings: orderedFindings(
          assessed.assessment.findings,
          for: assessed.rule.definition
        )
      )
    }

    let recognized = assessments.filter { assessed in
      assessed.assessment.recognition == .recognized
    }

    guard !recognized.isEmpty else {
      return [unrecognizedEvaluation(for: observation)]
    }
    if recognized.contains(where: { $0.orderedRuleFindings == nil }) {
      return [invalidRuleAggregate(for: observation, assessments: recognized)]
    }
    guard recognized.count == 1, let assessed = recognized.first else {
      return [conflictEvaluation(for: observation, assessments: recognized)]
    }
    return [
      evaluation(
        assessed,
        observation: observation,
        referenceUnixSeconds: referenceUnixSeconds
      )
    ]
  }

  private func evaluation(
    _ assessed: AssessedRule,
    observation: RuleObservation,
    referenceUnixSeconds: Int64
  ) -> RuleEvaluation {
    let definition = assessed.rule.definition
    let lexicalFinding = RuleFinding(
      identifier: AutomaticCheckIdentifier.lexicalRecognition,
      kind: .lexicalRecognition,
      state: assessed.assessment.recognition == .recognized ? .satisfied : .failed,
      explanation: definition.recognitionExplanation
    )

    guard let orderedRuleFindings = assessed.orderedRuleFindings else {
      let validityFinding = RuleFinding(
        identifier: AutomaticCheckIdentifier.ruleValidity,
        kind: .ruleValidity,
        state: .failed,
        explanation:
          "The rule returned missing, duplicate, unexpected, mismatched, or empty findings."
      )
      return makeEvaluation(
        definition: definition,
        observation: observation,
        state: .invalidRule,
        disposition: .protected,
        findings: [lexicalFinding, validityFinding],
        explanation: "The rule result was invalid, so this item remains protected."
      )
    }

    var findings = [lexicalFinding]
    findings.append(contentsOf: orderedRuleFindings)
    findings.append(reproducibilityFinding(for: definition))
    findings.append(
      ageFinding(
        requirement: definition.ageRequirement,
        observation: observation.facts.newestContentModificationUnixSeconds,
        referenceUnixSeconds: referenceUnixSeconds
      )
    )
    findings.append(
      activityFinding(
        requirement: definition.activityRequirement,
        observation: observation.facts.activity
      )
    )
    findings.append(contentsOf: integrityFindings(observation.integrity))

    let hasBlockingFinding = findings.contains { finding in
      finding.state != .satisfied
    }
    if hasBlockingFinding {
      return makeEvaluation(
        definition: definition,
        observation: observation,
        state: .possibleMatch,
        disposition: .protected,
        findings: findings,
        explanation:
          "The name matched, but required evidence was failed or unknown; the item remains protected."
      )
    }

    let disposition = definition.eligibleDisposition
    let dispositionExplanation: String
    switch disposition {
    case .reclaimable:
      dispositionExplanation =
        "All required evidence was satisfied; the item is classified as reclaimable."
    case .reviewRequired:
      dispositionExplanation =
        "All required evidence was satisfied, but this rule requires explicit review."
    case .protected:
      dispositionExplanation = "This rule protects the item."
    }

    return makeEvaluation(
      definition: definition,
      observation: observation,
      state: .matched,
      disposition: disposition,
      findings: findings,
      explanation: dispositionExplanation
    )
  }

  private func unrecognizedEvaluation(for observation: RuleObservation) -> RuleEvaluation {
    RuleEvaluation(
      path: observation.summary.path,
      rule: nil,
      matchingRules: [],
      displayName: "Unrecognized data",
      responsibleTool: "Unknown",
      matchState: .unrecognized,
      disposition: .protected,
      reproducibility: .unknown,
      findings: [
        RuleFinding(
          identifier: AutomaticCheckIdentifier.lexicalRecognition,
          kind: .lexicalRecognition,
          state: .failed,
          explanation: "No built-in rule recognized this exact raw filesystem path."
        )
      ],
      explanation: "No rule recognized this item, so it remains protected."
    )
  }

  private func conflictEvaluation(
    for observation: RuleObservation,
    assessments: [AssessedRule]
  ) -> RuleEvaluation {
    let revisions = assessments.map { $0.rule.definition.revision }.sorted()
    return RuleEvaluation(
      path: observation.summary.path,
      rule: nil,
      matchingRules: revisions,
      displayName: "Conflicting rules",
      responsibleTool: "Multiple tools",
      matchState: .conflict,
      disposition: .protected,
      reproducibility: .unknown,
      findings: [
        RuleFinding(
          identifier: AutomaticCheckIdentifier.ruleConflict,
          kind: .conflict,
          state: .failed,
          explanation: "More than one rule recognized this exact raw path."
        )
      ],
      explanation: "Multiple rules recognized this item, so it remains protected."
    )
  }

  private func invalidRuleAggregate(
    for observation: RuleObservation,
    assessments: [AssessedRule]
  ) -> RuleEvaluation {
    let revisions = assessments.map { $0.rule.definition.revision }.sorted()
    return RuleEvaluation(
      path: observation.summary.path,
      rule: nil,
      matchingRules: revisions,
      displayName: "Invalid rule result",
      responsibleTool: "Rule catalog",
      matchState: .invalidRule,
      disposition: .protected,
      reproducibility: .unknown,
      findings: [
        RuleFinding(
          identifier: AutomaticCheckIdentifier.ruleValidity,
          kind: .ruleValidity,
          state: .failed,
          explanation:
            "At least one recognized rule returned missing, duplicate, unexpected, mismatched, oversized, or empty findings."
        )
      ],
      explanation: "A recognized rule result was invalid, so this item remains protected."
    )
  }

  private func duplicateObservationEvaluation(for path: ScanRelativePath) -> RuleEvaluation {
    RuleEvaluation(
      path: path,
      rule: nil,
      matchingRules: [],
      displayName: "Duplicate observation",
      responsibleTool: "Rule classifier",
      matchState: .conflict,
      disposition: .protected,
      reproducibility: .unknown,
      findings: [
        RuleFinding(
          identifier: AutomaticCheckIdentifier.duplicateObservation,
          kind: .conflict,
          state: .failed,
          explanation: "The classifier received the same exact raw path more than once."
        )
      ],
      explanation: "Duplicate observations conflict, so this raw path remains protected."
    )
  }

  private func makeEvaluation(
    definition: RuleDefinition,
    observation: RuleObservation,
    state: RuleMatchState,
    disposition: RuleDisposition,
    findings: [RuleFinding],
    explanation: String
  ) -> RuleEvaluation {
    RuleEvaluation(
      path: observation.summary.path,
      rule: definition.revision,
      matchingRules: [definition.revision],
      displayName: definition.displayName,
      responsibleTool: definition.responsibleTool,
      matchState: state,
      disposition: disposition,
      reproducibility: definition.reproducibility,
      findings: findings,
      explanation: explanation
    )
  }

  private func orderedFindings(
    _ findings: [RuleFinding],
    for definition: RuleDefinition
  ) -> [RuleFinding]? {
    guard findings.count <= RuleCatalogLimits.maximumRuntimeFindingsPerRule else {
      return nil
    }
    guard
      findings.allSatisfy({ finding in
        finding.explanation.utf8.count
          <= RuleCatalogLimits.maximumRuntimeFindingTextUTF8Bytes
          && !finding.explanation.trimmedForRuleValidation.isEmpty
      })
    else {
      return nil
    }

    var byIdentifier: [CheckIdentifier: RuleFinding] = [:]
    for finding in findings {
      guard byIdentifier.updateValue(finding, forKey: finding.identifier) == nil else {
        return nil
      }
    }

    guard byIdentifier.count == definition.checks.count else {
      return nil
    }

    var result: [RuleFinding] = []
    for check in definition.checks {
      guard let finding = byIdentifier[check.identifier] else {
        return nil
      }
      let expectedKind: RuleFindingKind =
        check.kind == .positiveEvidence ? .positiveEvidence : .exclusion
      guard finding.kind == expectedKind else {
        return nil
      }
      result.append(finding)
    }
    return result
  }

  private func reproducibilityFinding(for definition: RuleDefinition) -> RuleFinding {
    let state: RuleFindingState
    let explanation: String

    switch definition.reproducibility {
    case .reproducible:
      state = .satisfied
      explanation = "The rule declares this generated data reproducible."
    case .conditional where definition.eligibleDisposition == .reviewRequired:
      state = .satisfied
      explanation = "Reproducibility is conditional and therefore requires review."
    case .conditional:
      state = .failed
      explanation = "Conditional reproducibility cannot be automatically reclaimable."
    case .unknown:
      state = .unknown(.unspecified)
      explanation = "The rule does not establish that this data is reproducible."
    }

    return RuleFinding(
      identifier: AutomaticCheckIdentifier.reproducibility,
      kind: .reproducibility,
      state: state,
      explanation: explanation
    )
  }

  private func ageFinding(
    requirement: RuleAgeRequirement,
    observation: RuleObserved<Int64>,
    referenceUnixSeconds: Int64
  ) -> RuleFinding {
    switch requirement {
    case .notRequired:
      return RuleFinding(
        identifier: AutomaticCheckIdentifier.age,
        kind: .age,
        state: .satisfied,
        explanation: "This rule does not require an age threshold."
      )
    case .minimumSeconds(let minimumSeconds):
      switch observation {
      case .unknown(let reason):
        return RuleFinding(
          identifier: AutomaticCheckIdentifier.age,
          kind: .age,
          state: .unknown(reason),
          explanation: "The newest content modification time is unavailable."
        )
      case .known(let modificationUnixSeconds):
        guard modificationUnixSeconds <= referenceUnixSeconds else {
          return RuleFinding(
            identifier: AutomaticCheckIdentifier.age,
            kind: .age,
            state: .unknown(.clockSkew),
            explanation: "The newest content modification time is in the future."
          )
        }

        let (age, overflow) = referenceUnixSeconds.subtractingReportingOverflow(
          modificationUnixSeconds
        )
        guard !overflow, age >= 0 else {
          return RuleFinding(
            identifier: AutomaticCheckIdentifier.age,
            kind: .age,
            state: .unknown(.invalidMetadata),
            explanation: "The content age could not be represented safely."
          )
        }

        let observedSeconds = UInt64(age)
        let satisfied = observedSeconds >= minimumSeconds
        return RuleFinding(
          identifier: AutomaticCheckIdentifier.age,
          kind: .age,
          state: satisfied ? .satisfied : .failed,
          explanation: satisfied
            ? "The newest observed content meets the minimum age requirement."
            : "The newest observed content is more recent than the rule permits."
        )
      }
    }
  }

  private func activityFinding(
    requirement: RuleActivityRequirement,
    observation: RuleObserved<RuleActivityState>
  ) -> RuleFinding {
    switch requirement {
    case .notRequired:
      return RuleFinding(
        identifier: AutomaticCheckIdentifier.activity,
        kind: .activity,
        state: .satisfied,
        explanation: "This rule does not require an activity check."
      )
    case .mustBeInactive:
      switch observation {
      case .unknown(let reason):
        return RuleFinding(
          identifier: AutomaticCheckIdentifier.activity,
          kind: .activity,
          state: .unknown(reason),
          explanation: "Reliable tool activity information is unavailable."
        )
      case .known(.active):
        return RuleFinding(
          identifier: AutomaticCheckIdentifier.activity,
          kind: .activity,
          state: .failed,
          explanation: "The responsible tool is active."
        )
      case .known(.inactive):
        return RuleFinding(
          identifier: AutomaticCheckIdentifier.activity,
          kind: .activity,
          state: .satisfied,
          explanation: "The responsible tool is known to be inactive."
        )
      }
    }
  }

  private func integrityFindings(_ integrity: RuleScanIntegrity) -> [RuleFinding] {
    [
      integrityFinding(
        identifier: AutomaticCheckIdentifier.reportComplete,
        condition: integrity.reportIsComplete,
        explanation: "The containing scan report is complete."
      ),
      integrityFinding(
        identifier: AutomaticCheckIdentifier.itemComplete,
        condition: integrity.itemIsComplete,
        explanation: "The candidate item observation is complete."
      ),
      integrityFinding(
        identifier: AutomaticCheckIdentifier.topLevelOutputComplete,
        condition: !integrity.topLevelItemsWereSuppressed,
        explanation: "The top-level scan output was not suppressed."
      ),
      integrityFinding(
        identifier: AutomaticCheckIdentifier.traversalDetailsRetained,
        condition: !integrity.traversalDetailsWereDiscarded,
        explanation: "Traversal details were retained."
      ),
      integrityFinding(
        identifier: AutomaticCheckIdentifier.issuesComplete,
        condition: integrity.suppressedIssueCount == 0,
        explanation: "No scan issues were suppressed."
      ),
      integrityFinding(
        identifier: AutomaticCheckIdentifier.allocationKnown,
        condition: integrity.unknownAllocatedItemCount == 0,
        explanation: "Allocated size is known for every observed item in this summary."
      ),
      integrityFinding(
        identifier: AutomaticCheckIdentifier.sizeDidNotOverflow,
        condition: !integrity.sizeOverflowed,
        explanation: "The summary size did not overflow."
      ),
      integrityFinding(
        identifier: AutomaticCheckIdentifier.hardLinksComplete,
        condition: integrity.hardLinkAccountingIsComplete,
        explanation: "Hard-link accounting is complete."
      ),
      observedIntegrityFinding(
        identifier: AutomaticCheckIdentifier.identityMatchesScan,
        observation: integrity.identityMatchesScan
      ),
    ]
  }

  private func integrityFinding(
    identifier: CheckIdentifier,
    condition: Bool,
    explanation: String
  ) -> RuleFinding {
    RuleFinding(
      identifier: identifier,
      kind: .scanIntegrity,
      state: condition ? .satisfied : .failed,
      explanation: explanation
    )
  }

  private func observedIntegrityFinding(
    identifier: CheckIdentifier,
    observation: RuleObserved<Bool>
  ) -> RuleFinding {
    let result: (state: RuleFindingState, explanation: String) =
      switch observation {
      case .known(true):
        (.satisfied, "The candidate identity matched the scan-time identity.")
      case .known(false):
        (.failed, "The candidate identity did not match the scan-time identity.")
      case .unknown(let reason):
        (
          .unknown(reason),
          "The candidate identity could not be rebound safely to the scan-time identity."
        )
      }
    return RuleFinding(
      identifier: identifier,
      kind: .scanIntegrity,
      state: result.state,
      explanation: result.explanation
    )
  }

  private static func validateCatalog(_ rules: [any ExplainableRule]) throws {
    guard rules.count <= RuleCatalogLimits.maximumRules else {
      throw RuleCatalogValidationError.tooManyRules(
        maximum: RuleCatalogLimits.maximumRules,
        actual: rules.count
      )
    }

    var ruleIdentifiers = Set<RuleIdentifier>()

    for rule in rules {
      let definition = rule.definition
      let identifier = definition.revision.identifier

      guard ruleIdentifiers.insert(identifier).inserted else {
        throw RuleCatalogValidationError.duplicateRuleIdentifier(identifier)
      }
      guard definition.checks.count <= RuleCatalogLimits.maximumChecksPerRule else {
        throw RuleCatalogValidationError.tooManyChecks(
          rule: identifier,
          maximum: RuleCatalogLimits.maximumChecksPerRule,
          actual: definition.checks.count
        )
      }
      try validateDefinitionText(
        definition.displayName,
        field: "display-name",
        rule: identifier
      )
      guard !definition.displayName.trimmedForRuleValidation.isEmpty else {
        throw RuleCatalogValidationError.emptyDefinitionField(
          rule: identifier,
          field: "display-name"
        )
      }
      try validateDefinitionText(
        definition.responsibleTool,
        field: "responsible-tool",
        rule: identifier
      )
      guard !definition.responsibleTool.trimmedForRuleValidation.isEmpty else {
        throw RuleCatalogValidationError.emptyDefinitionField(
          rule: identifier,
          field: "responsible-tool"
        )
      }
      try validateDefinitionText(
        definition.recognitionExplanation,
        field: "recognition-explanation",
        rule: identifier
      )
      guard !definition.recognitionExplanation.trimmedForRuleValidation.isEmpty else {
        throw RuleCatalogValidationError.emptyDefinitionField(
          rule: identifier,
          field: "recognition-explanation"
        )
      }
      guard definition.eligibleDisposition != .protected else {
        throw RuleCatalogValidationError.invalidEligibleDisposition(identifier)
      }
      guard
        definition.eligibleDisposition != .reclaimable
          || definition.reproducibility == .reproducible
      else {
        throw RuleCatalogValidationError.reclaimableRuleIsNotReproducible(identifier)
      }
      if case .minimumSeconds(0) = definition.ageRequirement {
        throw RuleCatalogValidationError.zeroMinimumAge(identifier)
      }

      var checkIdentifiers = Set<CheckIdentifier>()
      var hasPositiveEvidence = false
      var hasExclusion = false
      for check in definition.checks {
        guard !AutomaticCheckIdentifier.all.contains(check.identifier) else {
          throw RuleCatalogValidationError.reservedCheckIdentifier(
            rule: identifier,
            check: check.identifier
          )
        }
        guard checkIdentifiers.insert(check.identifier).inserted else {
          throw RuleCatalogValidationError.duplicateCheckIdentifier(
            rule: identifier,
            check: check.identifier
          )
        }
        try validateDefinitionText(
          check.explanation,
          field: "check-explanation",
          rule: identifier
        )
        guard !check.explanation.trimmedForRuleValidation.isEmpty else {
          throw RuleCatalogValidationError.emptyDefinitionField(
            rule: identifier,
            field: "check-explanation"
          )
        }
        hasPositiveEvidence = hasPositiveEvidence || check.kind == .positiveEvidence
        hasExclusion = hasExclusion || check.kind == .exclusion
      }
      guard hasPositiveEvidence else {
        throw RuleCatalogValidationError.missingPositiveEvidence(identifier)
      }
      guard hasExclusion else {
        throw RuleCatalogValidationError.missingExclusion(identifier)
      }

      if definition.eligibleDisposition == .reclaimable {
        guard case .minimumSeconds(let seconds) = definition.ageRequirement, seconds > 0 else {
          throw RuleCatalogValidationError.reclaimableRuleRequiresMinimumAge(identifier)
        }
        guard definition.activityRequirement == .mustBeInactive else {
          throw RuleCatalogValidationError.reclaimableRuleRequiresInactiveCheck(identifier)
        }
      }
    }
  }

  private static func validateObservationCount(_ count: Int) throws {
    guard count <= RuleCatalogLimits.maximumObservations else {
      throw RuleClassificationError.tooManyObservations(
        maximum: RuleCatalogLimits.maximumObservations,
        actual: count
      )
    }
  }

  private static func validateDefinitionText(
    _ text: String,
    field: String,
    rule: RuleIdentifier
  ) throws {
    guard text.utf8.count <= RuleCatalogLimits.maximumDefinitionTextUTF8Bytes else {
      throw RuleCatalogValidationError.definitionTextTooLong(
        rule: rule,
        field: field,
        maximumBytes: RuleCatalogLimits.maximumDefinitionTextUTF8Bytes
      )
    }
  }

  private func observationOrder(_ left: RuleObservation, _ right: RuleObservation) -> Bool {
    left.summary.path < right.summary.path
  }
}

private struct AssessedRule {
  let rule: any ExplainableRule
  let assessment: RuleAssessment
  let orderedRuleFindings: [RuleFinding]?
}

enum AutomaticCheckIdentifier {
  static let lexicalRecognition = makeCheckIdentifier("lexical-recognition")
  static let reproducibility = makeCheckIdentifier("reproducibility")
  static let age = makeCheckIdentifier("age-requirement")
  static let activity = makeCheckIdentifier("activity-requirement")
  static let reportComplete = makeCheckIdentifier("report-complete")
  static let itemComplete = makeCheckIdentifier("item-complete")
  static let topLevelOutputComplete = makeCheckIdentifier("top-level-output-complete")
  static let traversalDetailsRetained = makeCheckIdentifier("traversal-details-retained")
  static let issuesComplete = makeCheckIdentifier("issues-complete")
  static let allocationKnown = makeCheckIdentifier("allocation-known")
  static let sizeDidNotOverflow = makeCheckIdentifier("size-did-not-overflow")
  static let hardLinksComplete = makeCheckIdentifier("hard-links-complete")
  static let identityMatchesScan = makeCheckIdentifier("identity-matches-scan")
  static let ruleConflict = makeCheckIdentifier("rule-conflict")
  static let ruleValidity = makeCheckIdentifier("rule-validity")
  static let duplicateObservation = makeCheckIdentifier("duplicate-observation")

  static let all: Set<CheckIdentifier> = [
    lexicalRecognition,
    reproducibility,
    age,
    activity,
    reportComplete,
    itemComplete,
    topLevelOutputComplete,
    traversalDetailsRetained,
    issuesComplete,
    allocationKnown,
    sizeDidNotOverflow,
    hardLinksComplete,
    identityMatchesScan,
    ruleConflict,
    ruleValidity,
    duplicateObservation,
  ]
}

func makeRuleIdentifier(_ rawValue: String) -> RuleIdentifier {
  guard let identifier = RuleIdentifier(rawValue: rawValue) else {
    preconditionFailure("Invalid static rule identifier: \(rawValue)")
  }
  return identifier
}

func makeCheckIdentifier(_ rawValue: String) -> CheckIdentifier {
  guard let identifier = CheckIdentifier(rawValue: rawValue) else {
    preconditionFailure("Invalid static check identifier: \(rawValue)")
  }
  return identifier
}

func makeRuleVersion(_ rawValue: UInt32) -> RuleVersion {
  guard let version = RuleVersion(rawValue: rawValue) else {
    preconditionFailure("Invalid static rule version: \(rawValue)")
  }
  return version
}

extension String {
  fileprivate var trimmedForRuleValidation: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
