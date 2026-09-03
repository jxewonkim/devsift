import DevSiftCore
import Foundation

enum CleanupManifestReviewPrivacyProfile: String, CaseIterable, Hashable, Sendable {
  case redacted
  case rootRelativeExact = "root-relative-exact"
}

enum CleanupManifestReviewOutputContract {
  static let schema = "devsift.cleanup-manifest-review"
  static let schemaVersion = 2
  static let supportedSourceManifestContractVersion: UInt32 = 3
  static let maximumEncodedBytes = 128 * 1_024 * 1_024
}

enum CleanupManifestReviewEntryIssue: Equatable, Sendable {
  case path(CleanupPlanPathIssue)
  case unsupportedKind
  case ineligibleDisposition
  case unknownReproducibility
  case reclaimableIsNotReproducible
  case candidateDeviceMismatch
  case hardLinkExclusiveSizeExceedsAllocatedSize
  case missingIdentityFinding
  case missingRequiredFinding(CheckIdentifier)
  case requiredFindingKindMismatch(CheckIdentifier)
  case missingRulePositiveEvidence
  case missingRuleExclusion
  case tooManyFindings(maximum: Int, actual: Int)
  case findingsOutOfOrder
  case duplicateFindingIdentifier
  case invalidDeferredExecutionPreconditions
  case unsatisfiedFinding
  case emptyMetadata(RuleEvaluationMetadataField)
  case emptyFindingExplanation
  case metadataTooLarge(maximumBytes: Int, actualBytes: Int)
  case findingTextTooLarge(maximumBytes: Int, actualBytes: Int)
}

enum CleanupManifestReviewExportError: Error, Equatable, Sendable {
  case unsupportedManifestContractVersion(expected: UInt32, actual: UInt32)
  case tooManyEntries(maximum: Int, actual: Int)
  case entriesOutOfOrder(index: Int)
  case duplicateEntryPath(index: Int)
  case invalidEntry(index: Int, issue: CleanupManifestReviewEntryIssue)
  case undeclaredRuleRevision(index: Int)
  case tooManyFindings(maximum: Int, actual: Int)
  case reportTextTooLarge(maximumBytes: Int, actualBytes: Int)
  case totalOverflow(CleanupSizeMetric)
  case inconsistentTotals(CleanupSizeMetric)
  case outputTooLarge(maximumBytes: Int, projectedBytes: Int)
  case encodingFailed
}

/// Produces a lossy, review-only JSON projection of a cleanup manifest.
///
/// The encoder performs no filesystem I/O and exposes no decoder. Neither
/// profile contains filesystem identities, a dedicated absolute-root field,
/// approval, or execution authority.
struct CleanupManifestReviewJSONEncoder: Sendable {
  private let maximumEncodedBytes: Int

  init(maximumEncodedBytes: Int = CleanupManifestReviewOutputContract.maximumEncodedBytes) {
    self.maximumEncodedBytes = min(
      max(0, maximumEncodedBytes),
      CleanupManifestReviewOutputContract.maximumEncodedBytes
    )
  }

  func encode(
    manifest: CleanupManifest,
    privacyProfile: CleanupManifestReviewPrivacyProfile
  ) throws -> Data {
    try CleanupManifestReviewValidator.validate(manifest)
    try Task.checkCancellation()
    try preflightEncodedSize(manifest: manifest, privacyProfile: privacyProfile)

    let document = try CleanupManifestReviewJSONDocumentV2(
      manifest: manifest,
      privacyProfile: privacyProfile
    )
    var data = try encode(document, using: makeEncoder())

    try Task.checkCancellation()
    let (finalByteCount, byteCountOverflow) = data.count.addingReportingOverflow(1)
    guard !byteCountOverflow else {
      throw CleanupManifestReviewExportError.outputTooLarge(
        maximumBytes: maximumEncodedBytes,
        projectedBytes: Int.max
      )
    }
    guard finalByteCount <= maximumEncodedBytes else {
      throw CleanupManifestReviewExportError.outputTooLarge(
        maximumBytes: maximumEncodedBytes,
        projectedBytes: finalByteCount
      )
    }
    data.append(0x0A)
    return data
  }

