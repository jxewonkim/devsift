import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor quarantine purge retry, terminalization, and recovery", .serialized)
struct DescriptorQuarantinePurgeCompletionTests {
  @Test("Retry holds the exact existing intent and invokes no publication rename")
  func retryCreatesNoIntentAndInvokesNoRename() async throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.arrange(.work)
    let retry = try completionRetryEntry(fixture)
    let claim = try await completionPurgeClaim(.explicitRetry(retry))
    let workURL = try fixture.purgeWorkURL(for: fixture.purgeIntent)
    let workDescriptor = try completionOpenDirectory(workURL)
    defer { descriptorCloseIgnoringErrors(workDescriptor) }
    let namesBefore = try fixture.quarantineNames()
    let recorder = CompletionRenameRecorder()
    var dependencies = fixture.dependencies
    dependencies.renameExclusive = { root, source, destination, flags in
      recorder.record()
      return descriptorJournalTestRenameExclusive(
        quarantineRootDescriptor: root,
        source: source,
        destination: destination,
        flags: flags
      )
    }

    let result = DescriptorQuarantinePurgeRetryJournal(
      dependencies: dependencies
    ).begin(
      DescriptorQuarantinePurgeRetryJournalRequest(
        recoveryRequest: fixture.filesystem.recoveryRequest(),
        purgeWorkDescriptor: workDescriptor,
        claim: claim
      ))

