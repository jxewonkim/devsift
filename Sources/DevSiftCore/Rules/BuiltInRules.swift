public enum BuiltInRuleCatalog {
  public static let rules: [any ExplainableRule] = [
    BuiltInRule(
      definition: definition(
        id: "devsift.cache.uv",
        name: "uv cache",
        tool: "uv",
        recognition: "The candidate raw name must be exactly `uv`.",
        disposition: .reclaimable
      ),
      recognition: .exactName(Array("uv".utf8))
    ),
    BuiltInRule(
      definition: definition(
        id: "devsift.cache.npm",
        name: "npm content cache",
        tool: "npm",
        recognition: "The candidate raw name must be exactly `_cacache`.",
        disposition: .reviewRequired
      ),
      recognition: .exactName(Array("_cacache".utf8))
    ),
    BuiltInRule(
      definition: definition(
        id: "devsift.cache.homebrew",
        name: "Homebrew cache",
        tool: "Homebrew",
        recognition: "The candidate raw name must be exactly `Homebrew`.",
        disposition: .reviewRequired
      ),
      recognition: .exactName(Array("Homebrew".utf8))
    ),
    BuiltInRule(
      definition: definition(
        id: "devsift.xcode.derived-data",
        name: "Xcode DerivedData",
        tool: "Xcode",
        recognition: "The candidate raw name must be exactly `DerivedData`.",
        disposition: .reviewRequired
      ),
      recognition: .exactName(Array("DerivedData".utf8))
    ),
    BuiltInRule(
      definition: definition(
        id: "devsift.swiftpm.build",
        name: "SwiftPM build output",
        tool: "Swift Package Manager",
        recognition: "The candidate raw name must be exactly `.build`.",
        disposition: .reviewRequired,
        version: 2,
        includesPackageManifestCheck: true
      ),
      recognition: .exactName(Array(".build".utf8))
    ),
    BuiltInRule(
      definition: definition(
        id: "devsift.xcode.ios-device-support",
        name: "iOS DeviceSupport version",
        tool: "Xcode",
        recognition:
          "The selected root raw name must be exactly `iOS DeviceSupport` and the child must have a version-like raw name.",
        disposition: .reviewRequired,
        minimumAgeSeconds: 30 * 24 * 60 * 60
      ),
      recognition: .iosDeviceSupportVersion
    ),
  ]

  private static func definition(
    id: String,
    name: String,
    tool: String,
    recognition: String,
    disposition: RuleDisposition,
    version: UInt32 = 1,
    minimumAgeSeconds: UInt64 = 7 * 24 * 60 * 60,
    includesPackageManifestCheck: Bool = false
  ) -> RuleDefinition {
    var checks = [
      RuleCheckDefinition(
        identifier: BuiltInCheckIdentifier.candidateDirectory,
        kind: .positiveEvidence,
        explanation: "The candidate itself is an observed directory."
      ),
      RuleCheckDefinition(
        identifier: BuiltInCheckIdentifier.trustedLocation,
        kind: .positiveEvidence,
        explanation: "The location is a trusted container for this tool."
      ),
      RuleCheckDefinition(
        identifier: BuiltInCheckIdentifier.toolOwnership,
        kind: .positiveEvidence,
        explanation: "The observed item is owned by the responsible tool workflow."
      ),
      RuleCheckDefinition(
        identifier: BuiltInCheckIdentifier.generatedMarker,
        kind: .positiveEvidence,
        explanation: "A generated-content marker identifies reproducible output."
      ),
    ]
    if includesPackageManifestCheck {
      checks.append(
        RuleCheckDefinition(
          identifier: BuiltInCheckIdentifier.packageManifestSibling,
          kind: .positiveEvidence,
          explanation: "An exact raw `Package.swift` sibling identifies a Swift package root."
        )
      )
    }
    checks.append(
      RuleCheckDefinition(
        identifier: BuiltInCheckIdentifier.noProtectedDescendants,
        kind: .exclusion,
        explanation: "No protected descendant is present in the candidate scope."
      )
    )

    return RuleDefinition(
      revision: RuleRevision(
        identifier: makeRuleIdentifier(id),
        version: makeRuleVersion(version)
      ),
      displayName: name,
      responsibleTool: tool,
      recognitionExplanation: recognition,
      eligibleDisposition: disposition,
      reproducibility: disposition == .reclaimable ? .reproducible : .conditional,
      ageRequirement: .minimumSeconds(minimumAgeSeconds),
      activityRequirement: .mustBeInactive,
      checks: checks
    )
  }
}

private struct BuiltInRule: ExplainableRule {
  let definition: RuleDefinition
  let recognition: BuiltInRecognition

