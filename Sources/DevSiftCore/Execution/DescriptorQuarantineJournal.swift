import Darwin
import Foundation

enum DescriptorQuarantineJournalFailure: Error, Equatable, Sendable {
  case busy
  case unsafe
  case unavailable(CleanupQuarantineSystemFailure)
  case recoveryRequired(transactionID: String?)
}

struct DescriptorQuarantineJournalBeginRequest: Sendable {
  let rootDescriptor: Int32
  let quarantineRootDescriptor: Int32
  let candidateDescriptor: Int32
  let quarantineRootComponent: DescriptorPathComponent
  let absoluteRootComponents: [DescriptorPathComponent]
  let homeComponentCount: Int
  let accountUID: uid_t
  let intent: QuarantineJournalIntentV1
}

struct DescriptorQuarantineJournalRecoveryRequest: Sendable {
  let rootDescriptor: Int32
  let quarantineRootDescriptor: Int32
  let quarantineRootComponent: DescriptorPathComponent
  let absoluteRootComponents: [DescriptorPathComponent]
  let homeComponentCount: Int
  let accountUID: uid_t
}

enum DescriptorQuarantineJournalBeginResult: Sendable {
  case success(DescriptorQuarantineJournalSession)
  case failure(DescriptorQuarantineJournalFailure)
}

enum DescriptorQuarantineJournalTerminalOutcome: Equatable, Sendable {
  case notMoved
  case quarantined(selectedDestinationOrdinal: Int, sourceNameWasRecreated: Bool)
  case rolledBack
  case unresolved
}

enum DescriptorQuarantineJournalFinishResult: Equatable, Sendable {
  case receiptRecorded(QuarantineJournalReceiptV1)
  case recoveryRequired(transactionID: String)
  case unresolved(transactionID: String)
  case invalidSession
}

struct DescriptorQuarantineJournalRecoverySummary: Equatable, Sendable {
  let recoveredReceipts: [QuarantineJournalReceiptV1]
  let validatedTransactionCount: Int
}

enum DescriptorQuarantineJournalRecoveryResult: Equatable, Sendable {
  case success(DescriptorQuarantineJournalRecoverySummary)
  case failure(DescriptorQuarantineJournalFailure)
}

struct DescriptorQuarantineJournalHooks: Sendable {
  var didAcquireLock: @Sendable () -> Void
  var willFullSync: @Sendable (Int32) -> Void
  var didCreateStage: @Sendable (DescriptorPathComponent) -> Void
  var willReadInventory: @Sendable () -> Void
  var didEnumerateInventory: @Sendable () -> Void
  var willPublishStage: @Sendable (DescriptorPathComponent, DescriptorPathComponent) -> Void
  var didPublishFinal: @Sendable (DescriptorPathComponent) -> Void

  init(
    didAcquireLock: @escaping @Sendable () -> Void = {},
    willFullSync: @escaping @Sendable (Int32) -> Void = { _ in },
    didCreateStage: @escaping @Sendable (DescriptorPathComponent) -> Void = { _ in },
    willReadInventory: @escaping @Sendable () -> Void = {},
    didEnumerateInventory: @escaping @Sendable () -> Void = {},
    willPublishStage:
      @escaping @Sendable (
        DescriptorPathComponent,
        DescriptorPathComponent
      ) -> Void = { _, _ in },
    didPublishFinal: @escaping @Sendable (DescriptorPathComponent) -> Void = { _ in }
  ) {
    self.didAcquireLock = didAcquireLock
    self.willFullSync = willFullSync
    self.didCreateStage = didCreateStage
    self.willReadInventory = willReadInventory
    self.didEnumerateInventory = didEnumerateInventory
    self.willPublishStage = willPublishStage
    self.didPublishFinal = didPublishFinal
  }
}

struct DescriptorQuarantineJournalDependencies: Sendable {
  var fullSync: @Sendable (Int32) -> Int32?
  var writeAll: @Sendable (Int32, Data) -> Int32?
  var renameExclusive:
    @Sendable (
      Int32,
      DescriptorPathComponent,
      DescriptorPathComponent,
      UInt32
    ) -> DescriptorExclusiveRenameResult
  var lockExclusiveNonBlocking: @Sendable (Int32) -> Int32?
  var unlock: @Sendable (Int32) -> Void
  var hasExtendedACL: @Sendable (Int32) -> Result<Bool, DescriptorJournalPOSIXError>
  var hooks: DescriptorQuarantineJournalHooks

