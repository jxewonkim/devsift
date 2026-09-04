import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor-exclusive quarantine restorer")
struct DescriptorExclusiveQuarantineRestorerTests {
  @Test("A canonical restore invokes one exact rename and records a matching receipt")
  func canonicalRestore() async throws {
    let context = try await RestorerTestContext()

    let report = context.restorer.restore(context.scope)

    guard case .restored(let source, let quarantineNameWasRecreated) = report.status else {
      Issue.record("Expected restored status, got \(report.status)")
      return
    }
    #expect(source.rawComponents == [Array("_cacache".utf8)])
    #expect(!quarantineNameWasRecreated)
    #expect(report.isDurablyRestored)
    #expect(report.isDurablyRecorded)
    #expect(report.isCrashRecoverable)
    #expect(!report.performedPermanentDeletion)
    #expect(!report.overwroteExistingItem)
    #expect(!report.cancellationWasObservedAfterRename)

    let observation = context.probe.observation
    #expect(observation.beginCount == 1)
    #expect(observation.renameCount == 1)
    #expect(observation.finishCount == 1)
    #expect(observation.beginRootDescriptor == RestorerProbe.rootDescriptor)
    #expect(observation.beginQuarantineRootDescriptor == RestorerProbe.quarantineDescriptor)
    #expect(observation.beginItemDescriptor == RestorerProbe.itemDescriptor)
    #expect(observation.renameSourceDescriptor == RestorerProbe.quarantineDescriptor)
    #expect(observation.renameDestinationDescriptor == RestorerProbe.rootDescriptor)
    #expect(observation.renameSourceBytes == context.bundle.restoreIntent.quarantineItemComponent)
    #expect(observation.renameDestinationBytes == Array("_cacache".utf8))
    #expect(observation.renameFlags == DescriptorExclusiveQuarantineRestorer.renameFlags)
    #expect(
      observation.finishOutcome
        == .restored(quarantineNameWasRecreated: false)
    )
    #expect(observation.finishMutationMayHaveBeenInvoked == true)
    #expect(observation.treeValidationCount == 2)

