import DevSiftCore
import Foundation
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@Suite("Scan dashboard presentation")
struct ScanPresentationTests {
  @Test("Rows sort by allocated bytes then exact raw path bytes")
  func deterministicRowSorting() async throws {
    let invalid = AppTestReportFactory.item(
      rawComponents: [[0xFF]],
      kind: .regularFile,
      allocatedBytes: 4_096
    )
    let letterB = AppTestReportFactory.item(
      rawComponents: [Array("b".utf8)],
      kind: .regularFile,
      allocatedBytes: 4_096
    )
    let largest = AppTestReportFactory.item(
      rawComponents: [Array("largest".utf8)],
      allocatedBytes: 8_192
    )
    let report = AppTestReportFactory.report(topLevelItems: [invalid, letterB, largest])

    let presentation = try await makePresentation(for: report)

    #expect(presentation.items.map(\.id) == [largest.path, letterB.path, invalid.path])
    #expect(presentation.items.last?.displayPath == "\\xFF")
  }

  @Test("Paths escape controls, default-ignorable Unicode, backslashes and invalid bytes")
  func safePaths() {
    let hostile = ScanRelativePath(
      rawComponents: [Array("line\nleft​\\xFF".utf8), [0x66, 0x6F, 0xFF]]
    )

    let display = SafeDisplayText.path(hostile)

    #expect(display == "line\\nleft\\u{200B}\\\\xFF/\\x66\\x6F\\xFF")
    #expect(display.contains("\n") == false)
    #expect(display.contains("​") == false)
    #expect(SafeDisplayText.fileName(of: URL(fileURLWithPath: "/")) == "/")
    #expect(SafeDisplayText.filePath(URL(fileURLWithPath: "/")) == "/")
  }

  @Test("Traversal discard and size overflow make affected metrics unavailable")
  func unavailableMetrics() async throws {
    let discarded = try await makePresentation(
      for: AppTestReportFactory.report(
        topLevelItemsWereSuppressed: true,
        hardLinkAccountingIsComplete: false,
        traversalDetailsWereDiscarded: true
      )
    )
    #expect(discarded.metricsAreAvailable == false)
    #expect(discarded.sizeMetricsAreAvailable == false)
    #expect(discarded.observationIsComplete == false)

    let overflow = ScanIssue(
      path: .root,
      operation: .measureSize,
      reason: .sizeOverflow,
      impact: .estimateDegraded
    )
    let overflowed = try await makePresentation(
      for: AppTestReportFactory.report(
        root: AppTestReportFactory.item(sizeOverflowed: true, isComplete: false),
        issues: [overflow]
      )
    )
    #expect(overflowed.metricsAreAvailable)
    #expect(overflowed.sizeMetricsAreAvailable == false)
    #expect(overflowed.report.root.sizeOverflowed)
    #expect(overflowed.observationIsComplete == false)
  }

  @Test("Unknown allocated sizes make the allocation observation partial")
  func unknownAllocationIsPartial() async throws {
    let item = AppTestReportFactory.item(
      rawComponents: [Array("unknown".utf8)],
      unknownAllocatedItemCount: 1
    )
    let report = AppTestReportFactory.report(
      root: AppTestReportFactory.item(unknownAllocatedItemCount: 1),
      topLevelItems: [item]
    )

    let presentation = try await makePresentation(for: report)

    #expect(report.isComplete)
    #expect(presentation.observationIsComplete == false)
    #expect(presentation.items.first?.observationIsComplete == false)
    #expect(presentation.partialDetailMessages == ["1 entry has unknown allocation."])

    let suppressed = try await makePresentation(
      for: AppTestReportFactory.report(
        root: AppTestReportFactory.item(isComplete: false),
        suppressedIssueCount: 1
      )
    )
    #expect(suppressed.partialDetailMessages == ["1 additional scan issue was not retained."])
  }

