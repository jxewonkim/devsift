import Darwin
import Foundation

struct CandidateRuleEvidence: Hashable, Sendable {
  let identityMatchesScan: RuleObserved<Bool>
  let trustedLocation: RuleObserved<Bool>
  let generatedContentMarker: RuleObserved<Bool>

  static func unavailable(
    _ reason: RuleUnknownReason,
    for item: ScanItemSummary
  ) -> CandidateRuleEvidence {
    CandidateRuleEvidence(
      identityMatchesScan: .unknown(reason),
      trustedLocation: BuiltInTrustedLocationPolicy.containerSuffix(for: item.path) == nil
        ? .unknown(.notCollected) : .unknown(reason),
      generatedContentMarker: BuiltInGeneratedMarkerPolicy.policy(for: item.path) == nil
        ? .unknown(.notCollected) : .unknown(reason)
    )
  }

  func replacingTrustedLocation(
    _ observation: RuleObserved<Bool>
  ) -> CandidateRuleEvidence {
    CandidateRuleEvidence(
      identityMatchesScan: identityMatchesScan,
      trustedLocation: observation,
      generatedContentMarker: generatedContentMarker
    )
  }
}

/// The deliberately small set of default cache-container locations whose raw
/// path and descriptor ancestry Core currently knows how to verify.
enum BuiltInTrustedLocationPolicy {
  private static let uvName = Array("uv".utf8)
  private static let npmContentCacheName = Array("_cacache".utf8)
  private static let homebrewName = Array("Homebrew".utf8)

  private static let dotCache = [Array(".cache".utf8)]
  private static let dotNPM = [Array(".npm".utf8)]
  private static let libraryCaches = [Array("Library".utf8), Array("Caches".utf8)]

  static func containerSuffix(for path: ScanRelativePath) -> [[UInt8]]? {
    guard path.rawComponents.count == 1, let name = path.rawComponents.first else {
      return nil
    }
    if name == uvName {
      return dotCache
    }
    if name == npmContentCacheName {
      return dotNPM
    }
    if name == homebrewName {
      return libraryCaches
    }
    return nil
  }
}

private enum BuiltInGeneratedMarkerPolicy {
  case npmCACacheLayout
  case swiftPMWorkspaceState

  private static let npmContentCacheName = Array("_cacache".utf8)
  private static let swiftBuildName = Array(".build".utf8)

  static func policy(for path: ScanRelativePath) -> BuiltInGeneratedMarkerPolicy? {
    guard path.rawComponents.count == 1, let name = path.rawComponents.first else {
      return nil
    }
    if name == npmContentCacheName {
      return .npmCACacheLayout
    }
    if name == swiftBuildName {
      return .swiftPMWorkspaceState
    }
    return nil
  }

  var requirements: [GeneratedMarkerRequirement] {
    switch self {
    case .npmCACacheLayout:
      [
        GeneratedMarkerRequirement(
          rawName: Array("content-v2".utf8),
          expectedKind: .directory
        ),
        GeneratedMarkerRequirement(
          rawName: Array("index-v5".utf8),
          expectedKind: .directory
        ),
      ]
    case .swiftPMWorkspaceState:
      [
        GeneratedMarkerRequirement(
          rawName: Array("workspace-state.json".utf8),
          expectedKind: .regularFile
        )
      ]
    }
  }
}

private struct GeneratedMarkerRequirement {
  let rawName: [UInt8]
  let expectedKind: FileSystemEntryKind
}

/// Candidate evidence has the same count and index ordering as the source
/// `ScanReport.topLevelItems`. It deliberately is not keyed by a display path.
struct RuleEvidenceObservation: Hashable, Sendable {
  let candidates: [CandidateRuleEvidence]
}

protocol RuleEvidenceObserving: Sendable {
  func observe(_ request: RuleClassificationRequest) async throws -> RuleEvidenceObservation
}

/// Performs a bounded, read-only, descriptor-relative reobservation.
///
/// The result is a point-in-time classification input, never authority for a
/// later filesystem mutation.
struct DescriptorRuleEvidenceObserver: RuleEvidenceObserving, Sendable {
  typealias Checkpoint = @Sendable () throws -> Void
  typealias RootHook = @Sendable () throws -> Void
  typealias CandidateHook = @Sendable (ScanRelativePath) throws -> Void
  typealias RawHomeProvider = @Sendable () -> RuleObserved<[UInt8]>

  private static let maximumGeneratedMarkerEntries = 256

  private let checkpoint: Checkpoint
  private let rawHomeProvider: RawHomeProvider
  private let afterRootValidation: RootHook
  private let beforeOpeningCandidate: CandidateHook
  private let beforeMarkerObservation: CandidateHook
  private let beforeMarkerMetadataValidation: CandidateHook
  private let beforeFinalCandidateValidation: CandidateHook
  private let beforeFinalLocationValidation: RootHook
  private let beforeFinalRootValidation: RootHook

