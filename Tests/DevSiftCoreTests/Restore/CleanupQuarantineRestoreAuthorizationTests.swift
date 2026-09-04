import Foundation
import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine restore authorization")
struct CleanupQuarantineRestoreAuthorizationTests {
  @Test("A canonical quarantined pair produces one exact restore-only claim")
  func canonicalHappyPath() async throws {
    let evidence = try restoreAuthorizationEvidence()
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
    let request = session.confirmationRequest

    #expect(
      request.requiredStatement
        == .restoreCurrentQuarantinedContentsToOriginalCacacheWithoutOverwriteWithNPMStoppedAndPostQuarantineChangesAccepted
    )
    #expect(
      request.requiredStatement.rawValue
        == "restore-current-quarantined-contents-to-original-cacache-without-overwrite-with-npm-stopped-and-post-quarantine-changes-accepted"
    )
    #expect(request.requiredStatement.policyRevision == 1)
    #expect(request.subject.restoreTransactionID == evidence.restoreIntent.restoreTransactionID)
    #expect(
      request.subject.quarantineTransactionID == evidence.restoreIntent.quarantineTransactionID
    )
    #expect(request.subject.originalPath.rawComponents == [Array("_cacache".utf8)])
    #expect(
      request.subject.quarantineItemPath.rawComponents
        == [
          Array(".devsift-quarantine-v1".utf8),
          evidence.restoreIntent.quarantineItemComponent,
        ]
    )
    #expect(request.subject.responsibleTool == "npm")

    let confirmation = restoreConfirmation(for: session)
    let authorization = try await session.authorize(using: confirmation)
    let claim = try await authorization.consumeForExecution()

    #expect(claim.evidence == evidence)
    #expect(claim.confirmation == confirmation)
    #expect(authorization.contractVersion == 1)
    #expect(
      authorization.contractVersion == CleanupQuarantineRestoreAuthorization.currentContractVersion)
    #expect(authorization.isSingleUse)
    #expect(authorization.authorizesRestoreOnly)
    #expect(!authorization.authorizesPermanentDeletion)
    #expect(!authorization.authorizesOverwrite)
    #expect(authorization.requiresInlineFilesystemRevalidation)
    #expect(!authorization.grantsStandaloneFilesystemMutationAuthority)
    #expect(!authorization.usesWallClockFreshness)
    #expect(!isEncodableRestoreAuthorizationValue(evidence))
    #expect(!isEncodableRestoreAuthorizationValue(request))
    #expect(!isEncodableRestoreAuthorizationValue(confirmation))
    #expect(!isEncodableRestoreAuthorizationValue(authorization))
    #expect(!isEncodableRestoreAuthorizationValue(claim))
  }

  @Test("The authorizer accepts a canonical receipt produced by recovery")
  func recoveredQuarantineReceiptIsEligible() async throws {
    let evidence = try restoreAuthorizationEvidence(producedByRecovery: true)
    let receipt = try QuarantineJournalV1Codec.decodeReceipt(
      evidence.canonicalQuarantineReceiptBytes,
      matchingIntentBytes: evidence.canonicalQuarantineIntentBytes
    )
    #expect(receipt.producedByRecovery)

    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
    let authorization = try await session.authorize(using: restoreConfirmation(for: session))
    let claim = try await authorization.consumeForExecution()

    #expect(claim.evidence == evidence)
  }

  @Test("Noncanonical quarantine bytes cannot create an attempt")
  func nonCanonicalOriginalIntentIsRejected() throws {
    let evidence = try restoreAuthorizationEvidence()
    var changedBytes = evidence.canonicalQuarantineIntentBytes
    changedBytes.append(0x0A)
    let changed = CleanupQuarantineRestorePreparedEvidence(
      canonicalQuarantineIntentBytes: changedBytes,
      canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes,
      restoreIntent: evidence.restoreIntent
    )

    expectRestoreAuthorizationError(.invalidPreparedEvidence) {
      _ = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: changed)
    }
  }

  @Test("A non-quarantined terminal receipt cannot create a restore attempt")
  func nonQuarantinedReceiptIsRejected() throws {
    let evidence = try restoreAuthorizationEvidence()
    let notMoved = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: evidence.canonicalQuarantineIntentBytes
    )
    let receiptBytes = try QuarantineJournalV1Codec.encode(
      notMoved,
      matchingIntentBytes: evidence.canonicalQuarantineIntentBytes
    )
    let changed = CleanupQuarantineRestorePreparedEvidence(
      canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
      canonicalQuarantineReceiptBytes: receiptBytes,
      restoreIntent: evidence.restoreIntent
    )

    expectRestoreAuthorizationError(.invalidPreparedEvidence) {
      _ = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: changed)
    }
  }

  @Test("A logically valid replacement receipt is rejected unless its exact bytes were bound")
  func exactReceiptBytesAreBound() throws {
    let evidence = try restoreAuthorizationEvidence(producedByRecovery: false)
    let originalReceipt = try QuarantineJournalV1Codec.decodeReceipt(
      evidence.canonicalQuarantineReceiptBytes,
      matchingIntentBytes: evidence.canonicalQuarantineIntentBytes
    )
    guard let selectedDestinationOrdinal = originalReceipt.selectedDestinationOrdinal else {
      Issue.record("Expected a quarantined receipt destination ordinal")
      return
    }
    let replacement = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .quarantined,
      selectedDestinationOrdinal: selectedDestinationOrdinal,
      sourceNameWasRecreated: originalReceipt.sourceNameWasRecreated,
      producedByRecovery: true,
      canonicalIntentBytes: evidence.canonicalQuarantineIntentBytes
    )
    let replacementBytes = try QuarantineJournalV1Codec.encode(
      replacement,
      matchingIntentBytes: evidence.canonicalQuarantineIntentBytes
    )
    let changed = CleanupQuarantineRestorePreparedEvidence(
      canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
      canonicalQuarantineReceiptBytes: replacementBytes,
      restoreIntent: evidence.restoreIntent
    )

    #expect(replacement.outcome == originalReceipt.outcome)
    #expect(replacementBytes != evidence.canonicalQuarantineReceiptBytes)
    expectRestoreAuthorizationError(.invalidPreparedEvidence) {
      _ = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: changed)
    }
  }

  @Test("A caller-altered derived restore intent cannot create an attempt")
  func alteredDerivedIntentIsRejected() throws {
    let evidence = try restoreAuthorizationEvidence()
    let baseline = evidence.restoreIntent
    let changedBinding = restoreAuthorizationBinding(inode: baseline.candidateBinding.inode + 1)
    let changedIntent = QuarantineRestoreJournalIntentV1(
      restoreTransactionID: baseline.restoreTransactionID,
      quarantineTransactionID: baseline.quarantineTransactionID,
      quarantineIntentDigest: baseline.quarantineIntentDigest,
      quarantineReceiptDigest: baseline.quarantineReceiptDigest,
      npmRootBinding: baseline.npmRootBinding,
      quarantineRootBinding: baseline.quarantineRootBinding,
      candidateBinding: changedBinding,
      sourceComponents: baseline.sourceComponents,
      quarantineItemComponent: baseline.quarantineItemComponent,
      restorePolicyRevision: baseline.restorePolicyRevision
    )
    let changed = CleanupQuarantineRestorePreparedEvidence(
      canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
      canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes,
      restoreIntent: changedIntent
    )

    expectRestoreAuthorizationError(.invalidPreparedEvidence) {
      _ = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: changed)
    }
  }

  @Test("A future restore-policy revision cannot create an attempt")
  func futureRestorePolicyIsRejected() throws {
    let evidence = try restoreAuthorizationEvidence()
    let baseline = evidence.restoreIntent
    let changedIntent = QuarantineRestoreJournalIntentV1(
      restoreTransactionID: baseline.restoreTransactionID,
      quarantineTransactionID: baseline.quarantineTransactionID,
      quarantineIntentDigest: baseline.quarantineIntentDigest,
      quarantineReceiptDigest: baseline.quarantineReceiptDigest,
      npmRootBinding: baseline.npmRootBinding,
      quarantineRootBinding: baseline.quarantineRootBinding,
      candidateBinding: baseline.candidateBinding,
      sourceComponents: baseline.sourceComponents,
      quarantineItemComponent: baseline.quarantineItemComponent,
      restorePolicyRevision: baseline.restorePolicyRevision + 1
    )
    let changed = CleanupQuarantineRestorePreparedEvidence(
      canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
      canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes,
      restoreIntent: changedIntent
    )

    expectRestoreAuthorizationError(.invalidPreparedEvidence) {
      _ = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: changed)
    }
  }

  @Test("A confirmation from a same-looking second attempt is not substitutable")
  func crossAttemptConfirmationIsRejectedWithoutClosingTheAttempt() async throws {
    let evidence = try restoreAuthorizationEvidence()
    let first = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
    let second = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)

    #expect(first.confirmationRequest.subject == second.confirmationRequest.subject)
    #expect(
      first.confirmationRequest.requiredStatement
        == second.confirmationRequest.requiredStatement
    )
    #expect(first.confirmationRequest != second.confirmationRequest)

    await expectRestoreAuthorizationError(.confirmationDoesNotBelongToAttempt) {
      _ = try await first.authorize(using: restoreConfirmation(for: second))
    }
    _ = try await first.authorize(using: restoreConfirmation(for: first))
  }

  @Test("Concurrent issuance succeeds exactly once")
  func concurrentIssuanceIsSingleUse() async throws {
    let participantCount = 32
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(
      for: restoreAuthorizationEvidence()
    )
    let confirmation = restoreConfirmation(for: session)
    let gate = RestoreAuthorizationStartGate(participantCount: participantCount)

    let outcomes = await withTaskGroup(of: RestoreAuthorizationRaceOutcome.self) { group in
      for _ in 0..<participantCount {
        group.addTask {
          await gate.arriveAndWait()
          do {
            _ = try await session.authorize(using: confirmation)
            return .success
          } catch CleanupQuarantineRestoreAuthorizationError.attemptAlreadyAuthorized {
            return .expectedFailure
          } catch {
            return .unexpectedFailure(String(describing: error))
          }
        }
      }
      var outcomes: [RestoreAuthorizationRaceOutcome] = []
      for await outcome in group { outcomes.append(outcome) }
      return outcomes
    }

    expectOneRestoreRaceSuccess(outcomes, participantCount: participantCount)
  }

  @Test("Concurrent authorization-copy consumption succeeds exactly once")
  func concurrentConsumptionIsSingleUse() async throws {
    let participantCount = 32
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(
      for: restoreAuthorizationEvidence()
    )
    let authorization = try await session.authorize(using: restoreConfirmation(for: session))
    let copies = Array(repeating: authorization, count: participantCount)
    let gate = RestoreAuthorizationStartGate(participantCount: participantCount)

    let outcomes = await withTaskGroup(of: RestoreAuthorizationRaceOutcome.self) { group in
      for copy in copies {
        group.addTask {
          await gate.arriveAndWait()
          do {
            _ = try await copy.consumeForExecution()
            return .success
          } catch CleanupQuarantineRestoreAuthorizationConsumptionError
            .authorizationAlreadyConsumed
          {
            return .expectedFailure
          } catch {
            return .unexpectedFailure(String(describing: error))
          }
        }
      }
      var outcomes: [RestoreAuthorizationRaceOutcome] = []
      for await outcome in group { outcomes.append(outcome) }
      return outcomes
    }

    expectOneRestoreRaceSuccess(outcomes, participantCount: participantCount)
  }

  @Test("Cancellation before issuance is terminal")
  func cancellationBeforeIssuanceIsTerminal() async throws {
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(
      for: restoreAuthorizationEvidence()
    )
    await session.cancel()

    await expectRestoreAuthorizationError(.attemptCancelled) {
      _ = try await session.authorize(using: restoreConfirmation(for: session))
    }
  }

  @Test("Cancellation after issuance invalidates every authorization copy")
  func cancellationAfterIssuanceIsTerminal() async throws {
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(
      for: restoreAuthorizationEvidence()
    )
    let authorization = try await session.authorize(using: restoreConfirmation(for: session))
    let copy = authorization
    await session.cancel()

    await expectRestoreConsumptionError(.authorizationCancelled) {
      _ = try await authorization.consumeForExecution()
    }
    await expectRestoreConsumptionError(.authorizationCancelled) {
      _ = try await copy.consumeForExecution()
    }
  }

  @Test("A pre-cancelled issuance task cancels the attempt terminally")
  func taskCancellationWhileIssuingIsTerminal() async throws {
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(
      for: restoreAuthorizationEvidence()
    )
    let confirmation = restoreConfirmation(for: session)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await session.authorize(using: confirmation)
    }

    await expectRestoreCancellation { _ = try await task.value }
    await expectRestoreAuthorizationError(.attemptCancelled) {
      _ = try await session.authorize(using: confirmation)
    }
  }

  @Test("A pre-cancelled consumption task invalidates all copies terminally")
  func taskCancellationWhileConsumingIsTerminal() async throws {
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(
      for: restoreAuthorizationEvidence()
    )
    let authorization = try await session.authorize(using: restoreConfirmation(for: session))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await authorization.consumeForExecution()
    }

    await expectRestoreCancellation { _ = try await task.value }
    await expectRestoreConsumptionError(.authorizationCancelled) {
      _ = try await authorization.consumeForExecution()
    }
  }

  @Test("Cancellation racing issuance leaves no consumable authorization")
  func cancellationRacingIssuance() async throws {
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(
      for: restoreAuthorizationEvidence()
    )
    let confirmation = restoreConfirmation(for: session)
    let issueTask = Task { () -> RestoreAuthorizationIssueCancelOutcome in
      do {
        return .issued(try await session.authorize(using: confirmation))
      } catch CleanupQuarantineRestoreAuthorizationError.attemptCancelled {
        return .cancelled
      } catch {
        return .unexpectedFailure(String(describing: error))
      }
    }
    let cancelTask = Task {
      await session.cancel()
    }

    let outcome = await issueTask.value
    await cancelTask.value
    switch outcome {
    case .issued(let authorization):
      await expectRestoreConsumptionError(.authorizationCancelled) {
        _ = try await authorization.consumeForExecution()
      }
    case .cancelled:
      await expectRestoreAuthorizationError(.attemptCancelled) {
        _ = try await session.authorize(using: confirmation)
      }
    case .unexpectedFailure(let description):
      Issue.record("Unexpected restore issue/cancel race result: \(description)")
    }
  }

  @Test("Cancellation racing consumption has one irreversible winner")
  func cancellationRacingConsumption() async throws {
    let evidence = try restoreAuthorizationEvidence()
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
    let authorization = try await session.authorize(using: restoreConfirmation(for: session))
    let consumeTask = Task { () -> RestoreAuthorizationConsumeCancelOutcome in
      do {
        return .consumed(try await authorization.consumeForExecution())
      } catch CleanupQuarantineRestoreAuthorizationConsumptionError.authorizationCancelled {
        return .cancelled
      } catch {
        return .unexpectedFailure(String(describing: error))
      }
    }
    let cancelTask = Task {
      await session.cancel()
    }

    let outcome = await consumeTask.value
    await cancelTask.value
    switch outcome {
    case .consumed(let claim):
      #expect(claim.evidence == evidence)
      await expectRestoreConsumptionError(.authorizationAlreadyConsumed) {
        _ = try await authorization.consumeForExecution()
      }
    case .cancelled:
      await expectRestoreConsumptionError(.authorizationCancelled) {
        _ = try await authorization.consumeForExecution()
      }
    case .unexpectedFailure(let description):
      Issue.record("Unexpected restore consume/cancel race result: \(description)")
    }
  }
}

