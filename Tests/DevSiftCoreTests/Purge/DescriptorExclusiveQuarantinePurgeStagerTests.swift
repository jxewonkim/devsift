import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor-exclusive quarantine purge stager")
struct DescriptorExclusiveQuarantinePurgeStagerTests {
  @Test("A canonical initial attempt stages one exact receipt-bound work item")
  func canonicalStaging() async throws {
    let context = try await PurgeStagerTestContext()

    let result = context.stager.stage(context.scope)

    guard case .staged(let work) = result else {
      Issue.record("Expected staged work, got \(result)")
      return
    }
    #expect(work.workSnapshot.identity == context.bundle.itemSnapshot.identity)
    #expect(!work.quarantineNameWasRecreated)
    #expect(!work.cancellationWasObservedAfterRename)
    #expect(work.journalSession === context.session)

    let observation = context.probe.observation
    #expect(observation.beginCount == 1)
    #expect(observation.treeValidationCount == 2)
    #expect(observation.renameCount == 1)
    #expect(observation.syncCount == 1)
    #expect(observation.renameSourceDescriptor == PurgeStagerProbe.quarantineDescriptor)
    #expect(observation.renameDestinationDescriptor == PurgeStagerProbe.quarantineDescriptor)
    #expect(observation.renameSourceBytes == context.bundle.purgeIntent.quarantineItemComponent)
    #expect(observation.renameDestinationBytes == context.bundle.purgeIntent.purgeWorkComponent)
    #expect(observation.renameFlags == DescriptorExclusiveQuarantinePurgeStager.renameFlags)

    let beginIndex = try #require(observation.events.firstIndex(of: "journal-begin"))
    let treeIndices = observation.events.indices.filter {
      observation.events[$0] == "tree"
    }
    #expect(treeIndices.count == 2)
    #expect(treeIndices[0] < beginIndex)
    #expect(treeIndices[1] > beginIndex)
    let finalHook = try #require(observation.events.firstIndex(of: "final-work-hook"))
    #expect(observation.events[finalHook - 1] == "named-work")
    #expect(observation.events[finalHook + 1] == "rename")
    let renameIndex = try #require(observation.events.firstIndex(of: "rename"))
    let syncIndex = try #require(observation.events.firstIndex(of: "full-sync"))
    #expect(renameIndex < syncIndex)
  }

