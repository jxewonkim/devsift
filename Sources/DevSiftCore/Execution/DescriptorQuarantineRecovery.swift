import Darwin
import Foundation

private let descriptorJournalMaximumEntryCount = 4_096
private let descriptorJournalMaximumEntryNameBytes = 4 * 1_024 * 1_024
private let descriptorJournalLockBytes = Array(".lock-v1".utf8)

enum DescriptorJournalPublicationResult {
  case success
  case failure(DescriptorQuarantineJournalFailure)
  case finalMayExist
}

private enum DescriptorJournalRecordKind {
  case intentStage
  case intent
  case receiptStage
  case receipt
  case restoreIntentStage
  case restoreIntent
  case restoreReceiptStage
  case restoreReceipt
  case item
}

private struct DescriptorJournalManagedName {
  let component: DescriptorPathComponent
  let kind: DescriptorJournalRecordKind
  let transactionID: String
}

private struct DescriptorJournalRecord<Value> {
  let component: DescriptorPathComponent
  let bytes: Data
  let value: Value
}

private struct DescriptorJournalInventory {
  var intentStages: [String: DescriptorJournalRecord<QuarantineJournalIntentV1>] = [:]
  var intents: [String: DescriptorJournalRecord<QuarantineJournalIntentV1>] = [:]
  var receiptStages: [String: DescriptorJournalRecord<QuarantineJournalReceiptV1>] = [:]
  var receipts: [String: DescriptorJournalRecord<QuarantineJournalReceiptV1>] = [:]
  var restoreIntentStages: [String: DescriptorJournalRecord<QuarantineRestoreJournalIntentV1>] =
    [:]
  var restoreIntents: [String: DescriptorJournalRecord<QuarantineRestoreJournalIntentV1>] = [:]
  var restoreReceiptStages: [String: DescriptorJournalRecord<QuarantineRestoreJournalReceiptV1>] =
    [:]
  var restoreReceipts: [String: DescriptorJournalRecord<QuarantineRestoreJournalReceiptV1>] = [:]
  var items: Set<[UInt8]> = []
  var entryCount = 0
  var rawNameByteCount = 0
}

struct DescriptorJournalStat: Equatable {
  let snapshot: DescriptorStatSnapshot
  let byteCount: Int64

  static func read(from descriptor: Int32) throws -> DescriptorJournalStat {
    var information = stat()
    try descriptorJournalRetryInterrupted {
      guard Darwin.fstat(descriptor, &information) == 0 else {
        throw DescriptorJournalPOSIXError(code: errno)
      }
    }
    return DescriptorJournalStat(information: information)
  }

  static func read(
    at parentDescriptor: Int32,
    component: DescriptorPathComponent
  ) throws -> DescriptorJournalStat {
    var information = stat()
    try descriptorJournalRetryInterrupted {
      try component.withCString { pointer in
        guard
          Darwin.fstatat(parentDescriptor, pointer, &information, AT_SYMLINK_NOFOLLOW) == 0
        else {
          throw DescriptorJournalPOSIXError(code: errno)
        }
      }
    }
    return DescriptorJournalStat(information: information)
  }

  init(information: stat) {
    snapshot = DescriptorStatSnapshot(information: information)
    byteCount = information.st_size
  }

  static func == (left: DescriptorJournalStat, right: DescriptorJournalStat) -> Bool {
    left.byteCount == right.byteCount
      && left.snapshot.sameBinding(as: right.snapshot)
      && left.snapshot.sameMutationState(as: right.snapshot)
      && left.snapshot.ownerUID == right.snapshot.ownerUID
      && left.snapshot.permissionMode == right.snapshot.permissionMode
      && left.snapshot.flags == right.snapshot.flags
      && left.snapshot.linkCount == right.snapshot.linkCount
  }
}

enum DescriptorJournalObservedName: Equatable {
  case missing
  case expected(DescriptorJournalStat)
  case other(DescriptorJournalStat)
}

struct DescriptorJournalNamespaceTruth: Equatable {
  let source: DescriptorJournalObservedName
  let destinations: [DescriptorJournalObservedName]
}

private struct DescriptorRestoreJournalNamespaceTruth: Equatable {
  let source: DescriptorJournalObservedName
  let quarantineItem: DescriptorJournalObservedName
}

func descriptorJournalValidateBeginBindings(
  _ request: DescriptorQuarantineJournalBeginRequest,
  requireExactParentLinkCounts: Bool = true,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  guard
    Darwin.getuid() == request.accountUID,
    Darwin.geteuid() == request.accountUID,
    request.accountUID != 0
  else {
    return .failure(.unsafe)
  }

  let parentRequest = DescriptorQuarantineJournalRecoveryRequest(
    rootDescriptor: request.rootDescriptor,
    quarantineRootDescriptor: request.quarantineRootDescriptor,
    quarantineRootComponent: request.quarantineRootComponent,
    absoluteRootComponents: request.absoluteRootComponents,
    homeComponentCount: request.homeComponentCount,
    accountUID: request.accountUID
  )
  switch descriptorJournalValidateParents(
    parentRequest,
    expectedRoot: request.intent.npmRootBinding,
    expectedQuarantineRoot: request.intent.quarantineRootBinding,
    includeExpectedLinkCounts: requireExactParentLinkCounts,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }

  do {
    let heldCandidate = try DescriptorJournalStat.read(from: request.candidateDescriptor)
    guard
      descriptorJournalMatches(
        heldCandidate.snapshot,
        expected: request.intent.candidateBinding,
        includeLinkCount: true
      ),
      heldCandidate.snapshot.kind == .directory,
      heldCandidate.snapshot.permissionMode & mode_t(0o022) == 0,
      heldCandidate.snapshot.flags == 0
    else {
      return .failure(.unsafe)
    }
    switch dependencies.hasExtendedACL(request.candidateDescriptor) {
    case .success(false):
      break
    case .success(true):
      return .failure(.unsafe)
    case .failure(let error):
      return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
    }

    guard request.intent.sourceComponents.count == 1,
      let source = DescriptorPathComponent(request.intent.sourceComponents[0])
    else {
      return .failure(.unsafe)
    }
    let namedCandidate = try DescriptorJournalStat.read(
      at: request.rootDescriptor,
      component: source
    )
    guard namedCandidate == heldCandidate else { return .failure(.unsafe) }
    return .success(())
  } catch let error as DescriptorJournalPOSIXError {
    return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
  } catch {
    return .failure(.unavailable(.unspecified))
  }
}

func descriptorJournalValidateRecoveryParentsBeforeLock(
  _ request: DescriptorQuarantineJournalRecoveryRequest,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  descriptorJournalValidateParents(
    request,
    expectedRoot: nil,
    expectedQuarantineRoot: nil,
    dependencies: dependencies
  )
}

