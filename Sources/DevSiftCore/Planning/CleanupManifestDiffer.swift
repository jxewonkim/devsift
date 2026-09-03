public protocol CleanupManifestDiffing: Sendable {
  func difference(
    from baseline: CleanupManifest,
    to comparison: CleanupManifest
  ) throws -> CleanupManifestDiff
}

/// Compares compatible manifests without opening or mutating the filesystem.
public struct CleanupManifestDiffer: CleanupManifestDiffing, Sendable {
  public init() {}

  public func difference(
    from baseline: CleanupManifest,
    to comparison: CleanupManifest
  ) throws -> CleanupManifestDiff {
    try Task.checkCancellation()

    guard baseline.contractVersion == comparison.contractVersion else {
      throw CleanupManifestDiffError.manifestContractVersionMismatch(
        baseline: baseline.contractVersion,
        comparison: comparison.contractVersion
      )
    }
    guard baseline.contractVersion == CleanupManifest.currentContractVersion else {
      throw CleanupManifestDiffError.unsupportedManifestContractVersion(
        baseline.contractVersion
      )
    }
    guard baseline.policyProvenance == comparison.policyProvenance else {
      throw CleanupManifestDiffError.policyProvenanceMismatch
    }
    guard baseline.expectedRootIdentity == comparison.expectedRootIdentity else {
      throw CleanupManifestDiffError.rootIdentityMismatch
    }

    try validateEntries(
      baseline.entries,
      policyProvenance: baseline.policyProvenance,
      side: .baseline
    )
    try validateEntries(
      comparison.entries,
      policyProvenance: comparison.policyProvenance,
      side: .comparison
    )
    try Task.checkCancellation()

    var differences: [CleanupManifestEntryDifference] = []
    differences.reserveCapacity(baseline.entries.count + comparison.entries.count)
    var unchangedEntryCount = 0
    var baselineIndex = baseline.entries.startIndex
    var comparisonIndex = comparison.entries.startIndex

    while baselineIndex < baseline.entries.endIndex
      || comparisonIndex < comparison.entries.endIndex
    {
      try Task.checkCancellation()

      if baselineIndex == baseline.entries.endIndex {
        differences.append(.added(comparison.entries[comparisonIndex]))
        comparisonIndex = comparison.entries.index(after: comparisonIndex)
        continue
      }
      if comparisonIndex == comparison.entries.endIndex {
        differences.append(.removed(baseline.entries[baselineIndex]))
        baselineIndex = baseline.entries.index(after: baselineIndex)
        continue
      }

      let baselineEntry = baseline.entries[baselineIndex]
      let comparisonEntry = comparison.entries[comparisonIndex]
      if baselineEntry.path < comparisonEntry.path {
        differences.append(.removed(baselineEntry))
        baselineIndex = baseline.entries.index(after: baselineIndex)
      } else if comparisonEntry.path < baselineEntry.path {
        differences.append(.added(comparisonEntry))
        comparisonIndex = comparison.entries.index(after: comparisonIndex)
      } else {
        if baselineEntry == comparisonEntry {
          unchangedEntryCount += 1
        } else {
          let fields = changedFields(from: baselineEntry, to: comparisonEntry)
          guard !fields.isEmpty else {
            throw CleanupManifestDiffError.unrepresentedEntryDifference(
              baselineEntry.path
            )
          }
          differences.append(
            .modified(
              CleanupManifestEntryModification(
                baseline: baselineEntry,
                comparison: comparisonEntry,
                changedFields: fields
              )
            )
          )
        }
        baselineIndex = baseline.entries.index(after: baselineIndex)
        comparisonIndex = comparison.entries.index(after: comparisonIndex)
      }
    }

    try Task.checkCancellation()
    let result = CleanupManifestDiff(
      sourceManifestContractVersion: baseline.contractVersion,
      policyProvenance: baseline.policyProvenance,
      expectedRootIdentity: baseline.expectedRootIdentity,
      baselineReferenceUnixSeconds: baseline.classificationReferenceUnixSeconds,
      comparisonReferenceUnixSeconds: comparison.classificationReferenceUnixSeconds,
      baselineEntryCount: baseline.entries.count,
      comparisonEntryCount: comparison.entries.count,
      unchangedEntryCount: unchangedEntryCount,
      entryDifferences: differences,
      totals: CleanupManifestTotalsDifference(
        baseline: baseline.totals,
        comparison: comparison.totals
      )
    )
    try Task.checkCancellation()
    return result
  }

