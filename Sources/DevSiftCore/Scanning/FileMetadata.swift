import Darwin
import Foundation

struct FileIdentity: Hashable, Sendable {
  let device: UInt64
  let inode: UInt64
}

struct FileSystemName: Comparable, Hashable, Sendable {
  let bytes: [UInt8]

  static func < (left: FileSystemName, right: FileSystemName) -> Bool {
    left.bytes.lexicographicallyPrecedes(right.bytes)
  }

  func withCString<Result>(
    _ body: (UnsafePointer<CChar>) throws -> Result
  ) rethrows -> Result {
    var terminatedBytes = bytes.map { CChar(bitPattern: $0) }
    terminatedBytes.append(0)

    return try terminatedBytes.withUnsafeBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }
}

struct FileMetadata: Equatable, Sendable {
  let kind: FileSystemEntryKind
  let identity: FileIdentity
  let size: StorageSize
  let allocatedSizeIsKnown: Bool
  let hardLinkCount: UInt64
  let mayShareFileContent: Bool?
  let modificationUnixSeconds: Int64

  init(
    kind: FileSystemEntryKind,
    identity: FileIdentity,
    size: StorageSize,
    allocatedSizeIsKnown: Bool,
    hardLinkCount: UInt64,
    mayShareFileContent: Bool?,
    modificationUnixSeconds: Int64
  ) {
    self.kind = kind
    self.identity = identity
    self.size = size
    self.allocatedSizeIsKnown = allocatedSizeIsKnown
    self.hardLinkCount = hardLinkCount
    self.mayShareFileContent = mayShareFileContent
    self.modificationUnixSeconds = modificationUnixSeconds
  }

  /// Reads the selected root without following its final component.
  static func read(from url: URL) throws -> FileMetadata {
    var information = stat()
    var failureCode: Int32 = EINVAL

    let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else {
        return -1
      }

      let result = Darwin.lstat(path, &information)
      if result != 0 {
        failureCode = errno
      }
      return result
    }

    guard status == 0 else {
      throw FileMetadataError(code: failureCode)
    }
    return try FileMetadata(information: information)
  }

  /// Reads one child relative to an already-open directory, without following
  /// symbolic links or reconstructing an absolute path.
  static func read(
    at parentDescriptor: Int32,
    name: FileSystemName
  ) throws -> FileMetadata {
    var information = stat()
    var failureCode: Int32 = EINVAL

    let status = name.withCString { namePointer -> Int32 in
      let result = Darwin.fstatat(
        parentDescriptor,
        namePointer,
        &information,
        AT_SYMLINK_NOFOLLOW
      )
      if result != 0 {
        failureCode = errno
      }
      return result
    }

    guard status == 0 else {
      throw FileMetadataError(code: failureCode)
    }
    return try FileMetadata(information: information)
  }

  /// Reads metadata from an already-open descriptor. This is used to verify
  /// that a directory opened with `openat` is the entry that was just observed.
  static func read(fromDescriptor descriptor: Int32) throws -> FileMetadata {
    var information = stat()
    guard Darwin.fstat(descriptor, &information) == 0 else {
      throw FileMetadataError(code: errno)
    }
    return try FileMetadata(information: information)
  }

  private init(information: stat) throws {
    guard information.st_size >= 0 else {
      throw FileMetadataError(code: EIO)
    }

    let allocatedBytes = Self.allocatedByteCount(blockCount: information.st_blocks)
    kind = Self.entryKind(for: information.st_mode)
    identity = FileIdentity(
      device: UInt64(bitPattern: Int64(information.st_dev)),
      inode: UInt64(information.st_ino)
    )
    size = StorageSize(
      logicalBytes: UInt64(information.st_size),
      allocatedBytes: allocatedBytes ?? 0
    )
    allocatedSizeIsKnown = allocatedBytes != nil
    hardLinkCount = UInt64(information.st_nlink)
    modificationUnixSeconds = Self.conservativeModificationUnixSeconds(
      information.st_mtimespec
    )

    // Foundation's clone-sharing resource key is path based. Reading it after
    // descriptor-relative validation would reintroduce a path race, so the
    // first scanner keeps this advisory value explicitly unknown.
    mayShareFileContent = nil
  }

  private static func entryKind(for mode: mode_t) -> FileSystemEntryKind {
    switch mode & mode_t(S_IFMT) {
    case mode_t(S_IFREG):
      .regularFile
    case mode_t(S_IFDIR):
      .directory
    case mode_t(S_IFLNK):
      .symbolicLink
    default:
      .other
    }
  }

  private static func allocatedByteCount(blockCount: Int64) -> UInt64? {
    guard blockCount >= 0 else {
      return nil
    }

    let (bytes, overflow) = UInt64(blockCount).multipliedReportingOverflow(by: 512)
    return overflow ? nil : bytes
  }

  /// Returns a whole-second upper bound so discarding subsecond precision can
  /// never make an inode appear older than it was. Negative, malformed, or
  /// unrepresentable timestamps use a negative sentinel that fails closed in
  /// summary aggregation and rule adaptation.
  private static func conservativeModificationUnixSeconds(
    _ timestamp: timespec
  ) -> Int64 {
    guard
      let seconds = Int64(exactly: timestamp.tv_sec),
      seconds >= 0,
      timestamp.tv_nsec >= 0,
      timestamp.tv_nsec < 1_000_000_000
    else {
      return -1
    }

    guard timestamp.tv_nsec > 0 else {
      return seconds
    }
    let (ceiling, overflow) = seconds.addingReportingOverflow(1)
    return overflow ? -1 : ceiling
  }
}

struct FileMetadataError: Error, CustomNSError, Sendable {
  static let errorDomain = NSPOSIXErrorDomain

  let code: Int32

  var errorCode: Int {
    Int(code)
  }
}
