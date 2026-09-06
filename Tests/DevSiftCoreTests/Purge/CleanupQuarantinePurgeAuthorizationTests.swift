import Foundation
import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine purge authorization")
struct CleanupQuarantinePurgeAuthorizationTests {
  @Test("Initial evidence produces one exact permanent-deletion claim")
  func initialHappyPath() async throws {
    let evidence = try purgeAuthorizationEvidence(attemptKind: .initial)
    let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: evidence)
    let request = session.confirmationRequest

    #expect(request.attemptKind == .initial)
    #expect(request.requiredStatement == .initialPermanentDeletionRisksAccepted)
    #expect(request.requiredStatement.attemptKind == .initial)
    #expect(request.requiredStatement.policyRevision == 1)
    #expect(request.subject.responsibleTool == "npm")
    #expect(request.subject.originalName == "_cacache")

    let confirmation = purgeConfirmation(for: session)
    let authorization = try await session.authorize(using: confirmation)
    let copy = authorization
    let claim = try await authorization.consumeForExecution()

    #expect(claim.attemptKind == .initial)
    #expect(claim.evidence == evidence)
    #expect(claim.confirmation == confirmation)
    #expect(authorization.contractVersion == 1)
    #expect(
      authorization.contractVersion == CleanupQuarantinePurgeAuthorization.currentContractVersion
    )
    #expect(authorization.attemptKind == .initial)
    #expect(authorization.isSingleUse)
    #expect(authorization.authorizesPurgeOnly)
    #expect(authorization.authorizesPermanentDeletion)
    #expect(!authorization.authorizesRestore)
    #expect(!authorization.authorizesOverwrite)
    #expect(!authorization.authorizesArbitraryPaths)
    #expect(!authorization.authorizesActiveCacheDeletion)
    #expect(authorization.authorizesOnlyExactStagedWorkTree)
    #expect(authorization.requiresInlineFilesystemRevalidation)
    #expect(authorization.requiresInlineACLRevalidation)
    #expect(!authorization.grantsStandaloneFilesystemMutationAuthority)
    #expect(!authorization.usesWallClockFreshness)
    await expectPurgeConsumptionError(.authorizationAlreadyConsumed) {
      _ = try await copy.consumeForExecution()
    }
    #expect(!isEncodablePurgeAuthorizationValue(evidence))
    #expect(!isEncodablePurgeAuthorizationValue(request))
    #expect(!isEncodablePurgeAuthorizationValue(confirmation))
    #expect(!isEncodablePurgeAuthorizationValue(authorization))
    #expect(!isEncodablePurgeAuthorizationValue(claim))
  }

  @Test("Retry evidence retains exact existing intent and current work identity")
  func explicitRetryHappyPath() async throws {
    let evidence = try purgeAuthorizationEvidence(attemptKind: .explicitRetry)
    let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: evidence)

    #expect(session.confirmationRequest.attemptKind == .explicitRetry)
    #expect(
      session.confirmationRequest.requiredStatement
        == .explicitRetryPermanentDeletionRisksAccepted
    )
    #expect(session.confirmationRequest.requiredStatement.attemptKind == .explicitRetry)

    let authorization = try await session.authorize(using: purgeConfirmation(for: session))
    let claim = try await authorization.consumeForExecution()

    #expect(authorization.attemptKind == .explicitRetry)
    #expect(claim.attemptKind == .explicitRetry)
    guard case .explicitRetry(let preparedRetry) = claim.evidence else {
      Issue.record("Expected exact retry evidence")
      return
    }
    guard case .explicitRetry(let suppliedRetry) = evidence else {
      Issue.record("Expected supplied retry evidence")
      return
    }
    #expect(preparedRetry.canonicalPurgeIntentBytes == suppliedRetry.canonicalPurgeIntentBytes)
    #expect(preparedRetry.purgeIntent == suppliedRetry.purgeIntent)
    #expect(preparedRetry.currentWorkBinding == suppliedRetry.currentWorkBinding)
    #expect(
      preparedRetry.currentWorkBinding.linkCount
        != preparedRetry.purgeIntent.candidateBinding.linkCount
    )
    #expect(
      preparedRetry.currentWorkBinding.permissionMode
        != preparedRetry.purgeIntent.candidateBinding.permissionMode
    )
  }

  @Test("Initial and retry confirmations are not interchangeable")
  func initialAndRetryStatementsAreDistinct() async throws {
    let initial = try CleanupQuarantinePurgeAuthorizer().beginAttempt(
      for: purgeAuthorizationEvidence(attemptKind: .initial)
    )
    let retry = try CleanupQuarantinePurgeAuthorizer().beginAttempt(
      for: purgeAuthorizationEvidence(attemptKind: .explicitRetry)
    )

    #expect(initial.confirmationRequest.subject == retry.confirmationRequest.subject)
    #expect(initial.confirmationRequest != retry.confirmationRequest)
    #expect(
      initial.confirmationRequest.requiredStatement
        != retry.confirmationRequest.requiredStatement
    )
    await expectPurgeAuthorizationError(.confirmationStatementMismatch) {
      _ = try await initial.authorize(
        using: CleanupQuarantinePurgeUserConfirmation(
          request: initial.confirmationRequest,
          statement: retry.confirmationRequest.requiredStatement
        )
      )
    }
    _ = try await initial.authorize(using: purgeConfirmation(for: initial))
  }

  @Test("A same-looking confirmation from another attempt is rejected")
  func crossAttemptConfirmationIsRejected() async throws {
    let evidence = try purgeAuthorizationEvidence(attemptKind: .initial)
    let first = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: evidence)
    let second = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: evidence)

    #expect(first.confirmationRequest.subject == second.confirmationRequest.subject)
    #expect(
      first.confirmationRequest.requiredStatement == second.confirmationRequest.requiredStatement)
    #expect(first.confirmationRequest != second.confirmationRequest)
    await expectPurgeAuthorizationError(.confirmationDoesNotBelongToAttempt) {
      _ = try await first.authorize(using: purgeConfirmation(for: second))
    }
    _ = try await first.authorize(using: purgeConfirmation(for: first))
  }

  @Test("Noncanonical quarantine bytes cannot create either attempt kind")
  func nonCanonicalQuarantineEvidenceIsRejected() throws {
    for attemptKind in CleanupQuarantinePurgeAttemptKind.allCases {
      let evidence = try purgeAuthorizationEvidence(attemptKind: attemptKind)
      var changed = evidence
      switch evidence {
      case .initial(let initial):
        var bytes = initial.canonicalQuarantineIntentBytes
        bytes.append(0x0A)
        changed = .initial(
          CleanupQuarantinePurgeInitialPreparedEvidence(
            canonicalQuarantineIntentBytes: bytes,
            canonicalQuarantineReceiptBytes: initial.canonicalQuarantineReceiptBytes,
            purgeIntent: initial.purgeIntent
          )
        )
      case .explicitRetry(let retry):
        var bytes = retry.canonicalQuarantineReceiptBytes
        bytes.append(0x20)
        changed = .explicitRetry(
          CleanupQuarantinePurgeRetryPreparedEvidence(
            canonicalQuarantineIntentBytes: retry.canonicalQuarantineIntentBytes,
            canonicalQuarantineReceiptBytes: bytes,
            purgeIntent: retry.purgeIntent,
            canonicalPurgeIntentBytes: retry.canonicalPurgeIntentBytes,
            currentWorkBinding: retry.currentWorkBinding
          )
        )
      }

      expectPurgeAuthorizationError(.invalidPreparedEvidence) {
        _ = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: changed)
      }
    }
  }

  @Test("Caller-altered derived initial intent cannot create an attempt")
  func alteredInitialIntentIsRejected() throws {
    let evidence = try purgeAuthorizationEvidence(attemptKind: .initial)
    guard case .initial(let initial) = evidence else {
      Issue.record("Expected initial evidence")
      return
    }
    let intent = initial.purgeIntent
    let changedIntent = purgeAuthorizationCopyIntent(
      intent,
      quarantineReceiptDigest: Array(repeating: 0xFF, count: 32)
    )
    let changed = CleanupQuarantinePurgePreparedEvidence.initial(
      CleanupQuarantinePurgeInitialPreparedEvidence(
        canonicalQuarantineIntentBytes: initial.canonicalQuarantineIntentBytes,
        canonicalQuarantineReceiptBytes: initial.canonicalQuarantineReceiptBytes,
        purgeIntent: changedIntent
      )
    )

    expectPurgeAuthorizationError(.invalidPreparedEvidence) {
      _ = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: changed)
    }
  }

  @Test("Retry requires canonical bytes for the same exact purge intent")
  func retryIntentBytesCannotBeSubstituted() throws {
    let evidence = try purgeAuthorizationEvidence(attemptKind: .explicitRetry)
    guard case .explicitRetry(let retry) = evidence else {
      Issue.record("Expected retry evidence")
      return
    }
    let other = try purgeAuthorizationEvidence(
      attemptKind: .explicitRetry,
      purgeTransactionID: String(repeating: "b", count: 32)
    )
    guard case .explicitRetry(let otherRetry) = other else {
      Issue.record("Expected second retry evidence")
      return
    }
    let substituted = CleanupQuarantinePurgePreparedEvidence.explicitRetry(
      CleanupQuarantinePurgeRetryPreparedEvidence(
        canonicalQuarantineIntentBytes: retry.canonicalQuarantineIntentBytes,
        canonicalQuarantineReceiptBytes: retry.canonicalQuarantineReceiptBytes,
        purgeIntent: retry.purgeIntent,
        canonicalPurgeIntentBytes: otherRetry.canonicalPurgeIntentBytes,
        currentWorkBinding: retry.currentWorkBinding
      )
    )

    expectPurgeAuthorizationError(.invalidPreparedEvidence) {
      _ = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: substituted)
    }

    var noncanonical = retry.canonicalPurgeIntentBytes
    noncanonical.append(0x0A)
    let drifted = CleanupQuarantinePurgePreparedEvidence.explicitRetry(
      CleanupQuarantinePurgeRetryPreparedEvidence(
        canonicalQuarantineIntentBytes: retry.canonicalQuarantineIntentBytes,
        canonicalQuarantineReceiptBytes: retry.canonicalQuarantineReceiptBytes,
        purgeIntent: retry.purgeIntent,
        canonicalPurgeIntentBytes: noncanonical,
        currentWorkBinding: retry.currentWorkBinding
      )
    )
    expectPurgeAuthorizationError(.invalidPreparedEvidence) {
      _ = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: drifted)
    }
  }

  @Test("Retry rejects changed identity and unsafe current work metadata")
  func retryWorkIdentityAndSafetyAreBound() throws {
    let evidence = try purgeAuthorizationEvidence(attemptKind: .explicitRetry)
    guard case .explicitRetry(let retry) = evidence else {
      Issue.record("Expected retry evidence")
      return
    }
    let changedIdentity = purgeAuthorizationRetryEvidence(
      retry,
      currentWorkBinding: purgeAuthorizationCopyBinding(
        retry.currentWorkBinding,
        inode: retry.currentWorkBinding.inode + 1
      )
    )
    let unsafeMode = purgeAuthorizationRetryEvidence(
      retry,
      currentWorkBinding: purgeAuthorizationCopyBinding(
        retry.currentWorkBinding,
        permissionMode: 0o722
      )
    )
    let unsafeFlags = purgeAuthorizationRetryEvidence(
      retry,
      currentWorkBinding: purgeAuthorizationCopyBinding(
        retry.currentWorkBinding,
        flags: 1
      )
    )
    let impossibleDirectoryLinkCount = purgeAuthorizationRetryEvidence(
      retry,
      currentWorkBinding: purgeAuthorizationCopyBinding(
        retry.currentWorkBinding,
        linkCount: 1
      )
    )

    for changed in [changedIdentity, unsafeMode, unsafeFlags, impossibleDirectoryLinkCount] {
      expectPurgeAuthorizationError(.invalidPreparedEvidence) {
        _ = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: changed)
      }
    }
  }

  @Test("Concurrent issuance succeeds exactly once")
  func concurrentIssuanceIsSingleUse() async throws {
    let participantCount = 32
    let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(
      for: purgeAuthorizationEvidence(attemptKind: .initial)
    )
    let confirmation = purgeConfirmation(for: session)
    let gate = PurgeAuthorizationStartGate(participantCount: participantCount)

    let outcomes = await withTaskGroup(of: PurgeAuthorizationRaceOutcome.self) { group in
      for _ in 0..<participantCount {
        group.addTask {
          await gate.arriveAndWait()
          do {
            _ = try await session.authorize(using: confirmation)
            return .success
          } catch CleanupQuarantinePurgeAuthorizationError.attemptAlreadyAuthorized {
            return .expectedFailure
          } catch {
            return .unexpectedFailure(String(describing: error))
          }
        }
      }
      var outcomes: [PurgeAuthorizationRaceOutcome] = []
      for await outcome in group { outcomes.append(outcome) }
      return outcomes
    }

    expectOnePurgeRaceSuccess(outcomes, participantCount: participantCount)
  }

  @Test("Concurrent authorization-copy consumption succeeds exactly once")
  func concurrentConsumptionIsSingleUse() async throws {
    let participantCount = 32
    let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(
      for: purgeAuthorizationEvidence(attemptKind: .explicitRetry)
    )
    let authorization = try await session.authorize(using: purgeConfirmation(for: session))
    let copies = Array(repeating: authorization, count: participantCount)
    let gate = PurgeAuthorizationStartGate(participantCount: participantCount)

    let outcomes = await withTaskGroup(of: PurgeAuthorizationRaceOutcome.self) { group in
      for copy in copies {
        group.addTask {
          await gate.arriveAndWait()
          do {
            _ = try await copy.consumeForExecution()
            return .success
          } catch CleanupQuarantinePurgeAuthorizationConsumptionError.authorizationAlreadyConsumed {
            return .expectedFailure
          } catch {
            return .unexpectedFailure(String(describing: error))
          }
        }
      }
      var outcomes: [PurgeAuthorizationRaceOutcome] = []
      for await outcome in group { outcomes.append(outcome) }
      return outcomes
    }

    expectOnePurgeRaceSuccess(outcomes, participantCount: participantCount)
  }

  @Test("Cancellation before issuance is terminal")
  func cancellationBeforeIssuanceIsTerminal() async throws {
    let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(
      for: purgeAuthorizationEvidence(attemptKind: .initial)
    )
    await session.cancel()

    await expectPurgeAuthorizationError(.attemptCancelled) {
      _ = try await session.authorize(using: purgeConfirmation(for: session))
    }
  }

  @Test("Cancellation after issuance invalidates every authorization copy")
  func cancellationAfterIssuanceIsTerminal() async throws {
    let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(
      for: purgeAuthorizationEvidence(attemptKind: .explicitRetry)
    )
    let authorization = try await session.authorize(using: purgeConfirmation(for: session))
    let copy = authorization
    await session.cancel()

    await expectPurgeConsumptionError(.authorizationCancelled) {
      _ = try await authorization.consumeForExecution()
    }
    await expectPurgeConsumptionError(.authorizationCancelled) {
      _ = try await copy.consumeForExecution()
    }
  }

  @Test("A pre-cancelled issuance task cancels the attempt terminally")
  func taskCancellationWhileIssuingIsTerminal() async throws {
    let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(
      for: purgeAuthorizationEvidence(attemptKind: .initial)
    )
    let confirmation = purgeConfirmation(for: session)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await session.authorize(using: confirmation)
    }

    await expectPurgeCancellation { _ = try await task.value }
    await expectPurgeAuthorizationError(.attemptCancelled) {
      _ = try await session.authorize(using: confirmation)
    }
  }

  @Test("A pre-cancelled consumption task invalidates every copy")
  func taskCancellationWhileConsumingIsTerminal() async throws {
    let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(
      for: purgeAuthorizationEvidence(attemptKind: .explicitRetry)
    )
    let authorization = try await session.authorize(using: purgeConfirmation(for: session))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await authorization.consumeForExecution()
    }

    await expectPurgeCancellation { _ = try await task.value }
    await expectPurgeConsumptionError(.authorizationCancelled) {
      _ = try await authorization.consumeForExecution()
    }
  }

  @Test("Cancellation racing consumption has one terminal winner")
  func cancellationRacingConsumption() async throws {
    let evidence = try purgeAuthorizationEvidence(attemptKind: .initial)
    let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: evidence)
    let authorization = try await session.authorize(using: purgeConfirmation(for: session))
    let consumeTask = Task { () -> PurgeAuthorizationConsumeCancelOutcome in
      do {
        return .consumed(try await authorization.consumeForExecution())
      } catch CleanupQuarantinePurgeAuthorizationConsumptionError.authorizationCancelled {
        return .cancelled
      } catch {
        return .unexpectedFailure(String(describing: error))
      }
    }
    let cancelTask = Task { await session.cancel() }

    let outcome = await consumeTask.value
    await cancelTask.value
    switch outcome {
    case .consumed(let claim):
      #expect(claim.evidence == evidence)
      await expectPurgeConsumptionError(.authorizationAlreadyConsumed) {
        _ = try await authorization.consumeForExecution()
      }
    case .cancelled:
      await expectPurgeConsumptionError(.authorizationCancelled) {
        _ = try await authorization.consumeForExecution()
      }
    case .unexpectedFailure(let description):
      Issue.record("Unexpected purge consume/cancel race result: \(description)")
    }
  }
}

