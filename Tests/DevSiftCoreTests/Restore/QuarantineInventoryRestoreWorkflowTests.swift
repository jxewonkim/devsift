import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Quarantine inventory and restore workflow", .serialized)
struct QuarantineInventoryRestoreWorkflowTests {
  @Test("A canonical durable quarantine is projected as ready without exposing its selector")
  func loadsReadyInventory() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let completed = try completeQuarantine(in: fixture)
    let loader = inventoryLoader(for: fixture)

    let entries = try requireInventory(loader.reconcileAndLoadInventory())

    #expect(entries.count == 1)
    #expect(entries[0].quarantineTransactionID == fixture.transactionID)
    #expect(entries[0].sourceState == .missing)
    #expect(entries[0].itemState == .available)
    #expect(!entries[0].quarantineReceiptWasProducedByRecovery)
    #expect(FileManager.default.fileExists(atPath: completed.destination.path))

    let workflow = workflowLoading(entries)
    let session = try requireFrontendInventory(workflow.reconcileAndLoadInventory())
    #expect(session.items.count == 1)
    #expect(!String(reflecting: session).contains(fixture.transactionID))
    #expect(!String(reflecting: session.items[0].reference).contains(fixture.transactionID))
    #expect(session.items[0].responsibleTool == "npm")
    #expect(session.items[0].originalName == "_cacache")
    #expect(session.items[0].readiness.canRestore)
  }

  @Test("Loading an absent fixed quarantine returns empty without creating it")
  func missingQuarantineIsEmptyAndUnchanged() throws {
    let fixture = try DescriptorJournalTestFixture(
      createCandidate: false,
      createQuarantine: false
    )
    defer { fixture.remove() }

    let entries = try requireInventory(
      inventoryLoader(for: fixture).reconcileAndLoadInventory()
    )

    #expect(entries.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.quarantineURL.path))
  }

  @Test("Active inventory order is deterministic across multiple durable receipts")
  func activeInventoryIsDeterministicallyOrdered() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    _ = try completeQuarantine(in: fixture)
    let secondTransactionID = String(repeating: "0", count: 31) + "2"
    _ = try completeAdditionalQuarantine(
      in: fixture,
      transactionID: secondTransactionID,
      destinationSeed: 100
    )

    let entries = try requireInventory(
      inventoryLoader(for: fixture).reconcileAndLoadInventory()
    )

    #expect(entries.map(\.quarantineTransactionID) == [secondTransactionID, fixture.transactionID])
    #expect(entries.allSatisfy { $0.sourceState == .missing && $0.itemState == .available })
  }

  @Test("Recovery and the post-recovery projection share one journal lock")
  func recoveryAndProjectionShareLock() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    try installValidCacacheTree(at: fixture.candidateURL)
    let inventoryReads = InventoryTestCounter()
    let lockAcquisitions = InventoryTestCounter()
    let dependencies = descriptorJournalTestDependencies(
      hooks: DescriptorQuarantineJournalHooks(
        didAcquireLock: { lockAcquisitions.increment() },
        willReadInventory: { inventoryReads.increment() }
      )
    )
    let journal = DescriptorQuarantineJournal(dependencies: dependencies)
    let intent = try fixture.intent()
    var session: DescriptorQuarantineJournalSession? = try fixture.requireSession(from: journal)
    #expect(session != nil)
    session = nil
    let destination = try inventoryDestinationURL(intent.destinationComponents[0], fixture: fixture)
    try FileManager.default.moveItem(at: fixture.candidateURL, to: destination)
    let inventoryReadsBeforeLoad = inventoryReads.value
    let lockAcquisitionsBeforeLoad = lockAcquisitions.value

    let entries = try requireInventory(
      inventoryLoader(for: fixture, dependencies: dependencies).reconcileAndLoadInventory()
    )

    #expect(entries.count == 1)
    #expect(entries[0].quarantineReceiptWasProducedByRecovery)
    #expect(entries[0].sourceState == .missing)
    #expect(entries[0].itemState == .available)
    // The loader takes one lock while recovery reads once and the final
    // projection rereads once.
    #expect(lockAcquisitions.value - lockAcquisitionsBeforeLoad == 1)
    #expect(inventoryReads.value - inventoryReadsBeforeLoad == 2)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.recordURL(".receipt-v1-\(fixture.transactionID)").path
      )
    )
  }

  @Test("An occupied source and changed quarantine item are both reported")
  func reportsCurrentNamespaceState() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let completed = try completeQuarantine(in: fixture)
    try FileManager.default.createDirectory(
      at: fixture.candidateURL,
      withIntermediateDirectories: false
    )
    try descriptorJournalTestChmod(fixture.candidateURL, mode: 0o700)
    let displaced = fixture.baseURL.appendingPathComponent("displaced-item")
    try FileManager.default.moveItem(at: completed.destination, to: displaced)
    try FileManager.default.createDirectory(
      at: completed.destination,
      withIntermediateDirectories: false
    )
    try descriptorJournalTestChmod(completed.destination, mode: 0o700)

    let entries = try requireInventory(
      inventoryLoader(for: fixture).reconcileAndLoadInventory()
    )

    #expect(entries.count == 1)
    #expect(entries[0].sourceState == .otherObjectPresent)
    #expect(entries[0].itemState == .changed)
  }

  @Test("A missing quarantined item remains visible and is not restore-ready")
  func reportsMissingItem() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let completed = try completeQuarantine(in: fixture)
    let displaced = fixture.baseURL.appendingPathComponent("displaced-item")
    try FileManager.default.moveItem(at: completed.destination, to: displaced)

    let entries = try requireInventory(
      inventoryLoader(for: fixture).reconcileAndLoadInventory()
    )

    #expect(entries.count == 1)
    #expect(entries[0].sourceState == .missing)
    #expect(entries[0].itemState == .missing)
  }

  @Test("Unsafe quarantined contents remain visible but cannot be restored")
  func reportsUnsafeItem() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let completed = try completeQuarantine(in: fixture)
    try descriptorJournalTestChmod(
      completed.destination.appendingPathComponent("content-v2"),
      mode: 0o777
    )

    let entries = try requireInventory(
      inventoryLoader(for: fixture).reconcileAndLoadInventory()
    )

    #expect(entries.count == 1)
    #expect(entries[0].itemState == .unsafe)
  }

  @Test("A successful restore receipt removes the historical item from active inventory")
  func excludesSuccessfullyRestoredItem() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    let completed = try completeQuarantine(in: fixture)
    let restoreTransactionID = String(repeating: "b", count: 32)
    let intentBytes = try Data(
      contentsOf: fixture.recordURL(".intent-v1-\(fixture.transactionID)")
    )
    let receiptBytes = try Data(
      contentsOf: fixture.recordURL(".receipt-v1-\(fixture.transactionID)")
    )
    let restoreIntent = try QuarantineRestoreJournalV1Codec.makeIntent(
      restoreTransactionID: restoreTransactionID,
      canonicalQuarantineIntentBytes: intentBytes,
      canonicalQuarantineReceiptBytes: receiptBytes
    )
    let restoreIntentBytes = try QuarantineRestoreJournalV1Codec.encode(
      restoreIntent,
      matchingQuarantineIntentBytes: intentBytes,
      matchingQuarantineReceiptBytes: receiptBytes
    )
    let restoreReceipt = try QuarantineRestoreJournalV1Codec.makeReceipt(
      outcome: .restored,
      producedByRecovery: false,
      canonicalRestoreIntentBytes: restoreIntentBytes
    )
    let restoreReceiptBytes = try QuarantineRestoreJournalV1Codec.encode(
      restoreReceipt,
      matchingIntentBytes: restoreIntentBytes
    )
    try inventoryWriteRecord(
      restoreIntentBytes,
      to: fixture.recordURL(".restore-intent-v1-\(restoreTransactionID)")
    )
    try inventoryWriteRecord(
      restoreReceiptBytes,
      to: fixture.recordURL(".restore-receipt-v1-\(restoreTransactionID)")
    )
    try FileManager.default.moveItem(at: completed.destination, to: fixture.candidateURL)

    let entries = try requireInventory(
      inventoryLoader(for: fixture).reconcileAndLoadInventory()
    )

    #expect(entries.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.candidateURL.path))
  }

  @Test("Restore preparation remains bound to the inventory's exact canonical records")
  func restorePreparationRejectsRecordSubstitution() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    _ = try completeQuarantine(in: fixture)
    let receiptBytes = try Data(
      contentsOf: fixture.recordURL(".receipt-v1-\(fixture.transactionID)")
    )
    let restoreTransactionID = String(repeating: "b", count: 32)

    let result = DescriptorQuarantineRestoreJournal(
      dependencies: descriptorJournalTestDependencies()
    ).prepare(
      DescriptorQuarantineRestorePreparationRequest(
        recoveryRequest: fixture.recoveryRequest(),
        quarantineTransactionID: fixture.transactionID,
        restoreTransactionID: restoreTransactionID,
        expectedCanonicalQuarantineIntentBytes: Data("substituted".utf8),
        expectedCanonicalQuarantineReceiptBytes: receiptBytes
      )
    )

    #expect(result == .failure(.transactionNotRestorable))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.recordURL(".restore-intent-v1-\(restoreTransactionID)").path
      )
    )
  }

  @Test("Malformed journal state fails atomically instead of returning a partial list")
  func malformedStateHasNoPartialSuccess() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    _ = try completeQuarantine(in: fixture)
    let sentinel = Data("unmanaged".utf8)
    let sentinelURL = fixture.recordURL("unmanaged-state")
    try inventoryWriteRecord(sentinel, to: sentinelURL)

    #expect(
      inventoryLoader(for: fixture).reconcileAndLoadInventory()
        == .failure(.journal(.unsafe))
    )
    #expect(try Data(contentsOf: sentinelURL) == sentinel)
  }

  @Test("A cancelled load never opens or reconciles the journal")
  func preCancelledLoadDoesNotReconcile() async throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    _ = try completeQuarantine(in: fixture)
    let lockAcquisitions = InventoryTestCounter()
    let inventoryReads = InventoryTestCounter()
    let loader = inventoryLoader(
      for: fixture,
      dependencies: descriptorJournalTestDependencies(
        hooks: DescriptorQuarantineJournalHooks(
          didAcquireLock: { lockAcquisitions.increment() },
          willReadInventory: { inventoryReads.increment() }
        )
      )
    )

    let result = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return loader.reconcileAndLoadInventory()
    }.value

    #expect(result == .failure(.cancelled))
    #expect(lockAcquisitions.value == 0)
    #expect(inventoryReads.value == 0)
  }

  @Test("Aggregate inventory traversal exhaustion fails without a partial list")
  func aggregateTraversalLimitHasNoPartialSuccess() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    _ = try completeQuarantine(in: fixture)

    let result = descriptorJournalReconcileAndLoadInventory(
      fixture.recoveryRequest(),
      dependencies: descriptorJournalTestDependencies(),
      maximumTraversalEntries: 0
    )

    #expect(result == .failure(.journal(.unavailable(.resourceLimit))))
  }

  @Test("A parent namespace change after the final reread prevents partial success")
  func parentChangeAfterRereadFailsAtomically() throws {
    let fixture = try DescriptorJournalTestFixture()
    defer { fixture.remove() }
    _ = try completeQuarantine(in: fixture)
    let inventoryEnumerations = InventoryTestCounter()
    let rootURL = fixture.rootURL
    let displacedRoot = fixture.baseURL.appendingPathComponent("displaced-npm")
    let dependencies = descriptorJournalTestDependencies(
      hooks: DescriptorQuarantineJournalHooks(
        didEnumerateInventory: {
          inventoryEnumerations.increment()
          guard inventoryEnumerations.value == 2 else { return }
          try? FileManager.default.moveItem(at: rootURL, to: displacedRoot)
        }
      )
    )

    let result = inventoryLoader(
      for: fixture,
      dependencies: dependencies
    ).reconcileAndLoadInventory()

    if case .success(let entries) = result {
      Issue.record("Unsafe parent drift returned \(entries.count) inventory entries")
    }
    #expect(inventoryEnumerations.value == 2)
  }

  @Test("References cannot cross otherwise identical inventory sessions")
  func referenceCannotCrossSessions() throws {
    let transactionID = String(repeating: "a", count: 32)
    let entry = readyDescriptorInventoryEntry(transactionID: transactionID)
    let prepareCalls = InventoryTestCounter()
    let workflow = QuarantineInventoryRestoreWorkflow(
      loadInventory: { .success([entry]) },
      prepareRestore: { _ in
        prepareCalls.increment()
        return .failure(.invalidClaim)
      },
      executeRestore: { _ in throw CancellationError() }
    )
    let first = try requireFrontendInventory(workflow.reconcileAndLoadInventory())
    let second = try requireFrontendInventory(workflow.reconcileAndLoadInventory())

    expectRestorePreparationFailure(
      .invalidInventoryReference,
      from: workflow.beginRestore(from: first, item: second.items[0].reference)
    )
    #expect(prepareCalls.value == 0)
  }

  @Test("A non-ready reference is rejected before restore preparation")
  func nonReadyReferenceDoesNotPrepare() throws {
    let entry = DescriptorQuarantineInventoryEntry(
      quarantineTransactionID: String(repeating: "a", count: 32),
      canonicalQuarantineIntentBytes: Data("intent".utf8),
      canonicalQuarantineReceiptBytes: Data("receipt".utf8),
      sourceState: .otherObjectPresent,
      itemState: .available,
      quarantineReceiptWasProducedByRecovery: false
    )
    let prepareCalls = InventoryTestCounter()
    let workflow = QuarantineInventoryRestoreWorkflow(
      loadInventory: { .success([entry]) },
      prepareRestore: { _ in
        prepareCalls.increment()
        return .failure(.invalidClaim)
      },
      executeRestore: { _ in throw CancellationError() }
    )
    let inventory = try requireFrontendInventory(workflow.reconcileAndLoadInventory())

    expectRestorePreparationFailure(
      .sourceOccupied,
      from: workflow.beginRestore(from: inventory, item: inventory.items[0].reference)
    )
    #expect(prepareCalls.value == 0)
  }

  @Test("Exact confirmation produces one single-use restore execution")
  func exactConfirmationExecutesOnce() async throws {
    let quarantineTransactionID = String(repeating: "1", count: 32)
    let entry = readyDescriptorInventoryEntry(transactionID: quarantineTransactionID)
    let evidence = try restoreAuthorizationEvidence(
      quarantineTransactionID: quarantineTransactionID
    )
    let report = CleanupQuarantineRestoreReport(
      quarantineTransactionID: quarantineTransactionID,
      restoreTransactionID: evidence.restoreIntent.restoreTransactionID,
      path: ScanRelativePath(rawComponents: [Array("_cacache".utf8)]),
      ruleRevision: try inventoryRuleRevision(),
      status: .restored(
        source: ScanRelativePath(rawComponents: [Array("_cacache".utf8)]),
        quarantineNameWasRecreated: false
      ),
      durabilityState: .receiptRecorded(
        restoreTransactionID: evidence.restoreIntent.restoreTransactionID,
        producedByRecovery: false
      )
    )
    let executor = CleanupQuarantineRestoreExecutor { _ in .success(report) }
    let workflow = QuarantineInventoryRestoreWorkflow(
      loadInventory: { .success([entry]) },
      prepareRestore: { entry in
        guard
          entry.quarantineTransactionID == quarantineTransactionID,
          entry.canonicalQuarantineIntentBytes
            == Data("intent:\(quarantineTransactionID)".utf8),
          entry.canonicalQuarantineReceiptBytes
            == Data("receipt:\(quarantineTransactionID)".utf8)
        else {
          return .failure(.invalidQuarantineTransactionID)
        }
        do {
          return .success(
            try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
          )
        } catch {
          return .failure(.authorization(.invalidPreparedEvidence))
        }
      },
      executeRestore: { try await executor.execute($0) }
    )
    let inventory = try requireFrontendInventory(workflow.reconcileAndLoadInventory())
    let session = try requireRestoreSession(
      workflow.beginRestore(from: inventory, item: inventory.items[0].reference)
    )
    #expect(!String(reflecting: session).contains(quarantineTransactionID))
    #expect(!String(reflecting: session.confirmationRequest).contains(quarantineTransactionID))
    #expect(session.confirmationRequest.responsibleTool == "npm")
    #expect(session.confirmationRequest.originalName == "_cacache")
    #expect(
      session.confirmationRequest.requiredStatement.rawValue
        == "restore-current-quarantined-contents-to-original-cacache-without-overwrite-with-npm-stopped-and-post-quarantine-changes-accepted"
    )
    let foreignSession = try requireRestoreSession(
      workflow.beginRestore(from: inventory, item: inventory.items[0].reference)
    )
    do {
      _ = try await session.authorize(
        using: QuarantineRestoreUserConfirmation(
          request: foreignSession.confirmationRequest,
          statement: foreignSession.confirmationRequest.requiredStatement
        )
      )
      Issue.record("A confirmation from another restore attempt was accepted")
    } catch let failure as QuarantineRestoreAuthorizationFailure {
      #expect(failure == .confirmationDoesNotBelongToAttempt)
    } catch {
      Issue.record("Unexpected foreign-confirmation failure: \(error)")
    }
    let authorization = try await session.authorize(
      using: QuarantineRestoreUserConfirmation(
        request: session.confirmationRequest,
        statement: session.confirmationRequest.requiredStatement
      )
    )
    #expect(!String(reflecting: authorization).contains(quarantineTransactionID))

    let first = await workflow.execute(authorization)
    let second = await workflow.execute(authorization)

    switch first {
    case .success(let outcome):
      #expect(outcome.isDurablyRestored)
      #expect(outcome.status == .restored(quarantineNameWasRecreated: false))
      #expect(outcome.durability == .receiptRecorded(producedByRecovery: false))
      #expect(!outcome.performedPermanentDeletion)
      #expect(!outcome.overwroteExistingItem)
    case .failure(let failure):
      Issue.record("First restore unexpectedly failed: \(failure)")
    }
    #expect(second == .failure(.authorizationAlreadyConsumed))
  }
}

