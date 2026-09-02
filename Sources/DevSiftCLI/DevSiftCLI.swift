import Darwin
import DevSiftCore
import Foundation

@main
struct DevSiftCLI {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let exitCode = run(arguments: arguments)

    if exitCode != 0 {
      Darwin.exit(exitCode)
    }
  }

  private static func run(arguments: [String]) -> Int32 {
    switch arguments.first {
    case nil, "status":
      print(DevSiftStatus.current.summary)
      print("No files are scanned or changed in this foundation build.")
      return 0

    case "version", "--version", "-v":
      print(DevSiftStatus.current.version)
      return 0

    case "help", "--help", "-h":
      printHelp()
      return 0

    default:
      writeError("Unknown command: \(arguments[0])\n")
      printHelp(toStandardError: true)
      return 64
    }
  }

  private static func printHelp(toStandardError: Bool = false) {
    let help = """
      OVERVIEW: Explainable, local-first storage analysis for macOS.

      USAGE: devsift <command>

      COMMANDS:
        status      Show the current safety mode (default)
        version     Show the development version
        help        Show this help

      The scan command will be introduced in the read-only scanner milestone.
      This build cannot delete, move, or modify files.
      """

    if toStandardError {
      writeError(help + "\n")
    } else {
      print(help)
    }
  }

  private static func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
  }
}
