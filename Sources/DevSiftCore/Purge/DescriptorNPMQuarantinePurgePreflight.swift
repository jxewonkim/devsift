import Darwin
import Foundation

/// Bounded failures produced by the read-only purge preparation boundary.
/// No case contains a caller-supplied path, identifier, or dependency string.
enum DescriptorNPMQuarantinePurgePreflightFailure: Error, Equatable, Sendable {
  case cancelled
  case unsupportedPlatform
  case invalidSelection
  case invalidClaim
  case invalidCurrentAccount
  case invalidHome
  case homeUnavailable(CleanupQuarantineSystemFailure)
  case homeUnsafe
  case rootUnavailable(CleanupQuarantineSystemFailure)
  case rootUnsafe
  case quarantineRootUnavailable(CleanupQuarantineSystemFailure)
  case quarantineRootUnsafe
  case journalRecordMissing
  case journalRecordChanged
  case journalRecordUnsafe
  case quarantinedItemMissing
  case quarantinedItemChanged
  case quarantinedItemUnsafe
  case purgeWorkMissing
  case purgeWorkChanged
  case purgeWorkUnsafe
  case purgeWorkNameOccupied
  case traversalLimitExceeded
  case capacityObservation(DescriptorQuarantinePurgeCapacityObservationFailure)
  case purgeIdentifierUnavailable
  case purgeIdentifierCollisionLimitExceeded
  case authorization(CleanupQuarantinePurgeAuthorizationError)
}

struct DescriptorNPMQuarantinePurgePreflightHooks: Sendable {
  var beforeFinalParentValidation: @Sendable () throws -> Void
  var beforeFinalEvidenceValidation: @Sendable () throws -> Void
  var beforeAuthorization: @Sendable () throws -> Void

  init(
    beforeFinalParentValidation: @escaping @Sendable () throws -> Void = {},
    beforeFinalEvidenceValidation: @escaping @Sendable () throws -> Void = {},
    beforeAuthorization: @escaping @Sendable () throws -> Void = {}
  ) {
    self.beforeFinalParentValidation = beforeFinalParentValidation
    self.beforeFinalEvidenceValidation = beforeFinalEvidenceValidation
    self.beforeAuthorization = beforeAuthorization
  }
}

/// Test seams do not broaden the production entry point: production discovery
/// remains fixed to passwd-home/`.npm`/`.devsift-quarantine-v1`.
struct DescriptorNPMQuarantinePurgePreflightDependencies: Sendable {
  typealias Checkpoint = @Sendable () throws -> Void
  typealias RawHomeProvider = @Sendable () -> RuleObserved<[UInt8]>
  typealias AccountUIDProvider = @Sendable () -> RuleObserved<uid_t>
  typealias NonceProvider = @Sendable (Int) -> [UInt8]?
  typealias ACLChecker = @Sendable (Int32) throws -> Bool
  typealias CompleteTreeValidator =
    @Sendable (
      Int32,
      Int32,
      DescriptorPathComponent,
      DescriptorStatSnapshot,
      UInt64,
      uid_t
    ) throws -> Void
  typealias RemainderTreeValidator =
    @Sendable (
      Int32,
      Int32,
      DescriptorPathComponent,
      QuarantineJournalFileBindingV1,
      UInt64,
      uid_t
    ) throws -> Void
  typealias BeginAuthorization =
    @Sendable (
      CleanupQuarantinePurgePreparedEvidence
    ) throws -> CleanupQuarantinePurgeAuthorizationSession

  var checkpoint: Checkpoint
  var rawHomeProvider: RawHomeProvider
  var accountUIDProvider: AccountUIDProvider
  var nonceBytes: NonceProvider
  var supportsDurablePurge: @Sendable () -> Bool
  var hasExtendedACL: ACLChecker
  var validateCompleteTree: CompleteTreeValidator
  var validateRemainderTree: RemainderTreeValidator
  var capacityObserver: DescriptorQuarantinePurgeCapacityObserver
  var beginAuthorization: BeginAuthorization
  var hooks: DescriptorNPMQuarantinePurgePreflightHooks

  init(
    checkpoint: @escaping Checkpoint = { try Task.checkCancellation() },
    rawHomeProvider: @escaping RawHomeProvider = { currentUIDRawHome() },
    accountUIDProvider: @escaping AccountUIDProvider = { currentNonRootAccountUID() },
    nonceBytes: @escaping NonceProvider = descriptorPurgePreflightRandomNonce,
    supportsDurablePurge: @escaping @Sendable () -> Bool = {
      ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
      )
    },
    hasExtendedACL: @escaping ACLChecker = descriptorHasExtendedACL,
    validateCompleteTree: @escaping CompleteTreeValidator =
      descriptorPurgePreflightValidateCompleteTree,
    validateRemainderTree: @escaping RemainderTreeValidator =
      descriptorPurgePreflightValidateRemainderTree,
    capacityObserver: DescriptorQuarantinePurgeCapacityObserver =
      DescriptorQuarantinePurgeCapacityObserver(),
    beginAuthorization: @escaping BeginAuthorization = {
      try CleanupQuarantinePurgeAuthorizer().beginAttempt(for: $0)
    },
    hooks: DescriptorNPMQuarantinePurgePreflightHooks =
      DescriptorNPMQuarantinePurgePreflightHooks()
  ) {
    self.checkpoint = checkpoint
    self.rawHomeProvider = rawHomeProvider
    self.accountUIDProvider = accountUIDProvider
    self.nonceBytes = nonceBytes
    self.supportsDurablePurge = supportsDurablePurge
    self.hasExtendedACL = hasExtendedACL
    self.validateCompleteTree = validateCompleteTree
    self.validateRemainderTree = validateRemainderTree
    self.capacityObserver = capacityObserver
    self.beginAuthorization = beginAuthorization
    self.hooks = hooks
  }
}

/// Descriptor-held retry scope. It is valid only for the synchronous callback
/// supplied to `withValidatedRetryClaim`; no path or transaction identifier is
/// accepted from the caller.
struct DescriptorNPMQuarantinePurgeRetryScope {
  let heldRootDescriptor: Int32
  let heldQuarantineRootDescriptor: Int32
  let heldPurgeWorkDescriptor: Int32
  let recoveryRequest: DescriptorQuarantineJournalRecoveryRequest
  let claim: CleanupQuarantinePurgeExecutionClaim
}

/// Read-only preparation and descriptor reopening for receipt-bound purge.
///
/// It never publishes a record, renames a name, or unlinks an entry. The only
/// production preparation input is an opaque inventory selection issued by
/// `QuarantineInventoryRestoreWorkflow`.
struct DescriptorNPMQuarantinePurgePreflight: Sendable {
  static let maximumPurgeIdentifierAttempts = 16

  private static let npmRootBytes = Array(".npm".utf8)
  private static let activeCacheBytes = Array("_cacache".utf8)
  private static let quarantineRootBytes =
    DescriptorExclusiveQuarantineMover.quarantineRootBytes

  private let dependencies: DescriptorNPMQuarantinePurgePreflightDependencies