private func purgeAuthorizationEvidence(
  attemptKind: CleanupQuarantinePurgeAttemptKind,
  quarantineTransactionID: String = String(repeating: "1", count: 32),
  purgeTransactionID: String = String(repeating: "a", count: 32),
  selectedDestinationOrdinal: Int = 3
) throws -> CleanupQuarantinePurgePreparedEvidence {
  let quarantineIntent = QuarantineJournalIntentV1(
    transactionID: quarantineTransactionID,
    npmRootBinding: purgeAuthorizationBinding(inode: 10, linkCount: 3),
    quarantineRootBinding: purgeAuthorizationBinding(inode: 20, linkCount: 3),
    candidateBinding: purgeAuthorizationBinding(inode: 30, linkCount: 5),
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<QuarantineJournalIntentV1.destinationCount).map {
      purgeAuthorizationItemComponent($0)
    }
  )
  let quarantineIntentBytes = try QuarantineJournalV1Codec.encode(quarantineIntent)
  let quarantineReceipt = try QuarantineJournalV1Codec.makeReceipt(
    outcome: .quarantined,
    selectedDestinationOrdinal: selectedDestinationOrdinal,
    producedByRecovery: false,
    canonicalIntentBytes: quarantineIntentBytes
  )
  let quarantineReceiptBytes = try QuarantineJournalV1Codec.encode(
    quarantineReceipt,
    matchingIntentBytes: quarantineIntentBytes
  )
  let purgeIntent = try QuarantinePurgeJournalV1Codec.makeIntent(
    purgeTransactionID: purgeTransactionID,
    capacityBefore: purgeAuthorizationCapacity(),
    canonicalQuarantineIntentBytes: quarantineIntentBytes,
    canonicalQuarantineReceiptBytes: quarantineReceiptBytes
  )

  switch attemptKind {
  case .initial:
    return .initial(
      CleanupQuarantinePurgeInitialPreparedEvidence(
        canonicalQuarantineIntentBytes: quarantineIntentBytes,
        canonicalQuarantineReceiptBytes: quarantineReceiptBytes,
        purgeIntent: purgeIntent
      )
    )
  case .explicitRetry:
    let purgeIntentBytes = try QuarantinePurgeJournalV1Codec.encode(
      purgeIntent,
      matchingQuarantineIntentBytes: quarantineIntentBytes,
      matchingQuarantineReceiptBytes: quarantineReceiptBytes
    )
    return .explicitRetry(
      CleanupQuarantinePurgeRetryPreparedEvidence(
        canonicalQuarantineIntentBytes: quarantineIntentBytes,
        canonicalQuarantineReceiptBytes: quarantineReceiptBytes,
        purgeIntent: purgeIntent,
        canonicalPurgeIntentBytes: purgeIntentBytes,
        currentWorkBinding: purgeAuthorizationBinding(
          inode: purgeIntent.candidateBinding.inode,
          permissionMode: 0o755,
          linkCount: 2
        )
      )
    )
  }
}