  private func preflightEncodedSize(
    manifest: CleanupManifest,
    privacyProfile: CleanupManifestReviewPrivacyProfile
  ) throws {
    let encoder = makeEncoder()
    let envelope = try CleanupManifestReviewJSONDocumentV2(
      manifest: manifest,
      privacyProfile: privacyProfile,
      projectedEntries: []
    )
    var projectedBytes = try encode(envelope, using: encoder).count

    for (index, entry) in manifest.entries.enumerated() {
      try Task.checkCancellation()
      let projectedEntry = CleanupManifestReviewJSONEntryV2(
        entry: entry,
        index: index,
        privacyProfile: privacyProfile
      )
      let entryBytes = try encode(projectedEntry, using: encoder).count
      projectedBytes = try addingProjectedBytes(entryBytes, to: projectedBytes)
      if index > 0 {
        projectedBytes = try addingProjectedBytes(1, to: projectedBytes)
      }
    }
    _ = try addingProjectedBytes(1, to: projectedBytes)
  }

  private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private func encode<Value: Encodable>(
    _ value: Value,
    using encoder: JSONEncoder
  ) throws -> Data {
    do {
      return try encoder.encode(value)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CleanupManifestReviewExportError.encodingFailed
    }
  }

  private func addingProjectedBytes(_ bytes: Int, to total: Int) throws -> Int {
    let (sum, overflow) = total.addingReportingOverflow(bytes)
    guard !overflow, sum <= maximumEncodedBytes else {
      throw CleanupManifestReviewExportError.outputTooLarge(
        maximumBytes: maximumEncodedBytes,
        projectedBytes: overflow ? Int.max : sum
      )
    }
    return sum
  }
}

enum CleanupManifestReviewValidator {
  private static let identityFinding = checkIdentifier("identity-matches-scan")
  private static let requiredCommonFindings: [(CheckIdentifier, RuleFindingKind)] = [
    (checkIdentifier("lexical-recognition"), .lexicalRecognition),
    (checkIdentifier("reproducibility"), .reproducibility),
    (checkIdentifier("age-requirement"), .age),
    (checkIdentifier("activity-requirement"), .activity),
    (checkIdentifier("report-complete"), .scanIntegrity),
    (checkIdentifier("item-complete"), .scanIntegrity),
    (checkIdentifier("top-level-output-complete"), .scanIntegrity),
    (checkIdentifier("traversal-details-retained"), .scanIntegrity),
    (checkIdentifier("issues-complete"), .scanIntegrity),
    (checkIdentifier("allocation-known"), .scanIntegrity),
    (checkIdentifier("size-did-not-overflow"), .scanIntegrity),
    (checkIdentifier("hard-links-complete"), .scanIntegrity),
    (identityFinding, .scanIntegrity),
  ]
  private static let automaticFindings = Set(
    requiredCommonFindings.map(\.0)
      + [
        checkIdentifier("rule-conflict"),
        checkIdentifier("rule-validity"),
        checkIdentifier("duplicate-observation"),
      ]
  )