  @Test("Cancellation before intent publication performs no journal or rename operation")
  func cancellationBeforeIntent() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(cancelInitially: true)
    )

    let result = context.stager.stage(context.scope)

    guard case .notStaged(.cancelled) = result else {
      Issue.record("Expected pre-intent cancellation, got \(result)")
      return
    }
    #expect(context.probe.observation.beginCount == 0)
    #expect(context.probe.observation.renameCount == 0)
    #expect(context.probe.observation.syncCount == 0)
  }

  @Test("An unsafe first complete-tree traversal publishes no intent")
  func unsafeTreeBeforeIntent() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(unsafeTreeValidationNumber: 1)
    )

    let result = context.stager.stage(context.scope)

    guard case .notStaged(.quarantinedItemUnsafe) = result else {
      Issue.record("Expected unsafe-tree refusal, got \(result)")
      return
    }
    #expect(context.probe.observation.treeValidationCount == 1)
    #expect(context.probe.observation.beginCount == 0)
    #expect(context.probe.observation.renameCount == 0)
  }

  @Test("A disappearing tree entry cannot be mistaken for an absent work name")
  func treeEntryDisappearanceBeforeIntent() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(treeValidationPOSIXFailureNumber: 1)
    )

    let result = context.stager.stage(context.scope)

    guard case .notStaged(.quarantinedItemChanged) = result else {
      Issue.record("Expected changed-tree refusal, got \(result)")
      return
    }
    #expect(context.probe.observation.treeValidationCount == 1)
    #expect(context.probe.observation.beginCount == 0)
    #expect(context.probe.observation.renameCount == 0)
  }

  @Test("Cancellation after durable intent preserves the pending intent without rename")
  func cancellationAfterIntent() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(cancelAfterDurableIntent: true)
    )

    let result = context.stager.stage(context.scope)

    guard case .notStagedAfterIntent(let pending) = result,
      pending.failure == .cancelled
    else {
      Issue.record("Expected a pending cancelled intent, got \(result)")
      return
    }
    defer { pending.journalSession.releasePreservingIntent() }
    #expect(
      pending.journalSession.purgeTransactionID
        == context.bundle.purgeIntent.purgeTransactionID
    )
    #expect(!pending.stagingRenameWasInvoked)
    #expect(context.probe.observation.beginCount == 1)
    #expect(context.probe.observation.renameCount == 0)
    #expect(context.probe.observation.syncCount == 0)
  }

  @Test("A changed second tree validation preserves intent and never renames")
  func unsafeTreeAfterIntent() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(unsafeTreeValidationNumber: 2)
    )

    let result = context.stager.stage(context.scope)

    guard case .notStagedAfterIntent(let pending) = result,
      pending.failure == .quarantinedItemUnsafe
    else {
      Issue.record("Expected post-intent tree refusal, got \(result)")
      return
    }
    defer { pending.journalSession.releasePreservingIntent() }
    #expect(
      pending.journalSession.purgeTransactionID
        == context.bundle.purgeIntent.purgeTransactionID
    )
    #expect(!pending.stagingRenameWasInvoked)
    #expect(context.probe.observation.treeValidationCount == 2)
    #expect(context.probe.observation.renameCount == 0)
  }

  @Test("A work-name collision in the final race window is never overwritten")
  func finalWorkCollision() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(
        renameBehavior: .fail(EEXIST),
        occupyWorkAfterFinalAbsence: true
      )
    )

    let result = context.stager.stage(context.scope)

    guard case .unresolved(let transactionID) = result else {
      Issue.record("Expected unresolved raced collision, got \(result)")
      return
    }
    #expect(transactionID == context.bundle.purgeIntent.purgeTransactionID)
    #expect(context.probe.observation.renameCount == 1)
    #expect(context.probe.observation.syncCount == 0)
    #expect(context.probe.observation.workState == .other)
  }

  @Test("A rejected rename with Q intact retains a terminalization session")
  func rejectedRenameRetainsNotPurgedSession() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(renameBehavior: .fail(EIO))
    )

    let result = context.stager.stage(context.scope)

    guard case .notStagedAfterIntent(let pending) = result else {
      Issue.record("Expected a terminalizable not-staged result, got \(result)")
      return
    }
    defer { pending.journalSession.releasePreservingIntent() }
    #expect(pending.failure == .renameRejected(.inputOutput))
    #expect(pending.stagingRenameWasInvoked)
    #expect(context.probe.observation.renameCount == 1)
    #expect(context.probe.observation.quarantineItemState == .candidate)
    #expect(context.probe.observation.workState == .missing)
  }

  @Test("A successful rename return without matching namespace truth never stages")
  func successfulReturnWithoutMove() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(renameBehavior: .succeedWithoutMoving)
    )

    let result = context.stager.stage(context.scope)

    guard case .unresolved(let transactionID) = result else {
      Issue.record("Expected unresolved namespace truth, got \(result)")
      return
    }
    #expect(transactionID == context.bundle.purgeIntent.purgeTransactionID)
    #expect(context.probe.observation.renameCount == 1)
    #expect(context.probe.observation.syncCount == 0)
  }

  @Test("A quarantine-root barrier failure never claims a staging commit")
  func syncFailureIsUnresolved() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(fullSyncFailure: EIO)
    )

    let result = context.stager.stage(context.scope)

    guard case .unresolved(let transactionID) = result else {
      Issue.record("Expected unresolved durability, got \(result)")
      return
    }
    #expect(transactionID == context.bundle.purgeIntent.purgeTransactionID)
    #expect(context.probe.observation.renameCount == 1)
    #expect(context.probe.observation.syncCount == 1)
  }

  @Test("Late cancellation cannot skip reconciliation and the parent barrier")
  func cancellationAfterRename() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(cancelAfterRename: true)
    )

    let result = context.stager.stage(context.scope)

    guard case .staged(let work) = result else {
      Issue.record("Expected staged work after late cancellation, got \(result)")
      return
    }
    #expect(work.cancellationWasObservedAfterRename)
    #expect(context.probe.observation.renameCount == 1)
    #expect(context.probe.observation.syncCount == 1)
    #expect(
      context.probe.observation.policiesAfterCancellation.allSatisfy {
        $0 == .ignoreTaskCancellation
      }
    )
  }

  @Test("An unsafe held item cannot skip Q and W reconciliation after rename")
  func unsafeHeldItemStillReconcilesBothNames() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(makeHeldItemUnsafeAfterRename: true)
    )

    let result = context.stager.stage(context.scope)

    guard case .unresolved(let transactionID) = result else {
      Issue.record("Expected unresolved unsafe held item, got \(result)")
      return
    }
    #expect(transactionID == context.bundle.purgeIntent.purgeTransactionID)
    let observation = context.probe.observation
    let renameIndex = try #require(observation.events.firstIndex(of: "rename"))
    let afterRename = observation.events[(renameIndex + 1)...]
    #expect(afterRename.contains("named-item"))
    #expect(afterRename.contains("named-work"))
    #expect(observation.syncCount == 0)
  }

  @Test("A recreated quarantine name is preserved beside exact staged work")
  func recreatedQuarantineNameIsReported() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(recreateQuarantineNameAfterRename: true)
    )

    let result = context.stager.stage(context.scope)

    guard case .staged(let work) = result else {
      Issue.record("Expected staged work with recreated name, got \(result)")
      return
    }
    #expect(work.quarantineNameWasRecreated)
    #expect(context.probe.observation.quarantineItemState == .other)
    #expect(context.probe.observation.workState == .candidate)
  }

  @Test("An explicit-retry authority cannot publish or invoke initial staging")
  func retryClaimIsRejected() async throws {
    let bundle = try purgeStagerBundle()
    let claim = try await purgeStagerClaim(
      .explicitRetry(
        CleanupQuarantinePurgeRetryPreparedEvidence(
          canonicalQuarantineIntentBytes: bundle.evidence.canonicalQuarantineIntentBytes,
          canonicalQuarantineReceiptBytes: bundle.evidence.canonicalQuarantineReceiptBytes,
          purgeIntent: bundle.purgeIntent,
          canonicalPurgeIntentBytes: bundle.canonicalPurgeIntentBytes,
          currentWorkBinding: try #require(
            QuarantineJournalFileBindingV1(snapshot: bundle.itemSnapshot)
          )
        )
      )
    )
    let context = PurgeStagerTestContext(bundle: bundle, claim: claim)

    let result = context.stager.stage(context.scope)

    guard case .notStaged(.invalidClaim) = result else {
      Issue.record("Expected retry claim rejection, got \(result)")
      return
    }
    #expect(context.probe.observation.beginCount == 0)
    #expect(context.probe.observation.renameCount == 0)
  }

  @Test("A mismatched journal session never reaches rename")
  func mismatchedJournalSession() async throws {
    let context = try await PurgeStagerTestContext(
      configuration: PurgeStagerConfiguration(invalidSessionBytes: true)
    )

    let result = context.stager.stage(context.scope)

    guard case .unresolved(let transactionID) = result else {
      Issue.record("Expected unresolved mismatched session, got \(result)")
      return
    }
    #expect(transactionID == context.bundle.purgeIntent.purgeTransactionID)
    #expect(context.probe.observation.beginCount == 1)
    #expect(context.probe.observation.renameCount == 0)
  }
}

