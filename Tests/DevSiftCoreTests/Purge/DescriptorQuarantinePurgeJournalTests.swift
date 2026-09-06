import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor quarantine purge journal", .serialized)
struct DescriptorQuarantinePurgeJournalTests {
  @Test("Exact canonical quarantine evidence publishes one final purge intent and retains the lock")
  func publishesExactDurableIntent() async throws {
    let fixture = try PurgeJournalFixture()
    defer { fixture.remove() }
    let recorder = PurgeJournalPublicationRecorder()
    let dependencies = descriptorJournalTestDependencies(
      hooks: DescriptorQuarantineJournalHooks(
        didCreateStage: { recorder.createdStage($0) },
        willPublishStage: { recorder.willPublish(stage: $0, final: $1) },
        didPublishFinal: { recorder.publishedFinal($0) }
      )
    )
    let journal = DescriptorQuarantinePurgeJournal(
      dependencies: DescriptorQuarantinePurgeJournalDependencies(journal: dependencies)
    )

    let result = journal.begin(
      DescriptorQuarantinePurgeJournalBeginRequest(
        recoveryRequest: fixture.filesystem.recoveryRequest(),
        quarantinedItemDescriptor: fixture.filesystem.candidateDescriptor,
        claim: try await fixture.claim()
      )
    )

    guard case .success(let session) = result else {
      Issue.record("Expected a durable purge-intent session, got \(result)")
      return
    }
    defer { session.releasePreservingIntent() }
    #expect(session.purgeTransactionID == fixture.purgeIntent.purgeTransactionID)
    #expect(session.quarantineTransactionID == fixture.quarantineIntent.transactionID)
    #expect(session.intent == fixture.purgeIntent)
    #expect(session.canonicalIntentBytes == fixture.purgeIntentBytes)
    guard case .production(let context) = session.payload else {
      Issue.record("Expected production journal context")
      return
    }
    #expect(context.canonicalQuarantineIntentBytes == fixture.quarantineIntentBytes)
    #expect(context.canonicalQuarantineReceiptBytes == fixture.quarantineReceiptBytes)
    #expect(context.canonicalPurgeIntentBytes == fixture.purgeIntentBytes)

    let finalURL = fixture.purgeRecordURL(prefix: ".purge-intent-v1-")
    let stageURL = fixture.purgeRecordURL(prefix: ".purge-intent-stage-v1-")
    let workURL = try fixture.purgeWorkURL()
    #expect(try Data(contentsOf: finalURL) == fixture.purgeIntentBytes)
    #expect(!FileManager.default.fileExists(atPath: stageURL.path))
    #expect(!FileManager.default.fileExists(atPath: workURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.quarantineItemURL.path))
    #expect(recorder.createdStageNames == [stageURL.lastPathComponent])
    #expect(recorder.publishPairs.count == 1)
    #expect(recorder.publishPairs.first?.0 == stageURL.lastPathComponent)
    #expect(recorder.publishPairs.first?.1 == finalURL.lastPathComponent)
    #expect(recorder.publishedFinalNames == [finalURL.lastPathComponent])

    let competing = DescriptorQuarantineJournal(dependencies: dependencies)
    #expect(
      competing.recover(fixture.filesystem.recoveryRequest())
        == .failure(.busy)
    )
  }

  @Test("A real same-directory rename is accepted despite its legitimate ctime change")
  func realRenameAcceptsPostRenameMetadata() async throws {
    let fixture = try PurgeJournalFixture()
    defer { fixture.remove() }
    let claim = try await fixture.claim()
    let journal = DescriptorQuarantinePurgeJournal(
      dependencies: DescriptorQuarantinePurgeJournalDependencies(
        journal: descriptorJournalTestDependencies()
      )
    )
    let recoveryRequest = fixture.filesystem.recoveryRequest()
    let begin = journal.begin(
      DescriptorQuarantinePurgeJournalBeginRequest(
        recoveryRequest: recoveryRequest,
        quarantinedItemDescriptor: fixture.filesystem.candidateDescriptor,
        claim: claim
      )
    )
    guard case .success(let session) = begin else {
      Issue.record("Expected a durable purge-intent session, got \(begin)")
      return
    }
    defer { session.releasePreservingIntent() }

    let beforeRename = try DescriptorStatSnapshot.read(
      from: fixture.filesystem.candidateDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    let accountUID = fixture.filesystem.accountUID
    let stager = DescriptorExclusiveQuarantinePurgeStager(
      dependencies: DescriptorExclusiveQuarantinePurgeStagerDependencies(
        currentAccountUID: { accountUID },
        supportsResolveBeneathRename: { true },
        volumeCapabilities: { _ in
          .success(
            DescriptorQuarantineVolumeCapabilities(
              supportsExclusiveRename: true,
              supportsPOSIXPermissions: true
            )
          )
        },
        renameExclusive: purgeJournalTestRename,
        fullSync: { _ in nil },
        journal: DescriptorQuarantinePurgeJournal(begin: { _ in .success(session) })
      )
    )
    let result = stager.stage(
      DescriptorNPMQuarantinePurgeStagingScope(
        heldRootDescriptor: fixture.filesystem.rootDescriptor,
        heldQuarantineRootDescriptor: fixture.filesystem.quarantineDescriptor,
        heldQuarantinedItemDescriptor: fixture.filesystem.candidateDescriptor,
        recoveryRequest: recoveryRequest,
        claim: claim
      )
    )

    guard case .staged(let work) = result else {
      Issue.record("Expected real staged work, got \(result)")
      return
    }
    let afterRename = try DescriptorStatSnapshot.read(
      from: fixture.filesystem.candidateDescriptor,
      cancellationPolicy: .ignoreTaskCancellation
    )
    #expect(afterRename.sameBinding(as: beforeRename))
    #expect(
      afterRename.changeSeconds != beforeRename.changeSeconds
        || afterRename.changeNanoseconds != beforeRename.changeNanoseconds
    )
    #expect(work.workSnapshot.sameBinding(as: afterRename))
    #expect(!FileManager.default.fileExists(atPath: fixture.quarantineItemURL.path))
    #expect(FileManager.default.fileExists(atPath: try fixture.purgeWorkURL().path))
  }

  @Test("A same-looking foreign canonical pair cannot substitute for recorded evidence")
  func foreignCanonicalPairIsRejected() async throws {
    let fixture = try PurgeJournalFixture()
    defer { fixture.remove() }
    let foreignEvidence = try fixture.foreignEvidence()
    let foreignID = foreignEvidence.purgeIntent.purgeTransactionID
    let journal = DescriptorQuarantinePurgeJournal(
      dependencies: DescriptorQuarantinePurgeJournalDependencies(
        journal: descriptorJournalTestDependencies()
      )
    )

    let result = journal.begin(
      DescriptorQuarantinePurgeJournalBeginRequest(
        recoveryRequest: fixture.filesystem.recoveryRequest(),
        quarantinedItemDescriptor: fixture.filesystem.candidateDescriptor,
        claim: try await purgeJournalClaim(.initial(foreignEvidence))
      )
    )

    guard case .failure(.transactionNotPurgeable) = result else {
      Issue.record("Expected exact-pair rejection, got \(result)")
      return
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.filesystem.recordURL(".purge-intent-v1-\(foreignID)").path
      )
    )
    #expect(FileManager.default.fileExists(atPath: fixture.quarantineItemURL.path))
  }

  @Test("An existing purge transaction and its managed names cannot be reused")
  func existingTransactionCollisionIsRejected() async throws {
    let fixture = try PurgeJournalFixture()
    defer { fixture.remove() }
    try fixture.writeCompletedNotPurgedAttempt()
    let journal = DescriptorQuarantinePurgeJournal(
      dependencies: DescriptorQuarantinePurgeJournalDependencies(
        journal: descriptorJournalTestDependencies()
      )
    )

    let result = journal.begin(
      DescriptorQuarantinePurgeJournalBeginRequest(
        recoveryRequest: fixture.filesystem.recoveryRequest(),
        quarantinedItemDescriptor: fixture.filesystem.candidateDescriptor,
        claim: try await fixture.claim()
      )
    )

    guard case .failure(.invalidClaim) = result else {
      Issue.record("Expected transaction collision rejection, got \(result)")
      return
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.purgeRecordURL(prefix: ".purge-intent-stage-v1-").path
      )
    )
    #expect(FileManager.default.fileExists(atPath: fixture.quarantineItemURL.path))
  }

  @Test("A replaced held item is classified as changed before publication")
  func replacedItemIsRejected() async throws {
    let fixture = try PurgeJournalFixture()
    defer { fixture.remove() }
    let displaced = fixture.filesystem.quarantineURL.appendingPathComponent(
      "displaced-item",
      isDirectory: true
    )
    let replacement = PurgeJournalReplacementRace(
      itemURL: fixture.quarantineItemURL,
      displacedURL: displaced
    )
    let journal = DescriptorQuarantinePurgeJournal(
      dependencies: DescriptorQuarantinePurgeJournalDependencies(
        journal: descriptorJournalTestDependencies(),
        validateCompleteTree: { _, _, _, _, _, _ in
          replacement.replace()
        }
      )
    )

    let result = journal.begin(
      DescriptorQuarantinePurgeJournalBeginRequest(
        recoveryRequest: fixture.filesystem.recoveryRequest(),
        quarantinedItemDescriptor: fixture.filesystem.candidateDescriptor,
        claim: try await fixture.claim()
      )
    )

    guard case .failure(.quarantinedItemChanged) = result else {
      Issue.record("Expected changed-item rejection, got \(result)")
      return
    }
    #expect(replacement.didReplace)
    #expect(replacement.failureDescription == nil)
    #expect(!fixture.finalPurgeIntentExists)
    #expect(!FileManager.default.fileExists(atPath: try fixture.purgeWorkURL().path))
  }

  @Test("Unsafe item metadata blocks intent publication")
  func unsafeItemMetadataIsRejected() async throws {
    let fixture = try PurgeJournalFixture()
    defer { fixture.remove() }
    try descriptorJournalTestChmod(fixture.quarantineItemURL, mode: 0o722)

    let result = try await fixture.beginWithDefaultJournal()

    guard case .failure(.quarantinedItemUnsafe) = result else {
      Issue.record("Expected unsafe-item rejection, got \(result)")
      return
    }
    #expect(!fixture.finalPurgeIntentExists)
    #expect(FileManager.default.fileExists(atPath: fixture.quarantineItemURL.path))
  }

  @Test("An invalid complete npm tree blocks intent publication")
  func unsafeCompleteTreeIsRejected() async throws {
    let fixture = try PurgeJournalFixture()
    defer { fixture.remove() }
    try Data([1]).write(
      to: fixture.quarantineItemURL.appendingPathComponent("unexpected")
    )

    let result = try await fixture.beginWithDefaultJournal()

    guard case .failure(.quarantinedItemUnsafe) = result else {
      Issue.record("Expected complete-tree rejection, got \(result)")
      return
    }
    #expect(!fixture.finalPurgeIntentExists)
    #expect(FileManager.default.fileExists(atPath: fixture.quarantineItemURL.path))
  }

  @Test("A purge-intent record barrier failure never invokes publication rename or item staging")
  func intentRecordSyncFailureFailsClosed() async throws {
    let fixture = try PurgeJournalFixture()
    defer { fixture.remove() }
    let syncs = PurgeJournalStageSyncFailure()
    let recorder = PurgeJournalPublicationRecorder()
    let dependencies = descriptorJournalTestDependencies(
      fullSync: { _ in syncs.result() },
      hooks: DescriptorQuarantineJournalHooks(
        didCreateStage: {
          recorder.createdStage($0)
          syncs.arm()
        },
        willPublishStage: { recorder.willPublish(stage: $0, final: $1) },
        didPublishFinal: { recorder.publishedFinal($0) }
      )
    )
    let journal = DescriptorQuarantinePurgeJournal(
      dependencies: DescriptorQuarantinePurgeJournalDependencies(journal: dependencies)
    )

    let result = journal.begin(
      DescriptorQuarantinePurgeJournalBeginRequest(
        recoveryRequest: fixture.filesystem.recoveryRequest(),
        quarantinedItemDescriptor: fixture.filesystem.candidateDescriptor,
        claim: try await fixture.claim()
      )
    )

    guard case .failure(.journal(.unavailable(.inputOutput))) = result else {
      Issue.record("Expected intent record sync failure, got \(result)")
      return
    }
    #expect(syncs.didFail)
    #expect(recorder.createdStageNames.count == 1)
    #expect(recorder.publishPairs.isEmpty)
    #expect(recorder.publishedFinalNames.isEmpty)
    #expect(!fixture.finalPurgeIntentExists)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.purgeRecordURL(prefix: ".purge-intent-stage-v1-").path
      )
    )
    #expect(FileManager.default.fileExists(atPath: fixture.quarantineItemURL.path))
    #expect(!FileManager.default.fileExists(atPath: try fixture.purgeWorkURL().path))
  }

  @Test("Cancellation immediately before record creation publishes no purge intent")
  func cancellationBeforeIntentStageCreation() async throws {
    let fixture = try PurgeJournalFixture()
    defer { fixture.remove() }
    let claim = try await fixture.claim()
    let syncCalls = DescriptorJournalTestCallGate()
    let recorder = PurgeJournalPublicationRecorder()
    let journal = DescriptorQuarantinePurgeJournal(
      dependencies: DescriptorQuarantinePurgeJournalDependencies(
        journal: descriptorJournalTestDependencies(
          hooks: DescriptorQuarantineJournalHooks(
            willFullSync: { _ in
              // The sixth barrier is the quarantine-root half of the final
              // pre-publication sync pair. Cancel there so the new guard is
              // the only boundary between cancellation and stage creation.
              syncCalls.run(onCall: 6) {
                withUnsafeCurrentTask { task in task?.cancel() }
              }
            },
            didCreateStage: { recorder.createdStage($0) },
            willPublishStage: { recorder.willPublish(stage: $0, final: $1) },
            didPublishFinal: { recorder.publishedFinal($0) }
          )
        )
      )
    )
    let request = DescriptorQuarantinePurgeJournalBeginRequest(
      recoveryRequest: fixture.filesystem.recoveryRequest(),
      quarantinedItemDescriptor: fixture.filesystem.candidateDescriptor,
      claim: claim
    )

    let result = await Task { journal.begin(request) }.value

    guard case .failure(.cancelled) = result else {
      Issue.record("Expected pre-publication cancellation, got \(result)")
      return
    }
    #expect(syncCalls.callCount == 6)
    #expect(recorder.createdStageNames.isEmpty)
    #expect(recorder.publishPairs.isEmpty)
    #expect(recorder.publishedFinalNames.isEmpty)
    #expect(!fixture.finalPurgeIntentExists)
    #expect(FileManager.default.fileExists(atPath: fixture.quarantineItemURL.path))
    #expect(!FileManager.default.fileExists(atPath: try fixture.purgeWorkURL().path))
  }
}

