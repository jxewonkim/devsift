import Foundation

enum DescriptorQuarantineRestoreFailure: Error, Equatable, Sendable {
  case cancelled
  case journal(DescriptorQuarantineJournalFailure)
  case invalidClaim
  case transactionNotFound
  case transactionNotRestorable
  case alreadyRestored
  case sourceNameOccupied
  case quarantinedItemMissing
  case quarantinedItemChanged
  case quarantinedItemUnsafe
  case traversalLimitExceeded
  case exclusiveRenameUnsupported
  case renameRejected(CleanupQuarantineSystemFailure)
}

struct DescriptorQuarantineRestorePreparationRequest: Sendable {
  let recoveryRequest: DescriptorQuarantineJournalRecoveryRequest
  let quarantineTransactionID: String
  let restoreTransactionID: String
  let expectedCanonicalQuarantineIntentBytes: Data?
  let expectedCanonicalQuarantineReceiptBytes: Data?

  init(
    recoveryRequest: DescriptorQuarantineJournalRecoveryRequest,
    quarantineTransactionID: String,
    restoreTransactionID: String,
    expectedCanonicalQuarantineIntentBytes: Data? = nil,
    expectedCanonicalQuarantineReceiptBytes: Data? = nil
  ) {
    self.recoveryRequest = recoveryRequest
    self.quarantineTransactionID = quarantineTransactionID
    self.restoreTransactionID = restoreTransactionID
    self.expectedCanonicalQuarantineIntentBytes = expectedCanonicalQuarantineIntentBytes
    self.expectedCanonicalQuarantineReceiptBytes = expectedCanonicalQuarantineReceiptBytes
  }
}

enum DescriptorQuarantineRestorePreparationResult: Equatable, Sendable {
  case success(CleanupQuarantineRestorePreparedEvidence)
  case failure(DescriptorQuarantineRestoreFailure)
}

struct DescriptorQuarantineRestoreJournalBeginRequest: Sendable {
  let recoveryRequest: DescriptorQuarantineJournalRecoveryRequest
  let quarantinedItemDescriptor: Int32
  let claim: CleanupQuarantineRestoreExecutionClaim
}

enum DescriptorQuarantineRestoreJournalBeginResult: Sendable {
  case success(DescriptorQuarantineRestoreJournalSession)
  case failure(DescriptorQuarantineRestoreFailure)
}

enum DescriptorQuarantineRestoreJournalTerminalOutcome: Equatable, Sendable {
  case notRestored(sourceNameWasOccupied: Bool)
  case restored(quarantineNameWasRecreated: Bool)
  case unresolved
}

enum DescriptorQuarantineRestoreJournalFinishResult: Equatable, Sendable {
  case receiptRecorded(QuarantineRestoreJournalReceiptV1)
  case recoveryRequired(restoreTransactionID: String)
  case unresolved(restoreTransactionID: String)
  case invalidSession
}

/// Owns the shared journal lock from durable restore-intent publication through
/// terminal restore-receipt publication. Dropping a live session preserves the
/// intent for observational recovery and only releases the advisory lock.
final class DescriptorQuarantineRestoreJournalSession: @unchecked Sendable {
  struct ProductionContext: Sendable {
    let recoveryRequest: DescriptorQuarantineJournalRecoveryRequest
    let canonicalQuarantineIntentBytes: Data
    let canonicalQuarantineReceiptBytes: Data
    let canonicalRestoreIntentBytes: Data
  }

  enum Payload: Sendable {
    case production(ProductionContext)
    case testing
  }

  let restoreTransactionID: String
  let quarantineTransactionID: String
  let intent: QuarantineRestoreJournalIntentV1
  let canonicalIntentBytes: Data
  let rootSnapshotAfterIntent: DescriptorStatSnapshot
  let quarantineRootSnapshotAfterIntent: DescriptorStatSnapshot

  private let stateLock = NSLock()
  private var state = State.active
  private var lockDescriptor: Int32?
  private let unlock: @Sendable (Int32) -> Void
  let payload: Payload

  private enum State {
    case active
    case finishing
    case finished
  }

  init(
    restoreTransactionID: String,
    quarantineTransactionID: String,
    intent: QuarantineRestoreJournalIntentV1,
    canonicalIntentBytes: Data,
    rootSnapshotAfterIntent: DescriptorStatSnapshot,
    quarantineRootSnapshotAfterIntent: DescriptorStatSnapshot,
    lockDescriptor: Int32?,
    unlock: @escaping @Sendable (Int32) -> Void,
    payload: Payload
  ) {
    self.restoreTransactionID = restoreTransactionID
    self.quarantineTransactionID = quarantineTransactionID
    self.intent = intent
    self.canonicalIntentBytes = canonicalIntentBytes
    self.rootSnapshotAfterIntent = rootSnapshotAfterIntent
    self.quarantineRootSnapshotAfterIntent = quarantineRootSnapshotAfterIntent
    self.lockDescriptor = lockDescriptor
    self.unlock = unlock
    self.payload = payload
  }