    let beginIndex = try #require(observation.events.firstIndex(of: "journal-begin"))
    let treeIndices = observation.events.indices.filter {
      observation.events[$0] == "tree"
    }
    #expect(treeIndices.count == 2)
    #expect(treeIndices[0] < beginIndex)
    #expect(treeIndices[1] > beginIndex)
    let finalHookIndex = try #require(observation.events.firstIndex(of: "final-source-hook"))
    #expect(finalHookIndex > 0)
    #expect(observation.events[finalHookIndex - 1] == "named-source")
    #expect(observation.events[finalHookIndex + 1] == "rename")
  }

  @Test("A source created after the final absence check is never overwritten")
  func sourceRaceIsRejectedByExclusiveRename() async throws {
    let context = try await RestorerTestContext(
      configuration: RestorerConfiguration(
        renameBehavior: .fail(EEXIST),
        occupySourceAfterFinalAbsence: true
      ))

    let report = context.restorer.restore(context.scope)

    #expect(report.status == .notRestored(.sourceNameOccupied))
    #expect(report.isDurablyRecorded)
    #expect(!report.isDurablyRestored)
    #expect(!report.overwroteExistingItem)
    let observation = context.probe.observation
    #expect(observation.renameCount == 1)
    #expect(
      observation.finishOutcome
        == .notRestored(sourceNameWasOccupied: true)
    )
    #expect(observation.finishMutationMayHaveBeenInvoked == true)
  }

  @Test("Cancellation after durable intent reconciles while ignoring task cancellation")
  func cancellationAfterIntentClosesNotRestoredReceipt() async throws {
    let context = try await RestorerTestContext(
      configuration: RestorerConfiguration(cancelAfterDurableIntent: true)
    )

    let report = context.restorer.restore(context.scope)

    #expect(report.status == .notRestored(.cancelled))
    #expect(report.isDurablyRecorded)
    #expect(!report.cancellationWasObservedAfterRename)
    let observation = context.probe.observation
    #expect(observation.renameCount == 0)
    #expect(observation.finishCount == 1)
    #expect(
      observation.finishOutcome
        == .notRestored(sourceNameWasOccupied: false)
    )
    #expect(observation.finishMutationMayHaveBeenInvoked == false)
    #expect(observation.observationPoliciesAfterCancellation.allSatisfy { $0 == .ignore })
  }

  @Test("Cancellation after rename is latched but cannot skip reconciliation or receipt")
  func cancellationAfterRenameIsOnlyLatched() async throws {
    let context = try await RestorerTestContext(
      configuration: RestorerConfiguration(cancelAfterRename: true)
    )

    let report = context.restorer.restore(context.scope)

    guard case .restored = report.status else {
      Issue.record("Expected restored status, got \(report.status)")
      return
    }
    #expect(report.cancellationWasObservedAfterRename)
    #expect(report.isDurablyRestored)
    let observation = context.probe.observation
    #expect(observation.renameCount == 1)
    #expect(observation.finishCount == 1)
    #expect(observation.finishMutationMayHaveBeenInvoked == true)
    #expect(observation.observationPoliciesAfterCancellation.allSatisfy { $0 == .ignore })
  }

  @Test("An unsafe pre-intent full tree publishes no journal record")
  func unsafeTreeFailsClosed() async throws {
    let context = try await RestorerTestContext(
      configuration: RestorerConfiguration(treeBehavior: .unsafe)
    )

    let report = context.restorer.restore(context.scope)

    #expect(report.status == .notRestored(.quarantinedItemUnsafe))
    #expect(report.durabilityState == .notRecorded)
    let observation = context.probe.observation
    #expect(observation.treeValidationCount == 1)
    #expect(observation.beginCount == 0)
    #expect(observation.renameCount == 0)
    #expect(observation.finishCount == 0)
  }

  @Test("An item mutation after full traversal fails the final binding gate")
  func itemMutationAfterTreeFailsClosed() async throws {
    let context = try await RestorerTestContext(
      configuration: RestorerConfiguration(changeItemAfterTree: true)
    )

    let report = context.restorer.restore(context.scope)

    #expect(report.status == .notRestored(.quarantinedItemChanged))
    #expect(report.isDurablyRecorded)
    let observation = context.probe.observation
    #expect(observation.renameCount == 0)
    #expect(
      observation.finishOutcome
        == .notRestored(sourceNameWasOccupied: false)
    )
  }

  @Test("An occupied final source name prevents the rename without overwrite")
  func occupiedSourceBeforeRenameFailsClosed() async throws {
    let context = try await RestorerTestContext(
      configuration: RestorerConfiguration(sourceInitiallyOccupied: true)
    )

    let report = context.restorer.restore(context.scope)

    #expect(report.status == .notRestored(.sourceNameOccupied))
    #expect(report.isDurablyRecorded)
    #expect(!report.overwroteExistingItem)
    let observation = context.probe.observation
    #expect(observation.renameCount == 0)
    #expect(
      observation.finishOutcome
        == .notRestored(sourceNameWasOccupied: true)
    )
  }

  @Test("A success return without matching namespace truth remains recovery-required")
  func successfulReturnWithoutMoveDoesNotOverclaim() async throws {
    let context = try await RestorerTestContext(
      configuration: RestorerConfiguration(renameBehavior: .succeedWithoutMoving)
    )

    let report = context.restorer.restore(context.scope)

    guard case .manualRecoveryRequired(_, let reason) = report.status else {
      Issue.record("Expected manual recovery status, got \(report.status)")
      return
    }
    #expect(reason == .renameOutcomeIndeterminate)
    #expect(!report.isDurablyRestored)
    #expect(!report.isDurablyRecorded)
    #expect(report.isCrashRecoverable)
    #expect(
      report.durabilityState
        == .intentRecorded(restoreTransactionID: context.bundle.restoreIntent.restoreTransactionID)
    )
    let observation = context.probe.observation
    #expect(observation.renameCount == 1)
    #expect(observation.finishOutcome == .unresolved)
    #expect(observation.finishMutationMayHaveBeenInvoked == true)
  }

  @Test("A recovery-produced receipt returned inline is rejected as false durability")
  func recoveredReceiptCannotCompleteInlineAttempt() async throws {
    let context = try await RestorerTestContext(
      configuration: RestorerConfiguration(finishBehavior: .recoveredReceipt)
    )

    let report = context.restorer.restore(context.scope)

    guard case .manualRecoveryRequired(_, let reason) = report.status else {
      Issue.record("Expected manual recovery status, got \(report.status)")
      return
    }
    #expect(reason == .durabilityRecordingFailed)
    #expect(!report.isDurablyRestored)
    #expect(!report.isDurablyRecorded)
    #expect(
      report.durabilityState
        == .unresolved(restoreTransactionID: context.bundle.restoreIntent.restoreTransactionID)
    )
  }

  @Test("An unsupported exclusive rename gate publishes no restore intent")
  func unsupportedRenamePublishesNoIntent() async throws {
    let context = try await RestorerTestContext(
      configuration: RestorerConfiguration(supportsExclusiveRename: false)
    )

    let report = context.restorer.restore(context.scope)

    #expect(report.status == .notRestored(.exclusiveRenameUnsupported))
    #expect(report.durabilityState == .notRecorded)
    let observation = context.probe.observation
    #expect(observation.beginCount == 0)
    #expect(observation.renameCount == 0)
    #expect(observation.finishCount == 0)
  }

  @Test("Cancellation before durable intent publishes no journal record")
  func cancellationBeforeIntentPublishesNothing() async throws {
    let context = try await RestorerTestContext(
      configuration: RestorerConfiguration(cancelInitially: true)
    )

    let report = context.restorer.restore(context.scope)

    #expect(report.status == .notRestored(.cancelled))
    #expect(report.durabilityState == .notRecorded)
    let observation = context.probe.observation
    #expect(observation.beginCount == 0)
    #expect(observation.renameCount == 0)
    #expect(observation.finishCount == 0)
  }

  @Test("A mismatched journal session is released without claiming recoverability")
  func mismatchedJournalSessionFailsClosed() async throws {
    let context = try await RestorerTestContext(
      configuration: RestorerConfiguration(invalidSessionBytes: true)
    )

    let report = context.restorer.restore(context.scope)

    #expect(
      report.status
        == .manualRecoveryRequired(
          quarantineLocation: CleanupQuarantineLocation(
            relativePath: ScanRelativePath(
              rawComponents: [
                DescriptorExclusiveQuarantineMover.quarantineRootBytes,
                context.bundle.restoreIntent.quarantineItemComponent,
              ]),
            observedIdentity: nil
          ),
          reason: .quarantineJournalUnsafe
        )
    )
    #expect(!report.isCrashRecoverable)
    #expect(
      report.durabilityState
        == .unresolved(restoreTransactionID: context.bundle.restoreIntent.restoreTransactionID)
    )
    let observation = context.probe.observation
    #expect(observation.finishCount == 1)
    #expect(observation.finishOutcome == .unresolved)
    #expect(observation.renameCount == 0)
  }

  @Test("The exact npm rule revision from a supported historical intent is accepted")
  func historicalNPMRuleRevisionIsAccepted() async throws {
    let context = try await RestorerTestContext(historicalNPMRuleVersion: 4)

    let report = context.restorer.restore(context.scope)

    guard case .restored = report.status else {
      Issue.record("Expected restored status, got \(report.status)")
      return
    }
    #expect(context.scope.ruleRevision.version.rawValue == 4)
    #expect(report.ruleRevision == context.scope.ruleRevision)
    #expect(report.isDurablyRestored)
  }

  @Test("Safe current candidate mode and link-count changes are validated, not historically pinned")
  func safePostQuarantineContentChangeIsAccepted() async throws {
    let context = try await RestorerTestContext()

    #expect(context.bundle.restoreIntent.candidateBinding.permissionMode == 0o700)
    #expect(context.bundle.restoreIntent.candidateBinding.linkCount == 2)
    #expect(context.bundle.itemSnapshot.permissionMode == 0o500)
    #expect(context.bundle.itemSnapshot.linkCount == 4)

    let report = context.restorer.restore(context.scope)

    guard case .restored = report.status else {
      Issue.record("Expected restored status, got \(report.status)")
      return
    }
    #expect(report.isDurablyRestored)
    #expect(context.probe.observation.treeValidationCount == 2)
  }
}

