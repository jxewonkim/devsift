import Darwin
import Foundation

struct CandidateRuleEvidence: Hashable, Sendable {
  let identityMatchesScan: RuleObserved<Bool>
  let trustedLocation: RuleObserved<Bool>
  let generatedContentMarker: RuleObserved<Bool>
  let accountOwnedCacheNamespace: RuleObserved<Bool>
  let protectedDescendantPresent: RuleObserved<Bool>

  init(
    identityMatchesScan: RuleObserved<Bool>,
    trustedLocation: RuleObserved<Bool>,
    generatedContentMarker: RuleObserved<Bool>,
    accountOwnedCacheNamespace: RuleObserved<Bool> = .unknown(.notCollected),
    protectedDescendantPresent: RuleObserved<Bool> = .unknown(.notCollected)
  ) {
    self.identityMatchesScan = identityMatchesScan
    self.trustedLocation = trustedLocation
    self.generatedContentMarker = generatedContentMarker
    self.accountOwnedCacheNamespace = accountOwnedCacheNamespace
    self.protectedDescendantPresent = protectedDescendantPresent
  }

  static func unavailable(
    _ reason: RuleUnknownReason,
    for item: ScanItemSummary
  ) -> CandidateRuleEvidence {
    CandidateRuleEvidence(
      identityMatchesScan: .unknown(reason),
      trustedLocation: BuiltInTrustedLocationPolicy.containerSuffix(for: item.path) == nil
        ? .unknown(.notCollected) : .unknown(reason),
      generatedContentMarker: BuiltInGeneratedMarkerPolicy.policy(for: item.path) == nil
        ? .unknown(.notCollected) : .unknown(reason),
      accountOwnedCacheNamespace: BuiltInAccountOwnedCacheNamespacePolicy.applies(to: item.path)
        ? .unknown(reason) : .unknown(.notCollected),
      protectedDescendantPresent: BuiltInProtectedDescendantPolicy.applies(to: item.path)
        ? .unknown(reason) : .unknown(.notCollected)
    )
  }

  func replacingTrustedLocation(
    _ observation: RuleObserved<Bool>
  ) -> CandidateRuleEvidence {
    CandidateRuleEvidence(
      identityMatchesScan: identityMatchesScan,
      trustedLocation: observation,
      generatedContentMarker: generatedContentMarker,
      accountOwnedCacheNamespace: accountOwnedCacheNamespace,
      protectedDescendantPresent: protectedDescendantPresent
    )
  }

  func replacingAccountOwnedCacheNamespace(
    _ observation: RuleObserved<Bool>
  ) -> CandidateRuleEvidence {
    CandidateRuleEvidence(
      identityMatchesScan: identityMatchesScan,
      trustedLocation: trustedLocation,
      generatedContentMarker: generatedContentMarker,
      accountOwnedCacheNamespace: observation,
      protectedDescendantPresent: protectedDescendantPresent
    )
  }
}

private enum BuiltInAccountOwnedCacheNamespacePolicy {
  private static let npmContentCacheName = Array("_cacache".utf8)

  static func applies(to path: ScanRelativePath) -> Bool {
    path.rawComponents == [npmContentCacheName]
  }
}

private enum BuiltInProtectedDescendantPolicy {
  private static let npmContentCacheName = Array("_cacache".utf8)

  static func applies(to path: ScanRelativePath) -> Bool {
    path.rawComponents == [npmContentCacheName]
  }
}

struct ProtectedDescendantLimits: Hashable, Sendable {
  static let defaults = ProtectedDescendantLimits(
    maximumEntries: 1_000_000,
    maximumDepth: 32,
    maximumRawNameBytes: 64 * 1_024 * 1_024
  )

  let maximumEntries: Int
  let maximumDepth: Int
  let maximumRawNameBytes: Int

  init(
    maximumEntries: Int = 1_000_000,
    maximumDepth: Int = 32,
    maximumRawNameBytes: Int = 64 * 1_024 * 1_024
  ) {
    self.maximumEntries = maximumEntries
    self.maximumDepth = maximumDepth
    self.maximumRawNameBytes = maximumRawNameBytes
  }

