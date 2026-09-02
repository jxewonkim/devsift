enum CLIOutputFormat: String, Equatable, Sendable {
  case text
  case json
}

enum CLICommand: Equatable, Sendable {
  case status
  case version
  case help
  case scanHelp
  case classifyHelp
  case scan(path: String, format: CLIOutputFormat)
  case classify(path: String, format: CLIOutputFormat)
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
  case missingClassifyPath
  case emptyClassifyPath
  case multipleClassifyPaths
  case unknownClassifyOption(String)
  case missingClassifyFormatValue
  case invalidClassifyFormat(String)
  case duplicateClassifyFormatOption
  case classifyHelpCannotBeCombined

  var isScanError: Bool {
    switch self {
    case .unknownCommand, .unexpectedArguments, .missingClassifyPath,
      .emptyClassifyPath, .multipleClassifyPaths, .unknownClassifyOption,
      .missingClassifyFormatValue, .invalidClassifyFormat,
      .duplicateClassifyFormatOption, .classifyHelpCannotBeCombined:
      false
    case .missingScanPath, .emptyScanPath, .multipleScanPaths,
      .unknownScanOption, .missingFormatValue, .invalidFormat,
      .duplicateFormatOption, .scanHelpCannotBeCombined:
      true
    }
  }

  var isClassifyError: Bool {
    switch self {
    case .missingClassifyPath, .emptyClassifyPath, .multipleClassifyPaths,
      .unknownClassifyOption, .missingClassifyFormatValue, .invalidClassifyFormat,
      .duplicateClassifyFormatOption, .classifyHelpCannotBeCombined:
      true
    case .unknownCommand, .unexpectedArguments, .missingScanPath, .emptyScanPath,
      .multipleScanPaths, .unknownScanOption, .missingFormatValue, .invalidFormat,
      .duplicateFormatOption, .scanHelpCannotBeCombined:
      false
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

    case "classify":
      return try parseClassify(trailingArguments)

    default:
      throw CLIArgumentError.unknownCommand(command)
    }
  }

  private static func parseScan(_ arguments: [String]) throws -> CLICommand {
    try parsePathCommand(arguments, command: .scan)
  }

  private static func parseClassify(_ arguments: [String]) throws -> CLICommand {
    try parsePathCommand(arguments, command: .classify)
  }

  private static func parsePathCommand(
    _ arguments: [String],
    command: PathCommand
  ) throws -> CLICommand {
    if arguments == ["--help"] || arguments == ["-h"] {
      return command.helpCommand
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
        throw command.helpCombinationError
      }

      if !optionsEnded, argument == "--json" {
        try setFormat(
          .json,
          wasSet: &formatWasSet,
          format: &format,
          duplicateError: command.duplicateFormatError
        )
        index += 1
        continue
      }

      if !optionsEnded, argument == "--format" {
        guard index + 1 < arguments.count else {
          throw command.missingFormatValueError
        }
        try setFormat(
          parseFormat(arguments[index + 1], command: command),
          wasSet: &formatWasSet,
          format: &format,
          duplicateError: command.duplicateFormatError
        )
        index += 2
        continue
      }

      if !optionsEnded, argument.hasPrefix("--format=") {
        let value = String(argument.dropFirst("--format=".count))
        try setFormat(
          parseFormat(value, command: command),
          wasSet: &formatWasSet,
          format: &format,
          duplicateError: command.duplicateFormatError
        )
        index += 1
        continue
      }

      if !optionsEnded, argument.hasPrefix("-") {
        throw command.unknownOptionError(argument)
      }

      guard !argument.isEmpty else {
        throw command.emptyPathError
      }
      guard path == nil else {
        throw command.multiplePathsError
      }
      path = argument
      index += 1
    }

    guard let path else {
      throw command.missingPathError
    }
    return command.makeCommand(path: path, format: format)
  }

  private static func parseFormat(
    _ value: String,
    command: PathCommand
  ) throws -> CLIOutputFormat {
    guard let format = CLIOutputFormat(rawValue: value) else {
      throw command.invalidFormatError(value)
    }
    return format
  }

  private static func setFormat(
    _ newFormat: CLIOutputFormat,
    wasSet: inout Bool,
    format: inout CLIOutputFormat,
    duplicateError: CLIArgumentError
  ) throws {
    guard !wasSet else {
      throw duplicateError
    }
    wasSet = true
    format = newFormat
  }

  private enum PathCommand {
    case scan
    case classify

    var helpCommand: CLICommand {
      switch self {
      case .scan: .scanHelp
      case .classify: .classifyHelp
      }
    }

    var missingPathError: CLIArgumentError {
      switch self {
      case .scan: .missingScanPath
      case .classify: .missingClassifyPath
      }
    }

    var emptyPathError: CLIArgumentError {
      switch self {
      case .scan: .emptyScanPath
      case .classify: .emptyClassifyPath
      }
    }

    var multiplePathsError: CLIArgumentError {
      switch self {
      case .scan: .multipleScanPaths
      case .classify: .multipleClassifyPaths
      }
    }

    var helpCombinationError: CLIArgumentError {
      switch self {
      case .scan: .scanHelpCannotBeCombined
      case .classify: .classifyHelpCannotBeCombined
      }
    }

    var missingFormatValueError: CLIArgumentError {
      switch self {
      case .scan: .missingFormatValue
      case .classify: .missingClassifyFormatValue
      }
    }

    var duplicateFormatError: CLIArgumentError {
      switch self {
      case .scan: .duplicateFormatOption
      case .classify: .duplicateClassifyFormatOption
      }
    }

    func invalidFormatError(_ value: String) -> CLIArgumentError {
      switch self {
      case .scan: .invalidFormat(value)
      case .classify: .invalidClassifyFormat(value)
      }
    }

    func unknownOptionError(_ option: String) -> CLIArgumentError {
      switch self {
      case .scan: .unknownScanOption(option)
      case .classify: .unknownClassifyOption(option)
      }
    }

    func makeCommand(path: String, format: CLIOutputFormat) -> CLICommand {
      switch self {
      case .scan: .scan(path: path, format: format)
      case .classify: .classify(path: path, format: format)
      }
    }
  }
}
