import Foundation
import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine purge executor")
struct CleanupQuarantinePurgeExecutorTests {
  @Test("Authorization copies enter the purge pipeline exactly once")
  func authorizationCopiesExecuteOnce() async throws {
    let authorization = try await purgeExecutorAuthorization(.initial)
    let probe = PurgeExecutorProbe()
    let executor = CleanupQuarantinePurgeExecutor(
      testingInitialClaim: { claim in
        probe.record(claim)
        return .noMutation(
          .cancelled,
          durableIntentAlreadyExists: false,
          cancellationWasObserved: true
        )
      },
      testingRetryClaim: { _ in
        Issue.record("Initial authority reached the retry pipeline")
        return .manualRecoveryRequired(
          .invalidExecutionResult,
          observedUnlinkCount: 0,
          cancellationWasObserved: false
        )
      }
    )

    let outcomes = await withTaskGroup(of: PurgeExecutorInvocationOutcome.self) { group in
      for _ in 0..<32 {
        group.addTask {
          do {
            return .report(try await executor.execute(authorization))
          } catch let failure as CleanupQuarantinePurgeAuthorizationConsumptionError {
            return .consumptionFailure(failure)
          } catch {
            return .unexpected
          }
        }
      }
      var values: [PurgeExecutorInvocationOutcome] = []
      for await value in group { values.append(value) }
      return values
    }

    #expect(outcomes.count { if case .report = $0 { true } else { false } } == 1)
    #expect(
      outcomes.count {
        $0 == .consumptionFailure(.authorizationAlreadyConsumed)
      } == 31
    )
    #expect(probe.callCount == 1)
    #expect(probe.lastAttemptKind == .initial)
  }

  @Test("Initial and retry authorities enter only their matching branch")
  func branchesOnConsumedAttemptKind() async throws {
    let probe = PurgeExecutorBranchProbe()
    let executor = CleanupQuarantinePurgeExecutor(
      testingInitialClaim: { claim in
        probe.recordInitial(claim)
        return .noMutation(
          .unsupportedPlatform,
          durableIntentAlreadyExists: false,
          cancellationWasObserved: false
        )
      },
      testingRetryClaim: { claim in
        probe.recordRetry(claim)
        return .noMutation(
          .quarantineJournalBusy,
          durableIntentAlreadyExists: true,
          cancellationWasObserved: false
        )
      }
    )

    let initial = try await executor.execute(
      purgeExecutorAuthorization(.initial)
    )
    let retry = try await executor.execute(
      purgeExecutorAuthorization(.explicitRetry)
    )

    #expect(initial.attemptKind == .initial)
    #expect(initial.status == .noMutation(.unsupportedPlatform))
    #expect(initial.durabilityState == .notRecorded)
    #expect(retry.attemptKind == .explicitRetry)
    #expect(retry.status == .noMutation(.quarantineJournalBusy))
    #expect(retry.durabilityState == .intentRecorded)
    #expect(probe.initialCount == 1)
    #expect(probe.retryCount == 1)
  }

  @Test("A cancelled authorization never enters either execution branch")
  func cancelledAuthorizationDoesNotExecute() async throws {
    let evidence = try purgeExecutorEvidence(.initial)
    let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: evidence)
    let authorization = try await session.authorize(
      using: purgeExecutorConfirmation(for: session)
    )
    await session.cancel()
    let probe = PurgeExecutorProbe()
    let executor = CleanupQuarantinePurgeExecutor(
      testingInitialClaim: { claim in
        probe.record(claim)
        return .manualRecoveryRequired(
          .invalidExecutionResult,
          observedUnlinkCount: 0,
          cancellationWasObserved: false
        )
      },
      testingRetryClaim: { claim in
        probe.record(claim)
        return .manualRecoveryRequired(
          .invalidExecutionResult,
          observedUnlinkCount: 0,
          cancellationWasObserved: false
        )
      }
    )

    do {
      _ = try await executor.execute(authorization)
      Issue.record("Expected cancelled purge authorization")
    } catch let failure as CleanupQuarantinePurgeAuthorizationConsumptionError {
      #expect(failure == .authorizationCancelled)
    }
    #expect(probe.callCount == 0)
  }

  @Test("A terminal item-absent receipt reports bounded observed progress")
  func terminalItemAbsentReport() async throws {
    let report = try await purgeExecutorReport(
      attemptKind: .initial,
      outcome: .terminalReceipt(
        outcome: .itemAbsent,
        producedByRecovery: false,
        capacityObservationProvenance: .initialAttempt,
        observedCapacityChange: .increase(amount: 8_192),
        observedUnlinkCount: 4,
        cancellationWasObserved: false
      )
    )

    #expect(report.status == .itemAbsent)
    #expect(
      report.durabilityState
        == .terminalReceiptRecorded(outcome: .itemAbsent, producedByRecovery: false)
    )
    #expect(report.capacityObservationProvenance == .initialAttempt)
    #expect(report.observedCapacityChange == .increase(amount: 8_192))
    #expect(report.observedUnlinkCount == 4)
    #expect(report.performedPermanentDeletion)
    #expect(report.isDurablyTerminal)
    #expect(report.isCrashRecoverable)
    #expect(!report.requiresExplicitRetry)
  }

  @Test("Item absence can be terminal without an unlink attributed to this call")
  func observationalItemAbsenceDoesNotClaimDeletion() async throws {
    let report = try await purgeExecutorReport(
      attemptKind: .explicitRetry,
      outcome: .terminalReceipt(
        outcome: .itemAbsent,
        producedByRecovery: false,
        capacityObservationProvenance: .explicitRetry,
        observedCapacityChange: .unchanged,
        observedUnlinkCount: 0,
        cancellationWasObserved: false
      )
    )

    #expect(report.status == .itemAbsent)
    #expect(report.observedUnlinkCount == 0)
    #expect(!report.performedPermanentDeletion)
  }

  @Test("Recovered not-purged receipt is terminal and never claims unlink progress")
  func recoveredNotPurgedReport() async throws {
    let report = try await purgeExecutorReport(
      attemptKind: .initial,
      outcome: .terminalReceipt(
        outcome: .notPurged,
        producedByRecovery: true,
        capacityObservationProvenance: .recovery,
        observedCapacityChange: .decrease(amount: 512),
        observedUnlinkCount: 0,
        cancellationWasObserved: true
      )
    )

    #expect(report.status == .notPurged)
    #expect(
      report.durabilityState
        == .terminalReceiptRecorded(outcome: .notPurged, producedByRecovery: true)
    )
    #expect(report.capacityObservationProvenance == .recovery)
    #expect(report.observedCapacityChange == .decrease(amount: 512))
    #expect(report.cancellationWasObserved)
    #expect(!report.performedPermanentDeletion)
  }

  @Test(
    "A synchronized remainder distinguishes staged-only and current-call unlink progress",
    arguments: [UInt64(0), UInt64(3)]
  )
  func explicitRetryProgress(observedUnlinkCount: UInt64) async throws {
    let report = try await purgeExecutorReport(
      attemptKind: .initial,
      outcome: .explicitRetryRequired(
        reason: .cancelled,
        observedUnlinkCount: observedUnlinkCount,
        cancellationWasObserved: true
      )
    )
    let expectedProgress: CleanupQuarantinePurgeProgress =
      observedUnlinkCount == 0 ? .stagedWithNoUnlinkObserved : .unlinkProgressObserved

    #expect(
      report.status
        == .explicitRetryRequired(progress: expectedProgress, reason: .cancelled)
    )
    #expect(report.durabilityState == .intentRecorded)
    #expect(report.observedUnlinkCount == observedUnlinkCount)
    #expect(report.performedPermanentDeletion == (observedUnlinkCount > 0))
    #expect(report.requiresExplicitRetry)
    #expect(report.cancellationWasObserved)
    #expect(report.capacityObservationProvenance == nil)
    #expect(report.observedCapacityChange == .unavailable)
  }

  @Test("Durability-unresolved reporting preserves only bounded unlink progress")
  func manualRecoveryAfterObservedUnlink() async throws {
    let report = try await purgeExecutorReport(
      attemptKind: .explicitRetry,
      outcome: .manualRecoveryRequired(
        .durabilityUnresolved,
        observedUnlinkCount: 2,
        cancellationWasObserved: false
      )
    )

    #expect(report.status == .manualRecoveryRequired(.durabilityUnresolved))
    #expect(report.durabilityState == .unresolved)
    #expect(report.observedUnlinkCount == 2)
    #expect(report.performedPermanentDeletion)
    #expect(!report.isDurablyTerminal)
    #expect(!report.isCrashRecoverable)
  }

  @Test("An intent awaiting observation exposes no journal identifier")
  func observationalRecoveryReport() async throws {
    let report = try await purgeExecutorReport(
      attemptKind: .initial,
      outcome: .observationalRecoveryRequired(
        .stagingMayHaveBeenInvoked,
        cancellationWasObserved: true
      )
    )

    #expect(
      report.status
        == .observationalRecoveryRequired(.stagingMayHaveBeenInvoked)
    )
    #expect(report.durabilityState == .intentRecorded)
    #expect(report.isCrashRecoverable)
    #expect(!report.isDurablyTerminal)
    #expect(report.cancellationWasObserved)
  }

  @Test("Forged report relationships fail closed")
  func invalidOutcomeRelationshipsFailClosed() async throws {
    let mismatchedIntentState = try await purgeExecutorReport(
      attemptKind: .initial,
      outcome: .noMutation(
        .cancelled,
        durableIntentAlreadyExists: true,
        cancellationWasObserved: true
      )
    )
    let retryNotPurged = try await purgeExecutorReport(
      attemptKind: .explicitRetry,
      outcome: .terminalReceipt(
        outcome: .notPurged,
        producedByRecovery: false,
        capacityObservationProvenance: .explicitRetry,
        observedCapacityChange: .unavailable,
        observedUnlinkCount: 0,
        cancellationWasObserved: false
      )
    )
    let wrongProvenance = try await purgeExecutorReport(
      attemptKind: .initial,
      outcome: .terminalReceipt(
        outcome: .itemAbsent,
        producedByRecovery: false,
        capacityObservationProvenance: .explicitRetry,
        observedCapacityChange: .unchanged,
        observedUnlinkCount: 1,
        cancellationWasObserved: false
      )
    )
    let overBound = try await purgeExecutorReport(
      attemptKind: .initial,
      outcome: .explicitRetryRequired(
        reason: .treeChanged,
        observedUnlinkCount: UInt64.max,
        cancellationWasObserved: false
      )
    )

    for report in [mismatchedIntentState, retryNotPurged, wrongProvenance, overBound] {
      #expect(report.status == .manualRecoveryRequired(.invalidExecutionResult))
      #expect(report.durabilityState == .unresolved)
      #expect(report.observedUnlinkCount == 0)
      #expect(!report.performedPermanentDeletion)
    }
  }

  @Test("Report reflection and descriptions contain no purge identifiers or paths")
  func privacyBoundedReflection() async throws {
    let report = try await purgeExecutorReport(
      attemptKind: .initial,
      outcome: .explicitRetryRequired(
        reason: .unlinkRejected(.permissionDenied),
        observedUnlinkCount: 7,
        cancellationWasObserved: false
      )
    )
    let error = CleanupQuarantinePurgeNoMutationReason.quarantineJournalUnavailable(
      .inputOutput
    )
    let rendered = [
      String(describing: report),
      String(reflecting: report),
      purgeExecutorMirrorText(report),
      String(describing: error),
      String(reflecting: error),
      purgeExecutorMirrorText(error),
    ].joined(separator: "\n")
    let forbidden = [
      String(repeating: "a", count: 32),
      String(repeating: "1", count: 32),
      "/Users/private-owner/.npm",
      "item-v1-",
      ".purge-work-v1-",
      "_cacache",
      "eyJjYW5vbmljYWwiOiJieXRlcyJ9",
    ]

    for value in forbidden {
      #expect(!rendered.contains(value))
    }
    #expect(!(report is any Encodable))
    #expect(!(error is any Encodable))
  }
}

