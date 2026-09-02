import DevSiftCore
import Foundation

enum ClassificationOutputContract {
  static let schema = "devsift.classification"
  static let schemaVersion = 1
  static let catalogIdentifier = "devsift.builtin-rules"
  static let catalogVersion = 2
  static let catalogRuleCount = BuiltInRuleCatalog.rules.count
}

private enum ClassificationDecisionOrdering {
  static func sorted(_ evaluations: [RuleEvaluation]) -> [RuleEvaluation] {
    evaluations.sorted { left, right in
      if left.path != right.path {
        return left.path < right.path
      }
      if left.matchState != right.matchState {
        return left.matchState.rawValue < right.matchState.rawValue
      }
      return revisionText(left.rule) < revisionText(right.rule)
    }
  }

  private static func revisionText(_ revision: RuleRevision?) -> String {
    guard let revision else {
      return ""
    }
    return "\(revision.identifier.rawValue)@\(revision.version.rawValue)"
  }
}

private enum ClassificationObservationLookup {
  static func summaries(in report: ScanReport) -> [ScanRelativePath: ScanItemSummary] {
    var summaries: [ScanRelativePath: ScanItemSummary] = [:]
    var duplicatePaths = Set<ScanRelativePath>()

    for summary in report.topLevelItems {
      if summaries.updateValue(summary, forKey: summary.path) != nil {
        duplicatePaths.insert(summary.path)
      }
    }
    for path in duplicatePaths {
      summaries.removeValue(forKey: path)
    }
    return summaries
  }
}

struct ClassificationSummary: Equatable, Sendable {
  let decisionCount: Int
  let observedRuleRevisionCount: Int
  let matchedCount: Int
  let possibleMatchCount: Int
  let unrecognizedCount: Int
  let conflictCount: Int
  let invalidRuleCount: Int
  let reclaimableCount: Int
  let reviewRequiredCount: Int
  let protectedCount: Int

  init(evaluations: [RuleEvaluation]) {
    var revisions = Set<RuleRevision>()
    for evaluation in evaluations {
      if let rule = evaluation.rule {
        revisions.insert(rule)
      }
      revisions.formUnion(evaluation.matchingRules)
    }

    decisionCount = evaluations.count
    observedRuleRevisionCount = revisions.count
    matchedCount = evaluations.count { $0.matchState == .matched }
    possibleMatchCount = evaluations.count { $0.matchState == .possibleMatch }
    unrecognizedCount = evaluations.count { $0.matchState == .unrecognized }
    conflictCount = evaluations.count { $0.matchState == .conflict }
    invalidRuleCount = evaluations.count { $0.matchState == .invalidRule }
    reclaimableCount = evaluations.count { $0.disposition == .reclaimable }
    reviewRequiredCount = evaluations.count { $0.disposition == .reviewRequired }
    protectedCount = evaluations.count { $0.disposition == .protected }
  }
}

struct ClassificationScanIntegrity: Equatable, Sendable {
  let isComplete: Bool
  let rootIsComplete: Bool
  let topLevelItemCount: UInt64
  let retainedTopLevelItemCount: Int
  let topLevelItemsWereSuppressed: Bool
  let traversalDetailsWereDiscarded: Bool
  let hardLinkAccountingIsComplete: Bool
  let retainedIssueCount: Int
  let suppressedIssueCount: UInt64
  let rootSizeOverflowed: Bool
  let anyRetainedItemSizeOverflowed: Bool
  let rootUnknownAllocatedItemCount: UInt64
  let retainedItemsWithUnknownAllocatedSizeCount: Int
  let anyUnknownAllocatedSize: Bool

