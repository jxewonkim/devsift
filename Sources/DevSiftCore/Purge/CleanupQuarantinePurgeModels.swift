/// Terminal outcomes that are backed by one immutable purge receipt.
enum CleanupQuarantinePurgeTerminalReceiptOutcome: String, Equatable, Sendable {
  case notPurged = "not-purged"
  case itemAbsent = "item-absent"
}

/// Why a consumed purge authority reached no durable purge intent and no
/// irreversible namespace operation.
///
/// Every associated failure is a stable category. Paths, managed components,
/// transaction identifiers, canonical bytes, and dependency descriptions are
/// deliberately absent.
enum CleanupQuarantinePurgeNoMutationReason: Equatable, Sendable {
  case cancelled
  case invalidClaim
  case unsupportedPlatform
  case invalidCurrentAccount
  case trustedRootUnavailable(CleanupQuarantineSystemFailure)
  case trustedRootChanged
  case journalRecordMissing
  case journalRecordChanged
  case journalRecordUnsafe
  case quarantinedItemMissing
  case quarantinedItemChanged
  case quarantinedItemUnsafe
  case purgeWorkMissing
  case purgeWorkChanged
  case purgeWorkUnsafe
  case purgeWorkNameOccupied
  case traversalLimitExceeded
  case capacityObservationUnavailable
  case purgeIdentifierUnavailable
  case originalTransactionUnavailable
  case originalTransactionNotPurgeable
  case alreadyPurged
  case quarantineJournalBusy
  case quarantineJournalUnavailable(CleanupQuarantineSystemFailure)
  case exclusiveRenameUnsupported
  case renameRejected(CleanupQuarantineSystemFailure)
}

/// Process-local progress observed during the current call.
///
/// A later inventory cannot reconstruct this distinction because purge does
/// not persist a complete original-entry manifest or per-name progress.
enum CleanupQuarantinePurgeProgress: String, Equatable, Sendable {
  case stagedWithNoUnlinkObserved = "staged-with-no-unlink-observed"
  case unlinkProgressObserved = "unlink-progress-observed"
}

/// Why an exact, synchronized work remainder needs a separately confirmed
/// explicit retry.
enum CleanupQuarantinePurgeRetryReason: Equatable, Sendable {
  case cancelled
  case namespaceChanged
  case treeChanged
  case treeUnsafe
  case traversalLimitExceeded
  case synchronizationLimitExceeded
  case observationUnavailable(CleanupQuarantineSystemFailure)
  case unlinkRejected(CleanupQuarantineSystemFailure)
  case synchronizationFailed(CleanupQuarantineSystemFailure)
}

/// A durable purge intent whose current Q/W truth must be reconciled by the
/// read-only recovery boundary before another action is offered.
enum CleanupQuarantinePurgeRecoveryReason: String, Equatable, Sendable {
  case stagingNotCommitted = "staging-not-committed"
  case stagingMayHaveBeenInvoked = "staging-may-have-been-invoked"
  case journalRequiresReconciliation = "journal-requires-reconciliation"
}

/// Why the executor cannot safely advertise a terminal receipt or an explicit
/// retry. These values never embed a filesystem or journal identifier.
enum CleanupQuarantinePurgeManualRecoveryReason: String, Equatable, Sendable {
  case invalidExecutionResult = "invalid-execution-result"
  case invalidTerminalReceipt = "invalid-terminal-receipt"
  case invalidTerminalizationSession = "invalid-terminalization-session"
  case journalUnsafe = "journal-unsafe"
  case recordsChanged = "records-changed"
  case parentBindingChanged = "parent-binding-changed"
  case namespaceAmbiguous = "namespace-ambiguous"
  case workTreeChanged = "work-tree-changed"
  case workTreeUnsafe = "work-tree-unsafe"
  case traversalLimitExceeded = "traversal-limit-exceeded"
  case durabilityUnresolved = "durability-unresolved"
}

/// Bounded result of one explicitly confirmed purge pass.
enum CleanupQuarantinePurgeStatus: Equatable, Sendable {
  case noMutation(CleanupQuarantinePurgeNoMutationReason)
  case notPurged
  case observationalRecoveryRequired(CleanupQuarantinePurgeRecoveryReason)
  case explicitRetryRequired(
    progress: CleanupQuarantinePurgeProgress,
    reason: CleanupQuarantinePurgeRetryReason
  )
  case itemAbsent
  case manualRecoveryRequired(CleanupQuarantinePurgeManualRecoveryReason)
}

/// Monotonic durability evidence without exposing a journal identifier.
enum CleanupQuarantinePurgeDurabilityState: Equatable, Sendable {
  case notRecorded
  case intentRecorded
  case terminalReceiptRecorded(
    outcome: CleanupQuarantinePurgeTerminalReceiptOutcome,
    producedByRecovery: Bool
  )
  case unresolved

  var isDurablyTerminal: Bool {
    guard case .terminalReceiptRecorded = self else { return false }
    return true
  }

  var isCrashRecoverable: Bool {
    switch self {
    case .intentRecorded, .terminalReceiptRecorded:
      return true
    case .notRecorded, .unresolved:
      return false
    }
  }
}

/// Privacy-bounded, process-local report for one purge authorization.
///
/// The report intentionally contains no path, raw component, transaction
/// identifier, canonical record bytes, filesystem binding, or raw dependency
/// error. Capacity change is observational and never attributed to DevSift.
struct CleanupQuarantinePurgeReport: Equatable, Sendable {
  static let currentContractVersion: UInt32 = 1

  let contractVersion: UInt32
  let attemptKind: CleanupQuarantinePurgeAttemptKind
  let status: CleanupQuarantinePurgeStatus
  let durabilityState: CleanupQuarantinePurgeDurabilityState
  let capacityObservationProvenance: QuarantinePurgeCapacityObservationProvenanceV1?
  let observedCapacityChange: QuarantinePurgeObservedCapacityChange

  /// Number of names for which this call invoked `unlinkat` and then observed
  /// the name absent. It is bounded by the sealed intent policy and does not
  /// prove who removed the object, secure erasure, or reclaimed capacity.
  let observedUnlinkCount: UInt64
  let cancellationWasObserved: Bool

  var isDurablyTerminal: Bool { durabilityState.isDurablyTerminal }
  var isCrashRecoverable: Bool { durabilityState.isCrashRecoverable }

  /// `true` means only that this process observed at least one successful
  /// unlink linearization during this call. It is not a secure-erasure,
  /// attribution, or storage-reclamation claim.
  var performedPermanentDeletion: Bool { observedUnlinkCount > 0 }

  var requiresExplicitRetry: Bool {
    guard case .explicitRetryRequired = status else { return false }
    return true
  }

  init(
    contractVersion: UInt32 = CleanupQuarantinePurgeReport.currentContractVersion,
    attemptKind: CleanupQuarantinePurgeAttemptKind,
    status: CleanupQuarantinePurgeStatus,
    durabilityState: CleanupQuarantinePurgeDurabilityState,
    capacityObservationProvenance: QuarantinePurgeCapacityObservationProvenanceV1? = nil,
    observedCapacityChange: QuarantinePurgeObservedCapacityChange = .unavailable,
    observedUnlinkCount: UInt64 = 0,
    cancellationWasObserved: Bool = false
  ) {
    self.contractVersion = contractVersion
    self.attemptKind = attemptKind
    self.status = status
    self.durabilityState = durabilityState
    self.capacityObservationProvenance = capacityObservationProvenance
    self.observedCapacityChange = observedCapacityChange
    self.observedUnlinkCount = observedUnlinkCount
    self.cancellationWasObserved = cancellationWasObserved
  }
}
