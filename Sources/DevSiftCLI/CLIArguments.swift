enum CLIOutputFormat: String, Equatable, Sendable {
  case text
  case json
}

enum CLICommand: Equatable, Sendable {
  case status
  case version
  case help
  case scanHelp
  case scan(path: String, format: CLIOutputFormat)
}

enum CLIArgumentError: Error, Equatable, Sendable {
  case unknownCommand(String)
  case unexpectedArguments(command: String)
  case missingScanPath
  case emptyScanPath
  case multipleScanPaths
  case unknownScanOption(String)
  case missingFormatValue
  case invalidFormat(String)
  case duplicateFormatOption
  case scanHelpCannotBeCombined

  var isScanError: Bool {
    switch self {
    case .unknownCommand, .unexpectedArguments:
      false
    case .missingScanPath, .emptyScanPath, .multipleScanPaths,
      .unknownScanOption, .missingFormatValue, .invalidFormat,
      .duplicateFormatOption, .scanHelpCannotBeCombined:
      true
    }
  }
}

enum CLIArguments {
  static func parse(_ arguments: [String]) throws -> CLICommand {
    guard let command = arguments.first else {
      return .status
    }

    let trailingArguments = Array(arguments.dropFirst())
    switch command {
    case "status":
      guard trailingArguments.isEmpty else {
        throw CLIArgumentError.unexpectedArguments(command: command)
      }
      return .status

    case "version", "--version", "-v":
      guard trailingArguments.isEmpty else {
        throw CLIArgumentError.unexpectedArguments(command: command)
      }
      return .version

    case "help", "--help", "-h":
      guard trailingArguments.isEmpty else {
        throw CLIArgumentError.unexpectedArguments(command: command)
      }
      return .help

    case "scan":
      return try parseScan(trailingArguments)

    default:
      throw CLIArgumentError.unknownCommand(command)
    }
  }

  private static func parseScan(_ arguments: [String]) throws -> CLICommand {
    if arguments == ["--help"] || arguments == ["-h"] {
      return .scanHelp
    }

    var format = CLIOutputFormat.text
    var formatWasSet = false
    var path: String?
    var optionsEnded = false
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]

      if !optionsEnded, argument == "--" {
        optionsEnded = true
        index += 1
        continue
      }

      if !optionsEnded, argument == "--help" || argument == "-h" {
        throw CLIArgumentError.scanHelpCannotBeCombined
      }

      if !optionsEnded, argument == "--json" {
        try setFormat(.json, wasSet: &formatWasSet, format: &format)
        index += 1
        continue
      }

      if !optionsEnded, argument == "--format" {
        guard index + 1 < arguments.count else {
          throw CLIArgumentError.missingFormatValue
        }
        try setFormat(
          parseFormat(arguments[index + 1]),
          wasSet: &formatWasSet,
          format: &format
        )
        index += 2
        continue
      }

      if !optionsEnded, argument.hasPrefix("--format=") {
        let value = String(argument.dropFirst("--format=".count))
        try setFormat(parseFormat(value), wasSet: &formatWasSet, format: &format)
        index += 1
        continue
      }

      if !optionsEnded, argument.hasPrefix("-") {
        throw CLIArgumentError.unknownScanOption(argument)
      }

      guard !argument.isEmpty else {
        throw CLIArgumentError.emptyScanPath
      }
      guard path == nil else {
        throw CLIArgumentError.multipleScanPaths
      }
      path = argument
      index += 1
    }

    guard let path else {
      throw CLIArgumentError.missingScanPath
    }
    return .scan(path: path, format: format)
  }

  private static func parseFormat(_ value: String) throws -> CLIOutputFormat {
    guard let format = CLIOutputFormat(rawValue: value) else {
      throw CLIArgumentError.invalidFormat(value)
    }
    return format
  }

  private static func setFormat(
    _ newFormat: CLIOutputFormat,
    wasSet: inout Bool,
    format: inout CLIOutputFormat
  ) throws {
    guard !wasSet else {
      throw CLIArgumentError.duplicateFormatOption
    }
    wasSet = true
    format = newFormat
  }
}