private struct CompletedInventoryQuarantine {
  let intent: QuarantineJournalIntentV1
  let destination: URL
}

private func completeQuarantine(
  in fixture: DescriptorJournalTestFixture
) throws -> CompletedInventoryQuarantine {
  try installValidCacacheTree(at: fixture.candidateURL)
  let journal = DescriptorQuarantineJournal(
    dependencies: descriptorJournalTestDependencies()
  )
  let session = try fixture.requireSession(from: journal)
  let intent = session.intent
  let destination = try inventoryDestinationURL(intent.destinationComponents[0], fixture: fixture)
  try FileManager.default.moveItem(at: fixture.candidateURL, to: destination)
  guard
    case .receiptRecorded = journal.finish(
      session,
      outcome: .quarantined(
        selectedDestinationOrdinal: 0,
        sourceNameWasRecreated: false
      ),
      namespaceMutationMayHaveBeenInvoked: true
    )
  else {
    throw InventoryTestError.couldNotCompleteQuarantine
  }
  return CompletedInventoryQuarantine(intent: intent, destination: destination)
}

private func completeAdditionalQuarantine(
  in fixture: DescriptorJournalTestFixture,
  transactionID: String,
  destinationSeed: Int
) throws -> CompletedInventoryQuarantine {
  try installValidCacacheTree(at: fixture.candidateURL)
  let candidateDescriptor = Darwin.open(
    fixture.candidateURL.path,
    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
  )
  guard candidateDescriptor >= 0 else {
    throw InventoryTestError.couldNotCompleteQuarantine
  }
  defer { descriptorCloseIgnoringErrors(candidateDescriptor) }

  let root = try DescriptorStatSnapshot.read(
    from: fixture.rootDescriptor,
    cancellationPolicy: .ignoreTaskCancellation
  )
  let quarantine = try DescriptorStatSnapshot.read(
    from: fixture.quarantineDescriptor,
    cancellationPolicy: .ignoreTaskCancellation
  )
  let candidate = try DescriptorStatSnapshot.read(
    from: candidateDescriptor,
    cancellationPolicy: .ignoreTaskCancellation
  )
  guard
    let rootBinding = QuarantineJournalFileBindingV1(snapshot: root),
    let quarantineBinding = QuarantineJournalFileBindingV1(snapshot: quarantine),
    let candidateBinding = QuarantineJournalFileBindingV1(snapshot: candidate)
  else {
    throw InventoryTestError.couldNotCompleteQuarantine
  }
  let intent = QuarantineJournalIntentV1(
    transactionID: transactionID,
    npmRootBinding: rootBinding,
    quarantineRootBinding: quarantineBinding,
    candidateBinding: candidateBinding,
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<16).map { ordinal in
      Array("item-v1-\(String(format: "%032x", destinationSeed + ordinal + 1))".utf8)
    },
    policy: .current
  )
  let journal = DescriptorQuarantineJournal(
    dependencies: descriptorJournalTestDependencies()
  )
  let session: DescriptorQuarantineJournalSession
  switch journal.begin(
    DescriptorQuarantineJournalBeginRequest(
      rootDescriptor: fixture.rootDescriptor,
      quarantineRootDescriptor: fixture.quarantineDescriptor,
      candidateDescriptor: candidateDescriptor,
      quarantineRootComponent: DescriptorPathComponent(
        Array(".devsift-quarantine-v1".utf8)
      )!,
      absoluteRootComponents: fixture.absoluteRootComponents,
      homeComponentCount: fixture.homeComponentCount,
      accountUID: fixture.accountUID,
      intent: intent
    )
  ) {
  case .success(let value):
    session = value
  case .failure:
    throw InventoryTestError.couldNotCompleteQuarantine
  }
  let destination = try inventoryDestinationURL(
    intent.destinationComponents[0],
    fixture: fixture
  )
  try FileManager.default.moveItem(at: fixture.candidateURL, to: destination)
  guard
    case .receiptRecorded = journal.finish(
      session,
      outcome: .quarantined(
        selectedDestinationOrdinal: 0,
        sourceNameWasRecreated: false
      ),
      namespaceMutationMayHaveBeenInvoked: true
    )
  else {
    throw InventoryTestError.couldNotCompleteQuarantine
  }
  return CompletedInventoryQuarantine(intent: intent, destination: destination)
}