  private func validateEntries(
    _ entries: [CleanupManifestEntry],
    policyProvenance: RulePolicyProvenance,
    side: CleanupManifestDiffSide
  ) throws {
    guard entries.count <= CleanupPlanningLimits.maximumSelections else {
      throw CleanupManifestDiffError.tooManyEntries(
        side: side,
        maximum: CleanupPlanningLimits.maximumSelections,
        actual: entries.count
      )
    }

    let declaredRuleRevisions = Set(policyProvenance.ruleRevisions)
    var previousPath: ScanRelativePath?
    for entry in entries {
      try Task.checkCancellation()
      guard declaredRuleRevisions.contains(entry.ruleRevision) else {
        throw CleanupManifestDiffError.undeclaredPolicyRuleRevision(
          side: side,
          path: entry.path,
          revision: entry.ruleRevision
        )
      }
      if let previousPath {
        if entry.path == previousPath {
          throw CleanupManifestDiffError.duplicateEntryPath(
            side: side,
            path: entry.path
          )
        }
        guard previousPath < entry.path else {
          throw CleanupManifestDiffError.entriesOutOfOrder(
            side: side,
            previous: previousPath,
            current: entry.path
          )
        }
      }
      previousPath = entry.path
    }
  }

  private func changedFields(
    from baseline: CleanupManifestEntry,
    to comparison: CleanupManifestEntry
  ) -> [CleanupManifestEntryField] {
    var fields: [CleanupManifestEntryField] = []
    if baseline.expectedKind != comparison.expectedKind {
      fields.append(.expectedKind)
    }
    if baseline.expectedIdentity != comparison.expectedIdentity {
      fields.append(.expectedIdentity)
    }
    if baseline.ruleRevision != comparison.ruleRevision {
      fields.append(.ruleRevision)
    }
    if baseline.disposition != comparison.disposition {
      fields.append(.disposition)
    }
    if baseline.reproducibility != comparison.reproducibility {
      fields.append(.reproducibility)
    }
    if baseline.displayName != comparison.displayName {
      fields.append(.displayName)
    }
    if baseline.responsibleTool != comparison.responsibleTool {
      fields.append(.responsibleTool)
    }
    if baseline.classificationExplanation != comparison.classificationExplanation {
      fields.append(.classificationExplanation)
    }
    if baseline.findings != comparison.findings {
      fields.append(.findings)
    }
    if baseline.deferredExecutionPreconditions != comparison.deferredExecutionPreconditions {
      fields.append(.deferredExecutionPreconditions)
    }
    if baseline.size.observedLogicalBytes != comparison.size.observedLogicalBytes {
      fields.append(.observedLogicalBytes)
    }
    if baseline.size.observedAllocatedBytes != comparison.size.observedAllocatedBytes {
      fields.append(.observedAllocatedBytes)
    }
    if baseline.size.observedHardLinkExclusiveAllocatedBytes
      != comparison.size.observedHardLinkExclusiveAllocatedBytes
    {
      fields.append(.observedHardLinkExclusiveAllocatedBytes)
    }
    if baseline.size.possibleSharedContentFileCount
      != comparison.size.possibleSharedContentFileCount
    {
      fields.append(.possibleSharedContentFileCount)
    }
    if baseline.size.sharedContentMetadataUnavailableCount
      != comparison.size.sharedContentMetadataUnavailableCount
    {
      fields.append(.sharedContentMetadataUnavailableCount)
    }
    if baseline.size.unobservedHardLinkFileCount
      != comparison.size.unobservedHardLinkFileCount
    {
      fields.append(.unobservedHardLinkFileCount)
    }
    if baseline.size.nonExclusiveHardLinkFileCount
      != comparison.size.nonExclusiveHardLinkFileCount
    {
      fields.append(.nonExclusiveHardLinkFileCount)
    }
    return fields
  }
}