func restoreAuthorizationEvidence(
  quarantineTransactionID: String = String(repeating: "1", count: 32),
  restoreTransactionID: String = String(repeating: "a", count: 32),
  selectedDestinationOrdinal: Int = 3,
  producedByRecovery: Bool = false
) throws -> CleanupQuarantineRestorePreparedEvidence {
  let intent = QuarantineJournalIntentV1(
    transactionID: quarantineTransactionID,
    npmRootBinding: restoreAuthorizationBinding(inode: 10),
    quarantineRootBinding: restoreAuthorizationBinding(inode: 20),
    candidateBinding: restoreAuthorizationBinding(inode: 30),
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<QuarantineJournalIntentV1.destinationCount).map {
      restoreAuthorizationItemComponent($0)
    }
  )
  let intentBytes = try QuarantineJournalV1Codec.encode(intent)
  let receipt = try QuarantineJournalV1Codec.makeReceipt(
    outcome: .quarantined,
    selectedDestinationOrdinal: selectedDestinationOrdinal,
    producedByRecovery: producedByRecovery,
    canonicalIntentBytes: intentBytes
  )
  let receiptBytes = try QuarantineJournalV1Codec.encode(
    receipt,
    matchingIntentBytes: intentBytes
  )
  let restoreIntent = try QuarantineRestoreJournalV1Codec.makeIntent(
    restoreTransactionID: restoreTransactionID,
    canonicalQuarantineIntentBytes: intentBytes,
    canonicalQuarantineReceiptBytes: receiptBytes
  )
  return CleanupQuarantineRestorePreparedEvidence(
    canonicalQuarantineIntentBytes: intentBytes,
    canonicalQuarantineReceiptBytes: receiptBytes,
    restoreIntent: restoreIntent
  )
}

