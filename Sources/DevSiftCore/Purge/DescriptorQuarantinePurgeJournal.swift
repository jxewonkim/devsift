import Foundation

enum DescriptorQuarantinePurgeFailure: Error, Equatable, Sendable {
  case cancelled
  case journal(DescriptorQuarantineJournalFailure)
  case invalidClaim
  case transactionNotFound
  case transactionNotPurgeable
  case alreadyPurged
  case quarantinedItemMissing
  case quarantinedItemChanged
  case quarantinedItemUnsafe
  case workNameOccupied
  case traversalLimitExceeded
  case exclusiveRenameUnsupported
  case renameRejected(CleanupQuarantineSystemFailure)
}

struct DescriptorQuarantinePurgeJournalBeginRequest: Sendable {
  let recoveryRequest: DescriptorQuarantineJournalRecoveryRequest
  let quarantinedItemDescriptor: Int32
  let claim: CleanupQuarantinePurgeExecutionClaim
}

enum DescriptorQuarantinePurgeJournalBeginResult: Sendable {
  case success(DescriptorQuarantinePurgeJournalSession)
  case failure(DescriptorQuarantinePurgeFailure)
}

/// Injectable seams for admission and durable purge-intent publication.
struct DescriptorQuarantinePurgeJournalDependencies: Sendable {
  typealias ValidateCompleteTree =
    @Sendable (
      Int32,
      Int32,
      DescriptorPathComponent,
      DescriptorStatSnapshot,
      UInt64,
      uid_t
    ) throws -> Void

  var journal: DescriptorQuarantineJournalDependencies
  var validateCompleteTree: ValidateCompleteTree

  init(
    journal: DescriptorQuarantineJournalDependencies =
      DescriptorQuarantineJournalDependencies(),
    validateCompleteTree: @escaping ValidateCompleteTree =
      descriptorPurgeJournalValidateCompleteTree
  ) {
    self.journal = journal
    self.validateCompleteTree = validateCompleteTree
  }
}

/// Owns the shared journal lock after immutable purge-intent publication.
///
/// A successful stager hands this session to the future bounded unlink engine.
/// Releasing or dropping it preserves the final intent and current namespace;
/// it never rolls back or removes a record.
final class DescriptorQuarantinePurgeJournalSession: @unchecked Sendable {
  struct ProductionContext: Sendable {
    let recoveryRequest: DescriptorQuarantineJournalRecoveryRequest
    let canonicalQuarantineIntentBytes: Data
    let canonicalQuarantineReceiptBytes: Data
    let canonicalPurgeIntentBytes: Data
  }

  enum Payload: Sendable {
    case production(ProductionContext)
    case testing
  }

  let purgeTransactionID: String
  let quarantineTransactionID: String
  let attemptKind: CleanupQuarantinePurgeAttemptKind
  let intent: QuarantinePurgeJournalIntentV1
  let canonicalIntentBytes: Data
  let rootSnapshotAfterIntent: DescriptorStatSnapshot
  let quarantineRootSnapshotAfterIntent: DescriptorStatSnapshot
  let payload: Payload

  private let stateLock = NSLock()
  private var state = State.active
  private var lockDescriptor: Int32?
  private let unlock: @Sendable (Int32) -> Void

  private enum State {
    case active
    case terminalizing
    case finished
  }

  init(
    purgeTransactionID: String,
    quarantineTransactionID: String,
    attemptKind: CleanupQuarantinePurgeAttemptKind,
    intent: QuarantinePurgeJournalIntentV1,
    canonicalIntentBytes: Data,
    rootSnapshotAfterIntent: DescriptorStatSnapshot,
    quarantineRootSnapshotAfterIntent: DescriptorStatSnapshot,
    lockDescriptor: Int32?,
    unlock: @escaping @Sendable (Int32) -> Void,
    payload: Payload
  ) {
    self.purgeTransactionID = purgeTransactionID
    self.quarantineTransactionID = quarantineTransactionID
    self.attemptKind = attemptKind
    self.intent = intent
    self.canonicalIntentBytes = canonicalIntentBytes
    self.rootSnapshotAfterIntent = rootSnapshotAfterIntent
    self.quarantineRootSnapshotAfterIntent = quarantineRootSnapshotAfterIntent
    self.lockDescriptor = lockDescriptor
    self.unlock = unlock
    self.payload = payload
  }

