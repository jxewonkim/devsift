public enum CleanupManifestDiffSide: String, CaseIterable, Hashable, Sendable {
  case baseline
  case comparison
}

public enum CleanupManifestDiffError: Error, Equatable, Sendable {
  case manifestContractVersionMismatch(baseline: UInt32, comparison: UInt32)
  case unsupportedManifestContractVersion(UInt32)
  case policyProvenanceMismatch
  case rootIdentityMismatch
  case tooManyEntries(side: CleanupManifestDiffSide, maximum: Int, actual: Int)
  case entriesOutOfOrder(
    side: CleanupManifestDiffSide,
    previous: ScanRelativePath,
    current: ScanRelativePath
  )
  case duplicateEntryPath(side: CleanupManifestDiffSide, path: ScanRelativePath)
  case undeclaredPolicyRuleRevision(
    side: CleanupManifestDiffSide,
    path: ScanRelativePath,
    revision: RuleRevision
  )
  case unrepresentedEntryDifference(ScanRelativePath)
}

/// Stored entry fields compared for a same-path modification.
///
/// Declaration order is the canonical presentation order.
public enum CleanupManifestEntryField: String, CaseIterable, Hashable, Sendable {
  case expectedKind = "expected-kind"
  case expectedIdentity = "expected-identity"
  case ruleRevision = "rule-revision"
  case disposition
  case reproducibility
  case displayName = "display-name"
  case responsibleTool = "responsible-tool"
  case classificationExplanation = "classification-explanation"
  case findings
  case deferredExecutionPreconditions = "deferred-execution-preconditions"
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

/// An overflow-safe directional difference between two observed quantities.
public enum CleanupQuantityDifference: Hashable, Sendable {
  case unchanged
  case increased(by: UInt64)
  case decreased(by: UInt64)

  init(baseline: UInt64, comparison: UInt64) {
    if comparison > baseline {
      self = .increased(by: comparison - baseline)
    } else if comparison < baseline {
      self = .decreased(by: baseline - comparison)
    } else {
      self = .unchanged
    }
  }
}

public struct CleanupManifestTotalsDifference: Hashable, Sendable {
  public let observedLogicalBytes: CleanupQuantityDifference
  public let observedAllocatedBytes: CleanupQuantityDifference
  public let observedHardLinkExclusiveAllocatedBytes: CleanupQuantityDifference
  public let possibleSharedContentFileCount: CleanupQuantityDifference
  public let sharedContentMetadataUnavailableCount: CleanupQuantityDifference
  public let unobservedHardLinkFileCount: CleanupQuantityDifference
  public let nonExclusiveHardLinkFileCount: CleanupQuantityDifference

  init(baseline: CleanupManifestTotals, comparison: CleanupManifestTotals) {
    observedLogicalBytes = CleanupQuantityDifference(
      baseline: baseline.observedLogicalBytes,
      comparison: comparison.observedLogicalBytes
    )
    observedAllocatedBytes = CleanupQuantityDifference(
      baseline: baseline.observedAllocatedBytes,
      comparison: comparison.observedAllocatedBytes
    )
    observedHardLinkExclusiveAllocatedBytes = CleanupQuantityDifference(
      baseline: baseline.observedHardLinkExclusiveAllocatedBytes,
      comparison: comparison.observedHardLinkExclusiveAllocatedBytes
    )
    possibleSharedContentFileCount = CleanupQuantityDifference(
      baseline: baseline.possibleSharedContentFileCount,
      comparison: comparison.possibleSharedContentFileCount
    )
    sharedContentMetadataUnavailableCount = CleanupQuantityDifference(
      baseline: baseline.sharedContentMetadataUnavailableCount,
      comparison: comparison.sharedContentMetadataUnavailableCount
    )
    unobservedHardLinkFileCount = CleanupQuantityDifference(
      baseline: baseline.unobservedHardLinkFileCount,
      comparison: comparison.unobservedHardLinkFileCount
    )
    nonExclusiveHardLinkFileCount = CleanupQuantityDifference(
      baseline: baseline.nonExclusiveHardLinkFileCount,
      comparison: comparison.nonExclusiveHardLinkFileCount
    )
  }
}

public struct CleanupManifestEntryModification: Hashable, Sendable {
  public let baseline: CleanupManifestEntry
  public let comparison: CleanupManifestEntry
  public let changedFields: [CleanupManifestEntryField]
}

public enum CleanupManifestEntryDifference: Hashable, Sendable {
  case added(CleanupManifestEntry)
  case removed(CleanupManifestEntry)
  case modified(CleanupManifestEntryModification)

  public var path: ScanRelativePath {
    switch self {
    case .added(let entry), .removed(let entry):
      entry.path
    case .modified(let modification):
      modification.baseline.path
    }
  }
}

/// An immutable, in-memory comparison of two compatible draft manifests.
///
/// This value describes retained observations only. It is not approval,
/// freshness evidence, an authenticity proof, or filesystem authority.
public struct CleanupManifestDiff: Hashable, Sendable {
  public static let currentContractVersion: UInt32 = 2

  public let contractVersion: UInt32
  public let sourceManifestContractVersion: UInt32
  public let policyProvenance: RulePolicyProvenance
  public let expectedRootIdentity: FileIdentity
  public let baselineReferenceUnixSeconds: Int64
  public let comparisonReferenceUnixSeconds: Int64
  public let baselineEntryCount: Int
  public let comparisonEntryCount: Int
  public let unchangedEntryCount: Int
  public let entryDifferences: [CleanupManifestEntryDifference]
  public let totals: CleanupManifestTotalsDifference

  public var isEmpty: Bool { entryDifferences.isEmpty }

  init(
    sourceManifestContractVersion: UInt32,
    policyProvenance: RulePolicyProvenance,
    expectedRootIdentity: FileIdentity,
    baselineReferenceUnixSeconds: Int64,
    comparisonReferenceUnixSeconds: Int64,
    baselineEntryCount: Int,
    comparisonEntryCount: Int,
    unchangedEntryCount: Int,
    entryDifferences: [CleanupManifestEntryDifference],
    totals: CleanupManifestTotalsDifference
  ) {
    contractVersion = Self.currentContractVersion
    self.sourceManifestContractVersion = sourceManifestContractVersion
    self.policyProvenance = policyProvenance
    self.expectedRootIdentity = expectedRootIdentity
    self.baselineReferenceUnixSeconds = baselineReferenceUnixSeconds
    self.comparisonReferenceUnixSeconds = comparisonReferenceUnixSeconds
    self.baselineEntryCount = baselineEntryCount
    self.comparisonEntryCount = comparisonEntryCount
    self.unchangedEntryCount = unchangedEntryCount
    self.entryDifferences = entryDifferences
    self.totals = totals
  }
}
