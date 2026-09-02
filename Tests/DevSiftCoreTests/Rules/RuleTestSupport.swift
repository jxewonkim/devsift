import Foundation

@testable import DevSiftCore

func testRuleIdentifier(_ rawValue: String) -> RuleIdentifier {
  guard let identifier = RuleIdentifier(rawValue: rawValue) else {
    preconditionFailure("Invalid test rule identifier: \(rawValue)")
  }
  return identifier
}

func testCheckIdentifier(_ rawValue: String) -> CheckIdentifier {
  guard let identifier = CheckIdentifier(rawValue: rawValue) else {
    preconditionFailure("Invalid test check identifier: \(rawValue)")
  }
  return identifier
}

func testRuleVersion(_ rawValue: UInt32 = 1) -> RuleVersion {
  guard let version = RuleVersion(rawValue: rawValue) else {
    preconditionFailure("Invalid test rule version: \(rawValue)")
  }
  return version
}

func ruleSummary(
  rawComponents: [[UInt8]],
  kind: FileSystemEntryKind = .directory,
  isComplete: Bool = true,
  unknownAllocatedItemCount: UInt64 = 0,
  sizeOverflowed: Bool = false
) -> ScanItemSummary {
  ScanItemSummary(
    path: ScanRelativePath(rawComponents: rawComponents),
    kind: kind,
    recursiveSize: StorageSize(logicalBytes: 1_024, allocatedBytes: 1_024),
    hardLinkExclusiveAllocatedBytes: 1_024,
    counts: ScanEntryCounts(
      regularFiles: kind == .regularFile ? 1 : 0,
      directories: kind == .directory ? 1 : 0,
      symbolicLinks: kind == .symbolicLink ? 1 : 0,
      other: kind == .other ? 1 : 0,
      duplicateHardLinks: 0
    ),
    unknownAllocatedItemCount: unknownAllocatedItemCount,
    possibleSharedContentFileCount: 0,
    sharedContentMetadataUnavailableCount: 0,
    unobservedHardLinkFileCount: 0,
    nonExclusiveHardLinkFileCount: 0,
    sizeOverflowed: sizeOverflowed,
    isComplete: isComplete
  )
}

func completeRuleIntegrity() -> RuleScanIntegrity {
  RuleScanIntegrity(
    reportIsComplete: true,
    itemIsComplete: true,
    topLevelItemsWereSuppressed: false,
    traversalDetailsWereDiscarded: false,
    suppressedIssueCount: 0,
    unknownAllocatedItemCount: 0,
    sizeOverflowed: false,
    hardLinkAccountingIsComplete: true
  )
}

func satisfiedRuleFacts(
  modificationUnixSeconds: Int64 = 0,
  activity: RuleObserved<RuleActivityState> = .known(.inactive),
  protectedDescendantPresent: RuleObserved<Bool> = .known(false),
  siblingPackageManifestPresent: RuleObserved<Bool> = .known(true)
) -> RuleObservationFacts {
  RuleObservationFacts(
    trustedLocation: .known(true),
    toolOwnership: .known(true),
    generatedContentMarker: .known(true),
    newestContentModificationUnixSeconds: .known(modificationUnixSeconds),
    activity: activity,
    protectedDescendantPresent: protectedDescendantPresent,
    siblingPackageManifestPresent: siblingPackageManifestPresent
  )
}

func ruleObservation(
  name: [UInt8],
  selectedRootBasename: [UInt8] = Array("Caches".utf8),
  integrity: RuleScanIntegrity = completeRuleIntegrity(),
  facts: RuleObservationFacts = satisfiedRuleFacts()
) -> RuleObservation {
  RuleObservation(
    summary: ruleSummary(rawComponents: [name]),
    selectedRootBasename: .known(selectedRootBasename),
    integrity: integrity,
    facts: facts
  )
}

func syntheticDefinition(
  id: String,
  disposition: RuleDisposition = .reclaimable,
  reproducibility: RuleReproducibility = .reproducible,
  age: RuleAgeRequirement = .notRequired,
  activity: RuleActivityRequirement = .notRequired,
  checks: [RuleCheckDefinition]? = nil
) -> RuleDefinition {
  RuleDefinition(
    revision: RuleRevision(
      identifier: testRuleIdentifier(id),
      version: testRuleVersion()
    ),
    displayName: "Synthetic rule",
    responsibleTool: "Synthetic tool",
    recognitionExplanation: "The synthetic raw name matches.",
    eligibleDisposition: disposition,
    reproducibility: reproducibility,
    ageRequirement: age,
    activityRequirement: activity,
    checks: checks
      ?? [
        RuleCheckDefinition(
          identifier: testCheckIdentifier("synthetic-evidence"),
          kind: .positiveEvidence,
          explanation: "Synthetic evidence is satisfied."
        )
      ]
  )
}

struct SyntheticRule: ExplainableRule {
  let definition: RuleDefinition
  let recognition: RuleLexicalRecognition
  let findings: [RuleFinding]

  init(
    definition: RuleDefinition,
    recognition: RuleLexicalRecognition = .recognized,
    findings: [RuleFinding]? = nil
  ) {
    self.definition = definition
    self.recognition = recognition
    self.findings =
      findings
      ?? definition.checks.map { check in
        RuleFinding(
          identifier: check.identifier,
          kind: check.kind == .positiveEvidence ? .positiveEvidence : .exclusion,
          state: .satisfied,
          explanation: check.explanation
        )
      }
  }

  func assess(_ observation: RuleObservation) -> RuleAssessment {
    RuleAssessment(recognition: recognition, findings: findings)
  }
}

func completeScanReport(topLevelItems: [ScanItemSummary]) -> ScanReport {
  ScanReport(
    root: ruleSummary(rawComponents: [], isComplete: true),
    topLevelItems: topLevelItems,
    topLevelItemCount: UInt64(topLevelItems.count),
    topLevelItemsWereSuppressed: false,
    hardLinkAccountingIsComplete: true,
    traversalDetailsWereDiscarded: false,
    issues: [],
    suppressedIssueCount: 0
  )
}
