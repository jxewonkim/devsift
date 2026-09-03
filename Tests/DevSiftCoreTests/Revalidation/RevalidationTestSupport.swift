import Foundation
import Testing

@testable import DevSiftCore

actor RevalidationRequestLog<Value: Sendable> {
  private var values: [Value] = []

  func append(_ value: Value) {
    values.append(value)
  }

  func snapshot() -> [Value] {
    values
  }
}

struct RevalidationStubScanner: FileSystemScanning {
  let handler: @Sendable (ScanRequest) async throws -> ScanReport

  func scan(_ request: ScanRequest) async throws -> ScanReport {
    try await handler(request)
  }
}

struct RevalidationStubClassifier: RuleClassifying {
  let handler: @Sendable (RuleClassificationRequest) async throws -> RuleClassificationReport

  func classify(_ request: RuleClassificationRequest) async throws -> RuleClassificationReport {
    try await handler(request)
  }
}

func revalidationApproval(
  rawNames: [[UInt8]] = [Array("a-cache".utf8), Array("b-cache".utf8)],
  root: URL = URL(fileURLWithPath: "/synthetic/RevalidationRoot", isDirectory: true)
) async throws -> (source: ApprovalTestSource, approval: CleanupApproval) {
  let source = try await approvalTestSource(rawNames: rawNames, root: root)
  let approver = CleanupApprover()
  let session = try approver.beginReview(source.manifestRequest)
  let approval = try approver.approve(
    CleanupApprovalRequest(
      session: session,
      confirmations: try approvalConfirmations(from: session)
    )
  )
  return (source, approval)
}

func revalidationReport(
  _ report: ScanReport,
  root: ScanItemSummary? = nil,
  items: [ScanItemSummary]? = nil,
  rootIsComplete: Bool? = nil
) -> ScanReport {
  let sourceRoot = root ?? report.root
  let revisedRoot: ScanItemSummary
  if let rootIsComplete {
    revisedRoot = ScanItemSummary(
      path: sourceRoot.path,
      kind: sourceRoot.kind,
      scanTimeIdentity: sourceRoot.scanTimeIdentity,
      recursiveSize: sourceRoot.recursiveSize,
      hardLinkExclusiveAllocatedBytes: sourceRoot.hardLinkExclusiveAllocatedBytes,
      counts: sourceRoot.counts,
      unknownAllocatedItemCount: sourceRoot.unknownAllocatedItemCount,
      possibleSharedContentFileCount: sourceRoot.possibleSharedContentFileCount,
      sharedContentMetadataUnavailableCount: sourceRoot.sharedContentMetadataUnavailableCount,
      unobservedHardLinkFileCount: sourceRoot.unobservedHardLinkFileCount,
      nonExclusiveHardLinkFileCount: sourceRoot.nonExclusiveHardLinkFileCount,
      newestContentModificationUnixSeconds: sourceRoot.newestContentModificationUnixSeconds,
      sizeOverflowed: sourceRoot.sizeOverflowed,
      isComplete: rootIsComplete
    )
  } else {
    revisedRoot = sourceRoot
  }
  let revisedItems = items ?? report.topLevelItems
  return ScanReport(
    root: revisedRoot,
    topLevelItems: revisedItems,
    topLevelItemCount: UInt64(revisedItems.count),
    topLevelItemsWereSuppressed: false,
    hardLinkAccountingIsComplete: true,
    traversalDetailsWereDiscarded: false,
    issues: [],
    suppressedIssueCount: 0
  )
}

func revalidationSummary(
  _ summary: ScanItemSummary,
  kind: FileSystemEntryKind? = nil,
  identity: FileIdentity? = nil
) -> ScanItemSummary {
  ScanItemSummary(
    path: summary.path,
    kind: kind ?? summary.kind,
    scanTimeIdentity: identity ?? summary.scanTimeIdentity,
    recursiveSize: summary.recursiveSize,
    hardLinkExclusiveAllocatedBytes: summary.hardLinkExclusiveAllocatedBytes,
    counts: summary.counts,
    unknownAllocatedItemCount: summary.unknownAllocatedItemCount,
    possibleSharedContentFileCount: summary.possibleSharedContentFileCount,
    sharedContentMetadataUnavailableCount: summary.sharedContentMetadataUnavailableCount,
    unobservedHardLinkFileCount: summary.unobservedHardLinkFileCount,
    nonExclusiveHardLinkFileCount: summary.nonExclusiveHardLinkFileCount,
    newestContentModificationUnixSeconds: summary.newestContentModificationUnixSeconds,
    sizeOverflowed: summary.sizeOverflowed,
    isComplete: summary.isComplete
  )
}

