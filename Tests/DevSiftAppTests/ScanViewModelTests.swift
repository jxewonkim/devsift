import Darwin
import DevSiftCore
import Foundation
import Testing

@testable import DevSiftApp

@MainActor
@Suite("Scan dashboard view model")
struct ScanViewModelTests {
  @Test("The app starts idle and never scans implicitly")
  func startsIdle() async {
    let recorder = ScanRequestRecorder()
    let model = ScanViewModel(
      scanner: ImmediateScanner(
        outcome: .report(AppTestReportFactory.report()),
        recorder: recorder
      ),
      securityScope: SecurityScopeSpy()
    )

    #expect(model.phase == .empty)
    #expect(model.isScanning == false)
    #expect(model.canRescan == false)
    #expect(await recorder.requests().isEmpty)
  }

  @Test("A successful scan preserves the selected URL and balances security scope")
  func successfulScan() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/DevSift fixture/../selected", isDirectory: true)
    let report = AppTestReportFactory.report(
      root: AppTestReportFactory.item(logicalBytes: 2_048, allocatedBytes: 4_096)
    )
    let recorder = ScanRequestRecorder()
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(report), recorder: recorder),
      securityScope: scope
    )

    let task = model.startScan(at: root)
    await task.value

    let requests = await recorder.requests()
    #expect(requests == [ScanRequest(root: root)])
    #expect(scope.snapshot() == .init(starts: [root], stops: [root]))
    guard case .result(let resultRoot, let presentation) = model.phase else {
      Issue.record("Expected a result phase")
      return
    }
    #expect(resultRoot == root)
    #expect(presentation.report == report)
    #expect(presentation.observationIsComplete)
  }

  @Test("A security scope that is not needed does not block an otherwise readable URL")
  func scopeNotNeeded() async {
    let root = URL(fileURLWithPath: "/private/tmp/devsift-unscoped", isDirectory: true)
    let recorder = ScanRequestRecorder()
    let scope = SecurityScopeSpy(startResult: false)
    let model = ScanViewModel(
      scanner: ImmediateScanner(
        outcome: .report(AppTestReportFactory.report()),
        recorder: recorder
      ),
      securityScope: scope
    )

    await model.startScan(at: root).value

    #expect(await recorder.requests().count == 1)
    #expect(scope.snapshot() == .init(starts: [root], stops: []))
    guard case .result = model.phase else {
      Issue.record("An already-readable unscoped URL should still be scanned")
      return
    }
  }

  @Test("Every partial report remains a usable partial observation")
  func partialReports() async {
    let reports = [
      AppTestReportFactory.report(root: AppTestReportFactory.item(isComplete: false)),
      AppTestReportFactory.report(topLevelItemsWereSuppressed: true),
      AppTestReportFactory.report(hardLinkAccountingIsComplete: false),
      AppTestReportFactory.report(traversalDetailsWereDiscarded: true),
      AppTestReportFactory.report(suppressedIssueCount: 1),
    ]

    for (index, report) in reports.enumerated() {
      let model = ScanViewModel(
        scanner: ImmediateScanner(outcome: .report(report)),
        securityScope: SecurityScopeSpy()
      )
      let root = URL(fileURLWithPath: "/private/tmp/partial-\(index)", isDirectory: true)

      await model.startScan(at: root).value

      guard case .result(_, let presentation) = model.phase else {
        Issue.record("Expected a partial result")
        continue
      }
      #expect(presentation.observationIsComplete == false)
      #expect(presentation.report == report)
    }
  }

  @Test("Rescan reuses the exact selected URL")
  func rescanUsesExactURL() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/a/../rescan-root", isDirectory: true)
    let recorder = ScanRequestRecorder()
    let model = ScanViewModel(
      scanner: ImmediateScanner(
        outcome: .report(AppTestReportFactory.report()),
        recorder: recorder
      ),
      securityScope: SecurityScopeSpy()
    )

    await model.startScan(at: root).value
    let task = try #require(model.rescan())
    await task.value

    #expect(await recorder.requests() == [ScanRequest(root: root), ScanRequest(root: root)])
  }

  @Test("Cancellation and unexpected errors remain distinct terminal states")
  func terminalErrorStates() async {
    let root = URL(fileURLWithPath: "/private/tmp/terminal-state", isDirectory: true)

    let cancelled = ScanViewModel(
      scanner: ImmediateScanner(outcome: .cancelled),
      securityScope: SecurityScopeSpy()
    )
    await cancelled.startScan(at: root).value
    #expect(cancelled.phase == .cancelled(root))

    let unexpected = ScanViewModel(
      scanner: ImmediateScanner(outcome: .unexpected),
      securityScope: SecurityScopeSpy()
    )
    await unexpected.startScan(at: root).value
    #expect(unexpected.phase == .failed(root, .unexpected))
    guard case .failed(_, let failure) = unexpected.phase else {
      return
    }
    #expect(failure.message.contains(root.path) == false)
    #expect(failure.message.contains("NSError") == false)
  }

  @Test("Scanner failures map to bounded presentation errors")
  func failureMapping() async {
    let errors: [ScanError] = [
      .rootMustBeAbsoluteFileURL,
      .rootNotFound,
      .rootIsSymbolicLink,
      .rootIsNotDirectory,
      .rootChangedDuringValidation,
      .rootUnavailable(operation: .readMetadata, systemCode: EACCES),
    ]

    for (index, error) in errors.enumerated() {
      let root = URL(fileURLWithPath: "/private/tmp/error-\(index)", isDirectory: true)
      let scope = SecurityScopeSpy()
      let model = ScanViewModel(
        scanner: ImmediateScanner(outcome: .scanError(error)),
        securityScope: scope
      )

      await model.startScan(at: root).value

      #expect(model.phase == .failed(root, .scan(error)))
      #expect(scope.snapshot() == .init(starts: [root], stops: [root]))
      guard case .failed(_, let failure) = model.phase else {
        continue
      }
      #expect(failure.message.contains(root.path) == false)
      #expect(failure.message.contains("NSError") == false)
    }
  }

  @Test("Cancellation is immediate in the UI and ignores a late success")
  func cancellationIgnoresLateSuccess() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/cancelled", isDirectory: true)
    let scanner = GatedScanner()
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(scanner: scanner, securityScope: scope)

    let task = model.startScan(at: root)
    try #require(await scanner.waitUntilStarted(root))
    #expect(model.phase == .scanning(root))

    model.cancelScan()
    model.cancelScan()
    #expect(model.phase == .cancelled(root))

    try await scanner.resolve(root, with: .report(AppTestReportFactory.report()))
    await task.value

    #expect(model.phase == .cancelled(root))
    #expect(scope.snapshot() == .init(starts: [root], stops: [root]))
  }

  @Test("A newer scan wins when an older scanner returns late")
  func newerScanWins() async throws {
    let firstRoot = URL(fileURLWithPath: "/private/tmp/first", isDirectory: true)
    let secondRoot = URL(fileURLWithPath: "/private/tmp/second", isDirectory: true)
    let firstReport = AppTestReportFactory.report(
      root: AppTestReportFactory.item(allocatedBytes: 1_024)
    )
    let secondReport = AppTestReportFactory.report(
      root: AppTestReportFactory.item(allocatedBytes: 8_192)
    )
    let scanner = GatedScanner()
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(scanner: scanner, securityScope: scope)

    let firstTask = model.startScan(at: firstRoot)
    try #require(await scanner.waitUntilStarted(firstRoot))
    let secondTask = model.startScan(at: secondRoot)
    try #require(await scanner.waitUntilStarted(secondRoot))

    try await scanner.resolve(secondRoot, with: .report(secondReport))
    await secondTask.value
    try await scanner.resolve(firstRoot, with: .report(firstReport))
    await firstTask.value

    guard case .result(let root, let presentation) = model.phase else {
      Issue.record("Expected the second result")
      return
    }
    #expect(root == secondRoot)
    #expect(presentation.report == secondReport)
    #expect(
      scope.snapshot()
        == .init(starts: [firstRoot, secondRoot], stops: [secondRoot, firstRoot])
    )
  }

  @Test("A same-root rescan wins over the cancelled scan's late failure")
  func sameRootRescanWins() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/same-root", isDirectory: true)
    let report = AppTestReportFactory.report(
      root: AppTestReportFactory.item(allocatedBytes: 16_384)
    )
    let scanner = GatedScanner()
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(scanner: scanner, securityScope: scope)

    let firstTask = model.startScan(at: root)
    try #require(await scanner.waitUntilStarted(root))
    model.cancelScan()

    let secondTask = try #require(model.rescan())
    try #require(await scanner.waitUntilStarted(root, count: 2))
    try await scanner.resolve(root, occurrence: 1, with: .report(report))
    await secondTask.value
    try await scanner.resolve(root, with: .unexpected)
    await firstTask.value

    guard case .result(let resultRoot, let presentation) = model.phase else {
      Issue.record("Expected the rescan result")
      return
    }
    #expect(resultRoot == root)
    #expect(presentation.report == report)
    #expect(scope.snapshot() == .init(starts: [root, root], stops: [root, root]))
  }

  @Test("Window closure cancels work without publishing a new phase")
  func teardownCancellation() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/window-close", isDirectory: true)
    let scanner = GatedScanner()
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(scanner: scanner, securityScope: scope)

    let task = model.startScan(at: root)
    try #require(await scanner.waitUntilStarted(root))
    model.stopForWindowClosure()
    try await scanner.resolve(root, with: .unexpected)
    await task.value

    #expect(model.phase == .scanning(root))
    #expect(scope.snapshot() == .init(starts: [root], stops: [root]))
  }
}