  var isValid: Bool {
    maximumEntries >= 0 && maximumDepth >= 0 && maximumRawNameBytes >= 0
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
  typealias AccountUIDProvider = @Sendable () -> RuleObserved<uid_t>

  private static let maximumGeneratedMarkerEntries = 256

  private let checkpoint: Checkpoint
  private let rawHomeProvider: RawHomeProvider
  private let accountUIDProvider: AccountUIDProvider
  private let protectedDescendantLimits: ProtectedDescendantLimits
  private let afterRootValidation: RootHook
  private let beforeOpeningCandidate: CandidateHook
  private let beforeMarkerObservation: CandidateHook
  private let beforeMarkerMetadataValidation: CandidateHook
  private let beforeProtectedDescendantObservation: CandidateHook
  private let beforeOpeningProtectedDescendantDirectory: CandidateHook
  private let beforeFinalProtectedDescendantDirectoryValidation: CandidateHook
  private let beforeFinalCandidateValidation: CandidateHook
  private let beforeFinalLocationValidation: RootHook
  private let beforeFinalRootValidation: RootHook

  init() {
    checkpoint = { try Task.checkCancellation() }
    rawHomeProvider = { currentUIDRawHome() }
    accountUIDProvider = { currentNonRootAccountUID() }
    protectedDescendantLimits = .defaults
    afterRootValidation = {}
    beforeOpeningCandidate = { _ in }
    beforeMarkerObservation = { _ in }
    beforeMarkerMetadataValidation = { _ in }
    beforeProtectedDescendantObservation = { _ in }
    beforeOpeningProtectedDescendantDirectory = { _ in }
    beforeFinalProtectedDescendantDirectoryValidation = { _ in }
    beforeFinalCandidateValidation = { _ in }
    beforeFinalLocationValidation = {}
    beforeFinalRootValidation = {}
  }

  init(
    checkpoint: @escaping Checkpoint = { try Task.checkCancellation() },
    rawHomeProvider: @escaping RawHomeProvider = { currentUIDRawHome() },
    accountUIDProvider: @escaping AccountUIDProvider = { currentNonRootAccountUID() },
    protectedDescendantLimits: ProtectedDescendantLimits = .defaults,
    afterRootValidation: @escaping RootHook = {},
    beforeOpeningCandidate: @escaping CandidateHook = { _ in },
    beforeMarkerObservation: @escaping CandidateHook = { _ in },
    beforeMarkerMetadataValidation: @escaping CandidateHook = { _ in },
    beforeProtectedDescendantObservation: @escaping CandidateHook = { _ in },
    beforeOpeningProtectedDescendantDirectory: @escaping CandidateHook = { _ in },
    beforeFinalProtectedDescendantDirectoryValidation: @escaping CandidateHook = { _ in },
    beforeFinalCandidateValidation: @escaping CandidateHook = { _ in },
    beforeFinalLocationValidation: @escaping RootHook = {},
    beforeFinalRootValidation: @escaping RootHook = {}
  ) {
    self.checkpoint = checkpoint
    self.rawHomeProvider = rawHomeProvider
    self.accountUIDProvider = accountUIDProvider
    self.protectedDescendantLimits = protectedDescendantLimits
    self.afterRootValidation = afterRootValidation
    self.beforeOpeningCandidate = beforeOpeningCandidate
    self.beforeMarkerObservation = beforeMarkerObservation
    self.beforeMarkerMetadataValidation = beforeMarkerMetadataValidation
    self.beforeProtectedDescendantObservation = beforeProtectedDescendantObservation
    self.beforeOpeningProtectedDescendantDirectory =
      beforeOpeningProtectedDescendantDirectory
    self.beforeFinalProtectedDescendantDirectoryValidation =
      beforeFinalProtectedDescendantDirectoryValidation
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

    let accountUID = try observeAccountUID(
      for: indices,
      items: request.report.topLevelItems
    )

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
          rootSnapshot: openedRoot,
          accountUID: accountUID,
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
    let rootOwnerRemainedStable = try validateFinalRootBinding(
      request.root,
      heldDescriptor: rootDescriptor,
      expectedSnapshot: openedRoot
    )
    if !rootOwnerRemainedStable {
      for index in indices {
        let item = request.report.topLevelItems[index]
        let revalidated = accountOwnedCacheNamespaceAfterRootOwnerValidation(
          result[index].accountOwnedCacheNamespace,
          applies: BuiltInAccountOwnedCacheNamespacePolicy.applies(to: item.path),
          candidateKind: item.kind,
          rootOwnerRemainedStable: false
        )
        if revalidated != result[index].accountOwnedCacheNamespace {
          result[index] = result[index].replacingAccountOwnedCacheNamespace(
            revalidated
          )
        }
      }
    }
  }

  private func observeAccountUID(
    for indices: [Int],
    items: [ScanItemSummary]
  ) throws -> RuleObserved<uid_t> {
    guard
      indices.contains(where: { index in
        BuiltInAccountOwnedCacheNamespacePolicy.applies(to: items[index].path)
      })
    else {
      return .unknown(.notCollected)
    }

    try cancellationCheckpoint()
    let observation = accountUIDProvider()
    try cancellationCheckpoint()
    if case .known(0) = observation {
      return .unknown(.invalidMetadata)
    }
    return observation
  }

  private func observeCandidate(
    _ item: ScanItemSummary,
    expectedIdentity: FileIdentity,
    component: DescriptorPathComponent,
    rootDescriptor: Int32,
    rootIdentity: FileIdentity,
    rootSnapshot: DescriptorStatSnapshot,
    accountUID: RuleObserved<uid_t>,
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
        generatedContentMarker: markerPolicy == nil ? .unknown(.notCollected) : .known(false),
        accountOwnedCacheNamespace: observeAccountOwnedCacheNamespace(
          for: item.path,
          accountUID: accountUID,
          root: rootSnapshot,
          candidate: initiallyNamed
        ),
        protectedDescendantPresent: BuiltInProtectedDescendantPolicy.applies(to: item.path)
          ? .known(false) : .unknown(.notCollected)
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
    var candidateOwnerRemainedStable =
      openedCandidate.ownerUID == initiallyNamed.ownerUID
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

    let protectedDescendant = try observeProtectedDescendants(
      for: item,
      in: candidateDescriptor,
      candidateSnapshot: openedCandidate,
      rootIdentity: rootIdentity,
      accountUID: accountUID
    )

    try beforeFinalCandidateValidation(item.path)
    try cancellationCheckpoint()
    let finalOpened = try DescriptorStatSnapshot.read(from: candidateDescriptor)
    let finalNamed = try DescriptorStatSnapshot.read(
      at: rootDescriptor,
      component: component
    )
    candidateOwnerRemainedStable =
      candidateOwnerRemainedStable
      && finalOpened.ownerUID == openedCandidate.ownerUID
      && finalNamed.ownerUID == finalOpened.ownerUID
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
      generatedContentMarker: marker,
      accountOwnedCacheNamespace: observeAccountOwnedCacheNamespace(
        for: item.path,
        accountUID: accountUID,
        root: rootSnapshot,
        candidate: openedCandidate,
        candidateOwnerRemainedStable: candidateOwnerRemainedStable
      ),
      protectedDescendantPresent: protectedDescendant
    )
  }

