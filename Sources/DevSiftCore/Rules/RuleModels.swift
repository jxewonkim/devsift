import Foundation

public struct RuleIdentifier: RawRepresentable, Comparable, Hashable, Sendable {
  public let rawValue: String

  public init?(rawValue: String) {
    guard RuleIdentifier.isValid(rawValue) else {
      return nil
    }
    self.rawValue = rawValue
  }

  public static func < (left: RuleIdentifier, right: RuleIdentifier) -> Bool {
    left.rawValue < right.rawValue
  }

  private static func isValid(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard
      !bytes.isEmpty,
      bytes.count <= 128,
      bytes.allSatisfy({ byte in
        (0x61...0x7A).contains(byte)
          || (0x30...0x39).contains(byte)
          || byte == 0x2D
          || byte == 0x2E
      }),
      let first = bytes.first,
      let last = bytes.last,
      isASCIIAlphaNumeric(first),
      isASCIIAlphaNumeric(last)
    else {
      return false
    }

    return !zip(bytes, bytes.dropFirst()).contains { left, right in
      isSeparator(left) && isSeparator(right)
    }
  }

  private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
    (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
  }

  private static func isSeparator(_ byte: UInt8) -> Bool {
    byte == 0x2D || byte == 0x2E
  }
}

public struct CheckIdentifier: RawRepresentable, Comparable, Hashable, Sendable {
  public let rawValue: String

  public init?(rawValue: String) {
    guard let identifier = RuleIdentifier(rawValue: rawValue) else {
      return nil
    }
    self.rawValue = identifier.rawValue
  }

  public static func < (left: CheckIdentifier, right: CheckIdentifier) -> Bool {
    left.rawValue < right.rawValue
  }
}

public struct RuleVersion: RawRepresentable, Comparable, Hashable, Sendable {
  public let rawValue: UInt32

  public init?(rawValue: UInt32) {
    guard rawValue > 0 else {
      return nil
    }
    self.rawValue = rawValue
  }

  public static func < (left: RuleVersion, right: RuleVersion) -> Bool {
    left.rawValue < right.rawValue
  }
}

public struct RuleRevision: Comparable, Hashable, Sendable {
  public let identifier: RuleIdentifier
  public let version: RuleVersion

  public init(identifier: RuleIdentifier, version: RuleVersion) {
    self.identifier = identifier
    self.version = version
  }

  public static func < (left: RuleRevision, right: RuleRevision) -> Bool {
    if left.identifier != right.identifier {
      return left.identifier < right.identifier
    }
    return left.version < right.version
  }
}

public enum RuleDisposition: String, CaseIterable, Hashable, Sendable {
  case reclaimable
  case reviewRequired = "review-required"
  case protected
}

public enum RuleMatchState: String, CaseIterable, Hashable, Sendable {
  case matched
  case possibleMatch = "possible-match"
  case unrecognized
  case conflict
  case invalidRule = "invalid-rule"
}

public enum RuleReproducibility: String, CaseIterable, Hashable, Sendable {
  case reproducible
  case conditional
  case unknown
}

public enum RuleAgeRequirement: Hashable, Sendable {
  case notRequired
  case minimumSeconds(UInt64)
}

public enum RuleActivityRequirement: String, CaseIterable, Hashable, Sendable {
  case notRequired = "not-required"
  case mustBeInactive = "must-be-inactive"
}

public enum RuleUnknownReason: String, CaseIterable, Hashable, Sendable {
  case notCollected = "not-collected"
  case unsupported
  case permissionDenied = "permission-denied"
  case incompleteScan = "incomplete-scan"
  case changedDuringObservation = "changed-during-observation"
  case resourceLimit = "resource-limit"
  case clockSkew = "clock-skew"
  case invalidMetadata = "invalid-metadata"
  case unspecified
}

public enum RuleObserved<Value: Hashable & Sendable>: Hashable, Sendable {
  case known(Value)
  case unknown(RuleUnknownReason)
}

public enum RuleActivityState: String, CaseIterable, Hashable, Sendable {
  case active
  case inactive
}

public enum RuleCheckKind: String, CaseIterable, Hashable, Sendable {
  case positiveEvidence = "positive-evidence"
  case exclusion
}

public struct RuleCheckDefinition: Hashable, Sendable {
  public let identifier: CheckIdentifier
  public let kind: RuleCheckKind
  public let explanation: String

