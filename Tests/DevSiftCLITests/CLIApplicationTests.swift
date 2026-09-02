import Darwin
import DevSiftCore
import Foundation
import Testing

@testable import DevSiftCLI

@Suite("CLI application")
struct CLIApplicationTests {
  @Test("Status, version and help stay on standard output")
  func informationalCommands() async {
    let recorder = ScanRequestRecorder()
    let classificationRecorder = ClassificationRequestRecorder()
    let scanner = StubScanner(
      outcome: .report(CLITestReportFactory.report()),
      recorder: recorder
    )
    let classifier = StubClassifier(
      outcome: .report(CLITestClassificationFactory.report()),
      recorder: classificationRecorder
    )
    let application = CLIApplication(scanner: scanner, classifier: classifier)

    let status = await application.run(arguments: [])
    #expect(status.exitCode == 0)
    #expect(status.standardOutput.contains("scan-only"))
    #expect(status.standardOutput.contains("scanning and policy classification"))
    #expect(status.standardOutput.contains("cannot delete, move, or modify"))
    #expect(status.standardError.isEmpty)

    let version = await application.run(arguments: ["--version"])
    #expect(version.standardOutput == DevSiftStatus.current.version + "\n")
    #expect(version.standardError.isEmpty)

    let help = await application.run(arguments: ["help"])
    #expect(help.standardOutput.contains("devsift scan"))
    #expect(help.standardOutput.contains("classify"))
    #expect(help.standardError.isEmpty)

    let scanHelp = await application.run(arguments: ["scan", "--help"])
    #expect(scanHelp.standardOutput.contains("--format <text|json>"))
    #expect(scanHelp.standardError.isEmpty)
    let classifyHelp = await application.run(arguments: ["classify", "--help"])
    #expect(classifyHelp.standardOutput.contains("devsift classify"))
    #expect(classifyHelp.standardOutput.contains("each retained top-level item"))
    #expect(classifyHelp.standardOutput.contains("not deletion"))
    #expect(classifyHelp.standardError.isEmpty)
    let requests = await recorder.requests()
    #expect(requests.isEmpty)
    let classificationRequests = await classificationRecorder.requests()
    #expect(classificationRequests.isEmpty)
  }

  @Test("Classify scans first and passes the exact report, root, and reference time")
  func classificationPipeline() async {
    let path = [Array("uv".utf8)]
    let item = CLITestReportFactory.item(
      rawComponents: path,
      allocatedBytes: 4_096
    )
    let scanReport = CLITestReportFactory.report(topLevelItems: [item])
    let scanRecorder = ScanRequestRecorder()
    let classificationRecorder = ClassificationRequestRecorder()
    let classificationReport = CLITestClassificationFactory.report(
      referenceUnixSeconds: 123,
      evaluations: [
        CLITestClassificationFactory.unrecognizedEvaluation(rawComponents: path)
      ]
    )
    let currentDirectory = URL(
      fileURLWithPath: "/private/tmp/devsift-cli-cwd",
      isDirectory: true
    )
    let application = CLIApplication(
      scanner: StubScanner(outcome: .report(scanReport), recorder: scanRecorder),
      classifier: StubClassifier(
        outcome: .report(classificationReport),
        recorder: classificationRecorder
      ),
      currentDirectory: currentDirectory,
      referenceUnixSeconds: { 123 }
    )

    let result = await application.run(
      arguments: ["classify", "--format", "text", "nested/../fixture"]
    )
    let scanRequests = await scanRecorder.requests()
    let classificationRequests = await classificationRecorder.requests()

    #expect(result.exitCode == CLIExitCode.success)
    #expect(result.standardOutput.contains("DevSift classification (read-only)"))
    #expect(result.standardError.isEmpty)
    #expect(scanRequests.count == 1)
    #expect(classificationRequests.count == 1)
    #expect(scanRequests.first?.root.path == "/private/tmp/devsift-cli-cwd/nested/../fixture")
    #expect(classificationRequests.first?.root == scanRequests.first?.root)
    #expect(classificationRequests.first?.report == scanReport)
    #expect(classificationRequests.first?.referenceUnixSeconds == 123)
  }

