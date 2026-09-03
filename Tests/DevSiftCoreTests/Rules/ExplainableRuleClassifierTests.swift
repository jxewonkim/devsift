import Foundation
import Testing

@testable import DevSiftCore

@Suite("Explainable rule classifier")
struct ExplainableRuleClassifierTests {
  @Test("Built-in rules produce their declared disposition only when every fact is satisfied")
  func builtInMatches() async throws {
    let classifier = ExplainableRuleClassifier()
    let reference: Int64 = 4_000_000
    let cases:
      [(name: String, root: String, rule: String, version: UInt32, disposition: RuleDisposition)] =
        [
          ("uv", "Caches", "devsift.cache.uv", 1, .reclaimable),
          ("_cacache", "Caches", "devsift.cache.npm", 2, .reviewRequired),
          ("Homebrew", "Caches", "devsift.cache.homebrew", 1, .reviewRequired),
          ("DerivedData", "Xcode", "devsift.xcode.derived-data", 1, .reviewRequired),
          (".build", "Project", "devsift.swiftpm.build", 2, .reviewRequired),
          (
            "17.4 (21E217)", "iOS DeviceSupport", "devsift.xcode.ios-device-support",
            1, .reviewRequired
          ),
        ]

    for testCase in cases {
      let report = try await classifier.classify(
        observations: [
          ruleObservation(
            name: Array(testCase.name.utf8),
            selectedRootBasename: Array(testCase.root.utf8),
            facts: satisfiedRuleFacts(modificationUnixSeconds: 0)
          )
        ],
        referenceUnixSeconds: reference
      )
      let evaluation = try evaluation(testCase.rule, in: report)
      #expect(evaluation.rule?.version.rawValue == testCase.version)
      #expect(evaluation.matchState == .matched, "Expected \(testCase.rule) to match")
      #expect(evaluation.disposition == testCase.disposition)
      #expect(!evaluation.explanation.isEmpty)
      #expect(evaluation.findings.allSatisfy { !$0.explanation.isEmpty })
    }
  }

  @Test("Failed and unknown required evidence remain protected")
  func requiredEvidenceFailClosed() async throws {
    let classifier = ExplainableRuleClassifier()
    let unknownFacts = RuleObservationFacts(
      trustedLocation: .unknown(.notCollected),
      toolOwnership: .known(true),
      generatedContentMarker: .known(true),
      newestContentModificationUnixSeconds: .known(0),
      activity: .known(.inactive),
      protectedDescendantPresent: .known(false),
      siblingPackageManifestPresent: .known(true)
    )
    let failedFacts = RuleObservationFacts(
      trustedLocation: .known(true),
      toolOwnership: .known(true),
      generatedContentMarker: .known(false),
      newestContentModificationUnixSeconds: .known(0),
      activity: .known(.inactive),
      protectedDescendantPresent: .known(false),
      siblingPackageManifestPresent: .known(true)
    )

    for facts in [unknownFacts, failedFacts] {
      let report = try await classifier.classify(
        observations: [ruleObservation(name: Array("uv".utf8), facts: facts)],
        referenceUnixSeconds: 1_000_000
      )
      let result = try #require(report.evaluations.first)
      #expect(result.matchState == .possibleMatch)
      #expect(result.disposition == .protected)
    }
  }

  @Test("Present and unknown exclusions remain protected")
  func exclusionsFailClosed() async throws {
    let classifier = ExplainableRuleClassifier()
    for exclusion: RuleObserved<Bool> in [.known(true), .unknown(.notCollected)] {
      let facts = satisfiedRuleFacts(protectedDescendantPresent: exclusion)
      let report = try await classifier.classify(
        observations: [ruleObservation(name: Array("uv".utf8), facts: facts)],
        referenceUnixSeconds: 1_000_000
      )
      let result = try evaluation("devsift.cache.uv", in: report)
      #expect(result.matchState == .possibleMatch)
      #expect(result.disposition == .protected)
    }
  }

