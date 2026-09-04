/// Stable reasons why a consumed restore claim completed without moving its
/// quarantined item back to the original source name.
enum CleanupQuarantineRestoreNotRestoredReason: Equatable, Sendable {
  case cancelled
  case invalidClaim
  case unsupported
  case originalTransactionUnavailable
  case originalTransactionNotRestorable
  case alreadyRestored
  case sourceNameOccupied
  case quarantinedItemMissing
  case quarantinedItemChanged
  case quarantinedItemUnsafe
  case traversalLimitExceeded
  case quarantineJournalBusy
  case quarantineJournalUnavailable(CleanupQuarantineSystemFailure)
  case exclusiveRenameUnsupported
  case renameRejected(CleanupQuarantineSystemFailure)
}

/// Why Core cannot safely classify a restore mutation without later bounded
/// recovery. These values contain no raw paths or dependency error strings.
enum CleanupQuarantineRestoreManualRecoveryReason: String, Equatable, Sendable {
  case quarantineJournalUnsafe = "quarantine-journal-unsafe"
  case durabilityRecordingFailed = "durability-recording-failed"
  case renameOutcomeIndeterminate = "rename-outcome-indeterminate"
  case parentBindingChanged = "parent-binding-changed"
  case sourceCouldNotBeVerified = "source-could-not-be-verified"
  case quarantineItemCouldNotBeVerified = "quarantine-item-could-not-be-verified"
}

/// The bounded result of one exact, user-confirmed restore attempt.
enum CleanupQuarantineRestoreStatus: Equatable, Sendable {
  case notRestored(CleanupQuarantineRestoreNotRestoredReason)
  case restored(
    source: ScanRelativePath,
    quarantineNameWasRecreated: Bool
  )
  case manualRecoveryRequired(
    quarantineLocation: CleanupQuarantineLocation?,
    reason: CleanupQuarantineRestoreManualRecoveryReason
  )
}

/// Monotonic evidence for the separate restore transaction. A completed
/// `not-restored` receipt is durable without claiming that a restore occurred.
enum CleanupQuarantineRestoreDurabilityState: Equatable, Sendable {
  case notRecorded
  case intentRecorded(restoreTransactionID: String)
  case receiptRecorded(restoreTransactionID: String, producedByRecovery: Bool)
  case unresolved(restoreTransactionID: String?)

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

/// Internal, process-local report for one restore attempt. It is deliberately
/// non-Codable and is not reachable from the app or CLI in this increment.
struct CleanupQuarantineRestoreReport: Equatable, Sendable {
  static let currentContractVersion: UInt32 = 1

  let contractVersion: UInt32
  let quarantineTransactionID: String
  let restoreTransactionID: String?
  let path: ScanRelativePath
  let ruleRevision: RuleRevision
  let status: CleanupQuarantineRestoreStatus
  let durabilityState: CleanupQuarantineRestoreDurabilityState
  let cancellationWasObservedAfterRename: Bool

  var isDurablyRecorded: Bool { durabilityState.isDurablyRecorded }
  var isCrashRecoverable: Bool { durabilityState.isCrashRecoverable }
  var isDurablyRestored: Bool {
    guard isDurablyRecorded, case .restored = status else { return false }
    return true
  }
  var performedPermanentDeletion: Bool { false }
  var overwroteExistingItem: Bool { false }

  init(
    contractVersion: UInt32 = CleanupQuarantineRestoreReport.currentContractVersion,
    quarantineTransactionID: String,
    restoreTransactionID: String?,
    path: ScanRelativePath,
    ruleRevision: RuleRevision,
    status: CleanupQuarantineRestoreStatus,
    durabilityState: CleanupQuarantineRestoreDurabilityState = .notRecorded,
    cancellationWasObservedAfterRename: Bool = false
  ) {
    self.contractVersion = contractVersion
    self.quarantineTransactionID = quarantineTransactionID
    self.restoreTransactionID = restoreTransactionID
    self.path = path
    self.ruleRevision = ruleRevision
    self.status = status
    self.durabilityState = durabilityState
    self.cancellationWasObservedAfterRename = cancellationWasObservedAfterRename
  }

  func replacing(
    status: CleanupQuarantineRestoreStatus? = nil,
    durabilityState: CleanupQuarantineRestoreDurabilityState? = nil,
    cancellationWasObservedAfterRename: Bool? = nil
  ) -> CleanupQuarantineRestoreReport {
    CleanupQuarantineRestoreReport(
      contractVersion: contractVersion,
      quarantineTransactionID: quarantineTransactionID,
      restoreTransactionID: restoreTransactionID,
      path: path,
      ruleRevision: ruleRevision,
      status: status ?? self.status,
      durabilityState: durabilityState ?? self.durabilityState,
      cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
        ?? self.cancellationWasObservedAfterRename
    )
  }
}
