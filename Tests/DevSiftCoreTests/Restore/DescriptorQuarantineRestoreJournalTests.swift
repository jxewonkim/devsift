import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor quarantine restore journal facade")
struct DescriptorQuarantineRestoreJournalTests {
  @Test("Injected operations receive the exact requests and finish a session once")
  func injectedFacadeAndOneShotFinish() async throws {
    let bundle = try restoreJournalTestBundle()
    let claim = try await restoreJournalTestClaim(for: bundle.evidence)
    let session = restoreJournalTestSession(from: bundle)
    let receipt = try QuarantineRestoreJournalV1Codec.makeReceipt(
      outcome: .restored,
      quarantineNameWasRecreated: true,
      producedByRecovery: false,
      canonicalRestoreIntentBytes: bundle.canonicalRestoreIntentBytes
    )
    let probe = RestoreJournalFacadeProbe(expectedSession: session)
    let journal = DescriptorQuarantineRestoreJournal(
      prepare: { request in
        probe.recordPrepare(request)
        return .success(bundle.evidence)
      },
      begin: { request in
        probe.recordBegin(request)
        return .success(session)
      },
      finish: { receivedSession, outcome, mutationMayHaveBeenInvoked in
        probe.recordFinish(
          session: receivedSession,
          outcome: outcome,
          mutationMayHaveBeenInvoked: mutationMayHaveBeenInvoked
        )
        return .receiptRecorded(receipt)
      }
    )
    let recoveryRequest = restoreJournalTestRecoveryRequest()
    let preparationRequest = DescriptorQuarantineRestorePreparationRequest(
      recoveryRequest: recoveryRequest,
      quarantineTransactionID: bundle.evidence.restoreIntent.quarantineTransactionID,
      restoreTransactionID: bundle.evidence.restoreIntent.restoreTransactionID
    )

    #expect(journal.prepare(preparationRequest) == .success(bundle.evidence))

    let beginRequest = DescriptorQuarantineRestoreJournalBeginRequest(
      recoveryRequest: recoveryRequest,
      quarantinedItemDescriptor: 103,
      claim: claim
    )
    switch journal.begin(beginRequest) {
    case .success(let receivedSession):
      #expect(receivedSession === session)
    case .failure(let failure):
      Issue.record("Injected begin unexpectedly failed: \(failure)")
    }

    let terminalOutcome = DescriptorQuarantineRestoreJournalTerminalOutcome.restored(
      quarantineNameWasRecreated: true
    )
    #expect(
      journal.finish(
        session,
        outcome: terminalOutcome,
        namespaceMutationMayHaveBeenInvoked: true
      ) == .receiptRecorded(receipt)
    )
    #expect(
      journal.finish(
        session,
        outcome: .unresolved,
        namespaceMutationMayHaveBeenInvoked: false
      ) == .invalidSession
    )

    let observation = probe.observation
    #expect(observation.prepareCallCount == 1)
    #expect(
      observation.preparedQuarantineTransactionID
        == bundle.evidence.restoreIntent.quarantineTransactionID
    )
    #expect(
      observation.preparedRestoreTransactionID
        == bundle.evidence.restoreIntent.restoreTransactionID
    )
    #expect(observation.beginCallCount == 1)
    #expect(observation.quarantinedItemDescriptor == 103)
    #expect(observation.finishCallCount == 1)
    #expect(observation.finishedSessionWasExpected)
    #expect(observation.terminalOutcome == terminalOutcome)
    #expect(observation.namespaceMutationMayHaveBeenInvoked == true)
  }

  @Test("A non-receipt finish result still consumes the session")
  func recoveryRequiredFinishIsOneShot() throws {
    let bundle = try restoreJournalTestBundle()
    let session = restoreJournalTestSession(from: bundle)
    let finishCalls = RestoreJournalFinishCounter()
    let journal = DescriptorQuarantineRestoreJournal(
      prepare: { _ in .failure(.transactionNotFound) },
      begin: { _ in .failure(.invalidClaim) },
      finish: { _, _, _ in
        finishCalls.record()
        return .recoveryRequired(
          restoreTransactionID: bundle.evidence.restoreIntent.restoreTransactionID
        )
      }
    )

    #expect(
      journal.finish(
        session,
        outcome: .unresolved,
        namespaceMutationMayHaveBeenInvoked: true
      )
        == .recoveryRequired(
          restoreTransactionID: bundle.evidence.restoreIntent.restoreTransactionID
        )
    )
    #expect(
      journal.finish(
        session,
        outcome: .notRestored(sourceNameWasOccupied: false),
        namespaceMutationMayHaveBeenInvoked: false
      ) == .invalidSession
    )
    #expect(finishCalls.callCount == 1)
  }

  @Test("Recovery summaries default to no restore activity")
  func recoverySummaryRestoreDefaults() {
    let summary = DescriptorQuarantineJournalRecoverySummary(
      recoveredReceipts: [],
      validatedTransactionCount: 7
    )

    #expect(summary.recoveredReceipts.isEmpty)
    #expect(summary.validatedTransactionCount == 7)
    #expect(summary.recoveredRestoreReceipts.isEmpty)
    #expect(summary.validatedRestoreTransactionCount == 0)
  }
}

