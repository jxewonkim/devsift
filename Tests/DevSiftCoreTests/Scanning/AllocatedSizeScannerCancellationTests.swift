import Darwin
import Dispatch
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Allocated size scanner cancellation")
struct AllocatedSizeScannerCancellationTests {
  @Test("A scan cancelled before work starts throws CancellationError")
  func preCancelledScan() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let task = Task {
      try await AllocatedSizeScanner().scan(root: fixture.root)
    }
    task.cancel()

    await expectCancellation {
      _ = try await task.value
    }
  }

  @Test("Cancellation at a deterministic mid-scan checkpoint is propagated")
  func midScanCancellation() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("one.txt", bytes: [1])
    try fixture.write("two.txt", bytes: [2])
    let gate = BlockingCheckpointGate(target: 1)
    let scanner = AllocatedSizeScanner(
      checkpoint: { count in
        gate.pauseIfNeeded(at: count)
        try Task.checkCancellation()
      }
    )
    let task = Task {
      try await scanner.scan(root: fixture.root)
    }

    await gate.waitUntilPaused()
    task.cancel()
    gate.release()

    await expectCancellation {
      _ = try await task.value
    }
  }

  @Test("Parent cancellation wins over a concurrent root-validation failure")
  func cancellationPrecedesRootFailure() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let gate = BlockingCheckpointGate(target: 0)
    let scanner = AllocatedSizeScanner(afterRootValidation: {
      gate.pauseIfNeeded(at: 0)
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    })
    let task = Task {
      try await scanner.scan(root: fixture.root)
    }

    await gate.waitUntilPaused()
    task.cancel()
    gate.release()

    await expectCancellation {
      _ = try await task.value
    }
  }
}

private final class BlockingCheckpointGate: @unchecked Sendable {
  let target: UInt64
  private let lock = NSLock()
  private let releaseSemaphore = DispatchSemaphore(value: 0)
  private var isPaused = false
  private var arrivalContinuation: CheckedContinuation<Void, Never>?

  init(target: UInt64) {
    self.target = target
  }

  func pauseIfNeeded(at count: UInt64) {
    guard count == target else {
      return
    }

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