  static func validate(_ manifest: CleanupManifest) throws {
    try Task.checkCancellation()
    guard
      manifest.contractVersion
        == CleanupManifestReviewOutputContract.supportedSourceManifestContractVersion
    else {
      throw CleanupManifestReviewExportError.unsupportedManifestContractVersion(
        expected: CleanupManifestReviewOutputContract.supportedSourceManifestContractVersion,
        actual: manifest.contractVersion
      )
    }
    guard manifest.entries.count <= CleanupPlanningLimits.maximumSelections else {
      throw CleanupManifestReviewExportError.tooManyEntries(
        maximum: CleanupPlanningLimits.maximumSelections,
        actual: manifest.entries.count
      )
    }

    let declaredRevisions = Set(manifest.policyProvenance.ruleRevisions)
    var previousPath: ScanRelativePath?
    var findingCount = 0
    var reportTextBytes = 0
    var totals = MutableReviewTotals()

    for (index, entry) in manifest.entries.enumerated() {
      try Task.checkCancellation()
      if let previousPath {
        if entry.path == previousPath {
          throw CleanupManifestReviewExportError.duplicateEntryPath(index: index)
        }
        guard previousPath < entry.path else {
          throw CleanupManifestReviewExportError.entriesOutOfOrder(index: index)
        }
      }
      previousPath = entry.path

      if let pathIssue = pathIssue(entry.path) {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .path(pathIssue)
        )
      }
      guard entry.expectedKind == .directory else {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .unsupportedKind
        )
      }
      guard entry.disposition == .reclaimable || entry.disposition == .reviewRequired else {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .ineligibleDisposition
        )
      }
      guard entry.reproducibility != .unknown else {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .unknownReproducibility
        )
      }
      guard entry.disposition != .reclaimable || entry.reproducibility == .reproducible else {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .reclaimableIsNotReproducible
        )
      }
      guard entry.expectedIdentity.device == manifest.expectedRootIdentity.device else {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .candidateDeviceMismatch
        )
      }
      guard
        entry.size.observedHardLinkExclusiveAllocatedBytes
          <= entry.size.observedAllocatedBytes
      else {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .hardLinkExclusiveSizeExceedsAllocatedSize
        )
      }
      guard declaredRevisions.contains(entry.ruleRevision) else {
        throw CleanupManifestReviewExportError.undeclaredRuleRevision(index: index)
      }

      guard entry.findings.count <= RuleCatalogLimits.maximumFindingsPerEvaluation else {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .tooManyFindings(
            maximum: RuleCatalogLimits.maximumFindingsPerEvaluation,
            actual: entry.findings.count
          )
        )
      }
      let (nextFindingCount, findingOverflow) = findingCount.addingReportingOverflow(
        entry.findings.count
      )
      guard !findingOverflow else {
        throw CleanupManifestReviewExportError.tooManyFindings(
          maximum: RuleCatalogLimits.maximumTotalEvaluationFindings,
          actual: Int.max
        )
      }
      findingCount = nextFindingCount
      guard findingCount <= RuleCatalogLimits.maximumTotalEvaluationFindings else {
        throw CleanupManifestReviewExportError.tooManyFindings(
          maximum: RuleCatalogLimits.maximumTotalEvaluationFindings,
          actual: findingCount
        )
      }

      var metadataBytes = 0
      for (field, text) in [
        (RuleEvaluationMetadataField.displayName, entry.displayName),
        (RuleEvaluationMetadataField.responsibleTool, entry.responsibleTool),
        (RuleEvaluationMetadataField.explanation, entry.classificationExplanation),
      ] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw CleanupManifestReviewExportError.invalidEntry(
            index: index,
            issue: .emptyMetadata(field)
          )
        }
        metadataBytes = try addingMetadataBytes(
          text.utf8.count,
          to: metadataBytes,
          entryIndex: index
        )
      }
      reportTextBytes = try addingTextBytes(
        metadataBytes,
        to: reportTextBytes
      )

      guard entry.deferredExecutionPreconditionsAreWellFormed else {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .invalidDeferredExecutionPreconditions
        )
      }
      let nonDeferredBlockingFindings = entry.nonDeferredBlockingFindings

      var previousFindingIdentifier: CheckIdentifier?
      var findingsByIdentifier: [CheckIdentifier: RuleFinding] = [:]
      for finding in entry.findings {
        try Task.checkCancellation()
        if let previousFindingIdentifier {
          if finding.identifier == previousFindingIdentifier {
            throw CleanupManifestReviewExportError.invalidEntry(
              index: index,
              issue: .duplicateFindingIdentifier
            )
          }
          guard previousFindingIdentifier < finding.identifier else {
            throw CleanupManifestReviewExportError.invalidEntry(
              index: index,
              issue: .findingsOutOfOrder
            )
          }
        }
        previousFindingIdentifier = finding.identifier
        findingsByIdentifier[finding.identifier] = finding

        guard !nonDeferredBlockingFindings.contains(finding) else {
          throw CleanupManifestReviewExportError.invalidEntry(
            index: index,
            issue: .unsatisfiedFinding
          )
        }
        let findingTextBytes = finding.explanation.utf8.count
        guard !finding.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw CleanupManifestReviewExportError.invalidEntry(
            index: index,
            issue: .emptyFindingExplanation
          )
        }
        guard findingTextBytes <= RuleCatalogLimits.maximumRuntimeFindingTextUTF8Bytes else {
          throw CleanupManifestReviewExportError.invalidEntry(
            index: index,
            issue: .findingTextTooLarge(
              maximumBytes: RuleCatalogLimits.maximumRuntimeFindingTextUTF8Bytes,
              actualBytes: findingTextBytes
            )
          )
        }
        reportTextBytes = try addingTextBytes(
          findingTextBytes,
          to: reportTextBytes
        )
      }

      guard findingsByIdentifier[identityFinding] != nil else {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .missingIdentityFinding
        )
      }
      for (identifier, expectedKind) in requiredCommonFindings {
        guard let finding = findingsByIdentifier[identifier] else {
          throw CleanupManifestReviewExportError.invalidEntry(
            index: index,
            issue: .missingRequiredFinding(identifier)
          )
        }
        guard finding.kind == expectedKind else {
          throw CleanupManifestReviewExportError.invalidEntry(
            index: index,
            issue: .requiredFindingKindMismatch(identifier)
          )
        }
      }
      guard
        entry.findings.contains(where: { finding in
          !automaticFindings.contains(finding.identifier)
            && finding.kind == .positiveEvidence
        })
      else {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .missingRulePositiveEvidence
        )
      }
      guard
        entry.findings.contains(where: { finding in
          !automaticFindings.contains(finding.identifier)
            && finding.kind == .exclusion
        })
      else {
        throw CleanupManifestReviewExportError.invalidEntry(
          index: index,
          issue: .missingRuleExclusion
        )
      }

      try totals.add(entry.size)
    }

    try totals.requireEqual(to: manifest.totals)
    try Task.checkCancellation()
  }

  private static func pathIssue(_ path: ScanRelativePath) -> CleanupPlanPathIssue? {
    guard path.rawComponents.count == 1 else {
      return .notTopLevel
    }
    let component = path.rawComponents[0]
    guard !component.isEmpty else {
      return .emptyComponent
    }
    guard component != [0x2E] else {
      return .currentDirectoryComponent
    }
    guard component != [0x2E, 0x2E] else {
      return .parentDirectoryComponent
    }
    guard !component.contains(0) else {
      return .containsNullByte
    }
    guard !component.contains(0x2F) else {
      return .containsPathSeparator
    }
    guard component.count <= CleanupPlanningLimits.maximumCandidateComponentBytes else {
      return .componentTooLong(
        maximum: CleanupPlanningLimits.maximumCandidateComponentBytes,
        actual: component.count
      )
    }
    return nil
  }

  private static func addingTextBytes(_ bytes: Int, to total: Int) throws -> Int {
    let (sum, overflow) = total.addingReportingOverflow(bytes)
    guard !overflow, sum <= RuleCatalogLimits.maximumTotalReportTextUTF8Bytes else {
      throw CleanupManifestReviewExportError.reportTextTooLarge(
        maximumBytes: RuleCatalogLimits.maximumTotalReportTextUTF8Bytes,
        actualBytes: overflow ? Int.max : sum
      )
    }
    return sum
  }

  private static func addingMetadataBytes(
    _ bytes: Int,
    to total: Int,
    entryIndex: Int
  ) throws -> Int {
    let (sum, overflow) = total.addingReportingOverflow(bytes)
    guard !overflow, sum <= RuleCatalogLimits.maximumEvaluationMetadataUTF8Bytes else {
      throw CleanupManifestReviewExportError.invalidEntry(
        index: entryIndex,
        issue: .metadataTooLarge(
          maximumBytes: RuleCatalogLimits.maximumEvaluationMetadataUTF8Bytes,
          actualBytes: overflow ? Int.max : sum
        )
      )
    }
    return sum
  }

  private static func checkIdentifier(_ rawValue: String) -> CheckIdentifier {
    guard let identifier = CheckIdentifier(rawValue: rawValue) else {
      preconditionFailure("Invalid manifest review check identifier")
    }
    return identifier
  }
}