  init(
    dependencies: DescriptorNPMQuarantinePurgePreflightDependencies =
      DescriptorNPMQuarantinePurgePreflightDependencies()
  ) {
    self.dependencies = dependencies
  }

  /// Resolves one exact inventory selection, reopens its canonical records and
  /// selected item, validates the full npm cache grammar, samples the held
  /// volume, and starts a process-local confirmation attempt.
  func prepareInitial(
    _ selection: QuarantineInventoryInitialPurgeSelection
  ) -> Result<
    CleanupQuarantinePurgeAuthorizationSession,
    DescriptorNPMQuarantinePurgePreflightFailure
  > {
    let entry = selection.entry
    guard entry.itemState == .available else {
      return .failure(.invalidSelection)
    }

    let pair: DescriptorPurgePreflightQuarantinePair
    do {
      pair = try decodeQuarantinePair(
        canonicalIntentBytes: entry.canonicalQuarantineIntentBytes,
        canonicalReceiptBytes: entry.canonicalQuarantineReceiptBytes
      )
      guard pair.intent.transactionID == entry.quarantineTransactionID else {
        return .failure(.invalidSelection)
      }
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch {
      return .failure(.invalidSelection)
    }

    return withValidatedParents(
      expectedRoot: pair.intent.npmRootBinding,
      expectedQuarantineRoot: pair.intent.quarantineRootBinding
    ) { context in
      guard dependencies.supportsDurablePurge() else {
        return .failure(.unsupportedPlatform)
      }

      let itemDescriptor: Int32
      do {
        try cancellationCheckpoint()
        try validateExactRecordPair(pair, in: context)
        itemDescriptor = try openInitialItem(pair, in: context)
      } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
        return .failure(failure)
      } catch is CancellationError {
        return .failure(.cancelled)
      } catch {
        return .failure(.quarantinedItemChanged)
      }
      defer { descriptorCloseIgnoringErrors(itemDescriptor) }

      do {
        try validateCompleteItem(
          descriptor: itemDescriptor,
          pair: pair,
          context: context
        )
      } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
        return .failure(failure)
      } catch is CancellationError {
        return .failure(.cancelled)
      } catch {
        return .failure(mapTreeFailure(error, retry: false))
      }

      let capacityBefore: QuarantinePurgeCapacityObservationV1
      switch dependencies.capacityObserver.observeBeforeIntent(
        fromHeldDescriptor: context.rootDescriptor,
        expectedDevice: pair.intent.npmRootBinding.device
      ) {
      case .success(let observation):
        capacityBefore = observation
      case .failure(let failure):
        return .failure(.capacityObservation(failure))
      }

      for attempt in 0..<Self.maximumPurgeIdentifierAttempts {
        do {
          try cancellationCheckpoint()
          guard
            let nonce = dependencies.nonceBytes(attempt),
            let purgeTransactionID = descriptorPurgePreflightIdentifier(nonce)
          else {
            if attempt + 1 < Self.maximumPurgeIdentifierAttempts { continue }
            return .failure(.purgeIdentifierUnavailable)
          }
          guard purgeTransactionID != pair.intent.transactionID else {
            if attempt + 1 < Self.maximumPurgeIdentifierAttempts { continue }
            return .failure(.purgeIdentifierCollisionLimitExceeded)
          }
          guard try purgeNamesAreAbsent(purgeTransactionID, in: context) else {
            if attempt + 1 < Self.maximumPurgeIdentifierAttempts { continue }
            return .failure(.purgeIdentifierCollisionLimitExceeded)
          }

          let intent = try QuarantinePurgeJournalV1Codec.makeIntent(
            purgeTransactionID: purgeTransactionID,
            capacityBefore: capacityBefore,
            canonicalQuarantineIntentBytes: entry.canonicalQuarantineIntentBytes,
            canonicalQuarantineReceiptBytes: entry.canonicalQuarantineReceiptBytes
          )
          guard intent.quarantineItemComponent != Self.activeCacheBytes else {
            return .failure(.invalidSelection)
          }

          try dependencies.hooks.beforeFinalEvidenceValidation()
          try cancellationCheckpoint()
          try validateParentsStillMatch(context)
          try validateExactRecordPair(pair, in: context)
          try validateInitialItemBinding(
            descriptor: itemDescriptor,
            pair: pair,
            context: context
          )
          try validateCompleteItem(
            descriptor: itemDescriptor,
            pair: pair,
            context: context
          )
          guard try purgeNamesAreAbsent(purgeTransactionID, in: context) else {
            if attempt + 1 < Self.maximumPurgeIdentifierAttempts { continue }
            return .failure(.purgeIdentifierCollisionLimitExceeded)
          }

          let evidence = CleanupQuarantinePurgePreparedEvidence.initial(
            CleanupQuarantinePurgeInitialPreparedEvidence(
              canonicalQuarantineIntentBytes: entry.canonicalQuarantineIntentBytes,
              canonicalQuarantineReceiptBytes: entry.canonicalQuarantineReceiptBytes,
              purgeIntent: intent
            ))
          try dependencies.hooks.beforeAuthorization()
          try cancellationCheckpoint()
          return .success(try dependencies.beginAuthorization(evidence))
        } catch is CancellationError {
          return .failure(.cancelled)
        } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
          return .failure(failure)
        } catch let failure as CleanupQuarantinePurgeAuthorizationError {
          return .failure(.authorization(failure))
        } catch {
          return .failure(.invalidSelection)
        }
      }
      return .failure(.purgeIdentifierCollisionLimitExceeded)
    }
  }

  /// Reopens and retains every descriptor needed by initial staging while the
  /// supplied synchronous body runs. Components come only from the normalized
  /// claim; the caller cannot supply a path, root, or transaction identifier.
  func withValidatedInitialClaim<ResultValue>(
    _ claim: CleanupQuarantinePurgeExecutionClaim,
    _ body: (DescriptorNPMQuarantinePurgeStagingScope) -> ResultValue
  ) -> Result<ResultValue, DescriptorNPMQuarantinePurgePreflightFailure> {
    guard claim.attemptKind == .initial,
      case .initial(let evidence) = claim.evidence
    else {
      return .failure(.invalidClaim)
    }

    let pair: DescriptorPurgePreflightQuarantinePair
    do {
      pair = try decodeQuarantinePair(
        canonicalIntentBytes: evidence.canonicalQuarantineIntentBytes,
        canonicalReceiptBytes: evidence.canonicalQuarantineReceiptBytes
      )
      try QuarantinePurgeJournalV1Codec.validate(
        evidence.purgeIntent,
        canonicalQuarantineIntentBytes: evidence.canonicalQuarantineIntentBytes,
        canonicalQuarantineReceiptBytes: evidence.canonicalQuarantineReceiptBytes
      )
    } catch {
      return .failure(.invalidClaim)
    }

    return withValidatedParents(
      expectedRoot: evidence.purgeIntent.npmRootBinding,
      expectedQuarantineRoot: evidence.purgeIntent.quarantineRootBinding
    ) { context in
      guard dependencies.supportsDurablePurge() else {
        return .failure(.unsupportedPlatform)
      }
      let itemDescriptor: Int32
      do {
        try validateExactRecordPair(pair, in: context)
        itemDescriptor = try openInitialItem(pair, in: context)
      } catch is CancellationError {
        return .failure(.cancelled)
      } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
        return .failure(failure)
      } catch {
        return .failure(.invalidClaim)
      }
      defer { descriptorCloseIgnoringErrors(itemDescriptor) }

      do {
        try validateCompleteItem(
          descriptor: itemDescriptor,
          pair: pair,
          context: context
        )
        guard try purgeNamesAreAbsent(evidence.purgeIntent.purgeTransactionID, in: context) else {
          return .failure(.purgeWorkNameOccupied)
        }
        let currentCapacity = dependencies.capacityObserver.observe(
          fromHeldDescriptor: context.rootDescriptor,
          expectedDevice: evidence.purgeIntent.npmRootBinding.device,
          expectedVolumeIdentity: evidence.purgeIntent.capacityBefore.volumeIdentity
        )
        guard case .success = currentCapacity else {
          if case .failure(let failure) = currentCapacity {
            return .failure(.capacityObservation(failure))
          }
          return .failure(.invalidClaim)
        }
        try dependencies.hooks.beforeFinalEvidenceValidation()
        try cancellationCheckpoint()
        try validateParentsStillMatch(context)
        try validateExactRecordPair(pair, in: context)
        try validateInitialItemBinding(
          descriptor: itemDescriptor,
          pair: pair,
          context: context
        )
        try validateCompleteItem(
          descriptor: itemDescriptor,
          pair: pair,
          context: context
        )
      } catch is CancellationError {
        return .failure(.cancelled)
      } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
        return .failure(failure)
      } catch {
        return .failure(mapTreeFailure(error, retry: false))
      }

      return .success(
        body(
          DescriptorNPMQuarantinePurgeStagingScope(
            heldRootDescriptor: context.rootDescriptor,
            heldQuarantineRootDescriptor: context.quarantineRootDescriptor,
            heldQuarantinedItemDescriptor: itemDescriptor,
            recoveryRequest: context.recoveryRequest,
            claim: claim
          )))
    }
  }

  /// Reopens one separately selected staged remainder and starts a distinct
  /// retry confirmation attempt. No new purge identifier or intent is made.
  func prepareExplicitRetry(
    _ selection: QuarantineInventoryPurgeRetrySelection
  ) -> Result<
    CleanupQuarantinePurgeAuthorizationSession,
    DescriptorNPMQuarantinePurgePreflightFailure
  > {
    let retry = selection.entry
    let pair: DescriptorPurgePreflightQuarantinePair
    let purgeIntent: QuarantinePurgeJournalIntentV1
    do {
      pair = try decodeQuarantinePair(
        canonicalIntentBytes: retry.canonicalQuarantineIntentBytes,
        canonicalReceiptBytes: retry.canonicalQuarantineReceiptBytes
      )
      purgeIntent = try QuarantinePurgeJournalV1Codec.decodeIntent(
        retry.canonicalPurgeIntentBytes,
        matchingQuarantineIntentBytes: retry.canonicalQuarantineIntentBytes,
        matchingQuarantineReceiptBytes: retry.canonicalQuarantineReceiptBytes
      )
      guard purgeIntent == retry.purgeIntent,
        descriptorPurgePreflightWorkBinding(
          retry.currentWorkBinding,
          matches: purgeIntent.candidateBinding
        )
      else {
        return .failure(.invalidSelection)
      }
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch {
      return .failure(.invalidSelection)
    }

    return withValidatedParents(
      expectedRoot: purgeIntent.npmRootBinding,
      expectedQuarantineRoot: purgeIntent.quarantineRootBinding
    ) { context in
      guard dependencies.supportsDurablePurge() else {
        return .failure(.unsupportedPlatform)
      }
      let workDescriptor: Int32
      do {
        try validateExactRecordPair(pair, in: context)
        try validateExactPurgeIntentRecord(
          retry.canonicalPurgeIntentBytes,
          intent: purgeIntent,
          in: context
        )
        try validateRetryOriginalItemName(pair, context: context)
        workDescriptor = try openRetryWork(purgeIntent, in: context)
      } catch is CancellationError {
        return .failure(.cancelled)
      } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
        return .failure(failure)
      } catch {
        return .failure(.purgeWorkChanged)
      }
      defer { descriptorCloseIgnoringErrors(workDescriptor) }

      do {
        try validateRetryWork(
          descriptor: workDescriptor,
          intent: purgeIntent,
          expectedCurrentBinding: retry.currentWorkBinding,
          context: context,
          validateRemainder: true
        )
        try dependencies.hooks.beforeFinalEvidenceValidation()
        try cancellationCheckpoint()
        try validateParentsStillMatch(context)
        try validateExactRecordPair(pair, in: context)
        try validateExactPurgeIntentRecord(
          retry.canonicalPurgeIntentBytes,
          intent: purgeIntent,
          in: context
        )
        try validateRetryOriginalItemName(pair, context: context)
        try validateRetryWork(
          descriptor: workDescriptor,
          intent: purgeIntent,
          expectedCurrentBinding: retry.currentWorkBinding,
          context: context,
          validateRemainder: true
        )

        let evidence = CleanupQuarantinePurgePreparedEvidence.explicitRetry(
          CleanupQuarantinePurgeRetryPreparedEvidence(
            canonicalQuarantineIntentBytes: retry.canonicalQuarantineIntentBytes,
            canonicalQuarantineReceiptBytes: retry.canonicalQuarantineReceiptBytes,
            purgeIntent: purgeIntent,
            canonicalPurgeIntentBytes: retry.canonicalPurgeIntentBytes,
            currentWorkBinding: retry.currentWorkBinding
          ))
        try dependencies.hooks.beforeAuthorization()
        try cancellationCheckpoint()
        return .success(try dependencies.beginAuthorization(evidence))
      } catch is CancellationError {
        return .failure(.cancelled)
      } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
        return .failure(failure)
      } catch let failure as CleanupQuarantinePurgeAuthorizationError {
        return .failure(.authorization(failure))
      } catch {
        return .failure(mapTreeFailure(error, retry: true))
      }
    }
  }

  /// Reopens a consumed retry claim and retains the exact work descriptor for
  /// the synchronous unlink orchestration callback.
  func withValidatedRetryClaim<ResultValue>(
    _ claim: CleanupQuarantinePurgeExecutionClaim,
    _ body: (DescriptorNPMQuarantinePurgeRetryScope) -> ResultValue
  ) -> Result<ResultValue, DescriptorNPMQuarantinePurgePreflightFailure> {
    guard claim.attemptKind == .explicitRetry,
      case .explicitRetry(let retry) = claim.evidence
    else {
      return .failure(.invalidClaim)
    }

    let pair: DescriptorPurgePreflightQuarantinePair
    let purgeIntent: QuarantinePurgeJournalIntentV1
    do {
      pair = try decodeQuarantinePair(
        canonicalIntentBytes: retry.canonicalQuarantineIntentBytes,
        canonicalReceiptBytes: retry.canonicalQuarantineReceiptBytes
      )
      purgeIntent = try QuarantinePurgeJournalV1Codec.decodeIntent(
        retry.canonicalPurgeIntentBytes,
        matchingQuarantineIntentBytes: retry.canonicalQuarantineIntentBytes,
        matchingQuarantineReceiptBytes: retry.canonicalQuarantineReceiptBytes
      )
      guard purgeIntent == retry.purgeIntent,
        descriptorPurgePreflightWorkBinding(
          retry.currentWorkBinding,
          matches: purgeIntent.candidateBinding
        )
      else {
        return .failure(.invalidClaim)
      }
    } catch {
      return .failure(.invalidClaim)
    }

    return withValidatedParents(
      expectedRoot: purgeIntent.npmRootBinding,
      expectedQuarantineRoot: purgeIntent.quarantineRootBinding
    ) { context in
      guard dependencies.supportsDurablePurge() else {
        return .failure(.unsupportedPlatform)
      }
      let workDescriptor: Int32
      do {
        try validateExactRecordPair(pair, in: context)
        try validateExactPurgeIntentRecord(
          retry.canonicalPurgeIntentBytes,
          intent: purgeIntent,
          in: context
        )
        try validateRetryOriginalItemName(pair, context: context)
        workDescriptor = try openRetryWork(purgeIntent, in: context)
      } catch is CancellationError {
        return .failure(.cancelled)
      } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
        return .failure(failure)
      } catch {
        return .failure(.invalidClaim)
      }
      defer { descriptorCloseIgnoringErrors(workDescriptor) }

      do {
        try validateRetryWork(
          descriptor: workDescriptor,
          intent: purgeIntent,
          expectedCurrentBinding: retry.currentWorkBinding,
          context: context,
          validateRemainder: true
        )
        try dependencies.hooks.beforeFinalEvidenceValidation()
        try cancellationCheckpoint()
        try validateParentsStillMatch(context)
        try validateExactRecordPair(pair, in: context)
        try validateExactPurgeIntentRecord(
          retry.canonicalPurgeIntentBytes,
          intent: purgeIntent,
          in: context
        )
        try validateRetryOriginalItemName(pair, context: context)
        try validateRetryWork(
          descriptor: workDescriptor,
          intent: purgeIntent,
          expectedCurrentBinding: retry.currentWorkBinding,
          context: context,
          validateRemainder: true
        )
      } catch is CancellationError {
        return .failure(.cancelled)
      } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
        return .failure(failure)
      } catch {
        return .failure(mapTreeFailure(error, retry: true))
      }

      return .success(
        body(
          DescriptorNPMQuarantinePurgeRetryScope(
            heldRootDescriptor: context.rootDescriptor,
            heldQuarantineRootDescriptor: context.quarantineRootDescriptor,
            heldPurgeWorkDescriptor: workDescriptor,
            recoveryRequest: context.recoveryRequest,
            claim: claim
          )))
    }
  }

  private func withValidatedParents<ResultValue>(
    expectedRoot: QuarantineJournalFileBindingV1,
    expectedQuarantineRoot: QuarantineJournalFileBindingV1,
    _ body: (DescriptorPurgePreflightContext) -> Result<
      ResultValue,
      DescriptorNPMQuarantinePurgePreflightFailure
    >
  ) -> Result<ResultValue, DescriptorNPMQuarantinePurgePreflightFailure> {
    do {
      try cancellationCheckpoint()
    } catch {
      return .failure(.cancelled)
    }

    let accountUID: uid_t
    switch dependencies.accountUIDProvider() {
    case .known(let value)
    where value != 0 && Darwin.getuid() == value && Darwin.geteuid() == value:
      accountUID = value
    case .known, .unknown:
      return .failure(.invalidCurrentAccount)
    }

    let rawHome: [UInt8]
    switch dependencies.rawHomeProvider() {
    case .known(let bytes):
      rawHome = bytes
    case .unknown:
      return .failure(.invalidHome)
    }
    guard
      let homePath = DescriptorAbsolutePath(rawBytes: rawHome),
      !homePath.components.isEmpty,
      let npmComponent = DescriptorPathComponent(Self.npmRootBytes),
      let quarantineComponent = DescriptorPathComponent(Self.quarantineRootBytes)
    else {
      return .failure(.invalidHome)
    }

    let homeDescriptor: Int32
    let homeSnapshot: DescriptorStatSnapshot
    do {
      (homeDescriptor, homeSnapshot) = try openValidatedHome(
        components: homePath.components,
        accountUID: accountUID
      )
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
      return .failure(failure)
    } catch {
      return .failure(.homeUnavailable(descriptorJournalFailure(for: error)))
    }
    defer { descriptorCloseIgnoringErrors(homeDescriptor) }

    let rootDescriptor: Int32
    do {
      rootDescriptor = try descriptorOpenTrustedDirectory(
        at: homeDescriptor,
        component: npmComponent
      )
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch {
      return .failure(.rootUnavailable(descriptorJournalFailure(for: error)))
    }
    defer { descriptorCloseIgnoringErrors(rootDescriptor) }

    let rootSnapshot: DescriptorStatSnapshot
    do {
      rootSnapshot = try validateRoot(
        descriptor: rootDescriptor,
        namedAt: homeDescriptor,
        component: npmComponent,
        homeSnapshot: homeSnapshot,
        accountUID: accountUID
      )
      guard descriptorPurgePreflightMatchesHistorical(rootSnapshot, expected: expectedRoot) else {
        return .failure(.rootUnsafe)
      }
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
      return .failure(failure)
    } catch {
      return .failure(.rootUnavailable(descriptorJournalFailure(for: error)))
    }

    let quarantineDescriptor: Int32
    do {
      quarantineDescriptor = try descriptorOpenTrustedDirectory(
        at: rootDescriptor,
        component: quarantineComponent
      )
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch {
      return .failure(.quarantineRootUnavailable(descriptorJournalFailure(for: error)))
    }
    defer { descriptorCloseIgnoringErrors(quarantineDescriptor) }

    let quarantineSnapshot: DescriptorStatSnapshot
    do {
      quarantineSnapshot = try validateQuarantineRoot(
        descriptor: quarantineDescriptor,
        namedAt: rootDescriptor,
        component: quarantineComponent,
        rootSnapshot: rootSnapshot,
        accountUID: accountUID
      )
      guard
        descriptorPurgePreflightMatchesHistorical(
          quarantineSnapshot,
          expected: expectedQuarantineRoot
        )
      else {
        return .failure(.quarantineRootUnsafe)
      }

      try dependencies.hooks.beforeFinalParentValidation()
      try cancellationCheckpoint()
      let finalHome = try DescriptorStatSnapshot.read(from: homeDescriptor)
      guard descriptorTrustedAncestorSnapshotsMatch(finalHome, homeSnapshot) else {
        return .failure(.homeUnsafe)
      }
      let finalRoot = try validateRoot(
        descriptor: rootDescriptor,
        namedAt: homeDescriptor,
        component: npmComponent,
        homeSnapshot: finalHome,
        accountUID: accountUID
      )
      guard descriptorPurgePreflightSnapshotsEqual(finalRoot, rootSnapshot) else {
        return .failure(.rootUnsafe)
      }
      let finalQuarantine = try validateQuarantineRoot(
        descriptor: quarantineDescriptor,
        namedAt: rootDescriptor,
        component: quarantineComponent,
        rootSnapshot: finalRoot,
        accountUID: accountUID
      )
      guard descriptorPurgePreflightSnapshotsEqual(finalQuarantine, quarantineSnapshot) else {
        return .failure(.quarantineRootUnsafe)
      }
      let rootFromSlash = try descriptorSnapshot(
        atAbsoluteComponents: homePath.components + [npmComponent],
        homeComponentCount: homePath.components.count
      )
      let quarantineFromSlash = try descriptorSnapshot(
        atAbsoluteComponents: homePath.components + [npmComponent, quarantineComponent],
        homeComponentCount: homePath.components.count
      )
      guard descriptorPurgePreflightSnapshotsEqual(rootFromSlash, finalRoot) else {
        return .failure(.rootUnsafe)
      }
      guard descriptorPurgePreflightSnapshotsEqual(quarantineFromSlash, finalQuarantine) else {
        return .failure(.quarantineRootUnsafe)
      }
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let failure as DescriptorNPMQuarantinePurgePreflightFailure {
      return .failure(failure)
    } catch {
      return .failure(.quarantineRootUnavailable(descriptorJournalFailure(for: error)))
    }

    let recoveryRequest = DescriptorQuarantineJournalRecoveryRequest(
      rootDescriptor: rootDescriptor,
      quarantineRootDescriptor: quarantineDescriptor,
      quarantineRootComponent: quarantineComponent,
      absoluteRootComponents: homePath.components + [npmComponent],
      homeComponentCount: homePath.components.count,
      accountUID: accountUID
    )
    return body(
      DescriptorPurgePreflightContext(
        homeDescriptor: homeDescriptor,
        rootDescriptor: rootDescriptor,
        quarantineRootDescriptor: quarantineDescriptor,
        homeSnapshot: homeSnapshot,
        rootSnapshot: rootSnapshot,
        quarantineRootSnapshot: quarantineSnapshot,
        homeComponents: homePath.components,
        npmComponent: npmComponent,
        quarantineComponent: quarantineComponent,
        accountUID: accountUID,
        recoveryRequest: recoveryRequest
      ))
  }

  private func openValidatedHome(
    components: [DescriptorPathComponent],
    accountUID: uid_t
  ) throws -> (Int32, DescriptorStatSnapshot) {
    var traversal = try descriptorOpenRoot(URL(fileURLWithPath: "/", isDirectory: true))
    do {
      var final: DescriptorStatSnapshot?
      for (ordinal, component) in components.enumerated() {
        try cancellationCheckpoint()
        let before = try DescriptorStatSnapshot.read(at: traversal, component: component)
        let child = try descriptorOpenTrustedDirectory(at: traversal, component: component)
        let held = try DescriptorStatSnapshot.read(from: child)
        let after = try DescriptorStatSnapshot.read(at: traversal, component: component)
        guard
          descriptorTrustedAncestorSnapshotsMatch(before, held),
          descriptorTrustedAncestorSnapshotsMatch(after, held)
        else {
          descriptorCloseIgnoringErrors(child)
          throw DescriptorNPMQuarantinePurgePreflightFailure.homeUnsafe
        }
        descriptorCloseIgnoringErrors(traversal)
        traversal = child
        if ordinal + 1 == components.count { final = held }
      }
      guard let snapshot = final else {
        throw DescriptorNPMQuarantinePurgePreflightFailure.invalidHome
      }
      guard
        snapshot.kind == .directory,
        snapshot.ownerUID == accountUID,
        snapshot.permissionMode & mode_t(0o022) == 0,
        snapshot.flags == 0
      else {
        throw DescriptorNPMQuarantinePurgePreflightFailure.homeUnsafe
      }
      return (traversal, snapshot)
    } catch {
      descriptorCloseIgnoringErrors(traversal)
      throw error
    }
  }

  private func validateRoot(
    descriptor: Int32,
    namedAt parentDescriptor: Int32,
    component: DescriptorPathComponent,
    homeSnapshot: DescriptorStatSnapshot,
    accountUID: uid_t
  ) throws -> DescriptorStatSnapshot {
    let held = try DescriptorStatSnapshot.read(from: descriptor)
    let named = try DescriptorStatSnapshot.read(at: parentDescriptor, component: component)
    guard
      descriptorPurgePreflightSnapshotsEqual(held, named),
      held.kind == .directory,
      held.identity.device == homeSnapshot.identity.device,
      held.ownerUID == accountUID,
      held.permissionMode & mode_t(0o022) == 0,
      held.flags == 0,
      try !dependencies.hasExtendedACL(descriptor)
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.rootUnsafe
    }
    return held
  }

  private func validateQuarantineRoot(
    descriptor: Int32,
    namedAt parentDescriptor: Int32,
    component: DescriptorPathComponent,
    rootSnapshot: DescriptorStatSnapshot,
    accountUID: uid_t
  ) throws -> DescriptorStatSnapshot {
    let held = try DescriptorStatSnapshot.read(from: descriptor)
    let named = try DescriptorStatSnapshot.read(at: parentDescriptor, component: component)
    guard
      descriptorPurgePreflightSnapshotsEqual(held, named),
      held.kind == .directory,
      held.identity.device == rootSnapshot.identity.device,
      held.ownerUID == accountUID,
      held.permissionMode == mode_t(0o700),
      held.flags == 0,
      try !dependencies.hasExtendedACL(descriptor)
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.quarantineRootUnsafe
    }
    return held
  }

  private func decodeQuarantinePair(
    canonicalIntentBytes: Data,
    canonicalReceiptBytes: Data
  ) throws -> DescriptorPurgePreflightQuarantinePair {
    try cancellationCheckpoint()
    let intent = try QuarantineJournalV1Codec.decodeIntent(canonicalIntentBytes)
    let receipt = try QuarantineJournalV1Codec.decodeReceipt(
      canonicalReceiptBytes,
      matchingIntentBytes: canonicalIntentBytes
    )
    guard
      receipt.outcome == .quarantined,
      let ordinal = receipt.selectedDestinationOrdinal,
      intent.destinationComponents.indices.contains(ordinal),
      receipt.destinationBinding == intent.candidateBinding,
      intent.sourceComponents == [Self.activeCacheBytes],
      let itemComponent = DescriptorPathComponent(intent.destinationComponents[ordinal]),
      itemComponent.bytes != Self.activeCacheBytes
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.invalidSelection
    }
    return DescriptorPurgePreflightQuarantinePair(
      intent: intent,
      receipt: receipt,
      itemComponent: itemComponent,
      canonicalIntentBytes: canonicalIntentBytes,
      canonicalReceiptBytes: canonicalReceiptBytes
    )
  }

  private func validateExactRecordPair(
    _ pair: DescriptorPurgePreflightQuarantinePair,
    in context: DescriptorPurgePreflightContext
  ) throws {
    guard
      let intentName = descriptorPurgePreflightRecordComponent(
        prefix: ".intent-v1-",
        transactionID: pair.intent.transactionID
      ),
      let receiptName = descriptorPurgePreflightRecordComponent(
        prefix: ".receipt-v1-",
        transactionID: pair.intent.transactionID
      )
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.invalidSelection
    }
    try readExactRecord(
      intentName,
      expectedBytes: pair.canonicalIntentBytes,
      in: context
    )
    try readExactRecord(
      receiptName,
      expectedBytes: pair.canonicalReceiptBytes,
      in: context
    )
  }

  private func readExactRecord(
    _ component: DescriptorPathComponent,
    expectedBytes: Data,
    in context: DescriptorPurgePreflightContext
  ) throws {
    guard
      !expectedBytes.isEmpty,
      expectedBytes.count
        <= max(
          QuarantineJournalV1Codec.maximumEncodedByteCount,
          QuarantinePurgeJournalV1Codec.maximumEncodedByteCount
        )
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.journalRecordUnsafe
    }
    var descriptor = Int32(-1)
    var failureCode = Int32(EINVAL)
    for attempt in 0..<3 {
      try cancellationCheckpoint()
      descriptor = component.withCString { pointer in
        let result = Darwin.openat(
          context.quarantineRootDescriptor,
          pointer,
          O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_RESOLVE_BENEATH
        )
        if result < 0 { failureCode = errno }
        return result
      }
      if descriptor >= 0 { break }
      if failureCode == EINTR, attempt + 1 < 3 { continue }
      break
    }
    guard descriptor >= 0 else {
      if failureCode == ENOENT {
        throw DescriptorNPMQuarantinePurgePreflightFailure.journalRecordMissing
      }
      throw DescriptorNPMQuarantinePurgePreflightFailure.journalRecordChanged
    }
    defer { descriptorCloseIgnoringErrors(descriptor) }

    let before = try DescriptorStatSnapshot.read(from: descriptor)
    let namedBefore = try DescriptorStatSnapshot.read(
      at: context.quarantineRootDescriptor,
      component: component
    )
    guard
      descriptorPurgePreflightSnapshotsEqual(before, namedBefore),
      before.kind == .regularFile,
      before.identity.device == context.rootSnapshot.identity.device,
      before.ownerUID == context.accountUID,
      before.permissionMode == mode_t(0o600),
      before.flags == 0,
      before.linkCount == 1,
      try !dependencies.hasExtendedACL(descriptor)
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.journalRecordUnsafe
    }

    var information = stat()
    guard Darwin.fstat(descriptor, &information) == 0,
      information.st_size == Int64(expectedBytes.count)
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.journalRecordUnsafe
    }
    var observed = Data(count: expectedBytes.count)
    var offset = 0
    var interruptedAttempts = 0
    let failure: Int32? = observed.withUnsafeMutableBytes { buffer in
      while offset < buffer.count {
        let count = Darwin.pread(
          descriptor,
          buffer.baseAddress!.advanced(by: offset),
          buffer.count - offset,
          off_t(offset)
        )
        if count > 0 {
          offset += count
          interruptedAttempts = 0
          continue
        }
        if count == 0 { return EIO }
        let code = errno
        if code == EINTR, interruptedAttempts + 1 < 3 {
          interruptedAttempts += 1
          continue
        }
        return code
      }
      return nil
    }
    guard failure == nil, observed == expectedBytes else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.journalRecordChanged
    }
    var finalInformation = stat()
    guard Darwin.fstat(descriptor, &finalInformation) == 0,
      finalInformation.st_size == Int64(expectedBytes.count)
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.journalRecordChanged
    }
    let after = try DescriptorStatSnapshot.read(from: descriptor)
    let namedAfter = try DescriptorStatSnapshot.read(
      at: context.quarantineRootDescriptor,
      component: component
    )
    guard
      descriptorPurgePreflightSnapshotsEqual(after, before),
      descriptorPurgePreflightSnapshotsEqual(namedAfter, before),
      try !dependencies.hasExtendedACL(descriptor)
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.journalRecordChanged
    }
  }

  private func openInitialItem(
    _ pair: DescriptorPurgePreflightQuarantinePair,
    in context: DescriptorPurgePreflightContext
  ) throws -> Int32 {
    do {
      return try descriptorOpenTrustedDirectory(
        at: context.quarantineRootDescriptor,
        component: pair.itemComponent
      )
    } catch DescriptorObservationError.posix(ENOENT) {
      throw DescriptorNPMQuarantinePurgePreflightFailure.quarantinedItemMissing
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw DescriptorNPMQuarantinePurgePreflightFailure.quarantinedItemChanged
    }
  }

  private func validateInitialItemBinding(
    descriptor: Int32,
    pair: DescriptorPurgePreflightQuarantinePair,
    context: DescriptorPurgePreflightContext
  ) throws {
    let held = try DescriptorStatSnapshot.read(from: descriptor)
    let named = try DescriptorStatSnapshot.read(
      at: context.quarantineRootDescriptor,
      component: pair.itemComponent
    )
    guard
      descriptorPurgePreflightSnapshotsEqual(held, named),
      descriptorPurgePreflightMatchesHistorical(
        held,
        expected: pair.intent.candidateBinding
      ),
      held.kind == .directory,
      held.identity.device == context.rootSnapshot.identity.device,
      held.ownerUID == context.accountUID,
      held.permissionMode & mode_t(0o022) == 0,
      held.flags == 0,
      held.linkCount >= 2,
      try !dependencies.hasExtendedACL(descriptor)
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.quarantinedItemUnsafe
    }
  }

  private func validateCompleteItem(
    descriptor: Int32,
    pair: DescriptorPurgePreflightQuarantinePair,
    context: DescriptorPurgePreflightContext
  ) throws {
    try validateInitialItemBinding(descriptor: descriptor, pair: pair, context: context)
    let expected = try DescriptorStatSnapshot.read(from: descriptor)
    do {
      try dependencies.validateCompleteTree(
        descriptor,
        context.quarantineRootDescriptor,
        pair.itemComponent,
        expected,
        context.rootSnapshot.identity.device,
        context.accountUID
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw mapTreeFailure(error, retry: false)
    }
  }

  private func validateExactPurgeIntentRecord(
    _ canonicalBytes: Data,
    intent: QuarantinePurgeJournalIntentV1,
    in context: DescriptorPurgePreflightContext
  ) throws {
    guard
      let component = descriptorPurgePreflightRecordComponent(
        prefix: ".purge-intent-v1-",
        transactionID: intent.purgeTransactionID
      )
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.invalidSelection
    }
    try readExactRecord(component, expectedBytes: canonicalBytes, in: context)
  }

  private func openRetryWork(
    _ intent: QuarantinePurgeJournalIntentV1,
    in context: DescriptorPurgePreflightContext
  ) throws -> Int32 {
    guard
      let component = DescriptorPathComponent(intent.purgeWorkComponent),
      component.bytes != Self.activeCacheBytes
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.invalidSelection
    }
    do {
      return try descriptorOpenTrustedDirectory(
        at: context.quarantineRootDescriptor,
        component: component
      )
    } catch DescriptorObservationError.posix(ENOENT) {
      throw DescriptorNPMQuarantinePurgePreflightFailure.purgeWorkMissing
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw DescriptorNPMQuarantinePurgePreflightFailure.purgeWorkChanged
    }
  }

  private func validateRetryWork(
    descriptor: Int32,
    intent: QuarantinePurgeJournalIntentV1,
    expectedCurrentBinding: QuarantineJournalFileBindingV1,
    context: DescriptorPurgePreflightContext,
    validateRemainder: Bool
  ) throws {
    guard let component = DescriptorPathComponent(intent.purgeWorkComponent) else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.invalidSelection
    }
    let held = try DescriptorStatSnapshot.read(from: descriptor)
    let named = try DescriptorStatSnapshot.read(
      at: context.quarantineRootDescriptor,
      component: component
    )
    guard
      descriptorPurgePreflightSnapshotsEqual(held, named),
      QuarantineJournalFileBindingV1(snapshot: held) == expectedCurrentBinding,
      descriptorPurgePreflightMatchesHistorical(
        held,
        expected: intent.candidateBinding
      ),
      held.kind == .directory,
      held.identity.device == context.rootSnapshot.identity.device,
      held.ownerUID == context.accountUID,
      held.permissionMode & mode_t(0o022) == 0,
      held.flags == 0,
      held.linkCount >= 2,
      try !dependencies.hasExtendedACL(descriptor)
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.purgeWorkUnsafe
    }
    if validateRemainder {
      do {
        try dependencies.validateRemainderTree(
          descriptor,
          context.quarantineRootDescriptor,
          component,
          expectedCurrentBinding,
          context.rootSnapshot.identity.device,
          context.accountUID
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw mapTreeFailure(error, retry: true)
      }
    }
  }

  /// An expected object at both Q and W is ambiguous. A different recreated Q
  /// is preserved, but must itself be a stable, safe same-volume object.
  private func validateRetryOriginalItemName(
    _ pair: DescriptorPurgePreflightQuarantinePair,
    context: DescriptorPurgePreflightContext
  ) throws {
    let namedBefore: DescriptorStatSnapshot
    do {
      namedBefore = try DescriptorStatSnapshot.read(
        at: context.quarantineRootDescriptor,
        component: pair.itemComponent
      )
    } catch DescriptorObservationError.posix(ENOENT) {
      return
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw DescriptorNPMQuarantinePurgePreflightFailure.quarantinedItemChanged
    }
    guard
      !descriptorPurgePreflightMatchesHistorical(
        namedBefore,
        expected: pair.intent.candidateBinding
      )
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.purgeWorkChanged
    }

    var descriptor = Int32(-1)
    var failureCode = Int32(EINVAL)
    for attempt in 0..<3 {
      descriptor = pair.itemComponent.withCString { pointer in
        let result = Darwin.openat(
          context.quarantineRootDescriptor,
          pointer,
          O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_RESOLVE_BENEATH
        )
        if result < 0 { failureCode = errno }
        return result
      }
      if descriptor >= 0 { break }
      if failureCode == EINTR, attempt + 1 < 3 { continue }
      break
    }
    guard descriptor >= 0 else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.quarantinedItemUnsafe
    }
    defer { descriptorCloseIgnoringErrors(descriptor) }

    let held = try DescriptorStatSnapshot.read(from: descriptor)
    let namedAfter = try DescriptorStatSnapshot.read(
      at: context.quarantineRootDescriptor,
      component: pair.itemComponent
    )
    let validLinkCount: Bool
    switch held.kind {
    case .directory:
      validLinkCount = held.linkCount >= 2
    case .regularFile:
      validLinkCount = held.linkCount == 1
    case .symbolicLink, .other:
      validLinkCount = false
    }
    guard
      descriptorPurgePreflightSnapshotsEqual(namedBefore, held),
      descriptorPurgePreflightSnapshotsEqual(namedAfter, held),
      held.identity.device == context.rootSnapshot.identity.device,
      held.ownerUID == context.accountUID,
      held.permissionMode & mode_t(0o022) == 0,
      held.flags == 0,
      validLinkCount,
      try !dependencies.hasExtendedACL(descriptor)
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.quarantinedItemUnsafe
    }
  }

  private func purgeNamesAreAbsent(
    _ purgeTransactionID: String,
    in context: DescriptorPurgePreflightContext
  ) throws -> Bool {
    let prefixes = [
      ".intent-stage-v1-",
      ".intent-v1-",
      ".receipt-stage-v1-",
      ".receipt-v1-",
      ".restore-intent-stage-v1-",
      ".restore-intent-v1-",
      ".restore-receipt-stage-v1-",
      ".restore-receipt-v1-",
      ".purge-intent-stage-v1-",
      ".purge-intent-v1-",
      ".purge-receipt-stage-v1-",
      ".purge-receipt-v1-",
      ".purge-work-v1-",
    ]
    for prefix in prefixes {
      guard
        let component = descriptorPurgePreflightRecordComponent(
          prefix: prefix,
          transactionID: purgeTransactionID
        )
      else {
        throw DescriptorNPMQuarantinePurgePreflightFailure.invalidSelection
      }
      do {
        _ = try DescriptorStatSnapshot.read(
          at: context.quarantineRootDescriptor,
          component: component
        )
        return false
      } catch DescriptorObservationError.posix(ENOENT) {
        continue
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw DescriptorNPMQuarantinePurgePreflightFailure.journalRecordChanged
      }
    }
    return true
  }

  private func validateParentsStillMatch(
    _ context: DescriptorPurgePreflightContext
  ) throws {
    let home = try DescriptorStatSnapshot.read(from: context.homeDescriptor)
    guard descriptorTrustedAncestorSnapshotsMatch(home, context.homeSnapshot) else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.homeUnsafe
    }
    let root = try validateRoot(
      descriptor: context.rootDescriptor,
      namedAt: context.homeDescriptor,
      component: context.npmComponent,
      homeSnapshot: home,
      accountUID: context.accountUID
    )
    let quarantine = try validateQuarantineRoot(
      descriptor: context.quarantineRootDescriptor,
      namedAt: context.rootDescriptor,
      component: context.quarantineComponent,
      rootSnapshot: root,
      accountUID: context.accountUID
    )
    guard descriptorPurgePreflightSnapshotsEqual(root, context.rootSnapshot) else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.rootUnsafe
    }
    guard
      descriptorPurgePreflightSnapshotsEqual(
        quarantine,
        context.quarantineRootSnapshot
      )
    else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.quarantineRootUnsafe
    }
    let rootFromSlash = try descriptorSnapshot(
      atAbsoluteComponents: context.homeComponents + [context.npmComponent],
      homeComponentCount: context.homeComponents.count
    )
    let quarantineFromSlash = try descriptorSnapshot(
      atAbsoluteComponents:
        context.homeComponents + [context.npmComponent, context.quarantineComponent],
      homeComponentCount: context.homeComponents.count
    )
    guard descriptorPurgePreflightSnapshotsEqual(rootFromSlash, root) else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.rootUnsafe
    }
    guard descriptorPurgePreflightSnapshotsEqual(quarantineFromSlash, quarantine) else {
      throw DescriptorNPMQuarantinePurgePreflightFailure.quarantineRootUnsafe
    }
  }

  private func mapTreeFailure(
    _ error: Error,
    retry: Bool
  ) -> DescriptorNPMQuarantinePurgePreflightFailure {
    guard let failure = error as? DescriptorNPMPurgeTreeValidationFailure else {
      return retry ? .purgeWorkChanged : .quarantinedItemChanged
    }
    switch failure {
    case .traversalLimitExceeded:
      return .traversalLimitExceeded
    case .rootBindingMismatch, .treeChanged:
      return retry ? .purgeWorkChanged : .quarantinedItemChanged
    case .treeUnsafe, .layoutMismatch, .invalidLimits:
      return retry ? .purgeWorkUnsafe : .quarantinedItemUnsafe
    }
  }

  private func cancellationCheckpoint() throws {
    do {
      try dependencies.checkpoint()
      try Task.checkCancellation()
    } catch {
      throw CancellationError()
    }
  }
}

