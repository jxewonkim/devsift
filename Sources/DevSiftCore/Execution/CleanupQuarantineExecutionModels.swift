/// Stable, bounded categories for a filesystem failure at the internal
/// quarantine boundary. Raw paths and arbitrary dependency errors never cross
/// into an execution report.
enum CleanupQuarantineSystemFailure: String, Equatable, Sendable {
  case permissionDenied = "permission-denied"
  case pathChanged = "path-changed"
  case unsupported = "unsupported"
  case crossDevice = "cross-device"
  case readOnlyFileSystem = "read-only-filesystem"
  case noSpace = "no-space"
  case resourceLimit = "resource-limit"
  case invalidMetadata = "invalid-metadata"
  case inputOutput = "input-output"
  case destinationExists = "destination-exists"
  case unspecified
}

/// Why an authorization was consumed without moving its approved candidate.
enum CleanupQuarantineNotMovedReason: Equatable, Sendable {
  case cancelled
  case invalidClaim
  case unsupportedPolicy
  case invalidCurrentAccount
  case trustedRootUnavailable(CleanupQuarantineSystemFailure)
  case trustedRootChanged
  case candidateMissing
  case candidateChanged
  case candidateUnsafe
  case traversalLimitExceeded
  case ageRequirementNotSatisfied
  case quarantineRootUnavailable(CleanupQuarantineSystemFailure)
  case quarantineRootUnsafe
  case exclusiveRenameUnsupported
  case invalidDestinationName
  case destinationCollisionLimitExceeded
  case preRenameValidationUnavailable(CleanupQuarantineSystemFailure)
  case renameRejected(CleanupQuarantineSystemFailure)
}

/// The bounded reason for a successful non-overwriting reverse rename.
enum CleanupQuarantineRollbackReason: String, Equatable, Sendable {
  case movedObjectDidNotMatchApproval = "moved-object-did-not-match-approval"
  case postMoveValidationUnavailable = "post-move-validation-unavailable"
}

/// Why Core cannot safely resolve a mutation without later recovery tooling.
enum CleanupQuarantineManualRecoveryReason: String, Equatable, Sendable {
  case renameOutcomeIndeterminate = "rename-outcome-indeterminate"
  case destinationCouldNotBeVerified = "destination-could-not-be-verified"
  case parentBindingChanged = "parent-binding-changed"
  case sourceNameOccupied = "source-name-occupied"
  case sourceCouldNotBeVerified = "source-could-not-be-verified"
  case restoredObjectDidNotMatchApproval = "restored-object-did-not-match-approval"
  case rollbackFailed = "rollback-failed"
  case rollbackOutcomeIndeterminate = "rollback-outcome-indeterminate"
}

/// Whether this attempt changed the fixed quarantine-root namespace before its
/// candidate outcome was known. `indeterminate` covers an interrupted or I/O
/// failed `mkdirat` whose mutation result cannot be inferred safely.
enum CleanupQuarantineRootMutation: String, Equatable, Sendable {
  case none
  case created
  case indeterminate
}

/// A root-relative quarantine location. It intentionally contains no absolute
/// path and is not yet a durable receipt.
struct CleanupQuarantineLocation: Equatable, Sendable {
  let relativePath: ScanRelativePath
  let observedIdentity: FileIdentity?
}

/// The only outcomes emitted after an authorization claim is consumed.
///
/// `quarantinedAwaitingReceipt` is deliberately not named `completed`: the
/// move is not crash-recoverable until a later increment durably records and
/// syncs its restore receipt.
enum CleanupQuarantineExecutionStatus: Equatable, Sendable {
  case notMoved(CleanupQuarantineNotMovedReason)
  case quarantinedAwaitingReceipt(
    location: CleanupQuarantineLocation,
    sourceNameWasRecreated: Bool
  )
  case rolledBack(CleanupQuarantineRollbackReason)
  case manualRecoveryRequired(
    location: CleanupQuarantineLocation?,
    reason: CleanupQuarantineManualRecoveryReason
  )
}

/// Internal result of one exact npm quarantine attempt.
///
/// This is process-local, non-serializable, and intentionally unavailable to
/// app and CLI targets until durable intent, receipt, and recovery exist.
struct CleanupQuarantineExecutionReport: Equatable, Sendable {
  static let currentContractVersion: UInt32 = 1

  let contractVersion: UInt32
  let path: ScanRelativePath
  let ruleRevision: RuleRevision
  let status: CleanupQuarantineExecutionStatus
  let quarantineRootMutation: CleanupQuarantineRootMutation
  let cancellationWasObservedAfterRename: Bool

  var isDurablyRecorded: Bool { false }
  var isCrashRecoverable: Bool { false }
  var performedPermanentDeletion: Bool { false }

  init(
    contractVersion: UInt32 = CleanupQuarantineExecutionReport.currentContractVersion,
    path: ScanRelativePath,
    ruleRevision: RuleRevision,
    status: CleanupQuarantineExecutionStatus,
    quarantineRootMutation: CleanupQuarantineRootMutation,
    cancellationWasObservedAfterRename: Bool = false
  ) {
    self.contractVersion = contractVersion
    self.path = path
    self.ruleRevision = ruleRevision
    self.status = status
    self.quarantineRootMutation = quarantineRootMutation
    self.cancellationWasObservedAfterRename = cancellationWasObservedAfterRename
  }
}
