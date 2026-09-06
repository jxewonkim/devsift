import Foundation

/// Exact descriptor-held inputs for continuing one already staged purge.
///
/// The request cannot select a path or create a transaction. The claim must be
/// an explicit-retry authority bound to the canonical intent and current work
/// identity retained by the inventory/preflight pipeline.
struct DescriptorQuarantinePurgeRetryJournalRequest: Sendable {
  let recoveryRequest: DescriptorQuarantineJournalRecoveryRequest
  let purgeWorkDescriptor: Int32
  let claim: CleanupQuarantinePurgeExecutionClaim
}

struct DescriptorQuarantinePurgeRetrySession: Sendable {
  let journalSession: DescriptorQuarantinePurgeJournalSession
  let workSnapshot: DescriptorStatSnapshot
  let quarantineNameWasRecreated: Bool
}

enum DescriptorQuarantinePurgeRetryJournalResult: Sendable {
  case success(DescriptorQuarantinePurgeRetrySession)
  case failure(DescriptorQuarantinePurgeFailure)
}

/// Acquires the shared journal lock and revalidates an existing receipt-less
/// purge intent and its exact work remainder. It never publishes a new intent,
/// invokes a staging rename, or unlinks a name.
struct DescriptorQuarantinePurgeRetryJournal: Sendable {
  private let dependencies: DescriptorQuarantineJournalDependencies

  init(
    dependencies: DescriptorQuarantineJournalDependencies =
      DescriptorQuarantineJournalDependencies()
  ) {
    self.dependencies = dependencies
  }

  func begin(
    _ request: DescriptorQuarantinePurgeRetryJournalRequest
  ) -> DescriptorQuarantinePurgeRetryJournalResult {
    descriptorJournalBeginPurgeRetry(request, dependencies: dependencies)
  }
}

enum DescriptorQuarantinePurgeTerminalOutcome: Equatable, Sendable {
  case notPurged
  case itemAbsent
}

enum DescriptorQuarantinePurgeManualRecoveryReason: Error, Equatable, Sendable {
  case invalidRequest
  case journalUnsafe
  case recordsChanged
  case parentBindingChanged
  case namespaceAmbiguous
  case workTreeChanged
  case workTreeUnsafe
  case traversalLimitExceeded
  case durabilityUnresolved
}

struct DescriptorQuarantinePurgeTerminalizationRequest: Sendable {
  let journalSession: DescriptorQuarantinePurgeJournalSession
  let outcome: DescriptorQuarantinePurgeTerminalOutcome
  let capacityObservationProvenance: QuarantinePurgeCapacityObservationProvenanceV1
}

enum DescriptorQuarantinePurgeTerminalizationResult: Equatable, Sendable {
  case receiptRecorded(
    QuarantinePurgeJournalReceiptV1,
    observedCapacityChange: QuarantinePurgeObservedCapacityChange
  )
  case retryRequired
  case manualRecoveryRequired(DescriptorQuarantinePurgeManualRecoveryReason)
  case invalidSession
}

/// Reconciles exact Q/W namespace truth and either publishes one immutable
/// terminal receipt or preserves a synchronized valid work remainder. It never
/// renames or unlinks a filesystem entry.
struct DescriptorQuarantinePurgeTerminalizer: Sendable {
  private let dependencies: DescriptorQuarantineJournalDependencies

  init(
    dependencies: DescriptorQuarantineJournalDependencies =
      DescriptorQuarantineJournalDependencies()
  ) {
    self.dependencies = dependencies
  }

  func terminalize(
    _ request: DescriptorQuarantinePurgeTerminalizationRequest
  ) -> DescriptorQuarantinePurgeTerminalizationResult {
    guard request.journalSession.claimForTerminalization() else {
      return .invalidSession
    }
    defer { request.journalSession.completeTerminalization() }
    return descriptorJournalTerminalizePurge(
      request,
      dependencies: dependencies
    )
  }
}
