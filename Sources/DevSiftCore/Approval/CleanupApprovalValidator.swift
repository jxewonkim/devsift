import Foundation

/// A stable reason why an approval cannot cross a later safety boundary.
public enum CleanupApprovalInvariant: String, Hashable, Sendable {
  case approvalContractVersion = "approval-contract-version"
  case manifestContractVersion = "manifest-contract-version"
  case invalidSourceRoot = "invalid-source-root"
  case emptyManifest = "empty-manifest"
  case tooManyEntries = "too-many-entries"
  case entriesNotCanonical = "entries-not-canonical"
  case duplicateEntryPath = "duplicate-entry-path"
  case invalidEntryPath = "invalid-entry-path"
  case unsupportedEntryKind = "unsupported-entry-kind"
  case entryDeviceMismatch = "entry-device-mismatch"
  case undeclaredRuleRevision = "undeclared-rule-revision"
  case ineligibleDisposition = "ineligible-disposition"
  case invalidFindings = "invalid-findings"
  case invalidPreconditionReviewAcknowledgements =
    "invalid-precondition-review-acknowledgements"
  case invalidTotals = "invalid-totals"
}

enum CleanupApprovalValidationError: Error, Equatable, Sendable {
  case invalid(CleanupApprovalInvariant)
  case unsupportedPolicy
}

/// Performs the one canonical, read-only approval preflight shared by every
/// boundary after approval. It does not open, scan, or mutate the filesystem.
enum CleanupApprovalValidator {
  static func validate(
    _ approval: CleanupApproval,
    supportedPolicyProvenance: RulePolicyProvenance
  ) throws {
    guard approval.contractVersion == CleanupApproval.currentContractVersion else {
      throw invalid(.approvalContractVersion)
    }
    guard approval.reviewedManifest.contractVersion == CleanupManifest.currentContractVersion else {
      throw invalid(.manifestContractVersion)
    }
    guard LocalFileSystemRootValidator.isValid(approval.sourceRoot) else {
      throw invalid(.invalidSourceRoot)
    }

    let manifest = approval.reviewedManifest
    guard manifest.policyProvenance == supportedPolicyProvenance else {
      throw CleanupApprovalValidationError.unsupportedPolicy
    }
    guard !manifest.entries.isEmpty else {
      throw invalid(.emptyManifest)
    }
    guard manifest.entries.count <= CleanupPlanningLimits.maximumSelections else {
      throw invalid(.tooManyEntries)
    }

    let ordered = manifest.entries.sorted(by: manifestEntryOrder)
    guard ordered == manifest.entries else {
      throw invalid(.entriesNotCanonical)
    }
    var paths = Set<ScanRelativePath>()
    for entry in manifest.entries {
      try Task.checkCancellation()
      guard paths.insert(entry.path).inserted else {
        throw invalid(.duplicateEntryPath)
      }
      guard candidatePathIsValid(entry.path) else {
        throw invalid(.invalidEntryPath)
      }
      guard entry.expectedKind == .directory else {
        throw invalid(.unsupportedEntryKind)
      }
      guard entry.expectedIdentity.device == manifest.expectedRootIdentity.device else {
        throw invalid(.entryDeviceMismatch)
      }
      guard manifest.policyProvenance.ruleRevisions.contains(entry.ruleRevision) else {
        throw invalid(.undeclaredRuleRevision)
      }
      guard entry.disposition == .reclaimable || entry.disposition == .reviewRequired else {
        throw invalid(.ineligibleDisposition)
      }
      guard entryIsPolicyValid(entry) else {
        throw invalid(.invalidFindings)
      }
    }
    guard preconditionReviewAcknowledgementsAreValid(approval) else {
      throw invalid(.invalidPreconditionReviewAcknowledgements)
    }
    guard try totalsAreValid(manifest) else {
      throw invalid(.invalidTotals)
    }
  }