  init() {
    checkpoint = { try Task.checkCancellation() }
    rawHomeProvider = { currentUIDRawHome() }
    afterRootValidation = {}
    beforeOpeningCandidate = { _ in }
    beforeMarkerObservation = { _ in }
    beforeMarkerMetadataValidation = { _ in }
    beforeFinalCandidateValidation = { _ in }
    beforeFinalLocationValidation = {}
    beforeFinalRootValidation = {}
  }

  init(
    checkpoint: @escaping Checkpoint = { try Task.checkCancellation() },
    rawHomeProvider: @escaping RawHomeProvider = { currentUIDRawHome() },
    afterRootValidation: @escaping RootHook = {},
    beforeOpeningCandidate: @escaping CandidateHook = { _ in },
    beforeMarkerObservation: @escaping CandidateHook = { _ in },
    beforeMarkerMetadataValidation: @escaping CandidateHook = { _ in },
    beforeFinalCandidateValidation: @escaping CandidateHook = { _ in },
    beforeFinalLocationValidation: @escaping RootHook = {},
    beforeFinalRootValidation: @escaping RootHook = {}
  ) {
    self.checkpoint = checkpoint
    self.rawHomeProvider = rawHomeProvider
    self.afterRootValidation = afterRootValidation
    self.beforeOpeningCandidate = beforeOpeningCandidate
    self.beforeMarkerObservation = beforeMarkerObservation
    self.beforeMarkerMetadataValidation = beforeMarkerMetadataValidation
    self.beforeFinalCandidateValidation = beforeFinalCandidateValidation
    self.beforeFinalLocationValidation = beforeFinalLocationValidation
    self.beforeFinalRootValidation = beforeFinalRootValidation
  }

  func observe(_ request: RuleClassificationRequest) async throws -> RuleEvidenceObservation {
    let priority = Task.currentPriority
    let worker = Task.detached(priority: priority) {
      try observeOnWorker(request)
    }

    return try await withTaskCancellationHandler {
      do {
        let observation = try await worker.value
        try Task.checkCancellation()
        return observation
      } catch {
        try Task.checkCancellation()
        throw error
      }
    } onCancel: {
      worker.cancel()
    }
  }