private struct RestorerConfiguration: Sendable {
  var renameBehavior: RestorerRenameBehavior = .succeedAndMove
  var finishBehavior: RestorerFinishBehavior = .matchingReceipt
  var treeBehavior: RestorerTreeBehavior = .valid
  var supportsExclusiveRename = true
  var cancelInitially = false
  var sourceInitiallyOccupied = false
  var occupySourceAfterFinalAbsence = false
  var cancelAfterDurableIntent = false
  var cancelAfterRename = false
  var changeItemAfterTree = false
  var invalidSessionBytes = false
}

private enum RestorerRenameBehavior: Sendable {
  case succeedAndMove
  case succeedWithoutMoving
  case fail(Int32)
}

private enum RestorerFinishBehavior: Sendable {
  case matchingReceipt
  case recoveredReceipt
}

private enum RestorerTreeBehavior: Sendable {
  case valid
  case unsafe
}

private struct RestorerTestBundle: Sendable {
  let evidence: CleanupQuarantineRestorePreparedEvidence
  let restoreIntent: QuarantineRestoreJournalIntentV1
  let restoreIntentBytes: Data
  let ruleRevision: RuleRevision
  let historicalRootSnapshot: DescriptorStatSnapshot
  let historicalQuarantineSnapshot: DescriptorStatSnapshot
  let rootSnapshotAfterIntent: DescriptorStatSnapshot
  let quarantineSnapshotAfterIntent: DescriptorStatSnapshot
  let itemSnapshot: DescriptorStatSnapshot
}