  static func testing(
    intent: QuarantinePurgeJournalIntentV1,
    canonicalIntentBytes: Data,
    rootSnapshotAfterIntent: DescriptorStatSnapshot,
    quarantineRootSnapshotAfterIntent: DescriptorStatSnapshot,
    attemptKind: CleanupQuarantinePurgeAttemptKind = .initial
  ) -> DescriptorQuarantinePurgeJournalSession {
    DescriptorQuarantinePurgeJournalSession(
      purgeTransactionID: intent.purgeTransactionID,
      quarantineTransactionID: intent.quarantineTransactionID,
      attemptKind: attemptKind,
      intent: intent,
      canonicalIntentBytes: canonicalIntentBytes,
      rootSnapshotAfterIntent: rootSnapshotAfterIntent,
      quarantineRootSnapshotAfterIntent: quarantineRootSnapshotAfterIntent,
      lockDescriptor: nil,
      unlock: { _ in },
      payload: .testing
    )
  }

  /// Releases only the advisory lock. Durable records and staged work remain.
  func releasePreservingIntent() {
    let descriptor: Int32?
    stateLock.lock()
    guard state == .active else {
      stateLock.unlock()
      return
    }
    state = .finished
    descriptor = lockDescriptor
    lockDescriptor = nil
    stateLock.unlock()
    if let descriptor {
      unlock(descriptor)
      descriptorCloseIgnoringErrors(descriptor)
    }
  }

  /// Claims this lock-owning session exactly once for receipt publication or
  /// a synchronized receipt-less handoff.
  func claimForTerminalization() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard state == .active, lockDescriptor != nil else { return false }
    state = .terminalizing
    return true
  }

  /// Ends a terminalization attempt and releases only the advisory lock. A
  /// failed or partial attempt deliberately preserves every durable record and
  /// any remaining work tree.
  func completeTerminalization() {
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
    state = .finished
    descriptor = lockDescriptor
    lockDescriptor = nil
    stateLock.unlock()
    if let descriptor {
      unlock(descriptor)
      descriptorCloseIgnoringErrors(descriptor)
    }
  }
}

struct DescriptorQuarantinePurgeJournal: Sendable {
  typealias BeginOperation =
    @Sendable (
      DescriptorQuarantinePurgeJournalBeginRequest
    ) -> DescriptorQuarantinePurgeJournalBeginResult

  private enum Backend: Sendable {
    case production(DescriptorQuarantinePurgeJournalDependencies)
    case injected(BeginOperation)
  }

  private let backend: Backend

  init(
    dependencies: DescriptorQuarantinePurgeJournalDependencies =
      DescriptorQuarantinePurgeJournalDependencies()
  ) {
    backend = .production(dependencies)
  }

  init(begin: @escaping BeginOperation) {
    backend = .injected(begin)
  }

  func begin(
    _ request: DescriptorQuarantinePurgeJournalBeginRequest
  ) -> DescriptorQuarantinePurgeJournalBeginResult {
    switch backend {
    case .production(let dependencies):
      descriptorJournalBeginPurge(request, dependencies: dependencies)
    case .injected(let operation):
      operation(request)
    }
  }
}

private func descriptorPurgeJournalValidateCompleteTree(
  descriptor: Int32,
  parentDescriptor: Int32,
  component: DescriptorPathComponent,
  expected: DescriptorStatSnapshot,
  rootDevice: UInt64,
  accountUID: uid_t
) throws {
  _ = try DescriptorNPMCompletePurgeTreeValidator(
    checkpoint: { try Task.checkCancellation() }
  ).validate(
    descriptor: descriptor,
    namedAt: parentDescriptor,
    component: component,
    expected: expected,
    rootDevice: rootDevice,
    accountUID: accountUID
  )
}