private final class PurgeJournalFixture {
  let filesystem: DescriptorJournalTestFixture
  let quarantineIntent: QuarantineJournalIntentV1
  let quarantineIntentBytes: Data
  let quarantineReceiptBytes: Data
  let quarantineItemURL: URL
  let purgeIntent: QuarantinePurgeJournalIntentV1
  let purgeIntentBytes: Data

  init() throws {
    let filesystem = try DescriptorJournalTestFixture()
    for requiredName in ["content-v2", "index-v5"] {
      let directory = filesystem.candidateURL.appendingPathComponent(
        requiredName,
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
      )
      try descriptorJournalTestChmod(directory, mode: 0o700)
    }
    let dependencies = descriptorJournalTestDependencies()
    let quarantineJournal = DescriptorQuarantineJournal(dependencies: dependencies)
    let quarantineSession = try filesystem.requireSession(from: quarantineJournal)
    let selectedDestinationOrdinal = 3
    let quarantineItemURL = try purgeJournalURL(
      parent: filesystem.quarantineURL,
      componentBytes: quarantineSession.intent.destinationComponents[
        selectedDestinationOrdinal
      ]
    )
    try FileManager.default.moveItem(at: filesystem.candidateURL, to: quarantineItemURL)
    switch quarantineJournal.finish(
      quarantineSession,
      outcome: .quarantined(
        selectedDestinationOrdinal: selectedDestinationOrdinal,
        sourceNameWasRecreated: false
      ),
      namespaceMutationMayHaveBeenInvoked: true
    ) {
    case .receiptRecorded:
      break
    case .recoveryRequired(let transactionID):
      throw PurgeJournalTestError.unexpected("quarantine recovery \(transactionID)")
    case .unresolved(let transactionID):
      throw PurgeJournalTestError.unexpected("quarantine unresolved \(transactionID)")
    case .invalidSession:
      throw PurgeJournalTestError.unexpected("invalid quarantine session")
    }
    let quarantineIntentBytes = quarantineSession.canonicalIntentBytes
    let quarantineReceiptBytes = try Data(
      contentsOf: filesystem.recordURL(
        ".receipt-v1-\(quarantineSession.intent.transactionID)"
      )
    )
    let purgeIntent = try QuarantinePurgeJournalV1Codec.makeIntent(
      purgeTransactionID: String(repeating: "b", count: 32),
      capacityBefore: purgeJournalCapacity(for: quarantineSession.intent),
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes
    )
    let purgeIntentBytes = try QuarantinePurgeJournalV1Codec.encode(
      purgeIntent,
      matchingQuarantineIntentBytes: quarantineIntentBytes,
      matchingQuarantineReceiptBytes: quarantineReceiptBytes
    )
    self.filesystem = filesystem
    quarantineIntent = quarantineSession.intent
    self.quarantineIntentBytes = quarantineIntentBytes
    self.quarantineReceiptBytes = quarantineReceiptBytes
    self.quarantineItemURL = quarantineItemURL
    self.purgeIntent = purgeIntent
    self.purgeIntentBytes = purgeIntentBytes
  }