  @Test("Age uses an inclusive boundary and future timestamps are unknown")
  func ageBoundaryAndFuture() async throws {
    let definition = syntheticDefinition(
      id: "devsift.test.age",
      age: .minimumSeconds(100)
    )
    let classifier = try ExplainableRuleClassifier(rules: [SyntheticRule(definition: definition)])
    let cases: [(modification: Int64, expected: RuleMatchState, ageState: RuleFindingState)] = [
      (900, .matched, .satisfied),
      (901, .possibleMatch, .failed),
      (1_001, .possibleMatch, .unknown(.clockSkew)),
    ]

    for testCase in cases {
      let report = try await classifier.classify(
        observations: [
          ruleObservation(
            name: Array("candidate".utf8),
            facts: satisfiedRuleFacts(modificationUnixSeconds: testCase.modification)
          )
        ],
        referenceUnixSeconds: 1_000
      )
      let result = try #require(report.evaluations.first)
      #expect(result.matchState == testCase.expected)
      #expect(result.findings.first { $0.kind == .age }?.state == testCase.ageState)
      if testCase.expected != .matched {
        #expect(result.disposition == .protected)
      }
    }
  }

  @Test("Required activity accepts inactive and protects active or unknown tools")
  func activityRequirement() async throws {
    let definition = syntheticDefinition(
      id: "devsift.test.activity",
      activity: .mustBeInactive
    )
    let classifier = try ExplainableRuleClassifier(rules: [SyntheticRule(definition: definition)])
    let cases: [(RuleObserved<RuleActivityState>, RuleMatchState)] = [
      (.known(.inactive), .matched),
      (.known(.active), .possibleMatch),
      (.unknown(.notCollected), .possibleMatch),
    ]

    for (activity, expected) in cases {
      let report = try await classifier.classify(
        observations: [
          ruleObservation(
            name: Array("candidate".utf8),
            facts: satisfiedRuleFacts(activity: activity)
          )
        ],
        referenceUnixSeconds: 100
      )
      let result = try #require(report.evaluations.first)
      #expect(result.matchState == expected)
      #expect(result.disposition == (expected == .matched ? .reclaimable : .protected))
    }
  }

