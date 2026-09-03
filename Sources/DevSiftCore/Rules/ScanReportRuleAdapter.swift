import Foundation

enum ScanReportRuleAdapter {
  static func observations(
    for request: RuleClassificationRequest,
    evidence: RuleEvidenceObservation? = nil
  ) -> [RuleObservation] {
    let rootBasename =
      rawBasename(of: request.root)
      .map(RuleObserved<[UInt8]>.known)
      ?? .unknown(.invalidMetadata)
    let packageManifest = packageManifestObservation(in: request.report)
    let candidateEvidence = normalizedEvidence(
      for: request.report,
      observation: evidence
    )

    return request.report.topLevelItems.enumerated().map { index, item in
      let observed = candidateEvidence[index]
      return RuleObservation(
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
          hardLinkAccountingIsComplete: request.report.hardLinkAccountingIsComplete,
          identityMatchesScan: observed.identityMatchesScan
        ),
        facts: RuleObservationFacts(
          trustedLocation: observed.trustedLocation,
          toolOwnership: .unknown(.notCollected),
          accountOwnedCacheNamespace: observed.accountOwnedCacheNamespace,
          generatedContentMarker: observed.generatedContentMarker,
          newestContentModificationUnixSeconds: newestModificationObservation(for: item),
          activity: .unknown(.notCollected),
          protectedDescendantPresent: observed.protectedDescendantPresent,
          siblingPackageManifestPresent: packageManifest
        )
      )
    }
  }

  private static func normalizedEvidence(
    for report: ScanReport,
    observation: RuleEvidenceObservation?
  ) -> [CandidateRuleEvidence] {
    let candidates: [CandidateRuleEvidence]
    if let observation, observation.candidates.count == report.topLevelItems.count {
      candidates = observation.candidates
    } else {
      let missingReason: RuleUnknownReason = observation == nil ? .notCollected : .invalidMetadata
      candidates = report.topLevelItems.map { item in
        unavailableEvidence(for: item, reason: missingReason)
      }
    }

    return zip(report.topLevelItems, candidates).map { item, evidence in
      guard report.isComplete, item.isComplete else {
        return unavailableEvidence(for: item, reason: .incompleteScan)
      }
      guard item.scanTimeIdentity != nil else {
        return unavailableEvidence(for: item, reason: .notCollected)
      }
      return evidence
    }
  }

  private static func unavailableEvidence(
    for item: ScanItemSummary,
    reason: RuleUnknownReason
  ) -> CandidateRuleEvidence {
    CandidateRuleEvidence.unavailable(reason, for: item)
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

  private static func newestModificationObservation(
    for item: ScanItemSummary
  ) -> RuleObserved<Int64> {
    guard item.isComplete else {
      return .unknown(.incompleteScan)
    }
    guard let unixSeconds = item.newestContentModificationUnixSeconds else {
      return .unknown(.notCollected)
    }
    guard unixSeconds >= 0 else {
      return .unknown(.invalidMetadata)
    }
    return .known(unixSeconds)
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
