import Darwin
import Foundation

@main
struct DevSiftCLI {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let result = await CLIApplication().run(arguments: arguments)

    if !result.standardOutput.isEmpty {
      FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
    }
    if !result.standardError.isEmpty {
      FileHandle.standardError.write(Data(result.standardError.utf8))
    }
    if result.exitCode != 0 {
      Darwin.exit(result.exitCode)
    }
  }
}
