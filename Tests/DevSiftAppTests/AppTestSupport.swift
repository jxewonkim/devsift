import DevSiftCore
import Foundation

@testable import DevSiftApp
@testable import DevSiftCore

enum AppTestReportFactory {
  static func counts(
    regularFiles: UInt64 = 0,
    directories: UInt64 = 1,
    symbolicLinks: UInt64 = 0,
    other: UInt64 = 0,
    duplicateHardLinks: UInt64 = 0
  ) -> ScanEntryCounts {
    ScanEntryCounts(
      regularFiles: regularFiles,
      directories: directories,
      symbolicLinks: symbolicLinks,
      other: other,
      duplicateHardLinks: duplicateHardLinks
    )
  }

  static func item(
    rawComponents: [[UInt8]] = [],
    kind: FileSystemEntryKind = .directory,
    logicalBytes: UInt64 = 0,
    allocatedBytes: UInt64 = 0,
    hardLinkExclusiveAllocatedBytes: UInt64 = 0,
    counts: ScanEntryCounts = counts(),
    unknownAllocatedItemCount: UInt64 = 0,
    possibleSharedContentFileCount: UInt64 = 0,
    sharedContentMetadataUnavailableCount: UInt64 = 0,
    unobservedHardLinkFileCount: UInt64 = 0,
    nonExclusiveHardLinkFileCount: UInt64 = 0,
    sizeOverflowed: Bool = false,
    isComplete: Bool = true
  ) -> ScanItemSummary {
    ScanItemSummary(
      path: ScanRelativePath(rawComponents: rawComponents),
      kind: kind,
      recursiveSize: StorageSize(logicalBytes: logicalBytes, allocatedBytes: allocatedBytes),
      hardLinkExclusiveAllocatedBytes: hardLinkExclusiveAllocatedBytes,
      counts: counts,
      unknownAllocatedItemCount: unknownAllocatedItemCount,
      possibleSharedContentFileCount: possibleSharedContentFileCount,
      sharedContentMetadataUnavailableCount: sharedContentMetadataUnavailableCount,
      unobservedHardLinkFileCount: unobservedHardLinkFileCount,
      nonExclusiveHardLinkFileCount: nonExclusiveHardLinkFileCount,
      sizeOverflowed: sizeOverflowed,
      isComplete: isComplete
    )
  }

  static func report(
    root: ScanItemSummary = item(),
    topLevelItems: [ScanItemSummary] = [],
    topLevelItemCount: UInt64? = nil,
    topLevelItemsWereSuppressed: Bool = false,
    hardLinkAccountingIsComplete: Bool = true,
    traversalDetailsWereDiscarded: Bool = false,
    issues: [ScanIssue] = [],
    suppressedIssueCount: UInt64 = 0
  ) -> ScanReport {
    ScanReport(
      root: root,
      topLevelItems: topLevelItems,
      topLevelItemCount: topLevelItemCount ?? UInt64(topLevelItems.count),
      topLevelItemsWereSuppressed: topLevelItemsWereSuppressed,
      hardLinkAccountingIsComplete: hardLinkAccountingIsComplete,
      traversalDetailsWereDiscarded: traversalDetailsWereDiscarded,
      issues: issues,
      suppressedIssueCount: suppressedIssueCount
    )
  }
}

actor ScanRequestRecorder {
  private var storage: [ScanRequest] = []

  func append(_ request: ScanRequest) {
    storage.append(request)
  }

  func requests() -> [ScanRequest] {
    storage
  }
}

enum ImmediateScanOutcome: Sendable {
  case report(ScanReport)
  case scanError(ScanError)
  case cancelled
  case unexpected
}

struct ImmediateScanner: FileSystemScanning, Sendable {
  let outcome: ImmediateScanOutcome
  let recorder: ScanRequestRecorder

  init(
    outcome: ImmediateScanOutcome,
    recorder: ScanRequestRecorder = ScanRequestRecorder()
  ) {
    self.outcome = outcome
    self.recorder = recorder
  }

  func scan(_ request: ScanRequest) async throws -> ScanReport {
    await recorder.append(request)
    switch outcome {
    case .report(let report):
      return report
    case .scanError(let error):
      throw error
    case .cancelled:
      throw CancellationError()
    case .unexpected:
      throw AppTestUnexpectedError()
    }
  }
}

struct AppTestUnexpectedError: Error, Sendable {}

enum GatedScanOutcome: Sendable {
  case report(ScanReport)
  case scanError(ScanError)
  case unexpected
}

enum GatedScannerError: Error {
  case missingOccurrence
}

actor GatedScanner: FileSystemScanning {
  private var pending: [URL: [CheckedContinuation<ScanReport, any Error>]] = [:]
  private var startCount: [URL: Int] = [:]

  func scan(_ request: ScanRequest) async throws -> ScanReport {
    startCount[request.root, default: 0] += 1

    return try await withCheckedThrowingContinuation { continuation in
      pending[request.root, default: []].append(continuation)
    }
  }

  func waitUntilStarted(
    _ root: URL,
    count: Int = 1,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while startCount[root, default: 0] < count {
      guard clock.now < deadline else {
        return false
      }
      try? await clock.sleep(for: .milliseconds(10))
    }
    return true
  }

  func resolve(_ root: URL, occurrence: Int = 0, with outcome: GatedScanOutcome) throws {
    guard var continuations = pending[root], continuations.indices.contains(occurrence) else {
      let orphaned = pending.values.flatMap { $0 }
      pending.removeAll()
      for continuation in orphaned {
        continuation.resume(throwing: GatedScannerError.missingOccurrence)
      }
      throw GatedScannerError.missingOccurrence
    }
    let continuation = continuations.remove(at: occurrence)
    pending[root] = continuations.isEmpty ? nil : continuations

    switch outcome {
    case .report(let report):
      continuation.resume(returning: report)
    case .scanError(let error):
      continuation.resume(throwing: error)
    case .unexpected:
      continuation.resume(throwing: AppTestUnexpectedError())
    }
  }
}

final class SecurityScopeSpy: SecurityScopedResourceAccessing, @unchecked Sendable {
  struct Snapshot: Equatable {
    let starts: [URL]
    let stops: [URL]
  }

  private let lock = NSLock()
  private let startResult: Bool
  private var starts: [URL] = []
  private var stops: [URL] = []

  init(startResult: Bool = true) {
    self.startResult = startResult
  }

  func startAccessing(_ url: URL) -> Bool {
    lock.withLock {
      starts.append(url)
    }
    return startResult
  }

  func stopAccessing(_ url: URL) {
    lock.withLock {
      stops.append(url)
    }
  }

  func snapshot() -> Snapshot {
    lock.withLock {
      Snapshot(starts: starts, stops: stops)
    }
  }
}