  private func observeAccountOwnedCacheNamespace(
    for path: ScanRelativePath,
    accountUID: RuleObserved<uid_t>,
    root: DescriptorStatSnapshot,
    candidate: DescriptorStatSnapshot,
    candidateOwnerRemainedStable: Bool = true
  ) -> RuleObserved<Bool> {
    guard BuiltInAccountOwnedCacheNamespacePolicy.applies(to: path) else {
      return .unknown(.notCollected)
    }
    return evaluateAccountOwnedCacheNamespace(
      accountUID: accountUID,
      rootKind: root.kind,
      rootOwnerUID: root.ownerUID,
      candidateKind: candidate.kind,
      candidateOwnerUID: candidate.ownerUID,
      candidateOwnerRemainedStable: candidateOwnerRemainedStable
    )
  }

  private func observeProtectedDescendants(
    for item: ScanItemSummary,
    in candidateDescriptor: Int32,
    candidateSnapshot: DescriptorStatSnapshot,
    rootIdentity: FileIdentity,
    accountUID: RuleObserved<uid_t>
  ) throws -> RuleObserved<Bool> {
    guard BuiltInProtectedDescendantPolicy.applies(to: item.path) else {
      return .unknown(.notCollected)
    }
    guard protectedDescendantLimits.isValid else {
      return .unknown(.resourceLimit)
    }
    guard
      let expectedDescendantCount = exactStrictDescendantCount(for: item),
      item.counts.directories > 0
    else {
      return .unknown(.invalidMetadata)
    }

    do {
      try beforeProtectedDescendantObservation(item.path)
      try cancellationCheckpoint()

      var state = ProtectedDescendantTraversalState(
        limits: protectedDescendantLimits,
        accountUID: accountUID,
        rootDevice: rootIdentity.device,
        seenDirectoryIdentities: [rootIdentity, candidateSnapshot.identity]
      )
      try traverseProtectedDescendants(
        in: candidateDescriptor,
        expectedDirectory: candidateSnapshot,
        directoryPath: item.path,
        format: .cacheRoot,
        childDepth: 1,
        state: &state
      )
      return state.result(expectedDescendantCount: expectedDescendantCount)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .unknown(descriptorUnknownReason(for: error))
    }
  }