private struct RestorerTestContext {
  let bundle: RestorerTestBundle
  let probe: RestorerProbe
  let scope: DescriptorNPMQuarantineRestoreScope
  let restorer: DescriptorExclusiveQuarantineRestorer

  init(
    configuration: RestorerConfiguration = RestorerConfiguration(),
    historicalNPMRuleVersion: UInt32? = nil
  ) async throws {
    let bundle = try restorerTestBundle(historicalNPMRuleVersion: historicalNPMRuleVersion)
    let claim = try await restorerTestClaim(bundle.evidence)
    let sessionBytes =
      configuration.invalidSessionBytes ? Data("{}".utf8) : bundle.restoreIntentBytes
    let session = DescriptorQuarantineRestoreJournalSession.testing(
      intent: bundle.restoreIntent,
      canonicalIntentBytes: sessionBytes,
      rootSnapshotAfterIntent: bundle.rootSnapshotAfterIntent,
      quarantineRootSnapshotAfterIntent: bundle.quarantineSnapshotAfterIntent
    )
    let probe = RestorerProbe(
      bundle: bundle,
      session: session,
      configuration: configuration
    )
    let recoveryRequest = DescriptorQuarantineJournalRecoveryRequest(
      rootDescriptor: RestorerProbe.rootDescriptor,
      quarantineRootDescriptor: RestorerProbe.quarantineDescriptor,
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
    self.probe = probe
    scope = DescriptorNPMQuarantineRestoreScope(
      heldRootDescriptor: RestorerProbe.rootDescriptor,
      heldQuarantineRootDescriptor: RestorerProbe.quarantineDescriptor,
      heldQuarantinedItemDescriptor: RestorerProbe.itemDescriptor,
      recoveryRequest: recoveryRequest,
      claim: claim,
      ruleRevision: bundle.ruleRevision
    )
    restorer = DescriptorExclusiveQuarantineRestorer(dependencies: probe.dependencies())
  }
}

private struct RestorerProbeObservation: Sendable {
  let events: [String]
  let beginCount: Int
  let beginRootDescriptor: Int32?
  let beginQuarantineRootDescriptor: Int32?
  let beginItemDescriptor: Int32?
  let treeValidationCount: Int
  let renameCount: Int
  let renameSourceDescriptor: Int32?
  let renameDestinationDescriptor: Int32?
  let renameSourceBytes: [UInt8]?
  let renameDestinationBytes: [UInt8]?
  let renameFlags: UInt32?
  let finishCount: Int
  let finishOutcome: DescriptorQuarantineRestoreJournalTerminalOutcome?
  let finishMutationMayHaveBeenInvoked: Bool?
  let observationPoliciesAfterCancellation: [RestorerObservedPolicy]
}

private enum RestorerObservedPolicy: Equatable, Sendable {
  case observe
  case ignore
}

private enum RestorerNameState {
  case missing
  case candidate
  case other
}

private final class RestorerProbe: @unchecked Sendable {
  static let rootDescriptor: Int32 = 101
  static let quarantineDescriptor: Int32 = 102
  static let itemDescriptor: Int32 = 103