  var finalPurgeIntentExists: Bool {
    FileManager.default.fileExists(
      atPath: purgeRecordURL(prefix: ".purge-intent-v1-").path
    )
  }

  func claim() async throws -> CleanupQuarantinePurgeExecutionClaim {
    try await purgeJournalClaim(
      .initial(
        CleanupQuarantinePurgeInitialPreparedEvidence(
          canonicalQuarantineIntentBytes: quarantineIntentBytes,
          canonicalQuarantineReceiptBytes: quarantineReceiptBytes,
          purgeIntent: purgeIntent
        )
      )
    )
  }

  func foreignEvidence() throws -> CleanupQuarantinePurgeInitialPreparedEvidence {
    let foreignIntent = QuarantineJournalIntentV1(
      transactionID: quarantineIntent.transactionID,
      npmRootBinding: quarantineIntent.npmRootBinding,
      quarantineRootBinding: quarantineIntent.quarantineRootBinding,
      candidateBinding: quarantineIntent.candidateBinding,
      sourceComponents: quarantineIntent.sourceComponents,
      destinationComponents: (0..<QuarantineJournalIntentV1.destinationCount).map {
        purgeJournalItemComponent(1_000 + $0)
      },
      policy: quarantineIntent.policy
    )
    let foreignIntentBytes = try QuarantineJournalV1Codec.encode(foreignIntent)
    let foreignReceipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .quarantined,
      selectedDestinationOrdinal: 3,
      producedByRecovery: false,
      canonicalIntentBytes: foreignIntentBytes
    )
    let foreignReceiptBytes = try QuarantineJournalV1Codec.encode(
      foreignReceipt,
      matchingIntentBytes: foreignIntentBytes
    )
    let foreignPurgeIntent = try QuarantinePurgeJournalV1Codec.makeIntent(
      purgeTransactionID: String(repeating: "c", count: 32),
      capacityBefore: purgeJournalCapacity(for: foreignIntent),
      canonicalQuarantineIntentBytes: foreignIntentBytes,
      canonicalQuarantineReceiptBytes: foreignReceiptBytes
    )
    return CleanupQuarantinePurgeInitialPreparedEvidence(
      canonicalQuarantineIntentBytes: foreignIntentBytes,
      canonicalQuarantineReceiptBytes: foreignReceiptBytes,
      purgeIntent: foreignPurgeIntent
    )
  }

  func beginWithDefaultJournal() async throws -> DescriptorQuarantinePurgeJournalBeginResult {
    DescriptorQuarantinePurgeJournal(
      dependencies: DescriptorQuarantinePurgeJournalDependencies(
        journal: descriptorJournalTestDependencies()
      )
    ).begin(
      DescriptorQuarantinePurgeJournalBeginRequest(
        recoveryRequest: filesystem.recoveryRequest(),
        quarantinedItemDescriptor: filesystem.candidateDescriptor,
        claim: try await claim()
      )
    )
  }

  func writeCompletedNotPurgedAttempt() throws {
    try purgeIntentBytes.write(
      to: purgeRecordURL(prefix: ".purge-intent-v1-"),
      options: []
    )
    try descriptorJournalTestChmod(
      purgeRecordURL(prefix: ".purge-intent-v1-"),
      mode: 0o600
    )
    let receipt = try QuarantinePurgeJournalV1Codec.makeReceipt(
      outcome: .notPurged,
      producedByRecovery: false,
      capacityObservationProvenance: .initialAttempt,
      capacityAfter: .unavailable,
      canonicalPurgeIntentBytes: purgeIntentBytes
    )
    let receiptBytes = try QuarantinePurgeJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: purgeIntentBytes
    )
    try receiptBytes.write(
      to: purgeRecordURL(prefix: ".purge-receipt-v1-"),
      options: []
    )
    try descriptorJournalTestChmod(
      purgeRecordURL(prefix: ".purge-receipt-v1-"),
      mode: 0o600
    )
  }

  func purgeRecordURL(prefix: String) -> URL {
    filesystem.recordURL("\(prefix)\(purgeIntent.purgeTransactionID)")
  }

  func purgeWorkURL() throws -> URL {
    try purgeJournalURL(
      parent: filesystem.quarantineURL,
      componentBytes: purgeIntent.purgeWorkComponent
    )
  }

  func remove() {
    filesystem.remove()
  }
}

