import Foundation
import Testing

@testable import DevSiftCore

@Suite("Allocated size scanner")
struct AllocatedSizeScannerTests {
  @Test("An empty root produces a complete root-only report")
  func emptyRoot() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let report = try await AllocatedSizeScanner().scan(root: fixture.root)

    #expect(report.isComplete)
    #expect(report.topLevelItems.isEmpty)
    #expect(report.issues.isEmpty)
    #expect(report.root.path == .root)
    #expect(report.root.kind == .directory)
    #expect(report.root.counts.directories == 1)
    #expect(report.root.counts.total == 1)
  }

  @Test("Top-level summaries include hidden, Unicode, whitespace, and nested items")
  func summarizesTopLevelItems() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write(".hidden", bytes: [1])
    try fixture.write("hello world.txt", bytes: [1, 2, 3])
    try fixture.write("zeta/alpha.bin", bytes: [4, 5, 6, 7])
    try fixture.makeDirectory("한글 캐시")

    let scanner = AllocatedSizeScanner()
    let first = try await scanner.scan(root: fixture.root)
    let second = try await scanner.scan(root: fixture.root)
    let names = first.topLevelItems.map(\.path.description)
    let expectedNames = [".hidden", "hello world.txt", "zeta", "한글 캐시"].sorted {
      $0.utf8.lexicographicallyPrecedes($1.utf8)
    }

    #expect(first == second)
    #expect(names == expectedNames)
    #expect(first.root.counts.regularFiles == 3)
    #expect(first.root.counts.directories == 3)

    let spacedFile = try summary(named: "hello world.txt", in: first)
    #expect(spacedFile.kind == .regularFile)
    #expect(spacedFile.recursiveSize.logicalBytes == 3)

    let nestedDirectory = try summary(named: "zeta", in: first)
    #expect(nestedDirectory.kind == .directory)
    #expect(nestedDirectory.counts.directories == 1)
    #expect(nestedDirectory.counts.regularFiles == 1)
    #expect(nestedDirectory.recursiveSize.logicalBytes >= 4)
  }

  @Test("Cross-item hard links keep apparent bytes without per-item exclusive credit")
  func reportsCrossItemHardLinks() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let original = try fixture.write("a.bin", bytes: Array(repeating: 7, count: 8_192))
    try fixture.makeHardLink("b.bin", source: original)

    let report = try await AllocatedSizeScanner().scan(root: fixture.root)
    let first = try summary(named: "a.bin", in: report)
    let duplicate = try summary(named: "b.bin", in: report)

    #expect(report.root.counts.regularFiles == 2)
    #expect(report.root.counts.duplicateHardLinks == 1)
    #expect(first.recursiveSize.logicalBytes == 8_192)
    #expect(duplicate.recursiveSize.logicalBytes == 8_192)
    #expect(first.hardLinkExclusiveAllocatedBytes == 0)
    #expect(duplicate.hardLinkExclusiveAllocatedBytes == 0)
    #expect(first.nonExclusiveHardLinkFileCount == 1)
    #expect(duplicate.nonExclusiveHardLinkFileCount == 1)
    #expect(report.root.nonExclusiveHardLinkFileCount == 0)
    #expect(report.root.unobservedHardLinkFileCount == 0)
  }

  @Test("Hard links inside one top-level item receive one exclusive allocation credit")
  func hardLinksInsideOneTopLevelItem() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let original = try fixture.write(
      "group/a.bin",
      bytes: Array(repeating: 7, count: 8_192)
    )
    try fixture.makeHardLink("group/b.bin", source: original)
    let groupURL = fixture.url(for: "group")
    let expectedExclusiveBytes =
      try FileMetadata.read(from: groupURL).size.allocatedBytes
      + FileMetadata.read(from: original).size.allocatedBytes

    let report = try await AllocatedSizeScanner().scan(root: fixture.root)
    let group = try summary(named: "group", in: report)

    #expect(group.counts.regularFiles == 2)
    #expect(group.counts.duplicateHardLinks == 1)
    #expect(group.nonExclusiveHardLinkFileCount == 0)
    #expect(group.hardLinkExclusiveAllocatedBytes == expectedExclusiveBytes)
  }

  @Test("A hard link outside the root makes reclaimability uncertain")
  func reportsExternalHardLinks() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let outsideFile = try fixture.write(
      "original.bin",
      bytes: Array(repeating: 1, count: 4_096),
      under: fixture.outside
    )
    try fixture.makeHardLink("inside.bin", source: outsideFile)

    let report = try await AllocatedSizeScanner().scan(root: fixture.root)
    let item = try summary(named: "inside.bin", in: report)

    #expect(item.unobservedHardLinkFileCount == 1)
    #expect(item.hardLinkExclusiveAllocatedBytes == 0)
    #expect(item.nonExclusiveHardLinkFileCount == 1)
    #expect(report.root.unobservedHardLinkFileCount == 1)
    #expect(report.root.nonExclusiveHardLinkFileCount == 1)
    #expect(report.root.counts.duplicateHardLinks == 0)
  }

  @Test("Sparse files retain separate logical and allocated measurements")
  func sparseFile() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let sparseURL = fixture.url(for: "sparse.bin")
    #expect(FileManager.default.createFile(atPath: sparseURL.path, contents: nil))
    let handle = try FileHandle(forWritingTo: sparseURL)
    try handle.truncate(atOffset: 1_048_576)
    try handle.close()

    let report = try await AllocatedSizeScanner().scan(root: fixture.root)
    let sparse = try summary(named: "sparse.bin", in: report)

    #expect(sparse.recursiveSize.logicalBytes == 1_048_576)
    #expect(sparse.recursiveSize.allocatedBytes <= sparse.recursiveSize.logicalBytes)
  }

  @Test("Entry and issue limits create an explicitly partial report")
  func resourceLimits() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("one.txt", bytes: [1])
    try fixture.write("two.txt", bytes: [2])

    let report = try await AllocatedSizeScanner().scan(
      ScanRequest(
        root: fixture.root,
        limits: ScanLimits(maximumRecordedIssues: 8, maximumEntries: 1)
      )
    )
    let repeatedReport = try await AllocatedSizeScanner().scan(
      ScanRequest(
        root: fixture.root,
        limits: ScanLimits(maximumRecordedIssues: 8, maximumEntries: 1)
      )
    )

    #expect(report == repeatedReport)
    #expect(!report.isComplete)
    #expect(report.topLevelItems.isEmpty)
    #expect(report.topLevelItemsWereSuppressed)
    #expect(!report.hardLinkAccountingIsComplete)
    #expect(report.traversalDetailsWereDiscarded)
    #expect(report.issues.contains { $0.reason == .resourceLimit })
  }

  @Test("Top-level output is all-or-nothing when its memory bound is reached")
  func topLevelOutputLimit() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("a.txt", bytes: [1])
    try fixture.write("b.txt", bytes: [2])

    let report = try await AllocatedSizeScanner().scan(
      ScanRequest(root: fixture.root, limits: ScanLimits(maximumTopLevelItems: 1))
    )

    #expect(!report.isComplete)
    #expect(report.topLevelItemCount == 2)
    #expect(report.topLevelItems.isEmpty)
    #expect(report.topLevelItemsWereSuppressed)
    #expect(report.root.counts.regularFiles == 2)
  }

  @Test("Hard-link accounting fails closed when its memory bound is reached")
  func hardLinkTrackingLimit() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let first = try fixture.write("a.bin", bytes: Array(repeating: 1, count: 4_096))
    try fixture.makeHardLink("a-link.bin", source: first)
    let second = try fixture.write("b.bin", bytes: Array(repeating: 2, count: 4_096))
    try fixture.makeHardLink("b-link.bin", source: second)

    let report = try await AllocatedSizeScanner().scan(
      ScanRequest(
        root: fixture.root,
        limits: ScanLimits(maximumTrackedHardLinkEntries: 1)
      )
    )

    #expect(!report.isComplete)
    #expect(!report.hardLinkAccountingIsComplete)
    #expect(report.root.counts.regularFiles == 4)
    #expect(report.issues.contains { $0.reason == .resourceLimit })
    #expect(report.topLevelItems.allSatisfy { !$0.isComplete })
  }

  @Test("Hard-link path-byte accounting is bounded and fails closed")
  func hardLinkPathByteLimit() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let original = try fixture.write("a.bin", bytes: Array(repeating: 1, count: 4_096))
    try fixture.makeHardLink("b.bin", source: original)

    let report = try await AllocatedSizeScanner().scan(
      ScanRequest(
        root: fixture.root,
        limits: ScanLimits(maximumTrackedHardLinkPathBytes: 0)
      )
    )

    #expect(!report.isComplete)
    #expect(!report.hardLinkAccountingIsComplete)
    #expect(report.topLevelItems.allSatisfy { $0.hardLinkExclusiveAllocatedBytes == 0 })
    #expect(report.issues.contains { $0.reason == .resourceLimit })
  }

  @Test("Changed cross-item hard links invalidate every affected summary")
  func changedHardLinkGroupCompleteness() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let original = try fixture.write("a.bin", bytes: Array(repeating: 3, count: 4_096))
    try fixture.makeHardLink("b.bin", source: original)

    let scanner = AllocatedSizeScanner(metadataTransform: { path, metadata in
      guard path.description == "b.bin" else {
        return metadata
      }
      return FileMetadata(
        kind: metadata.kind,
        identity: metadata.identity,
        size: StorageSize(
          logicalBytes: metadata.size.logicalBytes + 1,
          allocatedBytes: metadata.size.allocatedBytes
        ),
        allocatedSizeIsKnown: metadata.allocatedSizeIsKnown,
        hardLinkCount: metadata.hardLinkCount,
        mayShareFileContent: metadata.mayShareFileContent
      )
    })

    let report = try await scanner.scan(root: fixture.root)
    let first = try summary(named: "a.bin", in: report)
    let second = try summary(named: "b.bin", in: report)

    #expect(!report.isComplete)
    #expect(!first.isComplete)
    #expect(!second.isComplete)
    #expect(first.hardLinkExclusiveAllocatedBytes == 0)
    #expect(second.hardLinkExclusiveAllocatedBytes == 0)
    #expect(report.issues.count { $0.reason == .changedDuringScan } == 1)
  }

  @Test("Size arithmetic saturates and reports canonical summary issues")
  func sizeOverflow() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("bucket/a.bin", bytes: [1])
    try fixture.write("bucket/b.bin", bytes: [2])

    let scanner = AllocatedSizeScanner(metadataTransform: { _, metadata in
      guard metadata.kind == .regularFile else {
        return metadata
      }
      return FileMetadata(
        kind: metadata.kind,
        identity: metadata.identity,
        size: StorageSize(logicalBytes: .max, allocatedBytes: .max),
        allocatedSizeIsKnown: true,
        hardLinkCount: metadata.hardLinkCount,
        mayShareFileContent: metadata.mayShareFileContent
      )
    })

    let report = try await scanner.scan(root: fixture.root)
    let bucket = try summary(named: "bucket", in: report)
    let overflowPaths = report.issues
      .filter { $0.reason == .sizeOverflow }
      .map(\.path.description)

    #expect(!report.isComplete)
    #expect(!bucket.isComplete)
    #expect(report.root.recursiveSize.logicalBytes == .max)
    #expect(report.root.recursiveSize.allocatedBytes == .max)
    #expect(bucket.recursiveSize.logicalBytes == .max)
    #expect(bucket.recursiveSize.allocatedBytes == .max)
    #expect(overflowPaths == [".", "bucket"])
  }
}