private struct MutableReviewTotals {
  var observedLogicalBytes: UInt64 = 0
  var observedAllocatedBytes: UInt64 = 0
  var observedHardLinkExclusiveAllocatedBytes: UInt64 = 0
  var possibleSharedContentFileCount: UInt64 = 0
  var sharedContentMetadataUnavailableCount: UInt64 = 0
  var unobservedHardLinkFileCount: UInt64 = 0
  var nonExclusiveHardLinkFileCount: UInt64 = 0

  mutating func add(_ size: CleanupManifestSizeObservation) throws {
    try add(size.observedLogicalBytes, to: &observedLogicalBytes, metric: .observedLogicalBytes)
    try add(
      size.observedAllocatedBytes,
      to: &observedAllocatedBytes,
      metric: .observedAllocatedBytes
    )
    try add(
      size.observedHardLinkExclusiveAllocatedBytes,
      to: &observedHardLinkExclusiveAllocatedBytes,
      metric: .observedHardLinkExclusiveAllocatedBytes
    )
    try add(
      size.possibleSharedContentFileCount,
      to: &possibleSharedContentFileCount,
      metric: .possibleSharedContentFileCount
    )
    try add(
      size.sharedContentMetadataUnavailableCount,
      to: &sharedContentMetadataUnavailableCount,
      metric: .sharedContentMetadataUnavailableCount
    )
    try add(
      size.unobservedHardLinkFileCount,
      to: &unobservedHardLinkFileCount,
      metric: .unobservedHardLinkFileCount
    )
    try add(
      size.nonExclusiveHardLinkFileCount,
      to: &nonExclusiveHardLinkFileCount,
      metric: .nonExclusiveHardLinkFileCount
    )
  }

