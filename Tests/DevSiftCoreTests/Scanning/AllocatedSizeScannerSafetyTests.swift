import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Allocated size scanner safety")
struct AllocatedSizeScannerSafetyTests {
  @Test("A root symbolic link is rejected")
  func rejectsRootSymbolicLink() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let linkedRoot = try fixture.makeSymbolicLink(
      "linked-root",
      destination: fixture.root,
      under: fixture.container
    )

    await expectScanError(.rootIsSymbolicLink) {
      _ = try await AllocatedSizeScanner().scan(root: linkedRoot)
    }
    await expectScanError(.rootIsSymbolicLink) {
      _ = try await AllocatedSizeScanner().scan(
        root: URL(fileURLWithPath: linkedRoot.path + "/", isDirectory: true)
      )
    }
  }

  @Test("A symbolic-link parent is allowed when the selected root itself is a directory")
  func allowsSymbolicLinkAncestor() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let realParent = try fixture.makeDirectory("real", under: fixture.container)
    let selectedRoot = try fixture.makeDirectory("selected", under: realParent)
    try fixture.write("safe.txt", bytes: [1], under: selectedRoot)
    let aliasParent = try fixture.makeSymbolicLink(
      "alias-parent",
      destination: realParent,
      under: fixture.container
    )
    let rootThroughAlias = aliasParent.appendingPathComponent("selected", isDirectory: true)

    let report = try await AllocatedSizeScanner().scan(root: rootThroughAlias)

    #expect(report.isComplete)
    #expect(report.root.counts.regularFiles == 1)
  }

  @Test("Directory, file, and cyclic symbolic links are never traversed")
  func doesNotTraverseSymbolicLinks() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let outsideDirectory = try fixture.makeDirectory("payload", under: fixture.outside)
    let outsideFile = try fixture.write(
      "payload/large.bin",
      bytes: Array(repeating: 9, count: 1_048_576),
      under: fixture.outside
    )
    try fixture.makeSymbolicLink("directory-link", destination: outsideDirectory)
    try fixture.makeSymbolicLink("file-link", destination: outsideFile)
    try fixture.makeSymbolicLink("loop", destination: fixture.root)

    let report = try await AllocatedSizeScanner().scan(root: fixture.root)

    #expect(report.isComplete)
    #expect(report.root.counts.symbolicLinks == 3)
    #expect(report.root.counts.regularFiles == 0)
    #expect(report.topLevelItems.count == 3)
    #expect(report.topLevelItems.allSatisfy { $0.kind == .symbolicLink })
    #expect(
      report.topLevelItems.allSatisfy {
        $0.recursiveSize.logicalBytes < UInt64(1_048_576)
      }
    )
    #expect(try Data(contentsOf: outsideFile).count == 1_048_576)
  }

  @Test("Missing and regular-file roots fail with typed errors")
  func validatesRootType() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let file = try fixture.write("file.txt", bytes: [1])
    let missing = fixture.url(for: "missing")

    await expectScanError(.rootNotFound) {
      _ = try await AllocatedSizeScanner().scan(root: missing)
    }
    await expectScanError(.rootIsNotDirectory) {
      _ = try await AllocatedSizeScanner().scan(root: file)
    }
    await expectScanError(.rootMustBeAbsoluteFileURL) {
      _ = try await AllocatedSizeScanner().scan(
        root: try #require(URL(string: "https://example.invalid/not-local"))
      )
    }
    await expectScanError(.rootMustBeAbsoluteFileURL) {
      _ = try await AllocatedSizeScanner().scan(
        root: try #require(URL(string: "file://example.invalid\(fixture.root.path)"))
      )
    }
  }

  @Test("Relative path identity preserves exact non-UTF-8 filesystem bytes")
  func rawRelativePathIdentity() {
    let first = ScanRelativePath(rawComponents: [[0x61, 0xFF]])
    let second = ScanRelativePath(rawComponents: [[0x61, 0xFE]])

    #expect(first != second)
    #expect(second < first)
    #expect(first.description == "\\x61\\xFF")
    #expect(second.description == "\\x61\\xFE")
  }

  @Test("Issue ordering distinguishes a missing system code from zero")
  func issueOptionalCodeOrdering() {
    let withoutCode = ScanIssue(
      path: .root,
      operation: .readMetadata,
      reason: .ioFailure,
      impact: .entrySkipped
    )
    let withZeroCode = ScanIssue(
      path: .root,
      operation: .readMetadata,
      reason: .ioFailure,
      impact: .entrySkipped,
      systemCode: 0
    )

    #expect(withoutCode != withZeroCode)
    #expect(withoutCode < withZeroCode)
    #expect(!(withZeroCode < withoutCode))
  }

  @Test("Permission and disappearance failures are visible while siblings continue")
  func partialMetadataFailures() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("blocked/child.txt", bytes: [1])
    try fixture.write("gone.txt", bytes: [2])
    try fixture.write("safe.txt", bytes: [3])

    let scanner = AllocatedSizeScanner(metadataTransform: { path, metadata in
      switch path.description {
      case "blocked":
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
      case "gone.txt":
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
      default:
        return metadata
      }
    })

    let report = try await scanner.scan(root: fixture.root)

    #expect(!report.isComplete)
    #expect(report.topLevelItems.contains { $0.path.description == "safe.txt" })
    #expect(!report.topLevelItems.contains { $0.path.description == "blocked" })
    #expect(report.issues.map(\.path.description) == ["blocked", "gone.txt"])
    #expect(report.issues.map(\.reason) == [.permissionDenied, .disappeared])
  }

  @Test("Issue order and suppression are deterministic")
  func issueOrderingAndSuppression() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("z.txt", bytes: [1])
    try fixture.write("a.txt", bytes: [2])
    try fixture.write("m.txt", bytes: [3])

    let scanner = AllocatedSizeScanner(metadataTransform: { path, metadata in
      guard path == .root else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
      }
      return metadata
    })
    let report = try await scanner.scan(
      ScanRequest(
        root: fixture.root,
        limits: ScanLimits(maximumRecordedIssues: 2)
      )
    )

    #expect(!report.isComplete)
    #expect(report.issues.count == 2)
    #expect(report.suppressedIssueCount == 1)
    #expect(report.issues.map(\.path.description) == ["a.txt", "m.txt"])
  }

  @Test("A different-volume directory is reported and pruned")
  func prunesDifferentVolume() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("mounted/hidden.txt", bytes: [1])
    try fixture.write("safe.txt", bytes: [2])

    let scanner = AllocatedSizeScanner(metadataTransform: { path, metadata in
      guard path.description == "mounted" else {
        return metadata
      }

      return FileMetadata(
        kind: metadata.kind,
        identity: FileIdentity(
          device: metadata.identity.device &+ 1,
          inode: metadata.identity.inode
        ),
        size: metadata.size,
        allocatedSizeIsKnown: metadata.allocatedSizeIsKnown,
        hardLinkCount: metadata.hardLinkCount,
        mayShareFileContent: metadata.mayShareFileContent,
        modificationUnixSeconds: metadata.modificationUnixSeconds
      )
    })

    let report = try await scanner.scan(root: fixture.root)

    #expect(!report.isComplete)
    #expect(report.topLevelItems.map(\.path.description) == ["safe.txt"])
    #expect(report.issues.count == 1)
    #expect(report.issues[0].path.description == "mounted")
    #expect(report.issues[0].reason == .crossedVolumeBoundary)
  }

  @Test("A depth limit prunes descendants and marks their top-level item incomplete")
  func depthLimit() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("first/second/file.txt", bytes: [1])

    let report = try await AllocatedSizeScanner().scan(
      ScanRequest(root: fixture.root, limits: ScanLimits(maximumDepth: 1))
    )
    let first = try summary(named: "first", in: report)

    #expect(!report.isComplete)
    #expect(!first.isComplete)
    #expect(first.counts.directories == 1)
    #expect(first.counts.regularFiles == 0)
    #expect(report.issues.first?.reason == .depthLimitReached)
    #expect(report.issues.first?.path.description == "first")
  }

  @Test("A directory-to-symlink swap cannot escape the opened root")
  func resistsDirectorySymlinkSwap() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("victim/safe.txt", bytes: [1])
    let outsideFile = try fixture.write(
      "outside-only.bin",
      bytes: Array(repeating: 9, count: 1_048_576),
      under: fixture.outside
    )

    let scanner = AllocatedSizeScanner(beforeOpeningDirectory: { path in
      guard path.description == "victim" else {
        return
      }

      try FileManager.default.moveItem(
        at: fixture.url(for: "victim"),
        to: fixture.url(for: "parked")
      )
      try FileManager.default.createSymbolicLink(
        at: fixture.url(for: "victim"),
        withDestinationURL: fixture.outside
      )
    })

    let report = try await scanner.scan(root: fixture.root)

    #expect(!report.isComplete)
    #expect(report.root.recursiveSize.logicalBytes < 1_048_576)
    #expect(
      report.issues.contains {
        $0.path.description == "victim" && $0.reason == .changedDuringScan
      }
    )
    #expect(try Data(contentsOf: outsideFile).count == 1_048_576)
  }

  @Test("A directory replacement is rejected after descriptor identity validation")
  func resistsDirectoryReplacement() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("victim/original.txt", bytes: [1])
    let replacement = try fixture.makeDirectory("replacement", under: fixture.container)
    _ = try fixture.write(
      "replacement/unselected.bin",
      bytes: Array(repeating: 8, count: 1_048_576),
      under: fixture.container
    )

    let scanner = AllocatedSizeScanner(beforeOpeningDirectory: { path in
      guard path.description == "victim" else {
        return
      }

      try FileManager.default.moveItem(
        at: fixture.url(for: "victim"),
        to: fixture.container.appendingPathComponent("original-victim")
      )
      try FileManager.default.moveItem(at: replacement, to: fixture.url(for: "victim"))
    })

    let report = try await scanner.scan(root: fixture.root)

    #expect(!report.isComplete)
    #expect(report.root.recursiveSize.logicalBytes < 1_048_576)
    #expect(
      report.issues.contains {
        $0.path.description == "victim" && $0.reason == .changedDuringScan
      }
    )
    #expect(try Data(contentsOf: fixture.url(for: "victim/unselected.bin")).count == 1_048_576)
  }

  @Test("Replacing the selected root during validation is rejected")
  func rejectsRootSwap() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("original.txt", bytes: [1])
    let replacement = try fixture.makeDirectory("replacement", under: fixture.container)
    try fixture.write("replacement/unselected.txt", bytes: [2], under: fixture.container)

    let scanner = AllocatedSizeScanner(afterRootValidation: {
      try FileManager.default.moveItem(
        at: fixture.root,
        to: fixture.container.appendingPathComponent("original-root")
      )
      try FileManager.default.moveItem(at: replacement, to: fixture.root)
    })

    await expectScanError(.rootChangedDuringValidation) {
      _ = try await scanner.scan(root: fixture.root)
    }
  }

  @Test("A nested failure does not invalidate an independent top-level item")
  func isolatesTopLevelCompleteness() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("A/bad.txt", bytes: [1])
    try fixture.write("B/good.txt", bytes: [2])

    let scanner = AllocatedSizeScanner(metadataTransform: { path, metadata in
      guard path.description != "A/bad.txt" else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
      }
      return metadata
    })

    let report = try await scanner.scan(root: fixture.root)
    let first = try summary(named: "A", in: report)
    let second = try summary(named: "B", in: report)

    #expect(!report.root.isComplete)
    #expect(!first.isComplete)
    #expect(second.isComplete)
  }

  @Test("Scanning does not change fixture or outside sentinel metadata")
  func scanDoesNotMutate() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("nested/file.txt", bytes: [1, 2, 3])
    let sentinel = try fixture.write("sentinel.txt", bytes: [4, 5, 6], under: fixture.outside)
    let rootBefore = try treeSnapshot(at: fixture.root)
    let sentinelBefore = try NodeSnapshot.read(from: sentinel)
    let sentinelDataBefore = try Data(contentsOf: sentinel)

    _ = try await AllocatedSizeScanner().scan(root: fixture.root)

    #expect(try treeSnapshot(at: fixture.root) == rootBefore)
    #expect(try NodeSnapshot.read(from: sentinel) == sentinelBefore)
    #expect(try Data(contentsOf: sentinel) == sentinelDataBefore)
  }

  @Test("Shell-like names and FIFO nodes are treated only as filesystem entries")
  func unusualNamesAndFIFO() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let names = ["--help", "`command`", "$(command)", "line\nbreak"]
    for name in names {
      try fixture.write(name, bytes: [1])
    }

    let fifo = fixture.url(for: "named-pipe")
    let fifoStatus = fifo.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.mkfifo($0, 0o600) } ?? -1
    }
    #expect(fifoStatus == 0)

    let report = try await AllocatedSizeScanner().scan(root: fixture.root)
    let reportedNames = Set(report.topLevelItems.map(\.path.description))

    #expect(report.isComplete)
    #expect(Set(names + ["named-pipe"]) == reportedNames)
    #expect(try summary(named: "named-pipe", in: report).kind == .other)
  }
}