private final class PurgeJournalPublicationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stages: [String] = []
  private var pairs: [(String, String)] = []
  private var finals: [String] = []

  var createdStageNames: [String] { lock.withLock { stages } }
  var publishPairs: [(String, String)] { lock.withLock { pairs } }
  var publishedFinalNames: [String] { lock.withLock { finals } }

  func createdStage(_ component: DescriptorPathComponent) {
    lock.withLock { stages.append(String(decoding: component.bytes, as: UTF8.self)) }
  }

  func willPublish(
    stage: DescriptorPathComponent,
    final: DescriptorPathComponent
  ) {
    lock.withLock {
      pairs.append(
        (
          String(decoding: stage.bytes, as: UTF8.self),
          String(decoding: final.bytes, as: UTF8.self)
        )
      )
    }
  }

  func publishedFinal(_ component: DescriptorPathComponent) {
    lock.withLock { finals.append(String(decoding: component.bytes, as: UTF8.self)) }
  }
}

private final class PurgeJournalReplacementRace: @unchecked Sendable {
  private let lock = NSLock()
  private let itemURL: URL
  private let displacedURL: URL
  private var replacementOccurred = false
  private var storedFailureDescription: String?

  init(itemURL: URL, displacedURL: URL) {
    self.itemURL = itemURL
    self.displacedURL = displacedURL
  }