  public init(identifier: CheckIdentifier, kind: RuleCheckKind, explanation: String) {
    self.identifier = identifier
    self.kind = kind
    self.explanation = explanation
  }
}

public struct RuleDefinition: Hashable, Sendable {
  public let revision: RuleRevision
  public let displayName: String
  public let responsibleTool: String
  public let recognitionExplanation: String
  public let eligibleDisposition: RuleDisposition
  public let reproducibility: RuleReproducibility
  public let ageRequirement: RuleAgeRequirement
  public let activityRequirement: RuleActivityRequirement
  public let checks: [RuleCheckDefinition]

  public init(
    revision: RuleRevision,
    displayName: String,
    responsibleTool: String,
    recognitionExplanation: String,
    eligibleDisposition: RuleDisposition,
    reproducibility: RuleReproducibility,
    ageRequirement: RuleAgeRequirement,
    activityRequirement: RuleActivityRequirement,
    checks: [RuleCheckDefinition]
  ) {
    self.revision = revision
    self.displayName = displayName
    self.responsibleTool = responsibleTool
    self.recognitionExplanation = recognitionExplanation
    self.eligibleDisposition = eligibleDisposition
    self.reproducibility = reproducibility
    self.ageRequirement = ageRequirement
    self.activityRequirement = activityRequirement
    self.checks = checks
  }
}

public enum RuleFindingKind: String, CaseIterable, Hashable, Sendable {
  case lexicalRecognition = "lexical-recognition"
  case positiveEvidence = "positive-evidence"
  case exclusion
  case reproducibility
  case age
  case activity
  case scanIntegrity = "scan-integrity"
  case conflict
  case ruleValidity = "rule-validity"
}

public enum RuleFindingState: Hashable, Sendable {
  case satisfied
  case failed
  case unknown(RuleUnknownReason)
}

public struct RuleFinding: Hashable, Sendable {
  public let identifier: CheckIdentifier
  public let kind: RuleFindingKind
  public let state: RuleFindingState
  public let explanation: String

  public init(
    identifier: CheckIdentifier,
    kind: RuleFindingKind,
    state: RuleFindingState,
    explanation: String
  ) {
    self.identifier = identifier
    self.kind = kind
    self.state = state
    self.explanation = explanation
  }
}

public enum RuleLexicalRecognition: Hashable, Sendable {
  case recognized
  case unrecognized
}

public struct RuleAssessment: Hashable, Sendable {
  public let recognition: RuleLexicalRecognition
  public let findings: [RuleFinding]

  public init(recognition: RuleLexicalRecognition, findings: [RuleFinding]) {
    self.recognition = recognition
    self.findings = findings
  }
}

public struct RuleScanIntegrity: Hashable, Sendable {
  public let reportIsComplete: Bool
  public let itemIsComplete: Bool
  public let topLevelItemsWereSuppressed: Bool
  public let traversalDetailsWereDiscarded: Bool
  public let suppressedIssueCount: UInt64
  public let unknownAllocatedItemCount: UInt64
  public let sizeOverflowed: Bool
  public let hardLinkAccountingIsComplete: Bool

  public init(
    reportIsComplete: Bool,
    itemIsComplete: Bool,
    topLevelItemsWereSuppressed: Bool,
    traversalDetailsWereDiscarded: Bool,
    suppressedIssueCount: UInt64,
    unknownAllocatedItemCount: UInt64,
    sizeOverflowed: Bool,
    hardLinkAccountingIsComplete: Bool
  ) {
    self.reportIsComplete = reportIsComplete
    self.itemIsComplete = itemIsComplete
    self.topLevelItemsWereSuppressed = topLevelItemsWereSuppressed
    self.traversalDetailsWereDiscarded = traversalDetailsWereDiscarded
    self.suppressedIssueCount = suppressedIssueCount
    self.unknownAllocatedItemCount = unknownAllocatedItemCount
    self.sizeOverflowed = sizeOverflowed
    self.hardLinkAccountingIsComplete = hardLinkAccountingIsComplete
  }
}

public struct RuleObservationFacts: Hashable, Sendable {
  public let trustedLocation: RuleObserved<Bool>
  public let toolOwnership: RuleObserved<Bool>
  public let generatedContentMarker: RuleObserved<Bool>
  public let newestContentModificationUnixSeconds: RuleObserved<Int64>
  public let activity: RuleObserved<RuleActivityState>
  public let protectedDescendantPresent: RuleObserved<Bool>
  public let siblingPackageManifestPresent: RuleObserved<Bool>