private func purgeAuthorizationCapacity(
  availableBytes: UInt64 = 4_096
) -> QuarantinePurgeCapacityObservationV1 {
  QuarantinePurgeCapacityObservationV1(
    volumeIdentity: QuarantinePurgeVolumeIdentityV1(
      device: 7,
      fileSystemIDFirst: -2,
      fileSystemIDSecond: 9
    ),
    availableBytes: availableBytes
  )
}

private func purgeAuthorizationBinding(
  inode: UInt64,
  permissionMode: UInt32 = 0o700,
  flags: UInt32 = 0,
  linkCount: UInt64
) -> QuarantineJournalFileBindingV1 {
  QuarantineJournalFileBindingV1(
    device: 7,
    inode: inode,
    generation: 11,
    birthSeconds: 1_725_000_000,
    birthNanoseconds: 123_456_789,
    kind: .directory,
    ownerUID: 501,
    permissionMode: permissionMode,
    flags: flags,
    linkCount: linkCount
  )
}

private func purgeAuthorizationCopyBinding(
  _ baseline: QuarantineJournalFileBindingV1,
  inode: UInt64? = nil,
  permissionMode: UInt32? = nil,
  flags: UInt32? = nil,
  linkCount: UInt64? = nil
) -> QuarantineJournalFileBindingV1 {
  QuarantineJournalFileBindingV1(
    device: baseline.device,
    inode: inode ?? baseline.inode,
    generation: baseline.generation,
    birthSeconds: baseline.birthSeconds,
    birthNanoseconds: baseline.birthNanoseconds,
    kind: baseline.kind,
    ownerUID: baseline.ownerUID,
    permissionMode: permissionMode ?? baseline.permissionMode,
    flags: flags ?? baseline.flags,
    linkCount: linkCount ?? baseline.linkCount
  )
}

