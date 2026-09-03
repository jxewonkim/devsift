import DevSiftCore

/// A read-only, identity-free projection of an immutable cleanup manifest.
///
/// This value deliberately retains neither the source manifest nor any
/// filesystem identity, root, reference time, serialization, approval, or
/// execution state. An exact relative path identifies a row only within the
/// already-bound in-memory review flow; it is not authority to mutate it.
struct CleanupManifestReviewPresentation: Hashable, Sendable {
  let entryCount: Int
  let reclaimableCount: Int
  let reviewRequiredCount: Int
  let totals: CleanupManifestReviewSizePresentation
  let entries: [CleanupManifestReviewEntryPresentation]

  static func prepare(
    manifest: CleanupManifest
  ) throws -> CleanupManifestReviewPresentation {
    try prepare(manifest: manifest) {
      try Task.checkCancellation()
    }
  }

  /// The injected check keeps cancellation coverage deterministic without
  /// weakening the production entry point, which always uses the current task.
  static func prepare(
    manifest: CleanupManifest,
    cancellationCheck: () throws -> Void
  ) throws -> CleanupManifestReviewPresentation {
    try cancellationCheck()

    var reclaimableCount = 0
    var reviewRequiredCount = 0
    var entries: [CleanupManifestReviewEntryPresentation] = []
    entries.reserveCapacity(manifest.entries.count)

    // CleanupManifest owns the stable exact-path ordering. Project it in that
    // order so this potentially 50,000-row pass remains cancellation-aware.
    for entry in manifest.entries {
      try cancellationCheck()

      switch entry.disposition {
      case .reclaimable:
        reclaimableCount += 1
      case .reviewRequired:
        reviewRequiredCount += 1
      case .protected:
        break
      }

      var findings: [CleanupManifestReviewFindingPresentation] = []
      findings.reserveCapacity(entry.findings.count)
      for finding in entry.findings {
        try cancellationCheck()
        findings.append(CleanupManifestReviewFindingPresentation(finding: finding))
      }

      entries.append(
        CleanupManifestReviewEntryPresentation(
          entry: entry,
          findings: findings
        )
      )
    }

    try cancellationCheck()
    return CleanupManifestReviewPresentation(
      entryCount: entries.count,
      reclaimableCount: reclaimableCount,
      reviewRequiredCount: reviewRequiredCount,
      totals: CleanupManifestReviewSizePresentation(totals: manifest.totals),
      entries: entries
    )
  }
}

struct CleanupManifestReviewEntryPresentation: Hashable, Identifiable, Sendable {
  /// Exact raw-byte identity for selection and row diffing. Never render this
  /// value directly; `displayPath` is the terminal/UI-safe representation.
  let id: ScanRelativePath
  let displayPath: String
  let displayName: String
  let responsibleTool: String
  let classificationExplanation: String
  let ruleRevisionLabel: String
  let disposition: RuleDisposition
  let reproducibility: RuleReproducibility
  let findings: [CleanupManifestReviewFindingPresentation]
  let size: CleanupManifestReviewSizePresentation

  fileprivate init(
    entry: CleanupManifestEntry,
    findings: [CleanupManifestReviewFindingPresentation]
  ) {
    id = entry.path
    displayPath = SafeDisplayText.path(entry.path)
    displayName = SafeDisplayText.scalarSafe(entry.displayName)
    responsibleTool = SafeDisplayText.scalarSafe(entry.responsibleTool)
    classificationExplanation = SafeDisplayText.scalarSafe(
      entry.classificationExplanation
    )
    ruleRevisionLabel =
      "\(entry.ruleRevision.identifier.rawValue)@\(entry.ruleRevision.version.rawValue)"
    disposition = entry.disposition
    reproducibility = entry.reproducibility
    self.findings = findings
    size = CleanupManifestReviewSizePresentation(size: entry.size)
  }
}

struct CleanupManifestReviewFindingPresentation: Hashable, Sendable {
  let identifier: String
  let kind: RuleFindingKind
  let state: RuleFindingState
  let explanation: String

  fileprivate init(finding: RuleFinding) {
    identifier = finding.identifier.rawValue
    kind = finding.kind
    state = finding.state
    explanation = SafeDisplayText.scalarSafe(finding.explanation)
  }
}

struct CleanupManifestReviewSizePresentation: Hashable, Sendable {
  let observedLogicalBytes: UInt64
  let observedAllocatedBytes: UInt64
  let observedHardLinkExclusiveAllocatedBytes: UInt64
  let possibleSharedContentFileCount: UInt64
  let sharedContentMetadataUnavailableCount: UInt64
  let unobservedHardLinkFileCount: UInt64
  let nonExclusiveHardLinkFileCount: UInt64

  fileprivate init(size: CleanupManifestSizeObservation) {
    observedLogicalBytes = size.observedLogicalBytes
    observedAllocatedBytes = size.observedAllocatedBytes
    observedHardLinkExclusiveAllocatedBytes = size.observedHardLinkExclusiveAllocatedBytes
    possibleSharedContentFileCount = size.possibleSharedContentFileCount
    sharedContentMetadataUnavailableCount = size.sharedContentMetadataUnavailableCount
    unobservedHardLinkFileCount = size.unobservedHardLinkFileCount
    nonExclusiveHardLinkFileCount = size.nonExclusiveHardLinkFileCount
  }

  fileprivate init(totals: CleanupManifestTotals) {
    observedLogicalBytes = totals.observedLogicalBytes
    observedAllocatedBytes = totals.observedAllocatedBytes
    observedHardLinkExclusiveAllocatedBytes = totals.observedHardLinkExclusiveAllocatedBytes
    possibleSharedContentFileCount = totals.possibleSharedContentFileCount
    sharedContentMetadataUnavailableCount = totals.sharedContentMetadataUnavailableCount
    unobservedHardLinkFileCount = totals.unobservedHardLinkFileCount
    nonExclusiveHardLinkFileCount = totals.nonExclusiveHardLinkFileCount
  }
}