  init(report: ScanReport) {
    isComplete = report.isComplete
    rootIsComplete = report.root.isComplete
    topLevelItemCount = report.topLevelItemCount
    retainedTopLevelItemCount = report.topLevelItems.count
    topLevelItemsWereSuppressed = report.topLevelItemsWereSuppressed
    traversalDetailsWereDiscarded = report.traversalDetailsWereDiscarded
    hardLinkAccountingIsComplete = report.hardLinkAccountingIsComplete
    retainedIssueCount = report.issues.count
    suppressedIssueCount = report.suppressedIssueCount
    rootSizeOverflowed = report.root.sizeOverflowed
    anyRetainedItemSizeOverflowed = report.topLevelItems.contains(where: \.sizeOverflowed)
    rootUnknownAllocatedItemCount = report.root.unknownAllocatedItemCount
    retainedItemsWithUnknownAllocatedSizeCount = report.topLevelItems.count {
      $0.unknownAllocatedItemCount > 0
    }
    anyUnknownAllocatedSize =
      report.root.unknownAllocatedItemCount > 0
      || report.topLevelItems.contains { $0.unknownAllocatedItemCount > 0 }
  }
}

enum ClassificationTextRenderer {
  static func render(
    report: RuleClassificationReport,
    scanReport: ScanReport
  ) -> String {
    let decisions = ClassificationDecisionOrdering.sorted(report.evaluations)
    let summaries = ClassificationObservationLookup.summaries(in: scanReport)
    let summary = ClassificationSummary(evaluations: decisions)
    let integrity = ClassificationScanIntegrity(report: scanReport)
    var lines = [
      "DevSift classification (read-only)",
      "Catalog: \(ClassificationOutputContract.catalogIdentifier) v\(ClassificationOutputContract.catalogVersion)",
      "Catalog rules: \(ClassificationOutputContract.catalogRuleCount)",
      "Path scope: selected root (reported as \(TerminalText.quoted(".")))",
      "Scan completeness: \(scanReport.isComplete ? "complete" : "partial")",
      "Reference time (Unix seconds): \(report.referenceUnixSeconds)",
      "",
      "Scan integrity:",
      "  Report: \(integrity.isComplete ? "complete" : "partial")",
      "  Root summary: \(integrity.rootIsComplete ? "complete" : "partial")",
      "  Top-level items observed: \(integrity.topLevelItemCount)",
      "  Retained top-level items: \(integrity.retainedTopLevelItemCount)",
      "  Top-level items suppressed: \(yesNo(integrity.topLevelItemsWereSuppressed))",
      "  Traversal details discarded: \(yesNo(integrity.traversalDetailsWereDiscarded))",
      "  Hard-link accounting complete: \(yesNo(integrity.hardLinkAccountingIsComplete))",
      "  Issues: \(integrity.retainedIssueCount) retained, \(integrity.suppressedIssueCount) suppressed",
      "  Size overflow: root \(yesNo(integrity.rootSizeOverflowed)), any retained item \(yesNo(integrity.anyRetainedItemSizeOverflowed))",
      "  Unknown allocation: any \(yesNo(integrity.anyUnknownAllocatedSize)), root \(integrity.rootUnknownAllocatedItemCount), \(integrity.retainedItemsWithUnknownAllocatedSizeCount) retained item summaries affected",
      "",
      "Summary:",
      "  Decisions: \(summary.decisionCount)",
      "  Observed rule revisions: \(summary.observedRuleRevisionCount)",
      "  Match states: matched \(summary.matchedCount), possible-match \(summary.possibleMatchCount), unrecognized \(summary.unrecognizedCount), conflict \(summary.conflictCount), invalid-rule \(summary.invalidRuleCount)",
      "  Dispositions: reclaimable \(summary.reclaimableCount), review-required \(summary.reviewRequiredCount), protected \(summary.protectedCount)",
      "",
    ]

    guard !decisions.isEmpty else {
      lines.append("Decisions: none")
      return lines.joined(separator: "\n") + "\n"
    }

    lines.append("Decisions (raw path order):")
    for decision in decisions {
      append(
        decision,
        summary: summaries[decision.path],
        hardLinkAccountingIsComplete: scanReport.hardLinkAccountingIsComplete,
        to: &lines
      )
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func append(
    _ decision: RuleEvaluation,
    summary: ScanItemSummary?,
    hardLinkAccountingIsComplete: Bool,
    to lines: inout [String]
  ) {
    lines.append("- Path: \(TerminalText.quoted(path: decision.path))")
    lines.append("  Disposition: \(decision.disposition.rawValue)")
    lines.append("  Match: \(decision.matchState.rawValue)")
    lines.append("  Rule revision: \(revisionText(decision.rule))")
    lines.append(
      "  Matching rule revisions: \(matchingRevisionText(decision.matchingRules))"
    )
    lines.append("  Name: \(TerminalText.escaped(decision.displayName))")
    lines.append("  Responsible tool: \(TerminalText.escaped(decision.responsibleTool))")
    lines.append("  Reproducibility: \(decision.reproducibility.rawValue)")
    if let summary {
      lines.append(
        "  Observed apparent allocated: \(sizeText(summary.recursiveSize.allocatedBytes, overflowed: summary.sizeOverflowed))"
      )
      let hardLinkSuffix = hardLinkAccountingIsComplete ? "" : " (partial)"
      lines.append(
        "  Observed hard-link-exclusive allocated: \(sizeText(summary.hardLinkExclusiveAllocatedBytes, overflowed: summary.sizeOverflowed))\(hardLinkSuffix)"
      )
      lines.append("  Item observation: \(summary.isComplete ? "complete" : "partial")")
      lines.append("  Unknown allocated sizes: \(summary.unknownAllocatedItemCount)")
    } else {
      lines.append("  Observed allocation: unavailable (scan summary missing)")
      lines.append("  Item observation: unavailable")
    }
    lines.append("  Findings:")
    if decision.findings.isEmpty {
      lines.append("    - none")
    } else {
      for finding in decision.findings {
        lines.append(
          "    - \(finding.identifier.rawValue) | \(finding.kind.rawValue) | \(stateText(finding.state)) | \(TerminalText.escaped(finding.explanation))"
        )
      }
    }
    lines.append("  Explanation: \(TerminalText.escaped(decision.explanation))")
  }

  private static func sizeText(_ bytes: UInt64, overflowed: Bool) -> String {
    overflowed ? "unavailable (size overflow)" : IECByteCountFormatter.string(from: bytes)
  }

  private static func yesNo(_ value: Bool) -> String {
    value ? "yes" : "no"
  }

  private static func revisionText(_ revision: RuleRevision?) -> String {
    guard let revision else {
      return "none"
    }
    return "\(revision.identifier.rawValue)@\(revision.version.rawValue)"
  }

  private static func matchingRevisionText(_ revisions: [RuleRevision]) -> String {
    guard !revisions.isEmpty else {
      return "none"
    }
    return revisions.sorted().map { revisionText($0) }.joined(separator: ", ")
  }

  private static func stateText(_ state: RuleFindingState) -> String {
    switch state {
    case .satisfied:
      "satisfied"
    case .failed:
      "failed"
    case .unknown(let reason):
      "unknown(\(reason.rawValue))"
    }
  }
}

enum ClassificationJSONEncodingError: Error {
  case invalidUTF8
}

enum ClassificationJSONRenderer {
  static func render(
    report: RuleClassificationReport,
    scanReport: ScanReport
  ) throws -> String {
    let document = ClassificationJSONDocumentV1(
      report: report,
      scanReport: scanReport
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(document)

    guard let output = String(data: data, encoding: .utf8) else {
      throw ClassificationJSONEncodingError.invalidUTF8
    }
    return output + "\n"
  }
}

struct ClassificationJSONDocumentV1: Codable, Equatable, Sendable {
  let schema: String
  let schemaVersion: Int
  let devsiftVersion: String
  let safetyMode: String
  let pathStyle: String
  let catalog: ClassificationJSONCatalogV1
  let referenceUnixSeconds: String
  let scanIsComplete: Bool
  let scanIntegrity: ClassificationJSONScanIntegrityV1
  let summary: ClassificationJSONSummaryV1
  let decisions: [ClassificationJSONDecisionV1]

  init(report: RuleClassificationReport, scanReport: ScanReport) {
    let evaluations = ClassificationDecisionOrdering.sorted(report.evaluations)
    let summaries = ClassificationObservationLookup.summaries(in: scanReport)
    schema = ClassificationOutputContract.schema
    schemaVersion = ClassificationOutputContract.schemaVersion
    devsiftVersion = DevSiftStatus.current.version
    safetyMode = DevSiftStatus.current.safetyMode.rawValue
    pathStyle = "root-relative"
    catalog = ClassificationJSONCatalogV1()
    referenceUnixSeconds = String(report.referenceUnixSeconds)
    scanIsComplete = scanReport.isComplete
    scanIntegrity = ClassificationJSONScanIntegrityV1(
      integrity: ClassificationScanIntegrity(report: scanReport)
    )
    summary = ClassificationJSONSummaryV1(
      summary: ClassificationSummary(evaluations: evaluations)
    )
    decisions = evaluations.map { evaluation in
      ClassificationJSONDecisionV1(
        evaluation: evaluation,
        summary: summaries[evaluation.path],
        hardLinkAccountingIsComplete: scanReport.hardLinkAccountingIsComplete
      )
    }
  }

  enum CodingKeys: String, CodingKey {
    case schema
    case schemaVersion
    case devsiftVersion
    case safetyMode
    case pathStyle
    case catalog
    case referenceUnixSeconds
    case scanIsComplete
    case scanIntegrity
    case summary
    case decisions
  }
}

struct ClassificationJSONScanIntegrityV1: Codable, Equatable, Sendable {
  let isComplete: Bool
  let rootIsComplete: Bool
  let topLevelItemCount: String
  let retainedTopLevelItemCount: String
  let topLevelItemsWereSuppressed: Bool
  let traversalDetailsWereDiscarded: Bool
  let hardLinkAccountingIsComplete: Bool
  let retainedIssueCount: String
  let suppressedIssueCount: String
  let rootSizeOverflowed: Bool
  let anyRetainedItemSizeOverflowed: Bool
  let rootUnknownAllocatedItemCount: String
  let retainedItemsWithUnknownAllocatedSizeCount: String
  let anyUnknownAllocatedSize: Bool

  init(integrity: ClassificationScanIntegrity) {
    isComplete = integrity.isComplete
    rootIsComplete = integrity.rootIsComplete
    topLevelItemCount = String(integrity.topLevelItemCount)
    retainedTopLevelItemCount = String(integrity.retainedTopLevelItemCount)
    topLevelItemsWereSuppressed = integrity.topLevelItemsWereSuppressed
    traversalDetailsWereDiscarded = integrity.traversalDetailsWereDiscarded
    hardLinkAccountingIsComplete = integrity.hardLinkAccountingIsComplete
    retainedIssueCount = String(integrity.retainedIssueCount)
    suppressedIssueCount = String(integrity.suppressedIssueCount)
    rootSizeOverflowed = integrity.rootSizeOverflowed
    anyRetainedItemSizeOverflowed = integrity.anyRetainedItemSizeOverflowed
    rootUnknownAllocatedItemCount = String(integrity.rootUnknownAllocatedItemCount)
    retainedItemsWithUnknownAllocatedSizeCount = String(
      integrity.retainedItemsWithUnknownAllocatedSizeCount
    )
    anyUnknownAllocatedSize = integrity.anyUnknownAllocatedSize
  }

  enum CodingKeys: String, CodingKey {
    case isComplete
    case rootIsComplete
    case topLevelItemCount
    case retainedTopLevelItemCount
    case topLevelItemsWereSuppressed
    case traversalDetailsWereDiscarded
    case hardLinkAccountingIsComplete
    case retainedIssueCount
    case suppressedIssueCount
    case rootSizeOverflowed
    case anyRetainedItemSizeOverflowed
    case rootUnknownAllocatedItemCount
    case retainedItemsWithUnknownAllocatedSizeCount
    case anyUnknownAllocatedSize
  }
}

struct ClassificationJSONCatalogV1: Codable, Equatable, Sendable {
  let identifier: String
  let version: String
  let ruleCount: String

  init() {
    identifier = ClassificationOutputContract.catalogIdentifier
    version = String(ClassificationOutputContract.catalogVersion)
    ruleCount = String(ClassificationOutputContract.catalogRuleCount)
  }

  enum CodingKeys: String, CodingKey {
    case identifier
    case version
    case ruleCount
  }
}

struct ClassificationJSONSummaryV1: Codable, Equatable, Sendable {
  let decisionCount: String
  let observedRuleRevisionCount: String
  let matchedCount: String
  let possibleMatchCount: String
  let unrecognizedCount: String
  let conflictCount: String
  let invalidRuleCount: String
  let reclaimableCount: String
  let reviewRequiredCount: String
  let protectedCount: String

  init(summary: ClassificationSummary) {
    decisionCount = String(summary.decisionCount)
    observedRuleRevisionCount = String(summary.observedRuleRevisionCount)
    matchedCount = String(summary.matchedCount)
    possibleMatchCount = String(summary.possibleMatchCount)
    unrecognizedCount = String(summary.unrecognizedCount)
    conflictCount = String(summary.conflictCount)
    invalidRuleCount = String(summary.invalidRuleCount)
    reclaimableCount = String(summary.reclaimableCount)
    reviewRequiredCount = String(summary.reviewRequiredCount)
    protectedCount = String(summary.protectedCount)
  }

  enum CodingKeys: String, CodingKey {
    case decisionCount
    case observedRuleRevisionCount
    case matchedCount
    case possibleMatchCount
    case unrecognizedCount
    case conflictCount
    case invalidRuleCount
    case reclaimableCount
    case reviewRequiredCount
    case protectedCount
  }
}

struct ClassificationJSONDecisionV1: Codable, Equatable, Sendable {
  let path: ScanJSONPathV1
  let ruleRevision: ClassificationJSONRuleRevisionV1?
  let matchingRuleRevisions: [ClassificationJSONRuleRevisionV1]
  let displayName: String
  let responsibleTool: String
  let matchState: String
  let disposition: String
  let reproducibility: String
  let observation: ClassificationJSONObservationV1?
  let findings: [ClassificationJSONFindingV1]
  let explanation: String

  init(
    evaluation: RuleEvaluation,
    summary: ScanItemSummary?,
    hardLinkAccountingIsComplete: Bool
  ) {
    path = ScanJSONPathV1(path: evaluation.path)
    ruleRevision = evaluation.rule.map(ClassificationJSONRuleRevisionV1.init)
    matchingRuleRevisions = evaluation.matchingRules.sorted().map(
      ClassificationJSONRuleRevisionV1.init
    )
    displayName = evaluation.displayName
    responsibleTool = evaluation.responsibleTool
    matchState = evaluation.matchState.rawValue
    disposition = evaluation.disposition.rawValue
    reproducibility = evaluation.reproducibility.rawValue
    observation = summary.map {
      ClassificationJSONObservationV1(
        summary: $0,
        hardLinkAccountingIsComplete: hardLinkAccountingIsComplete
      )
    }
    findings = evaluation.findings.map(ClassificationJSONFindingV1.init)
    explanation = evaluation.explanation
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(ScanJSONPathV1.self, forKey: .path)
    ruleRevision = try container.decodeIfPresent(
      ClassificationJSONRuleRevisionV1.self,
      forKey: .ruleRevision
    )
    matchingRuleRevisions = try container.decode(
      [ClassificationJSONRuleRevisionV1].self,
      forKey: .matchingRuleRevisions
    )
    displayName = try container.decode(String.self, forKey: .displayName)
    responsibleTool = try container.decode(String.self, forKey: .responsibleTool)
    matchState = try container.decode(String.self, forKey: .matchState)
    disposition = try container.decode(String.self, forKey: .disposition)
    reproducibility = try container.decode(String.self, forKey: .reproducibility)
    observation = try container.decodeIfPresent(
      ClassificationJSONObservationV1.self,
      forKey: .observation
    )
    findings = try container.decode([ClassificationJSONFindingV1].self, forKey: .findings)
    explanation = try container.decode(String.self, forKey: .explanation)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(path, forKey: .path)
    if let ruleRevision {
      try container.encode(ruleRevision, forKey: .ruleRevision)
    } else {
      try container.encodeNil(forKey: .ruleRevision)
    }
    try container.encode(matchingRuleRevisions, forKey: .matchingRuleRevisions)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(responsibleTool, forKey: .responsibleTool)
    try container.encode(matchState, forKey: .matchState)
    try container.encode(disposition, forKey: .disposition)
    try container.encode(reproducibility, forKey: .reproducibility)
    if let observation {
      try container.encode(observation, forKey: .observation)
    } else {
      try container.encodeNil(forKey: .observation)
    }
    try container.encode(findings, forKey: .findings)
    try container.encode(explanation, forKey: .explanation)
  }

  enum CodingKeys: String, CodingKey {
    case path
    case ruleRevision
    case matchingRuleRevisions
    case displayName
    case responsibleTool
    case matchState
    case disposition
    case reproducibility
    case observation
    case findings
    case explanation
  }
}

struct ClassificationJSONObservationV1: Codable, Equatable, Sendable {
  let kind: String
  let apparentAllocatedBytes: String
  let hardLinkExclusiveAllocatedBytes: String
  let unknownAllocatedItemCount: String
  let itemIsComplete: Bool
  let sizeOverflowed: Bool
  let hardLinkAccountingIsComplete: Bool

  init(summary: ScanItemSummary, hardLinkAccountingIsComplete: Bool) {
    kind = summary.kind.rawValue
    apparentAllocatedBytes = String(summary.recursiveSize.allocatedBytes)
    hardLinkExclusiveAllocatedBytes = String(summary.hardLinkExclusiveAllocatedBytes)
    unknownAllocatedItemCount = String(summary.unknownAllocatedItemCount)
    itemIsComplete = summary.isComplete
    sizeOverflowed = summary.sizeOverflowed
    self.hardLinkAccountingIsComplete = hardLinkAccountingIsComplete
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case apparentAllocatedBytes
    case hardLinkExclusiveAllocatedBytes
    case unknownAllocatedItemCount
    case itemIsComplete
    case sizeOverflowed
    case hardLinkAccountingIsComplete
  }
}

struct ClassificationJSONRuleRevisionV1: Codable, Equatable, Sendable {
  let identifier: String
  let version: String

  init(revision: RuleRevision) {
    identifier = revision.identifier.rawValue
    version = String(revision.version.rawValue)
  }

  enum CodingKeys: String, CodingKey {
    case identifier
    case version
  }
}

struct ClassificationJSONFindingV1: Codable, Equatable, Sendable {
  let identifier: String
  let kind: String
  let state: ClassificationJSONFindingStateV1
  let explanation: String

  init(finding: RuleFinding) {
    identifier = finding.identifier.rawValue
    kind = finding.kind.rawValue
    state = ClassificationJSONFindingStateV1(state: finding.state)
    explanation = finding.explanation
  }

  enum CodingKeys: String, CodingKey {
    case identifier
    case kind
    case state
    case explanation
  }
}

struct ClassificationJSONFindingStateV1: Codable, Equatable, Sendable {
  let status: String
  let reason: String?

  init(state: RuleFindingState) {
    switch state {
    case .satisfied:
      status = "satisfied"
      reason = nil
    case .failed:
      status = "failed"
      reason = nil
    case .unknown(let unknownReason):
      status = "unknown"
      reason = unknownReason.rawValue
    }
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(String.self, forKey: .status)
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    if let reason {
      try container.encode(reason, forKey: .reason)
    } else {
      try container.encodeNil(forKey: .reason)
    }
  }

  enum CodingKeys: String, CodingKey {
    case status
    case reason
  }
}