private enum PurgeExecutorInvocationOutcome: Equatable, Sendable {
  case report(CleanupQuarantinePurgeReport)
  case consumptionFailure(CleanupQuarantinePurgeAuthorizationConsumptionError)
  case unexpected
}

private final class PurgeExecutorProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  private var attemptKind: CleanupQuarantinePurgeAttemptKind?

  var callCount: Int { lock.withLock { calls } }
  var lastAttemptKind: CleanupQuarantinePurgeAttemptKind? {
    lock.withLock { attemptKind }
  }

  func record(_ claim: CleanupQuarantinePurgeExecutionClaim) {
    lock.withLock {
      calls += 1
      attemptKind = claim.attemptKind
    }
  }
}

private final class PurgeExecutorBranchProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var initialCalls = 0
  private var retryCalls = 0

  var initialCount: Int { lock.withLock { initialCalls } }
  var retryCount: Int { lock.withLock { retryCalls } }

  func recordInitial(_ claim: CleanupQuarantinePurgeExecutionClaim) {
    lock.withLock {
      #expect(claim.attemptKind == .initial)
      initialCalls += 1
    }
  }

  func recordRetry(_ claim: CleanupQuarantinePurgeExecutionClaim) {
    lock.withLock {
      #expect(claim.attemptKind == .explicitRetry)
      retryCalls += 1
    }
  }
}