  public init(
    trustedLocation: RuleObserved<Bool> = .unknown(.notCollected),
    toolOwnership: RuleObserved<Bool> = .unknown(.notCollected),
    generatedContentMarker: RuleObserved<Bool> = .unknown(.notCollected),
    newestContentModificationUnixSeconds: RuleObserved<Int64> = .unknown(.notCollected),
    activity: RuleObserved<RuleActivityState> = .unknown(.notCollected),
    protectedDescendantPresent: RuleObserved<Bool> = .unknown(.notCollected),
    siblingPackageManifestPresent: RuleObserved<Bool> = .unknown(.notCollected)
  ) {
    self.trustedLocation = trustedLocation
    self.toolOwnership = toolOwnership
    self.generatedContentMarker = generatedContentMarker
    self.newestContentModificationUnixSeconds = newestContentModificationUnixSeconds
    self.activity = activity
    self.protectedDescendantPresent = protectedDescendantPresent
    self.siblingPackageManifestPresent = siblingPackageManifestPresent
  }
}

public struct RuleObservation: Hashable, Sendable {
  public let summary: ScanItemSummary
  public let selectedRootBasename: RuleObserved<[UInt8]>
  public let integrity: RuleScanIntegrity
  public let facts: RuleObservationFacts

  public init(
    summary: ScanItemSummary,
    selectedRootBasename: RuleObserved<[UInt8]>,
    integrity: RuleScanIntegrity,
    facts: RuleObservationFacts
  ) {
    self.summary = summary
    self.selectedRootBasename = selectedRootBasename
    self.integrity = integrity
    self.facts = facts
  }
}

public struct RuleEvaluation: Hashable, Sendable {
  public let path: ScanRelativePath
  public let rule: RuleRevision?
  public let matchingRules: [RuleRevision]
  public let displayName: String
  public let responsibleTool: String
  public let matchState: RuleMatchState
  public let disposition: RuleDisposition
  public let reproducibility: RuleReproducibility
  public let findings: [RuleFinding]
  public let explanation: String
}

public struct RuleClassificationRequest: Hashable, Sendable {
  public let root: URL
  public let report: ScanReport
  public let referenceUnixSeconds: Int64

  public init(root: URL, report: ScanReport, referenceUnixSeconds: Int64) {
    self.root = root
    self.report = report
    self.referenceUnixSeconds = referenceUnixSeconds
  }
}

public struct RuleClassificationReport: Hashable, Sendable {
  public let referenceUnixSeconds: Int64
  public let evaluations: [RuleEvaluation]

  public init(referenceUnixSeconds: Int64, evaluations: [RuleEvaluation]) {
    self.referenceUnixSeconds = referenceUnixSeconds
    self.evaluations = evaluations
  }
}

public enum RuleCatalogLimits {
  public static let maximumRules = 128
  public static let maximumChecksPerRule = 64
  public static let maximumObservations = 50_000
  public static let maximumDefinitionTextUTF8Bytes = 1_024
  public static let maximumRuntimeFindingsPerRule = 64
  public static let maximumRuntimeFindingTextUTF8Bytes = 1_024
  public static let maximumFindingsPerEvaluation = 80
  public static let maximumTotalEvaluationFindings = 1_000_000
  public static let maximumEvaluationMetadataUTF8Bytes = 4_096
  public static let maximumTotalReportTextUTF8Bytes = 64 * 1_024 * 1_024
}

public enum RuleClassificationError: Error, Equatable, Sendable {
  case tooManyObservations(maximum: Int, actual: Int)
}

public enum RuleEvaluationMetadataField: String, CaseIterable, Hashable, Sendable {
  case displayName = "display-name"
  case responsibleTool = "responsible-tool"
  case explanation
}