  func requireEqual(to totals: CleanupManifestTotals) throws {
    try require(
      observedLogicalBytes == totals.observedLogicalBytes,
      metric: .observedLogicalBytes
    )
    try require(
      observedAllocatedBytes == totals.observedAllocatedBytes,
      metric: .observedAllocatedBytes
    )
    try require(
      observedHardLinkExclusiveAllocatedBytes
        == totals.observedHardLinkExclusiveAllocatedBytes,
      metric: .observedHardLinkExclusiveAllocatedBytes
    )
    try require(
      possibleSharedContentFileCount == totals.possibleSharedContentFileCount,
      metric: .possibleSharedContentFileCount
    )
    try require(
      sharedContentMetadataUnavailableCount
        == totals.sharedContentMetadataUnavailableCount,
      metric: .sharedContentMetadataUnavailableCount
    )
    try require(
      unobservedHardLinkFileCount == totals.unobservedHardLinkFileCount,
      metric: .unobservedHardLinkFileCount
    )
    try require(
      nonExclusiveHardLinkFileCount == totals.nonExclusiveHardLinkFileCount,
      metric: .nonExclusiveHardLinkFileCount
    )
  }

  private func add(
    _ value: UInt64,
    to total: inout UInt64,
    metric: CleanupSizeMetric
  ) throws {
    let (sum, overflow) = total.addingReportingOverflow(value)
    guard !overflow else {
      throw CleanupManifestReviewExportError.totalOverflow(metric)
    }
    total = sum
  }

  private func require(_ condition: Bool, metric: CleanupSizeMetric) throws {
    guard condition else {
      throw CleanupManifestReviewExportError.inconsistentTotals(metric)
    }
  }
}

private struct CleanupManifestReviewJSONDocumentV2: Encodable, Sendable {
  let schema = CleanupManifestReviewOutputContract.schema
  let schemaVersion = CleanupManifestReviewOutputContract.schemaVersion
  let documentPurpose = "review-only"
  let executionAuthority = "none"
  let importSupported = false
  let canBeApproved = false
  let canBeExecuted = false
  let sourceManifestContractVersion: String
  let privacyProfile: String
  let sourceManifestRequiresExplicitApproval = true
  let sourceManifestRequiresExecutionRevalidation = true
  let disclosures: CleanupManifestReviewJSONDisclosuresV1
  let policy: CleanupManifestReviewJSONPolicyV1
  let classificationReferenceUnixSeconds: String?
  let summary: CleanupManifestReviewJSONSummaryV1
  let entries: [CleanupManifestReviewJSONEntryV2]

