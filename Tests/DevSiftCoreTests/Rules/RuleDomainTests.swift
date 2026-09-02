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

  @Test("Missing or malformed runtime findings invalidate a rule")
  func runtimeFindingValidation() async throws {
    let definition = syntheticDefinition(id: "devsift.test.invalid-findings")
    let classifier = try ExplainableRuleClassifier(
      rules: [SyntheticRule(definition: definition, findings: [])]
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
