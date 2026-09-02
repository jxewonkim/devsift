import Darwin
import Foundation
import Testing

@testable import DevSiftCore

struct ScannerFixture: Sendable {
  let container: URL
  let root: URL
  let outside: URL

  init() throws {
    container = FileManager.default.temporaryDirectory
      .appendingPathComponent("DevSiftTests-\(UUID().uuidString)", isDirectory: true)
    root = container.appendingPathComponent("root", isDirectory: true)
    outside = container.appendingPathComponent("outside", isDirectory: true)

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: container.path
    )
    try? FileManager.default.removeItem(at: container)
  }

  @discardableResult
  func makeDirectory(_ relativePath: String, under base: URL? = nil) throws -> URL {
    let url = url(for: relativePath, under: base ?? root)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  func write(
    _ relativePath: String,
    bytes: [UInt8],
    under base: URL? = nil
  ) throws -> URL {
    let url = url(for: relativePath, under: base ?? root)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(bytes).write(to: url)
    return url
  }

  @discardableResult
  func makeSymbolicLink(
    _ relativePath: String,
    destination: URL,
    under base: URL? = nil
  ) throws -> URL {
    let url = url(for: relativePath, under: base ?? root)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    return url
  }

  @discardableResult
  func makeHardLink(
    _ relativePath: String,
    source: URL,
    under base: URL? = nil
  ) throws -> URL {
    let url = url(for: relativePath, under: base ?? root)
    try FileManager.default.linkItem(at: source, to: url)
    return url
  }

  func url(for relativePath: String, under base: URL? = nil) -> URL {
    relativePath.split(separator: "/", omittingEmptySubsequences: false).reduce(base ?? root) {
      partialURL, component in
      partialURL.appendingPathComponent(String(component))
    }
  }

  func setModificationTime(
    _ unixSeconds: Int64,
    for url: URL,
    nanoseconds: Int = 0,
    followSymbolicLinks: Bool = true
  ) throws {
    guard
      let nativeSeconds = Int(exactly: unixSeconds),
      (0..<1_000_000_000).contains(nanoseconds)
    else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EOVERFLOW))
    }
    var timestamps = [
      timespec(tv_sec: nativeSeconds, tv_nsec: nanoseconds),
      timespec(tv_sec: nativeSeconds, tv_nsec: nanoseconds),
    ]
    var failureCode: Int32 = EINVAL
    let flags = followSymbolicLinks ? 0 : AT_SYMLINK_NOFOLLOW
    let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else {
        return -1
      }
      let result = Darwin.utimensat(AT_FDCWD, path, &timestamps, flags)
      if result != 0 {
        failureCode = errno
      }
      return result
    }

    guard status == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(failureCode))
    }
  }
}

struct NodeSnapshot: Equatable {
  let mode: mode_t
  let inode: UInt64
  let logicalBytes: Int64
  let blockCount: Int64
  let linkCount: UInt64
  let modificationSeconds: Int
  let modificationNanoseconds: Int

  static func read(from url: URL) throws -> NodeSnapshot {
    var information = stat()
    let status = url.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.lstat($0, &information) } ?? -1
    }
    guard status == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    return NodeSnapshot(
      mode: information.st_mode,
      inode: UInt64(information.st_ino),
      logicalBytes: Int64(information.st_size),
      blockCount: information.st_blocks,
      linkCount: UInt64(information.st_nlink),
      modificationSeconds: information.st_mtimespec.tv_sec,
      modificationNanoseconds: information.st_mtimespec.tv_nsec
    )
  }
}

func treeSnapshot(at root: URL) throws -> [String: NodeSnapshot] {
  var result = [".": try NodeSnapshot.read(from: root)]
  guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
  else {
    return result
  }

  while let url = enumerator.nextObject() as? URL {
    let rootComponents = root.standardizedFileURL.pathComponents
    let childComponents = url.standardizedFileURL.pathComponents
    guard
      childComponents.count >= rootComponents.count,
      zip(rootComponents, childComponents).allSatisfy(==)
    else {
      continue
    }
    let relativePath = childComponents.dropFirst(rootComponents.count).joined(separator: "/")
    result[relativePath] = try NodeSnapshot.read(from: url)
  }
  return result
}

func summary(named name: String, in report: ScanReport) throws -> ScanItemSummary {
  try #require(report.topLevelItems.first { $0.path.description == name })
}

func expectScanError(
  _ expected: ScanError,
  operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected scan error \(expected), but the operation succeeded")
  } catch let error as ScanError {
    #expect(error == expected)
  } catch {
    Issue.record("Expected scan error \(expected), received \(error)")
  }
}

func expectCancellation(operation: () async throws -> Void) async {
  do {
    try await operation()
    Issue.record("Expected CancellationError, but the operation succeeded")
  } catch is CancellationError {
    // Expected.
  } catch {
    Issue.record("Expected CancellationError, received \(error)")
  }
}