  var didReplace: Bool { lock.withLock { replacementOccurred } }
  var failureDescription: String? { lock.withLock { storedFailureDescription } }

  func replace() {
    lock.withLock {
      do {
        try FileManager.default.moveItem(at: itemURL, to: displacedURL)
        try FileManager.default.createDirectory(
          at: itemURL,
          withIntermediateDirectories: false
        )
        try descriptorJournalTestChmod(itemURL, mode: 0o700)
        replacementOccurred = true
      } catch {
        storedFailureDescription = String(describing: error)
      }
    }
  }
}

private final class PurgeJournalStageSyncFailure: @unchecked Sendable {
  private let lock = NSLock()
  private var isArmed = false
  private var failureOccurred = false

  var didFail: Bool { lock.withLock { failureOccurred } }

  func arm() {
    lock.withLock { isArmed = true }
  }

  func result() -> Int32? {
    lock.withLock {
      guard isArmed, !failureOccurred else { return nil }
      isArmed = false
      failureOccurred = true
      return EIO
    }
  }
}

private enum PurgeJournalTestError: Error {
  case invalidPath
  case unexpected(String)
}

private func purgeJournalClaim(
  _ evidence: CleanupQuarantinePurgePreparedEvidence
) async throws -> CleanupQuarantinePurgeExecutionClaim {
  let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: evidence)
  let confirmation = CleanupQuarantinePurgeUserConfirmation(
    request: session.confirmationRequest,
    statement: session.confirmationRequest.requiredStatement
  )
  let authorization = try await session.authorize(using: confirmation)
  return try await authorization.consumeForExecution()
}