private func purgeAuthorizationItemComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal + 1, radix: 16)
  return Array("item-v1-\(String(repeating: "0", count: 32 - suffix.count))\(suffix)".utf8)
}

private func purgeAuthorizationCopyIntent(
  _ baseline: QuarantinePurgeJournalIntentV1,
  quarantineReceiptDigest: [UInt8]
) -> QuarantinePurgeJournalIntentV1 {
  QuarantinePurgeJournalIntentV1(
    purgeTransactionID: baseline.purgeTransactionID,
    quarantineTransactionID: baseline.quarantineTransactionID,
    quarantineIntentDigest: baseline.quarantineIntentDigest,
    quarantineReceiptDigest: quarantineReceiptDigest,
    npmRootBinding: baseline.npmRootBinding,
    quarantineRootBinding: baseline.quarantineRootBinding,
    candidateBinding: baseline.candidateBinding,
    sourceComponents: baseline.sourceComponents,
    quarantineItemComponent: baseline.quarantineItemComponent,
    purgeWorkComponent: baseline.purgeWorkComponent,
    purgePolicyRevision: baseline.purgePolicyRevision,
    resourceBounds: baseline.resourceBounds,
    capacityBefore: baseline.capacityBefore
  )
}

private func purgeAuthorizationRetryEvidence(
  _ baseline: CleanupQuarantinePurgeRetryPreparedEvidence,
  currentWorkBinding: QuarantineJournalFileBindingV1
) -> CleanupQuarantinePurgePreparedEvidence {
  .explicitRetry(
    CleanupQuarantinePurgeRetryPreparedEvidence(
      canonicalQuarantineIntentBytes: baseline.canonicalQuarantineIntentBytes,
      canonicalQuarantineReceiptBytes: baseline.canonicalQuarantineReceiptBytes,
      purgeIntent: baseline.purgeIntent,
      canonicalPurgeIntentBytes: baseline.canonicalPurgeIntentBytes,
      currentWorkBinding: currentWorkBinding
    )
  )
}