  static func testing(
    intent: QuarantineRestoreJournalIntentV1,
    canonicalIntentBytes: Data,
    rootSnapshotAfterIntent: DescriptorStatSnapshot,
    quarantineRootSnapshotAfterIntent: DescriptorStatSnapshot
  ) -> DescriptorQuarantineRestoreJournalSession {
    DescriptorQuarantineRestoreJournalSession(
      restoreTransactionID: intent.restoreTransactionID,
      quarantineTransactionID: intent.quarantineTransactionID,
      intent: intent,
      canonicalIntentBytes: canonicalIntentBytes,
      rootSnapshotAfterIntent: rootSnapshotAfterIntent,
      quarantineRootSnapshotAfterIntent: quarantineRootSnapshotAfterIntent,
      lockDescriptor: nil,
      unlock: { _ in },
      payload: .testing
    )
  }

  fileprivate func claimForFinish() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard state == .active else { return false }
    state = .finishing
    return true
  }

  fileprivate func completeFinish() {
    let descriptor: Int32?
    stateLock.lock()
    state = .finished
    descriptor = lockDescriptor
    lockDescriptor = nil
    stateLock.unlock()
    if let descriptor {
      unlock(descriptor)
      descriptorCloseIgnoringErrors(descriptor)
    }
  }

  deinit {
    let descriptor: Int32?
    stateLock.lock()
    descriptor = lockDescriptor
    lockDescriptor = nil
    state = .finished
    stateLock.unlock()
    if let descriptor {
      unlock(descriptor)
      descriptorCloseIgnoringErrors(descriptor)
    }
  }
}

struct DescriptorQuarantineRestoreJournal: Sendable {
  typealias PrepareOperation =
    @Sendable (
      DescriptorQuarantineRestorePreparationRequest
    ) -> DescriptorQuarantineRestorePreparationResult
  typealias BeginOperation =
    @Sendable (
      DescriptorQuarantineRestoreJournalBeginRequest
    ) -> DescriptorQuarantineRestoreJournalBeginResult
  typealias FinishOperation =
    @Sendable (
      DescriptorQuarantineRestoreJournalSession,
      DescriptorQuarantineRestoreJournalTerminalOutcome,
      Bool
    ) -> DescriptorQuarantineRestoreJournalFinishResult

  private enum Backend: Sendable {
    case production(DescriptorQuarantineJournalDependencies)
    case injected(PrepareOperation, BeginOperation, FinishOperation)
  }

  private let backend: Backend

  init(
    dependencies: DescriptorQuarantineJournalDependencies =
      DescriptorQuarantineJournalDependencies()
  ) {
    backend = .production(dependencies)
  }

  init(
    prepare: @escaping PrepareOperation,
    begin: @escaping BeginOperation,
    finish: @escaping FinishOperation
  ) {
    backend = .injected(prepare, begin, finish)
  }

  func prepare(
    _ request: DescriptorQuarantineRestorePreparationRequest
  ) -> DescriptorQuarantineRestorePreparationResult {
    switch backend {
    case .production(let dependencies):
      return descriptorJournalPrepareRestore(request, dependencies: dependencies)
    case .injected(let operation, _, _):
      return operation(request)
    }
  }

  func begin(
    _ request: DescriptorQuarantineRestoreJournalBeginRequest
  ) -> DescriptorQuarantineRestoreJournalBeginResult {
    switch backend {
    case .production(let dependencies):
      return descriptorJournalBeginRestore(request, dependencies: dependencies)
    case .injected(_, let operation, _):
      return operation(request)
    }
  }

  func finish(
    _ session: DescriptorQuarantineRestoreJournalSession,
    outcome: DescriptorQuarantineRestoreJournalTerminalOutcome,
    namespaceMutationMayHaveBeenInvoked: Bool
  ) -> DescriptorQuarantineRestoreJournalFinishResult {
    guard session.claimForFinish() else { return .invalidSession }
    defer { session.completeFinish() }

    switch backend {
    case .production(let dependencies):
      return descriptorJournalFinishRestore(
        session,
        outcome: outcome,
        namespaceMutationMayHaveBeenInvoked: namespaceMutationMayHaveBeenInvoked,
        dependencies: dependencies
      )
    case .injected(_, _, let operation):
      return operation(session, outcome, namespaceMutationMayHaveBeenInvoked)
    }
  }
}