    switch result {
    case .success(let retrySession):
      #expect(retrySession.journalSession.attemptKind == .explicitRetry)
      #expect(retrySession.journalSession.canonicalIntentBytes == fixture.purgeIntentBytes)
      retrySession.journalSession.releasePreservingIntent()
    case .failure(let failure):
      Issue.record("retry unexpectedly failed: \(failure)")
    }
    #expect(recorder.count == 0)
    #expect(try fixture.quarantineNames() == namesBefore)
  }

  @Test("Retry refuses a stale work selection and preserves both objects")
  func retryRejectsStaleWorkBinding() async throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.arrange(.work)
    let retry = try completionRetryEntry(fixture)
    let claim = try await completionPurgeClaim(.explicitRetry(retry))
    let workURL = try fixture.purgeWorkURL(for: fixture.purgeIntent)
    let staleDescriptor = try completionOpenDirectory(workURL)
    defer { descriptorCloseIgnoringErrors(staleDescriptor) }
    let preservedURL = fixture.filesystem.baseURL.appendingPathComponent(
      "preserved-stale-work",
      isDirectory: true
    )
    try FileManager.default.moveItem(at: workURL, to: preservedURL)
    try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: false)
    try descriptorJournalTestChmod(workURL, mode: 0o700)

    let result = DescriptorQuarantinePurgeRetryJournal(
      dependencies: fixture.dependencies
    ).begin(
      DescriptorQuarantinePurgeRetryJournalRequest(
        recoveryRequest: fixture.filesystem.recoveryRequest(),
        purgeWorkDescriptor: staleDescriptor,
        claim: claim
      ))

    switch result {
    case .success(let session):
      session.journalSession.releasePreservingIntent()
      Issue.record("stale work selection unexpectedly resumed")
    case .failure:
      break
    }
    #expect(FileManager.default.fileExists(atPath: preservedURL.path))
    #expect(FileManager.default.fileExists(atPath: workURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.filesystem.recordURL(
          ".purge-receipt-v1-\(fixture.purgeTransactionID)"
        ).path
      )
    )
  }

  @Test("Terminalizer records not-purged only for exact Q and missing W")
  func terminalizerRecordsNotPurged() async throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    let journalSession = try await completionBeginInitialPurge(fixture)
    let expectedDevice = fixture.purgeIntent.capacityBefore.volumeIdentity.device

    var terminalDependencies = fixture.dependencies
    terminalDependencies.purgeCapacityObserver =
      DescriptorQuarantinePurgeCapacityObserver(
        dependencies: DescriptorQuarantinePurgeCapacityObserverDependencies(
          fstat: { _ in
            .success(
              DescriptorQuarantinePurgeFStatValue(
                device: expectedDevice
              ))
          },
          fstatfs: { _ in
            .success(
              DescriptorQuarantinePurgeFStatFSValue(
                blockSize: 1,
                availableBlockCount: 1_500_000,
                fileSystemIDFirst: 17,
                fileSystemIDSecond: 23
              ))
          }
        ))
    let result = DescriptorQuarantinePurgeTerminalizer(
      dependencies: terminalDependencies
    ).terminalize(
      DescriptorQuarantinePurgeTerminalizationRequest(
        journalSession: journalSession,
        outcome: .notPurged,
        capacityObservationProvenance: .initialAttempt
      ))

    switch result {
    case .receiptRecorded(let receipt, let capacityChange):
      #expect(receipt.outcome == .notPurged)
      #expect(!receipt.producedByRecovery)
      #expect(receipt.capacityObservationProvenance == .initialAttempt)
      #expect(capacityChange == .increase(amount: 500_000))
      #expect(
        receipt.capacityAfter
          == .available(
            QuarantinePurgeCapacityObservationV1(
              volumeIdentity: fixture.purgeIntent.capacityBefore.volumeIdentity,
              availableBytes: 1_500_000
            ))
      )
    case .retryRequired, .manualRecoveryRequired, .invalidSession:
      Issue.record("not-purged terminalization failed: \(result)")
    }
    #expect(FileManager.default.fileExists(atPath: fixture.quarantineItemURL.path))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.filesystem.recordURL(
          ".purge-receipt-v1-\(fixture.purgeTransactionID)"
        ).path
      )
    )
    #expect(
      DescriptorQuarantinePurgeTerminalizer(
        dependencies: fixture.dependencies
      ).terminalize(
        DescriptorQuarantinePurgeTerminalizationRequest(
          journalSession: journalSession,
          outcome: .notPurged,
          capacityObservationProvenance: .initialAttempt
        )) == .invalidSession
    )
  }

  @Test("Terminalizer records item-absent only after both managed names are absent")
  func terminalizerRecordsItemAbsent() async throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    let journalSession = try await completionBeginInitialPurge(fixture)
    let workURL = try fixture.purgeWorkURL(for: fixture.purgeIntent)
    try FileManager.default.moveItem(at: fixture.quarantineItemURL, to: workURL)
    try FileManager.default.removeItem(at: workURL)

    let result = DescriptorQuarantinePurgeTerminalizer(
      dependencies: fixture.dependencies
    ).terminalize(
      DescriptorQuarantinePurgeTerminalizationRequest(
        journalSession: journalSession,
        outcome: .itemAbsent,
        capacityObservationProvenance: .initialAttempt
      ))

    guard case .receiptRecorded(let receipt, _) = result else {
      Issue.record("item-absent terminalization failed: \(result)")
      return
    }
    #expect(receipt.outcome == .itemAbsent)
    #expect(!receipt.quarantineNameWasRecreated)
  }

  @Test("A synchronized work remainder requires retry and gets no receipt")
  func partialWorkGetsNoReceiptAndBlocksRestore() async throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    let journalSession = try await completionBeginInitialPurge(fixture)
    let workURL = try fixture.purgeWorkURL(for: fixture.purgeIntent)
    try FileManager.default.moveItem(at: fixture.quarantineItemURL, to: workURL)

    let result = DescriptorQuarantinePurgeTerminalizer(
      dependencies: fixture.dependencies
    ).terminalize(
      DescriptorQuarantinePurgeTerminalizationRequest(
        journalSession: journalSession,
        outcome: .itemAbsent,
        capacityObservationProvenance: .initialAttempt
      ))

    #expect(result == .retryRequired)
    #expect(FileManager.default.fileExists(atPath: workURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.filesystem.recordURL(
          ".purge-receipt-v1-\(fixture.purgeTransactionID)"
        ).path
      )
    )
    #expect(
      fixture.restoreJournal.prepare(fixture.restorePreparationRequest())
        == .failure(.transactionNotRestorable)
    )
  }

  @Test("An explicit retry records item-absent with retry provenance")
  func explicitRetryRecordsItemAbsent() async throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.arrange(.work)
    let retry = try completionRetryEntry(fixture)
    let claim = try await completionPurgeClaim(.explicitRetry(retry))
    let workURL = try fixture.purgeWorkURL(for: fixture.purgeIntent)
    let workDescriptor = try completionOpenDirectory(workURL)
    defer { descriptorCloseIgnoringErrors(workDescriptor) }
    let retrySession: DescriptorQuarantinePurgeRetrySession
    switch DescriptorQuarantinePurgeRetryJournal(
      dependencies: fixture.dependencies
    ).begin(
      DescriptorQuarantinePurgeRetryJournalRequest(
        recoveryRequest: fixture.filesystem.recoveryRequest(),
        purgeWorkDescriptor: workDescriptor,
        claim: claim
      ))
    {
    case .success(let session):
      retrySession = session
    case .failure(let failure):
      Issue.record("retry begin failed: \(failure)")
      return
    }
    try FileManager.default.removeItem(at: workURL)

    let result = DescriptorQuarantinePurgeTerminalizer(
      dependencies: fixture.dependencies
    ).terminalize(
      DescriptorQuarantinePurgeTerminalizationRequest(
        journalSession: retrySession.journalSession,
        outcome: .itemAbsent,
        capacityObservationProvenance: .explicitRetry
      ))

    guard case .receiptRecorded(let receipt, _) = result else {
      Issue.record("retry item-absent terminalization failed: \(result)")
      return
    }
    #expect(receipt.outcome == .itemAbsent)
    #expect(receipt.capacityObservationProvenance == .explicitRetry)
    #expect(!receipt.producedByRecovery)
  }

  @Test("Recovery terminalizes Q-only and absent states but projects exact W")
  func recoveryProjectsThreePurgeStates() throws {
    let notPurged = try DescriptorPurgeInventoryFixture()
    defer { notPurged.remove() }
    try notPurged.writePurgeIntent(notPurged.purgeIntentBytes, staged: false)
    let notPurgedSummary = try requirePurgeInventoryRecovery(
      notPurged.journal.recover(notPurged.filesystem.recoveryRequest())
    )
    #expect(notPurgedSummary.recoveredPurgeReceipts.count == 1)
    #expect(notPurgedSummary.recoveredPurgeReceipts.first?.outcome == .notPurged)
    #expect(notPurgedSummary.recoveredPurgeReceipts.first?.producedByRecovery == true)

    let retry = try DescriptorPurgeInventoryFixture()
    defer { retry.remove() }
    try retry.arrange(.work)
    let retryEntries = try completionInventoryEntries(retry)
    #expect(retryEntries.count == 1)
    #expect(retryEntries.first?.purgeRetry != nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: retry.filesystem.recordURL(
          ".purge-receipt-v1-\(retry.purgeTransactionID)"
        ).path
      )
    )

    let absent = try DescriptorPurgeInventoryFixture()
    defer { absent.remove() }
    try absent.writePurgeIntent(absent.purgeIntentBytes, staged: false)
    try FileManager.default.removeItem(at: absent.quarantineItemURL)
    let absentSummary = try requirePurgeInventoryRecovery(
      absent.journal.recover(absent.filesystem.recoveryRequest())
    )
    #expect(absentSummary.recoveredPurgeReceipts.count == 1)
    #expect(absentSummary.recoveredPurgeReceipts.first?.outcome == .itemAbsent)
  }

  @Test("Recovery preserves a safely recreated Q while projecting exact W")
  func recoveryPreservesRecreatedQuarantineName() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.arrange(.work)
    try FileManager.default.createDirectory(
      at: fixture.quarantineItemURL,
      withIntermediateDirectories: false
    )
    try descriptorJournalTestChmod(fixture.quarantineItemURL, mode: 0o700)

    let entries = try completionInventoryEntries(fixture)
    let workURL = try fixture.purgeWorkURL(for: fixture.purgeIntent)

    #expect(entries.first?.purgeRetry != nil)
    #expect(FileManager.default.fileExists(atPath: fixture.quarantineItemURL.path))
    #expect(FileManager.default.fileExists(atPath: workURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.filesystem.recordURL(
          ".purge-receipt-v1-\(fixture.purgeTransactionID)"
        ).path
      )
    )
  }

  @Test("Unsafe work state remains receipt-less and requires manual recovery")
  func unsafeWorkRequiresManualRecovery() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.arrange(.work)
    let workURL = try fixture.purgeWorkURL(for: fixture.purgeIntent)
    try descriptorJournalTestChmod(workURL, mode: 0o777)

    let result = descriptorJournalReconcileAndLoadInventory(
      fixture.filesystem.recoveryRequest(),
      dependencies: fixture.dependencies
    )

    #expect(
      result
        == .failure(
          .journal(
            .recoveryRequired(transactionID: fixture.purgeTransactionID)
          ))
    )
    #expect(FileManager.default.fileExists(atPath: workURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.filesystem.recordURL(
          ".purge-receipt-v1-\(fixture.purgeTransactionID)"
        ).path
      )
    )
  }

  @Test("Retry inventory selection is opaque, session-bound, and non-authorizing")
  func retryInventorySelectionIsOpaqueAndSessionBound() throws {
    let fixture = try DescriptorPurgeInventoryFixture()
    defer { fixture.remove() }
    try fixture.arrange(.work)
    let entries = try completionInventoryEntries(fixture)
    let workflow = completionInventoryWorkflow(entries)
    let first = try completionInventorySession(workflow)
    let second = try completionInventorySession(workflow)
    #expect(first.purgeRetries.count == 1)
    guard let reference = first.purgeRetries.first?.reference else {
      Issue.record("missing retry reference")
      return
    }
    switch workflow.selectForPurgeRetry(from: first, retry: reference) {
    case .success(let selection):
      #expect(!selection.isAuthorization)
      #expect(!selection.authorizesPermanentDeletion)
      #expect(!String(reflecting: selection).contains(fixture.purgeTransactionID))
    case .failure(let failure):
      Issue.record("exact retry selection failed: \(failure)")
    }
    switch workflow.selectForPurgeRetry(from: second, retry: reference) {
    case .success:
      Issue.record("foreign retry reference unexpectedly resolved")
    case .failure(let failure):
      #expect(failure == .invalidInventoryReference)
    }
  }
}