  @Test("Complete classifications support text and classification JSON v1")
  func completeClassification() async throws {
    let path = [Array("cache".utf8)]
    let scanReport = CLITestReportFactory.report(
      topLevelItems: [
        CLITestReportFactory.item(rawComponents: path, allocatedBytes: 2_048)
      ]
    )
    let classificationReport = CLITestClassificationFactory.report(
      evaluations: [
        CLITestClassificationFactory.unrecognizedEvaluation(rawComponents: path)
      ]
    )
    let application = CLIApplication(
      scanner: StubScanner(outcome: .report(scanReport)),
      classifier: StubClassifier(outcome: .report(classificationReport)),
      referenceUnixSeconds: { 1_700_000_000 }
    )

    let text = await application.run(arguments: ["classify", "."])
    #expect(text.exitCode == CLIExitCode.success)
    #expect(text.standardOutput.contains("Scan completeness: complete"))
    #expect(text.standardError.isEmpty)

    let json = await application.run(arguments: ["classify", "--json", "."])
    #expect(json.exitCode == CLIExitCode.success)
    #expect(json.standardError.isEmpty)
    let data = try #require(json.standardOutput.data(using: .utf8))
    let decoded = try JSONDecoder().decode(ClassificationJSONDocumentV1.self, from: data)
    #expect(decoded.schema == "devsift.classification")
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.scanIsComplete)
  }

  @Test("Malformed classifier reports fail closed before rendering")
  func malformedClassificationReports() async {
    let path = [Array("cache".utf8)]
    let extraPath = [Array("extra".utf8)]
    let item = CLITestReportFactory.item(rawComponents: path)
    let scanReport = CLITestReportFactory.report(topLevelItems: [item])
    let valid = CLITestClassificationFactory.unrecognizedEvaluation(rawComponents: path)
    let extra = CLITestClassificationFactory.evaluation(rawComponents: extraPath)
    let unsafe = CLITestClassificationFactory.evaluation(
      rawComponents: path,
      matchState: .possibleMatch,
      disposition: .reclaimable,
      findings: [
        CLITestClassificationFactory.finding(state: .unknown(.notCollected))
      ]
    )
    let malformedReports = [
      CLITestClassificationFactory.report(
        referenceUnixSeconds: 124,
        evaluations: [valid]
      ),
      CLITestClassificationFactory.report(
        referenceUnixSeconds: 123,
        evaluations: []
      ),
      CLITestClassificationFactory.report(
        referenceUnixSeconds: 123,
        evaluations: [valid, extra]
      ),
      CLITestClassificationFactory.report(
        referenceUnixSeconds: 123,
        evaluations: [valid, valid]
      ),
      CLITestClassificationFactory.report(
        referenceUnixSeconds: 123,
        evaluations: [unsafe]
      ),
    ]

    for malformedReport in malformedReports {
      let application = CLIApplication(
        scanner: StubScanner(outcome: .report(scanReport)),
        classifier: StubClassifier(outcome: .report(malformedReport)),
        referenceUnixSeconds: { 123 }
      )
      let result = await application.run(arguments: ["classify", "--json", "."])

      #expect(result.exitCode == CLIExitCode.internalError)
      #expect(result.standardOutput.isEmpty)
      #expect(result.standardError == "devsift: an unexpected internal error occurred.\n")
    }
  }

  @Test("A relative path preserves dot components against the injected directory")
  func relativePathPreservesDotComponents() async {
    let recorder = ScanRequestRecorder()
    let scanner = StubScanner(
      outcome: .report(CLITestReportFactory.report()),
      recorder: recorder
    )
    let currentDirectory = URL(
      fileURLWithPath: "/private/tmp/devsift-cli-cwd",
      isDirectory: true
    )
    let application = CLIApplication(
      scanner: scanner,
      currentDirectory: currentDirectory
    )

    let result = await application.run(arguments: ["scan", "nested/../fixture"])
    let requests = await recorder.requests()

    #expect(result.exitCode == 0)
    #expect(requests.count == 1)
    #expect(requests.first?.root.path == "/private/tmp/devsift-cli-cwd/nested/../fixture")
    #expect(requests.first?.limits == ScanLimits())
  }

  @Test("A complete report succeeds without diagnostics")
  func completeReport() async {
    let report = CLITestReportFactory.report(
      root: CLITestReportFactory.item(
        logicalBytes: 10,
        allocatedBytes: 4_096,
        sharedContentMetadataUnavailableCount: 1
      )
    )
    let application = CLIApplication(scanner: StubScanner(outcome: .report(report)))

    let text = await application.run(arguments: ["scan", "."])
    #expect(text.exitCode == CLIExitCode.success)
    #expect(text.standardOutput.contains("Scan completeness: complete"))
    #expect(text.standardError.isEmpty)

    let json = await application.run(arguments: ["scan", "--json", "."])
    #expect(json.exitCode == CLIExitCode.success)
    #expect(json.standardOutput.contains("\"schemaVersion\" : 2"))
    #expect(json.standardError.isEmpty)
  }

  @Test("Every report completeness flag produces a usable partial result")
  func partialReports() async throws {
    let partialReports = [
      CLITestReportFactory.report(root: CLITestReportFactory.item(isComplete: false)),
      CLITestReportFactory.report(topLevelItemsWereSuppressed: true),
      CLITestReportFactory.report(hardLinkAccountingIsComplete: false),
      CLITestReportFactory.report(traversalDetailsWereDiscarded: true),
      CLITestReportFactory.report(suppressedIssueCount: 1),
    ]

    for report in partialReports {
      #expect(report.isComplete == false)
      let application = CLIApplication(scanner: StubScanner(outcome: .report(report)))
      let result = await application.run(arguments: ["scan", "--json", "."])

      #expect(result.exitCode == CLIExitCode.partialResult)
      #expect(result.standardError.contains("partial results"))
      let data = try #require(result.standardOutput.data(using: .utf8))
      let decoded = try JSONDecoder().decode(ScanJSONDocumentV2.self, from: data)
      #expect(decoded.report.isComplete == false)
    }
  }

  @Test("Every partial scan flag makes classification exit with status 2")
  func partialClassificationReports() async throws {
    let partialReports = [
      CLITestReportFactory.report(root: CLITestReportFactory.item(isComplete: false)),
      CLITestReportFactory.report(topLevelItemsWereSuppressed: true),
      CLITestReportFactory.report(hardLinkAccountingIsComplete: false),
      CLITestReportFactory.report(traversalDetailsWereDiscarded: true),
      CLITestReportFactory.report(suppressedIssueCount: 1),
    ]

    for report in partialReports {
      #expect(report.isComplete == false)
      let application = CLIApplication(
        scanner: StubScanner(outcome: .report(report)),
        classifier: StubClassifier(
          outcome: .report(CLITestClassificationFactory.report(evaluations: []))
        ),
        referenceUnixSeconds: { 1_700_000_000 }
      )
      let result = await application.run(arguments: ["classify", "--json", "."])

      #expect(result.exitCode == CLIExitCode.partialResult)
      #expect(result.standardError.contains("partial scan results"))
      let data = try #require(result.standardOutput.data(using: .utf8))
      let decoded = try JSONDecoder().decode(ClassificationJSONDocumentV1.self, from: data)
      #expect(decoded.scanIsComplete == false)
    }
  }

  @Test("Fatal scanner errors map to stable sysexits-style codes")
  func scannerErrorMapping() async {
    let mappings: [(ScanError, Int32)] = [
      (.rootMustBeAbsoluteFileURL, CLIExitCode.invalidInput),
      (.rootNotFound, CLIExitCode.missingInput),
      (.rootIsSymbolicLink, CLIExitCode.invalidInput),
      (.rootIsNotDirectory, CLIExitCode.invalidInput),
      (.rootChangedDuringValidation, CLIExitCode.temporaryFailure),
      (
        .rootUnavailable(operation: .validateRoot, systemCode: EACCES),
        CLIExitCode.permissionDenied
      ),
      (
        .rootUnavailable(operation: .listDirectory, systemCode: EIO),
        CLIExitCode.inputOutputError
      ),
      (
        .rootUnavailable(operation: .readMetadata, systemCode: nil),
        CLIExitCode.inputOutputError
      ),
    ]

    for (error, expectedExitCode) in mappings {
      let application = CLIApplication(scanner: StubScanner(outcome: .scanError(error)))
      let result = await application.run(arguments: ["scan", "fixture"])

      #expect(result.exitCode == expectedExitCode)
      #expect(result.standardOutput.isEmpty)
      #expect(result.standardError.hasPrefix("devsift: cannot scan \"fixture\":"))
      #expect(result.standardError.hasSuffix(".\n"))
    }
  }

  @Test("Classify uses the same fatal scanner mappings and never calls the classifier")
  func classificationScannerErrorMapping() async {
    let mappings: [(ScanError, Int32)] = [
      (.rootMustBeAbsoluteFileURL, CLIExitCode.invalidInput),
      (.rootNotFound, CLIExitCode.missingInput),
      (.rootIsSymbolicLink, CLIExitCode.invalidInput),
      (.rootIsNotDirectory, CLIExitCode.invalidInput),
      (.rootChangedDuringValidation, CLIExitCode.temporaryFailure),
      (
        .rootUnavailable(operation: .validateRoot, systemCode: EACCES),
        CLIExitCode.permissionDenied
      ),
      (
        .rootUnavailable(operation: .listDirectory, systemCode: EIO),
        CLIExitCode.inputOutputError
      ),
    ]

    for (error, expectedExitCode) in mappings {
      let recorder = ClassificationRequestRecorder()
      let application = CLIApplication(
        scanner: StubScanner(outcome: .scanError(error)),
        classifier: StubClassifier(
          outcome: .report(CLITestClassificationFactory.report()),
          recorder: recorder
        )
      )
      let result = await application.run(arguments: ["classify", "fixture"])

      #expect(result.exitCode == expectedExitCode)
      #expect(result.standardOutput.isEmpty)
      #expect(result.standardError.hasPrefix("devsift: cannot scan \"fixture\":"))
      let requests = await recorder.requests()
      #expect(requests.isEmpty)
    }
  }

  @Test("Classification cancellation and unexpected errors use stable exits")
  func classifierErrorMapping() async {
    let scanReport = CLITestReportFactory.report()
    let scanCancelledRecorder = ClassificationRequestRecorder()
    let scanCancelled = CLIApplication(
      scanner: StubScanner(outcome: .cancelled),
      classifier: StubClassifier(
        outcome: .report(CLITestClassificationFactory.report()),
        recorder: scanCancelledRecorder
      )
    )
    let scanCancelledResult = await scanCancelled.run(arguments: ["classify", "."])
    #expect(scanCancelledResult.exitCode == CLIExitCode.cancelled)
    #expect(scanCancelledResult.standardOutput.isEmpty)
    #expect(scanCancelledResult.standardError == "devsift: scan cancelled.\n")
    let scanCancelledRequests = await scanCancelledRecorder.requests()
    #expect(scanCancelledRequests.isEmpty)

    let cancelled = CLIApplication(
      scanner: StubScanner(outcome: .report(scanReport)),
      classifier: StubClassifier(outcome: .cancelled)
    )
    let cancelledResult = await cancelled.run(arguments: ["classify", "."])
    #expect(cancelledResult.exitCode == CLIExitCode.cancelled)
    #expect(cancelledResult.standardOutput.isEmpty)
    #expect(cancelledResult.standardError == "devsift: classification cancelled.\n")

    let unexpected = CLIApplication(
      scanner: StubScanner(outcome: .report(scanReport)),
      classifier: StubClassifier(outcome: .unexpectedError)
    )
    let unexpectedResult = await unexpected.run(arguments: ["classify", "."])
    #expect(unexpectedResult.exitCode == CLIExitCode.internalError)
    #expect(unexpectedResult.standardOutput.isEmpty)
    #expect(unexpectedResult.standardError.contains("unexpected internal error"))

    let scannerUnexpected = CLIApplication(
      scanner: StubScanner(outcome: .unexpectedError),
      classifier: StubClassifier(outcome: .report(CLITestClassificationFactory.report()))
    )
    let scannerUnexpectedResult = await scannerUnexpected.run(arguments: ["classify", "."])
    #expect(scannerUnexpectedResult.exitCode == CLIExitCode.internalError)
    #expect(scannerUnexpectedResult.standardOutput.isEmpty)
    #expect(scannerUnexpectedResult.standardError.contains("unexpected internal error"))
  }

  @Test("Classify usage errors point to classify help")
  func classificationUsageErrors() async {
    let application = CLIApplication()
    let errors: [[String]] = [
      ["classify"],
      ["classify", "one", "two"],
      ["classify", "--format"],
      ["classify", "--format", "yaml", "one"],
      ["classify", "one", "--help"],
    ]

    for arguments in errors {
      let result = await application.run(arguments: arguments)
      #expect(result.exitCode == CLIExitCode.usage)
      #expect(result.standardOutput.isEmpty)
      #expect(result.standardError.contains(CLIHelp.classifyUsage))
    }
  }

  @Test("Cancellation and unexpected errors never emit partial output")
  func cancellationAndUnexpectedErrors() async {
    let cancelled = await CLIApplication(
      scanner: StubScanner(outcome: .cancelled)
    ).run(arguments: ["scan", "."])
    #expect(cancelled.exitCode == CLIExitCode.cancelled)
    #expect(cancelled.standardOutput.isEmpty)
    #expect(cancelled.standardError == "devsift: scan cancelled.\n")

    let unexpected = await CLIApplication(
      scanner: StubScanner(outcome: .unexpectedError)
    ).run(arguments: ["scan", "."])
    #expect(unexpected.exitCode == CLIExitCode.internalError)
    #expect(unexpected.standardOutput.isEmpty)
    #expect(unexpected.standardError == "devsift: an unexpected internal error occurred.\n")
  }

  @Test("Usage errors are terminal-safe and never invoke the scanner")
  func terminalSafeUsageError() async {
    let recorder = ScanRequestRecorder()
    let scanner = StubScanner(
      outcome: .report(CLITestReportFactory.report()),
      recorder: recorder
    )
    let application = CLIApplication(scanner: scanner)
    let hostileCommand = "bad\u{001B}[31m\ncommand\\name"

    let result = await application.run(arguments: [hostileCommand])
    let requests = await recorder.requests()

    #expect(result.exitCode == CLIExitCode.usage)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains("bad\\u{001B}[31m\\ncommand\\\\name"))
    #expect(result.standardError.unicodeScalars.contains("\u{001B}") == false)
    #expect(requests.isEmpty)
  }
}
