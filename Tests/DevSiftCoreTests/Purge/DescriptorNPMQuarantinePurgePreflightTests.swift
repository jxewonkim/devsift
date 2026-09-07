import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor npm quarantine purge preflight", .serialized)
struct DescriptorNPMQuarantinePurgePreflightTests {
  @Test("Initial preparation uses opaque selection and Core-issued 128-bit identifier")
  func initialPreparation() throws {
    let fixture = try PurgePreflightFixture()
    defer { fixture.remove() }
    let probe = PurgePreflightAuthorizationProbe()
    let nonce = [UInt8](repeating: 0xBC, count: 16)
    let preflight = fixture.preflight(
      nonceBytes: { attempt in
        #expect(attempt == 0)
        return nonce
      },
      beginAuthorization: probe.begin
    )

    let result = preflight.prepareInitial(try fixture.initialSelection())

    let session = try requirePurgeSession(result)
    #expect(session.confirmationRequest.attemptKind == .initial)
    #expect(
      session.confirmationRequest.requiredStatement
        == .initialPermanentDeletionRisksAccepted
    )
    let evidence = try #require(probe.evidence)
    guard case .initial(let initial) = evidence else {
      Issue.record("Expected initial evidence")
      return
    }
    #expect(initial.purgeIntent.purgeTransactionID == String(repeating: "bc", count: 16))
    #expect(initial.purgeIntent.quarantineTransactionID == fixture.quarantineTransactionID)
    #expect(initial.purgeIntent.capacityBefore.availableBytes == 9_000)
    #expect(initial.canonicalQuarantineIntentBytes == fixture.canonicalIntentBytes)
    #expect(initial.canonicalQuarantineReceiptBytes == fixture.canonicalReceiptBytes)
    #expect(FileManager.default.fileExists(atPath: fixture.itemURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.workURL(for: initial.purgeIntent).path))
  }

  @Test("Current active cache is never selected or changed")
  func activeCacheIsNotPurgeInput() throws {
    let fixture = try PurgePreflightFixture()
    defer { fixture.remove() }
    let active = fixture.rootURL.appendingPathComponent("_cacache", isDirectory: true)
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
    try descriptorJournalTestChmod(active, mode: 0o700)
    let marker = active.appendingPathComponent("must-remain")
    try Data([1, 2, 3]).write(to: marker)
    try descriptorJournalTestChmod(marker, mode: 0o600)

    _ = try requirePurgeSession(
      fixture.preflight().prepareInitial(try fixture.initialSelection())
    )

    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(FileManager.default.fileExists(atPath: fixture.itemURL.path))
  }

  @Test("Initial preparation rereads exact canonical record bytes")
  func initialRecordChange() throws {
    let fixture = try PurgePreflightFixture()
    defer { fixture.remove() }
    let oneShot = PurgePreflightOneShot()
    let preflight = fixture.preflight(
      hooks: DescriptorNPMQuarantinePurgePreflightHooks(
        beforeFinalEvidenceValidation: {
          try oneShot.run {
            var bytes = fixture.canonicalReceiptBytes
            bytes[bytes.startIndex] ^= 0x01
            try bytes.write(to: fixture.receiptRecordURL)
            try descriptorJournalTestChmod(fixture.receiptRecordURL, mode: 0o600)
          }
        }
      )
    )

    expectPurgePreflightFailure(
      .journalRecordChanged,
      from: preflight.prepareInitial(try fixture.initialSelection())
    )
    #expect(FileManager.default.fileExists(atPath: fixture.itemURL.path))
  }

  @Test("Initial preparation rejects an incomplete cache tree")
  func incompleteInitialTree() throws {
    let fixture = try PurgePreflightFixture()
    defer { fixture.remove() }
    try FileManager.default.removeItem(
      at: fixture.itemURL.appendingPathComponent("content-v2")
    )

    expectPurgePreflightFailure(
      .quarantinedItemUnsafe,
      from: fixture.preflight().prepareInitial(try fixture.initialSelection())
    )
  }

  @Test("Unsupported systems fail before capacity sampling")
  func unsupportedBeforeCapacity() throws {
    let fixture = try PurgePreflightFixture()
    defer { fixture.remove() }
    let capacityProbe = PurgePreflightCallProbe()
    let preflight = fixture.preflight(
      supportsDurablePurge: { false },
      capacityObserver: fixture.capacityObserver(probe: capacityProbe)
    )

    expectPurgePreflightFailure(
      .unsupportedPlatform,
      from: preflight.prepareInitial(try fixture.initialSelection())
    )
    #expect(capacityProbe.callCount == 0)
  }

  @Test("Unrelated home child churn preserves the exact trusted parents")
  func unrelatedHomeChildChurn() throws {
    let fixture = try PurgePreflightFixture()
    defer { fixture.remove() }
    let unrelated = fixture.homeURL.appendingPathComponent(
      "unrelated-sibling",
      isDirectory: true
    )
    let preflight = fixture.preflight(
      hooks: DescriptorNPMQuarantinePurgePreflightHooks(
        beforeFinalParentValidation: {
          try FileManager.default.createDirectory(
            at: unrelated,
            withIntermediateDirectories: false
          )
          try descriptorJournalTestChmod(unrelated, mode: 0o700)
        }
      )
    )

    _ = try requirePurgeSession(
      preflight.prepareInitial(try fixture.initialSelection())
    )
  }

  @Test("Purge identifier namespace collisions are bounded")
  func identifierCollisions() throws {
    let fixture = try PurgePreflightFixture()
    defer { fixture.remove() }
    let collidingID = String(repeating: "cd", count: 16)
    let occupied = fixture.quarantineURL.appendingPathComponent(
      ".purge-work-v1-\(collidingID)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
    try descriptorJournalTestChmod(occupied, mode: 0o700)
    let nonceProbe = PurgePreflightCallProbe()
    let preflight = fixture.preflight(
      nonceBytes: { _ in
        nonceProbe.record()
        return [UInt8](repeating: 0xCD, count: 16)
      }
    )

    expectPurgePreflightFailure(
      .purgeIdentifierCollisionLimitExceeded,
      from: preflight.prepareInitial(try fixture.initialSelection())
    )
    #expect(
      nonceProbe.callCount
        == DescriptorNPMQuarantinePurgePreflight.maximumPurgeIdentifierAttempts
    )
  }

  @Test("Initial claim callback retains only the exact fixed descriptors")
  func initialClaimScope() async throws {
    let fixture = try PurgePreflightFixture()
    defer { fixture.remove() }
    let preflight = fixture.preflight()
    let session = try requirePurgeSession(
      preflight.prepareInitial(try fixture.initialSelection())
    )
    let authorization = try await session.authorize(
      using: CleanupQuarantinePurgeUserConfirmation(
        request: session.confirmationRequest,
        statement: session.confirmationRequest.requiredStatement
      ))
    let claim = try await authorization.consumeForExecution()

    let result = preflight.withValidatedInitialClaim(claim) { scope in
      var root = stat()
      var quarantine = stat()
      var item = stat()
      let descriptorsAreOpen =
        Darwin.fstat(scope.heldRootDescriptor, &root) == 0
        && Darwin.fstat(scope.heldQuarantineRootDescriptor, &quarantine) == 0
        && Darwin.fstat(scope.heldQuarantinedItemDescriptor, &item) == 0
      let named = try? DescriptorStatSnapshot.read(
        at: scope.heldQuarantineRootDescriptor,
        component: DescriptorPathComponent(fixture.itemComponent)!
      )
      let held = try? DescriptorStatSnapshot.read(
        from: scope.heldQuarantinedItemDescriptor
      )
      return descriptorsAreOpen
        && named != nil
        && held != nil
        && named!.sameBinding(as: held!)
        && scope.recoveryRequest.quarantineRootComponent.bytes
          == DescriptorExclusiveQuarantineMover.quarantineRootBytes
    }

    switch result {
    case .success(let valid):
      #expect(valid)
    case .failure(let failure):
      Issue.record("Initial claim reopening failed: \(failure)")
    }
  }

  @Test("Explicit retry validates a deletion-derived remainder without new capacity sample")
  func explicitRetryPreparation() throws {
    let fixture = try PurgePreflightFixture(makeRetry: true)
    defer { fixture.remove() }
    let probe = PurgePreflightAuthorizationProbe()
    let capacityProbe = PurgePreflightCallProbe()
    let preflight = fixture.preflight(
      capacityObserver: fixture.capacityObserver(probe: capacityProbe),
      beginAuthorization: probe.begin
    )

    let session = try requirePurgeSession(
      preflight.prepareExplicitRetry(try fixture.retrySelection())
    )

    #expect(session.confirmationRequest.attemptKind == .explicitRetry)
    #expect(
      session.confirmationRequest.requiredStatement
        == .explicitRetryPermanentDeletionRisksAccepted
    )
    guard case .explicitRetry(let evidence) = try #require(probe.evidence) else {
      Issue.record("Expected retry evidence")
      return
    }
    #expect(evidence.canonicalPurgeIntentBytes == fixture.canonicalPurgeIntentBytes)
    #expect(evidence.currentWorkBinding == fixture.currentWorkBinding)
    #expect(capacityProbe.callCount == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.retryWorkURL.path))
  }

  @Test("Retry selection is stale when work changed after inventory")
  func staleRetryWorkBinding() throws {
    let fixture = try PurgePreflightFixture(makeRetry: true)
    defer { fixture.remove() }
    let selection = try fixture.retrySelection()
    let extra = fixture.retryWorkURL.appendingPathComponent("CACHEDIR.TAG")
    try Data([7]).write(to: extra)
    try descriptorJournalTestChmod(extra, mode: 0o600)

    expectPurgePreflightFailure(
      .purgeWorkUnsafe,
      from: fixture.preflight().prepareExplicitRetry(selection)
    )
  }

  @Test("Retry claim callback retains the exact intent-derived work descriptor")
  func retryClaimScope() async throws {
    let fixture = try PurgePreflightFixture(makeRetry: true)
    defer { fixture.remove() }
    let preflight = fixture.preflight()
    let session = try requirePurgeSession(
      preflight.prepareExplicitRetry(try fixture.retrySelection())
    )
    let authorization = try await session.authorize(
      using: CleanupQuarantinePurgeUserConfirmation(
        request: session.confirmationRequest,
        statement: session.confirmationRequest.requiredStatement
      ))
    let claim = try await authorization.consumeForExecution()

    let result = preflight.withValidatedRetryClaim(claim) { scope in
      let held = try? DescriptorStatSnapshot.read(from: scope.heldPurgeWorkDescriptor)
      let component = DescriptorPathComponent(fixture.purgeIntent!.purgeWorkComponent)!
      let named = try? DescriptorStatSnapshot.read(
        at: scope.heldQuarantineRootDescriptor,
        component: component
      )
      return held != nil && named != nil && held!.sameBinding(as: named!)
    }

    switch result {
    case .success(let valid):
      #expect(valid)
    case .failure(let failure):
      Issue.record("Retry claim reopening failed: \(failure)")
    }
  }
}