private struct RestoreJournalTestBundle: Sendable {
  let evidence: CleanupQuarantineRestorePreparedEvidence
  let canonicalRestoreIntentBytes: Data
}

private func restoreJournalTestBundle() throws -> RestoreJournalTestBundle {
  let quarantineIntent = QuarantineJournalIntentV1(
    transactionID: String(repeating: "1", count: 32),
    npmRootBinding: restoreJournalTestBinding(inode: 10),
    quarantineRootBinding: restoreJournalTestBinding(inode: 20),
    candidateBinding: restoreJournalTestBinding(inode: 30),
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<QuarantineJournalIntentV1.destinationCount).map {
      restoreJournalTestItemComponent($0)
    }
  )
  let quarantineIntentBytes = try QuarantineJournalV1Codec.encode(quarantineIntent)
  let quarantineReceipt = try QuarantineJournalV1Codec.makeReceipt(
    outcome: .quarantined,
    selectedDestinationOrdinal: 3,
    producedByRecovery: false,
    canonicalIntentBytes: quarantineIntentBytes
  )
  let quarantineReceiptBytes = try QuarantineJournalV1Codec.encode(
    quarantineReceipt,
    matchingIntentBytes: quarantineIntentBytes
  )
  let restoreIntent = try QuarantineRestoreJournalV1Codec.makeIntent(
    restoreTransactionID: String(repeating: "a", count: 32),
    canonicalQuarantineIntentBytes: quarantineIntentBytes,
    canonicalQuarantineReceiptBytes: quarantineReceiptBytes
  )
  let restoreIntentBytes = try QuarantineRestoreJournalV1Codec.encode(
    restoreIntent,
    matchingQuarantineIntentBytes: quarantineIntentBytes,
    matchingQuarantineReceiptBytes: quarantineReceiptBytes
  )
  return RestoreJournalTestBundle(
    evidence: CleanupQuarantineRestorePreparedEvidence(
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes,
      restoreIntent: restoreIntent
    ),
    canonicalRestoreIntentBytes: restoreIntentBytes
  )
}

private func restoreJournalTestClaim(
  for evidence: CleanupQuarantineRestorePreparedEvidence
) async throws -> CleanupQuarantineRestoreExecutionClaim {
  let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
  let confirmation = CleanupQuarantineRestoreUserConfirmation(
    request: session.confirmationRequest,
    statement: session.confirmationRequest.requiredStatement
  )
  let authorization = try await session.authorize(using: confirmation)
  return try await authorization.consumeForExecution()
}

private func restoreJournalTestSession(
  from bundle: RestoreJournalTestBundle
) -> DescriptorQuarantineRestoreJournalSession {
  let snapshot = DescriptorStatSnapshot(information: stat())
  return DescriptorQuarantineRestoreJournalSession.testing(
    intent: bundle.evidence.restoreIntent,
    canonicalIntentBytes: bundle.canonicalRestoreIntentBytes,
    rootSnapshotAfterIntent: snapshot,
    quarantineRootSnapshotAfterIntent: snapshot
  )
}