private func purgeConfirmation(
  for session: CleanupQuarantinePurgeAuthorizationSession
) -> CleanupQuarantinePurgeUserConfirmation {
  CleanupQuarantinePurgeUserConfirmation(
    request: session.confirmationRequest,
    statement: session.confirmationRequest.requiredStatement
  )
}

private func expectPurgeAuthorizationError(
  _ expected: CleanupQuarantinePurgeAuthorizationError,
  performing operation: () throws -> Void
) {
  do {
    try operation()
    Issue.record("Expected purge authorization error \(expected)")
  } catch let error as CleanupQuarantinePurgeAuthorizationError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected purge authorization error \(error)")
  }
}

private func expectPurgeAuthorizationError(
  _ expected: CleanupQuarantinePurgeAuthorizationError,
  performing operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected purge authorization error \(expected)")
  } catch let error as CleanupQuarantinePurgeAuthorizationError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected purge authorization error \(error)")
  }
}

private func expectPurgeConsumptionError(
  _ expected: CleanupQuarantinePurgeAuthorizationConsumptionError,
  performing operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected purge authorization consumption error \(expected)")
  } catch let error as CleanupQuarantinePurgeAuthorizationConsumptionError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected purge authorization consumption error \(error)")
  }
}

private func expectPurgeCancellation(
  performing operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected CancellationError")
  } catch is CancellationError {
  } catch {
    Issue.record("Unexpected purge cancellation error \(error)")
  }
}

private func isEncodablePurgeAuthorizationValue(_ value: Any) -> Bool {
  value is any Encodable
}

private actor PurgeAuthorizationStartGate {
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

private enum PurgeAuthorizationRaceOutcome: Sendable {
  case success
  case expectedFailure
  case unexpectedFailure(String)
}

private enum PurgeAuthorizationConsumeCancelOutcome: Sendable {
  case consumed(CleanupQuarantinePurgeExecutionClaim)
  case cancelled
  case unexpectedFailure(String)
}

private func expectOnePurgeRaceSuccess(
  _ outcomes: [PurgeAuthorizationRaceOutcome],
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