private struct DescriptorPurgePreflightContext {
  let homeDescriptor: Int32
  let rootDescriptor: Int32
  let quarantineRootDescriptor: Int32
  let homeSnapshot: DescriptorStatSnapshot
  let rootSnapshot: DescriptorStatSnapshot
  let quarantineRootSnapshot: DescriptorStatSnapshot
  let homeComponents: [DescriptorPathComponent]
  let npmComponent: DescriptorPathComponent
  let quarantineComponent: DescriptorPathComponent
  let accountUID: uid_t
  let recoveryRequest: DescriptorQuarantineJournalRecoveryRequest
}

private struct DescriptorPurgePreflightQuarantinePair {
  let intent: QuarantineJournalIntentV1
  let receipt: QuarantineJournalReceiptV1
  let itemComponent: DescriptorPathComponent
  let canonicalIntentBytes: Data
  let canonicalReceiptBytes: Data
}

private func descriptorPurgePreflightValidateCompleteTree(
  descriptor: Int32,
  parentDescriptor: Int32,
  component: DescriptorPathComponent,
  expected: DescriptorStatSnapshot,
  rootDevice: UInt64,
  accountUID: uid_t
) throws {
  _ = try DescriptorNPMCompletePurgeTreeValidator(
    checkpoint: { try Task.checkCancellation() }
  ).validate(
    descriptor: descriptor,
    namedAt: parentDescriptor,
    component: component,
    expected: expected,
    rootDevice: rootDevice,
    accountUID: accountUID
  )
}