  private static func entryIsPolicyValid(_ entry: CleanupManifestEntry) -> Bool {
    let findings = entry.findings
    guard
      !findings.isEmpty,
      findings.count <= RuleCatalogLimits.maximumFindingsPerEvaluation
    else {
      return false
    }
    let identifiers = findings.map(\.identifier)
    guard identifiers == identifiers.sorted(), Set(identifiers).count == identifiers.count else {
      return false
    }
    return entry.deferredExecutionPreconditionsAreWellFormed
      && entry.nonDeferredBlockingFindings.isEmpty
  }

  private static func preconditionReviewAcknowledgementsAreValid(
    _ approval: CleanupApproval
  ) -> Bool {
    var expected: [PreconditionBinding] = []
    for entry in approval.reviewedManifest.entries {
      for precondition in entry.deferredExecutionPreconditions {
        expected.append(
          PreconditionBinding(
            ordinal: expected.count,
            path: entry.path,
            ruleRevision: entry.ruleRevision,
            precondition: precondition
          )
        )
      }
    }
    let actual = approval.preconditionReviewAcknowledgements.map { acknowledgement in
      PreconditionBinding(
        ordinal: acknowledgement.ordinal,
        path: acknowledgement.path,
        ruleRevision: acknowledgement.ruleRevision,
        precondition: acknowledgement.precondition
      )
    }
    return actual == expected
  }

  private static func totalsAreValid(_ manifest: CleanupManifest) throws -> Bool {
    var logical: UInt64 = 0
    var allocated: UInt64 = 0
    var exclusive: UInt64 = 0
    var possibleShared: UInt64 = 0
    var unavailableShared: UInt64 = 0
    var unobservedHardLinks: UInt64 = 0
    var nonExclusiveHardLinks: UInt64 = 0

    for entry in manifest.entries {
      try Task.checkCancellation()
      guard
        add(entry.size.observedLogicalBytes, to: &logical),
        add(entry.size.observedAllocatedBytes, to: &allocated),
        add(entry.size.observedHardLinkExclusiveAllocatedBytes, to: &exclusive),
        add(entry.size.possibleSharedContentFileCount, to: &possibleShared),
        add(entry.size.sharedContentMetadataUnavailableCount, to: &unavailableShared),
        add(entry.size.unobservedHardLinkFileCount, to: &unobservedHardLinks),
        add(entry.size.nonExclusiveHardLinkFileCount, to: &nonExclusiveHardLinks)
      else {
        return false
      }
    }
    return logical == manifest.totals.observedLogicalBytes
      && allocated == manifest.totals.observedAllocatedBytes
      && exclusive == manifest.totals.observedHardLinkExclusiveAllocatedBytes
      && possibleShared == manifest.totals.possibleSharedContentFileCount
      && unavailableShared == manifest.totals.sharedContentMetadataUnavailableCount
      && unobservedHardLinks == manifest.totals.unobservedHardLinkFileCount
      && nonExclusiveHardLinks == manifest.totals.nonExclusiveHardLinkFileCount
  }

  private static func add(_ value: UInt64, to total: inout UInt64) -> Bool {
    let (sum, overflow) = total.addingReportingOverflow(value)
    guard !overflow else { return false }
    total = sum
    return true
  }

  private static func candidatePathIsValid(_ path: ScanRelativePath) -> Bool {
    guard path.rawComponents.count == 1 else { return false }
    let component = path.rawComponents[0]
    return !component.isEmpty
      && component != [0x2E]
      && component != [0x2E, 0x2E]
      && !component.contains(0)
      && !component.contains(0x2F)
      && component.count <= CleanupPlanningLimits.maximumCandidateComponentBytes
  }

  private static func manifestEntryOrder(
    _ left: CleanupManifestEntry,
    _ right: CleanupManifestEntry
  ) -> Bool {
    if left.path != right.path { return left.path < right.path }
    return left.ruleRevision < right.ruleRevision
  }

  private static func invalid(
    _ invariant: CleanupApprovalInvariant
  ) -> CleanupApprovalValidationError {
    .invalid(invariant)
  }
}

private struct PreconditionBinding: Equatable {
  let ordinal: Int
  let path: ScanRelativePath
  let ruleRevision: RuleRevision
  let precondition: RuleDeferredExecutionPrecondition
}