  @Test("Policy decisions join rows by exact raw path identity")
  func policyDecisionsUseRawPaths() async throws {
    let exact = AppTestReportFactory.item(
      rawComponents: [Array("uv".utf8)],
      allocatedBytes: 8_192
    )
    let hostileNearMiss = AppTestReportFactory.item(
      rawComponents: [Array("uv\n".utf8)],
      allocatedBytes: 4_096
    )
    let invalidUTF8 = AppTestReportFactory.item(
      rawComponents: [[0x75, 0x76, 0xFF]],
      allocatedBytes: 2_048
    )
    let report = AppTestReportFactory.report(
      topLevelItems: [invalidUTF8, hostileNearMiss, exact]
    )

    let result = try await makePresentation(for: report)

    let exactRow = try #require(result.items.first { $0.id == exact.path })
    #expect(exactRow.policy.evaluation?.path == exact.path)
    #expect(exactRow.policy.matchState == .possibleMatch)
    #expect(exactRow.policy.disposition == .protected)
    #expect(
      exactRow.policy.ruleRevisionLabels == ["devsift.cache.uv@1"]
    )

    let hostileRow = try #require(result.items.first { $0.id == hostileNearMiss.path })
    #expect(hostileRow.displayPath == "uv\\n")
    #expect(hostileRow.policy.evaluation?.path == hostileNearMiss.path)
    #expect(hostileRow.policy.matchState == .unrecognized)
    #expect(hostileRow.policy.badgeTitle == "Protected")
    #expect(hostileRow.policy.matchStateDisplayName == "Unrecognized")

