import Dispatch
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine executor")
struct CleanupQuarantineExecutorTests {
  @Test("Sixty-four authorization copies permit exactly one execution")
  func concurrentAuthorizationCopies() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let authorization = try await fixture.makeAuthorization()
    let executor = CleanupQuarantineExecutor(
      preflight: fixture.preflight(),
      mover: supportedExecutionTestMover(
        nonceBytes: { _ in [UInt8](repeating: 0x55, count: 16) }
      )
    )

    let outcomes = await withTaskGroup(of: ExecutorRaceOutcome.self) { group in
      for _ in 0..<64 {
        group.addTask {
          do {
            return .report(try await executor.execute(authorization))
          } catch let error as CleanupQuarantineAuthorizationConsumptionError {
            return .consumptionFailure(error)
          } catch is CancellationError {
            return .unexpectedCancellation
          } catch {
            return .unexpectedError
          }
        }
      }
      var values: [ExecutorRaceOutcome] = []
      for await value in group {
        values.append(value)
      }
      return values
    }

    let reports = outcomes.compactMap { outcome -> CleanupQuarantineExecutionReport? in
      guard case .report(let report) = outcome else { return nil }
      return report
    }
    let alreadyConsumed = outcomes.count { outcome in
      outcome == .consumptionFailure(.authorizationAlreadyConsumed)
    }
    let report = try #require(reports.only)
    let location = try executorQuarantinedLocation(from: report)

    #expect(outcomes.count == 64)
    #expect(reports.count == 1)
    #expect(alreadyConsumed == 63)
    #expect(!FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(
      FileManager.default.fileExists(
        atPath: try executorLocationURL(location, root: fixture.root).path
      )
    )
    #expect(!report.isDurablyRecorded)
    #expect(!report.performedPermanentDeletion)
  }

  @Test("Separate authorizations for one approval cannot both claim the same move")
  func concurrentAuthorizationsForOneApproval() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let approval = try await fixture.makeApproval()
    let firstAuthorization = try await fixture.makeAuthorization(for: approval)
    let secondAuthorization = try await fixture.makeAuthorization(for: approval)
    let quarantineRoot = try fixture.scannerFixture.makeDirectory(
      ".devsift-quarantine-v1",
      under: fixture.root
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: quarantineRoot.path
    )
    let barrier = ExecutorTwoPartyBarrier()
    let executor = CleanupQuarantineExecutor(
      preflight: fixture.preflight(),
      mover: supportedExecutionTestMover(
        nonceBytes: { _ in [UInt8](repeating: 0x56, count: 16) },
        hooks: DescriptorExclusiveQuarantineMoverHooks(
          afterFinalSourceValidationBeforeRename: { _ in
            barrier.arriveAndWait()
          }
        )
      )
    )

    async let first = executor.execute(firstAuthorization)
    async let second = executor.execute(secondAuthorization)
    let reports = try await [first, second]
    let moved = reports.count { report in
      guard case .quarantinedAwaitingReceipt = report.status else { return false }
      return true
    }
    let indeterminate = reports.count { report in
      guard
        case .manualRecoveryRequired(_, .renameOutcomeIndeterminate) = report.status
      else { return false }
      return true
    }

    #expect(moved == 1)
    #expect(indeterminate == 1)
    #expect(!barrier.didTimeOut)
    #expect(!FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: quarantineRoot.path).count == 1)
    #expect(reports.allSatisfy { !$0.performedPermanentDeletion })
  }

  @Test("A task cancelled before execute consumes no mutation authority")
  func preCancelledExecution() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let authorization = try await fixture.makeAuthorization()
    let executor = CleanupQuarantineExecutor(
      preflight: fixture.preflight(),
      mover: supportedExecutionTestMover()
    )
    let before = try treeSnapshot(at: fixture.scannerFixture.container)

    let task = Task {
      withUnsafeCurrentTask { current in
        current?.cancel()
      }
      return try await executor.execute(authorization)
    }
    do {
      _ = try await task.value
      Issue.record("Expected cancellation before authorization consumption")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Expected CancellationError, received \(error)")
    }

    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(try treeSnapshot(at: fixture.scannerFixture.container) == before)
  }

  @Test("Task cancellation at the final pre-rename hook returns not-moved")
  func taskCancellationBeforeRename() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let authorization = try await fixture.makeAuthorization()
    let gate = ExecutorBlockingGate()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterFinalSourceValidationBeforeRename: { _ in gate.pause() }
    )
    let executor = CleanupQuarantineExecutor(
      preflight: fixture.preflight(),
      mover: supportedExecutionTestMover(
        cancellationIsRequested: { Task.isCancelled },
        hooks: hooks
      )
    )

    let task = Task { try await executor.execute(authorization) }
    await gate.waitUntilPaused()
    task.cancel()
    gate.release()
    let report = try await task.value

    #expect(report.status == .notMoved(.cancelled))
    #expect(!report.cancellationWasObservedAfterRename)
    #expect(FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(!report.performedPermanentDeletion)
  }

  @Test("Task cancellation after rename preserves the moved report and latch")
  func taskCancellationAfterRename() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let authorization = try await fixture.makeAuthorization()
    let gate = ExecutorBlockingGate()
    let hooks = DescriptorExclusiveQuarantineMoverHooks(
      afterRenameReturn: { _, result in
        if result == .succeeded { gate.pause() }
      }
    )
    let executor = CleanupQuarantineExecutor(
      preflight: fixture.preflight(),
      mover: supportedExecutionTestMover(
        nonceBytes: { _ in [UInt8](repeating: 0x99, count: 16) },
        cancellationIsRequested: { Task.isCancelled },
        hooks: hooks
      )
    )

    let task = Task { try await executor.execute(authorization) }
    await gate.waitUntilPaused()
    task.cancel()
    gate.release()
    let report = try await task.value
    let location = try executorQuarantinedLocation(from: report)

    #expect(report.cancellationWasObservedAfterRename)
    #expect(!FileManager.default.fileExists(atPath: fixture.candidate.path))
    #expect(
      FileManager.default.fileExists(
        atPath: try executorLocationURL(location, root: fixture.root).path
      )
    )
    #expect(!report.performedPermanentDeletion)
  }
}

