import Testing

@testable import DevSiftCLI

@Suite("CLI argument parsing")
struct CLIArgumentsTests {
  @Test("Status is the default and explicit command")
  func statusCommands() throws {
    #expect(try CLIArguments.parse([]) == .status)
    #expect(try CLIArguments.parse(["status"]) == .status)
  }

  @Test("Help and version aliases are accepted")
  func topLevelAliases() throws {
    #expect(try CLIArguments.parse(["help"]) == .help)
    #expect(try CLIArguments.parse(["--help"]) == .help)
    #expect(try CLIArguments.parse(["-h"]) == .help)
    #expect(try CLIArguments.parse(["version"]) == .version)
    #expect(try CLIArguments.parse(["--version"]) == .version)
    #expect(try CLIArguments.parse(["-v"]) == .version)
  }

  @Test("Scan accepts text and JSON formats in either option position")
  func scanFormats() throws {
    #expect(try CLIArguments.parse(["scan", "fixture"]) == .scan(path: "fixture", format: .text))
    #expect(
      try CLIArguments.parse(["scan", "--format", "json", "fixture"])
        == .scan(path: "fixture", format: .json)
    )
    #expect(
      try CLIArguments.parse(["scan", "fixture", "--format=text"])
        == .scan(path: "fixture", format: .text)
    )
    #expect(
      try CLIArguments.parse(["scan", "fixture", "--json"])
        == .scan(path: "fixture", format: .json)
    )
  }

  @Test("Double dash preserves dash-prefixed and help-like paths")
  func optionsTerminator() throws {
    #expect(
      try CLIArguments.parse(["scan", "--", "-cache"])
        == .scan(path: "-cache", format: .text)
    )
    #expect(
      try CLIArguments.parse(["scan", "--", "--help"])
        == .scan(path: "--help", format: .text)
    )
  }

  @Test("Scan help is scoped and cannot hide invalid combinations")
  func scanHelp() throws {
    #expect(try CLIArguments.parse(["scan", "--help"]) == .scanHelp)
    #expect(try CLIArguments.parse(["scan", "-h"]) == .scanHelp)
    #expect(
      parseError(["scan", "folder", "--help"])
        == .scanHelpCannotBeCombined
    )
  }

  @Test("Missing, empty, multiple, unknown and duplicate arguments fail")
  func invalidArguments() {
    #expect(parseError(["scan"]) == .missingScanPath)
    #expect(parseError(["scan", ""]) == .emptyScanPath)
    #expect(parseError(["scan", "one", "two"]) == .multipleScanPaths)
    #expect(parseError(["scan", "--wat", "one"]) == .unknownScanOption("--wat"))
    #expect(parseError(["scan", "--format"]) == .missingFormatValue)
    #expect(parseError(["scan", "--format", "yaml", "one"]) == .invalidFormat("yaml"))
    #expect(
      parseError(["scan", "--json", "--format", "json", "one"])
        == .duplicateFormatOption
    )
    for command in ["clean", "delete", "remove", "purge", "quarantine"] {
      #expect(parseError([command, "one"]) == .unknownCommand(command))
    }
    #expect(parseError(["status", "extra"]) == .unexpectedArguments(command: "status"))
  }

  private func parseError(_ arguments: [String]) -> CLIArgumentError? {
    do {
      _ = try CLIArguments.parse(arguments)
      return nil
    } catch let error as CLIArgumentError {
      return error
    } catch {
      return nil
    }
  }
}