private func purgeJournalCapacity(
  for intent: QuarantineJournalIntentV1
) -> QuarantinePurgeCapacityObservationV1 {
  QuarantinePurgeCapacityObservationV1(
    volumeIdentity: QuarantinePurgeVolumeIdentityV1(
      device: intent.candidateBinding.device,
      fileSystemIDFirst: 17,
      fileSystemIDSecond: 23
    ),
    availableBytes: 1_000_000
  )
}

private func purgeJournalURL(parent: URL, componentBytes: [UInt8]) throws -> URL {
  guard let component = String(bytes: componentBytes, encoding: .utf8) else {
    throw PurgeJournalTestError.invalidPath
  }
  return parent.appendingPathComponent(component)
}

private func purgeJournalItemComponent(_ ordinal: Int) -> [UInt8] {
  Array("item-v1-\(String(format: "%032x", ordinal + 1))".utf8)
}

private func purgeJournalTestRename(
  fromDescriptor: Int32,
  fromPath: DescriptorQuarantineRelativePath,
  toDescriptor: Int32,
  toPath: DescriptorQuarantineRelativePath,
  flags: UInt32
) -> DescriptorExclusiveRenameResult {
  let supportsResolveBeneath = ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
  )
  let effectiveFlags =
    supportsResolveBeneath
    ? flags
    : flags & ~DescriptorExclusiveQuarantineMover.resolveBeneathRenameFlag
  var failureCode: Int32 = EINVAL
  let result = fromPath.withCString { fromPointer in
    toPath.withCString { toPointer in
      let value = Darwin.renameatx_np(
        fromDescriptor,
        fromPointer,
        toDescriptor,
        toPointer,
        effectiveFlags
      )
      if value != 0 { failureCode = errno }
      return value
    }
  }
  return result == 0 ? .succeeded : .failed(failureCode)
}
