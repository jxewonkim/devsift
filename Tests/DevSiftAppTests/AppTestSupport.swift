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
    scanTimeIdentity: FileIdentity? = nil,
    logicalBytes: UInt64 = 0,
    allocatedBytes: UInt64 = 0,
    hardLinkExclusiveAllocatedBytes: UInt64 = 0,
    counts: ScanEntryCounts = counts(),
    unknownAllocatedItemCount: UInt64 = 0,
    possibleSharedContentFileCount: UInt64 = 0,
    sharedContentMetadataUnavailableCount: UInt64 = 0,
    unobservedHardLinkFileCount: UInt64 = 0,
    nonExclusiveHardLinkFileCount: UInt64 = 0,
    newestContentModificationUnixSeconds: Int64? = nil,
    sizeOverflowed: Bool = false,
    isComplete: Bool = true
  ) -> ScanItemSummary {
    ScanItemSummary(
      path: ScanRelativePath(rawComponents: rawComponents),
      kind: kind,
      scanTimeIdentity: scanTimeIdentity,
      recursiveSize: StorageSize(logicalBytes: logicalBytes, allocatedBytes: allocatedBytes),
      hardLinkExclusiveAllocatedBytes: hardLinkExclusiveAllocatedBytes,
      counts: counts,
      unknownAllocatedItemCount: unknownAllocatedItemCount,
      possibleSharedContentFileCount: possibleSharedContentFileCount,
      sharedContentMetadataUnavailableCount: sharedContentMetadataUnavailableCount,
      unobservedHardLinkFileCount: unobservedHardLinkFileCount,
      nonExclusiveHardLinkFileCount: nonExclusiveHardLinkFileCount,
      newestContentModificationUnixSeconds: newestContentModificationUnixSeconds,
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

actor RuleClassificationRequestRecorder {
  private var storage: [RuleClassificationRequest] = []

  func append(_ request: RuleClassificationRequest) {
    storage.append(request)
  }

  func requests() -> [RuleClassificationRequest] {
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

enum ImmediateRuleClassificationOutcome: Sendable {
  case classify
  case report(RuleClassificationReport)
  case cancelled
  case unexpected
}

struct ImmediateRuleClassifier: RuleClassifying, Sendable {
  let outcome: ImmediateRuleClassificationOutcome
  let recorder: RuleClassificationRequestRecorder

  init(
    outcome: ImmediateRuleClassificationOutcome = .classify,
    recorder: RuleClassificationRequestRecorder = RuleClassificationRequestRecorder()
  ) {
    self.outcome = outcome
    self.recorder = recorder
  }

  func classify(
    _ request: RuleClassificationRequest
  ) async throws -> RuleClassificationReport {
    await recorder.append(request)
    switch outcome {
    case .classify:
      return try await ExplainableRuleClassifier().classify(request)
    case .report(let report):
      return report
    case .cancelled:
      throw CancellationError()
    case .unexpected:
      throw AppTestUnexpectedError()
    }
  }
}

/// Produces source-bound, planning-eligible built-in decisions from synthetic
/// report values without opening a filesystem path.
struct SyntheticEligibleRuleClassifier: RuleClassifying, Sendable {
  let recorder: RuleClassificationRequestRecorder?

  init(recorder: RuleClassificationRequestRecorder? = nil) {
    self.recorder = recorder
  }

  func classify(
    _ request: RuleClassificationRequest
  ) async throws -> RuleClassificationReport {
    await recorder?.append(request)
    let observations = request.report.topLevelItems.map { summary in
      RuleObservation(
        summary: summary,
        selectedRootBasename: .known(Array("Caches".utf8)),
        integrity: RuleScanIntegrity(
          reportIsComplete: true,
          itemIsComplete: true,
          topLevelItemsWereSuppressed: false,
          traversalDetailsWereDiscarded: false,
          suppressedIssueCount: 0,
          unknownAllocatedItemCount: 0,
          sizeOverflowed: false,
          hardLinkAccountingIsComplete: true,
          identityMatchesScan: .known(true)
        ),
        facts: RuleObservationFacts(
          trustedLocation: .known(true),
          toolOwnership: .known(true),
          generatedContentMarker: .known(true),
          newestContentModificationUnixSeconds: .known(
            summary.newestContentModificationUnixSeconds ?? 0
          ),
          activity: .known(.inactive),
          protectedDescendantPresent: .known(false),
          siblingPackageManifestPresent: .known(true)
        )
      )
    }
    return try await ExplainableRuleClassifier().classify(
      observations: observations,
      referenceUnixSeconds: request.referenceUnixSeconds
    ).binding(to: request)
  }
}

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

enum GatedRuleClassificationOutcome: Sendable {
  case classify
  case unexpected
}

enum GatedRuleClassifierError: Error {
  case missingOccurrence
}

actor GatedRuleClassifier: RuleClassifying {
  private struct PendingClassification {
    let request: RuleClassificationRequest
    let continuation: CheckedContinuation<RuleClassificationReport, any Error>
  }

  private var pending: [URL: [PendingClassification]] = [:]
  private var startCount: [URL: Int] = [:]

  func classify(
    _ request: RuleClassificationRequest
  ) async throws -> RuleClassificationReport {
    startCount[request.root, default: 0] += 1

    return try await withCheckedThrowingContinuation { continuation in
      pending[request.root, default: []].append(
        PendingClassification(request: request, continuation: continuation)
      )
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

  func request(_ root: URL, occurrence: Int = 0) -> RuleClassificationRequest? {
    guard let pending = pending[root], pending.indices.contains(occurrence) else {
      return nil
    }
    return pending[occurrence].request
  }

  func resolve(
    _ root: URL,
    occurrence: Int = 0,
    with outcome: GatedRuleClassificationOutcome
  ) async throws {
    guard var classifications = pending[root], classifications.indices.contains(occurrence) else {
      let orphaned = pending.values.flatMap { $0 }
      pending.removeAll()
      for pendingClassification in orphaned {
        pendingClassification.continuation.resume(
          throwing: GatedRuleClassifierError.missingOccurrence
        )
      }
      throw GatedRuleClassifierError.missingOccurrence
    }

    let pendingClassification = classifications.remove(at: occurrence)
    pending[root] = classifications.isEmpty ? nil : classifications

    switch outcome {
    case .classify:
      do {
        let result = try await ExplainableRuleClassifier().classify(
          pendingClassification.request
        )
        pendingClassification.continuation.resume(returning: result)
      } catch {
        pendingClassification.continuation.resume(throwing: error)
      }
    case .unexpected:
      pendingClassification.continuation.resume(throwing: AppTestUnexpectedError())
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