    let invalidRow = try #require(result.items.first { $0.id == invalidUTF8.path })
    #expect(invalidRow.displayPath == "\\x75\\x76\\xFF")
    #expect(invalidRow.policy.evaluation?.path == invalidUTF8.path)
    #expect(invalidRow.policy.matchState == .unrecognized)
  }

  @Test("Policy presentation exposes structured evidence and advisory-safe labels")
  func policyEvidencePresentation() async throws {
    let derivedData = AppTestReportFactory.item(
      rawComponents: [Array("DerivedData".utf8)]
    )
    let result = try await makePresentation(
      for: AppTestReportFactory.report(topLevelItems: [derivedData])
    )
    let policy = try #require(result.items.first?.policy)

    #expect(policy.badgeTitle == "Protected")
    #expect(policy.displayName == "Xcode DerivedData")
    #expect(policy.responsibleTool == "Xcode")
    #expect(policy.explanation.contains("remains protected"))
    #expect(!policy.findings.isEmpty)
    #expect(
      policy.findings.contains {
        $0.kind == .activity && $0.state == .unknown(.notCollected)
      }
    )
  }

  @Test("Possible-match reclaimable singleton is protected as malformed")
  func possibleMatchCannotSurfaceReclaimable() throws {
    let rule = try testRuleRevision()
    let evaluation = try testEvaluation(
      rule: rule,
      matchingRules: [rule],
      matchState: .possibleMatch,
      disposition: .reclaimable,
      reproducibility: .reproducible,
      findingState: .failed
    )

    let policy = PolicyDecisionPresentation(evaluations: [evaluation])

    assertMalformedProtected(policy)
    #expect(policy.malformedReason?.contains("possible match") == true)
  }

  @Test("Matched singleton with a failed finding is protected as malformed")
  func failedFindingCannotSurfaceReclaimable() throws {
    let rule = try testRuleRevision()
    let evaluation = try testEvaluation(
      rule: rule,
      matchingRules: [rule],
      matchState: .matched,
      disposition: .reclaimable,
      reproducibility: .reproducible,
      findingState: .failed
    )

    let policy = PolicyDecisionPresentation(evaluations: [evaluation])

    assertMalformedProtected(policy)
    #expect(policy.malformedReason?.contains("unsatisfied finding") == true)
  }

  @Test("Matched singleton without a rule is protected as malformed")
  func missingRuleCannotSurfaceReclaimable() throws {
    let evaluation = try testEvaluation(
      rule: nil,
      matchingRules: [],
      matchState: .matched,
      disposition: .reclaimable,
      reproducibility: .reproducible,
      findingState: .satisfied
    )

    let policy = PolicyDecisionPresentation(evaluations: [evaluation])

    assertMalformedProtected(policy)
    #expect(policy.malformedReason?.contains("did not identify its rule revision") == true)
  }

  @Test("Conditionally reproducible singleton cannot surface reclaimable")
  func conditionalReproducibilityCannotSurfaceReclaimable() throws {
    let rule = try testRuleRevision()
    let evaluation = try testEvaluation(
      rule: rule,
      matchingRules: [rule],
      matchState: .matched,
      disposition: .reclaimable,
      reproducibility: .conditional,
      findingState: .satisfied
    )

    let policy = PolicyDecisionPresentation(evaluations: [evaluation])

    assertMalformedProtected(policy)
    #expect(policy.malformedReason?.contains("did not establish reproducibility") == true)
  }

  @Test("Unknown reproducibility cannot surface a review decision")
  func unknownReproducibilityCannotSurfaceReview() throws {
    let rule = try testRuleRevision()
    let evaluation = try testEvaluation(
      rule: rule,
      matchingRules: [rule],
      matchState: .matched,
      disposition: .reviewRequired,
      reproducibility: .unknown,
      findingState: .satisfied
    )

    let policy = PolicyDecisionPresentation(evaluations: [evaluation])

    assertMalformedProtected(policy)
    #expect(policy.malformedReason?.contains("unknown reproducibility") == true)
  }

  @Test("Matched results without the local evidence floor remain protected")
  func matchedEvidenceFloor() throws {
    let rule = try testRuleRevision()
    let missingPositiveEvidence = try testEvaluation(
      rule: rule,
      matchingRules: [rule],
      matchState: .matched,
      disposition: .reclaimable,
      reproducibility: .reproducible,
      findingState: .satisfied,
      includesPositiveEvidence: false
    )
    let missingExclusion = try testEvaluation(
      rule: rule,
      matchingRules: [rule],
      matchState: .matched,
      disposition: .reclaimable,
      reproducibility: .reproducible,
      findingState: .satisfied,
      includesExclusion: false
    )
    let protectedMatch = try testEvaluation(
      rule: rule,
      matchingRules: [rule],
      matchState: .matched,
      disposition: .protected,
      reproducibility: .reproducible,
      findingState: .satisfied
    )

    for evaluation in [missingPositiveEvidence, missingExclusion, protectedMatch] {
      assertMalformedProtected(PolicyDecisionPresentation(evaluations: [evaluation]))
    }
  }

  @Test("Only coherent matched singletons surface non-protected dispositions")
  func coherentNonProtectedSingletons() throws {
    let rule = try testRuleRevision()
    let reclaimable = PolicyDecisionPresentation(
      evaluations: [
        try testEvaluation(
          rule: rule,
          matchingRules: [rule],
          matchState: .matched,
          disposition: .reclaimable,
          reproducibility: .reproducible,
          findingState: .satisfied
        )
      ]
    )
    let review = PolicyDecisionPresentation(
      evaluations: [
        try testEvaluation(
          rule: rule,
          matchingRules: [rule],
          matchState: .matched,
          disposition: .reviewRequired,
          reproducibility: .conditional,
          findingState: .satisfied
        )
      ]
    )

    #expect(reclaimable.disposition == .reclaimable)
    #expect(reclaimable.badgeTitle == "Reclaimable")
    #expect(reclaimable.isMalformed == false)
    #expect(review.disposition == .reviewRequired)
    #expect(review.badgeTitle == "Review")
    #expect(review.isMalformed == false)
  }

  @Test("Missing and duplicate path results remain protected as malformed")
  func resultCardinalityMustBeExact() throws {
    let rule = try testRuleRevision()
    let evaluation = try testEvaluation(
      rule: rule,
      matchingRules: [rule],
      matchState: .matched,
      disposition: .reclaimable,
      reproducibility: .reproducible,
      findingState: .satisfied
    )

    let missing = PolicyDecisionPresentation(evaluations: [])
    let duplicate = PolicyDecisionPresentation(evaluations: [evaluation, evaluation])

    assertMalformedProtected(missing)
    assertMalformedProtected(duplicate)
    #expect(missing.malformedReason?.contains("No policy evaluation") == true)
    #expect(duplicate.malformedReason?.contains("Multiple policy evaluations") == true)
  }

  @Test("Byte formatting preserves stable IEC boundaries")
  func byteFormatting() {
    #expect(StorageByteFormatter.string(from: 0) == "0 B")
    #expect(StorageByteFormatter.string(from: 1_023) == "1023 B")
    #expect(StorageByteFormatter.string(from: 1_024) == "1.0 KiB")
    #expect(StorageByteFormatter.string(from: 1 << 20) == "1.0 MiB")
    #expect(StorageByteFormatter.string(from: UInt64.max) == "16.0 EiB")
  }

  @Test("Phase changes provide bounded VoiceOver announcements")
  func accessibilityAnnouncements() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/synthetic-cache", isDirectory: true)
    let complete = try await makePresentation(for: AppTestReportFactory.report())
    let partial = try await makePresentation(
      for: AppTestReportFactory.report(
        root: AppTestReportFactory.item(isComplete: false),
        suppressedIssueCount: 1
      )
    )

    #expect(DashboardAccessibility.announcement(for: .empty) == nil)
    #expect(
      DashboardAccessibility.announcement(for: .scanning(root))
        == "Scanning synthetic-cache. File contents are never opened."
    )
    #expect(
      DashboardAccessibility.announcement(for: .classifying(root))
        == "Storage scan finished. Analyzing read-only policies for synthetic-cache."
    )
    #expect(
      DashboardAccessibility.announcement(for: .result(root, complete))
        == "Scan and read-only policy analysis complete. Results are ready."
    )
    #expect(
      DashboardAccessibility.announcement(for: .result(root, partial))?
        .hasPrefix("Partial scan and read-only policy analysis complete") == true
    )
    #expect(
      DashboardAccessibility.announcement(for: .cancelled(root))
        == "Scan cancelled. No files were changed."
    )
    #expect(DashboardAccessibility.cancelHint.contains("active scan or policy analysis"))
    #expect(
      PolicyDisclosureAccessibility.hint(isExpanded: false)
        == "Expands the rule identifier, explanation, and structured evidence"
    )
    #expect(
      PolicyDisclosureAccessibility.hint(isExpanded: true)
        == "Collapses the rule identifier, explanation, and structured evidence"
    )
    #expect(
      ObservationDisclosureAccessibility.hint(isExpanded: false)
        == "Expands partial scan details and retained issues"
    )
    #expect(
      ObservationDisclosureAccessibility.hint(isExpanded: true)
        == "Collapses partial scan details and retained issues"
    )
  }

  private func assertMalformedProtected(
    _ policy: PolicyDecisionPresentation,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(policy.disposition == .protected, sourceLocation: sourceLocation)
    #expect(policy.badgeTitle == "Protected", sourceLocation: sourceLocation)
    #expect(policy.matchState == .invalidRule, sourceLocation: sourceLocation)
    #expect(policy.matchStateDisplayName == "Malformed result", sourceLocation: sourceLocation)
    #expect(policy.isMalformed, sourceLocation: sourceLocation)
    #expect(policy.explanation.contains("remains protected"), sourceLocation: sourceLocation)
  }

  private func testRuleRevision() throws -> RuleRevision {
    RuleRevision(
      identifier: try #require(RuleIdentifier(rawValue: "devsift.test.policy")),
      version: try #require(RuleVersion(rawValue: 1))
    )
  }

  private func testEvaluation(
    rule: RuleRevision?,
    matchingRules: [RuleRevision],
    matchState: RuleMatchState,
    disposition: RuleDisposition,
    reproducibility: RuleReproducibility,
    findingState: RuleFindingState,
    includesPositiveEvidence: Bool = true,
    includesExclusion: Bool = true
  ) throws -> RuleEvaluation {
    var findings: [RuleFinding] = []
    if includesPositiveEvidence {
      findings.append(
        RuleFinding(
          identifier: try #require(CheckIdentifier(rawValue: "test.positive-evidence")),
          kind: .positiveEvidence,
          state: findingState,
          explanation: "Synthetic structured evidence."
        )
      )
    }
    if includesExclusion {
      findings.append(
        RuleFinding(
          identifier: try #require(CheckIdentifier(rawValue: "test.exclusion")),
          kind: .exclusion,
          state: findingState,
          explanation: "Synthetic exclusion evidence."
        )
      )
    }

    return RuleEvaluation(
      path: ScanRelativePath(rawComponents: [Array("synthetic-cache".utf8)]),
      rule: rule,
      matchingRules: matchingRules,
      displayName: "Synthetic cache",
      responsibleTool: "Synthetic tool",
      matchState: matchState,
      disposition: disposition,
      reproducibility: reproducibility,
      findings: findings,
      explanation: "Synthetic classifier explanation."
    )
  }

  private func makePresentation(
    for report: ScanReport,
    root: URL = URL(fileURLWithPath: "/private/tmp/AppPolicyFixture", isDirectory: true)
  ) async throws -> ScanPresentation {
    let classification = try await ExplainableRuleClassifier().classify(
      RuleClassificationRequest(
        root: root,
        report: report,
        referenceUnixSeconds: 1_700_000_000
      )
    )
    return try await ScanPresentation.prepare(
      report: report,
      classification: classification
    )
  }
}