func boundRevalidationReport(
  request: RuleClassificationRequest,
  source: ApprovalTestSource,
  evaluations: [RuleEvaluation]? = nil,
  provenance: RulePolicyProvenance? = nil
) -> RuleClassificationReport {
  let policyProvenance = provenance ?? source.classificationReport.policyProvenance
  return RuleClassificationReport(
    referenceUnixSeconds: request.referenceUnixSeconds,
    evaluations: evaluations ?? source.classificationReport.evaluations,
    policyProvenance: policyProvenance,
    sourceBinding: RuleClassificationSourceBinding(
      request: request,
      policyProvenance: policyProvenance
    )
  )
}

func revalidationEvaluation(
  _ source: RuleEvaluation,
  rule: RuleRevision? = nil,
  matchingRules: [RuleRevision]? = nil,
  displayName: String? = nil,
  matchState: RuleMatchState? = nil,
  disposition: RuleDisposition? = nil,
  findings: [RuleFinding]? = nil
) -> RuleEvaluation {
  RuleEvaluation(
    path: source.path,
    rule: rule ?? source.rule,
    matchingRules: matchingRules ?? source.matchingRules,
    displayName: displayName ?? source.displayName,
    responsibleTool: source.responsibleTool,
    matchState: matchState ?? source.matchState,
    disposition: disposition ?? source.disposition,
    reproducibility: source.reproducibility,
    findings: findings ?? source.findings,
    explanation: source.explanation
  )
}

func expectRevalidationError(
  _ expected: CleanupRevalidationError,
  sourceLocation: SourceLocation = #_sourceLocation,
  performing operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected cleanup revalidation error \(expected)", sourceLocation: sourceLocation)
  } catch let error as CleanupRevalidationError {
    #expect(error == expected, sourceLocation: sourceLocation)
  } catch {
    Issue.record("Unexpected cleanup revalidation error \(error)", sourceLocation: sourceLocation)
  }
}

func isEncodableRevalidationValue(_ value: Any) -> Bool {
  value is any Encodable
}

func actualSyntheticRevalidationApproval(
  root: URL,
  rawNames: [[UInt8]]
) async throws -> CleanupApproval {
  let scanReport = try await AllocatedSizeScanner().scan(root: root)
  let referenceUnixSeconds: Int64 = 2_000_000
  let classificationRequest = RuleClassificationRequest(
    root: root,
    report: scanReport,
    referenceUnixSeconds: referenceUnixSeconds
  )
  let classifier = try ExplainableRuleClassifier(
    rules: [SyntheticRule(definition: approvalTestRuleDefinition)],
    catalogRevision: planningTestCatalogRevision
  )
  let classificationReport = try await classifier.classify(
    observations: scanReport.topLevelItems.map { summary in
      RuleObservation(
        summary: summary,
        selectedRootBasename: .known(Array("root".utf8)),
        integrity: completeRuleIntegrity(),
        facts: satisfiedRuleFacts()
      )
    },
    referenceUnixSeconds: referenceUnixSeconds
  ).binding(to: classificationRequest)
  let selections = rawNames.map { rawName in
    CleanupCandidateSelection(
      path: ScanRelativePath(rawComponents: [rawName]),
      ruleRevision: approvalTestRuleDefinition.revision
    )
  }
  let approver = CleanupApprover()
  let session = try approver.beginReview(
    CleanupManifestRequest(
      classificationRequest: classificationRequest,
      classificationReport: classificationReport,
      selections: selections
    )
  )
  return try approver.approve(
    CleanupApprovalRequest(
      session: session,
      confirmations: try approvalConfirmations(from: session)
    )
  )
}

func actualSyntheticRevalidator(
  supportedPolicyProvenance: RulePolicyProvenance
) throws -> CleanupRevalidator {
  let classifier = try ExplainableRuleClassifier(
    rules: [SyntheticRule(definition: approvalTestRuleDefinition)],
    catalogRevision: planningTestCatalogRevision
  )
  return CleanupRevalidator(
    scanner: AllocatedSizeScanner(),
    classifier: RevalidationStubClassifier { request in
      try await classifier.classify(
        observations: request.report.topLevelItems.map { summary in
          RuleObservation(
            summary: summary,
            selectedRootBasename: .known(Array("root".utf8)),
            integrity: completeRuleIntegrity(),
            facts: satisfiedRuleFacts()
          )
        },
        referenceUnixSeconds: request.referenceUnixSeconds
      ).binding(to: request)
    },
    referenceTime: { 2_000_000 },
    supportedPolicyProvenance: supportedPolicyProvenance
  )
}