private final class CompletionRenameRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func record() {
    lock.lock()
    value += 1
    lock.unlock()
  }
}

private func completionPurgeClaim(
  _ evidence: CleanupQuarantinePurgePreparedEvidence
) async throws -> CleanupQuarantinePurgeExecutionClaim {
  let attempt = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: evidence)
  let authorization = try await attempt.authorize(
    using: CleanupQuarantinePurgeUserConfirmation(
      request: attempt.confirmationRequest,
      statement: attempt.confirmationRequest.requiredStatement
    ))
  return try await authorization.consumeForExecution()
}

private func completionBeginInitialPurge(
  _ fixture: DescriptorPurgeInventoryFixture
) async throws -> DescriptorQuarantinePurgeJournalSession {
  let claim = try await completionPurgeClaim(
    .initial(
      CleanupQuarantinePurgeInitialPreparedEvidence(
        canonicalQuarantineIntentBytes: fixture.quarantineIntentBytes,
        canonicalQuarantineReceiptBytes: fixture.quarantineReceiptBytes,
        purgeIntent: fixture.purgeIntent
      )))
  switch DescriptorQuarantinePurgeJournal(
    dependencies: DescriptorQuarantinePurgeJournalDependencies(
      journal: fixture.dependencies
    )
  ).begin(
    DescriptorQuarantinePurgeJournalBeginRequest(
      recoveryRequest: fixture.filesystem.recoveryRequest(),
      quarantinedItemDescriptor: fixture.filesystem.candidateDescriptor,
      claim: claim
    ))
  {
  case .success(let session):
    return session
  case .failure(let failure):
    throw CompletionPurgeTestError.begin(failure)
  }
}