private func descriptorPurgePreflightValidateRemainderTree(
  descriptor: Int32,
  parentDescriptor: Int32,
  component: DescriptorPathComponent,
  expectedBinding: QuarantineJournalFileBindingV1,
  rootDevice: UInt64,
  accountUID: uid_t
) throws {
  _ = try DescriptorNPMPurgeRemainderTreeValidator(
    checkpoint: { try Task.checkCancellation() }
  ).validate(
    descriptor: descriptor,
    namedAt: parentDescriptor,
    component: component,
    expectedBinding: expectedBinding,
    rootDevice: rootDevice,
    accountUID: accountUID
  )
}

private func descriptorPurgePreflightRecordComponent(
  prefix: String,
  transactionID: String
) -> DescriptorPathComponent? {
  guard descriptorPurgePreflightIsIdentifier(transactionID) else { return nil }
  return DescriptorPathComponent(Array("\(prefix)\(transactionID)".utf8))
}

private func descriptorPurgePreflightIsIdentifier(_ value: String) -> Bool {
  let bytes = Array(value.utf8)
  return bytes.count == 32
    && bytes.allSatisfy {
      (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
    }
}

private func descriptorPurgePreflightIdentifier(_ nonce: [UInt8]) -> String? {
  guard nonce.count == 16 else { return nil }
  let digits = Array("0123456789abcdef".utf8)
  var result = [UInt8]()
  result.reserveCapacity(32)
  for byte in nonce {
    result.append(digits[Int(byte >> 4)])
    result.append(digits[Int(byte & 0x0F)])
  }
  return String(bytes: result, encoding: .utf8)
}

private func descriptorPurgePreflightRandomNonce(_ attempt: Int) -> [UInt8]? {
  _ = attempt
  var bytes = [UInt8](repeating: 0, count: 16)
  bytes.withUnsafeMutableBytes { buffer in
    if let baseAddress = buffer.baseAddress {
      Darwin.arc4random_buf(baseAddress, buffer.count)
    }
  }
  return bytes
}

private func descriptorPurgePreflightSnapshotsEqual(
  _ left: DescriptorStatSnapshot,
  _ right: DescriptorStatSnapshot
) -> Bool {
  left.sameBinding(as: right)
    && left.sameMutationState(as: right)
    && left.ownerUID == right.ownerUID
    && left.permissionMode == right.permissionMode
    && left.flags == right.flags
    && left.linkCount == right.linkCount
}

private func descriptorPurgePreflightMatchesHistorical(
  _ snapshot: DescriptorStatSnapshot,
  expected: QuarantineJournalFileBindingV1
) -> Bool {
  guard
    let birthSeconds = Int64(exactly: snapshot.birthSeconds),
    let birthNanoseconds = UInt32(exactly: snapshot.birthNanoseconds),
    let ownerUID = UInt32(exactly: snapshot.ownerUID)
  else {
    return false
  }
  return snapshot.identity.device == expected.device
    && snapshot.identity.inode == expected.inode
    && snapshot.generation == expected.generation
    && birthSeconds == expected.birthSeconds
    && birthNanoseconds == expected.birthNanoseconds
    && snapshot.kind == expected.kind
    && ownerUID == expected.ownerUID
}

private func descriptorPurgePreflightWorkBinding(
  _ current: QuarantineJournalFileBindingV1,
  matches historical: QuarantineJournalFileBindingV1
) -> Bool {
  current.device == historical.device
    && current.inode == historical.inode
    && current.generation == historical.generation
    && current.birthSeconds == historical.birthSeconds
    && current.birthNanoseconds == historical.birthNanoseconds
    && current.kind == .directory
    && current.kind == historical.kind
    && current.ownerUID != 0
    && current.ownerUID == historical.ownerUID
    && current.permissionMode <= 0o7777
    && current.permissionMode & 0o022 == 0
    && current.flags == 0
    && current.linkCount >= 2
}