private func restoreAuthorizationBinding(
  inode: UInt64
) -> QuarantineJournalFileBindingV1 {
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

private func restoreAuthorizationItemComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal + 1, radix: 16)
  return Array("item-v1-\(String(repeating: "0", count: 32 - suffix.count))\(suffix)".utf8)
}

func restoreConfirmation(
  for session: CleanupQuarantineRestoreAuthorizationSession
) -> CleanupQuarantineRestoreUserConfirmation {
  CleanupQuarantineRestoreUserConfirmation(
    request: session.confirmationRequest,
    statement: session.confirmationRequest.requiredStatement
  )
}

private func expectRestoreAuthorizationError(
  _ expected: CleanupQuarantineRestoreAuthorizationError,
  performing operation: () throws -> Void
) {
  do {
    try operation()
    Issue.record("Expected restore authorization error \(expected)")
  } catch let error as CleanupQuarantineRestoreAuthorizationError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected restore authorization error \(error)")
  }
}

private func expectRestoreAuthorizationError(
  _ expected: CleanupQuarantineRestoreAuthorizationError,
  performing operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected restore authorization error \(expected)")
  } catch let error as CleanupQuarantineRestoreAuthorizationError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected restore authorization error \(error)")
  }
}

private func expectRestoreConsumptionError(
  _ expected: CleanupQuarantineRestoreAuthorizationConsumptionError,
  performing operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected restore authorization consumption error \(expected)")
  } catch let error as CleanupQuarantineRestoreAuthorizationConsumptionError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected restore authorization consumption error \(error)")
  }
}

