import Foundation
import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine restore executor")
struct CleanupQuarantineRestoreExecutorTests {
  @Test("Authorization copies permit exactly one restore execution")
  func authorizationCopiesExecuteOnce() async throws {
    let evidence = try restoreAuthorizationEvidence()
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
    let authorization = try await session.authorize(using: restoreConfirmation(for: session))
    let probe = RestoreExecutorProbe()
    let expected = restoreExecutorReport(evidence: evidence)
    let executor = CleanupQuarantineRestoreExecutor { claim in
      probe.record(claim)
      return .success(expected)
    }

    let outcomes = await withTaskGroup(of: RestoreExecutorOutcome.self) { group in
      for _ in 0..<32 {
        group.addTask {
          do {
            return .report(try await executor.execute(authorization))
          } catch let failure as CleanupQuarantineRestoreAuthorizationConsumptionError {
            return .consumptionFailure(failure)
          } catch {
            return .unexpected
          }
        }
      }
      var values: [RestoreExecutorOutcome] = []
      for await value in group { values.append(value) }
      return values
    }

    #expect(outcomes.count { $0 == .report(expected) } == 1)
    #expect(
      outcomes.count {
        $0 == .consumptionFailure(.authorizationAlreadyConsumed)
      } == 31
    )
    #expect(probe.callCount == 1)
    #expect(probe.lastEvidence == evidence)
  }

  @Test("A cancelled authorization never enters filesystem preflight")
  func cancelledAuthorizationDoesNotExecute() async throws {
    let evidence = try restoreAuthorizationEvidence()
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
    let authorization = try await session.authorize(using: restoreConfirmation(for: session))
    await session.cancel()
    let probe = RestoreExecutorProbe()
    let executor = CleanupQuarantineRestoreExecutor { claim in
      probe.record(claim)
      return .success(restoreExecutorReport(evidence: evidence))
    }

    do {
      _ = try await executor.execute(authorization)
      Issue.record("Expected a cancelled restore authorization")
    } catch let failure as CleanupQuarantineRestoreAuthorizationConsumptionError {
      #expect(failure == .authorizationCancelled)
    }
    #expect(probe.callCount == 0)
  }

  @Test("Preflight root drift becomes a bounded non-durable report")
  func rootDriftReport() async throws {
    let evidence = try restoreAuthorizationEvidence()
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
    let authorization = try await session.authorize(using: restoreConfirmation(for: session))
    let executor = CleanupQuarantineRestoreExecutor { _ in .failure(.rootUnsafe) }

    let report = try await executor.execute(authorization)

    #expect(report.status == .notRestored(.trustedRootChanged))
    #expect(report.durabilityState == .notRecorded)
    #expect(!report.isCrashRecoverable)
    #expect(!report.performedPermanentDeletion)
    #expect(!report.overwroteExistingItem)
  }

  @Test("A pending journal blocker is never presented as restore durability")
  func pendingJournalBlocker() async throws {
    let evidence = try restoreAuthorizationEvidence()
    let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
    let authorization = try await session.authorize(using: restoreConfirmation(for: session))
    let blocker = String(repeating: "f", count: 32)
    let executor = CleanupQuarantineRestoreExecutor { _ in
      .failure(.restore(.journal(.recoveryRequired(transactionID: blocker))))
    }

    let report = try await executor.execute(authorization)

    #expect(
      report.status
        == .manualRecoveryRequired(
          quarantineLocation: nil,
          reason: .quarantineJournalUnsafe
        )
    )
    #expect(report.durabilityState == .unresolved(restoreTransactionID: blocker))
    #expect(!report.isCrashRecoverable)
    #expect(!report.isDurablyRecorded)
  }
}

private enum RestoreExecutorOutcome: Equatable, Sendable {
  case report(CleanupQuarantineRestoreReport)
  case consumptionFailure(CleanupQuarantineRestoreAuthorizationConsumptionError)
  case unexpected
}

private final class RestoreExecutorProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  private var evidence: CleanupQuarantineRestorePreparedEvidence?

  var callCount: Int { lock.withLock { calls } }
  var lastEvidence: CleanupQuarantineRestorePreparedEvidence? {
    lock.withLock { evidence }
  }

  func record(_ claim: CleanupQuarantineRestoreExecutionClaim) {
    lock.withLock {
      calls += 1
      evidence = claim.evidence
    }
  }
}

private func restoreExecutorReport(
  evidence: CleanupQuarantineRestorePreparedEvidence
) -> CleanupQuarantineRestoreReport {
  let policy =
    (try? QuarantineJournalV1Codec.decodeIntent(
      evidence.canonicalQuarantineIntentBytes
    ))?.policy.npmRule
  let identifier = RuleIdentifier(rawValue: policy?.identifier ?? "devsift.cache.npm")!
  let version = RuleVersion(rawValue: policy?.version ?? 5)!
  return CleanupQuarantineRestoreReport(
    quarantineTransactionID: evidence.restoreIntent.quarantineTransactionID,
    restoreTransactionID: evidence.restoreIntent.restoreTransactionID,
    path: ScanRelativePath(rawComponents: evidence.restoreIntent.sourceComponents),
    ruleRevision: RuleRevision(identifier: identifier, version: version),
    status: .notRestored(.cancelled)
  )
}
