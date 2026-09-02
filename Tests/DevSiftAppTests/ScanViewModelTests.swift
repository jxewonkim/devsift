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
    #expect(model.isWorking == false)
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
    let classificationRecorder = RuleClassificationRequestRecorder()
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(report), recorder: recorder),
      classifier: ImmediateRuleClassifier(recorder: classificationRecorder),
      securityScope: scope,
      referenceUnixSeconds: { 1_700_000_000 }
    )

    let task = model.startScan(at: root)
    await task.value

    let requests = await recorder.requests()
    #expect(requests == [ScanRequest(root: root)])
    let classificationRequests = await classificationRecorder.requests()
    #expect(classificationRequests.count == 1)
    #expect(classificationRequests.first?.root == root)
    #expect(classificationRequests.first?.report == report)
    #expect(classificationRequests.first?.referenceUnixSeconds == 1_700_000_000)
    #expect(scope.snapshot() == .init(starts: [root], stops: [root]))
    guard case .result(let resultRoot, let presentation) = model.phase else {
      Issue.record("Expected a result phase")
      return
    }
    #expect(resultRoot == root)
    #expect(presentation.report == report)
    #expect(presentation.classification.referenceUnixSeconds == 1_700_000_000)
    #expect(presentation.observationIsComplete)
  }

  @Test("Security-scoped access remains active until policy classification finishes")
  func securityScopeCoversClassification() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/policy-scope", isDirectory: true)
    let report = AppTestReportFactory.report(
      topLevelItems: [
        AppTestReportFactory.item(rawComponents: [Array("DerivedData".utf8)])
      ]
    )
    let classifier = GatedRuleClassifier()
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(report)),
      classifier: classifier,
      securityScope: scope,
      referenceUnixSeconds: { 123 }
    )

    let task = model.startScan(at: root)
    try #require(await classifier.waitUntilStarted(root))

    #expect(model.phase == .classifying(root))
    #expect(model.isWorking)
    #expect(scope.snapshot() == .init(starts: [root], stops: []))
    let request = try #require(await classifier.request(root))
    #expect(request.root == root)
    #expect(request.report == report)
    #expect(request.referenceUnixSeconds == 123)

    try await classifier.resolve(root, with: .classify)
    await task.value

    guard case .result(let resultRoot, let presentation) = model.phase else {
      Issue.record("Expected a classified result")
      return
    }
    #expect(resultRoot == root)
    #expect(presentation.items.first?.policy.matchState == .possibleMatch)
    #expect(presentation.items.first?.policy.disposition == .protected)
    #expect(scope.snapshot() == .init(starts: [root], stops: [root]))
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
      AppTestReportFactory.report(
        topLevelItemsWereSuppressed: true,
        hardLinkAccountingIsComplete: false,
        traversalDetailsWereDiscarded: true
      ),
      AppTestReportFactory.report(
        root: AppTestReportFactory.item(isComplete: false),
        suppressedIssueCount: 1
      ),
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

  @Test("Classifier cancellation and failure remain safe terminal states")
  func classifierTerminalStates() async {
    let root = URL(fileURLWithPath: "/private/tmp/policy-terminal-state", isDirectory: true)
    let report = AppTestReportFactory.report()

    let cancelledScope = SecurityScopeSpy()
    let cancelled = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(report)),
      classifier: ImmediateRuleClassifier(outcome: .cancelled),
      securityScope: cancelledScope
    )
    await cancelled.startScan(at: root).value
    #expect(cancelled.phase == .cancelled(root))
    #expect(cancelledScope.snapshot() == .init(starts: [root], stops: [root]))

    let failedScope = SecurityScopeSpy()
    let failed = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(report)),
      classifier: ImmediateRuleClassifier(outcome: .unexpected),
      securityScope: failedScope
    )
    await failed.startScan(at: root).value
    #expect(failed.phase == .failed(root, .classification))
    #expect(failedScope.snapshot() == .init(starts: [root], stops: [root]))
    guard case .failed(_, let failure) = failed.phase else {
      return
    }
    #expect(failure.message.contains(root.path) == false)
    #expect(failure.message.contains("NSError") == false)
  }

  @Test("A classifier report with a mismatched reference time fails closed")
  func mismatchedClassificationReferenceTime() async {
    let root = URL(fileURLWithPath: "/private/tmp/mismatched-policy-time", isDirectory: true)
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(AppTestReportFactory.report())),
      classifier: ImmediateRuleClassifier(
        outcome: .report(
          RuleClassificationReport(referenceUnixSeconds: 101, evaluations: [])
        )
      ),
      securityScope: scope,
      referenceUnixSeconds: { 100 }
    )

    await model.startScan(at: root).value

    #expect(model.phase == .failed(root, .classification))
    #expect(scope.snapshot() == .init(starts: [root], stops: [root]))
    guard case .failed(_, let failure) = model.phase else {
      Issue.record("An invalid classifier report must not reach presentation")
      return
    }
    #expect(failure.message == ScanFailure.classification.message)
    #expect(failure.message.contains("reference") == false)
    #expect(failure.message.contains("101") == false)
  }

  @Test("Classifier reports with missing or extra evaluations fail closed")
  func invalidClassificationPathCoverage() async throws {
    let referenceUnixSeconds: Int64 = 100
    let item = AppTestReportFactory.item(rawComponents: [Array("ordinary".utf8)])
    let reportWithItem = AppTestReportFactory.report(topLevelItems: [item])
    let missing = RuleClassificationReport(
      referenceUnixSeconds: referenceUnixSeconds,
      evaluations: []
    )
    let extra = try await ExplainableRuleClassifier().classify(
      RuleClassificationRequest(
        root: URL(fileURLWithPath: "/private/tmp/extra-policy-source", isDirectory: true),
        report: reportWithItem,
        referenceUnixSeconds: referenceUnixSeconds
      )
    )
    let fixtures: [(ScanReport, RuleClassificationReport)] = [
      (reportWithItem, missing),
      (AppTestReportFactory.report(), extra),
    ]

    for (index, fixture) in fixtures.enumerated() {
      let root = URL(
        fileURLWithPath: "/private/tmp/invalid-policy-coverage-\(index)",
        isDirectory: true
      )
      let scope = SecurityScopeSpy()
      let model = ScanViewModel(
        scanner: ImmediateScanner(outcome: .report(fixture.0)),
        classifier: ImmediateRuleClassifier(outcome: .report(fixture.1)),
        securityScope: scope,
        referenceUnixSeconds: { referenceUnixSeconds }
      )

      await model.startScan(at: root).value

      #expect(model.phase == .failed(root, .classification))
      #expect(scope.snapshot() == .init(starts: [root], stops: [root]))
      guard case .failed(_, let failure) = model.phase else {
        Issue.record("An invalid classifier report must not reach presentation")
        continue
      }
      #expect(failure.message == ScanFailure.classification.message)
      #expect(failure.message.contains("ordinary") == false)
      #expect(failure.message.contains("evaluation") == false)
    }
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
      let classificationRecorder = RuleClassificationRequestRecorder()
      let model = ScanViewModel(
        scanner: ImmediateScanner(outcome: .scanError(error)),
        classifier: ImmediateRuleClassifier(recorder: classificationRecorder),
        securityScope: scope
      )

      await model.startScan(at: root).value

      #expect(model.phase == .failed(root, .scan(error)))
      #expect(await classificationRecorder.requests().isEmpty)
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

  @Test("Cancelling policy analysis is immediate and ignores its late result")
  func cancellationDuringClassificationIgnoresLateResult() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/cancelled-policy", isDirectory: true)
    let classifier = GatedRuleClassifier()
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(AppTestReportFactory.report())),
      classifier: classifier,
      securityScope: scope
    )

    let task = model.startScan(at: root)
    try #require(await classifier.waitUntilStarted(root))
    #expect(model.phase == .classifying(root))

    model.cancelScan()
    model.cancelScan()
    #expect(model.phase == .cancelled(root))
    #expect(scope.snapshot() == .init(starts: [root], stops: []))

    try await classifier.resolve(root, with: .classify)
    await task.value

    #expect(model.phase == .cancelled(root))
    #expect(scope.snapshot() == .init(starts: [root], stops: [root]))
  }

  @Test("A newer policy classification wins when an older one returns late")
  func newerClassificationWins() async throws {
    let firstRoot = URL(fileURLWithPath: "/private/tmp/first-policy", isDirectory: true)
    let secondRoot = URL(fileURLWithPath: "/private/tmp/second-policy", isDirectory: true)
    let report = AppTestReportFactory.report(
      topLevelItems: [AppTestReportFactory.item(rawComponents: [Array("uv".utf8)])]
    )
    let classifier = GatedRuleClassifier()
    let scope = SecurityScopeSpy()
    let model = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(report)),
      classifier: classifier,
      securityScope: scope
    )

    let firstTask = model.startScan(at: firstRoot)
    try #require(await classifier.waitUntilStarted(firstRoot))
    let secondTask = model.startScan(at: secondRoot)
    try #require(await classifier.waitUntilStarted(secondRoot))

    try await classifier.resolve(secondRoot, with: .classify)
    await secondTask.value
    try await classifier.resolve(firstRoot, with: .unexpected)
    await firstTask.value

    guard case .result(let root, let presentation) = model.phase else {
      Issue.record("Expected the newer policy result")
      return
    }
    #expect(root == secondRoot)
    #expect(presentation.report == report)
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
