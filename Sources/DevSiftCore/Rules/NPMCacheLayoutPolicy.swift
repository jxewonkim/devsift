enum NPMCacheDirectoryFormat {
  case cacheRoot
  case contentAlgorithms
  case contentFirstShard
  case contentSecondShard
  case contentLeaves
  case indexFirstShard
  case indexSecondShard
  case indexLeaves
  case emptyTemporaryDirectory

  private static let contentDirectoryName = Array("content-v2".utf8)
  private static let indexDirectoryName = Array("index-v5".utf8)
  private static let temporaryDirectoryName = Array("tmp".utf8)
  private static let lastVerifiedName = Array("_lastverified".utf8)
  private static let cacheDirectoryTagName = Array("CACHEDIR.TAG".utf8)

  func expectation(for rawName: [UInt8]) -> NPMCacheEntryExpectation? {
    switch self {
    case .cacheRoot:
      switch rawName {
      case Self.contentDirectoryName:
        return NPMCacheEntryExpectation(
          expectedKind: .directory,
          childDirectoryFormat: .contentAlgorithms
        )
      case Self.indexDirectoryName:
        return NPMCacheEntryExpectation(
          expectedKind: .directory,
          childDirectoryFormat: .indexFirstShard
        )
      case Self.temporaryDirectoryName:
        return NPMCacheEntryExpectation(
          expectedKind: .directory,
          childDirectoryFormat: .emptyTemporaryDirectory
        )
      case Self.lastVerifiedName, Self.cacheDirectoryTagName:
        return NPMCacheEntryExpectation(
          expectedKind: .regularFile,
          childDirectoryFormat: nil
        )
      default:
        return nil
      }
    case .contentAlgorithms:
      guard isNPMCacheAlgorithmName(rawName) else { return nil }
      return NPMCacheEntryExpectation(
        expectedKind: .directory,
        childDirectoryFormat: .contentFirstShard
      )
    case .contentFirstShard:
      guard isLowercaseHex(rawName, exactCount: 2) else { return nil }
      return NPMCacheEntryExpectation(
        expectedKind: .directory,
        childDirectoryFormat: .contentSecondShard
      )
    case .contentSecondShard:
      guard isLowercaseHex(rawName, exactCount: 2) else { return nil }
      return NPMCacheEntryExpectation(
        expectedKind: .directory,
        childDirectoryFormat: .contentLeaves
      )
    case .contentLeaves:
      guard isNonemptyLowercaseHex(rawName) else { return nil }
      return NPMCacheEntryExpectation(
        expectedKind: .regularFile,
        childDirectoryFormat: nil
      )
    case .indexFirstShard:
      guard isLowercaseHex(rawName, exactCount: 2) else { return nil }
      return NPMCacheEntryExpectation(
        expectedKind: .directory,
        childDirectoryFormat: .indexSecondShard
      )
    case .indexSecondShard:
      guard isLowercaseHex(rawName, exactCount: 2) else { return nil }
      return NPMCacheEntryExpectation(
        expectedKind: .directory,
        childDirectoryFormat: .indexLeaves
      )
    case .indexLeaves:
      guard isLowercaseHex(rawName, exactCount: 60) else { return nil }
      return NPMCacheEntryExpectation(
        expectedKind: .regularFile,
        childDirectoryFormat: nil
      )
    case .emptyTemporaryDirectory:
      return nil
    }
  }
}

struct NPMCacheEntryExpectation {
  let expectedKind: FileSystemEntryKind
  let childDirectoryFormat: NPMCacheDirectoryFormat?
}

private func isNPMCacheAlgorithmName(_ rawName: [UInt8]) -> Bool {
  !rawName.isEmpty
    && rawName.allSatisfy { byte in
      (0x61...0x7A).contains(byte)
        || (0x30...0x39).contains(byte)
        || byte == 0x2D
    }
}

private func isLowercaseHex(_ rawName: [UInt8], exactCount: Int) -> Bool {
  rawName.count == exactCount && isNonemptyLowercaseHex(rawName)
}

private func isNonemptyLowercaseHex(_ rawName: [UInt8]) -> Bool {
  !rawName.isEmpty
    && rawName.allSatisfy { byte in
      (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
    }
}