  private let lock = NSLock()
  private let bundle: RestorerTestBundle
  private let session: DescriptorQuarantineRestoreJournalSession
  private let configuration: RestorerConfiguration
  private var events: [String] = []
  private var cancellationRequested: Bool
  private var rootSnapshot: DescriptorStatSnapshot
  private var quarantineSnapshot: DescriptorStatSnapshot
  private var itemSnapshot: DescriptorStatSnapshot
  private var sourceState: RestorerNameState
  private var quarantineItemState: RestorerNameState = .candidate
  private var beginCount = 0
  private var beginRootDescriptor: Int32?
  private var beginQuarantineRootDescriptor: Int32?
  private var beginItemDescriptor: Int32?
  private var treeValidationCount = 0
  private var renameCount = 0
  private var renameSourceDescriptor: Int32?
  private var renameDestinationDescriptor: Int32?
  private var renameSourceBytes: [UInt8]?
  private var renameDestinationBytes: [UInt8]?
  private var renameFlags: UInt32?
  private var finishCount = 0
  private var finishOutcome: DescriptorQuarantineRestoreJournalTerminalOutcome?
  private var finishMutationMayHaveBeenInvoked: Bool?
  private var observationPoliciesAfterCancellation: [RestorerObservedPolicy] = []

  init(
    bundle: RestorerTestBundle,
    session: DescriptorQuarantineRestoreJournalSession,
    configuration: RestorerConfiguration
  ) {
    self.bundle = bundle
    self.session = session
    self.configuration = configuration
    rootSnapshot = bundle.rootSnapshotAfterIntent
    quarantineSnapshot = bundle.quarantineSnapshotAfterIntent
    itemSnapshot = bundle.itemSnapshot
    sourceState = configuration.sourceInitiallyOccupied ? .other : .missing
    cancellationRequested = configuration.cancelInitially
  }

  var observation: RestorerProbeObservation {
    lock.withLock {
      RestorerProbeObservation(
        events: events,
        beginCount: beginCount,
        beginRootDescriptor: beginRootDescriptor,
        beginQuarantineRootDescriptor: beginQuarantineRootDescriptor,
        beginItemDescriptor: beginItemDescriptor,
        treeValidationCount: treeValidationCount,
        renameCount: renameCount,
        renameSourceDescriptor: renameSourceDescriptor,
        renameDestinationDescriptor: renameDestinationDescriptor,
        renameSourceBytes: renameSourceBytes,
        renameDestinationBytes: renameDestinationBytes,
        renameFlags: renameFlags,
        finishCount: finishCount,
        finishOutcome: finishOutcome,
        finishMutationMayHaveBeenInvoked: finishMutationMayHaveBeenInvoked,
        observationPoliciesAfterCancellation: observationPoliciesAfterCancellation
      )
    }
  }

