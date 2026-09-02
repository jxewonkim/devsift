import Darwin
import Foundation

struct CandidateRuleEvidence: Hashable, Sendable {
  let identityMatchesScan: RuleObserved<Bool>
  let generatedContentMarker: RuleObserved<Bool>

  static func unavailable(
    _ reason: RuleUnknownReason,
    observesGeneratedMarker: Bool
  ) -> CandidateRuleEvidence {
    CandidateRuleEvidence(
      identityMatchesScan: .unknown(reason),
      generatedContentMarker: observesGeneratedMarker
        ? .unknown(reason) : .unknown(.notCollected)
    )
  }
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

  private static let swiftBuildName = Array(".build".utf8)
  private static let swiftWorkspaceMarkerName = Array("workspace-state.json".utf8)

  private let checkpoint: Checkpoint
  private let afterRootValidation: RootHook
  private let beforeOpeningCandidate: CandidateHook
  private let beforeMarkerObservation: CandidateHook
  private let beforeFinalCandidateValidation: CandidateHook
  private let beforeFinalRootValidation: RootHook

  init() {
    checkpoint = { try Task.checkCancellation() }
    afterRootValidation = {}
    beforeOpeningCandidate = { _ in }
    beforeMarkerObservation = { _ in }
    beforeFinalCandidateValidation = { _ in }
    beforeFinalRootValidation = {}
  }

  init(
    checkpoint: @escaping Checkpoint = { try Task.checkCancellation() },
    afterRootValidation: @escaping RootHook = {},
    beforeOpeningCandidate: @escaping CandidateHook = { _ in },
    beforeMarkerObservation: @escaping CandidateHook = { _ in },
    beforeFinalCandidateValidation: @escaping CandidateHook = { _ in },
    beforeFinalRootValidation: @escaping RootHook = {}
  ) {
    self.checkpoint = checkpoint
    self.afterRootValidation = afterRootValidation
    self.beforeOpeningCandidate = beforeOpeningCandidate
    self.beforeMarkerObservation = beforeMarkerObservation
    self.beforeFinalCandidateValidation = beforeFinalCandidateValidation
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
      CandidateRuleEvidence.unavailable(
        .notCollected,
        observesGeneratedMarker: observesSwiftMarker(item)
      )
    }
    guard !items.isEmpty else {
      return RuleEvidenceObservation(candidates: result)
    }

    switch preflight(request) {
    case .unavailable(let reason):
      for index in result.indices {
        result[index] = CandidateRuleEvidence.unavailable(
          reason,
          observesGeneratedMarker: observesSwiftMarker(items[index])
        )
      }
      return RuleEvidenceObservation(candidates: result)
    case .ready(let rootIdentity, let duplicatePaths):
      let eligibleIndices = items.indices.filter { index in
        !duplicatePaths.contains(items[index].path)
      }
      for index in items.indices where duplicatePaths.contains(items[index].path) {
        result[index] = CandidateRuleEvidence.unavailable(
          .invalidMetadata,
          observesGeneratedMarker: observesSwiftMarker(items[index])
        )
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
          result[index] = CandidateRuleEvidence.unavailable(
            reason,
            observesGeneratedMarker: observesSwiftMarker(items[index])
          )
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
      descriptorRootURLIsValid(request.root)
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

    for index in indices {
      try cancellationCheckpoint()
      let item = request.report.topLevelItems[index]
      let observesMarker = observesSwiftMarker(item)
      guard
        let identity = item.scanTimeIdentity,
        let bytes = item.path.rawComponents.first,
        let component = DescriptorPathComponent(bytes)
      else {
        result[index] = .unavailable(
          .invalidMetadata,
          observesGeneratedMarker: observesMarker
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
          observesMarker: observesMarker
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        result[index] = .unavailable(
          descriptorUnknownReason(for: error),
          observesGeneratedMarker: observesMarker
        )
      }
    }

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
    observesMarker: Bool
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
        generatedContentMarker: observesMarker ? .known(false) : .unknown(.notCollected)
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
      try observesMarker
      ? observeSwiftWorkspaceMarker(
        in: candidateDescriptor,
        candidatePath: item.path,
        rootIdentity: rootIdentity
      ) : .unknown(.notCollected)

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
      generatedContentMarker: marker
    )
  }

  private func observeSwiftWorkspaceMarker(
    in candidateDescriptor: Int32,
    candidatePath: ScanRelativePath,
    rootIdentity: FileIdentity
  ) throws -> RuleObserved<Bool> {
    guard let markerName = DescriptorPathComponent(Self.swiftWorkspaceMarkerName) else {
      return .unknown(.invalidMetadata)
    }

    do {
      try beforeMarkerObservation(candidatePath)
      try cancellationCheckpoint()
      let marker = try DescriptorStatSnapshot.read(
        at: candidateDescriptor,
        component: markerName
      )
      guard marker.identity.device == rootIdentity.device else {
        return .unknown(.changedDuringObservation)
      }
      return .known(marker.kind == .regularFile)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as DescriptorObservationError {
      if case .posix(ENOENT) = error {
        return .known(false)
      }
      return .unknown(descriptorUnknownReason(for: error))
    } catch {
      return .unknown(descriptorUnknownReason(for: error))
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

  private func observesSwiftMarker(_ item: ScanItemSummary) -> Bool {
    item.path.rawComponents == [Self.swiftBuildName]
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

private enum DescriptorObservationError: Error {
  case bindingChanged
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

private func descriptorRootURLIsValid(_ url: URL) -> Bool {
  let hostIsLocal: Bool
  if let host = url.host, !host.isEmpty {
    hostIsLocal = host.caseInsensitiveCompare("localhost") == .orderedSame
  } else {
    hostIsLocal = true
  }
  return url.isFileURL
    && hostIsLocal
    && !url.path.utf8.contains(0)
    && !url.absoluteString.lowercased().contains("%00")
    && url.user == nil
    && url.password == nil
    && url.port == nil
    && url.query == nil
    && url.fragment == nil
    && url.pathComponents.first == "/"
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
  case ENOENT, ENOTDIR, ELOOP, ESTALE, EAGAIN: .changedDuringObservation
  case EMFILE, ENFILE, ENOMEM: .resourceLimit
  case EINVAL, EOVERFLOW, ENAMETOOLONG: .invalidMetadata
  case ENOTSUP: .unsupported
  default: .unspecified
  }
}