private func installValidCacacheTree(at root: URL) throws {
  let contentDirectory = root.appendingPathComponent("content-v2/sha512/aa/bb")
  let indexDirectory = root.appendingPathComponent("index-v5/aa/bb")
  let temporaryDirectory = root.appendingPathComponent("tmp")
  try FileManager.default.createDirectory(
    at: contentDirectory,
    withIntermediateDirectories: true
  )
  try FileManager.default.createDirectory(
    at: indexDirectory,
    withIntermediateDirectories: true
  )
  try FileManager.default.createDirectory(
    at: temporaryDirectory,
    withIntermediateDirectories: false
  )
  try Data([1, 2, 3]).write(
    to: contentDirectory.appendingPathComponent("0123456789abcdef"),
    options: .withoutOverwriting
  )
  try Data([4, 5]).write(
    to: indexDirectory.appendingPathComponent(
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab"
    ),
    options: .withoutOverwriting
  )
}

private func inventoryLoader(
  for fixture: DescriptorJournalTestFixture,
  dependencies: DescriptorQuarantineJournalDependencies = descriptorJournalTestDependencies()
) -> DescriptorNPMQuarantineInventoryLoader {
  let rawHome = rawNPMPreflightPathBytes(fixture.baseURL)
  return DescriptorNPMQuarantineInventoryLoader(
    dependencies: dependencies,
    rawHomeProvider: { .known(rawHome) },
    accountUIDProvider: { .known(Darwin.getuid()) },
    supportsDurableMutation: { true }
  )
}