private struct PurgeStagerConfiguration: Sendable {
  var renameBehavior: PurgeStagerRenameBehavior = .succeedAndMove
  var cancelInitially = false
  var cancelAfterDurableIntent = false
  var cancelAfterRename = false
  var occupyWorkAfterFinalAbsence = false
  var recreateQuarantineNameAfterRename = false
  var makeHeldItemUnsafeAfterRename = false
  var unsafeTreeValidationNumber: Int?
  var treeValidationPOSIXFailureNumber: Int?
  var fullSyncFailure: Int32?
  var invalidSessionBytes = false
}

private enum PurgeStagerRenameBehavior: Sendable {
  case succeedAndMove
  case succeedWithoutMoving
  case fail(Int32)
}

private struct PurgeStagerTestBundle: Sendable {
  let evidence: CleanupQuarantinePurgeInitialPreparedEvidence
  let purgeIntent: QuarantinePurgeJournalIntentV1
  let canonicalPurgeIntentBytes: Data
  let rootSnapshotAfterIntent: DescriptorStatSnapshot
  let quarantineSnapshotAfterIntent: DescriptorStatSnapshot
  let itemSnapshot: DescriptorStatSnapshot
}

private struct PurgeStagerTestContext {
  let bundle: PurgeStagerTestBundle
  let session: DescriptorQuarantinePurgeJournalSession
  let probe: PurgeStagerProbe
  let scope: DescriptorNPMQuarantinePurgeStagingScope
  let stager: DescriptorExclusiveQuarantinePurgeStager