private enum ExecutorRaceOutcome: Equatable, Sendable {
  case report(CleanupQuarantineExecutionReport)
  case consumptionFailure(CleanupQuarantineAuthorizationConsumptionError)
  case unexpectedCancellation
  case unexpectedError
}

private func executorQuarantinedLocation(
  from report: CleanupQuarantineExecutionReport
) throws -> CleanupQuarantineLocation {
  guard case .quarantinedAwaitingReceipt(let location, false) = report.status else {
    throw ExecutorTestError.unexpectedStatus
  }
  return location
}

private func executorLocationURL(_ location: CleanupQuarantineLocation, root: URL) throws -> URL {
  try location.relativePath.rawComponents.reduce(root) { result, bytes in
    guard let component = String(bytes: bytes, encoding: .utf8) else {
      throw ExecutorTestError.invalidLocation
    }
    return result.appendingPathComponent(component)
  }
}

private enum ExecutorTestError: Error {
  case unexpectedStatus
  case invalidLocation
}

extension Array {
  fileprivate var only: Element? { count == 1 ? self[0] : nil }
}

private final class ExecutorBlockingGate: @unchecked Sendable {
  private let lock = NSLock()
  private let releaseSemaphore = DispatchSemaphore(value: 0)
  private var isPaused = false
  private var arrivalContinuation: CheckedContinuation<Void, Never>?

  func pause() {
    lock.lock()
    isPaused = true
    let continuation = arrivalContinuation
    arrivalContinuation = nil
    lock.unlock()

    continuation?.resume()
    releaseSemaphore.wait()
  }

  func waitUntilPaused() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if isPaused {
        lock.unlock()
        continuation.resume()
      } else {
        arrivalContinuation = continuation
        lock.unlock()
      }
    }
  }

  func release() {
    releaseSemaphore.signal()
  }
}

private final class ExecutorTwoPartyBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private let releaseSemaphore = DispatchSemaphore(value: 0)
  private var arrivals = 0
  private var timedOut = false

  var didTimeOut: Bool {
    lock.withLock { timedOut }
  }

  func arriveAndWait() {
    lock.lock()
    arrivals += 1
    let shouldRelease = arrivals == 2
    lock.unlock()

    if shouldRelease {
      releaseSemaphore.signal()
      releaseSemaphore.signal()
    }
    if releaseSemaphore.wait(timeout: .now() + 5) == .timedOut {
      lock.withLock { timedOut = true }
    }
  }
}