  private func observeOnWorker(
    _ request: RuleClassificationRequest
  ) throws -> RuleEvidenceObservation {
    try cancellationCheckpoint()

    let items = request.report.topLevelItems
    var result = items.map { item in
      CandidateRuleEvidence.unavailable(.notCollected, for: item)
    }
    guard !items.isEmpty else {
      return RuleEvidenceObservation(candidates: result)
    }

    switch preflight(request) {
    case .unavailable(let reason):
      for index in result.indices {
        result[index] = CandidateRuleEvidence.unavailable(reason, for: items[index])
      }
      return RuleEvidenceObservation(candidates: result)
    case .ready(let rootIdentity, let duplicatePaths):
      let eligibleIndices = items.indices.filter { index in
        !duplicatePaths.contains(items[index].path)
      }
      for index in items.indices where duplicatePaths.contains(items[index].path) {
        result[index] = CandidateRuleEvidence.unavailable(.invalidMetadata, for: items[index])
      }
      guard !eligibleIndices.isEmpty else {
        return RuleEvidenceObservation(candidates: result)
      }

      do {
        try observeCandidates(
          at: eligibleIndices,
          request: request,
          rootIdentity: rootIdentity,
          result: &result
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        let reason = descriptorUnknownReason(for: error)
        for index in eligibleIndices {
          result[index] = CandidateRuleEvidence.unavailable(reason, for: items[index])
        }
      }
      return RuleEvidenceObservation(candidates: result)
    }
  }

  private func preflight(
    _ request: RuleClassificationRequest
  ) -> DescriptorObservationPreflight {
    let report = request.report
    guard report.topLevelItems.count <= RuleCatalogLimits.maximumObservations else {
      return .unavailable(.resourceLimit)
    }
    guard report.isComplete, report.topLevelItems.allSatisfy(\.isComplete) else {
      return .unavailable(.incompleteScan)
    }
    guard
      report.root.path == .root,
      report.root.kind == .directory,
      report.topLevelItemCount == UInt64(report.topLevelItems.count),
      !report.topLevelItemsWereSuppressed,
      report.hardLinkAccountingIsComplete,
      !report.traversalDetailsWereDiscarded,
      report.issues.isEmpty,
      report.suppressedIssueCount == 0,
      LocalFileSystemRootValidator.isValid(request.root)
    else {
      return .unavailable(.invalidMetadata)
    }

    var pathCounts: [ScanRelativePath: Int] = [:]
    for item in report.topLevelItems {
      guard
        item.path.rawComponents.count == 1,
        DescriptorPathComponent(item.path.rawComponents[0]) != nil
      else {
        return .unavailable(.invalidMetadata)
      }
      pathCounts[item.path, default: 0] += 1
    }

    let rootIdentity = report.root.scanTimeIdentity
    let itemIdentities = report.topLevelItems.map(\.scanTimeIdentity)
    if rootIdentity == nil, itemIdentities.allSatisfy({ $0 == nil }) {
      return .unavailable(.notCollected)
    }
    guard
      let rootIdentity,
      itemIdentities.allSatisfy({ $0 != nil }),
      itemIdentities.allSatisfy({ $0?.device == rootIdentity.device })
    else {
      return .unavailable(.invalidMetadata)
    }

    return .ready(
      rootIdentity: rootIdentity,
      duplicatePaths: Set(pathCounts.compactMap { $0.value > 1 ? $0.key : nil })
    )
  }

  private func observeCandidates(
    at indices: [Int],
    request: RuleClassificationRequest,
    rootIdentity: FileIdentity,
    result: inout [CandidateRuleEvidence]
  ) throws {
    try cancellationCheckpoint()

    let rootDescriptor = try descriptorOpenRoot(request.root)
    defer { descriptorCloseIgnoringErrors(rootDescriptor) }
    let openedRoot = try DescriptorStatSnapshot.read(from: rootDescriptor)
    guard openedRoot.kind == .directory, openedRoot.identity == rootIdentity else {
      throw DescriptorObservationError.bindingChanged
    }

    try afterRootValidation()
    try cancellationCheckpoint()

    let locationContext = try observeInitialTrustedLocations(
      at: indices,
      request: request,
      heldRoot: openedRoot
    )

    for index in indices {
      try cancellationCheckpoint()
      let item = request.report.topLevelItems[index]
      let markerPolicy = BuiltInGeneratedMarkerPolicy.policy(for: item.path)
      guard
        let identity = item.scanTimeIdentity,
        let bytes = item.path.rawComponents.first,
        let component = DescriptorPathComponent(bytes)
      else {
        result[index] = .unavailable(
          .invalidMetadata,
          for: item
        )
        continue
      }

      do {
        result[index] = try observeCandidate(
          item,
          expectedIdentity: identity,
          component: component,
          rootDescriptor: rootDescriptor,
          rootIdentity: rootIdentity,
          markerPolicy: markerPolicy,
          trustedLocation: locationContext.observations[index]
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        result[index] = .unavailable(
          descriptorUnknownReason(for: error),
          for: item
        )
      }
    }

    try revalidateTrustedLocation(
      locationContext,
      heldRootDescriptor: rootDescriptor,
      result: &result
    )

    try beforeFinalRootValidation()
    try cancellationCheckpoint()
    try validateFinalRootBinding(
      request.root,
      heldDescriptor: rootDescriptor,
      expectedIdentity: rootIdentity
    )
  }

  private func observeCandidate(
    _ item: ScanItemSummary,
    expectedIdentity: FileIdentity,
    component: DescriptorPathComponent,
    rootDescriptor: Int32,
    rootIdentity: FileIdentity,
    markerPolicy: BuiltInGeneratedMarkerPolicy?,
    trustedLocation: RuleObserved<Bool>
  ) throws -> CandidateRuleEvidence {
    let initiallyNamed = try DescriptorStatSnapshot.read(
      at: rootDescriptor,
      component: component
    )
    guard
      initiallyNamed.kind == item.kind,
      initiallyNamed.identity == expectedIdentity,
      initiallyNamed.identity.device == rootIdentity.device
    else {
      throw DescriptorObservationError.bindingChanged
    }

    guard item.kind == .directory else {
      try beforeFinalCandidateValidation(item.path)
      try cancellationCheckpoint()
      let finallyNamed = try DescriptorStatSnapshot.read(
        at: rootDescriptor,
        component: component
      )
      guard
        finallyNamed.sameBinding(as: initiallyNamed),
        finallyNamed.sameMutationState(as: initiallyNamed)
      else {
        throw DescriptorObservationError.bindingChanged
      }
      return CandidateRuleEvidence(
        identityMatchesScan: .known(true),
        trustedLocation: trustedLocation,
        generatedContentMarker: markerPolicy == nil ? .unknown(.notCollected) : .known(false)
      )
    }

    try beforeOpeningCandidate(item.path)
    try cancellationCheckpoint()
    let candidateDescriptor = try descriptorOpenDirectory(
      at: rootDescriptor,
      component: component
    )
    defer { descriptorCloseIgnoringErrors(candidateDescriptor) }

    let openedCandidate = try DescriptorStatSnapshot.read(from: candidateDescriptor)
    guard
      openedCandidate.sameBinding(as: initiallyNamed),
      openedCandidate.sameMutationState(as: initiallyNamed),
      openedCandidate.identity == expectedIdentity,
      openedCandidate.identity.device == rootIdentity.device
    else {
      throw DescriptorObservationError.bindingChanged
    }

    let marker =
      try markerPolicy.map { policy in
        try observeGeneratedMarker(
          policy,
          in: candidateDescriptor,
          candidatePath: item.path,
          rootIdentity: rootIdentity
        )
      } ?? .unknown(.notCollected)

    try beforeFinalCandidateValidation(item.path)
    try cancellationCheckpoint()
    let finalOpened = try DescriptorStatSnapshot.read(from: candidateDescriptor)
    let finalNamed = try DescriptorStatSnapshot.read(
      at: rootDescriptor,
      component: component
    )
    guard
      finalOpened.sameBinding(as: openedCandidate),
      finalOpened.sameMutationState(as: openedCandidate),
      finalNamed.sameBinding(as: finalOpened),
      finalNamed.sameMutationState(as: finalOpened),
      finalNamed.identity.device == rootIdentity.device
    else {
      throw DescriptorObservationError.bindingChanged
    }

    return CandidateRuleEvidence(
      identityMatchesScan: .known(true),
      trustedLocation: trustedLocation,
      generatedContentMarker: marker
    )
  }

  private func observeInitialTrustedLocations(
    at indices: [Int],
    request: RuleClassificationRequest,
    heldRoot: DescriptorStatSnapshot
  ) throws -> TrustedLocationContext {
    let items = request.report.topLevelItems
    var observations = [RuleObserved<Bool>](
      repeating: .unknown(.notCollected),
      count: items.count
    )
    let applicableIndices = indices.filter { index in
      BuiltInTrustedLocationPolicy.containerSuffix(for: items[index].path) != nil
    }
    guard !applicableIndices.isEmpty else {
      return TrustedLocationContext(observations: observations, binding: nil)
    }

    try cancellationCheckpoint()
    let rawHome = rawHomeProvider()
    try cancellationCheckpoint()
    let rawHomeBytes: [UInt8]
    switch rawHome {
    case .known(let bytes):
      rawHomeBytes = bytes
    case .unknown(let reason):
      for index in applicableIndices {
        observations[index] = .unknown(reason)
      }
      return TrustedLocationContext(observations: observations, binding: nil)
    }
    guard
      let homePath = DescriptorAbsolutePath(rawBytes: rawHomeBytes),
      !homePath.components.isEmpty,
      let selectedRootPath = descriptorAbsolutePath(for: request.root)
    else {
      for index in applicableIndices {
        observations[index] = .unknown(.invalidMetadata)
      }
      return TrustedLocationContext(observations: observations, binding: nil)
    }

    var matchingIndices: [Int] = []
    var matchingComponents: [DescriptorPathComponent]?
    for index in applicableIndices {
      guard
        let suffix = BuiltInTrustedLocationPolicy.containerSuffix(for: items[index].path),
        let suffixComponents = descriptorComponents(suffix)
      else {
        observations[index] = .unknown(.invalidMetadata)
        continue
      }
      let expectedComponents = homePath.components + suffixComponents
      if selectedRootPath.rawComponents == expectedComponents.map(\.bytes) {
        matchingIndices.append(index)
        matchingComponents = expectedComponents
      } else {
        observations[index] = .known(false)
      }
    }
    guard let matchingComponents, !matchingIndices.isEmpty else {
      return TrustedLocationContext(observations: observations, binding: nil)
    }

    do {
      try cancellationCheckpoint()
      let locatedRoot = try descriptorSnapshot(
        atAbsoluteComponents: matchingComponents,
        homeComponentCount: homePath.components.count
      )
      guard
        locatedRoot.kind == .directory,
        locatedRoot.sameBinding(as: heldRoot),
        locatedRoot.identity.device == heldRoot.identity.device
      else {
        throw DescriptorObservationError.bindingChanged
      }
      for index in matchingIndices {
        observations[index] = .known(true)
      }
      return TrustedLocationContext(
        observations: observations,
        binding: TrustedLocationBinding(
          absoluteComponents: matchingComponents,
          homeComponentCount: homePath.components.count,
          initialSnapshot: locatedRoot,
          candidateIndices: matchingIndices
        )
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let reason = descriptorUnknownReason(for: error)
      for index in matchingIndices {
        observations[index] = .unknown(reason)
      }
      return TrustedLocationContext(observations: observations, binding: nil)
    }
  }

  private func revalidateTrustedLocation(
    _ context: TrustedLocationContext,
    heldRootDescriptor: Int32,
    result: inout [CandidateRuleEvidence]
  ) throws {
    guard let binding = context.binding else {
      return
    }

    do {
      try beforeFinalLocationValidation()
      try cancellationCheckpoint()
      let heldRoot = try DescriptorStatSnapshot.read(from: heldRootDescriptor)
      let locatedRoot = try descriptorSnapshot(
        atAbsoluteComponents: binding.absoluteComponents,
        homeComponentCount: binding.homeComponentCount
      )
      guard
        heldRoot.kind == .directory,
        heldRoot.sameBinding(as: binding.initialSnapshot),
        locatedRoot.kind == .directory,
        locatedRoot.sameBinding(as: binding.initialSnapshot),
        locatedRoot.identity.device == heldRoot.identity.device
      else {
        throw DescriptorObservationError.bindingChanged
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let unavailable = RuleObserved<Bool>.unknown(descriptorUnknownReason(for: error))
      for index in binding.candidateIndices where result.indices.contains(index) {
        result[index] = result[index].replacingTrustedLocation(unavailable)
      }
    }
  }

  private func observeGeneratedMarker(
    _ policy: BuiltInGeneratedMarkerPolicy,
    in candidateDescriptor: Int32,
    candidatePath: ScanRelativePath,
    rootIdentity: FileIdentity
  ) throws -> RuleObserved<Bool> {
    do {
      try beforeMarkerObservation(candidatePath)
      try cancellationCheckpoint()
      let requirements = policy.requirements
      let requiredNames = Set(requirements.map(\.rawName))
      let observedNames = try exactRawEntryNames(
        in: candidateDescriptor,
        matching: requiredNames,
        maximumNonDotEntries: Self.maximumGeneratedMarkerEntries
      )
      guard observedNames == requiredNames else {
        return .known(false)
      }

      try beforeMarkerMetadataValidation(candidatePath)
      try cancellationCheckpoint()
      var observations: [RuleObserved<Bool>] = []
      observations.reserveCapacity(requirements.count)
      for requirement in requirements {
        try cancellationCheckpoint()
        guard let markerName = DescriptorPathComponent(requirement.rawName) else {
          observations.append(.unknown(.invalidMetadata))
          continue
        }
        do {
          let marker = try DescriptorStatSnapshot.read(
            at: candidateDescriptor,
            component: markerName
          )
          if marker.identity.device != rootIdentity.device {
            observations.append(.unknown(.changedDuringObservation))
          } else {
            observations.append(.known(marker.kind == requirement.expectedKind))
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          observations.append(.unknown(descriptorUnknownReason(for: error)))
        }
      }
      return combineGeneratedMarkerRequirements(observations)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .unknown(descriptorUnknownReason(for: error))
    }
  }

  private func exactRawEntryNames(
    in directoryDescriptor: Int32,
    matching requiredNames: Set<[UInt8]>,
    maximumNonDotEntries: Int
  ) throws -> Set<[UInt8]> {
    guard maximumNonDotEntries >= 0 else {
      throw DescriptorObservationError.markerEntryLimitExceeded
    }

    let enumerationDescriptor = try descriptorOpenCurrentDirectory(directoryDescriptor)
    guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
      let code = errno
      descriptorCloseIgnoringErrors(enumerationDescriptor)
      throw DescriptorObservationError.posix(code)
    }
    defer { _ = Darwin.closedir(stream) }

    var observedNames: Set<[UInt8]> = []
    var nonDotEntryCount = 0
    var interruptedAttempts = 0
    while true {
      try cancellationCheckpoint()
      errno = 0
      guard let entry = Darwin.readdir(stream) else {
        let code = errno
        if code == EINTR, interruptedAttempts + 1 < 3 {
          interruptedAttempts += 1
          continue
        }
        guard code == 0 else {
          throw DescriptorObservationError.posix(code)
        }
        return observedNames
      }
      interruptedAttempts = 0

      let rawName = descriptorRawName(from: entry)
      if rawName == [0x2E] || rawName == [0x2E, 0x2E] {
        continue
      }
      nonDotEntryCount += 1
      guard nonDotEntryCount <= maximumNonDotEntries else {
        throw DescriptorObservationError.markerEntryLimitExceeded
      }
      if requiredNames.contains(rawName) {
        observedNames.insert(rawName)
      }
    }
  }

  private func validateFinalRootBinding(
    _ root: URL,
    heldDescriptor: Int32,
    expectedIdentity: FileIdentity
  ) throws {
    let heldRoot = try DescriptorStatSnapshot.read(from: heldDescriptor)
    guard heldRoot.kind == .directory, heldRoot.identity == expectedIdentity else {
      throw DescriptorObservationError.bindingChanged
    }

    let reboundDescriptor = try descriptorOpenRoot(root)
    defer { descriptorCloseIgnoringErrors(reboundDescriptor) }
    let reboundRoot = try DescriptorStatSnapshot.read(from: reboundDescriptor)
    guard reboundRoot.kind == .directory, reboundRoot.identity == expectedIdentity else {
      throw DescriptorObservationError.bindingChanged
    }
  }

  private func cancellationCheckpoint() throws {
    try Task.checkCancellation()
    try checkpoint()
    try Task.checkCancellation()
  }
}

/// A single validated POSIX path component suitable for an `*at` syscall.
struct DescriptorPathComponent: Equatable, Sendable {
  let bytes: [UInt8]

  init?(_ bytes: [UInt8]) {
    guard
      !bytes.isEmpty,
      bytes.count <= Int(NAME_MAX),
      !bytes.contains(0),
      !bytes.contains(0x2F),
      bytes != [0x2E],
      bytes != [0x2E, 0x2E]
    else {
      return nil
    }
    self.bytes = bytes
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

private enum DescriptorObservationPreflight {
  case unavailable(RuleUnknownReason)
  case ready(rootIdentity: FileIdentity, duplicatePaths: Set<ScanRelativePath>)
}

private struct TrustedLocationContext {
  let observations: [RuleObserved<Bool>]
  let binding: TrustedLocationBinding?
}

private struct TrustedLocationBinding {
  let absoluteComponents: [DescriptorPathComponent]
  let homeComponentCount: Int
  let initialSnapshot: DescriptorStatSnapshot
  let candidateIndices: [Int]
}

private struct DescriptorAbsolutePath {
  let components: [DescriptorPathComponent]

  init?(rawBytes: [UInt8]) {
    guard
      !rawBytes.isEmpty,
      rawBytes.count <= Int(PATH_MAX),
      rawBytes.first == 0x2F,
      rawBytes.last != 0x2F
    else {
      return nil
    }

    let rawComponents = rawBytes.dropFirst().split(
      separator: 0x2F,
      omittingEmptySubsequences: false
    )
    var validated: [DescriptorPathComponent] = []
    validated.reserveCapacity(rawComponents.count)
    for rawComponent in rawComponents {
      guard let component = DescriptorPathComponent(Array(rawComponent)) else {
        return nil
      }
      validated.append(component)
    }
    components = validated
  }
}

private enum DescriptorObservationError: Error {
  case bindingChanged
  case crossedVolume
  case markerEntryLimitExceeded
  case posix(Int32)
}

private struct DescriptorStatSnapshot: Sendable {
  let identity: FileIdentity
  let kind: FileSystemEntryKind
  let generation: UInt32
  let birthSeconds: Int
  let birthNanoseconds: Int
  let changeSeconds: Int
  let changeNanoseconds: Int
  let modificationSeconds: Int
  let modificationNanoseconds: Int

  static func read(from descriptor: Int32) throws -> DescriptorStatSnapshot {
    var information = stat()
    try descriptorRetryingInterrupted {
      guard Darwin.fstat(descriptor, &information) == 0 else {
        throw DescriptorObservationError.posix(errno)
      }
    }
    return DescriptorStatSnapshot(information: information)
  }

  static func read(
    at parentDescriptor: Int32,
    component: DescriptorPathComponent
  ) throws -> DescriptorStatSnapshot {
    var information = stat()
    try descriptorRetryingInterrupted {
      try component.withCString { pointer in
        guard
          Darwin.fstatat(
            parentDescriptor,
            pointer,
            &information,
            AT_SYMLINK_NOFOLLOW
          ) == 0
        else {
          throw DescriptorObservationError.posix(errno)
        }
      }
    }
    return DescriptorStatSnapshot(information: information)
  }

  init(information: stat) {
    identity = FileIdentity(
      device: UInt64(bitPattern: Int64(information.st_dev)),
      inode: UInt64(information.st_ino)
    )
    kind = descriptorEntryKind(for: information.st_mode)
    generation = information.st_gen
    birthSeconds = information.st_birthtimespec.tv_sec
    birthNanoseconds = information.st_birthtimespec.tv_nsec
    changeSeconds = information.st_ctimespec.tv_sec
    changeNanoseconds = information.st_ctimespec.tv_nsec
    modificationSeconds = information.st_mtimespec.tv_sec
    modificationNanoseconds = information.st_mtimespec.tv_nsec
  }

  func sameBinding(as other: DescriptorStatSnapshot) -> Bool {
    identity == other.identity
      && kind == other.kind
      && generation == other.generation
      && birthSeconds == other.birthSeconds
      && birthNanoseconds == other.birthNanoseconds
  }

  func sameMutationState(as other: DescriptorStatSnapshot) -> Bool {
    changeSeconds == other.changeSeconds
      && changeNanoseconds == other.changeNanoseconds
      && modificationSeconds == other.modificationSeconds
      && modificationNanoseconds == other.modificationNanoseconds
  }
}

private func descriptorOpenRoot(_ url: URL) throws -> Int32 {
  var descriptor: Int32 = -1
  try descriptorRetryingInterrupted {
    var failureCode: Int32 = EINVAL
    descriptor = url.withUnsafeFileSystemRepresentation { pointer in
      guard let pointer else { return -1 }
      let result = Darwin.open(
        pointer,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      if result < 0 { failureCode = errno }
      return result
    }
    guard descriptor >= 0 else {
      throw DescriptorObservationError.posix(failureCode)
    }
  }
  return descriptor
}

func combineGeneratedMarkerRequirements(
  _ observations: [RuleObserved<Bool>]
) -> RuleObserved<Bool> {
  if observations.contains(.known(false)) {
    return .known(false)
  }
  for observation in observations {
    if case .unknown(let reason) = observation {
      return .unknown(reason)
    }
  }
  return .known(true)
}

private func descriptorOpenCurrentDirectory(_ descriptor: Int32) throws -> Int32 {
  var opened: Int32 = -1
  try descriptorRetryingInterrupted {
    var failureCode: Int32 = EINVAL
    opened = Darwin.openat(
      descriptor,
      ".",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    if opened < 0 { failureCode = errno }
    guard opened >= 0 else {
      throw DescriptorObservationError.posix(failureCode)
    }
  }
  return opened
}

private func descriptorRawName(from entry: UnsafeMutablePointer<dirent>) -> [UInt8] {
  let length = Int(entry.pointee.d_namlen)
  return withUnsafeBytes(of: &entry.pointee.d_name) { rawBuffer in
    Array(rawBuffer.prefix(length))
  }
}

private func descriptorOpenDirectory(
  at parentDescriptor: Int32,
  component: DescriptorPathComponent
) throws -> Int32 {
  var descriptor: Int32 = -1
  try descriptorRetryingInterrupted {
    var failureCode: Int32 = EINVAL
    descriptor = component.withCString { pointer in
      let result = Darwin.openat(
        parentDescriptor,
        pointer,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      if result < 0 { failureCode = errno }
      return result
    }
    guard descriptor >= 0 else {
      throw DescriptorObservationError.posix(failureCode)
    }
  }
  return descriptor
}

private func descriptorOpenTrustedDirectory(
  at parentDescriptor: Int32,
  component: DescriptorPathComponent
) throws -> Int32 {
  var descriptor: Int32 = -1
  try descriptorRetryingInterrupted {
    var failureCode: Int32 = EINVAL
    descriptor = component.withCString { pointer in
      let result = Darwin.openat(
        parentDescriptor,
        pointer,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
      )
      if result < 0 { failureCode = errno }
      return result
    }
    guard descriptor >= 0 else {
      throw DescriptorObservationError.posix(failureCode)
    }
  }
  return descriptor
}

private func descriptorSnapshot(
  atAbsoluteComponents components: [DescriptorPathComponent],
  homeComponentCount: Int
) throws -> DescriptorStatSnapshot {
  guard homeComponentCount > 0, homeComponentCount < components.count else {
    throw DescriptorObservationError.posix(EINVAL)
  }

  var descriptor: Int32 = -1
  try descriptorRetryingInterrupted {
    descriptor = Darwin.open(
      "/",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw DescriptorObservationError.posix(errno)
    }
  }

  do {
    var homeDevice: UInt64?
    var finalSnapshot: DescriptorStatSnapshot?
    for (index, component) in components.enumerated() {
      try Task.checkCancellation()
      let childDescriptor = try descriptorOpenTrustedDirectory(
        at: descriptor,
        component: component
      )
      descriptorCloseIgnoringErrors(descriptor)
      descriptor = childDescriptor

      let openedComponentCount = index + 1
      guard openedComponentCount >= homeComponentCount else {
        continue
      }
      let snapshot = try DescriptorStatSnapshot.read(from: descriptor)
      if openedComponentCount == homeComponentCount {
        homeDevice = snapshot.identity.device
      } else {
        guard let homeDevice, snapshot.identity.device == homeDevice else {
          throw DescriptorObservationError.crossedVolume
        }
      }
      finalSnapshot = snapshot
    }
    guard let finalSnapshot else {
      throw DescriptorObservationError.posix(EINVAL)
    }
    descriptorCloseIgnoringErrors(descriptor)
    return finalSnapshot
  } catch {
    descriptorCloseIgnoringErrors(descriptor)
    throw error
  }
}

private func descriptorAbsolutePath(for url: URL) -> DescriptorRawAbsolutePath? {
  url.withUnsafeFileSystemRepresentation { representation in
    guard let representation else {
      return nil
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(min(Int(PATH_MAX), 256))
    for offset in 0...Int(PATH_MAX) {
      let byte = UInt8(bitPattern: representation[offset])
      if byte == 0 {
        return DescriptorRawAbsolutePath(rawBytes: bytes)
      }
      guard offset < Int(PATH_MAX) else {
        return nil
      }
      bytes.append(byte)
    }
    return nil
  }
}

private struct DescriptorRawAbsolutePath {
  let rawComponents: [[UInt8]]

  init?(rawBytes: [UInt8]) {
    guard
      !rawBytes.isEmpty,
      rawBytes.count <= Int(PATH_MAX),
      rawBytes.first == 0x2F
    else {
      return nil
    }
    if rawBytes == [0x2F] {
      rawComponents = []
      return
    }
    rawComponents = rawBytes.dropFirst().split(
      separator: 0x2F,
      omittingEmptySubsequences: false
    ).map(Array.init)
  }
}

private func descriptorComponents(
  _ rawComponents: [[UInt8]]
) -> [DescriptorPathComponent]? {
  var result: [DescriptorPathComponent] = []
  result.reserveCapacity(rawComponents.count)
  for rawComponent in rawComponents {
    guard let component = DescriptorPathComponent(rawComponent) else {
      return nil
    }
    result.append(component)
  }
  return result
}

/// Reads the real user's passwd home as bounded raw bytes. Environment-based
/// home overrides are intentionally not trusted policy input.
private func currentUIDRawHome() -> RuleObserved<[UInt8]> {
  let realUser = Darwin.getuid()
  let effectiveUser = Darwin.geteuid()
  guard realUser != 0, realUser == effectiveUser else {
    return .unknown(.unsupported)
  }

  let recommendedBufferSize = Darwin.sysconf(_SC_GETPW_R_SIZE_MAX)
  let maximumBufferSize = 64 * 1_024
  guard
    recommendedBufferSize > 0,
    let bufferSize = Int(exactly: recommendedBufferSize),
    bufferSize <= maximumBufferSize
  else {
    return .unknown(.resourceLimit)
  }

  var record = passwd()
  var resolvedRecord: UnsafeMutablePointer<passwd>?
  var buffer = [CChar](repeating: 0, count: bufferSize)
  let result: (status: Int32, bytes: [UInt8]?) = buffer.withUnsafeMutableBufferPointer {
    bufferPointer in
    guard let baseAddress = bufferPointer.baseAddress else {
      return (ENOMEM, nil)
    }
    let status = Darwin.getpwuid_r(
      realUser,
      &record,
      baseAddress,
      bufferPointer.count,
      &resolvedRecord
    )
    guard status == 0, resolvedRecord != nil, let home = record.pw_dir else {
      return (status, nil)
    }
    return (
      status,
      boundedCStringBytes(
        home,
        storageBase: baseAddress,
        storageCount: bufferPointer.count
      )
    )
  }

  guard result.status == 0 else {
    return .unknown(descriptorUnknownReason(forPOSIXCode: result.status))
  }
  guard let bytes = result.bytes else {
    return resolvedRecord == nil ? .unknown(.notCollected) : .unknown(.invalidMetadata)
  }
  guard DescriptorAbsolutePath(rawBytes: bytes) != nil else {
    return .unknown(.invalidMetadata)
  }
  return .known(bytes)
}

private func boundedCStringBytes(
  _ value: UnsafePointer<CChar>,
  storageBase: UnsafePointer<CChar>,
  storageCount: Int
) -> [UInt8]? {
  let startAddress = UInt(bitPattern: value)
  let storageAddress = UInt(bitPattern: storageBase)
  let (storageEnd, overflow) = storageAddress.addingReportingOverflow(UInt(storageCount))
  guard
    !overflow,
    startAddress >= storageAddress,
    startAddress < storageEnd
  else {
    return nil
  }

  let available = Int(storageEnd - startAddress)
  var result: [UInt8] = []
  result.reserveCapacity(min(available, Int(PATH_MAX)))
  for offset in 0..<available {
    let byte = UInt8(bitPattern: value[offset])
    if byte == 0 {
      return result
    }
    guard result.count < Int(PATH_MAX) else {
      return nil
    }
    result.append(byte)
  }
  return nil
}

private func descriptorRetryingInterrupted(
  maximumAttempts: Int = 3,
  _ operation: () throws -> Void
) throws {
  var attempt = 0
  while true {
    try Task.checkCancellation()
    do {
      try operation()
      return
    } catch DescriptorObservationError.posix(EINTR) where attempt + 1 < maximumAttempts {
      attempt += 1
    }
  }
}

private func descriptorCloseIgnoringErrors(_ descriptor: Int32) {
  _ = Darwin.close(descriptor)
}

private func descriptorEntryKind(for mode: mode_t) -> FileSystemEntryKind {
  switch mode & mode_t(S_IFMT) {
  case mode_t(S_IFREG): .regularFile
  case mode_t(S_IFDIR): .directory
  case mode_t(S_IFLNK): .symbolicLink
  default: .other
  }
}

private func descriptorUnknownReason(for error: Error) -> RuleUnknownReason {
  if let observationError = error as? DescriptorObservationError {
    switch observationError {
    case .bindingChanged:
      return .changedDuringObservation
    case .crossedVolume:
      return .changedDuringObservation
    case .markerEntryLimitExceeded:
      return .resourceLimit
    case .posix(let code):
      return descriptorUnknownReason(forPOSIXCode: code)
    }
  }

  let nsError = error as NSError
  if nsError.domain == NSPOSIXErrorDomain, let code = Int32(exactly: nsError.code) {
    return descriptorUnknownReason(forPOSIXCode: code)
  }
  return .unspecified
}

private func descriptorUnknownReason(forPOSIXCode code: Int32) -> RuleUnknownReason {
  switch code {
  case EACCES, EPERM: .permissionDenied
  case ENOENT, ENOTDIR, ELOOP, ESTALE, EAGAIN, EXDEV:
    .changedDuringObservation
  case EMFILE, ENFILE, ENOMEM, ERANGE: .resourceLimit
  case EINVAL, EOVERFLOW, ENAMETOOLONG: .invalidMetadata
  case ENOTSUP: .unsupported
  default: .unspecified
  }
}
