import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor quarantine journal")
struct DescriptorQuarantineJournalTests {
  @Test("Intent and receipt publication are immutable and hold one exclusive session")
  func publishesIntentAndReceiptUnderLock() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let lockEvents = DescriptorJournalTestCounter()
    let dependencies = descriptorJournalTestDependencies(
      hooks: DescriptorQuarantineJournalHooks(
        didAcquireLock: { _ = lockEvents.result() }
      )
    )
    let journal = DescriptorQuarantineJournal(
      dependencies: dependencies
    )
    let beginRequest = fixture.beginRequest()
    switch descriptorJournalValidateBeginBindings(
      beginRequest,
      dependencies: descriptorJournalTestDependencies()
    ) {
    case .success:
      break
    case .failure(let failure):
      Issue.record("pre-lock validation failed: \(failure)")
    }

    let session: DescriptorQuarantineJournalSession
    switch journal.begin(beginRequest) {
    case .success(let value):
      session = value
    case .failure(let failure):
      let names = try FileManager.default.contentsOfDirectory(
        atPath: fixture.quarantineURL.path
      )
      let details =
        "begin failed: \(failure), lock events: \(lockEvents.callCount), "
        + "entries: \(names.sorted())"
      Issue.record(Comment(rawValue: details))
      return
    }
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      ))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)").path
      ))

    let secondIntent = try fixture.intent(
      transactionID: String(repeating: "b", count: 32),
      destinationSeed: 100
    )
    switch journal.begin(fixture.beginRequest(intent: secondIntent)) {
    case .failure(.busy):
      break
    case .failure(let failure):
      Issue.record("expected busy, got \(failure)")
    case .success:
      Issue.record("a second session acquired the held journal lock")
    }

    let receipt: QuarantineJournalReceiptV1
    switch journal.finish(
      session,
      outcome: .notMoved,
      namespaceMutationMayHaveBeenInvoked: false
    ) {
    case .receiptRecorded(let value):
      receipt = value
    case .recoveryRequired(let transactionID):
      Issue.record("finish requires recovery: \(transactionID)")
      return
    case .unresolved(let transactionID):
      Issue.record("finish is not automatically recoverable: \(transactionID)")
      return
    case .invalidSession:
      Issue.record("fresh session was rejected")
      return
    }
    #expect(receipt.outcome == .notMoved)
    #expect(!receipt.producedByRecovery)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
      ))
    #expect(
      journal.finish(
        session,
        outcome: .notMoved,
        namespaceMutationMayHaveBeenInvoked: false
      ) == .invalidSession
    )

    let intentBytes = try Data(
      contentsOf: fixture.recordURL(".intent-v1-\(fixture.transactionID)")
    )
    let receiptBytes = try Data(
      contentsOf: fixture.recordURL(".receipt-v1-\(fixture.transactionID)")
    )
    #expect(
      try QuarantineJournalV1Codec.decodeReceipt(
        receiptBytes,
        matchingIntentBytes: intentBytes
      ) == receipt
    )
  }

  @Test("A pre-intent sync failure cannot publish final intent")
  func preIntentSyncFailureCannotPublishIntent() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let syncs = DescriptorJournalTestCounter(failingCall: 3)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies(fullSync: { _ in syncs.result() })
    )

    switch journal.begin(fixture.beginRequest()) {
    case .failure(.unavailable(.inputOutput)):
      break
    case .failure(let failure):
      Issue.record("unexpected failure: \(failure)")
    case .success:
      Issue.record("begin succeeded after its required bootstrap sync failed")
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      ))
    #expect(syncs.callCount == 4)
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("A post-rename publication barrier failure retains a recoverable final intent")
  func finalIntentBarrierFailureRequiresRecovery() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let syncs = DescriptorJournalTestCounter(failingCall: 6)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies(fullSync: { _ in syncs.result() })
    )

    switch journal.begin(fixture.beginRequest()) {
    case .failure(.recoveryRequired(let transactionID)):
      #expect(transactionID == fixture.transactionID)
    case .failure(let failure):
      Issue.record("unexpected failure: \(failure)")
    case .success:
      Issue.record("begin claimed durable success after its directory barrier failed")
    }
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      ))
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("An unresolved finish synchronizes a possibly mutated namespace and writes no receipt")
  func unresolvedFinishLeavesOnlyIntent() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let syncs = DescriptorJournalTestCounter()
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies(fullSync: { _ in syncs.result() })
    )
    let session = try fixture.requireSession(from: journal)
    let countBeforeFinish = syncs.callCount

    #expect(
      journal.finish(
        session,
        outcome: .unresolved,
        namespaceMutationMayHaveBeenInvoked: true
      ) == .recoveryRequired(transactionID: fixture.transactionID)
    )
    #expect(syncs.callCount >= countBeforeFinish + 2)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
      ))
  }

  @Test("An ambiguous namespace retains reachable canonical intent evidence")
  func ambiguousNamespaceRemainsCrashReconciliationAdmissible() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let session = try fixture.requireSession(from: journal)
    let unplanned = fixture.baseURL.appendingPathComponent("unplanned-candidate")
    try FileManager.default.moveItem(at: fixture.candidateURL, to: unplanned)

    #expect(
      journal.finish(
        session,
        outcome: .unresolved,
        namespaceMutationMayHaveBeenInvoked: true
      ) == .recoveryRequired(transactionID: fixture.transactionID)
    )
    #expect(
      journal.recover(fixture.recoveryRequest())
        == .failure(.recoveryRequired(transactionID: fixture.transactionID))
    )
    #expect(FileManager.default.fileExists(atPath: unplanned.path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      )
    )
  }

  @Test("A later intent cannot reuse a prior transaction destination plan")
  func rejectsDestinationReservationReuse() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let first = try fixture.requireSession(from: journal)
    _ = journal.finish(
      first,
      outcome: .notMoved,
      namespaceMutationMayHaveBeenInvoked: false
    )
    let overlapping = try fixture.intent(
      transactionID: String(repeating: "c", count: 32),
      destinationSeed: 0
    )

    switch journal.begin(fixture.beginRequest(intent: overlapping)) {
    case .failure(.unsafe):
      break
    case .failure(let failure):
      Issue.record("unexpected failure: \(failure)")
    case .success:
      Issue.record("overlapping destination reservations were accepted")
    }
  }

  @Test("Reservation reread rejects a concurrently introduced orphan receipt")
  func reservationRereadRejectsOrphanReceipt() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let orphanTransactionID = String(repeating: "b", count: 32)
    let orphanIntentBytes = try QuarantineJournalV1Codec.encode(
      fixture.intent(transactionID: orphanTransactionID, destinationSeed: 100)
    )
    let orphanReceipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: orphanIntentBytes
    )
    let orphanBytes = try QuarantineJournalV1Codec.encode(
      orphanReceipt,
      matchingIntentBytes: orphanIntentBytes
    )
    let orphanURL = fixture.recordURL(".receipt-v1-\(orphanTransactionID)")
    let inventoryReads = DescriptorJournalTestCallGate()
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies(
        hooks: DescriptorQuarantineJournalHooks(
          willReadInventory: {
            inventoryReads.run(onCall: 2) {
              try? orphanBytes.write(to: orphanURL, options: [])
              try? descriptorJournalTestChmod(orphanURL, mode: 0o600)
            }
          }
        )
      )
    )

    switch journal.begin(fixture.beginRequest()) {
    case .failure(.unsafe):
      break
    case .failure(let failure):
      Issue.record("unexpected failure: \(failure)")
    case .success:
      Issue.record("a new intent was published over an orphan receipt")
    }
    #expect(inventoryReads.callCount == 2)
    #expect(try Data(contentsOf: orphanURL) == orphanBytes)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      )
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("A new intent cannot use a historical policy revision")
  func rejectsHistoricalPolicyForNewIntent() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let historicalIntent = try fixture.intent(policy: descriptorJournalTestHistoricalPolicy())

    switch journal.begin(fixture.beginRequest(intent: historicalIntent)) {
    case .failure(.unsafe):
      break
    case .failure(let failure):
      Issue.record("unexpected failure: \(failure)")
    case .success:
      Issue.record("a stale policy was admitted for a new transaction")
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.recordURL(".lock-v1").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      )
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test(
    "Every required full-sync position fails closed",
    arguments: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
  )
  func fullSyncFailureSweep(failurePosition: Int) throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let syncs = DescriptorJournalTestSyncProbe(failingCall: failurePosition)
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies(fullSync: { descriptor in
        syncs.result(for: descriptor)
      })
    )

    switch journal.begin(fixture.beginRequest()) {
    case .failure:
      #expect(failurePosition <= 7)
    case .success(let session):
      #expect(failurePosition >= 8)
      #expect(
        journal.finish(
          session,
          outcome: .notMoved,
          namespaceMutationMayHaveBeenInvoked: true
        ) == .recoveryRequired(transactionID: fixture.transactionID)
      )
    }

    let expectedCallCount =
      [1, 3, 8, 10].contains(failurePosition)
      ? failurePosition + 1
      : failurePosition
    #expect(syncs.descriptors.count == expectedCallCount)
    for parentPairStart in [3, 8, 10] where failurePosition == parentPairStart {
      #expect(
        Array(syncs.descriptors[(parentPairStart - 1)...parentPairStart])
          == [fixture.rootDescriptor, fixture.quarantineDescriptor]
      )
    }
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
    if failurePosition <= 12 {
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
        )
      )
    }
  }

  @Test("An injected interrupted write is not mistaken for a complete record")
  func interruptedWriteFailsClosedAndPreservesStage() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let writes = DescriptorJournalTestCounter()
    var dependencies = descriptorJournalTestDependencies()
    dependencies.writeAll = { _, _ in
      _ = writes.result()
      return EINTR
    }
    let journal = DescriptorQuarantineJournal(dependencies: dependencies)

    switch journal.begin(fixture.beginRequest()) {
    case .failure(.unavailable(.inputOutput)):
      break
    case .failure(let failure):
      Issue.record("unexpected failure: \(failure)")
    case .success:
      Issue.record("begin accepted a failed record write")
    }

    let stageURL = fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)")
    #expect(writes.callCount == 1)
    #expect(try Data(contentsOf: stageURL).isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      )
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("A short write followed by an error preserves the partial stage")
  func partialWriteFailurePreservesPrefixWithoutPublishing() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let expectedIntentBytes = try QuarantineJournalV1Codec.encode(fixture.intent())
    var dependencies = descriptorJournalTestDependencies()
    dependencies.writeAll = { descriptor, bytes in
      descriptorJournalTestWritePrefix(
        descriptor: descriptor,
        bytes: bytes,
        byteCount: bytes.count / 2
      ) ?? EIO
    }
    let journal = DescriptorQuarantineJournal(dependencies: dependencies)

    switch journal.begin(fixture.beginRequest()) {
    case .failure(.unavailable(.inputOutput)):
      break
    case .failure(let failure):
      Issue.record("unexpected failure: \(failure)")
    case .success:
      Issue.record("begin accepted a partial record write")
    }

    let stageURL = fixture.recordURL(".intent-stage-v1-\(fixture.transactionID)")
    let stageBytes = try Data(contentsOf: stageURL)
    #expect(stageBytes == expectedIntentBytes.prefix(expectedIntentBytes.count / 2))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      )
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("A malformed partial receipt stage makes automatic recovery inadmissible")
  func receiptWriteFailureIsUnresolved() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let writer = DescriptorJournalTestWriter(failingCall: 2)
    var dependencies = descriptorJournalTestDependencies()
    dependencies.writeAll = { descriptor, bytes in
      writer.write(descriptor: descriptor, bytes: bytes)
    }
    let journal = DescriptorQuarantineJournal(dependencies: dependencies)
    let session = try fixture.requireSession(from: journal)

    #expect(
      journal.finish(
        session,
        outcome: .notMoved,
        namespaceMutationMayHaveBeenInvoked: false
      ) == .unresolved(transactionID: fixture.transactionID)
    )
    #expect(writer.callCount == 2)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.recordURL(".intent-v1-\(fixture.transactionID)").path
      )
    )
    #expect(
      try Data(
        contentsOf: fixture.recordURL(".receipt-stage-v1-\(fixture.transactionID)")
      ).isEmpty
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
      )
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
    #expect(journal.recover(fixture.recoveryRequest()) == .failure(.unsafe))
  }

  @Test("A detached quarantine root cannot retain crash-recoverable status")
  func detachedQuarantineRootMakesFinishUnresolved() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let journal = DescriptorQuarantineJournal(
      dependencies: descriptorJournalTestDependencies()
    )
    let session = try fixture.requireSession(from: journal)
    let detachedRoot = fixture.rootURL.appendingPathComponent("detached-quarantine")
    try FileManager.default.moveItem(at: fixture.quarantineURL, to: detachedRoot)
    try FileManager.default.createDirectory(
      at: fixture.quarantineURL,
      withIntermediateDirectories: false
    )
    try descriptorJournalTestChmod(fixture.quarantineURL, mode: 0o700)

    #expect(
      journal.finish(
        session,
        outcome: .notMoved,
        namespaceMutationMayHaveBeenInvoked: false
      ) == .unresolved(transactionID: fixture.transactionID)
    )
    #expect(
      FileManager.default.fileExists(
        atPath:
          detachedRoot
          .appendingPathComponent(".intent-v1-\(fixture.transactionID)").path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath:
          detachedRoot
          .appendingPathComponent(".receipt-v1-\(fixture.transactionID)").path
      )
    )
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("Production write-all stops after three consecutive interruptions")
  func writeAllBoundsConsecutiveInterruptions() {
    var callCount = 0
    let failure = descriptorJournalWriteAll(-1, Data([1, 2, 3])) { _, _, _ in
      callCount += 1
      errno = EINTR
      return -1
    }

    #expect(failure == EINTR)
    #expect(callCount == 3)
  }

  @Test("Production write-all advances through short writes")
  func writeAllAdvancesAfterShortWrites() {
    let expected = Data([1, 2, 3, 4, 5, 6, 7])
    var observed = Data()
    var requestedByteCounts: [Int] = []
    let failure = descriptorJournalWriteAll(-1, expected) { _, pointer, byteCount in
      requestedByteCounts.append(byteCount)
      let progress = min(3, byteCount)
      observed.append(pointer.assumingMemoryBound(to: UInt8.self), count: progress)
      return progress
    }

    #expect(failure == nil)
    #expect(observed == expected)
    #expect(requestedByteCounts == [7, 4, 1])
  }

  @Test("Write progress resets the consecutive interruption budget")
  func writeAllResetsInterruptionBudgetAfterProgress() {
    let expected = Data([1, 2, 3, 4, 5])
    var observed = Data()
    var callCount = 0
    let failure = descriptorJournalWriteAll(-1, expected) { _, pointer, byteCount in
      callCount += 1
      switch callCount {
      case 1, 4:
        observed.append(pointer.assumingMemoryBound(to: UInt8.self), count: 1)
        return 1
      case 2, 3, 5:
        errno = EINTR
        return -1
      default:
        observed.append(pointer.assumingMemoryBound(to: UInt8.self), count: byteCount)
        return byteCount
      }
    }

    #expect(failure == nil)
    #expect(callCount == 6)
    #expect(observed == expected)
  }
}