private func purgeExecutorReport(
  attemptKind: CleanupQuarantinePurgeAttemptKind,
  outcome: CleanupQuarantinePurgeClaimExecutionOutcome
) async throws -> CleanupQuarantinePurgeReport {
  let executor = CleanupQuarantinePurgeExecutor(
    testingInitialClaim: { _ in outcome },
    testingRetryClaim: { _ in outcome }
  )
  return try await executor.execute(
    purgeExecutorAuthorization(attemptKind)
  )
}

private func purgeExecutorAuthorization(
  _ attemptKind: CleanupQuarantinePurgeAttemptKind
) async throws -> CleanupQuarantinePurgeAuthorization {
  let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(
    for: purgeExecutorEvidence(attemptKind)
  )
  return try await session.authorize(
    using: purgeExecutorConfirmation(for: session)
  )
}

private func purgeExecutorConfirmation(
  for session: CleanupQuarantinePurgeAuthorizationSession
) -> CleanupQuarantinePurgeUserConfirmation {
  CleanupQuarantinePurgeUserConfirmation(
    request: session.confirmationRequest,
    statement: session.confirmationRequest.requiredStatement
  )
}

private func purgeExecutorEvidence(
  _ attemptKind: CleanupQuarantinePurgeAttemptKind
) throws -> CleanupQuarantinePurgePreparedEvidence {
  let quarantineIntent = QuarantineJournalIntentV1(
    transactionID: String(repeating: "1", count: 32),
    npmRootBinding: purgeExecutorBinding(inode: 10, linkCount: 3),
    quarantineRootBinding: purgeExecutorBinding(inode: 20, linkCount: 3),
    candidateBinding: purgeExecutorBinding(inode: 30, linkCount: 5),
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<QuarantineJournalIntentV1.destinationCount).map {
      purgeExecutorItemComponent($0)
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
  let purgeIntent = try QuarantinePurgeJournalV1Codec.makeIntent(
    purgeTransactionID: String(repeating: "a", count: 32),
    capacityBefore: QuarantinePurgeCapacityObservationV1(
      volumeIdentity: QuarantinePurgeVolumeIdentityV1(
        device: 7,
        fileSystemIDFirst: -2,
        fileSystemIDSecond: 9
      ),
      availableBytes: 4_096
    ),
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
      ))
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
        currentWorkBinding: purgeExecutorBinding(
          inode: purgeIntent.candidateBinding.inode,
          permissionMode: 0o755,
          linkCount: 2
        )
      ))
  }
}

private func purgeExecutorBinding(
  inode: UInt64,
  permissionMode: UInt32 = 0o700,
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
    flags: 0,
    linkCount: linkCount
  )
}

private func purgeExecutorItemComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal + 1, radix: 16)
  return Array("item-v1-\(String(repeating: "0", count: 32 - suffix.count))\(suffix)".utf8)
}

private func purgeExecutorMirrorText(
  _ value: Any,
  depth: Int = 0
) -> String {
  guard depth < 12 else { return "depth-limit" }
  let mirror = Mirror(reflecting: value)
  let children = mirror.children.map { child in
    let label = child.label ?? "unlabeled"
    return "\(label)=\(purgeExecutorMirrorText(child.value, depth: depth + 1))"
  }
  return "\(String(reflecting: mirror.subjectType)){\(children.joined(separator: ","))}"
}