  init(configuration: PurgeStagerConfiguration = PurgeStagerConfiguration()) async throws {
    let bundle = try purgeStagerBundle()
    let claim = try await purgeStagerClaim(.initial(bundle.evidence))
    self.init(bundle: bundle, claim: claim, configuration: configuration)
  }

  init(
    bundle: PurgeStagerTestBundle,
    claim: CleanupQuarantinePurgeExecutionClaim,
    configuration: PurgeStagerConfiguration = PurgeStagerConfiguration()
  ) {
    let session = DescriptorQuarantinePurgeJournalSession.testing(
      intent: bundle.purgeIntent,
      canonicalIntentBytes: configuration.invalidSessionBytes
        ? Data("{}".utf8) : bundle.canonicalPurgeIntentBytes,
      rootSnapshotAfterIntent: bundle.rootSnapshotAfterIntent,
      quarantineRootSnapshotAfterIntent: bundle.quarantineSnapshotAfterIntent
    )
    let probe = PurgeStagerProbe(
      bundle: bundle,
      session: session,
      configuration: configuration
    )
    let request = DescriptorQuarantineJournalRecoveryRequest(
      rootDescriptor: PurgeStagerProbe.rootDescriptor,
      quarantineRootDescriptor: PurgeStagerProbe.quarantineDescriptor,
      quarantineRootComponent: DescriptorPathComponent(
        DescriptorExclusiveQuarantineMover.quarantineRootBytes
      )!,
      absoluteRootComponents: [
        DescriptorPathComponent(Array("Users".utf8))!,
        DescriptorPathComponent(Array("fixture".utf8))!,
        DescriptorPathComponent(Array(".npm".utf8))!,
      ],
      homeComponentCount: 2,
      accountUID: 501
    )
    self.bundle = bundle
    self.session = session
    self.probe = probe
    scope = DescriptorNPMQuarantinePurgeStagingScope(
      heldRootDescriptor: PurgeStagerProbe.rootDescriptor,
      heldQuarantineRootDescriptor: PurgeStagerProbe.quarantineDescriptor,
      heldQuarantinedItemDescriptor: PurgeStagerProbe.itemDescriptor,
      recoveryRequest: request,
      claim: claim
    )
    stager = DescriptorExclusiveQuarantinePurgeStager(
      dependencies: probe.dependencies()
    )
  }
}

private enum PurgeStagerNameState: Equatable, Sendable {
  case missing
  case candidate
  case other
}

private struct PurgeStagerObservation: Sendable {
  let events: [String]
  let beginCount: Int
  let treeValidationCount: Int
  let renameCount: Int
  let renameSourceDescriptor: Int32?
  let renameDestinationDescriptor: Int32?
  let renameSourceBytes: [UInt8]?
  let renameDestinationBytes: [UInt8]?
  let renameFlags: UInt32?
  let syncCount: Int
  let quarantineItemState: PurgeStagerNameState
  let workState: PurgeStagerNameState
  let policiesAfterCancellation: [DescriptorCancellationPolicy]
}

