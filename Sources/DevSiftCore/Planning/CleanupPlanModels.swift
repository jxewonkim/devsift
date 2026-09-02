import Foundation

public enum CleanupPlanningLimits {
  public static let maximumSelections = 50_000
  public static let maximumCandidateComponentBytes = 255
}

public enum CleanupPlanPathIssue: Equatable, Sendable {
  case notTopLevel
  case emptyComponent
  case currentDirectoryComponent
  case parentDirectoryComponent
  case containsNullByte
  case containsPathSeparator
  case componentTooLong(maximum: Int, actual: Int)
}

public enum CleanupSizeMetric: String, CaseIterable, Hashable, Sendable {
  case observedLogicalBytes = "observed-logical-bytes"
  case observedAllocatedBytes = "observed-allocated-bytes"
  case observedHardLinkExclusiveAllocatedBytes =
    "observed-hard-link-exclusive-allocated-bytes"
  case possibleSharedContentFileCount = "possible-shared-content-file-count"
  case sharedContentMetadataUnavailableCount =
    "shared-content-metadata-unavailable-count"
  case unobservedHardLinkFileCount = "unobserved-hard-link-file-count"
  case nonExclusiveHardLinkFileCount = "non-exclusive-hard-link-file-count"
}

public enum CleanupPlanningError: Error, Equatable, Sendable {
  case invalidClassificationReport(RuleClassificationReportValidationError)
  case classificationValidationFailed
  case classificationReportIsNotSourceBound
  case tooManySelections(maximum: Int, actual: Int)
  case incompleteScan
  case missingRootIdentity
  case invalidSelectionPath(path: ScanRelativePath, issue: CleanupPlanPathIssue)
  case duplicateSelection(ScanRelativePath)
  case selectionNotFound(ScanRelativePath)
  case ambiguousSelection(ScanRelativePath)
  case ruleRevisionMismatch(
    path: ScanRelativePath,
    selected: RuleRevision,
    classified: RuleRevision?
  )
  case ineligibleCandidate(
    path: ScanRelativePath,
    matchState: RuleMatchState,
    disposition: RuleDisposition
  )
  case unsupportedCandidateKind(path: ScanRelativePath, kind: FileSystemEntryKind)
  case incompleteCandidateObservation(ScanRelativePath)
  case missingCandidateIdentity(ScanRelativePath)
  case candidateDeviceMismatch(ScanRelativePath)
  case evidenceNotSatisfied(path: ScanRelativePath, finding: CheckIdentifier)
  case identityEvidenceNotSatisfied(ScanRelativePath)
  case invalidSize(ScanRelativePath)
  case totalOverflow(CleanupSizeMetric)
}

/// One exact classifier decision selected for a draft cleanup manifest.
///
/// Selection is not approval. The rule revision prevents a stale frontend
/// selection from silently binding to a newer policy decision for the same raw
/// path.
public struct CleanupCandidateSelection: Hashable, Sendable {
  public let path: ScanRelativePath
  public let ruleRevision: RuleRevision

  public init(path: ScanRelativePath, ruleRevision: RuleRevision) {
    self.path = path
    self.ruleRevision = ruleRevision
  }
}

public struct CleanupManifestRequest: Hashable, Sendable {
  public let classificationRequest: RuleClassificationRequest
  public let classificationReport: RuleClassificationReport
  public let selections: [CleanupCandidateSelection]

  public init(
    classificationRequest: RuleClassificationRequest,
    classificationReport: RuleClassificationReport,
    selections: [CleanupCandidateSelection]
  ) {
    self.classificationRequest = classificationRequest
    self.classificationReport = classificationReport
    self.selections = selections
  }
}

/// Point-in-time size observations. None of these values guarantees how many
/// bytes a later cleanup would reclaim because clones and snapshots may share
/// storage outside file-level accounting.
public struct CleanupManifestSizeObservation: Hashable, Sendable {
  public let observedLogicalBytes: UInt64
  public let observedAllocatedBytes: UInt64
  public let observedHardLinkExclusiveAllocatedBytes: UInt64
  public let possibleSharedContentFileCount: UInt64
  public let sharedContentMetadataUnavailableCount: UInt64
  public let unobservedHardLinkFileCount: UInt64
  public let nonExclusiveHardLinkFileCount: UInt64

  init(summary: ScanItemSummary) {
    observedLogicalBytes = summary.recursiveSize.logicalBytes
    observedAllocatedBytes = summary.recursiveSize.allocatedBytes
    observedHardLinkExclusiveAllocatedBytes = summary.hardLinkExclusiveAllocatedBytes
    possibleSharedContentFileCount = summary.possibleSharedContentFileCount
    sharedContentMetadataUnavailableCount =
      summary.sharedContentMetadataUnavailableCount
    unobservedHardLinkFileCount = summary.unobservedHardLinkFileCount
    nonExclusiveHardLinkFileCount = summary.nonExclusiveHardLinkFileCount
  }
}

public struct CleanupManifestEntry: Hashable, Sendable {
  public let path: ScanRelativePath
  public let expectedKind: FileSystemEntryKind
  public let expectedIdentity: FileIdentity
  public let ruleRevision: RuleRevision
  public let disposition: RuleDisposition
  public let reproducibility: RuleReproducibility
  public let displayName: String
  public let responsibleTool: String
  public let classificationExplanation: String
  public let findings: [RuleFinding]
  public let size: CleanupManifestSizeObservation

