import Testing

@testable import DevSiftCore

@Suite("Rule policy provenance")
struct RulePolicyProvenanceTests {
  @Test("Rule revisions are canonical regardless of catalog input order")
  func canonicalRuleRevisionOrder() throws {
    let first = revision("devsift.test.first")
    let second = revision("devsift.test.second")

    let forward = try provenance(ruleRevisions: [first, second])
    let reversed = try provenance(ruleRevisions: [second, first])

    #expect(forward == reversed)
    #expect(forward.ruleRevisions == [first, second])
  }

  @Test("Rule revision roster is bounded and duplicate identifiers are rejected")
  func rosterValidation() throws {
    let maximum = (0..<RuleCatalogLimits.maximumRules).map { index in
      revision("devsift.provenance.r\(index)")
    }
    _ = try provenance(ruleRevisions: maximum)

    let overLimit = maximum + [revision("devsift.provenance.overflow")]
    do {
      _ = try provenance(ruleRevisions: overLimit)
      Issue.record("Expected an over-limit provenance roster to fail")
    } catch let error as RulePolicyProvenanceValidationError {
      #expect(
        error
          == .tooManyRuleRevisions(
            maximum: RuleCatalogLimits.maximumRules,
            actual: RuleCatalogLimits.maximumRules + 1
          )
      )
    }

    let duplicate = revision("devsift.provenance.duplicate")
    for duplicateRoster in [
      [duplicate, duplicate],
      [
        duplicate,
        RuleRevision(identifier: duplicate.identifier, version: testRuleVersion(2)),
      ],
    ] {
      do {
        _ = try provenance(ruleRevisions: duplicateRoster)
        Issue.record("Expected duplicate rule identifiers to fail")
      } catch let error as RulePolicyProvenanceValidationError {
        #expect(error == .duplicateRuleIdentifier(duplicate.identifier))
      }
    }
  }

  @Test("Default classifier owns the exact built-in policy provenance")
  func builtInClassifierProvenance() async throws {
    let report = try await ExplainableRuleClassifier().classify(
      observations: [],
      referenceUnixSeconds: 100
    )
    let policy = try #require(report.policyProvenance)

    #expect(
      policy.classificationContractRevision
        == ExplainableRuleClassifier.classificationContractRevision
    )
    #expect(policy.catalogRevision == BuiltInRuleCatalog.revision)
    #expect(
      policy.ruleRevisions
        == BuiltInRuleCatalog.rules.map { $0.definition.revision }.sorted()
    )
    #expect(policy.classificationContractRevision.version.rawValue == 2)
    #expect(policy.catalogRevision.version.rawValue == 3)
    #expect(
      Dictionary(
        uniqueKeysWithValues: policy.ruleRevisions.map {
          ($0.identifier.rawValue, $0.version.rawValue)
        }
      )
        == [
          "devsift.cache.homebrew": 1,
          "devsift.cache.npm": 2,
          "devsift.cache.uv": 1,
          "devsift.swiftpm.build": 2,
          "devsift.xcode.derived-data": 1,
          "devsift.xcode.ios-device-support": 1,
        ]
    )
  }

  @Test("Custom catalogs opt into provenance and cannot claim the built-in identity")
  func customCatalogProvenance() async throws {
    let definition = syntheticDefinition(id: "devsift.test.custom-policy")
    let rule = SyntheticRule(definition: definition)

    let presentationOnly = try ExplainableRuleClassifier(rules: [rule])
    let presentationReport = try await presentationOnly.classify(
      observations: [ruleObservation(name: Array("candidate".utf8))],
      referenceUnixSeconds: 100
    )
    #expect(presentationReport.policyProvenance == nil)

    let customRevision = revision("devsift.test.custom-catalog", version: 7)
    let plannable = try ExplainableRuleClassifier(
      rules: [rule],
      catalogRevision: customRevision
    )
    let plannableReport = try await plannable.classify(
      observations: [ruleObservation(name: Array("candidate".utf8))],
      referenceUnixSeconds: 100
    )
    #expect(plannableReport.policyProvenance?.catalogRevision == customRevision)
    #expect(plannableReport.policyProvenance?.ruleRevisions == [definition.revision])

    do {
      _ = try ExplainableRuleClassifier(
        rules: [rule],
        catalogRevision: BuiltInRuleCatalog.revision
      )
      Issue.record("Expected the built-in catalog identity to remain reserved")
    } catch let error as RuleCatalogValidationError {
      #expect(error == .reservedCatalogIdentifier(BuiltInRuleCatalog.revision.identifier))
    }
  }

  private func provenance(
    ruleRevisions: [RuleRevision]
  ) throws -> RulePolicyProvenance {
    try RulePolicyProvenance(
      classificationContractRevision: revision("devsift.test.classification-contract"),
      catalogRevision: revision("devsift.test.catalog"),
      ruleRevisions: ruleRevisions
    )
  }

  private func revision(_ identifier: String, version: UInt32 = 1) -> RuleRevision {
    RuleRevision(
      identifier: testRuleIdentifier(identifier),
      version: testRuleVersion(version)
    )
  }
}