private final class PurgeStagerProbe: @unchecked Sendable {
  static let rootDescriptor: Int32 = 201
  static let quarantineDescriptor: Int32 = 202
  static let itemDescriptor: Int32 = 203

  private let lock = NSLock()
  private let bundle: PurgeStagerTestBundle
  private let session: DescriptorQuarantinePurgeJournalSession
  private let configuration: PurgeStagerConfiguration
  private var events: [String] = []
  private var cancellationRequested: Bool
  private var rootSnapshot: DescriptorStatSnapshot
  private var quarantineSnapshot: DescriptorStatSnapshot
  private var itemSnapshot: DescriptorStatSnapshot
  private var quarantineItemState: PurgeStagerNameState = .candidate
  private var workState: PurgeStagerNameState = .missing
  private var beginCount = 0
  private var treeValidationCount = 0
  private var renameCount = 0
  private var renameSourceDescriptor: Int32?
  private var renameDestinationDescriptor: Int32?
  private var renameSourceBytes: [UInt8]?
  private var renameDestinationBytes: [UInt8]?
  private var renameFlags: UInt32?
  private var syncCount = 0
  private var policiesAfterCancellation: [DescriptorCancellationPolicy] = []

  init(
    bundle: PurgeStagerTestBundle,
    session: DescriptorQuarantinePurgeJournalSession,
    configuration: PurgeStagerConfiguration
  ) {
    self.bundle = bundle
    self.session = session
    self.configuration = configuration
    cancellationRequested = configuration.cancelInitially
    rootSnapshot = bundle.rootSnapshotAfterIntent
    quarantineSnapshot = bundle.quarantineSnapshotAfterIntent
    itemSnapshot = bundle.itemSnapshot
  }

  var observation: PurgeStagerObservation {
    lock.withLock {
      PurgeStagerObservation(
        events: events,
        beginCount: beginCount,
        treeValidationCount: treeValidationCount,
        renameCount: renameCount,
        renameSourceDescriptor: renameSourceDescriptor,
        renameDestinationDescriptor: renameDestinationDescriptor,
        renameSourceBytes: renameSourceBytes,
        renameDestinationBytes: renameDestinationBytes,
        renameFlags: renameFlags,
        syncCount: syncCount,
        quarantineItemState: quarantineItemState,
        workState: workState,
        policiesAfterCancellation: policiesAfterCancellation
      )
    }
  }

  func dependencies() -> DescriptorExclusiveQuarantinePurgeStagerDependencies {
    DescriptorExclusiveQuarantinePurgeStagerDependencies(
      currentAccountUID: { 501 },
      supportsResolveBeneathRename: { true },
      readDescriptor: { [self] descriptor, policy in
        try readDescriptor(descriptor, policy: policy)
      },
      readNamed: { [self] parent, component, policy in
        try readNamed(parent: parent, component: component, policy: policy)
      },
      readAbsoluteRoot: { [self] _, _, policy in
        readAbsoluteRoot(policy: policy)
      },
      hasExtendedACL: { [self] descriptor in
        hasExtendedACL(descriptor)
      },
      volumeCapabilities: { _ in
        .success(
          DescriptorQuarantineVolumeCapabilities(
            supportsExclusiveRename: true,
            supportsPOSIXPermissions: true
          )
        )
      },
      validateCompleteTree: { [self] descriptor, parent, component, expected, device, uid in
        try validateTree(
          descriptor: descriptor,
          parent: parent,
          component: component,
          expected: expected,
          device: device,
          uid: uid
        )
      },
      renameExclusive: { [self] fromFD, from, toFD, to, flags in
        rename(fromFD: fromFD, from: from, toFD: toFD, to: to, flags: flags)
      },
      fullSync: { [self] descriptor in fullSync(descriptor) },
      journal: DescriptorQuarantinePurgeJournal(
        begin: { [self] request in
          recordBegin(request)
          return .success(session)
        }
      ),
      cancellationIsRequested: { [self] in isCancellationRequested() },
      hooks: DescriptorExclusiveQuarantinePurgeStagerHooks(
        afterDurableIntent: { [self] in afterDurableIntent() },
        afterFullTreeValidation: { [self] in afterFullTreeValidation() },
        afterFinalWorkAbsenceValidation: { [self] in afterFinalWorkAbsence() },
        afterRenameReturn: { [self] _ in afterRename() },
        beforeQuarantineRootSync: { [self] in recordBeforeSync() }
      )
    )
  }

