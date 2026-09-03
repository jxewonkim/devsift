import Foundation

/// The point-in-time result of reobserving one approved manifest entry.
///
/// Eligibility is diagnostic only. A caller must not use this value as a
/// filesystem capability or assume that the observation remains current.
public struct CleanupRevalidationEntry: Hashable, Sendable {
  public let path: ScanRelativePath
  public let ruleRevision: RuleRevision
  public let status: CleanupRevalidationStatus
}

public enum CleanupRevalidationStatus: Hashable, Sendable {
  case eligibleAtObservation
  case awaitingExecutionPreconditions([RuleDeferredExecutionPrecondition])
  case rejected(CleanupRevalidationRejection)
}

/// A bounded reason why an approved entry was not eligible when reobserved.
public enum CleanupRevalidationRejection: Hashable, Sendable {
  case sourceObservationIncomplete
  case candidateMissing
  case candidateAmbiguous
  case candidateKindChanged(
    expected: FileSystemEntryKind,
    observed: FileSystemEntryKind
  )
  case candidateIdentityChanged
  case ruleRevisionChanged(expected: RuleRevision, observed: RuleRevision?)
  case blockingFinding(CheckIdentifier)
  case policyDecisionChanged
}

/// A non-persistent, point-in-time diagnostic produced from one approval.
///
/// The absolute source root is deliberately omitted. This report neither
/// authorizes mutation nor removes the need for descriptor-relative checks in
/// the executor immediately before each operation.
public struct CleanupRevalidationReport: Hashable, Sendable {
  public static let currentContractVersion: UInt32 = 2

  public let contractVersion: UInt32
  public let observedRootIdentity: FileIdentity
  public let policyProvenance: RulePolicyProvenance
  public let referenceUnixSeconds: Int64
  public let entries: [CleanupRevalidationEntry]

  public var grantsFilesystemMutationAuthority: Bool { false }
  public var requiresImmediateExecutionRevalidation: Bool { true }
  public var isFullyEligibleAtObservation: Bool {
    !entries.isEmpty && entries.allSatisfy { $0.status == .eligibleAtObservation }
  }

  public var hasPendingExecutionPreconditions: Bool {
    entries.contains { entry in
      if case .awaitingExecutionPreconditions = entry.status {
        return true
      }
      return false
    }
  }

  init(
    contractVersion: UInt32 = CleanupRevalidationReport.currentContractVersion,
    observedRootIdentity: FileIdentity,
    policyProvenance: RulePolicyProvenance,
    referenceUnixSeconds: Int64,
    entries: [CleanupRevalidationEntry]
  ) {
    self.contractVersion = contractVersion
    self.observedRootIdentity = observedRootIdentity
    self.policyProvenance = policyProvenance
    self.referenceUnixSeconds = referenceUnixSeconds
    self.entries = entries
  }
}

public enum CleanupRevalidationApprovalInvariant: String, Hashable, Sendable {
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

/// Stable failure categories which do not expose arbitrary dependency errors.
public enum CleanupRevalidationError: Error, Equatable, Sendable {
  case invalidApproval(CleanupRevalidationApprovalInvariant)
  case unsupportedApprovalPolicy
  case scanFailed
  case invalidScanReport
  case rootIdentityChanged
  case classificationFailed
  case invalidClassificationReport
  case classificationReportIsNotSourceBound
  case unsupportedClassificationPolicy
  case planningInvariantFailed
}
