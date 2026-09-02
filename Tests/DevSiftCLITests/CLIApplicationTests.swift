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
    let scanner = StubScanner(
      outcome: .report(CLITestReportFactory.report()),
      recorder: recorder
    )
    let application = CLIApplication(scanner: scanner)

    let status = await application.run(arguments: [])
    #expect(status.exitCode == 0)
    #expect(status.standardOutput.contains("scan-only"))
    #expect(status.standardOutput.contains("cannot delete, move, or modify"))
    #expect(status.standardError.isEmpty)

    let version = await application.run(arguments: ["--version"])
    #expect(version.standardOutput == DevSiftStatus.current.version + "\n")
    #expect(version.standardError.isEmpty)

    let help = await application.run(arguments: ["help"])
    #expect(help.standardOutput.contains("devsift scan"))
    #expect(help.standardError.isEmpty)

    let scanHelp = await application.run(arguments: ["scan", "--help"])
    #expect(scanHelp.standardOutput.contains("--format <text|json>"))
    #expect(scanHelp.standardError.isEmpty)
    let requests = await recorder.requests()
    #expect(requests.isEmpty)
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
    #expect(json.standardOutput.contains("\"schemaVersion\" : 1"))
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
      let decoded = try JSONDecoder().decode(ScanJSONDocumentV1.self, from: data)
      #expect(decoded.report.isComplete == false)
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
