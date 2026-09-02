import Foundation

public protocol FileSystemScanning: Sendable {
  func scan(_ request: ScanRequest) async throws -> ScanReport
}

public struct ScanRequest: Hashable, Sendable {
  public let root: URL
  public let limits: ScanLimits

  public init(root: URL, limits: ScanLimits = ScanLimits()) {
    self.root = root
    self.limits = limits
  }
}

public struct ScanLimits: Hashable, Sendable {
  public let maximumDepth: UInt16
  public let maximumRecordedIssues: UInt32
  public let maximumEntries: UInt64
  public let maximumTopLevelItems: UInt32
  public let maximumTrackedHardLinkEntries: UInt32
  public let maximumTrackedHardLinkPathBytes: UInt64

  public init(
    maximumDepth: UInt16 = 128,
    maximumRecordedIssues: UInt32 = 4_096,
    maximumEntries: UInt64 = 10_000_000,
    maximumTopLevelItems: UInt32 = 50_000,
    maximumTrackedHardLinkEntries: UInt32 = 100_000,
    maximumTrackedHardLinkPathBytes: UInt64 = 32 * 1_024 * 1_024
  ) {
    self.maximumDepth = maximumDepth
    self.maximumRecordedIssues = maximumRecordedIssues
    self.maximumEntries = maximumEntries
    self.maximumTopLevelItems = maximumTopLevelItems
    self.maximumTrackedHardLinkEntries = maximumTrackedHardLinkEntries
    self.maximumTrackedHardLinkPathBytes = maximumTrackedHardLinkPathBytes
  }
}

public struct StorageSize: Hashable, Sendable {
  public static let zero = StorageSize(logicalBytes: 0, allocatedBytes: 0)

  public let logicalBytes: UInt64
  public let allocatedBytes: UInt64

  public init(logicalBytes: UInt64, allocatedBytes: UInt64) {
    self.logicalBytes = logicalBytes
    self.allocatedBytes = allocatedBytes
  }
}

/// Device and inode observed during scanning.
///
/// This is a binding token for later descriptor-relative reobservation, not
/// standalone authority to mutate a path. Filesystem identities can be reused,
/// so any future mutation must reopen and revalidate immediately beforehand.
public struct FileIdentity: Hashable, Sendable {
  public let device: UInt64
  public let inode: UInt64

  public init(device: UInt64, inode: UInt64) {
    self.device = device
    self.inode = inode
  }
}

public enum FileSystemEntryKind: String, CaseIterable, Hashable, Sendable {
  case regularFile = "regular-file"
  case directory
  case symbolicLink = "symbolic-link"
  case other
}

public struct ScanRelativePath: Comparable, CustomStringConvertible, Hashable, Sendable {
  public static let root = ScanRelativePath(rawComponents: [])

  /// Exact filesystem bytes for every path component.
  ///
  /// POSIX filenames are byte sequences. Keeping those bytes prevents distinct,
  /// non-UTF-8 names from collapsing into the same report identity.
  public let rawComponents: [[UInt8]]

  public var components: [String] {
    rawComponents.map(Self.displayComponent)
  }

  public var description: String {
    components.isEmpty ? "." : components.joined(separator: "/")
  }

  public static func < (left: ScanRelativePath, right: ScanRelativePath) -> Bool {
    for (leftComponent, rightComponent) in zip(left.rawComponents, right.rawComponents) {
      guard leftComponent != rightComponent else {
        continue
      }

      return leftComponent.lexicographicallyPrecedes(rightComponent)
    }

    return left.rawComponents.count < right.rawComponents.count
  }

  init(components: [String]) {
    rawComponents = components.map { Array($0.utf8) }
  }

  init(rawComponents: [[UInt8]]) {
    self.rawComponents = rawComponents
  }

  func appending(rawComponent: [UInt8]) -> ScanRelativePath {
    ScanRelativePath(rawComponents: rawComponents + [rawComponent])
  }

  var topLevelRawComponent: [UInt8]? {
    rawComponents.first
  }

  private static func displayComponent(_ bytes: [UInt8]) -> String {
    if let string = String(bytes: bytes, encoding: .utf8) {
      return string
    }

    return bytes.map { String(format: "\\x%02X", $0) }.joined()
  }
}

public struct ScanEntryCounts: Hashable, Sendable {
  public let regularFiles: UInt64
  public let directories: UInt64
  public let symbolicLinks: UInt64
  public let other: UInt64
  public let duplicateHardLinks: UInt64

  public init(
    regularFiles: UInt64,
    directories: UInt64,
    symbolicLinks: UInt64,
    other: UInt64,
    duplicateHardLinks: UInt64
  ) {
    self.regularFiles = regularFiles
    self.directories = directories
    self.symbolicLinks = symbolicLinks
    self.other = other
    self.duplicateHardLinks = duplicateHardLinks
  }

  public var total: UInt64 {
    [regularFiles, directories, symbolicLinks, other].reduce(0) { total, count in
      let (sum, overflow) = total.addingReportingOverflow(count)
      return overflow ? UInt64.max : sum
    }
  }
}

public struct ScanItemSummary: Hashable, Sendable {
  public let path: ScanRelativePath
  public let kind: FileSystemEntryKind
  /// Identity of this summary's own inode when retained by the scanner.
  public let scanTimeIdentity: FileIdentity?
  public let recursiveSize: StorageSize
  public let hardLinkExclusiveAllocatedBytes: UInt64
  public let counts: ScanEntryCounts
  public let unknownAllocatedItemCount: UInt64
  public let possibleSharedContentFileCount: UInt64
  public let sharedContentMetadataUnavailableCount: UInt64
  public let unobservedHardLinkFileCount: UInt64
  public let nonExclusiveHardLinkFileCount: UInt64
  /// Conservative whole-second upper bound of the greatest inode modification
  /// timestamp observed for this summary. Negative values represent invalid
  /// metadata. A value on an incomplete summary is not proof that no newer
  /// descendant exists.
  public let newestContentModificationUnixSeconds: Int64?
  public let sizeOverflowed: Bool
  public let isComplete: Bool

