import Foundation

@testable import DevSiftCore

let planningTestCatalogRevision = RuleRevision(
  identifier: testRuleIdentifier("devsift.test.planning-catalog"),
  version: testRuleVersion()
)

func builtInTestPolicyProvenance() throws -> RulePolicyProvenance {
  try RulePolicyProvenance(
    classificationContractRevision: ExplainableRuleClassifier.classificationContractRevision,
    catalogRevision: BuiltInRuleCatalog.revision,
    ruleRevisions: BuiltInRuleCatalog.rules.map { $0.definition.revision }
  )
}

struct PlanningTestCandidate {
  let rawName: [UInt8]
  let identity: FileIdentity?
  let kind: FileSystemEntryKind
  let recursiveSize: StorageSize
  let hardLinkExclusiveAllocatedBytes: UInt64
  let possibleSharedContentFileCount: UInt64
  let sharedContentMetadataUnavailableCount: UInt64
  let unobservedHardLinkFileCount: UInt64
  let nonExclusiveHardLinkFileCount: UInt64
  let facts: RuleObservationFacts

  init(
    rawName: [UInt8],
    identity: FileIdentity?,
    kind: FileSystemEntryKind = .directory,
    recursiveSize: StorageSize = StorageSize(logicalBytes: 1_024, allocatedBytes: 1_024),
    hardLinkExclusiveAllocatedBytes: UInt64 = 1_024,
    possibleSharedContentFileCount: UInt64 = 0,
    sharedContentMetadataUnavailableCount: UInt64 = 0,
    unobservedHardLinkFileCount: UInt64 = 0,
    nonExclusiveHardLinkFileCount: UInt64 = 0,
    facts: RuleObservationFacts = satisfiedRuleFacts()
  ) {
    self.rawName = rawName
    self.identity = identity
    self.kind = kind
    self.recursiveSize = recursiveSize
    self.hardLinkExclusiveAllocatedBytes = hardLinkExclusiveAllocatedBytes
    self.possibleSharedContentFileCount = possibleSharedContentFileCount
    self.sharedContentMetadataUnavailableCount = sharedContentMetadataUnavailableCount
    self.unobservedHardLinkFileCount = unobservedHardLinkFileCount
    self.nonExclusiveHardLinkFileCount = nonExclusiveHardLinkFileCount
    self.facts = facts
  }

  var path: ScanRelativePath {
    ScanRelativePath(rawComponents: [rawName])
  }

  var summary: ScanItemSummary {
    ScanItemSummary(
      path: path,
      kind: kind,
      scanTimeIdentity: identity,
      recursiveSize: recursiveSize,
      hardLinkExclusiveAllocatedBytes: hardLinkExclusiveAllocatedBytes,
      counts: ScanEntryCounts(
        regularFiles: kind == .regularFile ? 1 : 0,
        directories: kind == .directory ? 1 : 0,
        symbolicLinks: kind == .symbolicLink ? 1 : 0,
        other: kind == .other ? 1 : 0,
        duplicateHardLinks: 0
      ),
      unknownAllocatedItemCount: 0,
      possibleSharedContentFileCount: possibleSharedContentFileCount,
      sharedContentMetadataUnavailableCount: sharedContentMetadataUnavailableCount,
      unobservedHardLinkFileCount: unobservedHardLinkFileCount,
      nonExclusiveHardLinkFileCount: nonExclusiveHardLinkFileCount,
      newestContentModificationUnixSeconds: 0,
      isComplete: true
    )
  }

  var observation: RuleObservation {
    RuleObservation(
      summary: summary,
      selectedRootBasename: .known(Array("Caches".utf8)),
      integrity: completeRuleIntegrity(),
      facts: facts
    )
  }
}

struct PlanningTestScenario {
  let classificationRequest: RuleClassificationRequest
  let classificationReport: RuleClassificationReport

