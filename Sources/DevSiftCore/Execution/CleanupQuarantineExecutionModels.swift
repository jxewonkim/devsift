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
  case quarantineJournalBusy
  case quarantineJournalUnavailable(CleanupQuarantineSystemFailure)
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
  case quarantineJournalUnsafe = "quarantine-journal-unsafe"
  case durabilityRecordingFailed = "durability-recording-failed"
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
/// path; the report's durability state says whether a receipt binds it.
struct CleanupQuarantineLocation: Equatable, Sendable {
  let relativePath: ScanRelativePath
  let observedIdentity: FileIdentity?
}

/// The only outcomes emitted after an authorization claim is consumed.
///
enum CleanupQuarantineExecutionStatus: Equatable, Sendable {
  case notMoved(CleanupQuarantineNotMovedReason)
  case quarantined(
    location: CleanupQuarantineLocation,
    sourceNameWasRecreated: Bool
  )
  case rolledBack(CleanupQuarantineRollbackReason)
  case manualRecoveryRequired(
    location: CleanupQuarantineLocation?,
    reason: CleanupQuarantineManualRecoveryReason
  )
}

/// Monotonic durability evidence for one execution report. Transaction IDs
/// are random bounded identifiers, not filesystem paths or authorization.
enum CleanupQuarantineDurabilityState: Equatable, Sendable {
  case notRecorded
  case intentRecorded(transactionID: String)
  case receiptRecorded(transactionID: String, producedByRecovery: Bool)
  case unresolved(transactionID: String?)

  var isDurablyRecorded: Bool {
    guard case .receiptRecorded = self else { return false }
    return true
  }

  var isCrashRecoverable: Bool {
    switch self {
    case .intentRecorded, .receiptRecorded:
      return true
    case .notRecorded, .unresolved:
      return false
    }
  }
}

/// Internal result of one exact npm quarantine attempt.
///
/// This is process-local, non-serializable, and intentionally unavailable to
/// app and CLI targets until durable intent, receipt, and recovery exist.
struct CleanupQuarantineExecutionReport: Equatable, Sendable {
  static let currentContractVersion: UInt32 = 2

  let contractVersion: UInt32
  let path: ScanRelativePath
  let ruleRevision: RuleRevision
  let status: CleanupQuarantineExecutionStatus
  let durabilityState: CleanupQuarantineDurabilityState
  let quarantineRootMutation: CleanupQuarantineRootMutation
  let cancellationWasObservedAfterRename: Bool

  var isDurablyRecorded: Bool { durabilityState.isDurablyRecorded }
  var isCrashRecoverable: Bool { durabilityState.isCrashRecoverable }
  var performedPermanentDeletion: Bool { false }

  init(
    contractVersion: UInt32 = CleanupQuarantineExecutionReport.currentContractVersion,
    path: ScanRelativePath,
    ruleRevision: RuleRevision,
    status: CleanupQuarantineExecutionStatus,
    durabilityState: CleanupQuarantineDurabilityState = .notRecorded,
    quarantineRootMutation: CleanupQuarantineRootMutation,
    cancellationWasObservedAfterRename: Bool = false
  ) {
    self.contractVersion = contractVersion
    self.path = path
    self.ruleRevision = ruleRevision
    self.status = status
    self.durabilityState = durabilityState
    self.quarantineRootMutation = quarantineRootMutation
    self.cancellationWasObservedAfterRename = cancellationWasObservedAfterRename
  }

  func replacing(
    status: CleanupQuarantineExecutionStatus? = nil,
    durabilityState: CleanupQuarantineDurabilityState? = nil
  ) -> CleanupQuarantineExecutionReport {
    CleanupQuarantineExecutionReport(
      contractVersion: contractVersion,
      path: path,
      ruleRevision: ruleRevision,
      status: status ?? self.status,
      durabilityState: durabilityState ?? self.durabilityState,
      quarantineRootMutation: quarantineRootMutation,
      cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
    )
  }
}