private final class PurgePreflightFixture: @unchecked Sendable {
  let filesystem: DescriptorJournalTestFixture
  let intent: QuarantineJournalIntentV1
  let receipt: QuarantineJournalReceiptV1
  let itemComponent: [UInt8]
  let itemURL: URL
  let canonicalIntentBytes: Data
  let canonicalReceiptBytes: Data
  let purgeIntent: QuarantinePurgeJournalIntentV1?
  let canonicalPurgeIntentBytes: Data?
  let currentWorkBinding: QuarantineJournalFileBindingV1?

  var rootURL: URL { filesystem.rootURL }
  var homeURL: URL { filesystem.baseURL }
  var quarantineURL: URL { filesystem.quarantineURL }
  var quarantineTransactionID: String { intent.transactionID }
  var intentRecordURL: URL {
    filesystem.recordURL(".intent-v1-\(intent.transactionID)")
  }
  var receiptRecordURL: URL {
    filesystem.recordURL(".receipt-v1-\(intent.transactionID)")
  }
  var retryWorkURL: URL {
    guard let purgeIntent else { return quarantineURL.appendingPathComponent("invalid") }
    return workURL(for: purgeIntent)
  }

  init(makeRetry: Bool = false) throws {
    let filesystem = try DescriptorJournalTestFixture()
    for name in ["content-v2", "index-v5"] {
      let directory = filesystem.candidateURL.appendingPathComponent(
        name,
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
      )
      try descriptorJournalTestChmod(directory, mode: 0o700)
    }
    let intent = try filesystem.intent(destinationSeed: 0x800)
    let selectedOrdinal = 4
    let itemComponent = intent.destinationComponents[selectedOrdinal]
    guard let itemName = String(bytes: itemComponent, encoding: .utf8) else {
      filesystem.remove()
      throw PurgePreflightTestError.invalidFixture
    }
    let itemURL = filesystem.quarantineURL.appendingPathComponent(
      itemName,
      isDirectory: true
    )
    let canonicalIntentBytes = try QuarantineJournalV1Codec.encode(intent)
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .quarantined,
      selectedDestinationOrdinal: selectedOrdinal,
      producedByRecovery: false,
      canonicalIntentBytes: canonicalIntentBytes
    )
    let canonicalReceiptBytes = try QuarantineJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: canonicalIntentBytes
    )
    try FileManager.default.moveItem(at: filesystem.candidateURL, to: itemURL)
    try PurgePreflightFixture.writeRecord(
      canonicalIntentBytes,
      to: filesystem.recordURL(".intent-v1-\(intent.transactionID)")
    )
    try PurgePreflightFixture.writeRecord(
      canonicalReceiptBytes,
      to: filesystem.recordURL(".receipt-v1-\(intent.transactionID)")
    )

    var builtPurgeIntent: QuarantinePurgeJournalIntentV1?
    var builtPurgeBytes: Data?
    var builtCurrentWorkBinding: QuarantineJournalFileBindingV1?
    if makeRetry {
      let purgeIntent = try QuarantinePurgeJournalV1Codec.makeIntent(
        purgeTransactionID: String(repeating: "d", count: 32),
        capacityBefore: QuarantinePurgeCapacityObservationV1(
          volumeIdentity: QuarantinePurgeVolumeIdentityV1(
            device: intent.candidateBinding.device,
            fileSystemIDFirst: 11,
            fileSystemIDSecond: 12
          ),
          availableBytes: 8_000
        ),
        canonicalQuarantineIntentBytes: canonicalIntentBytes,
        canonicalQuarantineReceiptBytes: canonicalReceiptBytes
      )
      let purgeBytes = try QuarantinePurgeJournalV1Codec.encode(
        purgeIntent,
        matchingQuarantineIntentBytes: canonicalIntentBytes,
        matchingQuarantineReceiptBytes: canonicalReceiptBytes
      )
      let workURL = filesystem.quarantineURL.appendingPathComponent(
        String(bytes: purgeIntent.purgeWorkComponent, encoding: .utf8)!,
        isDirectory: true
      )
      try FileManager.default.moveItem(at: itemURL, to: workURL)
      try FileManager.default.removeItem(
        at: workURL.appendingPathComponent("content-v2")
      )
      try PurgePreflightFixture.writeRecord(
        purgeBytes,
        to: filesystem.recordURL(".purge-intent-v1-\(purgeIntent.purgeTransactionID)")
      )
      let workDescriptor = Darwin.open(
        workURL.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard workDescriptor >= 0 else {
        filesystem.remove()
        throw PurgePreflightTestError.posix(errno)
      }
      defer { descriptorCloseIgnoringErrors(workDescriptor) }
      let workSnapshot = try DescriptorStatSnapshot.read(from: workDescriptor)
      guard let binding = QuarantineJournalFileBindingV1(snapshot: workSnapshot) else {
        filesystem.remove()
        throw PurgePreflightTestError.invalidFixture
      }
      builtPurgeIntent = purgeIntent
      builtPurgeBytes = purgeBytes
      builtCurrentWorkBinding = binding
    }

    self.filesystem = filesystem
    self.intent = intent
    self.receipt = receipt
    self.itemComponent = itemComponent
    self.itemURL = itemURL
    self.canonicalIntentBytes = canonicalIntentBytes
    self.canonicalReceiptBytes = canonicalReceiptBytes
    self.purgeIntent = builtPurgeIntent
    self.canonicalPurgeIntentBytes = builtPurgeBytes
    self.currentWorkBinding = builtCurrentWorkBinding
  }

  func preflight(
    nonceBytes: @escaping DescriptorNPMQuarantinePurgePreflightDependencies.NonceProvider = {
      _ in [UInt8](repeating: 0xBC, count: 16)
    },
    supportsDurablePurge: @escaping @Sendable () -> Bool = { true },
    capacityObserver: DescriptorQuarantinePurgeCapacityObserver? = nil,
    beginAuthorization:
      @escaping DescriptorNPMQuarantinePurgePreflightDependencies
      .BeginAuthorization = {
        try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: $0)
      },
    hooks: DescriptorNPMQuarantinePurgePreflightHooks =
      DescriptorNPMQuarantinePurgePreflightHooks()
  ) -> DescriptorNPMQuarantinePurgePreflight {
    let rawHome = Array(filesystem.baseURL.path.utf8)
    return DescriptorNPMQuarantinePurgePreflight(
      dependencies: DescriptorNPMQuarantinePurgePreflightDependencies(
        checkpoint: {},
        rawHomeProvider: { .known(rawHome) },
        accountUIDProvider: { .known(Darwin.getuid()) },
        nonceBytes: nonceBytes,
        supportsDurablePurge: supportsDurablePurge,
        capacityObserver: capacityObserver ?? self.capacityObserver(),
        beginAuthorization: beginAuthorization,
        hooks: hooks
      ))
  }

  func capacityObserver(
    probe: PurgePreflightCallProbe? = nil
  ) -> DescriptorQuarantinePurgeCapacityObserver {
    let device = intent.candidateBinding.device
    return DescriptorQuarantinePurgeCapacityObserver(
      dependencies: DescriptorQuarantinePurgeCapacityObserverDependencies(
        fstat: { descriptor in
          probe?.record()
          var information = stat()
          guard Darwin.fstat(descriptor, &information) == 0 else {
            return .failure(DescriptorQuarantinePurgeCapacityPOSIXError(code: errno))
          }
          return .success(DescriptorQuarantinePurgeFStatValue(device: device))
        },
        fstatfs: { _ in
          .success(
            DescriptorQuarantinePurgeFStatFSValue(
              blockSize: 1_000,
              availableBlockCount: 9,
              fileSystemIDFirst: 11,
              fileSystemIDSecond: 12
            ))
        }
      ))
  }

  func initialSelection() throws -> QuarantineInventoryInitialPurgeSelection {
    let workflow = workflow(entry: inventoryEntry())
    let inventory: QuarantineInventorySession
    switch workflow.reconcileAndLoadInventory() {
    case .success(let value):
      inventory = value
    case .failure:
      throw PurgePreflightTestError.invalidFixture
    }
    guard let item = inventory.items.first else {
      throw PurgePreflightTestError.invalidFixture
    }
    switch workflow.selectForInitialPurge(from: inventory, item: item.reference) {
    case .success(let selection):
      return selection
    case .failure:
      throw PurgePreflightTestError.invalidFixture
    }
  }

  func retrySelection() throws -> QuarantineInventoryPurgeRetrySelection {
    let workflow = workflow(entry: inventoryEntry(includeRetry: true))
    let inventory: QuarantineInventorySession
    switch workflow.reconcileAndLoadInventory() {
    case .success(let value):
      inventory = value
    case .failure:
      throw PurgePreflightTestError.invalidFixture
    }
    guard let item = inventory.purgeRetries.first else {
      throw PurgePreflightTestError.invalidFixture
    }
    switch workflow.selectForPurgeRetry(from: inventory, retry: item.reference) {
    case .success(let selection):
      return selection
    case .failure:
      throw PurgePreflightTestError.invalidFixture
    }
  }

  func workURL(for intent: QuarantinePurgeJournalIntentV1) -> URL {
    quarantineURL.appendingPathComponent(
      String(bytes: intent.purgeWorkComponent, encoding: .utf8)!,
      isDirectory: true
    )
  }

  func remove() {
    filesystem.remove()
  }

  private func inventoryEntry(
    includeRetry: Bool = false
  ) -> DescriptorQuarantineInventoryEntry {
    let retry: DescriptorQuarantinePurgeRetryInventoryEntry?
    if includeRetry,
      let purgeIntent,
      let canonicalPurgeIntentBytes,
      let currentWorkBinding
    {
      retry = DescriptorQuarantinePurgeRetryInventoryEntry(
        canonicalQuarantineIntentBytes: canonicalIntentBytes,
        canonicalQuarantineReceiptBytes: canonicalReceiptBytes,
        purgeIntent: purgeIntent,
        canonicalPurgeIntentBytes: canonicalPurgeIntentBytes,
        currentWorkBinding: currentWorkBinding
      )
    } else {
      retry = nil
    }
    return DescriptorQuarantineInventoryEntry(
      quarantineTransactionID: intent.transactionID,
      canonicalQuarantineIntentBytes: canonicalIntentBytes,
      canonicalQuarantineReceiptBytes: canonicalReceiptBytes,
      sourceState: .missing,
      itemState: includeRetry ? .missing : .available,
      quarantineReceiptWasProducedByRecovery: false,
      purgeRetry: retry
    )
  }

  private func workflow(
    entry: DescriptorQuarantineInventoryEntry
  ) -> QuarantineInventoryRestoreWorkflow {
    QuarantineInventoryRestoreWorkflow(
      loadInventory: { .success([entry]) },
      prepareRestore: { _ in .failure(.invalidClaim) },
      executeRestore: { _ in throw CancellationError() }
    )
  }

  private static func writeRecord(_ bytes: Data, to url: URL) throws {
    try bytes.write(to: url)
    try descriptorJournalTestChmod(url, mode: 0o600)
  }
}

private final class PurgePreflightAuthorizationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvidence: CleanupQuarantinePurgePreparedEvidence?

  lazy var begin: DescriptorNPMQuarantinePurgePreflightDependencies.BeginAuthorization =
    { [weak self] evidence in
      self?.lock.lock()
      self?.storedEvidence = evidence
      self?.lock.unlock()
      return try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: evidence)
    }

  var evidence: CleanupQuarantinePurgePreparedEvidence? {
    lock.lock()
    defer { lock.unlock() }
    return storedEvidence
  }
}

private final class PurgePreflightCallProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCallCount = 0

  func record() {
    lock.lock()
    storedCallCount += 1
    lock.unlock()
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedCallCount
  }
}

private final class PurgePreflightOneShot: @unchecked Sendable {
  private let lock = NSLock()
  private var hasRun = false

  func run(_ operation: () throws -> Void) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !hasRun else { return }
    hasRun = true
    try operation()
  }
}

private enum PurgePreflightTestError: Error {
  case invalidFixture
  case posix(Int32)
}

private func requirePurgeSession(
  _ result: Result<
    CleanupQuarantinePurgeAuthorizationSession,
    DescriptorNPMQuarantinePurgePreflightFailure
  >
) throws -> CleanupQuarantinePurgeAuthorizationSession {
  switch result {
  case .success(let session):
    return session
  case .failure(let failure):
    Issue.record("Purge preflight unexpectedly failed: \(failure)")
    throw PurgePreflightTestError.invalidFixture
  }
}

private func expectPurgePreflightFailure(
  _ expected: DescriptorNPMQuarantinePurgePreflightFailure,
  from result: Result<
    CleanupQuarantinePurgeAuthorizationSession,
    DescriptorNPMQuarantinePurgePreflightFailure
  >
) {
  switch result {
  case .success:
    Issue.record("Purge preflight unexpectedly succeeded")
  case .failure(let failure):
    #expect(failure == expected)
  }
}