  @Test("Every partial or uncertain scan guard protects a recognized item")
  func scanIntegrityGuards() async throws {
    let classifier = ExplainableRuleClassifier()

    for guardCase in PartialGuardCase.allCases {
      let report = try await classifier.classify(
        observations: [
          ruleObservation(name: Array("uv".utf8), integrity: guardCase.integrity)
        ],
        referenceUnixSeconds: 1_000_000
      )
      let result = try evaluation("devsift.cache.uv", in: report)
      #expect(result.matchState == .possibleMatch, "Guard: \(guardCase)")
      #expect(result.disposition == .protected, "Guard: \(guardCase)")
      #expect(
        result.findings.contains {
          $0.kind == .scanIntegrity && $0.state != .satisfied
        },
        "Guard: \(guardCase)"
      )
    }
  }

  @Test("Recognition uses exact raw path bytes")
  func hostileRawNames() async throws {
    let classifier = ExplainableRuleClassifier()
    let hostileNames: [[[UInt8]]] = [
      [Array("UV".utf8)],
      [Array("uv ".utf8)],
      [[0x75, 0x76, 0xFF]],
      [Array("u\u{0301}v".utf8)],
      [Array("uv".utf8), Array("child".utf8)],
    ]

    for rawComponents in hostileNames {
      let observation = RuleObservation(
        summary: ruleSummary(rawComponents: rawComponents),
        selectedRootBasename: .known(Array("Caches".utf8)),
        integrity: completeRuleIntegrity(),
        facts: satisfiedRuleFacts()
      )
      let report = try await classifier.classify(
        observations: [observation],
        referenceUnixSeconds: 1_000_000
      )
      let result = try #require(report.evaluations.first)
      #expect(result.matchState == .unrecognized)
      #expect(result.disposition == .protected)
    }
  }

  @Test("DeviceSupport requires the exact raw root and a strict version-like child")
  func deviceSupportRecognition() async throws {
    let classifier = ExplainableRuleClassifier()
    let cases: [(root: String, child: String, expected: RuleMatchState)] = [
      ("iOS DeviceSupport", "17.4", .matched),
      ("iOS DeviceSupport", "17.4.1 (21E217)", .matched),
      ("IOS DeviceSupport", "17.4", .unrecognized),
      ("iOS DeviceSupport", "current", .unrecognized),
      ("iOS DeviceSupport", "17", .unrecognized),
      ("iOS DeviceSupport", "17.4 ()", .unrecognized),
    ]

    for testCase in cases {
      let report = try await classifier.classify(
        observations: [
          ruleObservation(
            name: Array(testCase.child.utf8),
            selectedRootBasename: Array(testCase.root.utf8)
          )
        ],
        referenceUnixSeconds: 4_000_000
      )
      let result = try #require(report.evaluations.first)
      #expect(result.matchState == testCase.expected)
    }
  }

  @Test("Every built-in rejects an exact raw-name near miss")
  func builtInNearMisses() async throws {
    let classifier = ExplainableRuleClassifier()
    let cases: [(exact: String, near: String, root: String)] = [
      ("uv", "UV", "Caches"),
      ("_cacache", "_cacache ", "Caches"),
      ("Homebrew", "homebrew", "Caches"),
      ("DerivedData", "Deriveddata", "Xcode"),
      (".build", ".Build", "Project"),
      ("17.4", "17", "iOS DeviceSupport"),
    ]

    for testCase in cases {
      let exact = try await classifier.classify(
        observations: [
          ruleObservation(
            name: Array(testCase.exact.utf8),
            selectedRootBasename: Array(testCase.root.utf8)
          )
        ],
        referenceUnixSeconds: 4_000_000
      )
      let near = try await classifier.classify(
        observations: [
          ruleObservation(
            name: Array(testCase.near.utf8),
            selectedRootBasename: Array(testCase.root.utf8)
          )
        ],
        referenceUnixSeconds: 4_000_000
      )

      #expect(exact.evaluations.first?.matchState == .matched)
      #expect(near.evaluations.first?.matchState == .unrecognized)
      #expect(near.evaluations.first?.disposition == .protected)
    }
  }

  @Test("Built-in seven-day and thirty-day thresholds are inclusive")
  func builtInAgeBoundaries() async throws {
    let classifier = ExplainableRuleClassifier()
    let reference: Int64 = 4_000_000
    let cases: [(name: String, root: String, seconds: Int64)] = [
      ("uv", "Caches", 7 * 24 * 60 * 60),
      ("17.4", "iOS DeviceSupport", 30 * 24 * 60 * 60),
    ]

    for testCase in cases {
      let exact = try await classifier.classify(
        observations: [
          ruleObservation(
            name: Array(testCase.name.utf8),
            selectedRootBasename: Array(testCase.root.utf8),
            facts: satisfiedRuleFacts(
              modificationUnixSeconds: reference - testCase.seconds
            )
          )
        ],
        referenceUnixSeconds: reference
      )
      let tooRecent = try await classifier.classify(
        observations: [
          ruleObservation(
            name: Array(testCase.name.utf8),
            selectedRootBasename: Array(testCase.root.utf8),
            facts: satisfiedRuleFacts(
              modificationUnixSeconds: reference - testCase.seconds + 1
            )
          )
        ],
        referenceUnixSeconds: reference
      )

      #expect(exact.evaluations.first?.matchState == .matched)
      #expect(tooRecent.evaluations.first?.matchState == .possibleMatch)
      #expect(tooRecent.evaluations.first?.disposition == .protected)
    }
  }

  @Test("Age subtraction overflow fails closed")
  func ageSubtractionOverflow() async throws {
    let definition = syntheticDefinition(id: "devsift.test.age-overflow")
    let classifier = try ExplainableRuleClassifier(rules: [SyntheticRule(definition: definition)])
    let report = try await classifier.classify(
      observations: [
        ruleObservation(
          name: Array("candidate".utf8),
          facts: satisfiedRuleFacts(modificationUnixSeconds: .min)
        )
      ],
      referenceUnixSeconds: .max
    )
    let evaluation = try #require(report.evaluations.first)

    #expect(evaluation.matchState == .possibleMatch)
    #expect(evaluation.disposition == .protected)
    #expect(
      evaluation.findings.first { $0.kind == .age }?.state
        == .unknown(.invalidMetadata)
    )
  }

  @Test("Multiple lexical matches conflict and remain protected")
  func conflictProtection() async throws {
    let first = SyntheticRule(definition: syntheticDefinition(id: "devsift.test.first"))
    let second = SyntheticRule(definition: syntheticDefinition(id: "devsift.test.second"))
    let classifier = try ExplainableRuleClassifier(rules: [first, second])

    let report = try await classifier.classify(
      observations: [ruleObservation(name: Array("candidate".utf8))],
      referenceUnixSeconds: 100
    )

    #expect(report.evaluations.count == 1)
    #expect(report.evaluations.allSatisfy { $0.matchState == .conflict })
    #expect(report.evaluations.allSatisfy { $0.disposition == .protected })
    #expect(report.evaluations.first?.matchingRules.count == 2)
  }

  @Test("Malformed recognized findings take precedence over a rule conflict")
  func invalidRulePrecedesConflict() async throws {
    let invalid = SyntheticRule(
      definition: syntheticDefinition(id: "devsift.test.invalid"),
      findings: []
    )
    let valid = SyntheticRule(definition: syntheticDefinition(id: "devsift.test.valid"))
    let classifier = try ExplainableRuleClassifier(rules: [valid, invalid])

    let report = try await classifier.classify(
      observations: [ruleObservation(name: Array("candidate".utf8))],
      referenceUnixSeconds: 100
    )

    #expect(report.evaluations.count == 1)
    #expect(report.evaluations.first?.matchState == .invalidRule)
    #expect(report.evaluations.first?.disposition == .protected)
    #expect(report.evaluations.first?.rule == nil)
    #expect(report.evaluations.first?.matchingRules.count == 2)
  }

  @Test("Duplicate exact raw-path observations emit one order-independent conflict")
  func duplicateObservations() async throws {
    let classifier = ExplainableRuleClassifier()
    let first = ruleObservation(
      name: Array("uv".utf8),
      facts: satisfiedRuleFacts(modificationUnixSeconds: 0)
    )
    let second = ruleObservation(
      name: Array("uv".utf8),
      facts: RuleObservationFacts()
    )

    let forward = try await classifier.classify(
      observations: [first, second],
      referenceUnixSeconds: 1_000_000
    )
    let reversed = try await classifier.classify(
      observations: [second, first],
      referenceUnixSeconds: 1_000_000
    )

    #expect(forward == reversed)
    #expect(forward.evaluations.count == 1)
    #expect(forward.evaluations.first?.matchState == .conflict)
    #expect(forward.evaluations.first?.disposition == .protected)
    #expect(forward.evaluations.first?.rule == nil)
    #expect(forward.evaluations.first?.matchingRules.isEmpty == true)
    #expect(
      forward.evaluations.first?.findings.first?.identifier
        == testCheckIdentifier("duplicate-observation")
    )
  }

  @Test("Rule and observation registration order cannot change output")
  func deterministicOrdering() async throws {
    let first = SyntheticRule(
      definition: syntheticDefinition(id: "devsift.test.first"),
      recognition: .unrecognized
    )
    let second = SyntheticRule(
      definition: syntheticDefinition(id: "devsift.test.second"),
      recognition: .unrecognized
    )
    let observations = [
      ruleObservation(name: Array("z".utf8)),
      ruleObservation(name: Array("a".utf8)),
    ]
    let forward = try await ExplainableRuleClassifier(rules: [first, second]).classify(
      observations: observations,
      referenceUnixSeconds: 100
    )
    let reversed = try await ExplainableRuleClassifier(rules: [second, first]).classify(
      observations: Array(observations.reversed()),
      referenceUnixSeconds: 100
    )

    #expect(forward == reversed)
  }

  @Test("Classification propagates task cancellation")
  func cancellation() async throws {
    let classifier = ExplainableRuleClassifier()
    let task = Task {
      try await classifier.classify(
        observations: [ruleObservation(name: Array("uv".utf8))],
        referenceUnixSeconds: 1_000_000
      )
    }
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected CancellationError")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Expected CancellationError, received \(error)")
    }
  }

  @Test("Observation count accepts its boundary and rejects one more before classification")
  func observationCountBound() async throws {
    let classifier = ExplainableRuleClassifier()
    let observation = ruleObservation(name: Array("uv".utf8))
    let boundary = Array(
      repeating: observation,
      count: RuleCatalogLimits.maximumObservations
    )

    let boundaryReport = try await classifier.classify(
      observations: boundary,
      referenceUnixSeconds: 1_000_000
    )
    #expect(boundaryReport.evaluations.count == 1)
    #expect(boundaryReport.evaluations.first?.matchState == .conflict)

    do {
      _ = try await classifier.classify(
        observations: boundary + [observation],
        referenceUnixSeconds: 1_000_000
      )
      Issue.record("Expected the observation-count bound to reject the request")
    } catch let error as RuleClassificationError {
      #expect(
        error
          == .tooManyObservations(
            maximum: RuleCatalogLimits.maximumObservations,
            actual: RuleCatalogLimits.maximumObservations + 1
          )
      )
    }

    let overLimitReport = completeScanReport(
      topLevelItems: Array(
        repeating: observation.summary,
        count: RuleCatalogLimits.maximumObservations + 1
      )
    )
    do {
      _ = try await classifier.classify(
        RuleClassificationRequest(
          root: URL(fileURLWithPath: "/synthetic/Caches", isDirectory: true),
          report: overLimitReport,
          referenceUnixSeconds: 1_000_000
        )
      )
      Issue.record("Expected the public adapter boundary to reject the request")
    } catch let error as RuleClassificationError {
      #expect(
        error
          == .tooManyObservations(
            maximum: RuleCatalogLimits.maximumObservations,
            actual: RuleCatalogLimits.maximumObservations + 1
          )
      )
    }
  }

  @Test("Request structure is preflighted before evidence observation")
  func requestPreflightPrecedesObservation() async throws {
    let observer = RuleEvidenceObserverSpy()
    let classifier = try ExplainableRuleClassifier(
      rules: [SyntheticRule(definition: syntheticDefinition(id: "devsift.test.preflight"))],
      evidenceObserver: observer
    )
    let nestedPath = ScanRelativePath(
      rawComponents: [Array("candidate".utf8), Array("nested".utf8)]
    )
    let request = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
      report: completeScanReport(
        topLevelItems: [ruleSummary(rawComponents: nestedPath.rawComponents)]
      ),
      referenceUnixSeconds: 100
    )

    do {
      _ = try await classifier.classify(request)
      Issue.record("Expected preflight to reject a nested top-level path")
    } catch let error as RuleClassificationReportValidationError {
      #expect(error == .inputPathIsNotTopLevel(nestedPath))
    }
    #expect(await observer.callCount() == 0)
  }

  private func evaluation(
    _ identifier: String,
    in report: RuleClassificationReport
  ) throws -> RuleEvaluation {
    try #require(
      report.evaluations.first {
        $0.rule?.identifier == testRuleIdentifier(identifier)
      }
    )
  }
}

