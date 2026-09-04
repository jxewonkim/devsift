import Darwin
import Foundation

/// Bounded, non-path-bearing failures from the read-only npm execution
/// preflight. None of these cases imply that a filesystem mutation occurred.
enum DescriptorNPMQuarantinePreflightFailure: Error, Equatable, Sendable {
  case cancelled
  case invalidClaim
  case invalidCurrentAccount
  case invalidHome
  case sourceRootMismatch
  case rootUnavailable(CleanupQuarantineSystemFailure)
  case rootChanged
  case candidateMissing
  case candidateChanged
  case candidateUnsafe
  case layoutMismatch
  case traversalLimitExceeded
  case ageRequirementNotSatisfied
}

struct DescriptorNPMQuarantineTraversalLimits: Equatable, Sendable {
  static let defaults = DescriptorNPMQuarantineTraversalLimits(
    maximumEntries: 1_000_000,
    maximumDepth: 32,
    maximumRawNameBytes: 64 * 1_024 * 1_024
  )

  let maximumEntries: Int
  let maximumDepth: Int
  let maximumRawNameBytes: Int

  var isValid: Bool {
    maximumEntries >= 0 && maximumDepth >= 0 && maximumRawNameBytes >= 0
  }
}

/// Descriptor-backed source binding supplied only while all validated source
/// descriptors remain held. The descriptors are closed immediately after the
/// synchronous body returns and must never be stored for later work.
struct DescriptorNPMQuarantineCandidateScope {
  let heldRootDescriptor: Int32
  let heldCandidateDescriptor: Int32
  let rootSnapshot: DescriptorStatSnapshot
  let candidateSnapshot: DescriptorStatSnapshot
  let entry: CleanupManifestEntry
  let absoluteRootComponents: [DescriptorPathComponent]
  let homeComponentCount: Int
  let accountUID: uid_t

  fileprivate init(
    heldRootDescriptor: Int32,
    heldCandidateDescriptor: Int32,
    rootSnapshot: DescriptorStatSnapshot,
    candidateSnapshot: DescriptorStatSnapshot,
    entry: CleanupManifestEntry,
    absoluteRootComponents: [DescriptorPathComponent],
    homeComponentCount: Int,
    accountUID: uid_t
  ) {
    self.heldRootDescriptor = heldRootDescriptor
    self.heldCandidateDescriptor = heldCandidateDescriptor
    self.rootSnapshot = rootSnapshot
    self.candidateSnapshot = candidateSnapshot
    self.entry = entry
    self.absoluteRootComponents = absoluteRootComponents
    self.homeComponentCount = homeComponentCount
    self.accountUID = accountUID
  }
}

struct DescriptorNPMQuarantineClaimProjection: Equatable, Sendable {
  let sourceRoot: URL
  let expectedRootIdentity: FileIdentity
  let path: ScanRelativePath
  let expectedCandidateIdentity: FileIdentity
  let ruleRevision: RuleRevision
  let entry: CleanupManifestEntry
}

/// Reopens and completely validates the sole currently authorized npm cache
/// candidate without mutation. This type is internal and intended to run on
/// the executor's synchronous, non-suspending filesystem stack.
struct DescriptorNPMQuarantinePreflight: Sendable {
  typealias Checkpoint = @Sendable () throws -> Void
  typealias RawHomeProvider = @Sendable () -> RuleObserved<[UInt8]>
  typealias AccountUIDProvider = @Sendable () -> RuleObserved<uid_t>
  typealias Clock = @Sendable () -> Int64
  typealias Hook = @Sendable () throws -> Void
  typealias EntryHook = @Sendable (Int, Int) throws -> Void

  private static let npmRootComponent = Array(".npm".utf8)
  private static let candidateName = Array("_cacache".utf8)
  private static let contentDirectoryName = Array("content-v2".utf8)
  private static let indexDirectoryName = Array("index-v5".utf8)
  private static let minimumAgeSeconds: Int64 = 7 * 24 * 60 * 60