final class DescriptorJournalTestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var callCount = 0
  private let failingCall: Int?

  init(failingCall: Int? = nil) {
    self.failingCall = failingCall
  }

  func result() -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    callCount += 1
    return callCount == failingCall ? EIO : nil
  }
}

final class DescriptorJournalTestSyncProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let failingCall: Int
  private var recordedDescriptors: [Int32] = []

  init(failingCall: Int) {
    self.failingCall = failingCall
  }

  var descriptors: [Int32] {
    lock.lock()
    defer { lock.unlock() }
    return recordedDescriptors
  }

  func result(for descriptor: Int32) -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    recordedDescriptors.append(descriptor)
    return recordedDescriptors.count == failingCall ? EIO : nil
  }
}

final class DescriptorJournalTestWriter: @unchecked Sendable {
  private let lock = NSLock()
  private let failingCall: Int
  private var recordedCallCount = 0

  init(failingCall: Int) {
    self.failingCall = failingCall
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recordedCallCount
  }

  func write(descriptor: Int32, bytes: Data) -> Int32? {
    lock.lock()
    recordedCallCount += 1
    let shouldFail = recordedCallCount == failingCall
    lock.unlock()
    if shouldFail { return EIO }
    return descriptorJournalTestWritePrefix(
      descriptor: descriptor,
      bytes: bytes,
      byteCount: bytes.count
    )
  }
}

