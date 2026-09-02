import Foundation

enum ScanReportRuleAdapter {
  static func observations(for request: RuleClassificationRequest) -> [RuleObservation] {
    let rootBasename =
      rawBasename(of: request.root)
      .map(RuleObserved<[UInt8]>.known)
      ?? .unknown(.invalidMetadata)
    let packageManifest = packageManifestObservation(in: request.report)

    return request.report.topLevelItems.map { item in
      RuleObservation(
        summary: item,
        selectedRootBasename: rootBasename,
        integrity: RuleScanIntegrity(
          reportIsComplete: request.report.isComplete,
          itemIsComplete: item.isComplete,
          topLevelItemsWereSuppressed: request.report.topLevelItemsWereSuppressed,
          traversalDetailsWereDiscarded: request.report.traversalDetailsWereDiscarded,
          suppressedIssueCount: request.report.suppressedIssueCount,
          unknownAllocatedItemCount: item.unknownAllocatedItemCount,
          sizeOverflowed: item.sizeOverflowed,
          hardLinkAccountingIsComplete: request.report.hardLinkAccountingIsComplete
        ),
        facts: RuleObservationFacts(
          trustedLocation: .unknown(.notCollected),
          toolOwnership: .unknown(.notCollected),
          generatedContentMarker: .unknown(.notCollected),
          newestContentModificationUnixSeconds: .unknown(.notCollected),
          activity: .unknown(.notCollected),
          protectedDescendantPresent: .unknown(.notCollected),
          siblingPackageManifestPresent: packageManifest
        )
      )
    }
  }

  private static func packageManifestObservation(
    in report: ScanReport
  ) -> RuleObserved<Bool> {
    let expectedName = Array("Package.swift".utf8)
    if report.topLevelItems.contains(where: { item in
      item.path.rawComponents == [expectedName] && item.kind == .regularFile
    }) {
      return .known(true)
    }

    guard
      report.isComplete,
      !report.topLevelItemsWereSuppressed,
      !report.traversalDetailsWereDiscarded
    else {
      return .unknown(.incompleteScan)
    }
    return .known(false)
  }

  private static func rawBasename(of url: URL) -> [UInt8]? {
    url.withUnsafeFileSystemRepresentation { representation in
      guard let representation else {
        return nil
      }

      var bytes: [UInt8] = []
      var offset = 0
      while representation[offset] != 0 {
        bytes.append(UInt8(bitPattern: representation[offset]))
        offset += 1
      }

      while bytes.count > 1, bytes.last == 0x2F {
        bytes.removeLast()
      }
      guard let separator = bytes.lastIndex(of: 0x2F) else {
        return bytes
      }
      return Array(bytes[bytes.index(after: separator)...])
    }
  }
}