  func dependencies() -> DescriptorExclusiveQuarantineRestorerDependencies {
    let journal = DescriptorQuarantineRestoreJournal(
      prepare: { _ in .failure(.invalidClaim) },
      begin: { [self] request in
        recordBegin(request)
        return .success(session)
      },
      finish: { [self] receivedSession, outcome, mutationWasInvoked in
        recordFinish(
          session: receivedSession,
          outcome: outcome,
          mutationWasInvoked: mutationWasInvoked
        )
        return finishResult(for: outcome)
      }
    )
    return DescriptorExclusiveQuarantineRestorerDependencies(
      currentAccountUID: { 501 },
      supportsResolveBeneathRename: { [configuration] in
        configuration.supportsExclusiveRename
      },
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
      volumeCapabilities: { [self] descriptor in
        volumeCapabilities(descriptor)
      },
      validateTree: { [self] descriptor, parent, component, expected, device, uid in
        try validateTree(
          descriptor: descriptor,
          parent: parent,
          component: component,
          expected: expected,
          device: device,
          uid: uid
        )
      },
      renameExclusive: { [self] sourceFD, source, destinationFD, destination, flags in
        rename(
          sourceFD: sourceFD,
          source: source,
          destinationFD: destinationFD,
          destination: destination,
          flags: flags
        )
      },
      journal: journal,
      cancellationIsRequested: { [self] in isCancellationRequested() },
      hooks: DescriptorExclusiveQuarantineRestorerHooks(
        afterDurableIntent: { [self] in afterDurableIntent() },
        afterFullTreeValidation: { [self] in afterFullTreeValidation() },
        afterFinalSourceAbsenceValidation: { [self] in afterFinalSourceAbsence() },
        afterRenameReturn: { [self] _ in afterRename() }
      )
    )
  }

  private func recordBegin(_ request: DescriptorQuarantineRestoreJournalBeginRequest) {
    lock.withLock {
      events.append("journal-begin")
      beginCount += 1
      beginRootDescriptor = request.recoveryRequest.rootDescriptor
      beginQuarantineRootDescriptor = request.recoveryRequest.quarantineRootDescriptor
      beginItemDescriptor = request.quarantinedItemDescriptor
    }
  }

  private func recordFinish(
    session receivedSession: DescriptorQuarantineRestoreJournalSession,
    outcome: DescriptorQuarantineRestoreJournalTerminalOutcome,
    mutationWasInvoked: Bool
  ) {
    lock.withLock {
      events.append("journal-finish")
      finishCount += 1
      if receivedSession !== session {
        events.append("wrong-session")
      }
      finishOutcome = outcome
      finishMutationMayHaveBeenInvoked = mutationWasInvoked
    }
  }

  private func finishResult(
    for outcome: DescriptorQuarantineRestoreJournalTerminalOutcome
  ) -> DescriptorQuarantineRestoreJournalFinishResult {
    guard outcome != .unresolved else {
      return .recoveryRequired(restoreTransactionID: bundle.restoreIntent.restoreTransactionID)
    }
    do {
      let producedByRecovery = configuration.finishBehavior == .recoveredReceipt
      let receipt: QuarantineRestoreJournalReceiptV1
      switch outcome {
      case .notRestored(let occupied):
        receipt = try QuarantineRestoreJournalV1Codec.makeReceipt(
          outcome: .notRestored,
          sourceNameWasOccupied: occupied,
          producedByRecovery: producedByRecovery,
          canonicalRestoreIntentBytes: bundle.restoreIntentBytes
        )
      case .restored(let recreated):
        receipt = try QuarantineRestoreJournalV1Codec.makeReceipt(
          outcome: .restored,
          quarantineNameWasRecreated: recreated,
          producedByRecovery: producedByRecovery,
          canonicalRestoreIntentBytes: bundle.restoreIntentBytes
        )
      case .unresolved:
        return .recoveryRequired(
          restoreTransactionID: bundle.restoreIntent.restoreTransactionID
        )
      }
      return .receiptRecorded(receipt)
    } catch {
      return .unresolved(restoreTransactionID: bundle.restoreIntent.restoreTransactionID)
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
      if parent == Self.rootDescriptor,
        component.bytes == DescriptorExclusiveQuarantineRestorer.sourceNameBytes
      {
        events.append("named-source")
        return try snapshot(for: sourceState)
      }
      if parent == Self.quarantineDescriptor,
        component.bytes == bundle.restoreIntent.quarantineItemComponent
      {
        events.append("named-item")
        return try snapshot(for: quarantineItemState)
      }
      throw DescriptorObservationError.posix(ENOENT)
    }
  }

  private func snapshot(for state: RestorerNameState) throws -> DescriptorStatSnapshot {
    switch state {
    case .missing:
      throw DescriptorObservationError.posix(ENOENT)
    case .candidate:
      return itemSnapshot
    case .other:
      return restorerSnapshot(device: 7, inode: 999, linkCount: 2, change: 30)
    }
  }

