import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine authorization lifecycle")
struct CleanupQuarantineAuthorizationLifecycleTests {
  @Test("Sixty-four concurrent issuance requests produce exactly one authorization")
  func concurrentIssuanceIsExactlyOnce() async throws {
    let participantCount = 64
    let value = try await authorizationPendingApproval()
    let session = try syntheticAuthorizationSession(for: value.approval)
    let attestation = authorizationAttestation(for: session)
    let gate = AuthorizationStartGate(participantCount: participantCount)

    let outcomes = await withTaskGroup(of: AuthorizationRaceOutcome.self) { group in
      for _ in 0..<participantCount {
        group.addTask {
          await gate.arriveAndWait()
          do {
            _ = try await session.authorize(using: attestation)
            return .success
          } catch CleanupQuarantineAuthorizationError.attemptAlreadyAuthorized {
            return .expectedFailure
          } catch {
            return .unexpectedFailure(String(describing: error))
          }
        }
      }

      var results: [AuthorizationRaceOutcome] = []
      for await result in group {
        results.append(result)
      }
      return results
    }

    let successCount = outcomes.count { outcome in
      if case .success = outcome { return true }
      return false
    }
    let expectedFailureCount = outcomes.count { outcome in
      if case .expectedFailure = outcome { return true }
      return false
    }
    let unexpectedFailures = outcomes.compactMap { outcome -> String? in
      if case .unexpectedFailure(let description) = outcome { return description }
      return nil
    }

    #expect(successCount == 1)
    #expect(expectedFailureCount == participantCount - 1)
    #expect(unexpectedFailures.isEmpty)
  }

  @Test("Sixty-four concurrent authorization copies produce exactly one execution claim")
  func concurrentConsumptionIsExactlyOnce() async throws {
    let participantCount = 64
    let value = try await authorizationPendingApproval()
    let session = try syntheticAuthorizationSession(for: value.approval)
    let authorization = try await session.authorize(
      using: authorizationAttestation(for: session)
    )
    let copies = Array(repeating: authorization, count: participantCount)
    let gate = AuthorizationStartGate(participantCount: participantCount)

    let outcomes = await withTaskGroup(of: AuthorizationRaceOutcome.self) { group in
      for copy in copies {
        group.addTask {
          await gate.arriveAndWait()
          do {
            _ = try await copy.consumeForExecution()
            return .success
          } catch CleanupQuarantineAuthorizationConsumptionError.authorizationAlreadyConsumed {
            return .expectedFailure
          } catch {
            return .unexpectedFailure(String(describing: error))
          }
        }
      }

      var results: [AuthorizationRaceOutcome] = []
      for await result in group {
        results.append(result)
      }
      return results
    }

    let successCount = outcomes.count { outcome in
      if case .success = outcome { return true }
      return false
    }
    let expectedFailureCount = outcomes.count { outcome in
      if case .expectedFailure = outcome { return true }
      return false
    }
    let unexpectedFailures = outcomes.compactMap { outcome -> String? in
      if case .unexpectedFailure(let description) = outcome { return description }
      return nil
    }

    #expect(successCount == 1)
    #expect(expectedFailureCount == participantCount - 1)
    #expect(unexpectedFailures.isEmpty)
  }

  @Test("Explicit cancellation before issuance is irreversible")
  func explicitCancellationBeforeIssuance() async throws {
    let value = try await authorizationPendingApproval()
    let session = try syntheticAuthorizationSession(for: value.approval)
    await session.cancel()

    await expectAuthorizationError(.attemptCancelled) {
      _ = try await session.authorize(using: authorizationAttestation(for: session))
    }
  }

  @Test("Explicit cancellation after issuance prevents consumption")
  func explicitCancellationAfterIssuance() async throws {
    let value = try await authorizationPendingApproval()
    let session = try syntheticAuthorizationSession(for: value.approval)
    let authorization = try await session.authorize(
      using: authorizationAttestation(for: session)
    )
    await session.cancel()

    await expectAuthorizationConsumptionError(.authorizationCancelled) {
      _ = try await authorization.consumeForExecution()
    }
  }

  @Test("Pre-cancelled issuance cancels the attempt terminally")
  func preCancelledIssuanceIsTerminal() async throws {
    let value = try await authorizationPendingApproval()
    let session = try syntheticAuthorizationSession(for: value.approval)
    let attestation = authorizationAttestation(for: session)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await session.authorize(using: attestation)
    }

    await expectAuthorizationCancellation {
      _ = try await task.value
    }
    await expectAuthorizationError(.attemptCancelled) {
      _ = try await session.authorize(using: attestation)
    }
  }

  @Test("Pre-cancelled consumption cancels every authorization copy terminally")
  func preCancelledConsumptionIsTerminal() async throws {
    let value = try await authorizationPendingApproval()
    let session = try syntheticAuthorizationSession(for: value.approval)
    let authorization = try await session.authorize(
      using: authorizationAttestation(for: session)
    )
    let copy = authorization
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await copy.consumeForExecution()
    }

    await expectAuthorizationCancellation {
      _ = try await task.value
    }
    await expectAuthorizationConsumptionError(.authorizationCancelled) {
      _ = try await authorization.consumeForExecution()
    }
  }

  @Test("Cancellation racing issuance leaves no consumable authorization")
  func cancellationRacingIssuance() async throws {
    let value = try await authorizationPendingApproval()
    let session = try syntheticAuthorizationSession(for: value.approval)
    let attestation = authorizationAttestation(for: session)
    let issueTask = Task { () -> AuthorizationIssueCancelOutcome in
      do {
        return .issued(try await session.authorize(using: attestation))
      } catch CleanupQuarantineAuthorizationError.attemptCancelled {
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
      await expectAuthorizationConsumptionError(.authorizationCancelled) {
        _ = try await authorization.consumeForExecution()
      }
    case .cancelled:
      await expectAuthorizationError(.attemptCancelled) {
        _ = try await session.authorize(using: attestation)
      }
    case .unexpectedFailure(let description):
      Issue.record("Unexpected issue/cancel race result: \(description)")
    }
  }

  @Test("Cancellation racing consumption has one irreversible linearization winner")
  func cancellationRacingConsumption() async throws {
    let value = try await authorizationPendingApproval()
    let session = try syntheticAuthorizationSession(for: value.approval)
    let authorization = try await session.authorize(
      using: authorizationAttestation(for: session)
    )
    let consumeTask = Task { () -> AuthorizationConsumeCancelOutcome in
      do {
        return .consumed(try await authorization.consumeForExecution())
      } catch CleanupQuarantineAuthorizationConsumptionError.authorizationCancelled {
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
      #expect(claim.approval.sourceRoot == value.approval.sourceRoot)
      await expectAuthorizationConsumptionError(.authorizationAlreadyConsumed) {
        _ = try await authorization.consumeForExecution()
      }
    case .cancelled:
      await expectAuthorizationConsumptionError(.authorizationCancelled) {
        _ = try await authorization.consumeForExecution()
      }
    case .unexpectedFailure(let description):
      Issue.record("Unexpected consume/cancel race result: \(description)")
    }
  }
}