  init(
    manifest: CleanupManifest,
    privacyProfile: CleanupManifestReviewPrivacyProfile,
    projectedEntries: [CleanupManifestReviewJSONEntryV2]? = nil
  ) throws {
    try Task.checkCancellation()
    sourceManifestContractVersion = String(manifest.contractVersion)
    self.privacyProfile = privacyProfile.rawValue
    disclosures = CleanupManifestReviewJSONDisclosuresV1(privacyProfile: privacyProfile)
    var selectedRuleRevisions = Set<RuleRevision>()
    var generatedEntries: [CleanupManifestReviewJSONEntryV2] = []
    generatedEntries.reserveCapacity(projectedEntries == nil ? manifest.entries.count : 0)
    for (index, entry) in manifest.entries.enumerated() {
      try Task.checkCancellation()
      selectedRuleRevisions.insert(entry.ruleRevision)
      if projectedEntries == nil {
        generatedEntries.append(
          CleanupManifestReviewJSONEntryV2(
            entry: entry,
            index: index,
            privacyProfile: privacyProfile
          )
        )
      }
    }
    policy = CleanupManifestReviewJSONPolicyV1(
      provenance: manifest.policyProvenance,
      selectedRuleRevisions: selectedRuleRevisions,
      privacyProfile: privacyProfile
    )
    classificationReferenceUnixSeconds =
      privacyProfile == .rootRelativeExact
      ? String(manifest.classificationReferenceUnixSeconds) : nil
    summary = CleanupManifestReviewJSONSummaryV1(manifest: manifest)
    entries = projectedEntries ?? generatedEntries
    try Task.checkCancellation()
  }

  enum CodingKeys: String, CodingKey {
    case schema
    case schemaVersion
    case documentPurpose
    case executionAuthority
    case importSupported
    case canBeApproved
    case canBeExecuted
    case sourceManifestContractVersion
    case privacyProfile
    case sourceManifestRequiresExplicitApproval
    case sourceManifestRequiresExecutionRevalidation
    case disclosures
    case policy
    case classificationReferenceUnixSeconds
    case summary
    case entries
  }
}

private struct CleanupManifestReviewJSONDisclosuresV1: Encodable, Sendable {
  let absoluteRoot = "no-dedicated-field"
  let path: String
  let filesystemIdentity = "omitted"
  let referenceTime: String
  let explanatoryText: String
  let policyRuleRoster: String
  let policyIdentifiers = "included"
  let findingIdentifiers = "included"
  let toolUseMayBeInferred = true
  let quantities = "exact-observed"

  init(privacyProfile: CleanupManifestReviewPrivacyProfile) {
    switch privacyProfile {
    case .redacted:
      path = "document-ordinal"
      referenceTime = "omitted"
      explanatoryText = "omitted"
      policyRuleRoster = "selected-only"
    case .rootRelativeExact:
      path = "root-relative-exact"
      referenceTime = "exact"
      explanatoryText = "included"
      policyRuleRoster = "complete"
    }
  }

  enum CodingKeys: String, CodingKey {
    case absoluteRoot
    case path
    case filesystemIdentity
    case referenceTime
    case explanatoryText
    case policyRuleRoster
    case policyIdentifiers
    case findingIdentifiers
    case toolUseMayBeInferred
    case quantities
  }
}

private struct CleanupManifestReviewJSONPolicyV1: Encodable, Sendable {
  let classificationContractRevision: CleanupManifestReviewJSONRuleRevisionV1
  let catalogRevision: CleanupManifestReviewJSONRuleRevisionV1
  let ruleRevisionScope: String
  let disclosedRuleRevisions: [CleanupManifestReviewJSONRuleRevisionV1]

  init(
    provenance: RulePolicyProvenance,
    selectedRuleRevisions: Set<RuleRevision>,
    privacyProfile: CleanupManifestReviewPrivacyProfile
  ) {
    classificationContractRevision = CleanupManifestReviewJSONRuleRevisionV1(
      revision: provenance.classificationContractRevision
    )
    catalogRevision = CleanupManifestReviewJSONRuleRevisionV1(
      revision: provenance.catalogRevision
    )
    ruleRevisionScope =
      privacyProfile == .rootRelativeExact ? "complete" : "selected-only"
    let revisions =
      privacyProfile == .rootRelativeExact
      ? provenance.ruleRevisions : selectedRuleRevisions.sorted()
    disclosedRuleRevisions = revisions.map(CleanupManifestReviewJSONRuleRevisionV1.init)
  }