private func inventoryDestinationURL(
  _ bytes: [UInt8],
  fixture: DescriptorJournalTestFixture
) throws -> URL {
  guard let name = String(bytes: bytes, encoding: .utf8) else {
    throw InventoryTestError.invalidDestination
  }
  return fixture.quarantineURL.appendingPathComponent(name, isDirectory: true)
}

private func inventoryWriteRecord(_ bytes: Data, to url: URL) throws {
  try bytes.write(to: url, options: .withoutOverwriting)
  try descriptorJournalTestChmod(url, mode: 0o600)
}

private func requireInventory(
  _ result: DescriptorQuarantineInventoryResult
) throws -> [DescriptorQuarantineInventoryEntry] {
  switch result {
  case .success(let entries):
    return entries
  case .failure(let failure):
    throw InventoryTestError.inventory(failure)
  }
}

private func requireFrontendInventory(
  _ result: Result<QuarantineInventorySession, QuarantineInventoryLoadFailure>
) throws -> QuarantineInventorySession {
  switch result {
  case .success(let session):
    return session
  case .failure(let failure):
    throw InventoryTestError.frontendInventory(failure)
  }
}

private func requireRestoreSession(
  _ result: Result<QuarantineRestoreAuthorizationSession, QuarantineRestorePreparationFailure>
) throws -> QuarantineRestoreAuthorizationSession {
  switch result {
  case .success(let session):
    return session
  case .failure(let failure):
    throw InventoryTestError.restorePreparation(failure)
  }
}