final class DescriptorJournalTestOneShot: @unchecked Sendable {
  private let lock = NSLock()
  private var hasRun = false

  func run(_ operation: () -> Void) {
    lock.lock()
    guard !hasRun else {
      lock.unlock()
      return
    }
    hasRun = true
    operation()
    lock.unlock()
  }
}

final class DescriptorJournalTestCallGate: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCallCount = 0

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recordedCallCount
  }

  func run(onCall selectedCall: Int, _ operation: () -> Void) {
    lock.lock()
    recordedCallCount += 1
    let shouldRun = recordedCallCount == selectedCall
    lock.unlock()
    if shouldRun { operation() }
  }
}

final class DescriptorJournalTestFixture {
  let baseURL: URL
  let rootURL: URL
  let quarantineURL: URL
  let candidateURL: URL
  let transactionID = String(repeating: "a", count: 32)
  let accountUID = Darwin.getuid()
  let rootDescriptor: Int32
  let quarantineDescriptor: Int32
  let candidateDescriptor: Int32
  let absoluteRootComponents: [DescriptorPathComponent]
  let homeComponentCount: Int
  private var removed = false

  init(createCandidate: Bool = true, createQuarantine: Bool = true) throws {
    baseURL = URL(
      fileURLWithPath: "/private/tmp/devsift-journal-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    rootURL = baseURL.appendingPathComponent(".npm", isDirectory: true)
    quarantineURL = rootURL.appendingPathComponent(
      ".devsift-quarantine-v1",
      isDirectory: true
    )
    candidateURL = rootURL.appendingPathComponent("_cacache", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try descriptorJournalTestChmod(baseURL, mode: 0o700)
    try descriptorJournalTestChmod(rootURL, mode: 0o700)
    if createQuarantine {
      try FileManager.default.createDirectory(at: quarantineURL, withIntermediateDirectories: false)
      try descriptorJournalTestChmod(quarantineURL, mode: 0o700)
    }
    if createCandidate {
      try FileManager.default.createDirectory(at: candidateURL, withIntermediateDirectories: false)
      try descriptorJournalTestChmod(candidateURL, mode: 0o700)
    }

    rootDescriptor = Darwin.open(
      rootURL.path,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard rootDescriptor >= 0 else { throw DescriptorJournalTestError.posix(errno) }
    if createQuarantine {
      quarantineDescriptor = Darwin.open(
        quarantineURL.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard quarantineDescriptor >= 0 else {
        descriptorCloseIgnoringErrors(rootDescriptor)
        throw DescriptorJournalTestError.posix(errno)
      }
    } else {
      quarantineDescriptor = -1
    }
    if createCandidate {
      candidateDescriptor = Darwin.open(
        candidateURL.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard candidateDescriptor >= 0 else {
        descriptorCloseIgnoringErrors(quarantineDescriptor)
        descriptorCloseIgnoringErrors(rootDescriptor)
        throw DescriptorJournalTestError.posix(errno)
      }
    } else {
      candidateDescriptor = -1
    }
    guard let rawRoot = descriptorAbsolutePath(for: rootURL),
      let components = descriptorComponents(rawRoot.rawComponents),
      components.count > 1
    else {
      throw DescriptorJournalTestError.invalidPath
    }
    absoluteRootComponents = components
    homeComponentCount = components.count - 1
  }

  func intent(
    transactionID: String? = nil,
    destinationSeed: Int = 0,
    policy: QuarantineJournalPolicyV1 = .current
  ) throws -> QuarantineJournalIntentV1 {
    let root = try DescriptorStatSnapshot.read(
      from: rootDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    let quarantine = try DescriptorStatSnapshot.read(
      from: quarantineDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    let candidate = try DescriptorStatSnapshot.read(
      from: candidateDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    guard let rootBinding = QuarantineJournalFileBindingV1(snapshot: root),
      let quarantineBinding = QuarantineJournalFileBindingV1(snapshot: quarantine),
      let candidateBinding = QuarantineJournalFileBindingV1(snapshot: candidate)
    else {
      throw DescriptorJournalTestError.invalidSnapshot
    }
    return QuarantineJournalIntentV1(
      transactionID: transactionID ?? self.transactionID,
      npmRootBinding: rootBinding,
      quarantineRootBinding: quarantineBinding,
      candidateBinding: candidateBinding,
      sourceComponents: [Array("_cacache".utf8)],
      destinationComponents: (0..<16).map { ordinal in
        Array("item-v1-\(String(format: "%032x", destinationSeed + ordinal + 1))".utf8)
      },
      policy: policy
    )
  }

  func beginRequest(
    intent: QuarantineJournalIntentV1? = nil
  ) -> DescriptorQuarantineJournalBeginRequest {
    DescriptorQuarantineJournalBeginRequest(
      rootDescriptor: rootDescriptor,
      quarantineRootDescriptor: quarantineDescriptor,
      candidateDescriptor: candidateDescriptor,
      quarantineRootComponent: DescriptorPathComponent(
        Array(".devsift-quarantine-v1".utf8)
      )!,
      absoluteRootComponents: absoluteRootComponents,
      homeComponentCount: homeComponentCount,
      accountUID: accountUID,
      intent: try! intent ?? self.intent()
    )
  }

  func recoveryRequest() -> DescriptorQuarantineJournalRecoveryRequest {
    DescriptorQuarantineJournalRecoveryRequest(
      rootDescriptor: rootDescriptor,
      quarantineRootDescriptor: quarantineDescriptor,
      quarantineRootComponent: DescriptorPathComponent(
        Array(".devsift-quarantine-v1".utf8)
      )!,
      absoluteRootComponents: absoluteRootComponents,
      homeComponentCount: homeComponentCount,
      accountUID: accountUID
    )
  }

  func requireSession(
    from journal: DescriptorQuarantineJournal
  ) throws -> DescriptorQuarantineJournalSession {
    switch journal.begin(beginRequest()) {
    case .success(let session):
      return session
    case .failure(let failure):
      throw DescriptorJournalTestError.begin(failure)
    }
  }

  func recordURL(_ name: String) -> URL {
    quarantineURL.appendingPathComponent(name)
  }

  func remove() {
    guard !removed else { return }
    removed = true
    if candidateDescriptor >= 0 { descriptorCloseIgnoringErrors(candidateDescriptor) }
    if quarantineDescriptor >= 0 { descriptorCloseIgnoringErrors(quarantineDescriptor) }
    if rootDescriptor >= 0 { descriptorCloseIgnoringErrors(rootDescriptor) }
    try? FileManager.default.removeItem(at: baseURL)
  }

  deinit {
    remove()
  }
}

enum DescriptorJournalTestError: Error {
  case begin(DescriptorQuarantineJournalFailure)
  case invalidPath
  case invalidSnapshot
  case posix(Int32)
}

func descriptorJournalTestDependencies(
  fullSync: @escaping @Sendable (Int32) -> Int32? = { _ in nil },
  hooks: DescriptorQuarantineJournalHooks = DescriptorQuarantineJournalHooks()
) -> DescriptorQuarantineJournalDependencies {
  DescriptorQuarantineJournalDependencies(
    fullSync: fullSync,
    renameExclusive: descriptorJournalTestRenameExclusive,
    hooks: hooks
  )
}

func descriptorJournalTestRenameExclusive(
  quarantineRootDescriptor: Int32,
  source: DescriptorPathComponent,
  destination: DescriptorPathComponent,
  flags: UInt32
) -> DescriptorExclusiveRenameResult {
  let supportsFlag = ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
  )
  let effectiveFlags =
    supportsFlag
    ? flags
    : flags & ~DescriptorExclusiveQuarantineMover.resolveBeneathRenameFlag
  var failureCode = Int32(EINVAL)
  let result = source.withCString { sourcePointer in
    destination.withCString { destinationPointer in
      let status = Darwin.renameatx_np(
        quarantineRootDescriptor,
        sourcePointer,
        quarantineRootDescriptor,
        destinationPointer,
        effectiveFlags
      )
      if status != 0 { failureCode = errno }
      return status
    }
  }
  return result == 0 ? .succeeded : .failed(failureCode)
}

func descriptorJournalTestChmod(_ url: URL, mode: mode_t) throws {
  guard Darwin.chmod(url.path, mode) == 0 else {
    throw DescriptorJournalTestError.posix(errno)
  }
}

func descriptorJournalTestHistoricalPolicy() -> QuarantineJournalPolicyV1 {
  let current = QuarantineJournalPolicyV1.current
  return QuarantineJournalPolicyV1(
    classification: current.classification,
    catalog: QuarantineJournalPolicyRevisionV1(
      identifier: current.catalog.identifier,
      version: current.catalog.version - 1
    ),
    npmRule: current.npmRule
  )
}

func descriptorJournalTestWritePrefix(
  descriptor: Int32,
  bytes: Data,
  byteCount: Int
) -> Int32? {
  guard byteCount >= 0, byteCount <= bytes.count else { return EINVAL }
  return bytes.withUnsafeBytes { buffer in
    guard byteCount > 0 else { return nil }
    let result = Darwin.write(descriptor, buffer.baseAddress!, byteCount)
    guard result == byteCount else {
      return result < 0 ? errno : EIO
    }
    return nil
  }
}