  private func recordBegin(_ request: DescriptorQuarantinePurgeJournalBeginRequest) {
    lock.withLock {
      events.append("journal-begin")
      beginCount += 1
      if request.recoveryRequest.rootDescriptor != Self.rootDescriptor
        || request.recoveryRequest.quarantineRootDescriptor != Self.quarantineDescriptor
        || request.quarantinedItemDescriptor != Self.itemDescriptor
        || request.claim.attemptKind != .initial
      {
        events.append("wrong-begin-request")
      }
    }
  }

  private func readDescriptor(
    _ descriptor: Int32,
    policy: DescriptorCancellationPolicy
  ) throws -> DescriptorStatSnapshot {
    try lock.withLock {
      recordPolicyIfCancelled(policy)
      events.append("descriptor-\(descriptor)")
      switch descriptor {
      case Self.rootDescriptor:
        return rootSnapshot
      case Self.quarantineDescriptor:
        return quarantineSnapshot
      case Self.itemDescriptor:
        return itemSnapshot
      default:
        throw DescriptorObservationError.posix(EBADF)
      }
    }
  }

  private func readAbsoluteRoot(
    policy: DescriptorCancellationPolicy
  ) -> DescriptorStatSnapshot {
    lock.withLock {
      recordPolicyIfCancelled(policy)
      events.append("absolute-root")
      return rootSnapshot
    }
  }

  private func readNamed(
    parent: Int32,
    component: DescriptorPathComponent,
    policy: DescriptorCancellationPolicy
  ) throws -> DescriptorStatSnapshot {
    try lock.withLock {
      recordPolicyIfCancelled(policy)
      if parent == Self.rootDescriptor,
        component.bytes == DescriptorExclusiveQuarantineMover.quarantineRootBytes
      {
        events.append("named-quarantine-root")
        return quarantineSnapshot
      }
      if parent == Self.quarantineDescriptor,
        component.bytes == bundle.purgeIntent.quarantineItemComponent
      {
        events.append("named-item")
        return try snapshot(for: quarantineItemState)
      }
      if parent == Self.quarantineDescriptor,
        component.bytes == bundle.purgeIntent.purgeWorkComponent
      {
        events.append("named-work")
        return try snapshot(for: workState)
      }
      throw DescriptorObservationError.posix(ENOENT)
    }
  }

  private func snapshot(
    for state: PurgeStagerNameState
  ) throws -> DescriptorStatSnapshot {
    switch state {
    case .missing:
      throw DescriptorObservationError.posix(ENOENT)
    case .candidate:
      return itemSnapshot
    case .other:
      return purgeStagerSnapshot(device: 7, inode: 999, linkCount: 2, change: 30)
    }
  }

  private func hasExtendedACL(_ descriptor: Int32) -> Bool {
    lock.withLock {
      events.append("acl-\(descriptor)")
      return false
    }
  }

  private func validateTree(
    descriptor: Int32,
    parent: Int32,
    component: DescriptorPathComponent,
    expected: DescriptorStatSnapshot,
    device: UInt64,
    uid: uid_t
  ) throws {
    try lock.withLock {
      events.append("tree")
      treeValidationCount += 1
      guard
        descriptor == Self.itemDescriptor,
        parent == Self.quarantineDescriptor,
        component.bytes == bundle.purgeIntent.quarantineItemComponent,
        expected.sameProtectedDescendantState(as: itemSnapshot),
        device == bundle.purgeIntent.npmRootBinding.device,
        uid == 501
      else {
        throw DescriptorNPMPurgeTreeValidationFailure.treeChanged
      }
      if configuration.unsafeTreeValidationNumber == treeValidationCount {
        throw DescriptorNPMPurgeTreeValidationFailure.treeUnsafe
      }
      if configuration.treeValidationPOSIXFailureNumber == treeValidationCount {
        throw DescriptorObservationError.posix(ENOENT)
      }
    }
  }