private func expectRestorePreparationFailure(
  _ expected: QuarantineRestorePreparationFailure,
  from result: Result<QuarantineRestoreAuthorizationSession, QuarantineRestorePreparationFailure>
) {
  switch result {
  case .success:
    Issue.record("Expected restore preparation failure \(expected)")
  case .failure(let failure):
    #expect(failure == expected)
  }
}

private func workflowLoading(
  _ entries: [DescriptorQuarantineInventoryEntry]
) -> QuarantineInventoryRestoreWorkflow {
  QuarantineInventoryRestoreWorkflow(
    loadInventory: { .success(entries) },
    prepareRestore: { _ in .failure(.invalidClaim) },
    executeRestore: { _ in throw CancellationError() }
  )
}

private func readyDescriptorInventoryEntry(
  transactionID: String
) -> DescriptorQuarantineInventoryEntry {
  DescriptorQuarantineInventoryEntry(
    quarantineTransactionID: transactionID,
    canonicalQuarantineIntentBytes: Data("intent:\(transactionID)".utf8),
    canonicalQuarantineReceiptBytes: Data("receipt:\(transactionID)".utf8),
    sourceState: .missing,
    itemState: .available,
    quarantineReceiptWasProducedByRecovery: false
  )
}

private func inventoryRuleRevision() throws -> RuleRevision {
  guard
    let identifier = RuleIdentifier(rawValue: "devsift.cache.npm"),
    let version = RuleVersion(rawValue: 5)
  else {
    throw InventoryTestError.invalidRevision
  }
  return RuleRevision(identifier: identifier, version: version)
}

private final class InventoryTestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

private enum InventoryTestError: Error {
  case couldNotCompleteQuarantine
  case frontendInventory(QuarantineInventoryLoadFailure)
  case invalidDestination
  case invalidRevision
  case inventory(DescriptorQuarantineInventoryFailure)
  case restorePreparation(QuarantineRestorePreparationFailure)
}
