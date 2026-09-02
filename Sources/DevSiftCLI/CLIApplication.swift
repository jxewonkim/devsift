import Darwin
import DevSiftCore
import Foundation

struct CLIResult: Equatable, Sendable {
  let exitCode: Int32
  let standardOutput: String
  let standardError: String
}

enum CLIExitCode {
  static let success: Int32 = 0
  static let partialResult: Int32 = 2
  static let usage: Int32 = 64
  static let invalidInput: Int32 = 65
  static let missingInput: Int32 = 66
  static let internalError: Int32 = 70
  static let inputOutputError: Int32 = 74
  static let temporaryFailure: Int32 = 75
  static let permissionDenied: Int32 = 77
  static let cancelled: Int32 = 130
}

struct CLIApplication {
  private let scanner: any FileSystemScanning
  private let currentDirectory: URL
  private let scanLimits: ScanLimits

  init(
    scanner: any FileSystemScanning = AllocatedSizeScanner(),
    currentDirectory: URL = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ),
    scanLimits: ScanLimits = ScanLimits()
  ) {
    self.scanner = scanner
    self.currentDirectory = currentDirectory
    self.scanLimits = scanLimits
  }

  func run(arguments: [String]) async -> CLIResult {
    let command: CLICommand
    do {
      command = try CLIArguments.parse(arguments)
    } catch let error as CLIArgumentError {
      return usageError(error)
    } catch {
      return internalError()
    }

    switch command {
    case .status:
      return CLIResult(
        exitCode: CLIExitCode.success,
        standardOutput: """
          \(DevSiftStatus.current.summary)
          Read-only scanning is available. This build cannot delete, move, or modify files.
          """ + "\n",
        standardError: ""
      )

    case .version:
      return CLIResult(
        exitCode: CLIExitCode.success,
        standardOutput: DevSiftStatus.current.version + "\n",
        standardError: ""
      )

    case .help:
      return CLIResult(
        exitCode: CLIExitCode.success,
        standardOutput: CLIHelp.main + "\n",
        standardError: ""
      )

    case .scanHelp:
      return CLIResult(
        exitCode: CLIExitCode.success,
        standardOutput: CLIHelp.scan + "\n",
        standardError: ""
      )

    case .scan(let path, let format):
      return await scan(path: path, format: format)
    }
  }

  private func scan(path: String, format: CLIOutputFormat) async -> CLIResult {
    let root = resolvedRoot(for: path)
    let request = ScanRequest(root: root, limits: scanLimits)

    do {
      let report = try await scanner.scan(request)
      try Task.checkCancellation()

      let output: String
      switch format {
      case .text:
        output = ScanTextRenderer.render(report: report)
      case .json:
        output = try ScanJSONRenderer.render(report: report, limits: scanLimits)
      }
      try Task.checkCancellation()

      if report.isComplete {
        return CLIResult(
          exitCode: CLIExitCode.success,
          standardOutput: output,
          standardError: ""
        )
      }

      return CLIResult(
        exitCode: CLIExitCode.partialResult,
        standardOutput: output,
        standardError:
          "devsift: scan completed with partial results; inspect the report for details.\n"
      )
    } catch {
      if error is CancellationError || Task.isCancelled {
        return CLIResult(
          exitCode: CLIExitCode.cancelled,
          standardOutput: "",
          standardError: "devsift: scan cancelled.\n"
        )
      }
      if let scanError = error as? ScanError {
        return scanErrorResult(scanError, path: path)
      }
      return internalError()
    }
  }

  private func resolvedRoot(for path: String) -> URL {
    if path.hasPrefix("/") {
      return URL(fileURLWithPath: path, isDirectory: true)
    }

    let basePath = currentDirectory.path
    let separator = basePath.hasSuffix("/") ? "" : "/"
    return URL(
      fileURLWithPath: basePath + separator + path,
      isDirectory: true
    )
  }

  private func usageError(_ error: CLIArgumentError) -> CLIResult {
    let message: String
    switch error {
    case .unknownCommand(let command):
      message = "unknown command \(TerminalText.quoted(command))"
    case .unexpectedArguments(let command):
      message = "\(TerminalText.quoted(command)) does not accept arguments"
    case .missingScanPath:
      message = "scan requires exactly one path"
    case .emptyScanPath:
      message = "scan path must not be empty"
    case .multipleScanPaths:
      message = "scan accepts exactly one path"
    case .unknownScanOption(let option):
      message = "unknown scan option \(TerminalText.quoted(option))"
    case .missingFormatValue:
      message = "--format requires text or json"
    case .invalidFormat(let value):
      message = "invalid output format \(TerminalText.quoted(value)); expected text or json"
    case .duplicateFormatOption:
      message = "output format may be specified only once"
    case .scanHelpCannotBeCombined:
      message = "scan help cannot be combined with a path or other options"
    }

    let usage = error.isScanError ? CLIHelp.scanUsage : CLIHelp.mainUsage
    return CLIResult(
      exitCode: CLIExitCode.usage,
      standardOutput: "",
      standardError: "devsift: \(message)\n\(usage)\n"
    )
  }

  private func scanErrorResult(_ error: ScanError, path: String) -> CLIResult {
    let detail: String
    let exitCode: Int32

    switch error {
    case .rootMustBeAbsoluteFileURL:
      detail = "the path is not a valid local filesystem path"
      exitCode = CLIExitCode.invalidInput
    case .rootNotFound:
      detail = "the directory does not exist"
      exitCode = CLIExitCode.missingInput
    case .rootIsSymbolicLink:
      detail = "the selected root is a symbolic link"
      exitCode = CLIExitCode.invalidInput
    case .rootIsNotDirectory:
      detail = "the selected root is not a directory"
      exitCode = CLIExitCode.invalidInput
    case .rootChangedDuringValidation:
      detail = "the directory changed while it was being validated; retry the scan"
      exitCode = CLIExitCode.temporaryFailure
    case .rootUnavailable(let operation, let systemCode):
      detail = rootUnavailableDetail(operation: operation, systemCode: systemCode)
      if systemCode == EACCES || systemCode == EPERM {
        exitCode = CLIExitCode.permissionDenied
      } else {
        exitCode = CLIExitCode.inputOutputError
      }
    }

    return CLIResult(
      exitCode: exitCode,
      standardOutput: "",
      standardError: "devsift: cannot scan \(TerminalText.quoted(path)): \(detail).\n"
    )
  }

  private func rootUnavailableDetail(
    operation: ScanOperation,
    systemCode: Int32?
  ) -> String {
    guard let systemCode else {
      return "the directory is unavailable during \(operation.rawValue)"
    }
    return
      "the directory is unavailable during \(operation.rawValue) (errno \(systemCode))"
  }

  private func internalError() -> CLIResult {
    CLIResult(
      exitCode: CLIExitCode.internalError,
      standardOutput: "",
      standardError: "devsift: an unexpected internal error occurred.\n"
    )
  }
}

enum CLIHelp {
  static let mainUsage = "Usage: devsift <command>"
  static let scanUsage = "Usage: devsift scan [--format text|json] [--json] [--] <path>"

  static let main = """
    OVERVIEW: Explainable, local-first storage analysis for macOS.

    USAGE: devsift <command>

    COMMANDS:
      scan        Analyze one explicit directory without changing it
      status      Show the current safety mode (default)
      version     Show the development version
      help        Show this help

    Run 'devsift scan --help' for scan options.
    This build cannot delete, move, or modify files.
    """

  static let scan = """
    OVERVIEW: Analyze one explicit directory without changing it.

    USAGE: devsift scan [--format text|json] [--json] [--] <path>

    OPTIONS:
      --format <text|json>  Select the output format (default: text)
      --json                Alias for --format json
      --                     Treat the remaining argument as the path
      -h, --help             Show this help

    Paths may be absolute or relative to the current directory. Symbolic-link
    ancestors are allowed. The selected final root cannot be a symbolic link,
    and descendant symbolic links are never traversed. Output paths are
    root-relative. A partial report exits with status 2.

    This command reads filesystem metadata only. It never reads file contents
    and cannot delete, move, or modify files.
    """
}
