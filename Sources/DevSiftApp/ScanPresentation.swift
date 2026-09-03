import DevSiftCore
import Foundation

struct ScanItemRow: Hashable, Identifiable, Sendable {
  let summary: ScanItemSummary
  let displayPath: String
  let policy: PolicyDecisionPresentation
  let cleanupSelection: CleanupCandidateSelection?

  var id: ScanRelativePath {
    summary.path
  }

  var observationIsComplete: Bool {
    summary.isComplete
      && summary.unknownAllocatedItemCount == 0
      && !summary.sizeOverflowed
  }
}

struct PolicyDecisionPresentation: Hashable, Sendable {
  let evaluations: [RuleEvaluation]
  private let integrity: PolicyResultIntegrity

  init(evaluations: [RuleEvaluation]) {
    self.evaluations = evaluations.sorted { left, right in
      Self.revisionSortKey(left) < Self.revisionSortKey(right)
    }
    integrity = Self.validate(evaluations)
  }

  var evaluation: RuleEvaluation? {
    evaluations.count == 1 ? evaluations[0] : nil
  }

  var disposition: RuleDisposition {
    guard !isMalformed else {
      return .protected
    }
    return evaluation?.disposition ?? .protected
  }

  var matchState: RuleMatchState {
    guard !isMalformed else {
      return .invalidRule
    }
    return evaluation?.matchState ?? .unrecognized
  }

  var isMalformed: Bool {
    malformedReason != nil
  }

  var malformedReason: String? {
    guard case .malformed(let reason) = integrity else {
      return nil
    }
    return reason
  }

  var badgeTitle: String {
    switch disposition {
    case .reclaimable:
      "Reclaimable"
    case .reviewRequired:
      "Review"
    case .protected:
      "Protected"
    }
  }

  var systemImage: String {
    switch disposition {
    case .reclaimable:
      "checkmark.seal.fill"
    case .reviewRequired:
      "eye.fill"
    case .protected:
      "lock.shield.fill"
    }
  }

  var matchStateDisplayName: String {
    if isMalformed {
      return "Malformed result"
    }

    return switch matchState {
    case .matched:
      "Matched"
    case .possibleMatch:
      "Possible match"
    case .unrecognized:
      "Unrecognized"
    case .conflict:
      "Conflict"
    case .invalidRule:
      "Invalid rule"
    }
  }

  var displayName: String {
    if isMalformed {
      return "Malformed policy result"
    }
    return evaluation?.displayName ?? "Unrecognized data"
  }

  var responsibleTool: String {
    if isMalformed {
      return "Policy result validation"
    }
    return evaluation?.responsibleTool ?? "Unknown"
  }

  var explanation: String {
    if let malformedReason {
      return "\(malformedReason) The item remains protected."
    }
    return evaluation?.explanation
      ?? "No policy result was returned for this exact raw path, so the item remains protected."
  }

  var ruleRevisionLabels: [String] {
    let revisions = evaluations.flatMap { evaluation in
      [evaluation.rule].compactMap { $0 } + evaluation.matchingRules
    }
    return Array(Set(revisions)).sorted().map { revision in
      "\(revision.identifier.rawValue)@\(revision.version.rawValue)"
    }
  }

  var findings: [RuleFinding] {
    evaluation?.findings ?? []
  }

  var accessibilityLabel: String {
    "Policy disposition: \(badgeTitle). Match state: \(matchStateDisplayName). \(explanation)"
  }

  private static func revisionSortKey(_ evaluation: RuleEvaluation) -> String {
    if let rule = evaluation.rule {
      return "\(rule.identifier.rawValue)@\(rule.version.rawValue)"
    }
    return evaluation.matchingRules.map { revision in
      "\(revision.identifier.rawValue)@\(revision.version.rawValue)"
    }.joined(separator: ",")
  }