private actor RuleEvidenceObserverSpy: RuleEvidenceObserving {
  private var calls = 0

  func observe(_ request: RuleClassificationRequest) async throws -> RuleEvidenceObservation {
    calls += 1
    return RuleEvidenceObservation(
      candidates: request.report.topLevelItems.map { item in
        .unavailable(.notCollected, for: item)
      }
    )
  }

  func callCount() -> Int {
    calls
  }
}

private enum PartialGuardCase: String, CaseIterable {
  case reportIncomplete
  case itemIncomplete
  case topLevelSuppressed
  case traversalDiscarded
  case issuesSuppressed
  case allocationUnknown
  case sizeOverflow
  case hardLinksIncomplete
  case identityMismatch
  case identityUnknown

  var integrity: RuleScanIntegrity {
    let identityMatchesScan: RuleObserved<Bool> =
      switch self {
      case .identityMismatch: .known(false)
      case .identityUnknown: .unknown(.changedDuringObservation)
      default: .known(true)
      }
    return RuleScanIntegrity(
      reportIsComplete: self != .reportIncomplete,
      itemIsComplete: self != .itemIncomplete,
      topLevelItemsWereSuppressed: self == .topLevelSuppressed,
      traversalDetailsWereDiscarded: self == .traversalDiscarded,
      suppressedIssueCount: self == .issuesSuppressed ? 1 : 0,
      unknownAllocatedItemCount: self == .allocationUnknown ? 1 : 0,
      sizeOverflowed: self == .sizeOverflow,
      hardLinkAccountingIsComplete: self != .hardLinksIncomplete,
      identityMatchesScan: identityMatchesScan
    )
  }
}
