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

  @Test("Summaries retain their own scan-time identities without following symlink targets")
  func scanTimeIdentities() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let directory = try fixture.makeDirectory("directory")
    let file = try fixture.write("file.bin", bytes: [1])
    let hardLink = try fixture.makeHardLink("file-link.bin", source: file)
    let outsideTarget = try fixture.write("outside.bin", bytes: [2], under: fixture.outside)
    let symbolicLink = try fixture.makeSymbolicLink("outside-link", destination: outsideTarget)

    let report = try await AllocatedSizeScanner().scan(root: fixture.root)
    let rootIdentity = try FileMetadata.read(from: fixture.root).identity
    let directoryIdentity = try FileMetadata.read(from: directory).identity
    let fileIdentity = try FileMetadata.read(from: file).identity
    let hardLinkIdentity = try FileMetadata.read(from: hardLink).identity
    let symbolicLinkIdentity = try FileMetadata.read(from: symbolicLink).identity
    let outsideTargetIdentity = try FileMetadata.read(from: outsideTarget).identity

    #expect(report.root.scanTimeIdentity == rootIdentity)
    #expect(
      try summary(named: "directory", in: report).scanTimeIdentity
        == directoryIdentity
    )
    #expect(
      try summary(named: "file.bin", in: report).scanTimeIdentity
        == fileIdentity
    )
    #expect(
      try summary(named: "file-link.bin", in: report).scanTimeIdentity
        == hardLinkIdentity
    )
    #expect(
      try summary(named: "file.bin", in: report).scanTimeIdentity
        == summary(named: "file-link.bin", in: report).scanTimeIdentity
    )
    #expect(
      try summary(named: "outside-link", in: report).scanTimeIdentity
        == symbolicLinkIdentity
    )
    #expect(
      try summary(named: "outside-link", in: report).scanTimeIdentity
        != outsideTargetIdentity
    )
  }

  @Test("Summaries conservatively retain inode times without following symlink targets")
  func newestContentModificationTime() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let cache = try fixture.makeDirectory("cache")
    let nested = try fixture.makeDirectory("cache/nested")
    let payload = try fixture.write("cache/nested/payload.bin", bytes: [1])
    let empty = try fixture.makeDirectory("empty")
    let outsideTarget = try fixture.write("newer.bin", bytes: [2], under: fixture.outside)
    let link = try fixture.makeSymbolicLink("cache/link", destination: outsideTarget)
    let fractional = try fixture.write("fractional.bin", bytes: [3])

    try fixture.setModificationTime(900, for: outsideTarget)
    try fixture.setModificationTime(450, for: link, followSymbolicLinks: false)
    try fixture.setModificationTime(400, for: payload)
    try fixture.setModificationTime(300, for: nested)
    try fixture.setModificationTime(200, for: cache)
    try fixture.setModificationTime(500, for: empty)
    try fixture.setModificationTime(600, for: fractional, nanoseconds: 1)
    try fixture.setModificationTime(100, for: fixture.root)

    let report = try await AllocatedSizeScanner().scan(root: fixture.root)
    let cacheSummary = try summary(named: "cache", in: report)
    let emptySummary = try summary(named: "empty", in: report)
    let fractionalSummary = try summary(named: "fractional.bin", in: report)

    #expect(report.root.newestContentModificationUnixSeconds == 601)
    #expect(cacheSummary.newestContentModificationUnixSeconds == 450)
    #expect(emptySummary.newestContentModificationUnixSeconds == 500)
    #expect(fractionalSummary.newestContentModificationUnixSeconds == 601)
  }

  @Test("One invalid inode time invalidates the aggregate instead of hiding behind a newer time")
  func invalidModificationTimeInvalidatesAggregate() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    try fixture.write("cache/valid.bin", bytes: [1])
    try fixture.write("cache/invalid.bin", bytes: [2])
    let scanner = AllocatedSizeScanner(metadataTransform: { path, metadata in
      guard path.description == "cache/invalid.bin" else {
        return metadata
      }
      return FileMetadata(
        kind: metadata.kind,
        identity: metadata.identity,
        size: metadata.size,
        allocatedSizeIsKnown: metadata.allocatedSizeIsKnown,
        hardLinkCount: metadata.hardLinkCount,
        mayShareFileContent: metadata.mayShareFileContent,
        modificationUnixSeconds: -1
      )
    })

    let report = try await scanner.scan(root: fixture.root)
    let cacheSummary = try summary(named: "cache", in: report)

    #expect(report.root.newestContentModificationUnixSeconds == -1)
    #expect(cacheSummary.newestContentModificationUnixSeconds == -1)
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
    let rootIdentity = try FileMetadata.read(from: fixture.root).identity
    #expect(report.root.scanTimeIdentity == rootIdentity)
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
        mayShareFileContent: metadata.mayShareFileContent,
        modificationUnixSeconds: metadata.modificationUnixSeconds
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
        mayShareFileContent: metadata.mayShareFileContent,
        modificationUnixSeconds: metadata.modificationUnixSeconds
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
    #expect(report.root.sizeOverflowed)
    #expect(bucket.sizeOverflowed)
    #expect(overflowPaths == [".", "bucket"])

    let issueBoundedReport = try await scanner.scan(
      root: fixture.root,
      limits: ScanLimits(maximumRecordedIssues: 0)
    )
    let issueBoundedBucket = try summary(named: "bucket", in: issueBoundedReport)
    #expect(issueBoundedReport.issues.isEmpty)
    #expect(issueBoundedReport.suppressedIssueCount == 2)
    #expect(issueBoundedReport.root.sizeOverflowed)
    #expect(issueBoundedBucket.sizeOverflowed)
  }
}
