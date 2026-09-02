import Testing

@testable import DevSiftCore

@Suite("Rule domain")
struct RuleDomainTests {
  @Test("Rule and check identifiers accept only canonical lowercase ASCII")
  func identifierValidation() throws {
    #expect(RuleIdentifier(rawValue: "devsift.cache.uv")?.rawValue == "devsift.cache.uv")
    #expect(CheckIdentifier(rawValue: "trusted-location")?.rawValue == "trusted-location")

    let invalid = [
      "", ".leading", "trailing-", "two..segments", "UPPER", "under_score", "한글", "a b",
      String(repeating: "a", count: 129),
    ]
    for value in invalid {
      #expect(RuleIdentifier(rawValue: value) == nil)
      #expect(CheckIdentifier(rawValue: value) == nil)
    }
  }

  @Test("Rule versions are positive and revisions sort by identifier then version")
  func versionsAndOrdering() throws {
    #expect(RuleVersion(rawValue: 0) == nil)
    let first = RuleRevision(
      identifier: testRuleIdentifier("devsift.a"),
      version: testRuleVersion(2)
    )
    let second = RuleRevision(
      identifier: testRuleIdentifier("devsift.b"),
      version: testRuleVersion(1)
    )
    #expect(first < second)
  }

  @Test("Catalog rejects duplicate rule and check identifiers")
  func duplicateCatalogEntries() throws {
    let rule = SyntheticRule(definition: syntheticDefinition(id: "devsift.test.one"))
    do {
      _ = try ExplainableRuleClassifier(rules: [rule, rule])
      Issue.record("Expected duplicate rule rejection")
    } catch let error as RuleCatalogValidationError {
      #expect(error == .duplicateRuleIdentifier(testRuleIdentifier("devsift.test.one")))
    }

    let duplicatedCheck = RuleCheckDefinition(
      identifier: testCheckIdentifier("same-check"),
      kind: .positiveEvidence,
      explanation: "A nonempty explanation."
    )
    let definition = syntheticDefinition(
      id: "devsift.test.duplicate-check",
      checks: [duplicatedCheck, duplicatedCheck]
    )
    do {
      _ = try ExplainableRuleClassifier(rules: [SyntheticRule(definition: definition)])
      Issue.record("Expected duplicate check rejection")
    } catch let error as RuleCatalogValidationError {
      #expect(
        error
          == .duplicateCheckIdentifier(
            rule: definition.revision.identifier,
            check: duplicatedCheck.identifier
          )
      )
    }
  }

  @Test("Catalog rejects unsafe or unexplained definitions")
  func unsafeCatalogEntries() throws {
    let protectedDefinition = syntheticDefinition(
      id: "devsift.test.protected",
      disposition: .protected
    )
    #expect(throws: RuleCatalogValidationError.self) {
      _ = try ExplainableRuleClassifier(
        rules: [SyntheticRule(definition: protectedDefinition)]
      )
    }

    let conditionalReclaimable = syntheticDefinition(
      id: "devsift.test.conditional",
      reproducibility: .conditional
    )
    #expect(throws: RuleCatalogValidationError.self) {
      _ = try ExplainableRuleClassifier(
        rules: [SyntheticRule(definition: conditionalReclaimable)]
      )
    }

    let zeroAge = syntheticDefinition(
      id: "devsift.test.zero-age",
      age: .minimumSeconds(0)
    )
    #expect(throws: RuleCatalogValidationError.self) {
      _ = try ExplainableRuleClassifier(rules: [SyntheticRule(definition: zeroAge)])
    }
  }

  @Test("Reclaimable rules must meet the catalog safety floor")
  func reclaimableSafetyFloor() throws {
    let positive = RuleCheckDefinition(
      identifier: testCheckIdentifier("positive-check"),
      kind: .positiveEvidence,
      explanation: "Positive evidence."
    )
    let exclusion = RuleCheckDefinition(
      identifier: testCheckIdentifier("exclusion-check"),
      kind: .exclusion,
      explanation: "Exclusion is absent."
    )

    let noAge = syntheticDefinition(
      id: "devsift.test.no-age",
      age: .notRequired,
      checks: [positive, exclusion]
    )
    let noActivity = syntheticDefinition(
      id: "devsift.test.no-activity",
      activity: .notRequired,
      checks: [positive, exclusion]
    )
    let noExclusion = syntheticDefinition(
      id: "devsift.test.no-exclusion",
      checks: [positive]
    )

    try expectCatalogError(
      .reclaimableRuleRequiresMinimumAge(noAge.revision.identifier),
      definition: noAge
    )
    try expectCatalogError(
      .reclaimableRuleRequiresInactiveCheck(noActivity.revision.identifier),
      definition: noActivity
    )
    try expectCatalogError(
      .missingExclusion(noExclusion.revision.identifier),
      definition: noExclusion
    )

    let noReviewExclusion = syntheticDefinition(
      id: "devsift.test.review-no-exclusion",
      disposition: .reviewRequired,
      reproducibility: .conditional,
      age: .notRequired,
      activity: .notRequired,
      checks: [positive]
    )
    try expectCatalogError(
      .missingExclusion(noReviewExclusion.revision.identifier),
      definition: noReviewExclusion
    )

    let flexibleReview = syntheticDefinition(
      id: "devsift.test.flexible-review",
      disposition: .reviewRequired,
      reproducibility: .conditional,
      age: .notRequired,
      activity: .notRequired,
      checks: [positive, exclusion]
    )
    _ = try ExplainableRuleClassifier(rules: [SyntheticRule(definition: flexibleReview)])
  }

  @Test("Every classifier-owned check identifier is reserved")
  func reservedCheckIdentifiers() throws {
    for reserved in AutomaticCheckIdentifier.all.sorted() {
      let definition = syntheticDefinition(
        id: "devsift.test.reserved",
        checks: [
          RuleCheckDefinition(
            identifier: reserved,
            kind: .positiveEvidence,
            explanation: "Attempts to reuse a reserved identifier."
          ),
          RuleCheckDefinition(
            identifier: testCheckIdentifier("safe-exclusion"),
            kind: .exclusion,
            explanation: "A valid exclusion."
          ),
        ]
      )
      try expectCatalogError(
        .reservedCheckIdentifier(
          rule: definition.revision.identifier,
          check: reserved
        ),
        definition: definition
      )
    }
  }

  @Test("Catalog rule and check bounds accept their boundary and reject one more")
  func catalogCountBounds() throws {
    let rules = (0..<RuleCatalogLimits.maximumRules).map { index in
      SyntheticRule(definition: syntheticDefinition(id: "devsift.limit.r\(index)"))
    }
    _ = try ExplainableRuleClassifier(rules: rules)

    let extraRule = SyntheticRule(
      definition: syntheticDefinition(id: "devsift.limit.overflow")
    )
    do {
      _ = try ExplainableRuleClassifier(rules: rules + [extraRule])
      Issue.record("Expected the rule-count bound to reject the catalog")
    } catch let error as RuleCatalogValidationError {
      #expect(
        error
          == .tooManyRules(
            maximum: RuleCatalogLimits.maximumRules,
            actual: RuleCatalogLimits.maximumRules + 1
          )
      )
    }

    func checks(count: Int) -> [RuleCheckDefinition] {
      (0..<count).map { index in
        RuleCheckDefinition(
          identifier: testCheckIdentifier("bounded-check\(index)"),
          kind: index == 0 ? .positiveEvidence : .exclusion,
          explanation: "A bounded check."
        )
      }
    }

    let boundary = syntheticDefinition(
      id: "devsift.limit.check-boundary",
      checks: checks(count: RuleCatalogLimits.maximumChecksPerRule)
    )
    _ = try ExplainableRuleClassifier(rules: [SyntheticRule(definition: boundary)])

    let overflow = syntheticDefinition(
      id: "devsift.limit.check-overflow",
      checks: checks(count: RuleCatalogLimits.maximumChecksPerRule + 1)
    )
    do {
      _ = try ExplainableRuleClassifier(rules: [SyntheticRule(definition: overflow)])
      Issue.record("Expected the check-count bound to reject the rule")
    } catch let error as RuleCatalogValidationError {
      #expect(
        error
          == .tooManyChecks(
            rule: overflow.revision.identifier,
            maximum: RuleCatalogLimits.maximumChecksPerRule,
            actual: RuleCatalogLimits.maximumChecksPerRule + 1
          )
      )
    }
  }

  @Test("Definition text bounds count UTF-8 bytes")
  func definitionTextBounds() throws {
    let base = syntheticDefinition(id: "devsift.limit.text")
    func replacingRecognition(_ text: String) -> RuleDefinition {
      RuleDefinition(
        revision: base.revision,
        displayName: base.displayName,
        responsibleTool: base.responsibleTool,
        recognitionExplanation: text,
        eligibleDisposition: base.eligibleDisposition,
        reproducibility: base.reproducibility,
        ageRequirement: base.ageRequirement,
        activityRequirement: base.activityRequirement,
        checks: base.checks
      )
    }

    let boundaryText = String(
      repeating: "é",
      count: RuleCatalogLimits.maximumDefinitionTextUTF8Bytes / 2
    )
    #expect(boundaryText.utf8.count == RuleCatalogLimits.maximumDefinitionTextUTF8Bytes)
    _ = try ExplainableRuleClassifier(
      rules: [SyntheticRule(definition: replacingRecognition(boundaryText))]
    )

    let overflow = replacingRecognition(boundaryText + "a")
    try expectCatalogError(
      .definitionTextTooLong(
        rule: overflow.revision.identifier,
        field: "recognition-explanation",
        maximumBytes: RuleCatalogLimits.maximumDefinitionTextUTF8Bytes
      ),
      definition: overflow
    )
  }

  @Test("Missing or malformed runtime findings invalidate a rule")
  func runtimeFindingValidation() async throws {
    let definition = syntheticDefinition(id: "devsift.test.invalid-findings")
    let valid = SyntheticRule(definition: definition).findings
    let unexpected = RuleFinding(
      identifier: testCheckIdentifier("unexpected-finding"),
      kind: .positiveEvidence,
      state: .satisfied,
      explanation: "Unexpected evidence."
    )
    let wrongKind = RuleFinding(
      identifier: valid[0].identifier,
      kind: .exclusion,
      state: .satisfied,
      explanation: valid[0].explanation
    )
    let emptyText = RuleFinding(
      identifier: valid[0].identifier,
      kind: valid[0].kind,
      state: .satisfied,
      explanation: "   "
    )
    let malformed: [[RuleFinding]] = [
      [],
      [valid[0], valid[0], valid[1]],
      valid + [unexpected],
      [wrongKind, valid[1]],
      [emptyText, valid[1]],
    ]

    for findings in malformed {
      let classifier = try ExplainableRuleClassifier(
        rules: [SyntheticRule(definition: definition, findings: findings)]
      )
      let report = try await classifier.classify(
        observations: [ruleObservation(name: Array("candidate".utf8))],
        referenceUnixSeconds: 100
      )
      let evaluation = try #require(report.evaluations.first)

      #expect(evaluation.matchState == .invalidRule)
      #expect(evaluation.disposition == .protected)
      #expect(!evaluation.explanation.isEmpty)
      #expect(evaluation.findings.contains { $0.kind == .ruleValidity })
    }
  }

  @Test("Runtime finding count and text are bounded")
  func runtimeFindingBounds() async throws {
    let checks = (0..<RuleCatalogLimits.maximumChecksPerRule).map { index in
      RuleCheckDefinition(
        identifier: testCheckIdentifier("runtime-check\(index)"),
        kind: index == 0 ? .positiveEvidence : .exclusion,
        explanation: "A runtime-bound check."
      )
    }
    let definition = syntheticDefinition(id: "devsift.test.runtime-bounds", checks: checks)
    let boundaryText = String(
      repeating: "é",
      count: RuleCatalogLimits.maximumRuntimeFindingTextUTF8Bytes / 2
    )
    let boundaryFindings = checks.map { check in
      RuleFinding(
        identifier: check.identifier,
        kind: check.kind == .positiveEvidence ? .positiveEvidence : .exclusion,
        state: .satisfied,
        explanation: boundaryText
      )
    }
    let boundaryClassifier = try ExplainableRuleClassifier(
      rules: [SyntheticRule(definition: definition, findings: boundaryFindings)]
    )
    let boundary = try await boundaryClassifier.classify(
      observations: [ruleObservation(name: Array("candidate".utf8))],
      referenceUnixSeconds: 100
    )
    #expect(boundary.evaluations.first?.matchState == .matched)

    let overlong = RuleFinding(
      identifier: boundaryFindings[0].identifier,
      kind: boundaryFindings[0].kind,
      state: .satisfied,
      explanation: boundaryText + "a"
    )
    let overlongClassifier = try ExplainableRuleClassifier(
      rules: [
        SyntheticRule(
          definition: definition,
          findings: [overlong] + boundaryFindings.dropFirst()
        )
      ]
    )
    let overlongReport = try await overlongClassifier.classify(
      observations: [ruleObservation(name: Array("candidate".utf8))],
      referenceUnixSeconds: 100
    )
    #expect(overlongReport.evaluations.first?.matchState == .invalidRule)

    let excessFinding = RuleFinding(
      identifier: testCheckIdentifier("runtime-excess"),
      kind: .positiveEvidence,
      state: .satisfied,
      explanation: "Exceeds the runtime finding count."
    )
    let excessClassifier = try ExplainableRuleClassifier(
      rules: [
        SyntheticRule(
          definition: definition,
          findings: boundaryFindings + [excessFinding]
        )
      ]
    )
    let excessReport = try await excessClassifier.classify(
      observations: [ruleObservation(name: Array("candidate".utf8))],
      referenceUnixSeconds: 100
    )
    #expect(excessReport.evaluations.first?.matchState == .invalidRule)
  }

  private func expectCatalogError(
    _ expected: RuleCatalogValidationError,
    definition: RuleDefinition
  ) throws {
    do {
      _ = try ExplainableRuleClassifier(rules: [SyntheticRule(definition: definition)])
      Issue.record("Expected catalog error \(expected)")
    } catch let error as RuleCatalogValidationError {
      #expect(error == expected)
    }
  }
}