  enum CodingKeys: String, CodingKey {
    case classificationContractRevision
    case catalogRevision
    case ruleRevisionScope
    case disclosedRuleRevisions
  }
}

private struct CleanupManifestReviewJSONRuleRevisionV1: Encodable, Sendable {
  let identifier: String
  let version: String

  init(revision: RuleRevision) {
    identifier = revision.identifier.rawValue
    version = String(revision.version.rawValue)
  }

  enum CodingKeys: String, CodingKey {
    case identifier
    case version
  }
}

private struct CleanupManifestReviewJSONSummaryV1: Encodable, Sendable {
  let entryCount: String
  let totals: CleanupManifestReviewJSONSizeObservationV1

  init(manifest: CleanupManifest) {
    entryCount = String(manifest.entries.count)
    totals = CleanupManifestReviewJSONSizeObservationV1(totals: manifest.totals)
  }

  enum CodingKeys: String, CodingKey {
    case entryCount
    case totals
  }
}

private struct CleanupManifestReviewJSONEntryV2: Encodable, Sendable {
  let candidate: String
  let path: CleanupManifestReviewJSONPathV1?
  let expectedKind: String
  let ruleRevision: CleanupManifestReviewJSONRuleRevisionV1
  let disposition: String
  let reproducibility: String
  let deferredExecutionPreconditions: [CleanupManifestReviewJSONDeferredExecutionPreconditionV1]
  let displayName: String?
  let responsibleTool: String?
  let classificationExplanation: String?
  let findings: [CleanupManifestReviewJSONFindingV1]
  let size: CleanupManifestReviewJSONSizeObservationV1

  init(
    entry: CleanupManifestEntry,
    index: Int,
    privacyProfile: CleanupManifestReviewPrivacyProfile
  ) {
    candidate = Self.candidateIdentifier(index: index)
    path =
      privacyProfile == .rootRelativeExact
      ? CleanupManifestReviewJSONPathV1(path: entry.path) : nil
    expectedKind = entry.expectedKind.rawValue
    ruleRevision = CleanupManifestReviewJSONRuleRevisionV1(revision: entry.ruleRevision)
    disposition = entry.disposition.rawValue
    reproducibility = entry.reproducibility.rawValue
    deferredExecutionPreconditions = entry.deferredExecutionPreconditions.map(
      CleanupManifestReviewJSONDeferredExecutionPreconditionV1.init
    )
    displayName =
      privacyProfile == .rootRelativeExact ? TerminalText.escaped(entry.displayName) : nil
    responsibleTool =
      privacyProfile == .rootRelativeExact ? TerminalText.escaped(entry.responsibleTool) : nil
    classificationExplanation =
      privacyProfile == .rootRelativeExact
      ? TerminalText.escaped(entry.classificationExplanation) : nil
    findings = entry.findings.map { finding in
      CleanupManifestReviewJSONFindingV1(
        finding: finding,
        includeExplanation: privacyProfile == .rootRelativeExact
      )
    }
    size = CleanupManifestReviewJSONSizeObservationV1(size: entry.size)
  }

  private static func candidateIdentifier(index: Int) -> String {
    let number = String(index + 1)
    let padding = String(repeating: "0", count: max(0, 5 - number.count))
    return "candidate-\(padding)\(number)"
  }

  enum CodingKeys: String, CodingKey {
    case candidate
    case path
    case expectedKind
    case ruleRevision
    case disposition
    case reproducibility
    case deferredExecutionPreconditions
    case displayName
    case responsibleTool
    case classificationExplanation
    case findings
    case size
  }
}

private struct CleanupManifestReviewJSONDeferredExecutionPreconditionV1:
  Encodable, Sendable
{
  let identifier: String
  let policyRevision: String

  init(precondition: RuleDeferredExecutionPrecondition) {
    identifier = precondition.rawValue
    policyRevision = String(precondition.policyRevision)
  }

  enum CodingKeys: String, CodingKey {
    case identifier
    case policyRevision
  }
}

