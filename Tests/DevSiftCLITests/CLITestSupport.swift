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

actor ClassificationRequestRecorder {
  private var recordedRequests: [RuleClassificationRequest] = []

  func record(_ request: RuleClassificationRequest) {
    recordedRequests.append(request)
  }

  func requests() -> [RuleClassificationRequest] {
    recordedRequests
  }
}

enum StubClassifierOutcome: Sendable {
  case report(RuleClassificationReport)
  case scanError(ScanError)
  case cancelled
  case unexpectedError
}

struct StubClassifier: RuleClassifying {
  let outcome: StubClassifierOutcome
  let recorder: ClassificationRequestRecorder

  init(
    outcome: StubClassifierOutcome,
    recorder: ClassificationRequestRecorder = ClassificationRequestRecorder()
  ) {
    self.outcome = outcome
    self.recorder = recorder
  }

  func classify(
    _ request: RuleClassificationRequest
  ) async throws -> RuleClassificationReport {
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

enum CLITestClassificationFactory {
  static func revision(
    identifier: String = "devsift.test.rule",
    version: UInt32 = 1
  ) -> RuleRevision {
    RuleRevision(
      identifier: RuleIdentifier(rawValue: identifier)!,
      version: RuleVersion(rawValue: version)!
    )
  }

  static func finding(
    identifier: String = "test-finding",
    kind: RuleFindingKind = .positiveEvidence,
    state: RuleFindingState = .satisfied,
    explanation: String = "The test evidence is satisfied."
  ) -> RuleFinding {
    RuleFinding(
      identifier: CheckIdentifier(rawValue: identifier)!,
      kind: kind,
      state: state,
      explanation: explanation
    )
  }

  static func evaluation(
    rawComponents: [[UInt8]] = [Array("cache".utf8)],
    rule: RuleRevision? = revision(),
    matchingRules: [RuleRevision]? = nil,
    displayName: String = "Test cache",
    responsibleTool: String = "Test tool",
    matchState: RuleMatchState = .matched,
    disposition: RuleDisposition = .reviewRequired,
    reproducibility: RuleReproducibility = .reproducible,
    findings: [RuleFinding] = [finding()],
    explanation: String = "The test decision is explained."
  ) -> RuleEvaluation {
    RuleEvaluation(
      path: ScanRelativePath(rawComponents: rawComponents),
      rule: rule,
      matchingRules: matchingRules ?? rule.map { [$0] } ?? [],
      displayName: displayName,
      responsibleTool: responsibleTool,
      matchState: matchState,
      disposition: disposition,
      reproducibility: reproducibility,
      findings: findings,
      explanation: explanation
    )
  }

  static func unrecognizedEvaluation(
    rawComponents: [[UInt8]] = [Array("cache".utf8)]
  ) -> RuleEvaluation {
    evaluation(
      rawComponents: rawComponents,
      rule: nil,
      matchingRules: [],
      displayName: "Unrecognized item",
      responsibleTool: "Unknown",
      matchState: .unrecognized,
      disposition: .protected,
      reproducibility: .unknown,
      findings: [
        finding(
          identifier: "lexical-recognition",
          kind: .lexicalRecognition,
          state: .failed,
          explanation: "No rule recognized this item."
        )
      ],
      explanation: "No rule recognized this item, so it remains protected."
    )
  }

  static func report(
    referenceUnixSeconds: Int64 = 1_700_000_000,
    evaluations: [RuleEvaluation] = [evaluation()]
  ) -> RuleClassificationReport {
    RuleClassificationReport(
      referenceUnixSeconds: referenceUnixSeconds,
      evaluations: evaluations
    )
  }
}