  func manifestRequest(
    selections: [CleanupCandidateSelection],
    classificationReport: RuleClassificationReport? = nil
  ) -> CleanupManifestRequest {
    CleanupManifestRequest(
      classificationRequest: classificationRequest,
      classificationReport: classificationReport ?? self.classificationReport,
      selections: selections
    )
  }

  func selection(for path: ScanRelativePath) -> CleanupCandidateSelection {
    guard
      let revision = classificationReport.evaluations.first(where: { evaluation in
        evaluation.path == path
      })?.rule
    else {
      preconditionFailure("The planning test evaluation has no rule revision")
    }
    return CleanupCandidateSelection(path: path, ruleRevision: revision)
  }
}

func makePlanningTestScenario(
  candidates: [PlanningTestCandidate],
  rootIdentity: FileIdentity? = FileIdentity(device: 42, inode: 1),
  referenceUnixSeconds: Int64 = 1_000_000,
  rules: [any ExplainableRule]? = nil
) async throws -> PlanningTestScenario {
  let summaries = candidates.map(\.summary)
  let root = ScanItemSummary(
    path: .root,
    kind: .directory,
    scanTimeIdentity: rootIdentity,
    recursiveSize: .zero,
    hardLinkExclusiveAllocatedBytes: 0,
    counts: ScanEntryCounts(
      regularFiles: 0,
      directories: 1,
      symbolicLinks: 0,
      other: 0,
      duplicateHardLinks: 0
    ),
    unknownAllocatedItemCount: 0,
    possibleSharedContentFileCount: 0,
    sharedContentMetadataUnavailableCount: 0,
    unobservedHardLinkFileCount: 0,
    nonExclusiveHardLinkFileCount: 0,
    newestContentModificationUnixSeconds: 0,
    isComplete: true
  )
  let scanReport = ScanReport(
    root: root,
    topLevelItems: summaries,
    topLevelItemCount: UInt64(summaries.count),
    topLevelItemsWereSuppressed: false,
    hardLinkAccountingIsComplete: true,
    traversalDetailsWereDiscarded: false,
    issues: [],
    suppressedIssueCount: 0
  )
  let request = RuleClassificationRequest(
    root: URL(fileURLWithPath: "/synthetic/Caches", isDirectory: true),
    report: scanReport,
    referenceUnixSeconds: referenceUnixSeconds
  )
  let classifier: ExplainableRuleClassifier
  if let rules {
    classifier = try ExplainableRuleClassifier(
      rules: rules,
      catalogRevision: planningTestCatalogRevision
    )
  } else {
    classifier = ExplainableRuleClassifier()
  }
  let classificationReport = try await classifier.classify(
    observations: candidates.map(\.observation),
    referenceUnixSeconds: referenceUnixSeconds
  ).binding(to: request)
  return PlanningTestScenario(
    classificationRequest: request,
    classificationReport: classificationReport
  )
}

func planningEvaluation(
  _ evaluation: RuleEvaluation,
  findings: [RuleFinding]? = nil
) -> RuleEvaluation {
  RuleEvaluation(
    path: evaluation.path,
    rule: evaluation.rule,
    matchingRules: evaluation.matchingRules,
    displayName: evaluation.displayName,
    responsibleTool: evaluation.responsibleTool,
    matchState: evaluation.matchState,
    disposition: evaluation.disposition,
    reproducibility: evaluation.reproducibility,
    findings: findings ?? evaluation.findings,
    explanation: evaluation.explanation
  )
}

func planningClassificationReport(
  _ report: RuleClassificationReport,
  referenceUnixSeconds: Int64? = nil,
  evaluations: [RuleEvaluation]? = nil
) -> RuleClassificationReport {
  RuleClassificationReport(
    referenceUnixSeconds: referenceUnixSeconds ?? report.referenceUnixSeconds,
    evaluations: evaluations ?? report.evaluations,
    policyProvenance: report.policyProvenance,
    sourceBinding: report.sourceBinding
  )
}