private struct CleanupManifestReviewJSONPathV1: Encodable, Sendable {
  let display: String
  let rawComponentsBase64: [String]

  init(path: ScanRelativePath) {
    display = path.rawComponents.map { bytes in
      guard let component = String(bytes: bytes, encoding: .utf8) else {
        return bytes.map { String(format: "\\x%02X", $0) }.joined()
      }
      return TerminalText.escaped(component)
    }.joined(separator: "/")
    rawComponentsBase64 = path.rawComponents.map { Data($0).base64EncodedString() }
  }

  enum CodingKeys: String, CodingKey {
    case display
    case rawComponentsBase64
  }
}

private struct CleanupManifestReviewJSONFindingV1: Encodable, Sendable {
  let identifier: String
  let kind: String
  let state: CleanupManifestReviewJSONFindingStateV1
  let explanation: String?

  init(finding: RuleFinding, includeExplanation: Bool) {
    identifier = finding.identifier.rawValue
    kind = finding.kind.rawValue
    state = CleanupManifestReviewJSONFindingStateV1(state: finding.state)
    explanation = includeExplanation ? TerminalText.escaped(finding.explanation) : nil
  }

  enum CodingKeys: String, CodingKey {
    case identifier
    case kind
    case state
    case explanation
  }
}

private struct CleanupManifestReviewJSONFindingStateV1: Encodable, Sendable {
  let status: String
  let reason: String?

  init(state: RuleFindingState) {
    switch state {
    case .satisfied:
      status = "satisfied"
      reason = nil
    case .failed:
      status = "failed"
      reason = nil
    case .unknown(let reason):
      status = "unknown"
      self.reason = reason.rawValue
    }
  }

  enum CodingKeys: String, CodingKey {
    case status
    case reason
  }
}

private struct CleanupManifestReviewJSONSizeObservationV1: Encodable, Sendable {
  let observedLogicalBytes: String
  let observedAllocatedBytes: String
  let observedHardLinkExclusiveAllocatedBytes: String
  let possibleSharedContentFileCount: String
  let sharedContentMetadataUnavailableCount: String
  let unobservedHardLinkFileCount: String
  let nonExclusiveHardLinkFileCount: String

  init(size: CleanupManifestSizeObservation) {
    observedLogicalBytes = String(size.observedLogicalBytes)
    observedAllocatedBytes = String(size.observedAllocatedBytes)
    observedHardLinkExclusiveAllocatedBytes = String(
      size.observedHardLinkExclusiveAllocatedBytes
    )
    possibleSharedContentFileCount = String(size.possibleSharedContentFileCount)
    sharedContentMetadataUnavailableCount = String(
      size.sharedContentMetadataUnavailableCount
    )
    unobservedHardLinkFileCount = String(size.unobservedHardLinkFileCount)
    nonExclusiveHardLinkFileCount = String(size.nonExclusiveHardLinkFileCount)
  }

  init(totals: CleanupManifestTotals) {
    observedLogicalBytes = String(totals.observedLogicalBytes)
    observedAllocatedBytes = String(totals.observedAllocatedBytes)
    observedHardLinkExclusiveAllocatedBytes = String(
      totals.observedHardLinkExclusiveAllocatedBytes
    )
    possibleSharedContentFileCount = String(totals.possibleSharedContentFileCount)
    sharedContentMetadataUnavailableCount = String(
      totals.sharedContentMetadataUnavailableCount
    )
    unobservedHardLinkFileCount = String(totals.unobservedHardLinkFileCount)
    nonExclusiveHardLinkFileCount = String(totals.nonExclusiveHardLinkFileCount)
  }

  enum CodingKeys: String, CodingKey {
    case observedLogicalBytes
    case observedAllocatedBytes
    case observedHardLinkExclusiveAllocatedBytes
    case possibleSharedContentFileCount
    case sharedContentMetadataUnavailableCount
    case unobservedHardLinkFileCount
    case nonExclusiveHardLinkFileCount
  }
}