  private func rename(
    fromFD: Int32,
    from: DescriptorQuarantineRelativePath,
    toFD: Int32,
    to: DescriptorQuarantineRelativePath,
    flags: UInt32
  ) -> DescriptorExclusiveRenameResult {
    lock.withLock {
      events.append("rename")
      renameCount += 1
      renameSourceDescriptor = fromFD
      renameDestinationDescriptor = toFD
      renameSourceBytes = from.bytes
      renameDestinationBytes = to.bytes
      renameFlags = flags
      switch configuration.renameBehavior {
      case .succeedAndMove:
        quarantineItemState = .missing
        workState = .candidate
        quarantineSnapshot = purgeStagerSnapshot(
          device: 7,
          inode: 20,
          linkCount: quarantineSnapshot.linkCount,
          change: 20
        )
        return .succeeded
      case .succeedWithoutMoving:
        return .succeeded
      case .fail(let code):
        return .failed(code)
      }
    }
  }

  private func fullSync(_ descriptor: Int32) -> Int32? {
    lock.withLock {
      events.append("full-sync")
      syncCount += 1
      guard descriptor == Self.quarantineDescriptor else { return EBADF }
      return configuration.fullSyncFailure
    }
  }

  private func afterDurableIntent() {
    lock.withLock {
      events.append("durable-intent-hook")
      if configuration.cancelAfterDurableIntent { cancellationRequested = true }
    }
  }

  private func afterFullTreeValidation() {
    lock.withLock { events.append("tree-hook") }
  }

  private func afterFinalWorkAbsence() {
    lock.withLock {
      events.append("final-work-hook")
      if configuration.occupyWorkAfterFinalAbsence { workState = .other }
    }
  }

  private func afterRename() {
    lock.withLock {
      events.append("rename-hook")
      if configuration.makeHeldItemUnsafeAfterRename {
        itemSnapshot = purgeStagerSnapshot(
          device: 7,
          inode: 30,
          linkCount: itemSnapshot.linkCount,
          change: itemSnapshot.changeSeconds,
          permissionMode: 0o722
        )
      }
      if configuration.recreateQuarantineNameAfterRename {
        quarantineItemState = .other
      }
      if configuration.cancelAfterRename { cancellationRequested = true }
    }
  }

  private func recordBeforeSync() {
    lock.withLock { events.append("before-sync-hook") }
  }

  private func isCancellationRequested() -> Bool {
    lock.withLock { cancellationRequested }
  }

  private func recordPolicyIfCancelled(_ policy: DescriptorCancellationPolicy) {
    if cancellationRequested { policiesAfterCancellation.append(policy) }
  }
}