  init(
    path: ScanRelativePath,
    expectedKind: FileSystemEntryKind,
    expectedIdentity: FileIdentity,
    ruleRevision: RuleRevision,
    disposition: RuleDisposition,
    reproducibility: RuleReproducibility,
    displayName: String,
    responsibleTool: String,
    classificationExplanation: String,
    findings: [RuleFinding],
    size: CleanupManifestSizeObservation
  ) {
    self.path = path
    self.expectedKind = expectedKind
    self.expectedIdentity = expectedIdentity
    self.ruleRevision = ruleRevision
    self.disposition = disposition
    self.reproducibility = reproducibility
    self.displayName = displayName
    self.responsibleTool = responsibleTool
    self.classificationExplanation = classificationExplanation
    self.findings = findings.sorted { left, right in
      left.identifier < right.identifier
    }
    self.size = size
  }
}

public struct CleanupManifestTotals: Hashable, Sendable {
  public let observedLogicalBytes: UInt64
  public let observedAllocatedBytes: UInt64
  public let observedHardLinkExclusiveAllocatedBytes: UInt64
  public let possibleSharedContentFileCount: UInt64
  public let sharedContentMetadataUnavailableCount: UInt64
  public let unobservedHardLinkFileCount: UInt64
  public let nonExclusiveHardLinkFileCount: UInt64
}

/// An immutable, unapproved dry-run artifact produced from validated scan and
/// classification values. This value is never authority to mutate a path.
public struct CleanupManifest: Hashable, Sendable {
  public static let currentContractVersion: UInt32 = 1

  public let contractVersion: UInt32
  public let classificationReferenceUnixSeconds: Int64
  public let expectedRootIdentity: FileIdentity
  public let entries: [CleanupManifestEntry]
  public let totals: CleanupManifestTotals

  /// Every manifest still requires a separate explicit approval step.
  public var requiresExplicitApproval: Bool { true }

  /// Execution must always reopen and freshly validate the root, candidate,
  /// containment, kind, identity, and policy evidence before mutation.
  public var requiresExecutionRevalidation: Bool { true }

  init(
    classificationReferenceUnixSeconds: Int64,
    expectedRootIdentity: FileIdentity,
    entries: [CleanupManifestEntry]
  ) throws {
    let orderedEntries = entries.sorted { left, right in
      if left.path != right.path {
        return left.path < right.path
      }
      return left.ruleRevision < right.ruleRevision
    }
    contractVersion = Self.currentContractVersion
    self.classificationReferenceUnixSeconds = classificationReferenceUnixSeconds
    self.expectedRootIdentity = expectedRootIdentity
    self.entries = orderedEntries
    totals = try CleanupManifestTotals(entries: orderedEntries)
  }
}

extension CleanupManifestTotals {
  init(entries: [CleanupManifestEntry]) throws {
    var accumulator = MutableCleanupManifestTotals()
    for entry in entries {
      try Task.checkCancellation()
      try accumulator.add(entry.size)
    }
    self = accumulator.value
  }
}

private struct MutableCleanupManifestTotals {
  var observedLogicalBytes: UInt64 = 0
  var observedAllocatedBytes: UInt64 = 0
  var observedHardLinkExclusiveAllocatedBytes: UInt64 = 0
  var possibleSharedContentFileCount: UInt64 = 0
  var sharedContentMetadataUnavailableCount: UInt64 = 0
  var unobservedHardLinkFileCount: UInt64 = 0
  var nonExclusiveHardLinkFileCount: UInt64 = 0

  mutating func add(_ size: CleanupManifestSizeObservation) throws {
    try add(
      size.observedLogicalBytes,
      to: &observedLogicalBytes,
      metric: .observedLogicalBytes
    )
    try add(
      size.observedAllocatedBytes,
      to: &observedAllocatedBytes,
      metric: .observedAllocatedBytes
    )
    try add(
      size.observedHardLinkExclusiveAllocatedBytes,
      to: &observedHardLinkExclusiveAllocatedBytes,
      metric: .observedHardLinkExclusiveAllocatedBytes
    )
    try add(
      size.possibleSharedContentFileCount,
      to: &possibleSharedContentFileCount,
      metric: .possibleSharedContentFileCount
    )
    try add(
      size.sharedContentMetadataUnavailableCount,
      to: &sharedContentMetadataUnavailableCount,
      metric: .sharedContentMetadataUnavailableCount
    )
    try add(
      size.unobservedHardLinkFileCount,
      to: &unobservedHardLinkFileCount,
      metric: .unobservedHardLinkFileCount
    )
    try add(
      size.nonExclusiveHardLinkFileCount,
      to: &nonExclusiveHardLinkFileCount,
      metric: .nonExclusiveHardLinkFileCount
    )
  }

  var value: CleanupManifestTotals {
    CleanupManifestTotals(
      observedLogicalBytes: observedLogicalBytes,
      observedAllocatedBytes: observedAllocatedBytes,
      observedHardLinkExclusiveAllocatedBytes: observedHardLinkExclusiveAllocatedBytes,
      possibleSharedContentFileCount: possibleSharedContentFileCount,
      sharedContentMetadataUnavailableCount: sharedContentMetadataUnavailableCount,
      unobservedHardLinkFileCount: unobservedHardLinkFileCount,
      nonExclusiveHardLinkFileCount: nonExclusiveHardLinkFileCount
    )
  }

  private func add(
    _ value: UInt64,
    to total: inout UInt64,
    metric: CleanupSizeMetric
  ) throws {
    let (sum, overflow) = total.addingReportingOverflow(value)
    guard !overflow else {
      throw CleanupPlanningError.totalOverflow(metric)
    }
    total = sum
  }
}