private func expectRestoreCancellation(
  performing operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected CancellationError")
  } catch is CancellationError {
  } catch {
    Issue.record("Unexpected cancellation error \(error)")
  }
}

private func isEncodableRestoreAuthorizationValue(_ value: Any) -> Bool {
  value is any Encodable
}

private actor RestoreAuthorizationStartGate {
  private let participantCount: Int
  private var arrivedCount = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []

  init(participantCount: Int) {
    self.participantCount = participantCount
    continuations.reserveCapacity(participantCount)
  }

  func arriveAndWait() async {
    arrivedCount += 1
    if arrivedCount == participantCount {
      let waiting = continuations
      continuations.removeAll(keepingCapacity: false)
      for continuation in waiting { continuation.resume() }
      return
    }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }
}

private enum RestoreAuthorizationRaceOutcome: Sendable {
  case success
  case expectedFailure
  case unexpectedFailure(String)
}

private enum RestoreAuthorizationIssueCancelOutcome: Sendable {
  case issued(CleanupQuarantineRestoreAuthorization)
  case cancelled
  case unexpectedFailure(String)
}

private enum RestoreAuthorizationConsumeCancelOutcome: Sendable {
  case consumed(CleanupQuarantineRestoreExecutionClaim)
  case cancelled
  case unexpectedFailure(String)
}

private func expectOneRestoreRaceSuccess(
  _ outcomes: [RestoreAuthorizationRaceOutcome],
  participantCount: Int
) {
  let successCount = outcomes.count {
    if case .success = $0 { return true }
    return false
  }
  let expectedFailureCount = outcomes.count {
    if case .expectedFailure = $0 { return true }
    return false
  }
  let unexpected = outcomes.compactMap { outcome -> String? in
    if case .unexpectedFailure(let description) = outcome { return description }
    return nil
  }
  #expect(successCount == 1)
  #expect(expectedFailureCount == participantCount - 1)
  #expect(unexpected.isEmpty)
}