  private let checkpoint: Checkpoint
  private let rawHomeProvider: RawHomeProvider
  private let accountUIDProvider: AccountUIDProvider
  private let clock: Clock
  private let limits: DescriptorNPMQuarantineTraversalLimits
  private let afterRootValidation: Hook
  private let beforeOpeningCandidate: Hook
  private let beforeTraversalEntry: EntryHook
  private let beforeFinalValidation: Hook

  init() {
    checkpoint = { try Task.checkCancellation() }
    rawHomeProvider = { currentUIDRawHome() }
    accountUIDProvider = { currentNonRootAccountUID() }
    clock = { Int64(Date().timeIntervalSince1970.rounded(.down)) }
    limits = .defaults
    afterRootValidation = {}
    beforeOpeningCandidate = {}
    beforeTraversalEntry = { _, _ in }
    beforeFinalValidation = {}
  }

  init(
    checkpoint: @escaping Checkpoint = { try Task.checkCancellation() },
    rawHomeProvider: @escaping RawHomeProvider = { currentUIDRawHome() },
    accountUIDProvider: @escaping AccountUIDProvider = { currentNonRootAccountUID() },
    clock: @escaping Clock,
    limits: DescriptorNPMQuarantineTraversalLimits = .defaults,
    afterRootValidation: @escaping Hook = {},
    beforeOpeningCandidate: @escaping Hook = {},
    beforeTraversalEntry: @escaping EntryHook = { _, _ in },
    beforeFinalValidation: @escaping Hook = {}
  ) {
    self.checkpoint = checkpoint
    self.rawHomeProvider = rawHomeProvider
    self.accountUIDProvider = accountUIDProvider
    self.clock = clock
    self.limits = limits
    self.afterRootValidation = afterRootValidation
    self.beforeOpeningCandidate = beforeOpeningCandidate
    self.beforeTraversalEntry = beforeTraversalEntry
    self.beforeFinalValidation = beforeFinalValidation
  }