  private func hasExtendedACL(_ descriptor: Int32) -> Bool {
    lock.withLock {
      events.append("acl-\(descriptor)")
      return false
    }
  }

  private func volumeCapabilities(
    _ descriptor: Int32
  ) -> DescriptorQuarantineDependencyResult<DescriptorQuarantineVolumeCapabilities> {
    lock.withLock {
      events.append("volume-\(descriptor)")
      return .success(
        DescriptorQuarantineVolumeCapabilities(
          supportsExclusiveRename: true,
          supportsPOSIXPermissions: true
        ))
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
        component.bytes == bundle.restoreIntent.quarantineItemComponent,
        expected.sameProtectedDescendantState(as: itemSnapshot),
        device == bundle.restoreIntent.npmRootBinding.device,
        uid == 501
      else {
        throw DescriptorNPMQuarantinePreflightFailure.candidateChanged
      }
      if configuration.treeBehavior == .unsafe {
        throw DescriptorNPMQuarantinePreflightFailure.candidateUnsafe
      }
    }
  }

  private func rename(
    sourceFD: Int32,
    source: DescriptorQuarantineRelativePath,
    destinationFD: Int32,
    destination: DescriptorQuarantineRelativePath,
    flags: UInt32
  ) -> DescriptorExclusiveRenameResult {
    lock.withLock {
      events.append("rename")
      renameCount += 1
      renameSourceDescriptor = sourceFD
      renameDestinationDescriptor = destinationFD
      renameSourceBytes = source.bytes
      renameDestinationBytes = destination.bytes
      renameFlags = flags
      switch configuration.renameBehavior {
      case .succeedAndMove:
        sourceState = .candidate
        quarantineItemState = .missing
        rootSnapshot = restorerSnapshot(device: 7, inode: 10, linkCount: 11, change: 20)
        quarantineSnapshot = restorerSnapshot(
          device: 7,
          inode: 20,
          linkCount: 12,
          change: 20
        )
        itemSnapshot = restorerSnapshot(
          device: 7,
          inode: 30,
          linkCount: itemSnapshot.linkCount,
          change: 20,
          permissionMode: itemSnapshot.permissionMode
        )
        return .succeeded
      case .succeedWithoutMoving:
        return .succeeded
      case .fail(let code):
        return .failed(code)
      }
    }
  }

  private func afterDurableIntent() {
    lock.withLock {
      events.append("durable-intent-hook")
      if configuration.cancelAfterDurableIntent { cancellationRequested = true }
    }
  }

  private func afterFullTreeValidation() {
    lock.withLock {
      events.append("tree-hook")
      if configuration.changeItemAfterTree {
        itemSnapshot = restorerSnapshot(
          device: 7,
          inode: 30,
          linkCount: itemSnapshot.linkCount,
          change: 11,
          permissionMode: itemSnapshot.permissionMode
        )
      }
    }
  }

  private func afterFinalSourceAbsence() {
    lock.withLock {
      events.append("final-source-hook")
      if configuration.occupySourceAfterFinalAbsence { sourceState = .other }
    }
  }

  private func afterRename() {
    lock.withLock {
      events.append("rename-hook")
      if configuration.cancelAfterRename { cancellationRequested = true }
    }
  }

  private func isCancellationRequested() -> Bool {
    lock.withLock { cancellationRequested }
  }