  public init(
    path: ScanRelativePath,
    kind: FileSystemEntryKind,
    scanTimeIdentity: FileIdentity? = nil,
    recursiveSize: StorageSize,
    hardLinkExclusiveAllocatedBytes: UInt64,
    counts: ScanEntryCounts,
    unknownAllocatedItemCount: UInt64,
    possibleSharedContentFileCount: UInt64,
    sharedContentMetadataUnavailableCount: UInt64,
    unobservedHardLinkFileCount: UInt64,
    nonExclusiveHardLinkFileCount: UInt64,
    newestContentModificationUnixSeconds: Int64? = nil,
    sizeOverflowed: Bool = false,
    isComplete: Bool
  ) {
    self.path = path
    self.kind = kind
    self.scanTimeIdentity = scanTimeIdentity
    self.recursiveSize = recursiveSize
    self.hardLinkExclusiveAllocatedBytes = hardLinkExclusiveAllocatedBytes
    self.counts = counts
    self.unknownAllocatedItemCount = unknownAllocatedItemCount
    self.possibleSharedContentFileCount = possibleSharedContentFileCount
    self.sharedContentMetadataUnavailableCount = sharedContentMetadataUnavailableCount
    self.unobservedHardLinkFileCount = unobservedHardLinkFileCount
    self.nonExclusiveHardLinkFileCount = nonExclusiveHardLinkFileCount
    self.newestContentModificationUnixSeconds = newestContentModificationUnixSeconds
    self.sizeOverflowed = sizeOverflowed
    self.isComplete = isComplete
  }
}

public struct ScanReport: Hashable, Sendable {
  public let root: ScanItemSummary
  public let topLevelItems: [ScanItemSummary]
  public let topLevelItemCount: UInt64
  public let topLevelItemsWereSuppressed: Bool
  public let hardLinkAccountingIsComplete: Bool
  public let traversalDetailsWereDiscarded: Bool
  public let issues: [ScanIssue]
  public let suppressedIssueCount: UInt64

  public init(
    root: ScanItemSummary,
    topLevelItems: [ScanItemSummary],
    topLevelItemCount: UInt64,
    topLevelItemsWereSuppressed: Bool,
    hardLinkAccountingIsComplete: Bool,
    traversalDetailsWereDiscarded: Bool,
    issues: [ScanIssue],
    suppressedIssueCount: UInt64
  ) {
    self.root = root
    self.topLevelItems = topLevelItems
    self.topLevelItemCount = topLevelItemCount
    self.topLevelItemsWereSuppressed = topLevelItemsWereSuppressed
    self.hardLinkAccountingIsComplete = hardLinkAccountingIsComplete
    self.traversalDetailsWereDiscarded = traversalDetailsWereDiscarded
    self.issues = issues
    self.suppressedIssueCount = suppressedIssueCount
  }

  public var isComplete: Bool {
    root.isComplete
      && !topLevelItemsWereSuppressed
      && hardLinkAccountingIsComplete
      && !traversalDetailsWereDiscarded
      && suppressedIssueCount == 0
  }
}

public enum ScanOperation: String, CaseIterable, Hashable, Sendable {
  case validateRoot = "validate-root"
  case listDirectory = "list-directory"
  case readMetadata = "read-metadata"
  case measureSize = "measure-size"
}

public enum ScanIssueReason: String, CaseIterable, Hashable, Sendable {
  case permissionDenied = "permission-denied"
  case disappeared
  case changedDuringScan = "changed-during-scan"
  case crossedVolumeBoundary = "crossed-volume-boundary"
  case outsideRoot = "outside-root"
  case depthLimitReached = "depth-limit-reached"
  case resourceLimit = "resource-limit"
  case invalidMetadata = "invalid-metadata"
  case sizeOverflow = "size-overflow"
  case ioFailure = "io-failure"
}

public enum ScanIssueImpact: String, CaseIterable, Hashable, Sendable {
  case entrySkipped = "entry-skipped"
  case descendantsSkipped = "descendants-skipped"
  case estimateDegraded = "estimate-degraded"
}

public struct ScanIssue: Hashable, Sendable {
  public let path: ScanRelativePath
  public let operation: ScanOperation
  public let reason: ScanIssueReason
  public let impact: ScanIssueImpact
  public let systemCode: Int32?

  public init(
    path: ScanRelativePath,
    operation: ScanOperation,
    reason: ScanIssueReason,
    impact: ScanIssueImpact,
    systemCode: Int32? = nil
  ) {
    self.path = path
    self.operation = operation
    self.reason = reason
    self.impact = impact
    self.systemCode = systemCode
  }
}

public enum ScanError: Error, Equatable, Sendable {
  case rootMustBeAbsoluteFileURL
  case rootNotFound
  case rootIsSymbolicLink
  case rootIsNotDirectory
  case rootChangedDuringValidation
  case rootUnavailable(operation: ScanOperation, systemCode: Int32?)
}

extension ScanError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .rootMustBeAbsoluteFileURL:
      "The scan root must be an absolute local file URL."
    case .rootNotFound:
      "The scan root does not exist."
    case .rootIsSymbolicLink:
      "A symbolic link cannot be used as the scan root."
    case .rootIsNotDirectory:
      "The scan root must be a directory."
    case .rootChangedDuringValidation:
      "The scan root changed while it was being validated."
    case .rootUnavailable:
      "The scan root could not be read."
    }
  }
}