private func restoreJournalTestRecoveryRequest() -> DescriptorQuarantineJournalRecoveryRequest {
  DescriptorQuarantineJournalRecoveryRequest(
    rootDescriptor: 101,
    quarantineRootDescriptor: 102,
    quarantineRootComponent: DescriptorPathComponent(
      Array(".devsift-quarantine-v1".utf8)
    )!,
    absoluteRootComponents: [DescriptorPathComponent(Array("fixture".utf8))!],
    homeComponentCount: 0,
    accountUID: 501
  )
}

private func restoreJournalTestBinding(inode: UInt64) -> QuarantineJournalFileBindingV1 {
  QuarantineJournalFileBindingV1(
    device: 7,
    inode: inode,
    generation: 11,
    birthSeconds: 1_725_000_000,
    birthNanoseconds: 123_456_789,
    kind: .directory,
    ownerUID: 501,
    permissionMode: 0o700,
    flags: 0,
    linkCount: 2
  )
}

private func restoreJournalTestItemComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal, radix: 16)
  let padded = String(repeating: "0", count: 32 - suffix.count) + suffix
  return Array("item-v1-\(padded)".utf8)
}

private struct RestoreJournalFacadeObservation: Sendable {
  let prepareCallCount: Int
  let preparedQuarantineTransactionID: String?
  let preparedRestoreTransactionID: String?
  let beginCallCount: Int
  let quarantinedItemDescriptor: Int32?
  let finishCallCount: Int
  let finishedSessionWasExpected: Bool
  let terminalOutcome: DescriptorQuarantineRestoreJournalTerminalOutcome?
  let namespaceMutationMayHaveBeenInvoked: Bool?
}

private final class RestoreJournalFacadeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let expectedSession: DescriptorQuarantineRestoreJournalSession
  private var prepareCallCount = 0
  private var preparedQuarantineTransactionID: String?
  private var preparedRestoreTransactionID: String?
  private var beginCallCount = 0
  private var quarantinedItemDescriptor: Int32?
  private var finishCallCount = 0
  private var finishedSessionWasExpected = false
  private var terminalOutcome: DescriptorQuarantineRestoreJournalTerminalOutcome?
  private var namespaceMutationMayHaveBeenInvoked: Bool?

  init(expectedSession: DescriptorQuarantineRestoreJournalSession) {
    self.expectedSession = expectedSession
  }

  func recordPrepare(_ request: DescriptorQuarantineRestorePreparationRequest) {
    lock.lock()
    prepareCallCount += 1
    preparedQuarantineTransactionID = request.quarantineTransactionID
    preparedRestoreTransactionID = request.restoreTransactionID
    lock.unlock()
  }

  func recordBegin(_ request: DescriptorQuarantineRestoreJournalBeginRequest) {
    lock.lock()
    beginCallCount += 1
    quarantinedItemDescriptor = request.quarantinedItemDescriptor
    lock.unlock()
  }

  func recordFinish(
    session: DescriptorQuarantineRestoreJournalSession,
    outcome: DescriptorQuarantineRestoreJournalTerminalOutcome,
    mutationMayHaveBeenInvoked: Bool
  ) {
    lock.lock()
    finishCallCount += 1
    finishedSessionWasExpected = expectedSession === session
    terminalOutcome = outcome
    namespaceMutationMayHaveBeenInvoked = mutationMayHaveBeenInvoked
    lock.unlock()
  }

  var observation: RestoreJournalFacadeObservation {
    lock.lock()
    defer { lock.unlock() }
    return RestoreJournalFacadeObservation(
      prepareCallCount: prepareCallCount,
      preparedQuarantineTransactionID: preparedQuarantineTransactionID,
      preparedRestoreTransactionID: preparedRestoreTransactionID,
      beginCallCount: beginCallCount,
      quarantinedItemDescriptor: quarantinedItemDescriptor,
      finishCallCount: finishCallCount,
      finishedSessionWasExpected: finishedSessionWasExpected,
      terminalOutcome: terminalOutcome,
      namespaceMutationMayHaveBeenInvoked: namespaceMutationMayHaveBeenInvoked
    )
  }
}

private final class RestoreJournalFinishCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCallCount = 0

  func record() {
    lock.lock()
    recordedCallCount += 1
    lock.unlock()
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recordedCallCount
  }
}