  private func recordPolicyIfCancelled(_ policy: DescriptorCancellationPolicy) {
    guard cancellationRequested else { return }
    switch policy {
    case .observeTaskCancellation:
      observationPoliciesAfterCancellation.append(.observe)
    case .ignoreTaskCancellation:
      observationPoliciesAfterCancellation.append(.ignore)
    }
  }
}

private func restorerTestBundle(
  historicalNPMRuleVersion: UInt32?
) throws -> RestorerTestBundle {
  let historicalRoot = restorerSnapshot(
    device: 7,
    inode: 10,
    linkCount: 12,
    change: 1,
    permissionMode: 0o750
  )
  let historicalQuarantine = restorerSnapshot(device: 7, inode: 20, linkCount: 11, change: 1)
  let historicalItem = restorerSnapshot(device: 7, inode: 30, linkCount: 2, change: 1)
  let item = restorerSnapshot(
    device: 7,
    inode: 30,
    linkCount: 4,
    change: 10,
    permissionMode: 0o500
  )
  let rootBinding = try #require(QuarantineJournalFileBindingV1(snapshot: historicalRoot))
  let quarantineBinding = try #require(
    QuarantineJournalFileBindingV1(snapshot: historicalQuarantine)
  )
  let itemBinding = try #require(QuarantineJournalFileBindingV1(snapshot: historicalItem))
  let quarantineIntent = QuarantineJournalIntentV1(
    transactionID: String(repeating: "1", count: 32),
    npmRootBinding: rootBinding,
    quarantineRootBinding: quarantineBinding,
    candidateBinding: itemBinding,
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<QuarantineJournalIntentV1.destinationCount).map {
      restorerItemComponent($0)
    }
  )
  var quarantineIntentBytes = try QuarantineJournalV1Codec.encode(quarantineIntent)
  if let historicalNPMRuleVersion {
    let current = QuarantineJournalPolicyV1.current.npmRule
    let currentField = Data(
      "\"npmRuleRevision\":{\"identifier\":\"\(current.identifier)\",\"version\":\"\(current.version)\"}"
        .utf8
    )
    let historicalField = Data(
      "\"npmRuleRevision\":{\"identifier\":\"\(current.identifier)\",\"version\":\"\(historicalNPMRuleVersion)\"}"
        .utf8
    )
    let range = try #require(quarantineIntentBytes.range(of: currentField))
    quarantineIntentBytes.replaceSubrange(range, with: historicalField)
  }
  let decodedQuarantineIntent = try QuarantineJournalV1Codec.decodeIntent(quarantineIntentBytes)
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
  let restoreIntent = try QuarantineRestoreJournalV1Codec.makeIntent(
    restoreTransactionID: String(repeating: "a", count: 32),
    canonicalQuarantineIntentBytes: quarantineIntentBytes,
    canonicalQuarantineReceiptBytes: quarantineReceiptBytes
  )
  let restoreIntentBytes = try QuarantineRestoreJournalV1Codec.encode(
    restoreIntent,
    matchingQuarantineIntentBytes: quarantineIntentBytes,
    matchingQuarantineReceiptBytes: quarantineReceiptBytes
  )
  let ruleIdentifier = try #require(
    RuleIdentifier(rawValue: decodedQuarantineIntent.policy.npmRule.identifier)
  )
  let ruleVersion = try #require(
    RuleVersion(rawValue: decodedQuarantineIntent.policy.npmRule.version)
  )
  return RestorerTestBundle(
    evidence: CleanupQuarantineRestorePreparedEvidence(
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes,
      restoreIntent: restoreIntent
    ),
    restoreIntent: restoreIntent,
    restoreIntentBytes: restoreIntentBytes,
    ruleRevision: RuleRevision(identifier: ruleIdentifier, version: ruleVersion),
    historicalRootSnapshot: historicalRoot,
    historicalQuarantineSnapshot: historicalQuarantine,
    rootSnapshotAfterIntent: restorerSnapshot(
      device: 7,
      inode: 10,
      linkCount: 10,
      change: 10
    ),
    quarantineSnapshotAfterIntent: restorerSnapshot(
      device: 7,
      inode: 20,
      linkCount: 13,
      change: 10
    ),
    itemSnapshot: item
  )
}

private func restorerTestClaim(
  _ evidence: CleanupQuarantineRestorePreparedEvidence
) async throws -> CleanupQuarantineRestoreExecutionClaim {
  let session = try CleanupQuarantineRestoreAuthorizer().beginAttempt(for: evidence)
  let confirmation = CleanupQuarantineRestoreUserConfirmation(
    request: session.confirmationRequest,
    statement: session.confirmationRequest.requiredStatement
  )
  let authorization = try await session.authorize(using: confirmation)
  return try await authorization.consumeForExecution()
}

private func restorerSnapshot(
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

private func restorerItemComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal + 1, radix: 16)
  return Array("item-v1-\(String(repeating: "0", count: 32 - suffix.count))\(suffix)".utf8)
}