  private func traverseProtectedDescendants(
    in directoryDescriptor: Int32,
    expectedDirectory: DescriptorStatSnapshot,
    directoryPath: ScanRelativePath,
    format: NPMCacheDirectoryFormat,
    childDepth: Int,
    state: inout ProtectedDescendantTraversalState
  ) throws {
    try cancellationCheckpoint()
    guard !state.protectedDescendantWasObserved else {
      return
    }

    do {
      let currentDirectory = try DescriptorStatSnapshot.read(from: directoryDescriptor)
      guard currentDirectory.sameProtectedDescendantState(as: expectedDirectory) else {
        throw DescriptorObservationError.bindingChanged
      }

      let enumerationDescriptor = try descriptorOpenCurrentDirectory(directoryDescriptor)
      guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
        let code = errno
        descriptorCloseIgnoringErrors(enumerationDescriptor)
        throw DescriptorObservationError.posix(code)
      }
      defer { _ = Darwin.closedir(stream) }

      var interruptedAttempts = 0
      while !state.protectedDescendantWasObserved {
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
          break
        }
        interruptedAttempts = 0

        let rawName = descriptorRawName(from: entry)
        if rawName == [0x2E] || rawName == [0x2E, 0x2E] {
          continue
        }
        try state.recordEntry(rawName: rawName, depth: childDepth)
        guard let component = DescriptorPathComponent(rawName) else {
          state.recordFailure(.invalidMetadata)
          continue
        }

        let descendantPath = directoryPath.appending(rawComponent: rawName)
        do {
          try observeProtectedDescendantEntry(
            at: directoryDescriptor,
            component: component,
            path: descendantPath,
            formatExpectation: format.expectation(for: rawName),
            childDepth: childDepth,
            state: &state
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          state.recordFailure(descriptorUnknownReason(for: error))
        }
      }

      let finalDirectory = try DescriptorStatSnapshot.read(from: directoryDescriptor)
      guard finalDirectory.sameProtectedDescendantState(as: expectedDirectory) else {
        throw DescriptorObservationError.bindingChanged
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch DescriptorObservationError.protectedDescendantLimitExceeded {
      throw DescriptorObservationError.protectedDescendantLimitExceeded
    } catch {
      state.recordFailure(descriptorUnknownReason(for: error))
    }
  }

  private func observeProtectedDescendantEntry(
    at parentDescriptor: Int32,
    component: DescriptorPathComponent,
    path: ScanRelativePath,
    formatExpectation: NPMCacheEntryExpectation?,
    childDepth: Int,
    state: inout ProtectedDescendantTraversalState
  ) throws {
    try cancellationCheckpoint()
    let initiallyNamed = try DescriptorStatSnapshot.read(
      at: parentDescriptor,
      component: component
    )

    let repeatedDirectoryIdentity =
      initiallyNamed.kind == .directory
      && state.seenDirectoryIdentities.contains(initiallyNamed.identity)
    let isStructurallyProtected = state.isStructurallyProtected(
      initiallyNamed,
      expectation: formatExpectation,
      repeatedDirectoryIdentity: repeatedDirectoryIdentity
    )

    guard
      !isStructurallyProtected,
      initiallyNamed.kind == .directory,
      let childFormat = formatExpectation?.childDirectoryFormat
    else {
      let finallyNamed = try DescriptorStatSnapshot.read(
        at: parentDescriptor,
        component: component
      )
      guard finallyNamed.sameProtectedDescendantState(as: initiallyNamed) else {
        throw DescriptorObservationError.bindingChanged
      }
      if isStructurallyProtected {
        state.recordProtectedDescendant()
      }
      return
    }

    try beforeOpeningProtectedDescendantDirectory(path)
    try cancellationCheckpoint()
    let childDescriptor = try descriptorOpenTrustedDirectory(
      at: parentDescriptor,
      component: component
    )
    defer { descriptorCloseIgnoringErrors(childDescriptor) }

    let openedChild = try DescriptorStatSnapshot.read(from: childDescriptor)
    guard openedChild.sameProtectedDescendantState(as: initiallyNamed) else {
      throw DescriptorObservationError.bindingChanged
    }

    let openedIdentityWasRepeated = state.seenDirectoryIdentities.contains(
      openedChild.identity
    )
    if state.isStructurallyProtected(
      openedChild,
      expectation: formatExpectation,
      repeatedDirectoryIdentity: openedIdentityWasRepeated
    ) {
      try validateProtectedDescendantDirectory(
        descriptor: childDescriptor,
        namedAt: parentDescriptor,
        component: component,
        path: path,
        expected: openedChild
      )
      state.recordProtectedDescendant()
      return
    }

    guard state.seenDirectoryIdentities.insert(openedChild.identity).inserted else {
      try validateProtectedDescendantDirectory(
        descriptor: childDescriptor,
        namedAt: parentDescriptor,
        component: component,
        path: path,
        expected: openedChild
      )
      state.recordProtectedDescendant()
      return
    }

    let (nextChildDepth, depthOverflow) = childDepth.addingReportingOverflow(1)
    guard !depthOverflow else {
      throw DescriptorObservationError.protectedDescendantLimitExceeded
    }
    try traverseProtectedDescendants(
      in: childDescriptor,
      expectedDirectory: openedChild,
      directoryPath: path,
      format: childFormat,
      childDepth: nextChildDepth,
      state: &state
    )
    try validateProtectedDescendantDirectory(
      descriptor: childDescriptor,
      namedAt: parentDescriptor,
      component: component,
      path: path,
      expected: openedChild
    )
  }

  private func validateProtectedDescendantDirectory(
    descriptor: Int32,
    namedAt parentDescriptor: Int32,
    component: DescriptorPathComponent,
    path: ScanRelativePath,
    expected: DescriptorStatSnapshot
  ) throws {
    try beforeFinalProtectedDescendantDirectoryValidation(path)
    try cancellationCheckpoint()
    let finalOpened = try DescriptorStatSnapshot.read(from: descriptor)
    let finalNamed = try DescriptorStatSnapshot.read(
      at: parentDescriptor,
      component: component
    )
    guard
      finalOpened.sameProtectedDescendantState(as: expected),
      finalNamed.sameProtectedDescendantState(as: finalOpened)
    else {
      throw DescriptorObservationError.bindingChanged
    }
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
    expectedSnapshot: DescriptorStatSnapshot
  ) throws -> Bool {
    let heldRoot = try DescriptorStatSnapshot.read(from: heldDescriptor)
    guard heldRoot.kind == .directory, heldRoot.identity == expectedSnapshot.identity else {
      throw DescriptorObservationError.bindingChanged
    }

    let reboundDescriptor = try descriptorOpenRoot(root)
    defer { descriptorCloseIgnoringErrors(reboundDescriptor) }
    let reboundRoot = try DescriptorStatSnapshot.read(from: reboundDescriptor)
    guard reboundRoot.kind == .directory, reboundRoot.identity == expectedSnapshot.identity else {
      throw DescriptorObservationError.bindingChanged
    }
    return heldRoot.ownerUID == expectedSnapshot.ownerUID
      && reboundRoot.ownerUID == expectedSnapshot.ownerUID
  }

  private func cancellationCheckpoint() throws {
    try Task.checkCancellation()
    try checkpoint()
    try Task.checkCancellation()
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

private struct ProtectedDescendantTraversalState {
  let limits: ProtectedDescendantLimits
  let accountUID: RuleObserved<uid_t>
  let rootDevice: UInt64
  var seenDirectoryIdentities: Set<FileIdentity>

  private(set) var observedEntryCount = 0
  private(set) var observedRawNameBytes = 0
  private(set) var protectedDescendantWasObserved = false
  private var failureReason: RuleUnknownReason?

  init(
    limits: ProtectedDescendantLimits,
    accountUID: RuleObserved<uid_t>,
    rootDevice: UInt64,
    seenDirectoryIdentities: Set<FileIdentity>
  ) {
    self.limits = limits
    self.accountUID = accountUID
    self.rootDevice = rootDevice
    self.seenDirectoryIdentities = seenDirectoryIdentities
  }

  mutating func recordEntry(rawName: [UInt8], depth: Int) throws {
    let (newEntryCount, entryCountOverflow) = observedEntryCount.addingReportingOverflow(1)
    let (newRawNameBytes, rawNameBytesOverflow) =
      observedRawNameBytes.addingReportingOverflow(rawName.count)
    guard
      !entryCountOverflow,
      !rawNameBytesOverflow,
      depth <= limits.maximumDepth,
      newEntryCount <= limits.maximumEntries,
      newRawNameBytes <= limits.maximumRawNameBytes
    else {
      throw DescriptorObservationError.protectedDescendantLimitExceeded
    }
    observedEntryCount = newEntryCount
    observedRawNameBytes = newRawNameBytes
  }

  mutating func recordFailure(_ reason: RuleUnknownReason) {
    if failureReason == nil {
      failureReason = reason
    }
  }

  mutating func recordProtectedDescendant() {
    protectedDescendantWasObserved = true
  }

  func isStructurallyProtected(
    _ snapshot: DescriptorStatSnapshot,
    expectation: NPMCacheEntryExpectation?,
    repeatedDirectoryIdentity: Bool
  ) -> Bool {
    guard let expectation, snapshot.kind == expectation.expectedKind else {
      return true
    }
    guard
      snapshot.kind == .regularFile || snapshot.kind == .directory,
      snapshot.identity.device == rootDevice,
      snapshot.kind != .regularFile || snapshot.linkCount == 1,
      !repeatedDirectoryIdentity
    else {
      return true
    }
    if case .known(let uid) = accountUID, uid != 0, snapshot.ownerUID != uid {
      return true
    }
    return false
  }

  func result(expectedDescendantCount: UInt64) -> RuleObserved<Bool> {
    if protectedDescendantWasObserved {
      return .known(true)
    }
    if let failureReason {
      return .unknown(failureReason)
    }
    guard UInt64(observedEntryCount) == expectedDescendantCount else {
      return .unknown(.changedDuringObservation)
    }
    switch accountUID {
    case .known(let uid):
      return uid == 0 ? .unknown(.invalidMetadata) : .known(false)
    case .unknown(let reason):
      return .unknown(reason)
    }
  }
}

func evaluateAccountOwnedCacheNamespace(
  accountUID: RuleObserved<uid_t>,
  rootKind: FileSystemEntryKind,
  rootOwnerUID: uid_t,
  candidateKind: FileSystemEntryKind,
  candidateOwnerUID: uid_t,
  candidateOwnerRemainedStable: Bool = true
) -> RuleObserved<Bool> {
  guard rootKind == .directory, candidateKind == .directory else {
    return .known(false)
  }
  switch accountUID {
  case .known(let uid):
    guard uid != 0 else {
      return .unknown(.invalidMetadata)
    }
    guard candidateOwnerRemainedStable else {
      return .unknown(.changedDuringObservation)
    }
    return .known(rootOwnerUID == uid && candidateOwnerUID == uid)
  case .unknown(let reason):
    return .unknown(reason)
  }
}

private func exactStrictDescendantCount(for item: ScanItemSummary) -> UInt64? {
  guard
    item.kind == .directory,
    item.counts.directories > 0,
    item.counts.duplicateHardLinks <= item.counts.regularFiles
  else {
    return nil
  }

  var total: UInt64 = 0
  for count in [
    item.counts.regularFiles,
    item.counts.directories,
    item.counts.symbolicLinks,
    item.counts.other,
  ] {
    let (newTotal, overflow) = total.addingReportingOverflow(count)
    guard !overflow else { return nil }
    total = newTotal
  }
  guard total > 0 else { return nil }
  return total - 1
}

func accountOwnedCacheNamespaceAfterRootOwnerValidation(
  _ observation: RuleObserved<Bool>,
  applies: Bool,
  candidateKind: FileSystemEntryKind,
  rootOwnerRemainedStable: Bool
) -> RuleObserved<Bool> {
  guard
    !rootOwnerRemainedStable,
    applies,
    candidateKind == .directory,
    case .known = observation
  else {
    return observation
  }
  return .unknown(.changedDuringObservation)
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
