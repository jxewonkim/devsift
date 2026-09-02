import DevSiftCore
import Foundation

@testable import DevSiftCLI
@testable import DevSiftCore

actor ScanRequestRecorder {
  private var recordedRequests: [ScanRequest] = []

  func record(_ request: ScanRequest) {
    recordedRequests.append(request)
  }

  func requests() -> [ScanRequest] {
    recordedRequests
  }
}

enum StubScannerOutcome: Sendable {
  case report(ScanReport)
  case scanError(ScanError)
  case cancelled
  case unexpectedError
}

struct StubScannerError: Error, Sendable {}

struct StubScanner: FileSystemScanning {
  let outcome: StubScannerOutcome
  let recorder: ScanRequestRecorder

  init(
    outcome: StubScannerOutcome,
    recorder: ScanRequestRecorder = ScanRequestRecorder()
  ) {
    self.outcome = outcome
    self.recorder = recorder
  }

  func scan(_ request: ScanRequest) async throws -> ScanReport {
    await recorder.record(request)

    switch outcome {
    case .report(let report):
      return report
    case .scanError(let error):
      throw error
    case .cancelled:
      throw CancellationError()
    case .unexpectedError:
      throw StubScannerError()
    }
  }
}

enum CLITestReportFactory {
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
    hardLinkExclusiveAllocatedBytes: UInt64? = nil,
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
      recursiveSize: StorageSize(
        logicalBytes: logicalBytes,
        allocatedBytes: allocatedBytes
      ),
      hardLinkExclusiveAllocatedBytes: hardLinkExclusiveAllocatedBytes ?? allocatedBytes,
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