func descriptorJournalAcquireLock(
  quarantineRootDescriptor: Int32,
  expectedDevice: UInt64,
  accountUID: uid_t,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Int32, DescriptorQuarantineJournalFailure> {
  guard let lockName = DescriptorPathComponent(descriptorJournalLockBytes) else {
    return .failure(.unsafe)
  }

  func openExistingLock() -> (descriptor: Int32, failure: Int32) {
    var failure = Int32(EINVAL)
    for attempt in 0..<3 {
      let descriptor = lockName.withCString { pointer in
        let result = Darwin.openat(
          quarantineRootDescriptor,
          pointer,
          O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_RESOLVE_BENEATH
        )
        if result < 0 { failure = errno }
        return result
      }
      if descriptor >= 0 { return (descriptor, failure) }
      if failure != EINTR || attempt + 1 == 3 { break }
    }
    return (-1, failure)
  }

  func createLock() -> (descriptor: Int32, failure: Int32) {
    var failure = Int32(EINVAL)
    for attempt in 0..<3 {
      let descriptor = lockName.withCString { pointer in
        let result = Darwin.openat(
          quarantineRootDescriptor,
          pointer,
          O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            | O_RESOLVE_BENEATH,
          mode_t(0o600)
        )
        if result < 0 { failure = errno }
        return result
      }
      if descriptor >= 0 { return (descriptor, failure) }
      if failure != EINTR || attempt + 1 == 3 { break }
    }
    return (-1, failure)
  }

  var existing = openExistingLock()
  var lockDescriptor = existing.descriptor
  var openFailure = existing.failure
  if lockDescriptor < 0, openFailure == ENOENT {
    let names: [DescriptorPathComponent]
    switch descriptorJournalEnumerateNames(quarantineRootDescriptor) {
    case .success(let result):
      names = result
    case .failure(let failure):
      return .failure(failure)
    }
    if names.contains(where: { $0.bytes == descriptorJournalLockBytes }) {
      existing = openExistingLock()
      lockDescriptor = existing.descriptor
      openFailure = existing.failure
    } else {
      guard names.isEmpty else { return .failure(.unsafe) }
      let creation = createLock()
      lockDescriptor = creation.descriptor
      openFailure = creation.failure
      if lockDescriptor < 0, openFailure == EEXIST {
        existing = openExistingLock()
        lockDescriptor = existing.descriptor
        openFailure = existing.failure
      }
    }
  }
  guard lockDescriptor >= 0 else {
    return .failure(.unavailable(descriptorJournalFailureCode(openFailure)))
  }

  var shouldClose = true
  defer {
    if shouldClose { descriptorCloseIgnoringErrors(lockDescriptor) }
  }
  switch descriptorJournalValidateRecordDescriptor(
    lockDescriptor,
    namedAt: quarantineRootDescriptor,
    component: lockName,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedByteCount: 0,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }

  if let code = dependencies.lockExclusiveNonBlocking(lockDescriptor) {
    if code == EWOULDBLOCK || code == EAGAIN {
      return .failure(.busy)
    }
    return .failure(.unavailable(descriptorJournalFailureCode(code)))
  }

  switch descriptorJournalValidateRecordDescriptor(
    lockDescriptor,
    namedAt: quarantineRootDescriptor,
    component: lockName,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedByteCount: 0,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    dependencies.unlock(lockDescriptor)
    return .failure(failure)
  }

  guard
    descriptorJournalSyncPair(
      lockDescriptor,
      quarantineRootDescriptor,
      dependencies: dependencies
    )
  else {
    dependencies.unlock(lockDescriptor)
    return .failure(.unavailable(.inputOutput))
  }

  shouldClose = false
  return .success(lockDescriptor)
}

func descriptorJournalPublishNewRecord(
  bytes: Data,
  stageName: DescriptorPathComponent,
  finalName: DescriptorPathComponent,
  quarantineRootDescriptor: Int32,
  expectedDevice: UInt64,
  accountUID: uid_t,
  dependencies: DescriptorQuarantineJournalDependencies
) -> DescriptorJournalPublicationResult {
  guard !bytes.isEmpty, bytes.count <= QuarantineJournalV1Codec.maximumEncodedByteCount else {
    return .failure(.unsafe)
  }

  var descriptor = Int32(-1)
  var failureCode = Int32(EINVAL)
  for attempt in 0..<3 {
    descriptor = stageName.withCString { pointer in
      let result = Darwin.openat(
        quarantineRootDescriptor,
        pointer,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH,
        mode_t(0o600)
      )
      if result < 0 { failureCode = errno }
      return result
    }
    if descriptor >= 0 { break }
    if failureCode == EINTR, attempt + 1 < 3 { continue }
    break
  }
  guard descriptor >= 0 else {
    return .failure(
      failureCode == EEXIST
        ? .unsafe
        : .unavailable(descriptorJournalFailureCode(failureCode))
    )
  }
  defer { descriptorCloseIgnoringErrors(descriptor) }
  dependencies.hooks.didCreateStage(stageName)

  if let code = dependencies.writeAll(descriptor, bytes) {
    return .failure(.unavailable(descriptorJournalFailureCode(code)))
  }
  switch descriptorJournalValidateRecordDescriptor(
    descriptor,
    namedAt: quarantineRootDescriptor,
    component: stageName,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedByteCount: bytes.count,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }
  guard descriptorJournalSync(descriptor, dependencies: dependencies) == nil else {
    return .failure(.unavailable(.inputOutput))
  }

  dependencies.hooks.willPublishStage(stageName, finalName)
  let renameResult = dependencies.renameExclusive(
    quarantineRootDescriptor,
    stageName,
    finalName,
    DescriptorExclusiveQuarantineMover.renameFlags
  )
  switch renameResult {
  case .succeeded:
    break
  case .failed(EINTR), .failed(EIO):
    return .finalMayExist
  case .failed(let code):
    return .failure(
      code == EEXIST ? .unsafe : .unavailable(descriptorJournalFailureCode(code))
    )
  }
  dependencies.hooks.didPublishFinal(finalName)

  guard descriptorJournalSync(quarantineRootDescriptor, dependencies: dependencies) == nil else {
    return .finalMayExist
  }
  switch descriptorJournalValidateRecordDescriptor(
    descriptor,
    namedAt: quarantineRootDescriptor,
    component: finalName,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedByteCount: bytes.count,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure:
    return .finalMayExist
  }
  guard descriptorJournalSync(descriptor, dependencies: dependencies) == nil else {
    return .finalMayExist
  }
  return .success
}

private func descriptorJournalValidateRecordDescriptor(
  _ descriptor: Int32,
  namedAt parentDescriptor: Int32,
  component: DescriptorPathComponent,
  expectedDevice: UInt64,
  accountUID: uid_t,
  expectedByteCount: Int,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  do {
    let held = try DescriptorJournalStat.read(from: descriptor)
    let named = try DescriptorJournalStat.read(at: parentDescriptor, component: component)
    guard
      held == named,
      held.snapshot.kind == .regularFile,
      held.snapshot.identity.device == expectedDevice,
      held.snapshot.ownerUID == accountUID,
      held.snapshot.permissionMode == mode_t(0o600),
      held.snapshot.flags == 0,
      held.snapshot.linkCount == 1,
      held.byteCount == Int64(expectedByteCount)
    else {
      return .failure(.unsafe)
    }
    switch dependencies.hasExtendedACL(descriptor) {
    case .success(false):
      return .success(())
    case .success(true):
      return .failure(.unsafe)
    case .failure(let error):
      return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
    }
  } catch let error as DescriptorJournalPOSIXError {
    return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
  } catch {
    return .failure(.unavailable(.unspecified))
  }
}

private func descriptorJournalValidateParents(
  _ request: DescriptorQuarantineJournalRecoveryRequest,
  expectedRoot: QuarantineJournalFileBindingV1?,
  expectedQuarantineRoot: QuarantineJournalFileBindingV1?,
  includeExpectedLinkCounts: Bool = false,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  guard
    request.accountUID != 0,
    Darwin.getuid() == request.accountUID,
    Darwin.geteuid() == request.accountUID
  else {
    return .failure(.unsafe)
  }

  do {
    let heldRoot = try DescriptorStatSnapshot.read(
      from: request.rootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    let namedRoot = try descriptorSnapshot(
      atAbsoluteComponents: request.absoluteRootComponents,
      homeComponentCount: request.homeComponentCount,
      cancellationPolicy: .ignoreTaskCancellation
    )
    guard
      heldRoot.sameBinding(as: namedRoot),
      heldRoot.sameMutationState(as: namedRoot),
      heldRoot.ownerUID == namedRoot.ownerUID,
      heldRoot.permissionMode == namedRoot.permissionMode,
      heldRoot.flags == namedRoot.flags,
      heldRoot.linkCount == namedRoot.linkCount,
      heldRoot.kind == .directory,
      heldRoot.ownerUID == request.accountUID,
      heldRoot.permissionMode & mode_t(0o022) == 0,
      heldRoot.flags == 0
    else {
      return .failure(.unsafe)
    }
    switch dependencies.hasExtendedACL(request.rootDescriptor) {
    case .success(false):
      break
    case .success(true):
      return .failure(.unsafe)
    case .failure(let error):
      return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
    }

    let heldQuarantineRoot = try DescriptorStatSnapshot.read(
      from: request.quarantineRootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    let namedQuarantineRoot = try DescriptorStatSnapshot.read(
      at: request.rootDescriptor,
      component: request.quarantineRootComponent,
      cancellationPolicy: .ignoreTaskCancellation
    )
    guard
      heldQuarantineRoot.sameBinding(as: namedQuarantineRoot),
      heldQuarantineRoot.sameMutationState(as: namedQuarantineRoot),
      heldQuarantineRoot.ownerUID == namedQuarantineRoot.ownerUID,
      heldQuarantineRoot.permissionMode == namedQuarantineRoot.permissionMode,
      heldQuarantineRoot.flags == namedQuarantineRoot.flags,
      heldQuarantineRoot.linkCount == namedQuarantineRoot.linkCount,
      heldQuarantineRoot.kind == .directory,
      heldQuarantineRoot.identity.device == heldRoot.identity.device,
      heldQuarantineRoot.ownerUID == request.accountUID,
      heldQuarantineRoot.permissionMode == mode_t(0o700),
      heldQuarantineRoot.flags == 0
    else {
      return .failure(.unsafe)
    }
    switch dependencies.hasExtendedACL(request.quarantineRootDescriptor) {
    case .success(false):
      break
    case .success(true):
      return .failure(.unsafe)
    case .failure(let error):
      return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
    }

    if let expectedRoot {
      guard
        descriptorJournalMatches(
          heldRoot,
          expected: expectedRoot,
          includeLinkCount: includeExpectedLinkCounts
        )
      else {
        return .failure(.unsafe)
      }
    }
    if let expectedQuarantineRoot {
      guard
        descriptorJournalMatches(
          heldQuarantineRoot,
          expected: expectedQuarantineRoot,
          includeLinkCount: includeExpectedLinkCounts
        )
      else {
        return .failure(.unsafe)
      }
    }
    return .success(())
  } catch {
    return .failure(.unavailable(descriptorJournalFailure(for: error)))
  }
}

private func descriptorJournalMatches(
  _ snapshot: DescriptorStatSnapshot,
  expected: QuarantineJournalFileBindingV1,
  includeLinkCount: Bool
) -> Bool {
  guard
    let birthSeconds = Int64(exactly: snapshot.birthSeconds),
    let birthNanoseconds = UInt32(exactly: snapshot.birthNanoseconds),
    let ownerUID = UInt32(exactly: snapshot.ownerUID),
    let permissionMode = UInt32(exactly: snapshot.permissionMode)
  else {
    return false
  }
  return snapshot.identity.device == expected.device
    && snapshot.identity.inode == expected.inode
    && snapshot.generation == expected.generation
    && birthSeconds == expected.birthSeconds
    && birthNanoseconds == expected.birthNanoseconds
    && snapshot.kind == expected.kind
    && ownerUID == expected.ownerUID
    && permissionMode == expected.permissionMode
    && snapshot.flags == expected.flags
    && (!includeLinkCount || snapshot.linkCount == expected.linkCount)
}

private func descriptorJournalMatchesHistoricalParent(
  _ snapshot: DescriptorStatSnapshot,
  expected: QuarantineJournalFileBindingV1
) -> Bool {
  guard
    let birthSeconds = Int64(exactly: snapshot.birthSeconds),
    let birthNanoseconds = UInt32(exactly: snapshot.birthNanoseconds),
    let ownerUID = UInt32(exactly: snapshot.ownerUID)
  else {
    return false
  }
  return snapshot.identity.device == expected.device
    && snapshot.identity.inode == expected.inode
    && snapshot.generation == expected.generation
    && birthSeconds == expected.birthSeconds
    && birthNanoseconds == expected.birthNanoseconds
    && snapshot.kind == expected.kind
    && ownerUID == expected.ownerUID
}

private func descriptorJournalValidateHistoricalReceiptParents(
  _ request: DescriptorQuarantineJournalRecoveryRequest,
  expectedRoot: QuarantineJournalFileBindingV1,
  expectedQuarantineRoot: QuarantineJournalFileBindingV1,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  switch descriptorJournalValidateParents(
    request,
    expectedRoot: nil,
    expectedQuarantineRoot: nil,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }

  do {
    let root = try DescriptorStatSnapshot.read(
      from: request.rootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    let quarantineRoot = try DescriptorStatSnapshot.read(
      from: request.quarantineRootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    guard
      descriptorJournalMatchesHistoricalParent(root, expected: expectedRoot),
      descriptorJournalMatchesHistoricalParent(
        quarantineRoot,
        expected: expectedQuarantineRoot
      )
    else {
      return .failure(.unsafe)
    }
    return .success(())
  } catch {
    return .failure(.unavailable(descriptorJournalFailure(for: error)))
  }
}

private func descriptorJournalValidatedInventoryRoot(
  _ request: DescriptorQuarantineJournalRecoveryRequest,
  expectedDevice: UInt64,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<DescriptorJournalStat, DescriptorQuarantineJournalFailure> {
  do {
    let held = try DescriptorJournalStat.read(from: request.quarantineRootDescriptor)
    let named = try DescriptorJournalStat.read(
      at: request.rootDescriptor,
      component: request.quarantineRootComponent
    )
    guard
      held == named,
      held.snapshot.kind == .directory,
      held.snapshot.identity.device == expectedDevice,
      held.snapshot.ownerUID == request.accountUID,
      held.snapshot.permissionMode == mode_t(0o700),
      held.snapshot.flags == 0
    else {
      return .failure(.unsafe)
    }
    switch dependencies.hasExtendedACL(request.quarantineRootDescriptor) {
    case .success(false):
      return .success(held)
    case .success(true):
      return .failure(.unsafe)
    case .failure(let error):
      return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
    }
  } catch {
    return .failure(.unavailable(descriptorJournalFailure(for: error)))
  }
}

private func descriptorJournalReadInventory(
  _ request: DescriptorQuarantineJournalRecoveryRequest,
  expectedDevice: UInt64,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<DescriptorJournalInventory, DescriptorQuarantineJournalFailure> {
  dependencies.hooks.willReadInventory()
  let rootBefore: DescriptorJournalStat
  switch descriptorJournalValidatedInventoryRoot(
    request,
    expectedDevice: expectedDevice,
    dependencies: dependencies
  ) {
  case .success(let result):
    rootBefore = result
  case .failure(let failure):
    return .failure(failure)
  }

  let names: [DescriptorPathComponent]
  switch descriptorJournalEnumerateNames(request.quarantineRootDescriptor) {
  case .success(let result):
    names = result
  case .failure(let failure):
    return .failure(failure)
  }
  dependencies.hooks.didEnumerateInventory()

  var inventory = DescriptorJournalInventory()
  inventory.entryCount = names.count
  inventory.rawNameByteCount = names.reduce(into: 0) { count, component in
    count += component.bytes.count
  }
  for component in names {
    if component.bytes == descriptorJournalLockBytes { continue }
    guard let managedName = descriptorJournalParseManagedName(component) else {
      return .failure(.unsafe)
    }

    switch managedName.kind {
    case .item:
      guard inventory.items.insert(component.bytes).inserted else {
        return .failure(.unsafe)
      }
    case .intentStage, .intent:
      let bytes: Data
      switch descriptorJournalReadRecord(
        quarantineRootDescriptor: request.quarantineRootDescriptor,
        component: component,
        expectedDevice: expectedDevice,
        accountUID: request.accountUID,
        dependencies: dependencies
      ) {
      case .success(let result):
        bytes = result
      case .failure(let failure):
        return .failure(failure)
      }
      let intent: QuarantineJournalIntentV1
      do {
        intent = try QuarantineJournalV1Codec.decodeIntent(bytes)
      } catch {
        return .failure(.unsafe)
      }
      guard intent.transactionID == managedName.transactionID else {
        return .failure(.unsafe)
      }
      let record = DescriptorJournalRecord(
        component: component,
        bytes: bytes,
        value: intent
      )
      switch managedName.kind {
      case .intentStage:
        guard inventory.intentStages.updateValue(record, forKey: managedName.transactionID) == nil
        else {
          return .failure(.unsafe)
        }
      case .intent:
        guard inventory.intents.updateValue(record, forKey: managedName.transactionID) == nil else {
          return .failure(.unsafe)
        }
      case .receiptStage, .receipt, .restoreIntentStage, .restoreIntent,
        .restoreReceiptStage, .restoreReceipt, .item:
        return .failure(.unsafe)
      }
    case .receiptStage, .receipt:
      let bytes: Data
      switch descriptorJournalReadRecord(
        quarantineRootDescriptor: request.quarantineRootDescriptor,
        component: component,
        expectedDevice: expectedDevice,
        accountUID: request.accountUID,
        dependencies: dependencies
      ) {
      case .success(let result):
        bytes = result
      case .failure(let failure):
        return .failure(failure)
      }
      let receipt: QuarantineJournalReceiptV1
      do {
        receipt = try QuarantineJournalV1Codec.decodeReceipt(bytes)
      } catch {
        return .failure(.unsafe)
      }
      guard receipt.transactionID == managedName.transactionID else {
        return .failure(.unsafe)
      }
      let record = DescriptorJournalRecord(
        component: component,
        bytes: bytes,
        value: receipt
      )
      switch managedName.kind {
      case .receiptStage:
        guard inventory.receiptStages.updateValue(record, forKey: managedName.transactionID) == nil
        else {
          return .failure(.unsafe)
        }
      case .receipt:
        guard inventory.receipts.updateValue(record, forKey: managedName.transactionID) == nil
        else {
          return .failure(.unsafe)
        }
      case .intentStage, .intent, .restoreIntentStage, .restoreIntent,
        .restoreReceiptStage, .restoreReceipt, .item:
        return .failure(.unsafe)
      }
    case .restoreIntentStage, .restoreIntent:
      let bytes: Data
      switch descriptorJournalReadRecord(
        quarantineRootDescriptor: request.quarantineRootDescriptor,
        component: component,
        expectedDevice: expectedDevice,
        accountUID: request.accountUID,
        dependencies: dependencies
      ) {
      case .success(let result):
        bytes = result
      case .failure(let failure):
        return .failure(failure)
      }
      let intent: QuarantineRestoreJournalIntentV1
      do {
        intent = try QuarantineRestoreJournalV1Codec.decodeIntent(bytes)
      } catch {
        return .failure(.unsafe)
      }
      guard intent.restoreTransactionID == managedName.transactionID else {
        return .failure(.unsafe)
      }
      let record = DescriptorJournalRecord(
        component: component,
        bytes: bytes,
        value: intent
      )
      switch managedName.kind {
      case .restoreIntentStage:
        guard
          inventory.restoreIntentStages.updateValue(
            record,
            forKey: managedName.transactionID
          ) == nil
        else {
          return .failure(.unsafe)
        }
      case .restoreIntent:
        guard
          inventory.restoreIntents.updateValue(record, forKey: managedName.transactionID) == nil
        else {
          return .failure(.unsafe)
        }
      case .intentStage, .intent, .receiptStage, .receipt, .restoreReceiptStage,
        .restoreReceipt, .item:
        return .failure(.unsafe)
      }
    case .restoreReceiptStage, .restoreReceipt:
      let bytes: Data
      switch descriptorJournalReadRecord(
        quarantineRootDescriptor: request.quarantineRootDescriptor,
        component: component,
        expectedDevice: expectedDevice,
        accountUID: request.accountUID,
        dependencies: dependencies
      ) {
      case .success(let result):
        bytes = result
      case .failure(let failure):
        return .failure(failure)
      }
      let receipt: QuarantineRestoreJournalReceiptV1
      do {
        receipt = try QuarantineRestoreJournalV1Codec.decodeReceipt(bytes)
      } catch {
        return .failure(.unsafe)
      }
      guard receipt.restoreTransactionID == managedName.transactionID else {
        return .failure(.unsafe)
      }
      let record = DescriptorJournalRecord(
        component: component,
        bytes: bytes,
        value: receipt
      )
      switch managedName.kind {
      case .restoreReceiptStage:
        guard
          inventory.restoreReceiptStages.updateValue(
            record,
            forKey: managedName.transactionID
          ) == nil
        else {
          return .failure(.unsafe)
        }
      case .restoreReceipt:
        guard
          inventory.restoreReceipts.updateValue(record, forKey: managedName.transactionID) == nil
        else {
          return .failure(.unsafe)
        }
      case .intentStage, .intent, .receiptStage, .receipt, .restoreIntentStage,
        .restoreIntent, .item:
        return .failure(.unsafe)
      }
    }
  }
  switch descriptorJournalValidatedInventoryRoot(
    request,
    expectedDevice: expectedDevice,
    dependencies: dependencies
  ) {
  case .success(let rootAfter) where rootAfter == rootBefore:
    return .success(inventory)
  case .success:
    return .failure(.unsafe)
  case .failure(let failure):
    return .failure(failure)
  }
}

private func descriptorJournalInventory(
  _ inventory: DescriptorJournalInventory,
  canAddEntries additionalEntryCount: Int,
  peakAdditionalNameBytes: Int
) -> Bool {
  guard additionalEntryCount >= 0,
    peakAdditionalNameBytes >= 0,
    additionalEntryCount <= descriptorJournalMaximumEntryCount,
    peakAdditionalNameBytes <= descriptorJournalMaximumEntryNameBytes,
    inventory.entryCount <= descriptorJournalMaximumEntryCount - additionalEntryCount,
    inventory.rawNameByteCount
      <= descriptorJournalMaximumEntryNameBytes - peakAdditionalNameBytes
  else {
    return false
  }
  return true
}

private func descriptorJournalValidateInventoryStructure(
  _ inventory: DescriptorJournalInventory,
  maximumPendingIntentCount: Int
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  for transactionID in inventory.intentStages.keys
  where inventory.intents[transactionID] != nil {
    return .failure(.unsafe)
  }
  for transactionID in inventory.receiptStages.keys {
    guard let intentRecord = inventory.intents[transactionID],
      inventory.receipts[transactionID] == nil,
      let receiptRecord = inventory.receiptStages[transactionID],
      (try? QuarantineJournalV1Codec.decodeReceipt(
        receiptRecord.bytes,
        matchingIntentBytes: intentRecord.bytes
      )) != nil
    else {
      return .failure(.unsafe)
    }
  }
  for transactionID in inventory.receipts.keys {
    guard let intentRecord = inventory.intents[transactionID],
      let receiptRecord = inventory.receipts[transactionID],
      (try? QuarantineJournalV1Codec.decodeReceipt(
        receiptRecord.bytes,
        matchingIntentBytes: intentRecord.bytes
      )) != nil
    else {
      return .failure(.unsafe)
    }
  }

  for restoreTransactionID in inventory.restoreIntentStages.keys
  where inventory.restoreIntents[restoreTransactionID] != nil {
    return .failure(.unsafe)
  }
  for record in inventory.restoreIntentStages.values {
    guard descriptorJournalRestoreIntentMatchesQuarantinePair(record, inventory: inventory) else {
      return .failure(.unsafe)
    }
  }
  for record in inventory.restoreIntents.values {
    guard descriptorJournalRestoreIntentMatchesQuarantinePair(record, inventory: inventory) else {
      return .failure(.unsafe)
    }
  }
  for restoreTransactionID in inventory.restoreReceiptStages.keys {
    guard let intentRecord = inventory.restoreIntents[restoreTransactionID],
      inventory.restoreReceipts[restoreTransactionID] == nil,
      let receiptRecord = inventory.restoreReceiptStages[restoreTransactionID],
      (try? QuarantineRestoreJournalV1Codec.decodeReceipt(
        receiptRecord.bytes,
        matchingIntentBytes: intentRecord.bytes
      )) != nil
    else {
      return .failure(.unsafe)
    }
  }
  for restoreTransactionID in inventory.restoreReceipts.keys {
    guard let intentRecord = inventory.restoreIntents[restoreTransactionID],
      let receiptRecord = inventory.restoreReceipts[restoreTransactionID],
      (try? QuarantineRestoreJournalV1Codec.decodeReceipt(
        receiptRecord.bytes,
        matchingIntentBytes: intentRecord.bytes
      )) != nil
    else {
      return .failure(.unsafe)
    }
  }

  var pendingIntentCount = inventory.intents.keys.reduce(into: 0) { count, transactionID in
    if inventory.receipts[transactionID] == nil {
      count += 1
    }
  }
  pendingIntentCount = inventory.restoreIntents.keys.reduce(into: pendingIntentCount) {
    count,
    restoreTransactionID in
    if inventory.restoreReceipts[restoreTransactionID] == nil {
      count += 1
    }
  }
  guard pendingIntentCount <= maximumPendingIntentCount else {
    return .failure(.unsafe)
  }

  var restoredQuarantineTransactions = Set<String>()
  for (restoreTransactionID, receiptRecord) in inventory.restoreReceipts
  where receiptRecord.value.outcome == .restored {
    guard let restoreIntent = inventory.restoreIntents[restoreTransactionID]?.value,
      restoredQuarantineTransactions.insert(restoreIntent.quarantineTransactionID).inserted
    else {
      return .failure(.unsafe)
    }
  }
  for (restoreTransactionID, intentRecord) in inventory.restoreIntents
  where inventory.restoreReceipts[restoreTransactionID] == nil {
    guard !restoredQuarantineTransactions.contains(intentRecord.value.quarantineTransactionID)
    else {
      return .failure(.unsafe)
    }
  }

  var plannedDestinations = Set<[UInt8]>()
  for record in inventory.intents.values {
    for destination in record.value.destinationComponents {
      guard plannedDestinations.insert(destination).inserted else {
        return .failure(.unsafe)
      }
    }
  }
  guard inventory.items.isSubset(of: plannedDestinations) else {
    return .failure(.unsafe)
  }
  return .success(())
}

private func descriptorJournalRestoreIntentMatchesQuarantinePair(
  _ restoreRecord: DescriptorJournalRecord<QuarantineRestoreJournalIntentV1>,
  inventory: DescriptorJournalInventory
) -> Bool {
  let restoreIntent = restoreRecord.value
  guard
    let quarantineIntent = inventory.intents[restoreIntent.quarantineTransactionID],
    let quarantineReceipt = inventory.receipts[restoreIntent.quarantineTransactionID]
  else {
    return false
  }
  do {
    let decoded = try QuarantineRestoreJournalV1Codec.decodeIntent(
      restoreRecord.bytes,
      matchingQuarantineIntentBytes: quarantineIntent.bytes,
      matchingQuarantineReceiptBytes: quarantineReceipt.bytes
    )
    return decoded == restoreIntent
  } catch {
    return false
  }
}

func descriptorJournalValidateNewIntentReservations(
  _ newIntent: QuarantineJournalIntentV1,
  request: DescriptorQuarantineJournalRecoveryRequest,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  let quarantineSnapshot: DescriptorStatSnapshot
  do {
    quarantineSnapshot = try DescriptorStatSnapshot.read(
      from: request.quarantineRootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
  } catch {
    return .failure(.unavailable(descriptorJournalFailure(for: error)))
  }
  let inventory: DescriptorJournalInventory
  switch descriptorJournalReadInventory(
    request,
    expectedDevice: quarantineSnapshot.identity.device,
    dependencies: dependencies
  ) {
  case .success(let result):
    inventory = result
  case .failure(let failure):
    return .failure(failure)
  }
  switch descriptorJournalValidateInventoryStructure(
    inventory,
    maximumPendingIntentCount: 0
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }
  for transactionID in inventory.receipts.keys {
    guard let intentRecord = inventory.intents[transactionID] else {
      return .failure(.unsafe)
    }
    switch descriptorJournalValidateHistoricalReceiptParents(
      request,
      expectedRoot: intentRecord.value.npmRootBinding,
      expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure(let failure):
      return .failure(failure)
    }
  }
  let transactionID = newIntent.transactionID
  guard inventory.intentStages[transactionID] == nil,
    inventory.intents[transactionID] == nil,
    inventory.receiptStages[transactionID] == nil,
    inventory.receipts[transactionID] == nil
  else {
    return .failure(.unsafe)
  }
  guard
    let intentStageName = descriptorJournalRecordName(
      prefix: ".intent-stage-v1-",
      transactionID: transactionID
    ),
    let finalIntentName = descriptorJournalRecordName(
      prefix: ".intent-v1-",
      transactionID: transactionID
    ),
    let receiptStageName = descriptorJournalRecordName(
      prefix: ".receipt-stage-v1-",
      transactionID: transactionID
    ),
    let maximumDestinationNameByteCount = newIntent.destinationComponents.map(\.count).max()
  else {
    return .failure(.unsafe)
  }
  let intentPublicationNameBytes = intentStageName.bytes.count
  let terminalPublicationNameBytes =
    finalIntentName.bytes.count
    + maximumDestinationNameByteCount
    + receiptStageName.bytes.count
  guard
    descriptorJournalInventory(
      inventory,
      canAddEntries: 3,
      peakAdditionalNameBytes: max(
        intentPublicationNameBytes,
        terminalPublicationNameBytes
      )
    )
  else {
    return .failure(.unavailable(.resourceLimit))
  }

  var reserved = Set<[UInt8]>()
  for intent in inventory.intents.values {
    reserved.formUnion(intent.value.destinationComponents)
  }
  guard newIntent.destinationComponents.allSatisfy({ !reserved.contains($0) }) else {
    return .failure(.unsafe)
  }
  return .success(())
}

private func descriptorJournalEnumerateNames(
  _ quarantineRootDescriptor: Int32
) -> Result<[DescriptorPathComponent], DescriptorQuarantineJournalFailure> {
  let enumerationDescriptor: Int32
  do {
    enumerationDescriptor = try descriptorOpenCurrentDirectory(
      quarantineRootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
  } catch {
    return .failure(.unavailable(descriptorJournalFailure(for: error)))
  }
  guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
    let code = errno
    descriptorCloseIgnoringErrors(enumerationDescriptor)
    return .failure(.unavailable(descriptorJournalFailureCode(code)))
  }
  defer { _ = Darwin.closedir(stream) }

  var names: [DescriptorPathComponent] = []
  var rawNameBytes = 0
  while true {
    errno = 0
    guard let entry = Darwin.readdir(stream) else {
      let code = errno
      if code != 0 { return .failure(.unavailable(descriptorJournalFailureCode(code))) }
      break
    }
    let bytes = descriptorRawName(from: entry)
    if bytes == [0x2E] || bytes == [0x2E, 0x2E] { continue }
    guard let component = DescriptorPathComponent(bytes) else {
      return .failure(.unsafe)
    }
    names.append(component)
    rawNameBytes += bytes.count
    guard names.count <= descriptorJournalMaximumEntryCount,
      rawNameBytes <= descriptorJournalMaximumEntryNameBytes
    else {
      return .failure(.unavailable(.resourceLimit))
    }
  }
  return .success(names)
}

private func descriptorJournalParseManagedName(
  _ component: DescriptorPathComponent
) -> DescriptorJournalManagedName? {
  let prefixes: [(String, DescriptorJournalRecordKind)] = [
    (".intent-stage-v1-", .intentStage),
    (".intent-v1-", .intent),
    (".receipt-stage-v1-", .receiptStage),
    (".receipt-v1-", .receipt),
    (".restore-intent-stage-v1-", .restoreIntentStage),
    (".restore-intent-v1-", .restoreIntent),
    (".restore-receipt-stage-v1-", .restoreReceiptStage),
    (".restore-receipt-v1-", .restoreReceipt),
    ("item-v1-", .item),
  ]
  for (prefix, kind) in prefixes {
    let prefixBytes = Array(prefix.utf8)
    guard component.bytes.starts(with: prefixBytes) else { continue }
    let suffix = Array(component.bytes.dropFirst(prefixBytes.count))
    guard suffix.count == 32,
      suffix.allSatisfy({
        (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
      }),
      let transactionID = String(bytes: suffix, encoding: .utf8)
    else {
      return nil
    }
    return DescriptorJournalManagedName(
      component: component,
      kind: kind,
      transactionID: transactionID
    )
  }
  return nil
}

private func descriptorJournalReadRecord(
  quarantineRootDescriptor: Int32,
  component: DescriptorPathComponent,
  expectedDevice: UInt64,
  accountUID: uid_t,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Data, DescriptorQuarantineJournalFailure> {
  var descriptor = Int32(-1)
  var failureCode = Int32(EINVAL)
  for attempt in 0..<3 {
    descriptor = component.withCString { pointer in
      let result = Darwin.openat(
        quarantineRootDescriptor,
        pointer,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_RESOLVE_BENEATH
      )
      if result < 0 { failureCode = errno }
      return result
    }
    if descriptor >= 0 { break }
    if failureCode == EINTR, attempt + 1 < 3 { continue }
    break
  }
  guard descriptor >= 0 else {
    return .failure(.unavailable(descriptorJournalFailureCode(failureCode)))
  }
  defer { descriptorCloseIgnoringErrors(descriptor) }

  let before: DescriptorJournalStat
  do {
    before = try DescriptorJournalStat.read(from: descriptor)
  } catch let error as DescriptorJournalPOSIXError {
    return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
  } catch {
    return .failure(.unavailable(.unspecified))
  }
  guard before.byteCount > 0,
    before.byteCount <= Int64(QuarantineJournalV1Codec.maximumEncodedByteCount),
    let byteCount = Int(exactly: before.byteCount)
  else {
    return .failure(.unsafe)
  }
  switch descriptorJournalValidateRecordDescriptor(
    descriptor,
    namedAt: quarantineRootDescriptor,
    component: component,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedByteCount: byteCount,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }

  var bytes = Data(count: byteCount)
  var offset = 0
  var interruptedAttempts = 0
  let readFailure: Int32? = bytes.withUnsafeMutableBytes { buffer in
    while offset < buffer.count {
      let result = Darwin.read(
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
  if let readFailure {
    return .failure(.unavailable(descriptorJournalFailureCode(readFailure)))
  }

  do {
    let after = try DescriptorJournalStat.read(from: descriptor)
    guard before == after else { return .failure(.unsafe) }
  } catch let error as DescriptorJournalPOSIXError {
    return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
  } catch {
    return .failure(.unavailable(.unspecified))
  }
  switch descriptorJournalValidateRecordDescriptor(
    descriptor,
    namedAt: quarantineRootDescriptor,
    component: component,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedByteCount: byteCount,
    dependencies: dependencies
  ) {
  case .success:
    return .success(bytes)
  case .failure(let failure):
    return .failure(failure)
  }
}

func descriptorJournalFinishFailureIsRecoveryAdmissible(
  session: DescriptorQuarantineJournalSession,
  context: DescriptorQuarantineJournalSession.ProductionContext,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Bool {
  let request = DescriptorQuarantineJournalRecoveryRequest(
    rootDescriptor: context.rootDescriptor,
    quarantineRootDescriptor: context.quarantineRootDescriptor,
    quarantineRootComponent: context.quarantineRootComponent,
    absoluteRootComponents: context.absoluteRootComponents,
    homeComponentCount: context.homeComponentCount,
    accountUID: context.accountUID
  )
  guard
    case .success = descriptorJournalValidateParents(
      request,
      expectedRoot: session.intent.npmRootBinding,
      expectedQuarantineRoot: session.intent.quarantineRootBinding,
      dependencies: dependencies
    )
  else {
    return false
  }

  let inventory: DescriptorJournalInventory
  switch descriptorJournalReadInventory(
    request,
    expectedDevice: session.intent.quarantineRootBinding.device,
    dependencies: dependencies
  ) {
  case .success(let value):
    inventory = value
  case .failure:
    return false
  }
  guard
    inventory.intentStages[session.transactionID] == nil,
    let sessionIntent = inventory.intents[session.transactionID],
    sessionIntent.bytes == context.canonicalIntentBytes,
    sessionIntent.value == session.intent
  else {
    return false
  }

  guard
    case .success = descriptorJournalValidateInventoryStructure(
      inventory,
      maximumPendingIntentCount: 1
    )
  else {
    return false
  }
  let pendingTransactionIDs = inventory.intents.keys.filter {
    inventory.receipts[$0] == nil
  }

  for transactionID in inventory.receipts.keys {
    guard let intentRecord = inventory.intents[transactionID],
      case .success = descriptorJournalValidateHistoricalReceiptParents(
        request,
        expectedRoot: intentRecord.value.npmRootBinding,
        expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
        dependencies: dependencies
      )
    else {
      return false
    }
  }

  for transactionID in pendingTransactionIDs {
    guard let intentRecord = inventory.intents[transactionID],
      case .success = descriptorJournalValidateParents(
        request,
        expectedRoot: intentRecord.value.npmRootBinding,
        expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
        dependencies: dependencies
      )
    else {
      return false
    }
  }
  return true
}

func descriptorJournalRecoverLocked(
  _ request: DescriptorQuarantineJournalRecoveryRequest,
  dependencies: DescriptorQuarantineJournalDependencies
) -> DescriptorQuarantineJournalRecoveryResult {
  switch descriptorJournalValidateParents(
    request,
    expectedRoot: nil,
    expectedQuarantineRoot: nil,
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

  var inventory: DescriptorJournalInventory
  switch descriptorJournalReadInventory(
    request,
    expectedDevice: quarantineSnapshot.identity.device,
    dependencies: dependencies
  ) {
  case .success(let result):
    inventory = result
  case .failure(let failure):
    return .failure(failure)
  }

  switch descriptorJournalValidateInventoryStructure(
    inventory,
    maximumPendingIntentCount: 1
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }

  for transactionID in inventory.intents.keys.sorted() {
    guard let intentRecord = inventory.intents[transactionID] else {
      return .failure(.unsafe)
    }
    switch descriptorJournalStabilizeFinalRecord(
      intentRecord,
      quarantineRootDescriptor: request.quarantineRootDescriptor,
      expectedDevice: intentRecord.value.quarantineRootBinding.device,
      accountUID: request.accountUID,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure:
      return .failure(.recoveryRequired(transactionID: transactionID))
    }
  }

  for (transactionID, receiptRecord) in inventory.receipts {
    guard let intentRecord = inventory.intents[transactionID] else {
      return .failure(.unsafe)
    }
    do {
      _ = try QuarantineJournalV1Codec.decodeReceipt(
        receiptRecord.bytes,
        matchingIntentBytes: intentRecord.bytes
      )
    } catch {
      return .failure(.unsafe)
    }
    switch descriptorJournalValidateHistoricalReceiptParents(
      request,
      expectedRoot: intentRecord.value.npmRootBinding,
      expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure(let failure):
      return .failure(failure)
    }
    switch descriptorJournalStabilizeFinalRecord(
      receiptRecord,
      quarantineRootDescriptor: request.quarantineRootDescriptor,
      expectedDevice: intentRecord.value.quarantineRootBinding.device,
      accountUID: request.accountUID,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure:
      return .failure(.recoveryRequired(transactionID: transactionID))
    }
  }

  for restoreTransactionID in inventory.restoreIntents.keys.sorted() {
    guard let restoreIntentRecord = inventory.restoreIntents[restoreTransactionID] else {
      return .failure(.unsafe)
    }
    switch descriptorJournalValidateHistoricalReceiptParents(
      request,
      expectedRoot: restoreIntentRecord.value.npmRootBinding,
      expectedQuarantineRoot: restoreIntentRecord.value.quarantineRootBinding,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure(let failure):
      return .failure(failure)
    }
    switch descriptorJournalStabilizeFinalRecord(
      restoreIntentRecord,
      quarantineRootDescriptor: request.quarantineRootDescriptor,
      expectedDevice: restoreIntentRecord.value.quarantineRootBinding.device,
      accountUID: request.accountUID,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure:
      return .failure(.recoveryRequired(transactionID: restoreTransactionID))
    }
  }

  for (restoreTransactionID, restoreReceiptRecord) in inventory.restoreReceipts {
    guard let restoreIntentRecord = inventory.restoreIntents[restoreTransactionID] else {
      return .failure(.unsafe)
    }
    do {
      _ = try QuarantineRestoreJournalV1Codec.decodeReceipt(
        restoreReceiptRecord.bytes,
        matchingIntentBytes: restoreIntentRecord.bytes
      )
    } catch {
      return .failure(.unsafe)
    }
    switch descriptorJournalStabilizeFinalRecord(
      restoreReceiptRecord,
      quarantineRootDescriptor: request.quarantineRootDescriptor,
      expectedDevice: restoreIntentRecord.value.quarantineRootBinding.device,
      accountUID: request.accountUID,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure:
      return .failure(.recoveryRequired(transactionID: restoreTransactionID))
    }
  }

  var recoveredReceipts: [QuarantineJournalReceiptV1] = []
  for transactionID in inventory.receiptStages.keys.sorted() {
    guard let stage = inventory.receiptStages[transactionID],
      let intent = inventory.intents[transactionID]
    else {
      return .failure(.unsafe)
    }
    do {
      _ = try QuarantineJournalV1Codec.decodeReceipt(
        stage.bytes,
        matchingIntentBytes: intent.bytes
      )
    } catch {
      return .failure(.unsafe)
    }
    switch descriptorJournalCompleteStagedReceipt(
      stage,
      intentRecord: intent,
      request: request,
      dependencies: dependencies
    ) {
    case .success:
      inventory.receipts[transactionID] = stage
      recoveredReceipts.append(stage.value)
    case .failure(let failure):
      return .failure(failure)
    }
  }

  var recoveredRestoreReceipts: [QuarantineRestoreJournalReceiptV1] = []
  for restoreTransactionID in inventory.restoreReceiptStages.keys.sorted() {
    guard let stage = inventory.restoreReceiptStages[restoreTransactionID],
      let intent = inventory.restoreIntents[restoreTransactionID]
    else {
      return .failure(.unsafe)
    }
    do {
      _ = try QuarantineRestoreJournalV1Codec.decodeReceipt(
        stage.bytes,
        matchingIntentBytes: intent.bytes
      )
    } catch {
      return .failure(.unsafe)
    }
    switch descriptorJournalCompleteStagedRestoreReceipt(
      stage,
      intentRecord: intent,
      request: request,
      dependencies: dependencies
    ) {
    case .success:
      inventory.restoreReceipts[restoreTransactionID] = stage
      recoveredRestoreReceipts.append(stage.value)
    case .failure(let failure):
      return .failure(failure)
    }
  }

  for transactionID in inventory.intents.keys.sorted() {
    guard inventory.receipts[transactionID] == nil,
      let intentRecord = inventory.intents[transactionID]
    else {
      continue
    }

    guard
      let stageName = descriptorJournalRecordName(
        prefix: ".receipt-stage-v1-",
        transactionID: transactionID
      ),
      let finalName = descriptorJournalRecordName(
        prefix: ".receipt-v1-",
        transactionID: transactionID
      )
    else {
      return .failure(.unsafe)
    }
    guard
      descriptorJournalInventory(
        inventory,
        canAddEntries: 1,
        peakAdditionalNameBytes: stageName.bytes.count
      )
    else {
      return .failure(.unavailable(.resourceLimit))
    }

    let truthBefore: DescriptorJournalNamespaceTruth
    switch descriptorJournalObserveNamespace(
      intentRecord.value,
      request: request,
      dependencies: dependencies
    ) {
    case .success(let truth):
      truthBefore = truth
    case .failure(let failure):
      return .failure(failure)
    }
    guard let terminal = descriptorJournalRecoveredTerminalOutcome(from: truthBefore) else {
      return .failure(.recoveryRequired(transactionID: transactionID))
    }
    guard
      descriptorJournalSyncPair(
        request.rootDescriptor,
        request.quarantineRootDescriptor,
        dependencies: dependencies
      )
    else {
      return .failure(.recoveryRequired(transactionID: transactionID))
    }
    switch descriptorJournalValidateParents(
      request,
      expectedRoot: intentRecord.value.npmRootBinding,
      expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure:
      return .failure(.recoveryRequired(transactionID: transactionID))
    }
    let truthAfterSync: DescriptorJournalNamespaceTruth
    switch descriptorJournalObserveNamespace(
      intentRecord.value,
      request: request,
      dependencies: dependencies
    ) {
    case .success(let truth):
      truthAfterSync = truth
    case .failure:
      return .failure(.recoveryRequired(transactionID: transactionID))
    }
    guard truthBefore == truthAfterSync,
      descriptorJournalTruth(truthAfterSync, matches: terminal)
    else {
      return .failure(.recoveryRequired(transactionID: transactionID))
    }

    let receipt: QuarantineJournalReceiptV1
    do {
      receipt = try descriptorJournalMakeReceipt(
        terminal,
        producedByRecovery: true,
        canonicalIntentBytes: intentRecord.bytes
      )
    } catch {
      return .failure(.unsafe)
    }
    let receiptBytes: Data
    do {
      receiptBytes = try QuarantineJournalV1Codec.encode(
        receipt,
        matchingIntentBytes: intentRecord.bytes
      )
    } catch {
      return .failure(.unsafe)
    }
    switch descriptorJournalPublishNewRecord(
      bytes: receiptBytes,
      stageName: stageName,
      finalName: finalName,
      quarantineRootDescriptor: request.quarantineRootDescriptor,
      expectedDevice: intentRecord.value.quarantineRootBinding.device,
      accountUID: request.accountUID,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure, .finalMayExist:
      return .failure(.recoveryRequired(transactionID: transactionID))
    }

    switch descriptorJournalValidateParents(
      request,
      expectedRoot: intentRecord.value.npmRootBinding,
      expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure:
      return .failure(.recoveryRequired(transactionID: transactionID))
    }
    switch descriptorJournalObserveNamespace(
      intentRecord.value,
      request: request,
      dependencies: dependencies
    ) {
    case .success(let truth) where truth == truthAfterSync:
      recoveredReceipts.append(receipt)
    case .success, .failure:
      return .failure(.recoveryRequired(transactionID: transactionID))
    }
  }

  for restoreTransactionID in inventory.restoreIntents.keys.sorted() {
    guard inventory.restoreReceipts[restoreTransactionID] == nil,
      let intentRecord = inventory.restoreIntents[restoreTransactionID]
    else {
      continue
    }

    guard
      let stageName = descriptorJournalRecordName(
        prefix: ".restore-receipt-stage-v1-",
        transactionID: restoreTransactionID
      ),
      let finalName = descriptorJournalRecordName(
        prefix: ".restore-receipt-v1-",
        transactionID: restoreTransactionID
      )
    else {
      return .failure(.unsafe)
    }
    guard
      descriptorJournalInventory(
        inventory,
        canAddEntries: 1,
        peakAdditionalNameBytes: stageName.bytes.count
      )
    else {
      return .failure(.unavailable(.resourceLimit))
    }

    switch descriptorJournalValidateHistoricalReceiptParents(
      request,
      expectedRoot: intentRecord.value.npmRootBinding,
      expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure:
      return .failure(.recoveryRequired(transactionID: restoreTransactionID))
    }
    let truthBefore: DescriptorRestoreJournalNamespaceTruth
    switch descriptorJournalObserveRestoreNamespace(
      intentRecord.value,
      request: request,
      dependencies: dependencies
    ) {
    case .success(let truth):
      truthBefore = truth
    case .failure(let failure):
      return .failure(failure)
    }
    guard let terminal = descriptorJournalRecoveredRestoreOutcome(from: truthBefore) else {
      return .failure(.recoveryRequired(transactionID: restoreTransactionID))
    }
    guard
      descriptorJournalSyncPair(
        request.rootDescriptor,
        request.quarantineRootDescriptor,
        dependencies: dependencies
      )
    else {
      return .failure(.recoveryRequired(transactionID: restoreTransactionID))
    }
    switch descriptorJournalValidateHistoricalReceiptParents(
      request,
      expectedRoot: intentRecord.value.npmRootBinding,
      expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure:
      return .failure(.recoveryRequired(transactionID: restoreTransactionID))
    }
    let truthAfterSync: DescriptorRestoreJournalNamespaceTruth
    switch descriptorJournalObserveRestoreNamespace(
      intentRecord.value,
      request: request,
      dependencies: dependencies
    ) {
    case .success(let truth):
      truthAfterSync = truth
    case .failure:
      return .failure(.recoveryRequired(transactionID: restoreTransactionID))
    }
    guard truthBefore == truthAfterSync,
      descriptorJournalRestoreTruth(truthAfterSync, matches: terminal)
    else {
      return .failure(.recoveryRequired(transactionID: restoreTransactionID))
    }

    let receipt: QuarantineRestoreJournalReceiptV1
    do {
      receipt = try descriptorJournalMakeRestoreReceipt(
        terminal,
        producedByRecovery: true,
        canonicalIntentBytes: intentRecord.bytes
      )
    } catch {
      return .failure(.unsafe)
    }
    let receiptBytes: Data
    do {
      receiptBytes = try QuarantineRestoreJournalV1Codec.encode(
        receipt,
        matchingIntentBytes: intentRecord.bytes
      )
    } catch {
      return .failure(.unsafe)
    }
    switch descriptorJournalPublishNewRecord(
      bytes: receiptBytes,
      stageName: stageName,
      finalName: finalName,
      quarantineRootDescriptor: request.quarantineRootDescriptor,
      expectedDevice: intentRecord.value.quarantineRootBinding.device,
      accountUID: request.accountUID,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure, .finalMayExist:
      return .failure(.recoveryRequired(transactionID: restoreTransactionID))
    }

    switch descriptorJournalValidateHistoricalReceiptParents(
      request,
      expectedRoot: intentRecord.value.npmRootBinding,
      expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
      dependencies: dependencies
    ) {
    case .success:
      break
    case .failure:
      return .failure(.recoveryRequired(transactionID: restoreTransactionID))
    }
    switch descriptorJournalObserveRestoreNamespace(
      intentRecord.value,
      request: request,
      dependencies: dependencies
    ) {
    case .success(let truth) where truth == truthAfterSync:
      recoveredRestoreReceipts.append(receipt)
    case .success, .failure:
      return .failure(.recoveryRequired(transactionID: restoreTransactionID))
    }
  }

  return .success(
    DescriptorQuarantineJournalRecoverySummary(
      recoveredReceipts: recoveredReceipts,
      validatedTransactionCount: inventory.intents.count,
      recoveredRestoreReceipts: recoveredRestoreReceipts,
      validatedRestoreTransactionCount: inventory.restoreIntents.count
    ))
}

func descriptorJournalValidateTerminalOutcome(
  _ outcome: DescriptorQuarantineJournalTerminalOutcome,
  session: DescriptorQuarantineJournalSession,
  context: DescriptorQuarantineJournalSession.ProductionContext,
  synchronizeParents: Bool,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<DescriptorJournalNamespaceTruth, DescriptorQuarantineJournalFailure> {
  let request = DescriptorQuarantineJournalRecoveryRequest(
    rootDescriptor: context.rootDescriptor,
    quarantineRootDescriptor: context.quarantineRootDescriptor,
    quarantineRootComponent: context.quarantineRootComponent,
    absoluteRootComponents: context.absoluteRootComponents,
    homeComponentCount: context.homeComponentCount,
    accountUID: context.accountUID
  )
  switch descriptorJournalValidateParents(
    request,
    expectedRoot: session.intent.npmRootBinding,
    expectedQuarantineRoot: session.intent.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }
  let before: DescriptorJournalNamespaceTruth
  switch descriptorJournalObserveNamespace(
    session.intent,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let truth):
    before = truth
  case .failure(let failure):
    return .failure(failure)
  }
  guard descriptorJournalTruth(before, matches: outcome) else {
    return .failure(.recoveryRequired(transactionID: session.transactionID))
  }
  if synchronizeParents {
    guard
      descriptorJournalSyncPair(
        context.rootDescriptor,
        context.quarantineRootDescriptor,
        dependencies: dependencies
      )
    else {
      return .failure(.recoveryRequired(transactionID: session.transactionID))
    }
  }
  switch descriptorJournalValidateParents(
    request,
    expectedRoot: session.intent.npmRootBinding,
    expectedQuarantineRoot: session.intent.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure:
    return .failure(.recoveryRequired(transactionID: session.transactionID))
  }
  switch descriptorJournalObserveNamespace(
    session.intent,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let after) where after == before:
    return .success(after)
  case .success, .failure:
    return .failure(.recoveryRequired(transactionID: session.transactionID))
  }
}

func descriptorJournalSynchronizePendingIntent(
  session: DescriptorQuarantineJournalSession,
  context: DescriptorQuarantineJournalSession.ProductionContext,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  let request = DescriptorQuarantineJournalRecoveryRequest(
    rootDescriptor: context.rootDescriptor,
    quarantineRootDescriptor: context.quarantineRootDescriptor,
    quarantineRootComponent: context.quarantineRootComponent,
    absoluteRootComponents: context.absoluteRootComponents,
    homeComponentCount: context.homeComponentCount,
    accountUID: context.accountUID
  )
  let before: DescriptorJournalNamespaceTruth
  switch descriptorJournalObserveNamespace(
    session.intent,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let truth):
    before = truth
  case .failure(let failure):
    return .failure(failure)
  }
  guard
    descriptorJournalSyncPair(
      context.rootDescriptor,
      context.quarantineRootDescriptor,
      dependencies: dependencies
    )
  else {
    return .failure(.recoveryRequired(transactionID: session.transactionID))
  }
  switch descriptorJournalObserveNamespace(
    session.intent,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let after) where after == before:
    return .success(())
  case .success, .failure:
    return .failure(.recoveryRequired(transactionID: session.transactionID))
  }
}

private func descriptorJournalCompleteStagedReceipt(
  _ receiptRecord: DescriptorJournalRecord<QuarantineJournalReceiptV1>,
  intentRecord: DescriptorJournalRecord<QuarantineJournalIntentV1>,
  request: DescriptorQuarantineJournalRecoveryRequest,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  let expectedOutcome = descriptorJournalTerminalOutcome(for: receiptRecord.value)
  let truthBefore: DescriptorJournalNamespaceTruth
  switch descriptorJournalObserveNamespace(
    intentRecord.value,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let truth):
    truthBefore = truth
  case .failure(let failure):
    return .failure(failure)
  }
  guard descriptorJournalTruth(truthBefore, matches: expectedOutcome) else {
    return .failure(.recoveryRequired(transactionID: intentRecord.value.transactionID))
  }
  guard
    descriptorJournalSyncPair(
      request.rootDescriptor,
      request.quarantineRootDescriptor,
      dependencies: dependencies
    )
  else {
    return .failure(.recoveryRequired(transactionID: intentRecord.value.transactionID))
  }
  switch descriptorJournalValidateParents(
    request,
    expectedRoot: intentRecord.value.npmRootBinding,
    expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure:
    return .failure(.recoveryRequired(transactionID: intentRecord.value.transactionID))
  }
  let truthAfterSync: DescriptorJournalNamespaceTruth
  switch descriptorJournalObserveNamespace(
    intentRecord.value,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let truth):
    truthAfterSync = truth
  case .failure:
    return .failure(.recoveryRequired(transactionID: intentRecord.value.transactionID))
  }
  guard truthBefore == truthAfterSync else {
    return .failure(.recoveryRequired(transactionID: intentRecord.value.transactionID))
  }

  guard
    let finalName = descriptorJournalRecordName(
      prefix: ".receipt-v1-",
      transactionID: intentRecord.value.transactionID
    )
  else {
    return .failure(.unsafe)
  }
  switch descriptorJournalPromoteExistingStage(
    bytes: receiptRecord.bytes,
    stageName: receiptRecord.component,
    finalName: finalName,
    quarantineRootDescriptor: request.quarantineRootDescriptor,
    expectedDevice: intentRecord.value.quarantineRootBinding.device,
    accountUID: request.accountUID,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure, .finalMayExist:
    return .failure(.recoveryRequired(transactionID: intentRecord.value.transactionID))
  }

  switch descriptorJournalValidateParents(
    request,
    expectedRoot: intentRecord.value.npmRootBinding,
    expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure:
    return .failure(.recoveryRequired(transactionID: intentRecord.value.transactionID))
  }
  switch descriptorJournalObserveNamespace(
    intentRecord.value,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let truth) where truth == truthAfterSync:
    return .success(())
  case .success, .failure:
    return .failure(.recoveryRequired(transactionID: intentRecord.value.transactionID))
  }
}

private func descriptorJournalCompleteStagedRestoreReceipt(
  _ receiptRecord: DescriptorJournalRecord<QuarantineRestoreJournalReceiptV1>,
  intentRecord: DescriptorJournalRecord<QuarantineRestoreJournalIntentV1>,
  request: DescriptorQuarantineJournalRecoveryRequest,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  let expectedOutcome = descriptorJournalRestoreTerminalOutcome(for: receiptRecord.value)
  switch descriptorJournalValidateHistoricalReceiptParents(
    request,
    expectedRoot: intentRecord.value.npmRootBinding,
    expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure:
    return .failure(.recoveryRequired(transactionID: intentRecord.value.restoreTransactionID))
  }
  let truthBefore: DescriptorRestoreJournalNamespaceTruth
  switch descriptorJournalObserveRestoreNamespace(
    intentRecord.value,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let truth):
    truthBefore = truth
  case .failure(let failure):
    return .failure(failure)
  }
  guard descriptorJournalRestoreTruth(truthBefore, matches: expectedOutcome) else {
    return .failure(.recoveryRequired(transactionID: intentRecord.value.restoreTransactionID))
  }
  guard
    descriptorJournalSyncPair(
      request.rootDescriptor,
      request.quarantineRootDescriptor,
      dependencies: dependencies
    )
  else {
    return .failure(.recoveryRequired(transactionID: intentRecord.value.restoreTransactionID))
  }
  switch descriptorJournalValidateHistoricalReceiptParents(
    request,
    expectedRoot: intentRecord.value.npmRootBinding,
    expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure:
    return .failure(.recoveryRequired(transactionID: intentRecord.value.restoreTransactionID))
  }
  let truthAfterSync: DescriptorRestoreJournalNamespaceTruth
  switch descriptorJournalObserveRestoreNamespace(
    intentRecord.value,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let truth):
    truthAfterSync = truth
  case .failure:
    return .failure(.recoveryRequired(transactionID: intentRecord.value.restoreTransactionID))
  }
  guard truthBefore == truthAfterSync else {
    return .failure(.recoveryRequired(transactionID: intentRecord.value.restoreTransactionID))
  }

  guard
    let finalName = descriptorJournalRecordName(
      prefix: ".restore-receipt-v1-",
      transactionID: intentRecord.value.restoreTransactionID
    )
  else {
    return .failure(.unsafe)
  }
  switch descriptorJournalPromoteExistingStage(
    bytes: receiptRecord.bytes,
    stageName: receiptRecord.component,
    finalName: finalName,
    quarantineRootDescriptor: request.quarantineRootDescriptor,
    expectedDevice: intentRecord.value.quarantineRootBinding.device,
    accountUID: request.accountUID,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure, .finalMayExist:
    return .failure(.recoveryRequired(transactionID: intentRecord.value.restoreTransactionID))
  }

  switch descriptorJournalValidateHistoricalReceiptParents(
    request,
    expectedRoot: intentRecord.value.npmRootBinding,
    expectedQuarantineRoot: intentRecord.value.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure:
    return .failure(.recoveryRequired(transactionID: intentRecord.value.restoreTransactionID))
  }
  switch descriptorJournalObserveRestoreNamespace(
    intentRecord.value,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let truth) where truth == truthAfterSync:
    return .success(())
  case .success, .failure:
    return .failure(.recoveryRequired(transactionID: intentRecord.value.restoreTransactionID))
  }
}

private func descriptorJournalPromoteExistingStage(
  bytes: Data,
  stageName: DescriptorPathComponent,
  finalName: DescriptorPathComponent,
  quarantineRootDescriptor: Int32,
  expectedDevice: UInt64,
  accountUID: uid_t,
  dependencies: DescriptorQuarantineJournalDependencies
) -> DescriptorJournalPublicationResult {
  var descriptor = Int32(-1)
  var failureCode = Int32(EINVAL)
  for attempt in 0..<3 {
    descriptor = stageName.withCString { pointer in
      let result = Darwin.openat(
        quarantineRootDescriptor,
        pointer,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_RESOLVE_BENEATH
      )
      if result < 0 { failureCode = errno }
      return result
    }
    if descriptor >= 0 { break }
    if failureCode == EINTR, attempt + 1 < 3 { continue }
    break
  }
  guard descriptor >= 0 else {
    return .failure(.unavailable(descriptorJournalFailureCode(failureCode)))
  }
  defer { descriptorCloseIgnoringErrors(descriptor) }
  switch descriptorJournalValidateHeldRecordBytes(
    descriptor,
    namedAt: quarantineRootDescriptor,
    component: stageName,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedBytes: bytes,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }
  guard descriptorJournalSync(descriptor, dependencies: dependencies) == nil else {
    return .failure(.unavailable(.inputOutput))
  }
  switch descriptorJournalValidateHeldRecordBytes(
    descriptor,
    namedAt: quarantineRootDescriptor,
    component: stageName,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedBytes: bytes,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }
  dependencies.hooks.willPublishStage(stageName, finalName)
  switch dependencies.renameExclusive(
    quarantineRootDescriptor,
    stageName,
    finalName,
    DescriptorExclusiveQuarantineMover.renameFlags
  ) {
  case .succeeded:
    break
  case .failed(EINTR), .failed(EIO):
    return .finalMayExist
  case .failed(let code):
    return .failure(
      code == EEXIST ? .unsafe : .unavailable(descriptorJournalFailureCode(code))
    )
  }
  dependencies.hooks.didPublishFinal(finalName)
  guard descriptorJournalSync(quarantineRootDescriptor, dependencies: dependencies) == nil else {
    return .finalMayExist
  }
  switch descriptorJournalValidateHeldRecordBytes(
    descriptor,
    namedAt: quarantineRootDescriptor,
    component: finalName,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedBytes: bytes,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure:
    return .finalMayExist
  }
  guard descriptorJournalSync(descriptor, dependencies: dependencies) == nil else {
    return .finalMayExist
  }
  return .success
}

private func descriptorJournalStabilizeFinalRecord<Value>(
  _ record: DescriptorJournalRecord<Value>,
  quarantineRootDescriptor: Int32,
  expectedDevice: UInt64,
  accountUID: uid_t,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  var descriptor = Int32(-1)
  var failureCode = Int32(EINVAL)
  for attempt in 0..<3 {
    descriptor = record.component.withCString { pointer in
      let result = Darwin.openat(
        quarantineRootDescriptor,
        pointer,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_RESOLVE_BENEATH
      )
      if result < 0 { failureCode = errno }
      return result
    }
    if descriptor >= 0 { break }
    if failureCode == EINTR, attempt + 1 < 3 { continue }
    break
  }
  guard descriptor >= 0 else {
    return .failure(.unavailable(descriptorJournalFailureCode(failureCode)))
  }
  defer { descriptorCloseIgnoringErrors(descriptor) }

  switch descriptorJournalValidateHeldRecordBytes(
    descriptor,
    namedAt: quarantineRootDescriptor,
    component: record.component,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedBytes: record.bytes,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }
  guard descriptorJournalSync(quarantineRootDescriptor, dependencies: dependencies) == nil else {
    return .failure(.unavailable(.inputOutput))
  }
  switch descriptorJournalValidateHeldRecordBytes(
    descriptor,
    namedAt: quarantineRootDescriptor,
    component: record.component,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedBytes: record.bytes,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }
  guard descriptorJournalSync(descriptor, dependencies: dependencies) == nil else {
    return .failure(.unavailable(.inputOutput))
  }
  return .success(())
}

private func descriptorJournalValidateHeldRecordBytes(
  _ descriptor: Int32,
  namedAt parentDescriptor: Int32,
  component: DescriptorPathComponent,
  expectedDevice: UInt64,
  accountUID: uid_t,
  expectedBytes: Data,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineJournalFailure> {
  let before: DescriptorJournalStat
  do {
    before = try DescriptorJournalStat.read(from: descriptor)
  } catch {
    return .failure(.unavailable(descriptorJournalFailure(for: error)))
  }
  switch descriptorJournalValidateRecordDescriptor(
    descriptor,
    namedAt: parentDescriptor,
    component: component,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedByteCount: expectedBytes.count,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }

  var observedBytes = Data(count: expectedBytes.count)
  var offset = 0
  var interruptedAttempts = 0
  let readFailure: Int32? = observedBytes.withUnsafeMutableBytes { buffer in
    while offset < buffer.count {
      let result = Darwin.pread(
        descriptor,
        buffer.baseAddress!.advanced(by: offset),
        buffer.count - offset,
        off_t(offset)
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
  if let readFailure {
    return .failure(.unavailable(descriptorJournalFailureCode(readFailure)))
  }
  guard observedBytes == expectedBytes else { return .failure(.unsafe) }

  do {
    let after = try DescriptorJournalStat.read(from: descriptor)
    guard before == after else { return .failure(.unsafe) }
  } catch {
    return .failure(.unavailable(descriptorJournalFailure(for: error)))
  }
  return descriptorJournalValidateRecordDescriptor(
    descriptor,
    namedAt: parentDescriptor,
    component: component,
    expectedDevice: expectedDevice,
    accountUID: accountUID,
    expectedByteCount: expectedBytes.count,
    dependencies: dependencies
  )
}

private func descriptorJournalObserveNamespace(
  _ intent: QuarantineJournalIntentV1,
  request: DescriptorQuarantineJournalRecoveryRequest,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<DescriptorJournalNamespaceTruth, DescriptorQuarantineJournalFailure> {
  switch descriptorJournalValidateParents(
    request,
    expectedRoot: intent.npmRootBinding,
    expectedQuarantineRoot: intent.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }
  guard intent.sourceComponents.count == 1 else { return .failure(.unsafe) }

  let source: DescriptorJournalObservedName
  switch descriptorJournalObserveName(
    parentDescriptor: request.rootDescriptor,
    componentBytes: intent.sourceComponents[0],
    expected: intent.candidateBinding,
    dependencies: dependencies
  ) {
  case .success(let result):
    source = result
  case .failure(let failure):
    return .failure(failure)
  }

  var destinations: [DescriptorJournalObservedName] = []
  destinations.reserveCapacity(intent.destinationComponents.count)
  for destination in intent.destinationComponents {
    switch descriptorJournalObserveName(
      parentDescriptor: request.quarantineRootDescriptor,
      componentBytes: destination,
      expected: intent.candidateBinding,
      dependencies: dependencies
    ) {
    case .success(let result):
      destinations.append(result)
    case .failure(let failure):
      return .failure(failure)
    }
  }
  return .success(
    DescriptorJournalNamespaceTruth(source: source, destinations: destinations)
  )
}

private func descriptorJournalObserveName(
  parentDescriptor: Int32,
  componentBytes: [UInt8],
  expected: QuarantineJournalFileBindingV1,
  matchHistoricalIdentityOnly: Bool = false,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<DescriptorJournalObservedName, DescriptorQuarantineJournalFailure> {
  guard let component = DescriptorPathComponent(componentBytes) else {
    return .failure(.unsafe)
  }
  let named: DescriptorJournalStat
  do {
    named = try DescriptorJournalStat.read(at: parentDescriptor, component: component)
  } catch let error as DescriptorJournalPOSIXError where error.code == ENOENT {
    return .success(.missing)
  } catch let error as DescriptorJournalPOSIXError {
    return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
  } catch {
    return .failure(.unavailable(.unspecified))
  }
  let matchesExpected =
    matchHistoricalIdentityOnly
    ? descriptorJournalMatchesHistoricalParent(named.snapshot, expected: expected)
    : descriptorJournalMatches(named.snapshot, expected: expected, includeLinkCount: true)
  guard matchesExpected else {
    return .success(.other(named))
  }
  guard named.snapshot.kind == .directory,
    named.snapshot.permissionMode & mode_t(0o022) == 0,
    named.snapshot.flags == 0
  else {
    return .failure(.unsafe)
  }

  var descriptor = Int32(-1)
  var failureCode = Int32(EINVAL)
  for attempt in 0..<3 {
    descriptor = component.withCString { pointer in
      let result = Darwin.openat(
        parentDescriptor,
        pointer,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
      )
      if result < 0 { failureCode = errno }
      return result
    }
    if descriptor >= 0 { break }
    if failureCode == EINTR, attempt + 1 < 3 { continue }
    break
  }
  guard descriptor >= 0 else {
    return .failure(.unavailable(descriptorJournalFailureCode(failureCode)))
  }
  defer { descriptorCloseIgnoringErrors(descriptor) }
  do {
    let held = try DescriptorJournalStat.read(from: descriptor)
    let namedAgain = try DescriptorJournalStat.read(
      at: parentDescriptor,
      component: component
    )
    let heldMatchesExpected =
      matchHistoricalIdentityOnly
      ? descriptorJournalMatchesHistoricalParent(held.snapshot, expected: expected)
      : descriptorJournalMatches(held.snapshot, expected: expected, includeLinkCount: true)
    guard held == named,
      namedAgain == held,
      heldMatchesExpected
    else {
      return .failure(.unsafe)
    }
  } catch let error as DescriptorJournalPOSIXError {
    return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
  } catch {
    return .failure(.unavailable(.unspecified))
  }
  switch dependencies.hasExtendedACL(descriptor) {
  case .success(false):
    return .success(.expected(named))
  case .success(true):
    return .failure(.unsafe)
  case .failure(let error):
    return .failure(.unavailable(descriptorJournalFailureCode(error.code)))
  }
}

private func descriptorJournalRecoveredTerminalOutcome(
  from truth: DescriptorJournalNamespaceTruth
) -> DescriptorQuarantineJournalTerminalOutcome? {
  let expectedDestinations = truth.destinations.indices.filter {
    if case .expected = truth.destinations[$0] { return true }
    return false
  }
  if case .expected = truth.source, expectedDestinations.isEmpty {
    return .notMoved
  }
  guard expectedDestinations.count == 1 else { return nil }
  let ordinal = expectedDestinations[0]
  switch truth.source {
  case .missing:
    return .quarantined(
      selectedDestinationOrdinal: ordinal,
      sourceNameWasRecreated: false
    )
  case .other:
    return .quarantined(
      selectedDestinationOrdinal: ordinal,
      sourceNameWasRecreated: true
    )
  case .expected:
    return nil
  }
}

private func descriptorJournalTruth(
  _ truth: DescriptorJournalNamespaceTruth,
  matches outcome: DescriptorQuarantineJournalTerminalOutcome
) -> Bool {
  let expectedDestinations = truth.destinations.indices.filter {
    if case .expected = truth.destinations[$0] { return true }
    return false
  }
  switch outcome {
  case .notMoved, .rolledBack:
    guard case .expected = truth.source else { return false }
    return expectedDestinations.isEmpty
  case .quarantined(let ordinal, let sourceNameWasRecreated):
    guard expectedDestinations == [ordinal] else { return false }
    if sourceNameWasRecreated {
      guard case .other = truth.source else { return false }
    } else {
      guard case .missing = truth.source else { return false }
    }
    return true
  case .unresolved:
    return false
  }
}

private func descriptorJournalTerminalOutcome(
  for receipt: QuarantineJournalReceiptV1
) -> DescriptorQuarantineJournalTerminalOutcome {
  switch receipt.outcome {
  case .notMoved:
    return .notMoved
  case .rolledBack:
    return .rolledBack
  case .quarantined:
    return .quarantined(
      selectedDestinationOrdinal: receipt.selectedDestinationOrdinal!,
      sourceNameWasRecreated: receipt.sourceNameWasRecreated
    )
  }
}

private func descriptorJournalMakeReceipt(
  _ outcome: DescriptorQuarantineJournalTerminalOutcome,
  producedByRecovery: Bool,
  canonicalIntentBytes: Data
) throws -> QuarantineJournalReceiptV1 {
  switch outcome {
  case .notMoved:
    return try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: producedByRecovery,
      canonicalIntentBytes: canonicalIntentBytes
    )
  case .quarantined(let ordinal, let sourceNameWasRecreated):
    return try QuarantineJournalV1Codec.makeReceipt(
      outcome: .quarantined,
      selectedDestinationOrdinal: ordinal,
      sourceNameWasRecreated: sourceNameWasRecreated,
      producedByRecovery: producedByRecovery,
      canonicalIntentBytes: canonicalIntentBytes
    )
  case .rolledBack:
    return try QuarantineJournalV1Codec.makeReceipt(
      outcome: .rolledBack,
      producedByRecovery: producedByRecovery,
      canonicalIntentBytes: canonicalIntentBytes
    )
  case .unresolved:
    throw QuarantineJournalCodecError.invalidReceiptRelationships
  }
}

private func descriptorJournalRetryInterrupted(
  _ operation: () throws -> Void
) throws {
  var attempt = 0
  while true {
    do {
      try operation()
      return
    } catch let error as DescriptorJournalPOSIXError {
      guard error.code == EINTR, attempt + 1 < 3 else { throw error }
      attempt += 1
    } catch {
      throw error
    }
  }
}

private func descriptorJournalFailureCode(
  _ code: Int32
) -> CleanupQuarantineSystemFailure {
  descriptorJournalFailure(for: code)
}

func descriptorJournalPrepareRestore(
  _ request: DescriptorQuarantineRestorePreparationRequest,
  dependencies: DescriptorQuarantineJournalDependencies
) -> DescriptorQuarantineRestorePreparationResult {
  let recoveryRequest = request.recoveryRequest
  switch descriptorJournalValidateRecoveryParentsBeforeLock(
    recoveryRequest,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(.journal(failure))
  }

  let quarantineSnapshot: DescriptorStatSnapshot
  do {
    quarantineSnapshot = try DescriptorStatSnapshot.read(
      from: recoveryRequest.quarantineRootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
  } catch {
    return .failure(.journal(.unavailable(descriptorJournalFailure(for: error))))
  }
  let lock = descriptorJournalAcquireLock(
    quarantineRootDescriptor: recoveryRequest.quarantineRootDescriptor,
    expectedDevice: quarantineSnapshot.identity.device,
    accountUID: recoveryRequest.accountUID,
    dependencies: dependencies
  )
  let lockDescriptor: Int32
  switch lock {
  case .success(let descriptor):
    lockDescriptor = descriptor
  case .failure(let failure):
    return .failure(.journal(failure))
  }
  defer {
    dependencies.unlock(lockDescriptor)
    descriptorCloseIgnoringErrors(lockDescriptor)
  }
  dependencies.hooks.didAcquireLock()

  switch descriptorJournalRecoverLocked(recoveryRequest, dependencies: dependencies) {
  case .success:
    break
  case .failure(let failure):
    return .failure(.journal(failure))
  }

  let inventory: DescriptorJournalInventory
  switch descriptorJournalReadInventory(
    recoveryRequest,
    expectedDevice: quarantineSnapshot.identity.device,
    dependencies: dependencies
  ) {
  case .success(let value):
    inventory = value
  case .failure(let failure):
    return .failure(.journal(failure))
  }
  switch descriptorJournalValidateInventoryStructure(
    inventory,
    maximumPendingIntentCount: 0
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(.journal(failure))
  }

  guard
    let quarantineIntentRecord = inventory.intents[request.quarantineTransactionID],
    let quarantineReceiptRecord = inventory.receipts[request.quarantineTransactionID]
  else {
    return .failure(.transactionNotFound)
  }
  guard quarantineReceiptRecord.value.outcome == .quarantined else {
    return .failure(.transactionNotRestorable)
  }
  guard
    !descriptorJournalHasSuccessfulRestore(
      for: request.quarantineTransactionID,
      inventory: inventory
    )
  else {
    return .failure(.alreadyRestored)
  }
  guard
    !descriptorJournalContainsRestoreTransaction(
      request.restoreTransactionID,
      inventory: inventory
    )
  else {
    return .failure(.invalidClaim)
  }

  let restoreIntent: QuarantineRestoreJournalIntentV1
  do {
    restoreIntent = try QuarantineRestoreJournalV1Codec.makeIntent(
      restoreTransactionID: request.restoreTransactionID,
      canonicalQuarantineIntentBytes: quarantineIntentRecord.bytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptRecord.bytes
    )
  } catch {
    return .failure(.transactionNotRestorable)
  }
  switch descriptorJournalValidateHistoricalReceiptParents(
    recoveryRequest,
    expectedRoot: restoreIntent.npmRootBinding,
    expectedQuarantineRoot: restoreIntent.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(.journal(failure))
  }

  let truth: DescriptorRestoreJournalNamespaceTruth
  switch descriptorJournalObserveRestoreNamespace(
    restoreIntent,
    request: recoveryRequest,
    dependencies: dependencies
  ) {
  case .success(let value):
    truth = value
  case .failure(let failure):
    return .failure(.journal(failure))
  }
  switch truth.source {
  case .missing:
    break
  case .expected, .other:
    return .failure(.sourceNameOccupied)
  }
  guard case .expected = truth.quarantineItem else {
    switch truth.quarantineItem {
    case .missing:
      return .failure(.quarantinedItemMissing)
    case .other:
      return .failure(.quarantinedItemChanged)
    case .expected:
      return .failure(.quarantinedItemChanged)
    }
  }

  switch descriptorJournalValidateRestoreItemTree(
    restoreIntent,
    request: recoveryRequest,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }

  return .success(
    CleanupQuarantineRestorePreparedEvidence(
      canonicalQuarantineIntentBytes: quarantineIntentRecord.bytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptRecord.bytes,
      restoreIntent: restoreIntent
    ))
}

private func descriptorJournalContainsRestoreTransaction(
  _ restoreTransactionID: String,
  inventory: DescriptorJournalInventory
) -> Bool {
  inventory.restoreIntentStages[restoreTransactionID] != nil
    || inventory.restoreIntents[restoreTransactionID] != nil
    || inventory.restoreReceiptStages[restoreTransactionID] != nil
    || inventory.restoreReceipts[restoreTransactionID] != nil
}

private func descriptorJournalHasSuccessfulRestore(
  for quarantineTransactionID: String,
  inventory: DescriptorJournalInventory
) -> Bool {
  inventory.restoreReceipts.contains { restoreTransactionID, receiptRecord in
    guard receiptRecord.value.outcome == .restored,
      let intent = inventory.restoreIntents[restoreTransactionID]?.value
    else {
      return false
    }
    return intent.quarantineTransactionID == quarantineTransactionID
  }
}

private func descriptorJournalValidateRestoreItemTree(
  _ intent: QuarantineRestoreJournalIntentV1,
  request: DescriptorQuarantineJournalRecoveryRequest,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineRestoreFailure> {
  guard let itemComponent = DescriptorPathComponent(intent.quarantineItemComponent) else {
    return .failure(.quarantinedItemChanged)
  }
  let itemDescriptor: Int32
  do {
    itemDescriptor = try descriptorOpenTrustedDirectory(
      at: request.quarantineRootDescriptor,
      component: itemComponent,
      cancellationPolicy: .ignoreTaskCancellation
    )
  } catch DescriptorObservationError.posix(ENOENT) {
    return .failure(.quarantinedItemMissing)
  } catch {
    return .failure(.quarantinedItemChanged)
  }
  defer { descriptorCloseIgnoringErrors(itemDescriptor) }

  let heldBefore: DescriptorJournalStat
  let namedBefore: DescriptorJournalStat
  do {
    heldBefore = try DescriptorJournalStat.read(from: itemDescriptor)
    namedBefore = try DescriptorJournalStat.read(
      at: request.quarantineRootDescriptor,
      component: itemComponent
    )
  } catch {
    return .failure(.quarantinedItemChanged)
  }
  guard
    heldBefore == namedBefore,
    descriptorJournalMatchesHistoricalParent(
      heldBefore.snapshot,
      expected: intent.candidateBinding
    ),
    heldBefore.snapshot.kind == .directory,
    heldBefore.snapshot.ownerUID == request.accountUID,
    heldBefore.snapshot.permissionMode & mode_t(0o022) == 0,
    heldBefore.snapshot.flags == 0
  else {
    return .failure(.quarantinedItemUnsafe)
  }
  switch dependencies.hasExtendedACL(itemDescriptor) {
  case .success(false):
    break
  case .success(true):
    return .failure(.quarantinedItemUnsafe)
  case .failure:
    return .failure(.quarantinedItemChanged)
  }

  do {
    _ = try DescriptorNPMCacheTreeValidator(
      checkpoint: { try Task.checkCancellation() }
    ).validate(
      descriptor: itemDescriptor,
      namedAt: request.quarantineRootDescriptor,
      component: itemComponent,
      expected: heldBefore.snapshot,
      rootDevice: intent.npmRootBinding.device,
      accountUID: request.accountUID
    )
  } catch is CancellationError {
    return .failure(.cancelled)
  } catch DescriptorNPMQuarantinePreflightFailure.traversalLimitExceeded {
    return .failure(.traversalLimitExceeded)
  } catch DescriptorNPMQuarantinePreflightFailure.candidateUnsafe,
    DescriptorNPMQuarantinePreflightFailure.layoutMismatch
  {
    return .failure(.quarantinedItemUnsafe)
  } catch {
    return .failure(.quarantinedItemChanged)
  }

  do {
    let heldAfter = try DescriptorJournalStat.read(from: itemDescriptor)
    let namedAfter = try DescriptorJournalStat.read(
      at: request.quarantineRootDescriptor,
      component: itemComponent
    )
    guard heldAfter == heldBefore, namedAfter == namedBefore else {
      return .failure(.quarantinedItemChanged)
    }
  } catch {
    return .failure(.quarantinedItemChanged)
  }
  return .success(())
}

func descriptorJournalBeginRestore(
  _ request: DescriptorQuarantineRestoreJournalBeginRequest,
  dependencies: DescriptorQuarantineJournalDependencies
) -> DescriptorQuarantineRestoreJournalBeginResult {
  let recoveryRequest = request.recoveryRequest
  let evidence = request.claim.evidence
  let intent = evidence.restoreIntent
  let intentBytes: Data
  do {
    guard
      request.claim.confirmation.request.subject.restoreTransactionID
        == intent.restoreTransactionID,
      request.claim.confirmation.request.subject.quarantineTransactionID
        == intent.quarantineTransactionID,
      request.claim.confirmation.statement
        == request.claim.confirmation.request.requiredStatement
    else {
      return .failure(.invalidClaim)
    }
    intentBytes = try QuarantineRestoreJournalV1Codec.encode(
      intent,
      matchingQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
      matchingQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes
    )
  } catch {
    return .failure(.invalidClaim)
  }

  switch descriptorJournalValidateRecoveryParentsBeforeLock(
    recoveryRequest,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(.journal(failure))
  }
  let quarantineSnapshot: DescriptorStatSnapshot
  do {
    quarantineSnapshot = try DescriptorStatSnapshot.read(
      from: recoveryRequest.quarantineRootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
  } catch {
    return .failure(.journal(.unavailable(descriptorJournalFailure(for: error))))
  }
  let acquiredLock = descriptorJournalAcquireLock(
    quarantineRootDescriptor: recoveryRequest.quarantineRootDescriptor,
    expectedDevice: quarantineSnapshot.identity.device,
    accountUID: recoveryRequest.accountUID,
    dependencies: dependencies
  )
  let lockDescriptor: Int32
  switch acquiredLock {
  case .success(let descriptor):
    lockDescriptor = descriptor
  case .failure(let failure):
    return .failure(.journal(failure))
  }
  var sessionOwnsLock = false
  defer {
    if !sessionOwnsLock {
      dependencies.unlock(lockDescriptor)
      descriptorCloseIgnoringErrors(lockDescriptor)
    }
  }
  dependencies.hooks.didAcquireLock()

  switch descriptorJournalRecoverLocked(recoveryRequest, dependencies: dependencies) {
  case .success:
    break
  case .failure(let failure):
    return .failure(.journal(failure))
  }

  let inventory: DescriptorJournalInventory
  switch descriptorJournalReadInventory(
    recoveryRequest,
    expectedDevice: quarantineSnapshot.identity.device,
    dependencies: dependencies
  ) {
  case .success(let value):
    inventory = value
  case .failure(let failure):
    return .failure(.journal(failure))
  }
  switch descriptorJournalValidateInventoryStructure(
    inventory,
    maximumPendingIntentCount: 0
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(.journal(failure))
  }
  guard
    let quarantineIntentRecord = inventory.intents[intent.quarantineTransactionID],
    let quarantineReceiptRecord = inventory.receipts[intent.quarantineTransactionID],
    quarantineIntentRecord.bytes == evidence.canonicalQuarantineIntentBytes,
    quarantineReceiptRecord.bytes == evidence.canonicalQuarantineReceiptBytes,
    quarantineReceiptRecord.value.outcome == .quarantined
  else {
    return .failure(.invalidClaim)
  }
  guard
    !descriptorJournalHasSuccessfulRestore(
      for: intent.quarantineTransactionID,
      inventory: inventory
    )
  else {
    return .failure(.alreadyRestored)
  }
  guard
    !descriptorJournalContainsRestoreTransaction(
      intent.restoreTransactionID,
      inventory: inventory
    )
  else {
    return .failure(.invalidClaim)
  }
  switch descriptorJournalValidateHistoricalReceiptParents(
    recoveryRequest,
    expectedRoot: intent.npmRootBinding,
    expectedQuarantineRoot: intent.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(.journal(failure))
  }

  let truth: DescriptorRestoreJournalNamespaceTruth
  switch descriptorJournalObserveRestoreNamespace(
    intent,
    request: recoveryRequest,
    dependencies: dependencies
  ) {
  case .success(let value):
    truth = value
  case .failure(let failure):
    return .failure(.journal(failure))
  }
  guard case .missing = truth.source else {
    return .failure(.sourceNameOccupied)
  }
  guard case .expected = truth.quarantineItem else {
    switch truth.quarantineItem {
    case .missing:
      return .failure(.quarantinedItemMissing)
    case .other, .expected:
      return .failure(.quarantinedItemChanged)
    }
  }
  switch descriptorJournalValidateHeldRestoreItem(
    request.quarantinedItemDescriptor,
    intent: intent,
    request: recoveryRequest,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }
  // Selection-time validation is stale evidence. Re-run the complete current
  // cache-tree policy while the mixed journal lock is held and before the
  // durable restore intent is admitted. The restorer repeats this after intent
  // publication because publishing the record mutates the parent namespace.
  switch descriptorJournalValidateRestoreItemTree(
    intent,
    request: recoveryRequest,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }
  switch descriptorJournalValidateHeldRestoreItem(
    request.quarantinedItemDescriptor,
    intent: intent,
    request: recoveryRequest,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }

  guard
    let intentStageName = descriptorJournalRecordName(
      prefix: ".restore-intent-stage-v1-",
      transactionID: intent.restoreTransactionID
    ),
    let intentFinalName = descriptorJournalRecordName(
      prefix: ".restore-intent-v1-",
      transactionID: intent.restoreTransactionID
    ),
    let receiptStageName = descriptorJournalRecordName(
      prefix: ".restore-receipt-stage-v1-",
      transactionID: intent.restoreTransactionID
    ),
    descriptorJournalInventory(
      inventory,
      canAddEntries: 2,
      peakAdditionalNameBytes: max(
        intentStageName.bytes.count,
        intentFinalName.bytes.count + receiptStageName.bytes.count
      )
    )
  else {
    return .failure(.journal(.unavailable(.resourceLimit)))
  }
  guard
    descriptorJournalSyncPair(
      recoveryRequest.rootDescriptor,
      recoveryRequest.quarantineRootDescriptor,
      dependencies: dependencies
    )
  else {
    return .failure(.journal(.unavailable(.inputOutput)))
  }

  switch descriptorJournalPublishNewRecord(
    bytes: intentBytes,
    stageName: intentStageName,
    finalName: intentFinalName,
    quarantineRootDescriptor: recoveryRequest.quarantineRootDescriptor,
    expectedDevice: intent.quarantineRootBinding.device,
    accountUID: recoveryRequest.accountUID,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(.journal(failure))
  case .finalMayExist:
    return .failure(
      .journal(.recoveryRequired(transactionID: intent.restoreTransactionID))
    )
  }

  let rootAfterIntent: DescriptorStatSnapshot
  let quarantineRootAfterIntent: DescriptorStatSnapshot
  do {
    rootAfterIntent = try DescriptorStatSnapshot.read(
      from: recoveryRequest.rootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    quarantineRootAfterIntent = try DescriptorStatSnapshot.read(
      from: recoveryRequest.quarantineRootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
  } catch {
    return .failure(
      .journal(.recoveryRequired(transactionID: intent.restoreTransactionID))
    )
  }

  sessionOwnsLock = true
  return .success(
    DescriptorQuarantineRestoreJournalSession(
      restoreTransactionID: intent.restoreTransactionID,
      quarantineTransactionID: intent.quarantineTransactionID,
      intent: intent,
      canonicalIntentBytes: intentBytes,
      rootSnapshotAfterIntent: rootAfterIntent,
      quarantineRootSnapshotAfterIntent: quarantineRootAfterIntent,
      lockDescriptor: lockDescriptor,
      unlock: dependencies.unlock,
      payload: .production(
        DescriptorQuarantineRestoreJournalSession.ProductionContext(
          recoveryRequest: recoveryRequest,
          canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
          canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes,
          canonicalRestoreIntentBytes: intentBytes
        )
      )
    ))
}

private func descriptorJournalValidateHeldRestoreItem(
  _ descriptor: Int32,
  intent: QuarantineRestoreJournalIntentV1,
  request: DescriptorQuarantineJournalRecoveryRequest,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<Void, DescriptorQuarantineRestoreFailure> {
  guard descriptor >= 0,
    let component = DescriptorPathComponent(intent.quarantineItemComponent)
  else {
    return .failure(.quarantinedItemChanged)
  }
  do {
    let held = try DescriptorJournalStat.read(from: descriptor)
    let named = try DescriptorJournalStat.read(
      at: request.quarantineRootDescriptor,
      component: component
    )
    guard
      held == named,
      descriptorJournalMatchesHistoricalParent(
        held.snapshot,
        expected: intent.candidateBinding
      ),
      held.snapshot.kind == .directory,
      held.snapshot.ownerUID == request.accountUID,
      held.snapshot.permissionMode & mode_t(0o022) == 0,
      held.snapshot.flags == 0
    else {
      return .failure(.quarantinedItemUnsafe)
    }
    switch dependencies.hasExtendedACL(descriptor) {
    case .success(false):
      return .success(())
    case .success(true):
      return .failure(.quarantinedItemUnsafe)
    case .failure:
      return .failure(.quarantinedItemChanged)
    }
  } catch let error as DescriptorJournalPOSIXError where error.code == ENOENT {
    return .failure(.quarantinedItemMissing)
  } catch {
    return .failure(.quarantinedItemChanged)
  }
}

func descriptorJournalFinishRestore(
  _ session: DescriptorQuarantineRestoreJournalSession,
  outcome: DescriptorQuarantineRestoreJournalTerminalOutcome,
  namespaceMutationMayHaveBeenInvoked: Bool,
  dependencies: DescriptorQuarantineJournalDependencies
) -> DescriptorQuarantineRestoreJournalFinishResult {
  guard case .production(let context) = session.payload else {
    return .invalidSession
  }
  let request = context.recoveryRequest

  func recoveryResult() -> DescriptorQuarantineRestoreJournalFinishResult {
    descriptorJournalRestoreFinishFailureIsRecoveryAdmissible(
      session,
      context: context,
      dependencies: dependencies
    )
      ? .recoveryRequired(restoreTransactionID: session.restoreTransactionID)
      : .unresolved(restoreTransactionID: session.restoreTransactionID)
  }

  if namespaceMutationMayHaveBeenInvoked,
    !descriptorJournalSyncPair(
      request.rootDescriptor,
      request.quarantineRootDescriptor,
      dependencies: dependencies
    )
  {
    return recoveryResult()
  }
  guard outcome != .unresolved else { return recoveryResult() }

  let truthBeforeReceipt: DescriptorRestoreJournalNamespaceTruth
  switch descriptorJournalValidateRestoreTerminalOutcome(
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

  let receipt: QuarantineRestoreJournalReceiptV1
  do {
    switch outcome {
    case .notRestored(let sourceNameWasOccupied):
      receipt = try QuarantineRestoreJournalV1Codec.makeReceipt(
        outcome: .notRestored,
        sourceNameWasOccupied: sourceNameWasOccupied,
        producedByRecovery: false,
        canonicalRestoreIntentBytes: context.canonicalRestoreIntentBytes
      )
    case .restored(let quarantineNameWasRecreated):
      receipt = try QuarantineRestoreJournalV1Codec.makeReceipt(
        outcome: .restored,
        quarantineNameWasRecreated: quarantineNameWasRecreated,
        producedByRecovery: false,
        canonicalRestoreIntentBytes: context.canonicalRestoreIntentBytes
      )
    case .unresolved:
      return recoveryResult()
    }
  } catch {
    return recoveryResult()
  }
  let receiptBytes: Data
  do {
    receiptBytes = try QuarantineRestoreJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: context.canonicalRestoreIntentBytes
    )
  } catch {
    return recoveryResult()
  }
  guard
    let stageName = descriptorJournalRecordName(
      prefix: ".restore-receipt-stage-v1-",
      transactionID: session.restoreTransactionID
    ),
    let finalName = descriptorJournalRecordName(
      prefix: ".restore-receipt-v1-",
      transactionID: session.restoreTransactionID
    )
  else {
    return recoveryResult()
  }
  switch descriptorJournalPublishNewRecord(
    bytes: receiptBytes,
    stageName: stageName,
    finalName: finalName,
    quarantineRootDescriptor: request.quarantineRootDescriptor,
    expectedDevice: session.intent.quarantineRootBinding.device,
    accountUID: request.accountUID,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure, .finalMayExist:
    return recoveryResult()
  }

  switch descriptorJournalValidateHistoricalReceiptParents(
    request,
    expectedRoot: session.intent.npmRootBinding,
    expectedQuarantineRoot: session.intent.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure:
    return recoveryResult()
  }
  switch descriptorJournalObserveRestoreNamespace(
    session.intent,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let truth) where truth == truthBeforeReceipt:
    return .receiptRecorded(receipt)
  case .success, .failure:
    return recoveryResult()
  }
}

private func descriptorJournalValidateRestoreTerminalOutcome(
  _ outcome: DescriptorQuarantineRestoreJournalTerminalOutcome,
  session: DescriptorQuarantineRestoreJournalSession,
  context: DescriptorQuarantineRestoreJournalSession.ProductionContext,
  synchronizeParents: Bool,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<DescriptorRestoreJournalNamespaceTruth, DescriptorQuarantineJournalFailure> {
  let request = context.recoveryRequest
  switch descriptorJournalValidateHistoricalReceiptParents(
    request,
    expectedRoot: session.intent.npmRootBinding,
    expectedQuarantineRoot: session.intent.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure(let failure):
    return .failure(failure)
  }
  let before: DescriptorRestoreJournalNamespaceTruth
  switch descriptorJournalObserveRestoreNamespace(
    session.intent,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let truth):
    before = truth
  case .failure(let failure):
    return .failure(failure)
  }
  guard descriptorJournalRestoreTruth(before, matches: outcome) else {
    return .failure(.recoveryRequired(transactionID: session.restoreTransactionID))
  }
  if synchronizeParents,
    !descriptorJournalSyncPair(
      request.rootDescriptor,
      request.quarantineRootDescriptor,
      dependencies: dependencies
    )
  {
    return .failure(.recoveryRequired(transactionID: session.restoreTransactionID))
  }
  switch descriptorJournalValidateHistoricalReceiptParents(
    request,
    expectedRoot: session.intent.npmRootBinding,
    expectedQuarantineRoot: session.intent.quarantineRootBinding,
    dependencies: dependencies
  ) {
  case .success:
    break
  case .failure:
    return .failure(.recoveryRequired(transactionID: session.restoreTransactionID))
  }
  switch descriptorJournalObserveRestoreNamespace(
    session.intent,
    request: request,
    dependencies: dependencies
  ) {
  case .success(let after) where after == before:
    return .success(after)
  case .success, .failure:
    return .failure(.recoveryRequired(transactionID: session.restoreTransactionID))
  }
}

private func descriptorJournalRestoreFinishFailureIsRecoveryAdmissible(
  _ session: DescriptorQuarantineRestoreJournalSession,
  context: DescriptorQuarantineRestoreJournalSession.ProductionContext,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Bool {
  let request = context.recoveryRequest
  guard
    case .success = descriptorJournalValidateHistoricalReceiptParents(
      request,
      expectedRoot: session.intent.npmRootBinding,
      expectedQuarantineRoot: session.intent.quarantineRootBinding,
      dependencies: dependencies
    )
  else {
    return false
  }
  let inventory: DescriptorJournalInventory
  switch descriptorJournalReadInventory(
    request,
    expectedDevice: session.intent.quarantineRootBinding.device,
    dependencies: dependencies
  ) {
  case .success(let value):
    inventory = value
  case .failure:
    return false
  }
  guard
    inventory.restoreIntentStages[session.restoreTransactionID] == nil,
    let record = inventory.restoreIntents[session.restoreTransactionID],
    record.bytes == context.canonicalRestoreIntentBytes,
    record.value == session.intent,
    case .success = descriptorJournalValidateInventoryStructure(
      inventory,
      maximumPendingIntentCount: 1
    )
  else {
    return false
  }
  return true
}

private func descriptorJournalObserveRestoreNamespace(
  _ intent: QuarantineRestoreJournalIntentV1,
  request: DescriptorQuarantineJournalRecoveryRequest,
  dependencies: DescriptorQuarantineJournalDependencies
) -> Result<DescriptorRestoreJournalNamespaceTruth, DescriptorQuarantineJournalFailure> {
  guard intent.sourceComponents.count == 1 else {
    return .failure(.unsafe)
  }
  let source = descriptorJournalObserveName(
    parentDescriptor: request.rootDescriptor,
    componentBytes: intent.sourceComponents[0],
    expected: intent.candidateBinding,
    matchHistoricalIdentityOnly: true,
    dependencies: dependencies
  )
  let item = descriptorJournalObserveName(
    parentDescriptor: request.quarantineRootDescriptor,
    componentBytes: intent.quarantineItemComponent,
    expected: intent.candidateBinding,
    matchHistoricalIdentityOnly: true,
    dependencies: dependencies
  )
  switch (source, item) {
  case (.success(let source), .success(let quarantineItem)):
    return .success(
      DescriptorRestoreJournalNamespaceTruth(
        source: source,
        quarantineItem: quarantineItem
      ))
  case (.failure(let failure), _), (_, .failure(let failure)):
    return .failure(failure)
  }
}

private func descriptorJournalRestoreTruth(
  _ truth: DescriptorRestoreJournalNamespaceTruth,
  matches outcome: DescriptorQuarantineRestoreJournalTerminalOutcome
) -> Bool {
  switch outcome {
  case .notRestored(sourceNameWasOccupied: false):
    guard case .missing = truth.source, case .expected = truth.quarantineItem else {
      return false
    }
    return true
  case .notRestored(sourceNameWasOccupied: true):
    guard case .other = truth.source, case .expected = truth.quarantineItem else {
      return false
    }
    return true
  case .restored(quarantineNameWasRecreated: false):
    guard case .expected = truth.source, case .missing = truth.quarantineItem else {
      return false
    }
    return true
  case .restored(quarantineNameWasRecreated: true):
    guard case .expected = truth.source, case .other = truth.quarantineItem else {
      return false
    }
    return true
  case .unresolved:
    return false
  }
}

private func descriptorJournalRecoveredRestoreOutcome(
  from truth: DescriptorRestoreJournalNamespaceTruth
) -> DescriptorQuarantineRestoreJournalTerminalOutcome? {
  switch (truth.quarantineItem, truth.source) {
  case (.expected, .missing):
    return .notRestored(sourceNameWasOccupied: false)
  case (.expected, .other):
    return .notRestored(sourceNameWasOccupied: true)
  case (.missing, .expected):
    return .restored(quarantineNameWasRecreated: false)
  case (.other, .expected):
    return .restored(quarantineNameWasRecreated: true)
  default:
    return nil
  }
}

private func descriptorJournalRestoreTerminalOutcome(
  for receipt: QuarantineRestoreJournalReceiptV1
) -> DescriptorQuarantineRestoreJournalTerminalOutcome {
  switch receipt.outcome {
  case .notRestored:
    return .notRestored(sourceNameWasOccupied: receipt.sourceNameWasOccupied)
  case .restored:
    return .restored(quarantineNameWasRecreated: receipt.quarantineNameWasRecreated)
  }
}

private func descriptorJournalMakeRestoreReceipt(
  _ outcome: DescriptorQuarantineRestoreJournalTerminalOutcome,
  producedByRecovery: Bool,
  canonicalIntentBytes: Data
) throws -> QuarantineRestoreJournalReceiptV1 {
  switch outcome {
  case .notRestored(let sourceNameWasOccupied):
    return try QuarantineRestoreJournalV1Codec.makeReceipt(
      outcome: .notRestored,
      sourceNameWasOccupied: sourceNameWasOccupied,
      producedByRecovery: producedByRecovery,
      canonicalRestoreIntentBytes: canonicalIntentBytes
    )
  case .restored(let quarantineNameWasRecreated):
    return try QuarantineRestoreJournalV1Codec.makeReceipt(
      outcome: .restored,
      quarantineNameWasRecreated: quarantineNameWasRecreated,
      producedByRecovery: producedByRecovery,
      canonicalRestoreIntentBytes: canonicalIntentBytes
    )
  case .unresolved:
    throw QuarantineRestoreJournalCodecError.invalidReceiptRelationships
  }
}

/// Reaches the journal without reopening `_cacache`. This is the startup path
/// used after a successful move removed that source name. It only opens an
/// existing npm and quarantine root and never creates either directory.
struct DescriptorNPMQuarantineRecovery: Sendable {
  typealias RawHomeProvider = @Sendable () -> RuleObserved<[UInt8]>
  typealias AccountUIDProvider = @Sendable () -> RuleObserved<uid_t>

  private let journal: DescriptorQuarantineJournal
  private let rawHomeProvider: RawHomeProvider
  private let accountUIDProvider: AccountUIDProvider
  private let supportsDurableMutation: @Sendable () -> Bool

  init(
    journal: DescriptorQuarantineJournal = DescriptorQuarantineJournal(),
    rawHomeProvider: @escaping RawHomeProvider = { currentUIDRawHome() },
    accountUIDProvider: @escaping AccountUIDProvider = { currentNonRootAccountUID() },
    supportsDurableMutation: @escaping @Sendable () -> Bool = {
      ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
      )
    }
  ) {
    self.journal = journal
    self.rawHomeProvider = rawHomeProvider
    self.accountUIDProvider = accountUIDProvider
    self.supportsDurableMutation = supportsDurableMutation
  }

  func recover() -> DescriptorQuarantineJournalRecoveryResult {
    let accountUID: uid_t
    switch accountUIDProvider() {
    case .known(let value) where value != 0:
      accountUID = value
    case .known, .unknown:
      return .failure(.unsafe)
    }
    guard Darwin.getuid() == accountUID, Darwin.geteuid() == accountUID else {
      return .failure(.unsafe)
    }

    let rawHome: [UInt8]
    switch rawHomeProvider() {
    case .known(let value):
      rawHome = value
    case .unknown:
      return .failure(.unsafe)
    }
    guard let homePath = DescriptorAbsolutePath(rawBytes: rawHome),
      !homePath.components.isEmpty,
      let npmComponent = DescriptorPathComponent(Array(".npm".utf8)),
      let quarantineComponent = DescriptorPathComponent(
        DescriptorExclusiveQuarantineMover.quarantineRootBytes
      )
    else {
      return .failure(.unsafe)
    }

    let slashDescriptor: Int32
    do {
      slashDescriptor = try descriptorOpenRoot(
        URL(fileURLWithPath: "/", isDirectory: true),
        cancellationPolicy: .ignoreTaskCancellation
      )
    } catch {
      return .failure(.unavailable(descriptorJournalFailure(for: error)))
    }
    var traversalDescriptor = slashDescriptor
    defer { descriptorCloseIgnoringErrors(traversalDescriptor) }

    do {
      for component in homePath.components {
        let child = try descriptorOpenTrustedDirectory(
          at: traversalDescriptor,
          component: component,
          cancellationPolicy: .ignoreTaskCancellation
        )
        descriptorCloseIgnoringErrors(traversalDescriptor)
        traversalDescriptor = child
      }
    } catch {
      return .failure(.unavailable(descriptorJournalFailure(for: error)))
    }

    let homeSnapshot: DescriptorStatSnapshot
    do {
      homeSnapshot = try DescriptorStatSnapshot.read(
        from: traversalDescriptor,
        cancellationPolicy: .ignoreTaskCancellation
      )
      guard
        homeSnapshot.kind == .directory,
        homeSnapshot.ownerUID == accountUID,
        homeSnapshot.permissionMode & mode_t(0o022) == 0,
        homeSnapshot.flags == 0
      else {
        return .failure(.unsafe)
      }
    } catch {
      return .failure(.unavailable(descriptorJournalFailure(for: error)))
    }

    let rootDescriptor: Int32
    do {
      rootDescriptor = try descriptorOpenTrustedDirectory(
        at: traversalDescriptor,
        component: npmComponent,
        cancellationPolicy: .ignoreTaskCancellation
      )
    } catch DescriptorObservationError.posix(ENOENT) {
      return descriptorJournalEmptyRecoveryResult()
    } catch {
      return .failure(.unavailable(descriptorJournalFailure(for: error)))
    }
    defer { descriptorCloseIgnoringErrors(rootDescriptor) }

    do {
      let root = try DescriptorStatSnapshot.read(
        from: rootDescriptor,
        cancellationPolicy: .ignoreTaskCancellation
      )
      let namedRoot = try DescriptorStatSnapshot.read(
        at: traversalDescriptor,
        component: npmComponent,
        cancellationPolicy: .ignoreTaskCancellation
      )
      guard
        root.sameBinding(as: namedRoot),
        root.sameMutationState(as: namedRoot),
        root.ownerUID == namedRoot.ownerUID,
        root.permissionMode == namedRoot.permissionMode,
        root.flags == namedRoot.flags,
        root.linkCount == namedRoot.linkCount,
        root.kind == .directory,
        root.identity.device == homeSnapshot.identity.device,
        root.ownerUID == accountUID,
        root.permissionMode & mode_t(0o022) == 0,
        root.flags == 0,
        try !descriptorHasExtendedACL(rootDescriptor)
      else {
        return .failure(.unsafe)
      }
    } catch {
      return .failure(.unavailable(descriptorJournalFailure(for: error)))
    }

    let quarantineDescriptor: Int32
    do {
      quarantineDescriptor = try descriptorOpenTrustedDirectory(
        at: rootDescriptor,
        component: quarantineComponent,
        cancellationPolicy: .ignoreTaskCancellation
      )
    } catch DescriptorObservationError.posix(ENOENT) {
      return descriptorJournalEmptyRecoveryResult()
    } catch {
      return .failure(.unavailable(descriptorJournalFailure(for: error)))
    }
    defer { descriptorCloseIgnoringErrors(quarantineDescriptor) }

    guard supportsDurableMutation() else {
      return .failure(.unavailable(.unsupported))
    }
    do {
      let quarantine = try DescriptorStatSnapshot.read(
        from: quarantineDescriptor,
        cancellationPolicy: .ignoreTaskCancellation
      )
      let namedQuarantine = try DescriptorStatSnapshot.read(
        at: rootDescriptor,
        component: quarantineComponent,
        cancellationPolicy: .ignoreTaskCancellation
      )
      guard
        quarantine.sameBinding(as: namedQuarantine),
        quarantine.sameMutationState(as: namedQuarantine),
        quarantine.ownerUID == namedQuarantine.ownerUID,
        quarantine.permissionMode == namedQuarantine.permissionMode,
        quarantine.flags == namedQuarantine.flags,
        quarantine.linkCount == namedQuarantine.linkCount,
        quarantine.kind == .directory,
        quarantine.identity.device == homeSnapshot.identity.device,
        quarantine.ownerUID == accountUID,
        quarantine.permissionMode == mode_t(0o700),
        quarantine.flags == 0,
        try !descriptorHasExtendedACL(quarantineDescriptor)
      else {
        return .failure(.unsafe)
      }
    } catch {
      return .failure(.unavailable(descriptorJournalFailure(for: error)))
    }

    return journal.recover(
      DescriptorQuarantineJournalRecoveryRequest(
        rootDescriptor: rootDescriptor,
        quarantineRootDescriptor: quarantineDescriptor,
        quarantineRootComponent: quarantineComponent,
        absoluteRootComponents: homePath.components + [npmComponent],
        homeComponentCount: homePath.components.count,
        accountUID: accountUID
      ))
  }
}

private func descriptorJournalEmptyRecoveryResult()
  -> DescriptorQuarantineJournalRecoveryResult
{
  .success(
    DescriptorQuarantineJournalRecoverySummary(
      recoveredReceipts: [],
      validatedTransactionCount: 0
    ))
}