private func completionRetryEntry(
  _ fixture: DescriptorPurgeInventoryFixture
) throws -> CleanupQuarantinePurgeRetryPreparedEvidence {
  let entries = try completionInventoryEntries(fixture)
  guard let retry = entries.first?.purgeRetry else {
    throw CompletionPurgeTestError.missingRetry
  }
  return CleanupQuarantinePurgeRetryPreparedEvidence(
    canonicalQuarantineIntentBytes: retry.canonicalQuarantineIntentBytes,
    canonicalQuarantineReceiptBytes: retry.canonicalQuarantineReceiptBytes,
    purgeIntent: retry.purgeIntent,
    canonicalPurgeIntentBytes: retry.canonicalPurgeIntentBytes,
    currentWorkBinding: retry.currentWorkBinding
  )
}

private func completionInventoryEntries(
  _ fixture: DescriptorPurgeInventoryFixture
) throws -> [DescriptorQuarantineInventoryEntry] {
  switch descriptorJournalReconcileAndLoadInventory(
    fixture.filesystem.recoveryRequest(),
    dependencies: fixture.dependencies
  ) {
  case .success(let entries):
    return entries
  case .failure(let failure):
    throw CompletionPurgeTestError.inventory(failure)
  }
}

private func completionInventoryWorkflow(
  _ entries: [DescriptorQuarantineInventoryEntry]
) -> QuarantineInventoryRestoreWorkflow {
  QuarantineInventoryRestoreWorkflow(
    loadInventory: { .success(entries) },
    prepareRestore: { _ in fatalError("not used") },
    executeRestore: { _ in fatalError("not used") }
  )
}

private func completionInventorySession(
  _ workflow: QuarantineInventoryRestoreWorkflow
) throws -> QuarantineInventorySession {
  switch workflow.reconcileAndLoadInventory() {
  case .success(let session):
    return session
  case .failure(let failure):
    throw CompletionPurgeTestError.workflow(failure)
  }
}

private func completionOpenDirectory(_ url: URL) throws -> Int32 {
  let descriptor = Darwin.open(
    url.path,
    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
  )
  guard descriptor >= 0 else { throw CompletionPurgeTestError.posix(errno) }
  return descriptor
}

private enum CompletionPurgeTestError: Error {
  case begin(DescriptorQuarantinePurgeFailure)
  case inventory(DescriptorQuarantineInventoryFailure)
  case workflow(QuarantineInventoryLoadFailure)
  case missingRetry
  case posix(Int32)
}