  private static func validate(_ evaluations: [RuleEvaluation]) -> PolicyResultIntegrity {
    guard evaluations.count == 1, let evaluation = evaluations.first else {
      if evaluations.isEmpty {
        return .malformed("No policy evaluation was returned for this exact raw path.")
      }
      return .malformed(
        "Multiple policy evaluations were returned for this exact raw path."
      )
    }

    guard !evaluation.findings.isEmpty else {
      return .malformed("The policy evaluation contains no structured findings.")
    }
    guard evaluation.deferredExecutionPreconditionsAreWellFormed else {
      return .malformed("The policy evaluation contains invalid deferred execution requirements.")
    }

    switch evaluation.matchState {
    case .matched:
      guard evaluation.disposition == .reclaimable || evaluation.disposition == .reviewRequired
      else {
        return .malformed("A matched policy evaluation reported a protected disposition.")
      }
      guard let rule = evaluation.rule else {
        return .malformed("A matched policy evaluation did not identify its rule revision.")
      }
      guard evaluation.matchingRules == [rule] else {
        return .malformed(
          "A matched policy evaluation did not name exactly the same single rule revision."
        )
      }
      guard evaluation.nonDeferredBlockingFindings.isEmpty else {
        return .malformed(
          "A matched policy evaluation contains an unsatisfied finding that is not deferred."
        )
      }
      guard
        evaluation.findings.contains(where: {
          $0.kind == .positiveEvidence && $0.isSatisfied
        })
      else {
        return .malformed("A matched policy evaluation contains no positive evidence.")
      }
      guard
        evaluation.findings.contains(where: {
          $0.kind == .exclusion && $0.isSatisfied
        })
      else {
        return .malformed("A matched policy evaluation contains no satisfied exclusion check.")
      }
      guard evaluation.reproducibility != .unknown else {
        return .malformed("A matched policy evaluation has unknown reproducibility.")
      }
      if evaluation.disposition == .reclaimable,
        evaluation.reproducibility != .reproducible
      {
        return .malformed(
          "A reclaimable policy evaluation did not establish reproducibility."
        )
      }
      return .valid

    case .possibleMatch:
      guard evaluation.disposition == .protected else {
        return .malformed("A possible match reported a non-protected disposition.")
      }
      guard let rule = evaluation.rule else {
        return .malformed("A possible match did not identify its rule revision.")
      }
      guard evaluation.matchingRules == [rule] else {
        return .malformed(
          "A possible match did not name exactly the same single rule revision."
        )
      }
      guard evaluation.findings.contains(where: { !$0.isSatisfied }) else {
        return .malformed("A possible match did not contain a blocking finding.")
      }
      return .valid

    case .unrecognized:
      guard evaluation.disposition == .protected else {
        return .malformed("An unrecognized result reported a non-protected disposition.")
      }
      guard evaluation.rule == nil, evaluation.matchingRules.isEmpty else {
        return .malformed("An unrecognized result unexpectedly identified a matching rule.")
      }
      guard evaluation.findings.contains(where: { !$0.isSatisfied }) else {
        return .malformed("An unrecognized result did not contain a blocking finding.")
      }
      return .valid

    case .conflict:
      guard evaluation.disposition == .protected else {
        return .malformed("A conflicting result reported a non-protected disposition.")
      }
      guard evaluation.rule == nil else {
        return .malformed("A conflicting result unexpectedly selected one rule revision.")
      }
      guard evaluation.matchingRules.count != 1 else {
        return .malformed("A conflicting result identified only one matching rule revision.")
      }
      guard Set(evaluation.matchingRules).count == evaluation.matchingRules.count else {
        return .malformed("A conflicting result repeated a matching rule revision.")
      }
      guard evaluation.findings.contains(where: { !$0.isSatisfied }) else {
        return .malformed("A conflicting result did not contain a blocking finding.")
      }
      return .valid

    case .invalidRule:
      guard evaluation.disposition == .protected else {
        return .malformed("An invalid-rule result reported a non-protected disposition.")
      }
      if let rule = evaluation.rule {
        guard evaluation.matchingRules == [rule] else {
          return .malformed(
            "An invalid-rule result did not name exactly the same single rule revision."
          )
        }
      } else {
        guard !evaluation.matchingRules.isEmpty else {
          return .malformed("An invalid-rule result did not identify an affected rule revision.")
        }
        guard Set(evaluation.matchingRules).count == evaluation.matchingRules.count else {
          return .malformed("An invalid-rule result repeated an affected rule revision.")
        }
      }
      guard evaluation.findings.contains(where: { !$0.isSatisfied }) else {
        return .malformed("An invalid-rule result did not contain a blocking finding.")
      }
      return .valid
    }
  }
}

private enum PolicyResultIntegrity: Hashable, Sendable {
  case valid
  case malformed(String)
}

extension RuleFinding {
  fileprivate var isSatisfied: Bool {
    state == .satisfied
  }
}

struct ScanPresentation: Equatable, Sendable {
  let report: ScanReport
  let classification: RuleClassificationReport
  let items: [ScanItemRow]