private func purgeStagerBundle() throws -> PurgeStagerTestBundle {
  let historicalRoot = purgeStagerSnapshot(
    device: 7,
    inode: 10,
    linkCount: 12,
    change: 1,
    permissionMode: 0o750
  )
  let historicalQuarantine = purgeStagerSnapshot(
    device: 7,
    inode: 20,
    linkCount: 11,
    change: 1
  )
  let historicalItem = purgeStagerSnapshot(
    device: 7,
    inode: 30,
    linkCount: 2,
    change: 1
  )
  let item = purgeStagerSnapshot(
    device: 7,
    inode: 30,
    linkCount: 4,
    change: 10,
    permissionMode: 0o500
  )
  let quarantineIntent = QuarantineJournalIntentV1(
    transactionID: String(repeating: "1", count: 32),
    npmRootBinding: try #require(QuarantineJournalFileBindingV1(snapshot: historicalRoot)),
    quarantineRootBinding: try #require(
      QuarantineJournalFileBindingV1(snapshot: historicalQuarantine)
    ),
    candidateBinding: try #require(QuarantineJournalFileBindingV1(snapshot: historicalItem)),
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<QuarantineJournalIntentV1.destinationCount).map {
      purgeStagerItemComponent($0)
    }
  )
  let quarantineIntentBytes = try QuarantineJournalV1Codec.encode(quarantineIntent)
  let quarantineReceipt = try QuarantineJournalV1Codec.makeReceipt(
    outcome: .quarantined,
    selectedDestinationOrdinal: 3,
    producedByRecovery: false,
    canonicalIntentBytes: quarantineIntentBytes
  )
  let quarantineReceiptBytes = try QuarantineJournalV1Codec.encode(
    quarantineReceipt,
    matchingIntentBytes: quarantineIntentBytes
  )
  let purgeIntent = try QuarantinePurgeJournalV1Codec.makeIntent(
    purgeTransactionID: String(repeating: "a", count: 32),
    capacityBefore: QuarantinePurgeCapacityObservationV1(
      volumeIdentity: QuarantinePurgeVolumeIdentityV1(
        device: 7,
        fileSystemIDFirst: -2,
        fileSystemIDSecond: 9
      ),
      availableBytes: 4_096
    ),
    canonicalQuarantineIntentBytes: quarantineIntentBytes,
    canonicalQuarantineReceiptBytes: quarantineReceiptBytes
  )
  let purgeIntentBytes = try QuarantinePurgeJournalV1Codec.encode(
    purgeIntent,
    matchingQuarantineIntentBytes: quarantineIntentBytes,
    matchingQuarantineReceiptBytes: quarantineReceiptBytes
  )
  return PurgeStagerTestBundle(
    evidence: CleanupQuarantinePurgeInitialPreparedEvidence(
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes,
      purgeIntent: purgeIntent
    ),
    purgeIntent: purgeIntent,
    canonicalPurgeIntentBytes: purgeIntentBytes,
    rootSnapshotAfterIntent: purgeStagerSnapshot(
      device: 7,
      inode: 10,
      linkCount: 12,
      change: 10,
      permissionMode: 0o750
    ),
    quarantineSnapshotAfterIntent: purgeStagerSnapshot(
      device: 7,
      inode: 20,
      linkCount: 11,
      change: 10
    ),
    itemSnapshot: item
  )
}

private func purgeStagerClaim(
  _ evidence: CleanupQuarantinePurgePreparedEvidence
) async throws -> CleanupQuarantinePurgeExecutionClaim {
  let session = try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: evidence)
  let confirmation = CleanupQuarantinePurgeUserConfirmation(
    request: session.confirmationRequest,
    statement: session.confirmationRequest.requiredStatement
  )
  let authorization = try await session.authorize(using: confirmation)
  return try await authorization.consumeForExecution()
}

private func purgeStagerSnapshot(
  device: UInt64,
  inode: UInt64,
  linkCount: UInt64,
  change: Int,
  permissionMode: mode_t = 0o700
) -> DescriptorStatSnapshot {
  var information = stat()
  information.st_dev = dev_t(bitPattern: UInt32(device))
  information.st_ino = ino_t(inode)
  information.st_mode = mode_t(S_IFDIR) | permissionMode
  information.st_nlink = nlink_t(linkCount)
  information.st_uid = uid_t(501)
  information.st_flags = 0
  information.st_gen = 11
  information.st_birthtimespec.tv_sec = 1_725_000_000
  information.st_birthtimespec.tv_nsec = 123_456_789
  information.st_ctimespec.tv_sec = change
  information.st_ctimespec.tv_nsec = 0
  information.st_mtimespec.tv_sec = change
  information.st_mtimespec.tv_nsec = 0
  return DescriptorStatSnapshot(information: information)
}

private func purgeStagerItemComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal + 1, radix: 16)
  return Array("item-v1-\(String(repeating: "0", count: 32 - suffix.count))\(suffix)".utf8)
}