  init(
    fullSync: @escaping @Sendable (Int32) -> Int32? = descriptorJournalFullSync,
    writeAll: @escaping @Sendable (Int32, Data) -> Int32? = descriptorJournalWriteAll,
    renameExclusive:
      @escaping @Sendable (
        Int32,
        DescriptorPathComponent,
        DescriptorPathComponent,
        UInt32
      ) -> DescriptorExclusiveRenameResult = descriptorJournalRenameExclusive,
    lockExclusiveNonBlocking: @escaping @Sendable (Int32) -> Int32? =
      descriptorJournalLockExclusiveNonBlocking,
    unlock: @escaping @Sendable (Int32) -> Void = descriptorJournalUnlock,
    hasExtendedACL: @escaping @Sendable (Int32) -> Result<Bool, DescriptorJournalPOSIXError> =
      descriptorJournalHasExtendedACL,
    hooks: DescriptorQuarantineJournalHooks = DescriptorQuarantineJournalHooks()
  ) {
    self.fullSync = fullSync
    self.writeAll = writeAll
    self.renameExclusive = renameExclusive
    self.lockExclusiveNonBlocking = lockExclusiveNonBlocking
    self.unlock = unlock
    self.hasExtendedACL = hasExtendedACL
    self.hooks = hooks
  }
}

struct DescriptorJournalPOSIXError: Error, Equatable, Sendable {
  let code: Int32
}

/// Owns the advisory lock for exactly one durable intent. A session can be
/// finished once; abandoning it releases the lock but deliberately leaves the
/// already-published intent for startup recovery.
final class DescriptorQuarantineJournalSession: @unchecked Sendable {
  struct ProductionContext: Sendable {
    let rootDescriptor: Int32
    let quarantineRootDescriptor: Int32
    let quarantineRootComponent: DescriptorPathComponent
    let absoluteRootComponents: [DescriptorPathComponent]
    let homeComponentCount: Int
    let accountUID: uid_t
    let canonicalIntentBytes: Data
  }

  fileprivate enum Payload: Sendable {
    case production(ProductionContext)
    case testing
  }

  let transactionID: String
  let intent: QuarantineJournalIntentV1
  let canonicalIntentBytes: Data
  let quarantineRootSnapshotAfterIntent: DescriptorStatSnapshot

  private let stateLock = NSLock()
  private var state = State.active
  private var lockDescriptor: Int32?
  private let unlock: @Sendable (Int32) -> Void
  fileprivate let payload: Payload

  private enum State {
    case active
    case finishing
    case finished
  }

  fileprivate init(
    transactionID: String,
    intent: QuarantineJournalIntentV1,
    canonicalIntentBytes: Data,
    quarantineRootSnapshotAfterIntent: DescriptorStatSnapshot,
    lockDescriptor: Int32?,
    unlock: @escaping @Sendable (Int32) -> Void,
    payload: Payload
  ) {
    self.transactionID = transactionID
    self.intent = intent
    self.canonicalIntentBytes = canonicalIntentBytes
    self.quarantineRootSnapshotAfterIntent = quarantineRootSnapshotAfterIntent
    self.lockDescriptor = lockDescriptor
    self.unlock = unlock
    self.payload = payload
  }