  var metricsAreAvailable: Bool {
    !report.traversalDetailsWereDiscarded
  }

  var sizeMetricsAreAvailable: Bool {
    metricsAreAvailable && !report.root.sizeOverflowed
  }

  var observationIsComplete: Bool {
    report.isComplete
      && report.root.unknownAllocatedItemCount == 0
      && !report.root.sizeOverflowed
  }

  var partialDetailMessages: [String] {
    var messages: [String] = []
    if report.traversalDetailsWereDiscarded {
      messages.append(
        "Earlier descendant totals and scan issues were discarded; their total is unknown."
      )
    }
    if report.topLevelItemsWereSuppressed && !report.traversalDetailsWereDiscarded {
      messages.append("Top-level details exceeded the configured reporting limit.")
    }
    if !report.hardLinkAccountingIsComplete {
      messages.append("Hard-link-adjusted allocation is partial.")
    }
    if report.root.unknownAllocatedItemCount > 0 {
      let noun = report.root.unknownAllocatedItemCount == 1 ? "entry" : "entries"
      let verb = report.root.unknownAllocatedItemCount == 1 ? "has" : "have"
      messages.append(
        "\(report.root.unknownAllocatedItemCount.formatted()) \(noun) \(verb) unknown allocation."
      )
    }
    if report.root.sizeOverflowed {
      messages.append("One or more root size totals overflowed; exact values are unavailable.")
    }
    if report.suppressedIssueCount > 0 {
      let noun = report.suppressedIssueCount == 1 ? "issue" : "issues"
      messages.append(
        "\(report.suppressedIssueCount.formatted()) additional scan \(noun) \(report.suppressedIssueCount == 1 ? "was" : "were") not retained."
      )
    }
    return messages
  }

  static func prepare(
    report: ScanReport,
    classification: RuleClassificationReport
  ) async throws -> ScanPresentation {
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()

      let sortedItems = report.topLevelItems.sorted { left, right in
        if left.recursiveSize.allocatedBytes != right.recursiveSize.allocatedBytes {
          return left.recursiveSize.allocatedBytes > right.recursiveSize.allocatedBytes
        }
        return left.path < right.path
      }
      try Task.checkCancellation()

      var evaluationsByPath: [ScanRelativePath: [RuleEvaluation]] = [:]
      evaluationsByPath.reserveCapacity(classification.evaluations.count)
      for evaluation in classification.evaluations {
        try Task.checkCancellation()
        evaluationsByPath[evaluation.path, default: []].append(evaluation)
      }

      var summaryCountsByPath: [ScanRelativePath: Int] = [:]
      summaryCountsByPath.reserveCapacity(report.topLevelItems.count)
      for summary in report.topLevelItems {
        try Task.checkCancellation()
        summaryCountsByPath[summary.path, default: 0] += 1
      }

      var items: [ScanItemRow] = []
      items.reserveCapacity(sortedItems.count)
      for summary in sortedItems {
        try Task.checkCancellation()
        let policy = PolicyDecisionPresentation(
          evaluations: evaluationsByPath[summary.path, default: []]
        )
        items.append(
          ScanItemRow(
            summary: summary,
            displayPath: SafeDisplayText.path(summary.path),
            policy: policy,
            cleanupSelection: cleanupSelection(
              for: summary,
              summaryCount: summaryCountsByPath[summary.path, default: 0],
              policy: policy,
              report: report,
              classification: classification
            )
          )
        )
      }

      return ScanPresentation(
        report: report,
        classification: classification,
        items: items
      )
    }

    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  /// This is only a conservative UI convenience filter. `CleanupPlanner`
  /// remains the final validator and never treats this selection as approval or
  /// execution authority.
  private static func cleanupSelection(
    for summary: ScanItemSummary,
    summaryCount: Int,
    policy: PolicyDecisionPresentation,
    report: ScanReport,
    classification: RuleClassificationReport
  ) -> CleanupCandidateSelection? {
    guard
      report.isComplete,
      report.root.path == .root,
      report.root.kind == .directory,
      report.root.isComplete,
      !report.root.sizeOverflowed,
      report.root.unknownAllocatedItemCount == 0,
      report.hardLinkAccountingIsComplete,
      let rootIdentity = report.root.scanTimeIdentity,
      let policyProvenance = classification.policyProvenance
    else {
      return nil
    }

    guard
      summaryCount == 1,
      isValidTopLevelCandidatePath(summary.path),
      summary.kind == .directory,
      summary.isComplete,
      !summary.sizeOverflowed,
      summary.unknownAllocatedItemCount == 0,
      summary.hardLinkExclusiveAllocatedBytes <= summary.recursiveSize.allocatedBytes,
      let candidateIdentity = summary.scanTimeIdentity,
      candidateIdentity.device == rootIdentity.device
    else {
      return nil
    }

    guard
      !policy.isMalformed,
      policy.evaluations.count == 1,
      let evaluation = policy.evaluation,
      evaluation.path == summary.path,
      evaluation.matchState == .matched,
      evaluation.disposition == .reclaimable || evaluation.disposition == .reviewRequired,
      let rule = evaluation.rule,
      evaluation.matchingRules == [rule],
      policyProvenance.ruleRevisions.contains(rule),
      !evaluation.findings.isEmpty,
      evaluation.deferredExecutionPreconditionsAreWellFormed,
      evaluation.nonDeferredBlockingFindings.isEmpty,
      evaluation.findings.contains(where: {
        $0.identifier.rawValue == "identity-matches-scan"
          && $0.state == .satisfied
      }),
      evaluation.reproducibility != .unknown,
      evaluation.disposition != .reclaimable
        || evaluation.reproducibility == .reproducible
    else {
      return nil
    }

    return CleanupCandidateSelection(path: summary.path, ruleRevision: rule)
  }

