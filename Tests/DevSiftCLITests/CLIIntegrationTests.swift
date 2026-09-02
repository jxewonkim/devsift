import Foundation
import Testing

@testable import DevSiftCLI

@Suite("devsift executable integration")
struct CLIIntegrationTests {
  @Test("The executable classifies a synthetic fixture without mutation or root disclosure")
  func syntheticJSONClassification() async throws {
    let fixture = try TemporaryCLIFixture()
    defer { fixture.remove() }

    let uv = fixture.root.appendingPathComponent("uv", isDirectory: true)
    let build = fixture.root.appendingPathComponent(".build", isDirectory: true)
    try FileManager.default.createDirectory(at: uv, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
    try Data("// package".utf8).write(
      to: fixture.root.appendingPathComponent("Package.swift")
    )
    try Data([0xA1]).write(to: fixture.root.appendingPathComponent("mystery.bin"))
    try Data([0xB2]).write(to: fixture.root.appendingPathComponent("line\ncache"))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 100)],
      ofItemAtPath: uv.path
    )
    let uvAttributesBeforeClassification = try FileManager.default.attributesOfItem(
      atPath: uv.path
    )
    let uvModificationDateBeforeClassification = try #require(
      uvAttributesBeforeClassification[.modificationDate] as? Date
    )
    let beforeClassification = try fixture.snapshot()

    let result = try await runDevSift(
      ["classify", "--json", fixture.root.path],
      currentDirectory: fixture.parent
    )

    #expect(result.exitCode == 0)
    #expect(result.terminationReason == .exit)
    #expect(result.standardError.isEmpty)
    #expect(result.standardOutput.contains(fixture.root.path) == false)

    let data = try #require(result.standardOutput.data(using: .utf8))
    let document = try JSONDecoder().decode(ClassificationJSONDocumentV1.self, from: data)
    #expect(document.schema == "devsift.classification")
    #expect(document.schemaVersion == 1)
    #expect(document.pathStyle == "root-relative")
    #expect(document.scanIsComplete)
    #expect(document.summary.decisionCount == "5")
    #expect(document.decisions.count == 5)
    #expect(document.decisions.allSatisfy { $0.disposition == "protected" })
    let uvDecision = try #require(
      document.decisions.first(where: { $0.path.display == "uv" })
    )
    let uvAgeFinding = try #require(
      uvDecision.findings.first(where: { $0.identifier == "age-requirement" })
    )
    #expect(uvAgeFinding.kind == "age")
    #expect(uvAgeFinding.state.status == "satisfied")
    #expect(uvAgeFinding.state.reason == nil)
    #expect(uvDecision.matchState == "possible-match")
    #expect(uvDecision.disposition == "protected")
    #expect(
      uvDecision.findings.contains {
        $0.identifier == "activity-requirement"
          && $0.state.status == "unknown"
          && $0.state.reason == "not-collected"
      }
    )
    #expect(
      document.decisions.first(where: { $0.path.display == ".build" })?.ruleRevision?.identifier
        == "devsift.swiftpm.build"
    )
    #expect(
      document.decisions.first(where: { $0.path.display == "mystery.bin" })?.matchState
        == "unrecognized"
    )
    let newlineDecision = try #require(
      document.decisions.first(where: { $0.path.display == "line\ncache" })
    )
    #expect(
      newlineDecision.path.rawComponentsBase64
        == [Data("line\ncache".utf8).base64EncodedString()]
    )
    #expect(newlineDecision.observation != nil)
    #expect(newlineDecision.observation?.apparentAllocatedBytes.isEmpty == false)

    #expect(try fixture.snapshot() == beforeClassification)
    let uvAttributesAfterClassification = try FileManager.default.attributesOfItem(
      atPath: uv.path
    )
    #expect(
      uvAttributesAfterClassification[.modificationDate] as? Date
        == uvModificationDateBeforeClassification
    )
  }

  @Test("Classification text escapes terminal-control path content")
  func terminalSafeClassificationText() async throws {
    let fixture = try TemporaryCLIFixture()
    defer { fixture.remove() }

    try Data([0x01]).write(to: fixture.root.appendingPathComponent("line\ncache"))
    let result = try await runDevSift(
      ["classify", fixture.root.path],
      currentDirectory: fixture.parent
    )

    #expect(result.exitCode == 0)
    #expect(result.terminationReason == .exit)
    #expect(result.standardError.isEmpty)
    #expect(result.standardOutput.contains("Path: \"line\\ncache\""))
    #expect(result.standardOutput.contains("line\ncache") == false)
    #expect(result.standardOutput.contains(fixture.root.path) == false)
  }

  @Test("The executable scans a synthetic fixture deterministically without mutation")
  func syntheticJSONScan() async throws {
    let fixture = try TemporaryCLIFixture()
    defer { fixture.remove() }

    let nested = fixture.root.appendingPathComponent("folder name", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    let payload = Data(repeating: 0x41, count: 4_097)
    let payloadURL = nested.appendingPathComponent("한글 data.bin")
    try payload.write(to: payloadURL)
    try Data([0x42]).write(to: fixture.root.appendingPathComponent(".hidden"))
    try Data([0x43]).write(
      to: fixture.root.appendingPathComponent("$(touch SHOULD_NOT_EXIST)")
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent("outside-link"),
      withDestinationURL: fixture.outsideSentinel
    )
    let beforeScan = try fixture.snapshot()

    let first = try await runDevSift(
      ["scan", "--json", fixture.root.path],
      currentDirectory: fixture.parent
    )
    let second = try await runDevSift(
      ["scan", "--format", "json", fixture.root.path],
      currentDirectory: fixture.parent
    )

    #expect(first.exitCode == 0)
    #expect(first.terminationReason == .exit)
    #expect(second.terminationReason == .exit)
    #expect(first.standardError.isEmpty)
    #expect(first.standardOutput == second.standardOutput)
    #expect(first.standardOutput.contains(fixture.root.path) == false)

    let data = try #require(first.standardOutput.data(using: .utf8))
    let document = try JSONDecoder().decode(ScanJSONDocumentV2.self, from: data)
    #expect(document.schemaVersion == 2)
    #expect(document.pathStyle == "root-relative")
    #expect(document.report.isComplete)
    #expect(document.report.root.counts.regularFiles == "3")
    #expect(document.report.root.counts.symbolicLinks == "1")
    #expect(document.report.topLevelItemCount == "4")
    #expect(document.report.topLevelItems.map(\.path.display).contains("folder name"))
    #expect(document.report.topLevelItems.map(\.path.display).contains("outside-link"))

    #expect(try Data(contentsOf: payloadURL) == payload)
    #expect(try Data(contentsOf: fixture.outsideSentinel) == fixture.outsideData)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.root.appendingPathComponent("outside-link").path
      ) == fixture.outsideSentinel.path
    )
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.parent.appendingPathComponent("SHOULD_NOT_EXIST").path
      ) == false
    )
    #expect(try fixture.snapshot() == beforeScan)
  }

  @Test("Double dash allows a dash-prefixed relative root")
  func dashPrefixedRoot() async throws {
    let fixture = try TemporaryCLIFixture()
    defer { fixture.remove() }

    let dashRoot = fixture.parent.appendingPathComponent("-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: dashRoot, withIntermediateDirectories: false)

    let result = try await runDevSift(
      ["scan", "--", "-cache"],
      currentDirectory: fixture.parent
    )

    #expect(result.exitCode == 0)
    #expect(result.terminationReason == .exit)
    #expect(result.standardOutput.contains("Scan completeness: complete"))
    #expect(result.standardError.isEmpty)
  }

  @Test("Classify double dash allows a dash-prefixed relative root")
  func classifyDashPrefixedRoot() async throws {
    let fixture = try TemporaryCLIFixture()
    defer { fixture.remove() }

    let dashRoot = fixture.parent.appendingPathComponent("-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: dashRoot, withIntermediateDirectories: false)

    let result = try await runDevSift(
      ["classify", "--", "-cache"],
      currentDirectory: fixture.parent
    )

    #expect(result.exitCode == 0)
    #expect(result.terminationReason == .exit)
    #expect(result.standardOutput.contains("Scan completeness: complete"))
    #expect(result.standardError.isEmpty)
  }

  @Test("Symlink ancestors followed by dot-dot keep their POSIX meaning")
  func symlinkAncestorWithParentComponent() async throws {
    let fixture = try TemporaryCLIFixture()
    defer { fixture.remove() }

    let actualParent = fixture.parent.appendingPathComponent("actual", isDirectory: true)
    let nested = actualParent.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data([0xA1]).write(to: actualParent.appendingPathComponent("actual-marker"))
    try Data([0xB2]).write(to: fixture.parent.appendingPathComponent("wrong-marker"))
    try FileManager.default.createSymbolicLink(
      at: fixture.parent.appendingPathComponent("link"),
      withDestinationURL: nested
    )

    let result = try await runDevSift(
      ["scan", "--json", "link/.."],
      currentDirectory: fixture.parent
    )
    let data = try #require(result.standardOutput.data(using: .utf8))
    let document = try JSONDecoder().decode(ScanJSONDocumentV2.self, from: data)
    let paths = document.report.topLevelItems.map(\.path.display)

    #expect(result.exitCode == 0)
    #expect(result.terminationReason == .exit)
    #expect(paths.contains("actual-marker"))
    #expect(paths.contains("nested"))
    #expect(paths.contains("wrong-marker") == false)
  }

  @Test("Missing and non-directory roots use stable error exits")
  func invalidRoots() async throws {
    let fixture = try TemporaryCLIFixture()
    defer { fixture.remove() }

    let missing = fixture.parent.appendingPathComponent("missing")
    let missingResult = try await runDevSift(
      ["scan", missing.path],
      currentDirectory: fixture.parent
    )
    #expect(missingResult.exitCode == CLIExitCode.missingInput)
    #expect(missingResult.terminationReason == .exit)
    #expect(missingResult.standardOutput.isEmpty)
    #expect(missingResult.standardError.contains("does not exist"))

    let file = fixture.parent.appendingPathComponent("not-a-directory")
    try Data([0x01]).write(to: file)
    let fileResult = try await runDevSift(
      ["scan", file.path],
      currentDirectory: fixture.parent
    )
    #expect(fileResult.exitCode == CLIExitCode.invalidInput)
    #expect(fileResult.terminationReason == .exit)
    #expect(fileResult.standardOutput.isEmpty)
    #expect(fileResult.standardError.contains("not a directory"))

    let link = fixture.parent.appendingPathComponent("root-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
    let linkResult = try await runDevSift(
      ["scan", link.path],
      currentDirectory: fixture.parent
    )
    #expect(linkResult.exitCode == CLIExitCode.invalidInput)
    #expect(linkResult.terminationReason == .exit)
    #expect(linkResult.standardOutput.isEmpty)
    #expect(linkResult.standardError.contains("symbolic link"))
  }

  @Test("Unknown mutation commands cannot mutate the fixture")
  func mutationCommandsDoNotExist() async throws {
    let fixture = try TemporaryCLIFixture()
    defer { fixture.remove() }

    let beforeCommand = try fixture.snapshot()
    for command in [
      "clean", "cleanup", "delete", "erase", "prune", "remove", "purge", "quarantine",
    ] {
      let result = try await runDevSift(
        [command, fixture.root.path],
        currentDirectory: fixture.parent
      )

      #expect(result.exitCode == CLIExitCode.usage)
      #expect(result.terminationReason == .exit)
      #expect(result.standardOutput.isEmpty)
      #expect(result.standardError.contains("unknown command"))
      #expect(try fixture.snapshot() == beforeCommand)
    }
  }
}

private struct SubprocessResult {
  let exitCode: Int32
  let terminationReason: Process.TerminationReason
  let standardOutput: String
  let standardError: String
}

private func runDevSift(
  _ arguments: [String],
  currentDirectory: URL? = nil
) async throws -> SubprocessResult {
  let process = Process()
  let standardOutput = Pipe()
  let standardError = Pipe()
  process.executableURL = try devSiftExecutableURL()
  process.arguments = arguments
  process.currentDirectoryURL = currentDirectory
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = standardOutput
  process.standardError = standardError
  process.environment = [
    "LANG": "C",
    "LC_ALL": "C",
    "NO_COLOR": "1",
    "TERM": "dumb",
    "TZ": "UTC",
  ]

  try process.run()
  defer {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }
  async let outputData = standardOutput.fileHandleForReading.readToEnd()
  async let errorData = standardError.fileHandleForReading.readToEnd()

  let deadline = Date().addingTimeInterval(10)
  while process.isRunning, Date() < deadline {
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  if process.isRunning {
    process.terminate()
    process.waitUntilExit()
    _ = try await (outputData, errorData)
    throw CLIIntegrationTestError.timedOut
  }

  let (capturedOutput, capturedError) = try await (outputData, errorData)
  return SubprocessResult(
    exitCode: process.terminationStatus,
    terminationReason: process.terminationReason,
    standardOutput: String(decoding: capturedOutput ?? Data(), as: UTF8.self),
    standardError: String(decoding: capturedError ?? Data(), as: UTF8.self)
  )
}

private func devSiftExecutableURL() throws -> URL {
  var searchDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
    .absoluteURL
    .deletingLastPathComponent()
  for _ in 0..<8 {
    let candidate = searchDirectory.appendingPathComponent("devsift")
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
    searchDirectory.deleteLastPathComponent()
  }

  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let executable =
    repositoryRoot
    .appendingPathComponent(".build", isDirectory: true)
    .appendingPathComponent("debug", isDirectory: true)
    .appendingPathComponent("devsift")

  guard FileManager.default.isExecutableFile(atPath: executable.path) else {
    throw CLIIntegrationTestError.executableNotFound(executable.path)
  }
  return executable
}

private enum CLIIntegrationTestError: Error {
  case executableNotFound(String)
  case timedOut
}

private struct FixtureTreeSnapshot: Equatable {
  let relativePaths: [String]
  let fileContents: [String: Data]
  let symbolicLinkDestinations: [String: String]
}

private final class TemporaryCLIFixture {
  let parent: URL
  let root: URL
  let outsideSentinel: URL
  let outsideData = Data("outside-sentinel".utf8)

  init() throws {
    parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("DevSiftCLITests-\(UUID().uuidString)", isDirectory: true)
    root = parent.appendingPathComponent("scan-root", isDirectory: true)
    outsideSentinel = parent.appendingPathComponent("outside.txt")

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try outsideData.write(to: outsideSentinel)
  }

  func remove() {
    try? FileManager.default.removeItem(at: parent)
  }

  func snapshot() throws -> FixtureTreeSnapshot {
    let manager = FileManager.default
    let relativePaths = try manager.subpathsOfDirectory(atPath: parent.path).sorted()
    var fileContents: [String: Data] = [:]
    var symbolicLinkDestinations: [String: String] = [:]

    for relativePath in relativePaths {
      let absolutePath = parent.appendingPathComponent(relativePath).path
      let attributes = try manager.attributesOfItem(atPath: absolutePath)
      switch attributes[.type] as? FileAttributeType {
      case .typeRegular:
        fileContents[relativePath] = try Data(contentsOf: URL(fileURLWithPath: absolutePath))
      case .typeSymbolicLink:
        symbolicLinkDestinations[relativePath] = try manager.destinationOfSymbolicLink(
          atPath: absolutePath
        )
      default:
        break
      }
    }

    return FixtureTreeSnapshot(
      relativePaths: relativePaths,
      fileContents: fileContents,
      symbolicLinkDestinations: symbolicLinkDestinations
    )
  }
}