  static func testing(
    intent: QuarantineJournalIntentV1,
    canonicalIntentBytes: Data,
    quarantineRootSnapshotAfterIntent: DescriptorStatSnapshot
  ) -> DescriptorQuarantineJournalSession {
    DescriptorQuarantineJournalSession(
      transactionID: intent.transactionID,
      intent: intent,
      canonicalIntentBytes: canonicalIntentBytes,
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

struct DescriptorQuarantineJournal: Sendable {
  typealias BeginOperation =
    @Sendable (DescriptorQuarantineJournalBeginRequest) -> DescriptorQuarantineJournalBeginResult
  typealias FinishOperation =
    @Sendable (
      DescriptorQuarantineJournalSession,
      DescriptorQuarantineJournalTerminalOutcome,
      Bool
    ) -> DescriptorQuarantineJournalFinishResult
  typealias RecoveryOperation =
    @Sendable (
      DescriptorQuarantineJournalRecoveryRequest
    ) -> DescriptorQuarantineJournalRecoveryResult

  private enum Backend: Sendable {
    case production(DescriptorQuarantineJournalDependencies)
    case injected(BeginOperation, FinishOperation, RecoveryOperation)
  }

  private let backend: Backend

  init(
    dependencies: DescriptorQuarantineJournalDependencies =
      DescriptorQuarantineJournalDependencies()
  ) {
    backend = .production(dependencies)
  }

  init(
    begin: @escaping BeginOperation,
    finish: @escaping FinishOperation,
    recover: @escaping RecoveryOperation = { _ in
      .success(
        DescriptorQuarantineJournalRecoverySummary(
          recoveredReceipts: [],
          validatedTransactionCount: 0
        ))
    }
  ) {
    backend = .injected(begin, finish, recover)
  }

  func begin(
    _ request: DescriptorQuarantineJournalBeginRequest
  ) -> DescriptorQuarantineJournalBeginResult {
    switch backend {
    case .production(let dependencies):
      return beginProduction(request, dependencies: dependencies)
    case .injected(let operation, _, _):
      return operation(request)
    }
  }

  func finish(
    _ session: DescriptorQuarantineJournalSession,
    outcome: DescriptorQuarantineJournalTerminalOutcome,
    namespaceMutationMayHaveBeenInvoked: Bool
  ) -> DescriptorQuarantineJournalFinishResult {
    guard session.claimForFinish() else { return .invalidSession }
    defer { session.completeFinish() }

    switch backend {
    case .production(let dependencies):
      return finishProduction(
        session,
        outcome: outcome,
        namespaceMutationMayHaveBeenInvoked: namespaceMutationMayHaveBeenInvoked,
        dependencies: dependencies
      )
    case .injected(_, let operation, _):
      return operation(session, outcome, namespaceMutationMayHaveBeenInvoked)
    }
  }

  func recover(
    _ request: DescriptorQuarantineJournalRecoveryRequest
  ) -> DescriptorQuarantineJournalRecoveryResult {
    switch backend {
    case .production(let dependencies):
      return recoverProduction(request, dependencies: dependencies)
    case .injected(_, _, let operation):
      return operation(request)
    }
  }
}

extension DescriptorQuarantineJournal {
  fileprivate func beginProduction(
    _ request: DescriptorQuarantineJournalBeginRequest,
    dependencies: DescriptorQuarantineJournalDependencies
  ) -> DescriptorQuarantineJournalBeginResult {
    let intentBytes: Data
    do {
      intentBytes = try QuarantineJournalV1Codec.encode(request.intent)
    } catch {
      return .failure(.unsafe)
    }

    guard
      request.accountUID != 0,
      request.intent.transactionID
        == descriptorJournalTransactionID(
          from: request.intent.transactionID),
      request.intent.policy == .current,
      request.intent.npmRootBinding.ownerUID == UInt32(request.accountUID),
      request.intent.quarantineRootBinding.ownerUID == UInt32(request.accountUID),
      request.intent.candidateBinding.ownerUID == UInt32(request.accountUID)
    else {
      return .failure(.unsafe)
    }

    switch descriptorJournalValidateBeginBindings(
      request,
      requireExactParentLinkCounts: true,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure(let failure):
      return .failure(failure)
    }

    let lock: Result<Int32, DescriptorQuarantineJournalFailure> =
      descriptorJournalAcquireLock(
        quarantineRootDescriptor: request.quarantineRootDescriptor,
        expectedDevice: request.intent.quarantineRootBinding.device,
        accountUID: request.accountUID,
        dependencies: dependencies
      )
    let lockDescriptor: Int32
    switch lock {
    case .success(let descriptor):
      lockDescriptor = descriptor
    case .failure(let failure):
      return .failure(failure)
    }

    var sessionOwnsLock = false
    defer {
      if !sessionOwnsLock {
        dependencies.unlock(lockDescriptor)
        descriptorCloseIgnoringErrors(lockDescriptor)
      }
    }
    dependencies.hooks.didAcquireLock()

    let recoveryRequest = DescriptorQuarantineJournalRecoveryRequest(
      rootDescriptor: request.rootDescriptor,
      quarantineRootDescriptor: request.quarantineRootDescriptor,
      quarantineRootComponent: request.quarantineRootComponent,
      absoluteRootComponents: request.absoluteRootComponents,
      homeComponentCount: request.homeComponentCount,
      accountUID: request.accountUID
    )
    switch descriptorJournalRecoverLocked(
      recoveryRequest,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure(let failure):
      return .failure(failure)
    }

    switch descriptorJournalValidateNewIntentReservations(
      request.intent,
      request: recoveryRequest,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure(let failure):
      return .failure(failure)
    }

    switch descriptorJournalValidateBeginBindings(
      request,
      requireExactParentLinkCounts: false,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure(let failure):
      return .failure(failure)
    }

    guard
      descriptorJournalSyncPair(
        request.rootDescriptor,
        request.quarantineRootDescriptor,
        dependencies: dependencies
      )
    else {
      return .failure(.unavailable(.inputOutput))
    }

    let stageName = descriptorJournalRecordName(
      prefix: ".intent-stage-v1-",
      transactionID: request.intent.transactionID
    )
    let finalName = descriptorJournalRecordName(
      prefix: ".intent-v1-",
      transactionID: request.intent.transactionID
    )
    guard let stageName, let finalName else {
      return .failure(.unsafe)
    }
    switch descriptorJournalPublishNewRecord(
      bytes: intentBytes,
      stageName: stageName,
      finalName: finalName,
      quarantineRootDescriptor: request.quarantineRootDescriptor,
      expectedDevice: request.intent.quarantineRootBinding.device,
      accountUID: request.accountUID,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure(let failure):
      return .failure(failure)
    case .finalMayExist:
      return .failure(.recoveryRequired(transactionID: request.intent.transactionID))
    }

    let freshQuarantineRoot: DescriptorStatSnapshot
    do {
      freshQuarantineRoot = try DescriptorStatSnapshot.read(
        from: request.quarantineRootDescriptor,
        cancellationPolicy: .ignoreTaskCancellation
      )
    } catch {
      return .failure(.recoveryRequired(transactionID: request.intent.transactionID))
    }

    sessionOwnsLock = true
    let context = DescriptorQuarantineJournalSession.ProductionContext(
      rootDescriptor: request.rootDescriptor,
      quarantineRootDescriptor: request.quarantineRootDescriptor,
      quarantineRootComponent: request.quarantineRootComponent,
      absoluteRootComponents: request.absoluteRootComponents,
      homeComponentCount: request.homeComponentCount,
      accountUID: request.accountUID,
      canonicalIntentBytes: intentBytes
    )
    return .success(
      DescriptorQuarantineJournalSession(
        transactionID: request.intent.transactionID,
        intent: request.intent,
        canonicalIntentBytes: intentBytes,
        quarantineRootSnapshotAfterIntent: freshQuarantineRoot,
        lockDescriptor: lockDescriptor,
        unlock: dependencies.unlock,
        payload: .production(context)
      ))
  }

  fileprivate func finishProduction(
    _ session: DescriptorQuarantineJournalSession,
    outcome: DescriptorQuarantineJournalTerminalOutcome,
    namespaceMutationMayHaveBeenInvoked: Bool,
    dependencies: DescriptorQuarantineJournalDependencies
  ) -> DescriptorQuarantineJournalFinishResult {
    guard case .production(let context) = session.payload else {
      return .invalidSession
    }
    func recoveryResult() -> DescriptorQuarantineJournalFinishResult {
      descriptorJournalFinishFailureIsRecoveryAdmissible(
        session: session,
        context: context,
        dependencies: dependencies
      )
        ? .recoveryRequired(transactionID: session.transactionID)
        : .unresolved(transactionID: session.transactionID)
    }
    if namespaceMutationMayHaveBeenInvoked,
      !descriptorJournalSyncPair(
        context.rootDescriptor,
        context.quarantineRootDescriptor,
        dependencies: dependencies
      )
    {
      return recoveryResult()
    }
    if outcome == .unresolved {
      if namespaceMutationMayHaveBeenInvoked {
        switch descriptorJournalSynchronizePendingIntent(
          session: session,
          context: context,
          dependencies: dependencies
        ) {
        case .success:
          break
        case .failure:
          return recoveryResult()
        }
      }
      return recoveryResult()
    }

    let truthBeforeReceipt: DescriptorJournalNamespaceTruth
    switch descriptorJournalValidateTerminalOutcome(
      outcome,
      session: session,
      context: context,
      synchronizeParents: true,
      dependencies: dependencies
    ) {
    case .success(let truth):
      truthBeforeReceipt = truth
    case .failure:
      return recoveryResult()
    }

    let receipt: QuarantineJournalReceiptV1
    do {
      switch outcome {
      case .notMoved:
        receipt = try QuarantineJournalV1Codec.makeReceipt(
          outcome: .notMoved,
          producedByRecovery: false,
          canonicalIntentBytes: context.canonicalIntentBytes
        )
      case .quarantined(let ordinal, let sourceNameWasRecreated):
        receipt = try QuarantineJournalV1Codec.makeReceipt(
          outcome: .quarantined,
          selectedDestinationOrdinal: ordinal,
          sourceNameWasRecreated: sourceNameWasRecreated,
          producedByRecovery: false,
          canonicalIntentBytes: context.canonicalIntentBytes
        )
      case .rolledBack:
        receipt = try QuarantineJournalV1Codec.makeReceipt(
          outcome: .rolledBack,
          producedByRecovery: false,
          canonicalIntentBytes: context.canonicalIntentBytes
        )
      case .unresolved:
        return recoveryResult()
      }
    } catch {
      return recoveryResult()
    }

    let bytes: Data
    do {
      bytes = try QuarantineJournalV1Codec.encode(
        receipt,
        matchingIntentBytes: context.canonicalIntentBytes
      )
    } catch {
      return recoveryResult()
    }
    guard
      let stageName = descriptorJournalRecordName(
        prefix: ".receipt-stage-v1-",
        transactionID: session.transactionID
      ),
      let finalName = descriptorJournalRecordName(
        prefix: ".receipt-v1-",
        transactionID: session.transactionID
      )
    else {
      return recoveryResult()
    }
    switch descriptorJournalPublishNewRecord(
      bytes: bytes,
      stageName: stageName,
      finalName: finalName,
      quarantineRootDescriptor: context.quarantineRootDescriptor,
      expectedDevice: session.intent.quarantineRootBinding.device,
      accountUID: context.accountUID,
      dependencies: dependencies
    ) {
    case .success:
      switch descriptorJournalValidateTerminalOutcome(
        outcome,
        session: session,
        context: context,
        synchronizeParents: false,
        dependencies: dependencies
      ) {
      case .success(let truth) where truth == truthBeforeReceipt:
        return .receiptRecorded(receipt)
      case .success, .failure:
        return recoveryResult()
      }
    case .failure, .finalMayExist:
      return recoveryResult()
    }
  }

  fileprivate func recoverProduction(
    _ request: DescriptorQuarantineJournalRecoveryRequest,
    dependencies: DescriptorQuarantineJournalDependencies
  ) -> DescriptorQuarantineJournalRecoveryResult {
    guard request.accountUID != 0 else { return .failure(.unsafe) }
    switch descriptorJournalValidateRecoveryParentsBeforeLock(
      request,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure(let failure):
      return .failure(failure)
    }
    let quarantineSnapshot: DescriptorStatSnapshot
    do {
      quarantineSnapshot = try DescriptorStatSnapshot.read(
        from: request.quarantineRootDescriptor,
        cancellationPolicy: .ignoreTaskCancellation
      )
    } catch {
      return .failure(.unavailable(descriptorJournalFailure(for: error)))
    }

    let lock = descriptorJournalAcquireLock(
      quarantineRootDescriptor: request.quarantineRootDescriptor,
      expectedDevice: quarantineSnapshot.identity.device,
      accountUID: request.accountUID,
      dependencies: dependencies
    )
    let lockDescriptor: Int32
    switch lock {
    case .success(let descriptor):
      lockDescriptor = descriptor
    case .failure(let failure):
      return .failure(failure)
    }
    defer {
      dependencies.unlock(lockDescriptor)
      descriptorCloseIgnoringErrors(lockDescriptor)
    }
    dependencies.hooks.didAcquireLock()
    return descriptorJournalRecoverLocked(request, dependencies: dependencies)
  }
}

private func descriptorJournalTransactionID(from value: String) -> String? {
  let bytes = Array(value.utf8)
  guard bytes.count == 32,
    bytes.allSatisfy({
      (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
    })
  else {
    return nil
  }
  return value
}

func descriptorJournalRecordName(
  prefix: String,
  transactionID: String
) -> DescriptorPathComponent? {
  guard descriptorJournalTransactionID(from: transactionID) != nil else { return nil }
  return DescriptorPathComponent(Array((prefix + transactionID).utf8))
}

func descriptorJournalSync(
  _ descriptor: Int32,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Int32? {
  dependencies.hooks.willFullSync(descriptor)
  return dependencies.fullSync(descriptor)
}

func descriptorJournalSyncPair(
  _ firstDescriptor: Int32,
  _ secondDescriptor: Int32,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Bool {
  let firstFailure = descriptorJournalSync(firstDescriptor, dependencies: dependencies)
  let secondFailure = descriptorJournalSync(secondDescriptor, dependencies: dependencies)
  return firstFailure == nil && secondFailure == nil
}

private func descriptorJournalFullSync(_ descriptor: Int32) -> Int32? {
  for attempt in 0..<3 {
    if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return nil }
    let code = errno
    if code == EINTR, attempt + 1 < 3 { continue }
    return code
  }
  return EINTR
}

private func descriptorJournalWriteAll(_ descriptor: Int32, _ bytes: Data) -> Int32? {
  descriptorJournalWriteAll(descriptor, bytes) { descriptor, pointer, byteCount in
    Darwin.write(descriptor, pointer, byteCount)
  }
}

func descriptorJournalWriteAll(
  _ descriptor: Int32,
  _ bytes: Data,
  write: (Int32, UnsafeRawPointer, Int) -> Int
) -> Int32? {
  var offset = 0
  var interruptedAttempts = 0
  return bytes.withUnsafeBytes { buffer in
    while offset < buffer.count {
      let result = write(
        descriptor,
        buffer.baseAddress!.advanced(by: offset),
        buffer.count - offset
      )
      if result > 0 {
        offset += result
        interruptedAttempts = 0
        continue
      }
      if result == 0 { return EIO }
      let code = errno
      if code == EINTR, interruptedAttempts + 1 < 3 {
        interruptedAttempts += 1
        continue
      }
      return code
    }
    return nil
  }
}

private func descriptorJournalRenameExclusive(
  _ quarantineRootDescriptor: Int32,
  _ source: DescriptorPathComponent,
  _ destination: DescriptorPathComponent,
  _ flags: UInt32
) -> DescriptorExclusiveRenameResult {
  var failureCode = Int32(EINVAL)
  let result = source.withCString { sourcePointer in
    destination.withCString { destinationPointer in
      let status = Darwin.renameatx_np(
        quarantineRootDescriptor,
        sourcePointer,
        quarantineRootDescriptor,
        destinationPointer,
        flags
      )
      if status != 0 { failureCode = errno }
      return status
    }
  }
  return result == 0 ? .succeeded : .failed(failureCode)
}

private func descriptorJournalLockExclusiveNonBlocking(_ descriptor: Int32) -> Int32? {
  if descriptorJournalSystemFlock(descriptor, LOCK_EX | LOCK_NB) == 0 { return nil }
  return errno
}

private func descriptorJournalUnlock(_ descriptor: Int32) {
  _ = descriptorJournalSystemFlock(descriptor, LOCK_UN)
}

@_silgen_name("flock")
private func descriptorJournalSystemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

private func descriptorJournalHasExtendedACL(
  _ descriptor: Int32
) -> Result<Bool, DescriptorJournalPOSIXError> {
  do {
    return .success(try descriptorHasExtendedACL(descriptor))
  } catch DescriptorObservationError.posix(let code) {
    return .failure(DescriptorJournalPOSIXError(code: code))
  } catch {
    return .failure(DescriptorJournalPOSIXError(code: EIO))
  }
}

func descriptorJournalFailure(
  for error: Error
) -> CleanupQuarantineSystemFailure {
  if let observation = error as? DescriptorObservationError {
    switch observation {
    case .bindingChanged, .crossedVolume:
      return .pathChanged
    case .markerEntryLimitExceeded, .protectedDescendantLimitExceeded:
      return .resourceLimit
    case .posix(let code):
      return descriptorJournalFailure(for: code)
    }
  }
  let nsError = error as NSError
  if nsError.domain == NSPOSIXErrorDomain, let code = Int32(exactly: nsError.code) {
    return descriptorJournalFailure(for: code)
  }
  return .unspecified
}

func descriptorJournalFailure(
  for code: Int32
) -> CleanupQuarantineSystemFailure {
  switch code {
  case EACCES, EPERM:
    return .permissionDenied
  case ENOENT, ENOTDIR, ELOOP, ESTALE, EAGAIN:
    return .pathChanged
  case ENOTSUP, ENOSYS, EINVAL:
    return .unsupported
  case EXDEV:
    return .crossDevice
  case EROFS:
    return .readOnlyFileSystem
  case ENOSPC, EDQUOT:
    return .noSpace
  case EMFILE, ENFILE, ENOMEM:
    return .resourceLimit
  case EFAULT, EOVERFLOW, ENAMETOOLONG:
    return .invalidMetadata
  case EIO, EINTR:
    return .inputOutput
  case EEXIST:
    return .destinationExists
  default:
    return .unspecified
  }
}