  private static func isValidTopLevelCandidatePath(_ path: ScanRelativePath) -> Bool {
    guard path.rawComponents.count == 1, let component = path.rawComponents.first else {
      return false
    }
    return !component.isEmpty
      && component != [0x2E]
      && component != [0x2E, 0x2E]
      && !component.contains(0)
      && !component.contains(0x2F)
      && component.count <= CleanupPlanningLimits.maximumCandidateComponentBytes
  }
}

enum SafeDisplayText {
  static func path(_ path: ScanRelativePath) -> String {
    guard !path.rawComponents.isEmpty else {
      return "."
    }

    return path.rawComponents.map(component).joined(separator: "/")
  }

  static func fileName(of url: URL) -> String {
    let bytes = fileSystemBytes(of: url)
    guard !bytes.isEmpty else {
      return "/"
    }

    let trimmed = bytes.last == 0x2F ? Array(bytes.dropLast()) : bytes
    guard !trimmed.isEmpty else {
      return "/"
    }
    guard let separator = trimmed.lastIndex(of: 0x2F) else {
      return component(trimmed)
    }
    let name = Array(trimmed[trimmed.index(after: separator)...])
    return name.isEmpty ? "/" : component(name)
  }

  static func filePath(_ url: URL) -> String {
    let bytes = fileSystemBytes(of: url)
    guard !bytes.isEmpty else {
      return "."
    }

    let isAbsolute = bytes.first == 0x2F
    let parts = bytes.split(separator: 0x2F, omittingEmptySubsequences: true)
      .map { component(Array($0)) }
    let rendered = parts.joined(separator: "/")
    return isAbsolute ? "/" + rendered : rendered
  }

  static func scalarSafe(_ value: String) -> String {
    var output = ""
    for scalar in value.unicodeScalars {
      append(scalar, to: &output)
    }
    return output
  }

  private static func component(_ bytes: [UInt8]) -> String {
    guard let value = String(bytes: bytes, encoding: .utf8) else {
      return bytes.map { String(format: "\\x%02X", $0) }.joined()
    }
    return scalarSafe(value)
  }

  private static func append(_ scalar: Unicode.Scalar, to output: inout String) {
    switch scalar {
    case "\\":
      output += "\\\\"
    case "\n":
      output += "\\n"
    case "\r":
      output += "\\r"
    case "\t":
      output += "\\t"
    default:
      let category = scalar.properties.generalCategory
      let mustEscape =
        scalar.properties.isDefaultIgnorableCodePoint
        || category == .control
        || category == .format
        || category == .lineSeparator
        || category == .paragraphSeparator

      if mustEscape {
        output += String(format: "\\u{%04X}", scalar.value)
      } else {
        output.unicodeScalars.append(scalar)
      }
    }
  }

  private static func fileSystemBytes(of url: URL) -> [UInt8] {
    url.withUnsafeFileSystemRepresentation { pointer in
      guard let pointer else {
        return []
      }
      return Array(UnsafeBufferPointer(start: pointer, count: strlen(pointer))).map(UInt8.init)
    }
  }
}