  func assess(_ observation: RuleObservation) -> RuleAssessment {
    let lexicalRecognition: RuleLexicalRecognition =
      recognition.matches(observation) ? .recognized : .unrecognized

    let findings = definition.checks.map { check in
      switch check.identifier {
      case BuiltInCheckIdentifier.candidateDirectory:
        positiveFinding(
          check,
          observation: .known(observation.summary.kind == .directory)
        )
      case BuiltInCheckIdentifier.trustedLocation:
        positiveFinding(check, observation: observation.facts.trustedLocation)
      case BuiltInCheckIdentifier.toolOwnership:
        positiveFinding(check, observation: observation.facts.toolOwnership)
      case BuiltInCheckIdentifier.generatedMarker:
        positiveFinding(check, observation: observation.facts.generatedContentMarker)
      case BuiltInCheckIdentifier.packageManifestSibling:
        positiveFinding(
          check,
          observation: observation.facts.siblingPackageManifestPresent
        )
      case BuiltInCheckIdentifier.noProtectedDescendants:
        exclusionFinding(
          check,
          protectedDescendant: observation.facts.protectedDescendantPresent
        )
      default:
        RuleFinding(
          identifier: check.identifier,
          kind: findingKind(for: check.kind),
          state: .unknown(.unspecified),
          explanation: check.explanation
        )
      }
    }

    return RuleAssessment(recognition: lexicalRecognition, findings: findings)
  }

  private func positiveFinding(
    _ check: RuleCheckDefinition,
    observation: RuleObserved<Bool>
  ) -> RuleFinding {
    RuleFinding(
      identifier: check.identifier,
      kind: .positiveEvidence,
      state: stateRequiringTrue(observation),
      explanation: check.explanation
    )
  }

  private func exclusionFinding(
    _ check: RuleCheckDefinition,
    protectedDescendant: RuleObserved<Bool>
  ) -> RuleFinding {
    let state: RuleFindingState
    switch protectedDescendant {
    case .known(false):
      state = .satisfied
    case .known(true):
      state = .failed
    case .unknown(let reason):
      state = .unknown(reason)
    }
    return RuleFinding(
      identifier: check.identifier,
      kind: .exclusion,
      state: state,
      explanation: check.explanation
    )
  }

  private func stateRequiringTrue(_ observation: RuleObserved<Bool>) -> RuleFindingState {
    switch observation {
    case .known(true):
      .satisfied
    case .known(false):
      .failed
    case .unknown(let reason):
      .unknown(reason)
    }
  }

  private func findingKind(for kind: RuleCheckKind) -> RuleFindingKind {
    kind == .positiveEvidence ? .positiveEvidence : .exclusion
  }
}

private enum BuiltInRecognition: Sendable {
  case exactName([UInt8])
  case iosDeviceSupportVersion

  func matches(_ observation: RuleObservation) -> Bool {
    guard observation.summary.path.rawComponents.count == 1 else {
      return false
    }

    switch self {
    case .exactName(let expectedName):
      return observation.summary.path.rawComponents[0] == expectedName
    case .iosDeviceSupportVersion:
      guard
        observation.selectedRootBasename
          == .known(Array("iOS DeviceSupport".utf8))
      else {
        return false
      }
      return isVersionLike(observation.summary.path.rawComponents[0])
    }
  }

  private func isVersionLike(_ bytes: [UInt8]) -> Bool {
    var index = bytes.startIndex

    guard consumeDigits(in: bytes, index: &index), consume(0x2E, in: bytes, index: &index),
      consumeDigits(in: bytes, index: &index)
    else {
      return false
    }

    if consume(0x2E, in: bytes, index: &index), !consumeDigits(in: bytes, index: &index) {
      return false
    }
    if index == bytes.endIndex {
      return true
    }

    guard
      consume(0x20, in: bytes, index: &index),
      consume(0x28, in: bytes, index: &index)
    else {
      return false
    }
    let buildStart = index
    while index < bytes.endIndex, bytes[index] != 0x29 {
      let byte = bytes[index]
      guard
        (0x30...0x39).contains(byte)
          || (0x41...0x5A).contains(byte)
          || (0x61...0x7A).contains(byte)
          || byte == 0x2D
          || byte == 0x2E
      else {
        return false
      }
      index = bytes.index(after: index)
    }
    guard index > buildStart, consume(0x29, in: bytes, index: &index) else {
      return false
    }
    return index == bytes.endIndex
  }

  private func consumeDigits(in bytes: [UInt8], index: inout Int) -> Bool {
    let start = index
    while index < bytes.endIndex, (0x30...0x39).contains(bytes[index]) {
      index = bytes.index(after: index)
    }
    return index > start
  }

  private func consume(_ byte: UInt8, in bytes: [UInt8], index: inout Int) -> Bool {
    guard index < bytes.endIndex, bytes[index] == byte else {
      return false
    }
    index = bytes.index(after: index)
    return true
  }
}

private enum BuiltInCheckIdentifier {
  static let candidateDirectory = makeCheckIdentifier("candidate-directory")
  static let trustedLocation = makeCheckIdentifier("trusted-location")
  static let toolOwnership = makeCheckIdentifier("tool-ownership")
  static let generatedMarker = makeCheckIdentifier("generated-content-marker")
  static let packageManifestSibling = makeCheckIdentifier("package-manifest-sibling")
  static let noProtectedDescendants = makeCheckIdentifier("no-protected-descendants")
}