public enum RuleEvaluationInvariant: String, CaseIterable, Hashable, Sendable {
  case matchedDisposition = "matched-disposition"
  case matchedRuleIdentity = "matched-rule-identity"
  case matchedFindings = "matched-findings"
  case reclaimableReproducibility = "reclaimable-reproducibility"
  case protectedDisposition = "protected-disposition"
  case possibleMatchRuleIdentity = "possible-match-rule-identity"
  case unrecognizedRuleIdentity = "unrecognized-rule-identity"
  case conflictRuleIdentity = "conflict-rule-identity"
  case conflictDiagnostic = "conflict-diagnostic"
  case invalidRuleIdentity = "invalid-rule-identity"
  case invalidRuleDiagnostic = "invalid-rule-diagnostic"
  case blockingFinding = "blocking-finding"
  case duplicateObservationDecision = "duplicate-observation-decision"
}

public enum RuleClassificationReportValidationError: Error, Equatable, Sendable {
  case referenceTimeMismatch(expected: Int64, actual: Int64)
  case tooManyInputItems(maximum: Int, actual: Int)
  case tooManyEvaluations(maximum: Int, actual: Int)
  case inputPathIsNotTopLevel(ScanRelativePath)
  case missingEvaluation(ScanRelativePath)
  case extraEvaluation(ScanRelativePath)
  case duplicateEvaluation(ScanRelativePath)
  case evaluationsOutOfOrder(previous: ScanRelativePath, current: ScanRelativePath)
  case tooManyMatchingRules(path: ScanRelativePath, maximum: Int, actual: Int)
  case matchingRulesNotSortedAndUnique(ScanRelativePath)
  case emptyMetadata(path: ScanRelativePath, field: RuleEvaluationMetadataField)
  case metadataTooLarge(path: ScanRelativePath, maximumBytes: Int, actualBytes: Int)
  case tooManyFindings(path: ScanRelativePath, maximum: Int, actual: Int)
  case tooManyTotalFindings(maximum: Int, actual: Int)
  case emptyFindingExplanation(path: ScanRelativePath, finding: CheckIdentifier)
  case findingTextTooLong(
    path: ScanRelativePath,
    finding: CheckIdentifier,
    maximumBytes: Int,
    actualBytes: Int
  )
  case totalReportTextTooLong(maximumBytes: Int)
  case duplicateFindingIdentifier(path: ScanRelativePath, finding: CheckIdentifier)
  case missingCommonFinding(path: ScanRelativePath, finding: CheckIdentifier)
  case commonFindingKindMismatch(
    path: ScanRelativePath,
    finding: CheckIdentifier,
    expected: RuleFindingKind,
    actual: RuleFindingKind
  )
  case commonFindingStateMismatch(
    path: ScanRelativePath,
    finding: CheckIdentifier,
    expected: RuleFindingState,
    actual: RuleFindingState
  )
  case semanticInvariant(path: ScanRelativePath, invariant: RuleEvaluationInvariant)
}

public protocol RuleClassifying: Sendable {
  /// Custom implementations are trusted in-process code. Consumers should
  /// validate returned reports against the request before presenting them.
  func classify(_ request: RuleClassificationRequest) async throws -> RuleClassificationReport
}

public protocol ExplainableRule: Sendable {
  var definition: RuleDefinition { get }

  /// Performs only deterministic recognition and fact projection.
  /// Implementations do not receive a URL or filesystem capability. Custom
  /// implementations are trusted in-process code; result bounds cannot stop a
  /// rule that does not return from this method.
  func assess(_ observation: RuleObservation) -> RuleAssessment
}

public enum RuleCatalogValidationError: Error, Equatable, Sendable {
  case tooManyRules(maximum: Int, actual: Int)
  case tooManyChecks(rule: RuleIdentifier, maximum: Int, actual: Int)
  case definitionTextTooLong(rule: RuleIdentifier, field: String, maximumBytes: Int)
  case duplicateRuleIdentifier(RuleIdentifier)
  case duplicateCheckIdentifier(rule: RuleIdentifier, check: CheckIdentifier)
  case reservedCheckIdentifier(rule: RuleIdentifier, check: CheckIdentifier)
  case missingPositiveEvidence(RuleIdentifier)
  case emptyDefinitionField(rule: RuleIdentifier, field: String)
  case invalidEligibleDisposition(RuleIdentifier)
  case reclaimableRuleIsNotReproducible(RuleIdentifier)
  case reclaimableRuleRequiresMinimumAge(RuleIdentifier)
  case reclaimableRuleRequiresInactiveCheck(RuleIdentifier)
  case missingExclusion(RuleIdentifier)
  case zeroMinimumAge(RuleIdentifier)
}