  /// Pure, filesystem-free defensive projection of the exact authorization v1
  /// claim accepted by this increment.
  static func validateClaim(
    _ claim: CleanupQuarantineExecutionClaim
  ) -> Result<DescriptorNPMQuarantineClaimProjection, DescriptorNPMQuarantinePreflightFailure> {
    let approval = claim.approval
    do {
      try CleanupApprovalValidator.validate(
        approval,
        supportedPolicyProvenance: .currentBuiltIn
      )
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch {
      return .failure(.invalidClaim)
    }

    let manifest = approval.reviewedManifest
    guard
      manifest.policyProvenance.classificationContractRevision
        == pinnedRevision("devsift.classification.explainable", 3),
      manifest.policyProvenance.catalogRevision
        == pinnedRevision("devsift.builtin-rules", 6),
      manifest.entries.count == 1,
      let entry = manifest.entries.first,
      entry.path.rawComponents == [candidateName],
      entry.expectedKind == .directory,
      entry.expectedIdentity.device == manifest.expectedRootIdentity.device,
      entry.ruleRevision == pinnedRevision("devsift.cache.npm", 5),
      entry.disposition == .reviewRequired,
      entry.reproducibility == .conditional,
      entry.responsibleTool == "npm",
      entry.deferredExecutionPreconditions
        == [.requiresUserAttestationThatResponsibleToolIsStopped],
      approval.preconditionReviewAcknowledgements.count == 1,
      let acknowledgement = approval.preconditionReviewAcknowledgements.first,
      acknowledgement.ordinal == 0,
      acknowledgement.path == entry.path,
      acknowledgement.ruleRevision == entry.ruleRevision,
      acknowledgement.precondition
        == .requiresUserAttestationThatResponsibleToolIsStopped,
      claim.attestation.statement
        == .responsibleToolStoppedAndUnobservedActivityRiskAccepted,
      claim.attestation.statement.policyRevision == 1,
      claim.attestation.request.requiredStatement == claim.attestation.statement,
      claim.attestation.request.subjects.count == 1,
      let subject = claim.attestation.request.subjects.first,
      subject.ordinal == 0,
      subject.path == entry.path,
      subject.ruleRevision == entry.ruleRevision,
      subject.responsibleTool == entry.responsibleTool,
      subject.precondition == acknowledgement.precondition,
      subject.precondition.policyRevision == 1
    else {
      return .failure(.invalidClaim)
    }

    return .success(
      DescriptorNPMQuarantineClaimProjection(
        sourceRoot: approval.sourceRoot,
        expectedRootIdentity: manifest.expectedRootIdentity,
        path: entry.path,
        expectedCandidateIdentity: entry.expectedIdentity,
        ruleRevision: entry.ruleRevision,
        entry: entry
      )
    )
  }

  /// Runs read-only validation without exposing the descriptor-held scope.
  func validateCandidate(
    claim: CleanupQuarantineExecutionClaim
  ) -> Result<Void, DescriptorNPMQuarantinePreflightFailure> {
    withValidatedCandidate(claim: claim) { _ in () }
  }

  /// Performs the only supported operation while the validated descriptors
  /// remain live. No caller can return or retain the raw descriptor scope.
  func moveValidatedCandidate(
    claim: CleanupQuarantineExecutionClaim,
    using mover: DescriptorExclusiveQuarantineMover
  ) -> Result<CleanupQuarantineExecutionReport, DescriptorNPMQuarantinePreflightFailure> {
    withValidatedCandidate(claim: claim, mover.move)
  }

  /// Holds every descriptor on this stack until `body` returns. This generic
  /// callback is private so the raw scope cannot escape the preflight API.
  private func withValidatedCandidate<ResultValue>(
    claim: CleanupQuarantineExecutionClaim,
    _ body: (DescriptorNPMQuarantineCandidateScope) -> ResultValue
  ) -> Result<ResultValue, DescriptorNPMQuarantinePreflightFailure> {
    let projection: DescriptorNPMQuarantineClaimProjection
    switch Self.validateClaim(claim) {
    case .success(let value):
      projection = value
    case .failure(let failure):
      return .failure(failure)
    }

    do {
      try cancellationCheckpoint()
      guard limits.isValid else {
        return .failure(.traversalLimitExceeded)
      }

      let accountUID: uid_t
      switch accountUIDProvider() {
      case .known(let value) where value != 0:
        accountUID = value
      case .known, .unknown:
        return .failure(.invalidCurrentAccount)
      }
      try cancellationCheckpoint()

      let rawHome: [UInt8]
      switch rawHomeProvider() {
      case .known(let value):
        rawHome = value
      case .unknown:
        return .failure(.invalidHome)
      }
      guard
        let homePath = DescriptorAbsolutePath(rawBytes: rawHome),
        !homePath.components.isEmpty
      else {
        return .failure(.invalidHome)
      }
      guard
        let npmComponent = DescriptorPathComponent(Self.npmRootComponent),
        let candidateComponent = DescriptorPathComponent(Self.candidateName),
        let suppliedRoot = descriptorAbsolutePath(for: projection.sourceRoot),
        suppliedRoot.rawComponents
          == (homePath.components.map(\.bytes) + [Self.npmRootComponent])
      else {
        return .failure(.sourceRootMismatch)
      }

      return try withOpenedScope(
        projection: projection,
        homeComponents: homePath.components,
        npmComponent: npmComponent,
        candidateComponent: candidateComponent,
        accountUID: accountUID,
        body
      )
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let failure as DescriptorNPMQuarantinePreflightFailure {
      return .failure(failure)
    } catch {
      return .failure(.rootUnavailable(systemFailure(for: error)))
    }
  }

  private func withOpenedScope<ResultValue>(
    projection: DescriptorNPMQuarantineClaimProjection,
    homeComponents: [DescriptorPathComponent],
    npmComponent: DescriptorPathComponent,
    candidateComponent: DescriptorPathComponent,
    accountUID: uid_t,
    _ body: (DescriptorNPMQuarantineCandidateScope) -> ResultValue
  ) throws -> Result<ResultValue, DescriptorNPMQuarantinePreflightFailure> {
    var slashDescriptor = try openSlash()
    defer { descriptorCloseIgnoringErrors(slashDescriptor) }

    var homeDescriptor: Int32 = -1
    do {
      for component in homeComponents {
        try cancellationCheckpoint()
        let child = try descriptorOpenTrustedDirectory(
          at: slashDescriptor,
          component: component
        )
        descriptorCloseIgnoringErrors(slashDescriptor)
        slashDescriptor = child
      }
      homeDescriptor = try descriptorOpenCurrentDirectory(slashDescriptor)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failure(.rootUnavailable(systemFailure(for: error)))
    }
    defer { descriptorCloseIgnoringErrors(homeDescriptor) }

    let homeSnapshot: DescriptorStatSnapshot
    do {
      homeSnapshot = try DescriptorStatSnapshot.read(from: homeDescriptor)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failure(.rootUnavailable(systemFailure(for: error)))
    }

    let rootDescriptor: Int32
    do {
      rootDescriptor = try descriptorOpenTrustedDirectory(
        at: homeDescriptor,
        component: npmComponent
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failure(.rootUnavailable(systemFailure(for: error)))
    }
    defer { descriptorCloseIgnoringErrors(rootDescriptor) }

    let rootSnapshot: DescriptorStatSnapshot
    do {
      rootSnapshot = try DescriptorStatSnapshot.read(from: rootDescriptor)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failure(.rootUnavailable(systemFailure(for: error)))
    }

    guard
      homeSnapshot.kind == .directory,
      homeSnapshot.ownerUID == accountUID,
      descriptorAccountOwnsWriteAccess(homeSnapshot),
      rootSnapshot.kind == .directory,
      rootSnapshot.identity == projection.expectedRootIdentity,
      rootSnapshot.identity.device == homeSnapshot.identity.device,
      rootSnapshot.ownerUID == accountUID,
      descriptorAccountOwnsWriteAccess(rootSnapshot)
    else {
      return .failure(.rootChanged)
    }
    do {
      guard try !descriptorHasExtendedACL(rootDescriptor) else {
        return .failure(.rootChanged)
      }
      try cancellationCheckpoint()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failure(.rootUnavailable(systemFailure(for: error)))
    }
    do {
      try afterRootValidation()
      try cancellationCheckpoint()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failure(.rootChanged)
    }

    let initiallyNamed: DescriptorStatSnapshot
    do {
      initiallyNamed = try DescriptorStatSnapshot.read(
        at: rootDescriptor,
        component: candidateComponent
      )
    } catch DescriptorObservationError.posix(ENOENT) {
      return .failure(.candidateMissing)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failure(.candidateChanged)
    }
    guard
      initiallyNamed.kind == .directory,
      initiallyNamed.identity == projection.expectedCandidateIdentity,
      initiallyNamed.identity.device == rootSnapshot.identity.device,
      initiallyNamed.ownerUID == accountUID
    else {
      return .failure(.candidateChanged)
    }

    let candidateDescriptor: Int32
    do {
      try beforeOpeningCandidate()
      try cancellationCheckpoint()
      candidateDescriptor = try descriptorOpenTrustedDirectory(
        at: rootDescriptor,
        component: candidateComponent
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failure(.candidateChanged)
    }
    defer { descriptorCloseIgnoringErrors(candidateDescriptor) }

    let candidateSnapshot: DescriptorStatSnapshot
    do {
      candidateSnapshot = try DescriptorStatSnapshot.read(from: candidateDescriptor)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failure(.candidateChanged)
    }
    guard stableSnapshot(candidateSnapshot, equals: initiallyNamed) else {
      return .failure(.candidateChanged)
    }
    guard
      candidateSnapshot.kind == .directory,
      candidateSnapshot.ownerUID == accountUID,
      descriptorAccountOwnsWriteAccess(candidateSnapshot)
    else {
      return .failure(.candidateUnsafe)
    }

    var state = TraversalState(
      limits: limits,
      accountUID: accountUID,
      rootDevice: rootSnapshot.identity.device,
      seenDirectoryIdentities: [candidateSnapshot.identity],
      newestModificationUnixSeconds: candidateSnapshot.conservativeModificationUnixSeconds
    )
    guard state.newestModificationUnixSeconds != nil else {
      return .failure(.candidateUnsafe)
    }
    do {
      try traverseDirectory(
        descriptor: candidateDescriptor,
        namedAt: rootDescriptor,
        component: candidateComponent,
        expected: candidateSnapshot,
        format: .cacheRoot,
        childDepth: 1,
        isCacheRoot: true,
        state: &state
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let failure as DescriptorNPMQuarantinePreflightFailure {
      return .failure(failure)
    } catch {
      return .failure(.candidateChanged)
    }

    guard state.requiredCacheRootNames == [Self.contentDirectoryName, Self.indexDirectoryName]
    else {
      return .failure(.layoutMismatch)
    }
    guard let newestModificationUnixSeconds = state.newestModificationUnixSeconds else {
      return .failure(.candidateUnsafe)
    }
    let referenceUnixSeconds = clock()
    let (oldestPermitted, underflow) = referenceUnixSeconds.subtractingReportingOverflow(
      Self.minimumAgeSeconds
    )
    guard
      !underflow,
      referenceUnixSeconds >= 0,
      newestModificationUnixSeconds <= referenceUnixSeconds,
      newestModificationUnixSeconds <= oldestPermitted
    else {
      return .failure(.ageRequirementNotSatisfied)
    }

    do {
      try beforeFinalValidation()
      try cancellationCheckpoint()
      let finalHome = try DescriptorStatSnapshot.read(from: homeDescriptor)
      let finalRoot = try DescriptorStatSnapshot.read(from: rootDescriptor)
      let finalOpenedCandidate = try DescriptorStatSnapshot.read(from: candidateDescriptor)
      let finalNamedCandidate = try DescriptorStatSnapshot.read(
        at: rootDescriptor,
        component: candidateComponent
      )
      guard
        stableSnapshot(finalHome, equals: homeSnapshot),
        stableSnapshot(finalRoot, equals: rootSnapshot),
        stableSnapshot(finalOpenedCandidate, equals: candidateSnapshot),
        stableSnapshot(finalNamedCandidate, equals: candidateSnapshot),
        finalRoot.ownerUID == accountUID,
        finalOpenedCandidate.ownerUID == accountUID
      else {
        return .failure(.candidateChanged)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .failure(.candidateChanged)
    }

    try cancellationCheckpoint()
    return .success(
      body(
        DescriptorNPMQuarantineCandidateScope(
          heldRootDescriptor: rootDescriptor,
          heldCandidateDescriptor: candidateDescriptor,
          rootSnapshot: rootSnapshot,
          candidateSnapshot: candidateSnapshot,
          entry: projection.entry,
          absoluteRootComponents: homeComponents + [npmComponent],
          homeComponentCount: homeComponents.count,
          accountUID: accountUID
        )
      )
    )
  }

  private func traverseDirectory(
    descriptor: Int32,
    namedAt parentDescriptor: Int32,
    component: DescriptorPathComponent,
    expected: DescriptorStatSnapshot,
    format: NPMCacheDirectoryFormat,
    childDepth: Int,
    isCacheRoot: Bool,
    state: inout TraversalState
  ) throws {
    try cancellationCheckpoint()
    let before = try DescriptorStatSnapshot.read(from: descriptor)
    guard stableSnapshot(before, equals: expected) else {
      throw DescriptorNPMQuarantinePreflightFailure.candidateChanged
    }
    guard try !descriptorHasExtendedACL(descriptor) else {
      throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
    }

    let enumerationDescriptor = try descriptorOpenCurrentDirectory(descriptor)
    guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
      let code = errno
      descriptorCloseIgnoringErrors(enumerationDescriptor)
      throw DescriptorObservationError.posix(code)
    }
    defer { _ = Darwin.closedir(stream) }

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
        break
      }
      interruptedAttempts = 0

      let rawName = descriptorRawName(from: entry)
      if rawName == [0x2E] || rawName == [0x2E, 0x2E] {
        continue
      }
      try state.record(rawName: rawName, depth: childDepth)
      try beforeTraversalEntry(state.entryCount, childDepth)
      try cancellationCheckpoint()
      guard
        let childComponent = DescriptorPathComponent(rawName),
        let expectation = format.expectation(for: rawName)
      else {
        throw DescriptorNPMQuarantinePreflightFailure.layoutMismatch
      }
      if isCacheRoot,
        rawName == Self.contentDirectoryName || rawName == Self.indexDirectoryName
      {
        state.requiredCacheRootNames.insert(rawName)
      }
      try traverseEntry(
        parentDescriptor: descriptor,
        component: childComponent,
        expectation: expectation,
        childDepth: childDepth,
        state: &state
      )
    }

    let finalOpened = try DescriptorStatSnapshot.read(from: descriptor)
    let finalNamed = try DescriptorStatSnapshot.read(
      at: parentDescriptor,
      component: component
    )
    guard
      stableSnapshot(finalOpened, equals: expected),
      stableSnapshot(finalNamed, equals: expected)
    else {
      throw DescriptorNPMQuarantinePreflightFailure.candidateChanged
    }
  }

  private func traverseEntry(
    parentDescriptor: Int32,
    component: DescriptorPathComponent,
    expectation: NPMCacheEntryExpectation,
    childDepth: Int,
    state: inout TraversalState
  ) throws {
    let namedBefore = try DescriptorStatSnapshot.read(
      at: parentDescriptor,
      component: component
    )
    guard
      let modificationUnixSeconds = namedBefore.conservativeModificationUnixSeconds,
      namedBefore.kind == expectation.expectedKind,
      namedBefore.identity.device == state.rootDevice,
      namedBefore.ownerUID == state.accountUID,
      descriptorAccountOwnsWriteAccess(namedBefore)
    else {
      throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
    }
    state.recordModification(modificationUnixSeconds)

    switch namedBefore.kind {
    case .regularFile:
      guard namedBefore.linkCount == 1 else {
        throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
      }
      let descriptor = try openRegularFile(
        at: parentDescriptor,
        component: component
      )
      defer { descriptorCloseIgnoringErrors(descriptor) }
      let opened = try DescriptorStatSnapshot.read(from: descriptor)
      let namedAfter = try DescriptorStatSnapshot.read(
        at: parentDescriptor,
        component: component
      )
      guard
        stableSnapshot(opened, equals: namedBefore),
        stableSnapshot(namedAfter, equals: namedBefore),
        opened.kind == .regularFile,
        opened.ownerUID == state.accountUID,
        opened.linkCount == 1,
        descriptorAccountOwnsWriteAccess(opened)
      else {
        throw DescriptorNPMQuarantinePreflightFailure.candidateChanged
      }
      guard try !descriptorHasExtendedACL(descriptor) else {
        throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
      }
    case .directory:
      guard
        let childFormat = expectation.childDirectoryFormat,
        state.seenDirectoryIdentities.insert(namedBefore.identity).inserted
      else {
        throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
      }
      let descriptor = try descriptorOpenTrustedDirectory(
        at: parentDescriptor,
        component: component
      )
      defer { descriptorCloseIgnoringErrors(descriptor) }
      let opened = try DescriptorStatSnapshot.read(from: descriptor)
      guard
        stableSnapshot(opened, equals: namedBefore),
        descriptorAccountOwnsWriteAccess(opened)
      else {
        throw DescriptorNPMQuarantinePreflightFailure.candidateChanged
      }
      let (nextDepth, overflow) = childDepth.addingReportingOverflow(1)
      guard !overflow else {
        throw DescriptorNPMQuarantinePreflightFailure.traversalLimitExceeded
      }
      try traverseDirectory(
        descriptor: descriptor,
        namedAt: parentDescriptor,
        component: component,
        expected: opened,
        format: childFormat,
        childDepth: nextDepth,
        isCacheRoot: false,
        state: &state
      )
    case .symbolicLink, .other:
      throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
    }
  }

  private func cancellationCheckpoint() throws {
    do {
      try checkpoint()
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw DescriptorNPMQuarantinePreflightFailure.cancelled
    }
  }
}

private struct TraversalState {
  let limits: DescriptorNPMQuarantineTraversalLimits
  let accountUID: uid_t
  let rootDevice: UInt64
  var seenDirectoryIdentities: Set<FileIdentity>
  var newestModificationUnixSeconds: Int64?
  var requiredCacheRootNames: Set<[UInt8]> = []
  var entryCount = 0
  var rawNameBytes = 0

  mutating func record(rawName: [UInt8], depth: Int) throws {
    let (newEntryCount, entryOverflow) = entryCount.addingReportingOverflow(1)
    let (newRawNameBytes, byteOverflow) = rawNameBytes.addingReportingOverflow(rawName.count)
    guard
      !entryOverflow,
      !byteOverflow,
      newEntryCount <= limits.maximumEntries,
      depth <= limits.maximumDepth,
      newRawNameBytes <= limits.maximumRawNameBytes
    else {
      throw DescriptorNPMQuarantinePreflightFailure.traversalLimitExceeded
    }
    entryCount = newEntryCount
    rawNameBytes = newRawNameBytes
  }

  mutating func recordModification(_ unixSeconds: Int64) {
    newestModificationUnixSeconds = max(newestModificationUnixSeconds ?? unixSeconds, unixSeconds)
  }
}

private func stableSnapshot(
  _ observed: DescriptorStatSnapshot,
  equals expected: DescriptorStatSnapshot
) -> Bool {
  observed.sameProtectedDescendantState(as: expected)
    && observed.permissionMode == expected.permissionMode
    && observed.flags == expected.flags
}

/// Group or other write access would let another account alter the namespace
/// or traversed cache content after validation. Owner write access may remain;
/// the explicit npm-stop attestation covers that same-account race.
private func descriptorAccountOwnsWriteAccess(
  _ snapshot: DescriptorStatSnapshot
) -> Bool {
  snapshot.permissionMode & mode_t(0o022) == 0 && snapshot.flags == 0
}

private func openSlash() throws -> Int32 {
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
  return descriptor
}

private func openRegularFile(
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
        O_EVTONLY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
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

private func pinnedRevision(_ identifier: String, _ version: UInt32) -> RuleRevision {
  guard
    let identifier = RuleIdentifier(rawValue: identifier),
    let version = RuleVersion(rawValue: version)
  else {
    preconditionFailure("The pinned npm quarantine revision is invalid")
  }
  return RuleRevision(identifier: identifier, version: version)
}

private func systemFailure(for error: Error) -> CleanupQuarantineSystemFailure {
  let code: Int32?
  if case DescriptorObservationError.posix(let value) = error {
    code = value
  } else {
    let nsError = error as NSError
    code = nsError.domain == NSPOSIXErrorDomain ? Int32(exactly: nsError.code) : nil
  }

  switch code {
  case EACCES, EPERM: return .permissionDenied
  case ENOENT, ENOTDIR, ELOOP, ESTALE, EAGAIN: return .pathChanged
  case EXDEV: return .crossDevice
  case EROFS: return .readOnlyFileSystem
  case ENOSPC, EDQUOT: return .noSpace
  case EMFILE, ENFILE, ENOMEM: return .resourceLimit
  case EINVAL, EOVERFLOW, ENAMETOOLONG: return .invalidMetadata
  case EIO: return .inputOutput
  case ENOTSUP: return .unsupported
  default: return .unspecified
  }
}