enum StorageByteFormatter {
  private static let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]

  static func string(from bytes: UInt64) -> String {
    guard bytes >= 1_024 else {
      return "\(bytes) B"
    }

    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1_024, unitIndex < units.count - 1 {
      value /= 1_024
      unitIndex += 1
    }

    return String(
      format: "%.1f %@",
      locale: Locale(identifier: "en_US_POSIX"),
      value,
      units[unitIndex]
    )
  }
}

enum DashboardAccessibility {
  static let cancelHint =
    "Stops the active scan or policy analysis at the next cancellation checkpoint"

  static func announcement(for phase: ScanDashboardPhase) -> String? {
    switch phase {
    case .empty:
      nil
    case .scanning(let root):
      "Scanning \(SafeDisplayText.fileName(of: root)). File contents are never opened."
    case .classifying(let root):
      "Storage scan finished. Analyzing read-only policies for \(SafeDisplayText.fileName(of: root))."
    case .result(_, let presentation):
      presentation.observationIsComplete
        ? "Scan and read-only policy analysis complete. Results are ready."
        : "Partial scan and read-only policy analysis complete. Some observation details are unavailable. Results are ready."
    case .cancelled:
      "Scan cancelled. No files were changed."
    case .failed(_, let failure):
      "\(failure.title). No files were changed."
    }
  }
}

extension FileSystemEntryKind {
  var displayName: String {
    switch self {
    case .regularFile:
      "File"
    case .directory:
      "Folder"
    case .symbolicLink:
      "Symbolic link"
    case .other:
      "Other"
    }
  }

  var systemImage: String {
    switch self {
    case .regularFile:
      "doc"
    case .directory:
      "folder"
    case .symbolicLink:
      "link"
    case .other:
      "questionmark.square"
    }
  }
}

extension ScanIssueReason {
  var displayName: String {
    switch self {
    case .permissionDenied:
      "Permission denied"
    case .disappeared:
      "Item disappeared"
    case .changedDuringScan:
      "Changed during scan"
    case .crossedVolumeBoundary:
      "Volume boundary"
    case .outsideRoot:
      "Outside selected folder"
    case .depthLimitReached:
      "Depth limit reached"
    case .resourceLimit:
      "Resource limit reached"
    case .invalidMetadata:
      "Metadata unavailable"
    case .sizeOverflow:
      "Size overflow"
    case .ioFailure:
      "Input/output failure"
    }
  }
}

extension ScanIssueImpact {
  var displayName: String {
    switch self {
    case .entrySkipped:
      "Item skipped"
    case .descendantsSkipped:
      "Contents skipped"
    case .estimateDegraded:
      "Estimate degraded"
    }
  }
}

extension ScanOperation {
  var displayName: String {
    switch self {
    case .validateRoot:
      "Validate folder"
    case .listDirectory:
      "List folder"
    case .readMetadata:
      "Read metadata"
    case .measureSize:
      "Measure size"
    }
  }
}

extension RuleFindingKind {
  var displayName: String {
    switch self {
    case .lexicalRecognition:
      "Name recognition"
    case .positiveEvidence:
      "Required evidence"
    case .exclusion:
      "Protected-content check"
    case .reproducibility:
      "Reproducibility"
    case .age:
      "Age requirement"
    case .activity:
      "Activity requirement"
    case .scanIntegrity:
      "Observation integrity"
    case .conflict:
      "Rule conflict"
    case .ruleValidity:
      "Rule validity"
    }
  }
}

extension RuleFindingState {
  var displayName: String {
    switch self {
    case .satisfied:
      "Satisfied"
    case .failed:
      "Failed"
    case .unknown(let reason):
      "Unknown · \(reason.displayName)"
    }
  }

  var systemImage: String {
    switch self {
    case .satisfied:
      "checkmark.circle.fill"
    case .failed:
      "xmark.circle.fill"
    case .unknown:
      "questionmark.circle.fill"
    }
  }
}

extension RuleUnknownReason {
  var displayName: String {
    switch self {
    case .notCollected:
      "not collected"
    case .unsupported:
      "unsupported"
    case .permissionDenied:
      "permission denied"
    case .incompleteScan:
      "incomplete scan"
    case .changedDuringObservation:
      "changed during observation"
    case .resourceLimit:
      "resource limit"
    case .clockSkew:
      "clock skew"
    case .invalidMetadata:
      "invalid metadata"
    case .unspecified:
      "unspecified"
    }
  }
}
