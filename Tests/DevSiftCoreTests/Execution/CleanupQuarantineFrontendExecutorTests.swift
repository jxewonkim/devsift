import Testing

@testable import DevSiftCore

@Suite("Cleanup quarantine frontend executor")
struct CleanupQuarantineFrontendExecutorTests {
  @Test("Every status and durability combination has a bounded frontend outcome")
  func statusAndDurabilityCombinations() throws {
    let location = testLocation()
    let statuses: [(CleanupQuarantineExecutionStatus, FrontendOutcomeKind)] = [
      (.notMoved(.candidateChanged), .notMoved),
      (
        .quarantined(location: location, sourceNameWasRecreated: true),
        .quarantinedWithoutTerminalReceipt
      ),
      (.rolledBack(.postMoveValidationUnavailable), .rolledBack),
      (
        .manualRecoveryRequired(location: location, reason: .parentBindingChanged),
        .manualRecoveryRequired
      ),
    ]
    let durabilities: [FrontendDurabilityCase] = [
      (.notRecorded, .notRecorded),
      (
        .intentRecorded(transactionID: "00112233445566778899aabbccddeeff"),
        .intentRecorded(transactionID: "00112233445566778899aabbccddeeff")
      ),
      (
        .receiptRecorded(
          transactionID: "11223344556677889900aabbccddeeff",
          producedByRecovery: true
        ),
        .terminalReceiptRecorded(
          transactionID: "11223344556677889900aabbccddeeff",
          producedByRecovery: true
        )
      ),
      (
        .unresolved(transactionID: "22334455667788990011aabbccddeeff"),
        .unresolved(transactionID: "22334455667788990011aabbccddeeff")
      ),
    ]

    for (status, ordinaryExpectedKind) in statuses {
      for (durability, expectedDurability) in durabilities {
        let result = CleanupQuarantineFrontendExecutor.project(
          makeReport(
            status: status,
            durabilityState: durability,
            quarantineRootMutation: .created,
            cancellationWasObservedAfterRename: true
          )
        )
        let expectedKind: FrontendOutcomeKind
        if case .quarantined = status,
          case .receiptRecorded = durability
        {
          expectedKind = .durablyQuarantined
        } else {
          expectedKind = ordinaryExpectedKind
        }

        #expect(kind(of: result.outcome) == expectedKind)
        #expect(result.durabilityEvidence == expectedDurability)
        #expect(result.namespaceMutation == .quarantineRootCreated)
        #expect(result.cancellationWasObservedAfterRename)
        #expect(result.isDurablyQuarantined == (expectedKind == .durablyQuarantined))
        #expect(!result.performedPermanentDeletion)
        #expect(result.guaranteedFreedBytes == 0)
        #expect(result.contractVersion == 1)
      }
    }
  }

  @Test("Receipt-less quarantines retain their bounded move evidence")
  func receiptlessQuarantineEvidence() throws {
    let noRecord = CleanupQuarantineFrontendExecutor.project(
      makeReport(
        status: .quarantined(location: testLocation(), sourceNameWasRecreated: false),
        durabilityState: .notRecorded
      )
    )
    let intent = CleanupQuarantineFrontendExecutor.project(
      makeReport(
        status: .quarantined(location: testLocation(), sourceNameWasRecreated: true),
        durabilityState: .intentRecorded(transactionID: "00112233445566778899aabbccddeeff")
      )
    )
    let unresolved = CleanupQuarantineFrontendExecutor.project(
      makeReport(
        status: .quarantined(location: testLocation(), sourceNameWasRecreated: false),
        durabilityState: .unresolved(transactionID: nil)
      )
    )

    #expect(noRecord.outcome == .quarantinedWithoutTerminalReceipt(sourceNameWasRecreated: false))
    #expect(intent.outcome == .quarantinedWithoutTerminalReceipt(sourceNameWasRecreated: true))
    #expect(
      unresolved.outcome
        == .quarantinedWithoutTerminalReceipt(sourceNameWasRecreated: false)
    )
    #expect(!noRecord.isDurablyQuarantined)
    #expect(!intent.isDurablyQuarantined)
    #expect(!unresolved.isDurablyQuarantined)
  }

  @Test("Every not-moved reason is projected without an internal error")
  func notMovedReasons() throws {
    let cases: [FrontendNotMovedCase] = [
      (.cancelled, .cancelled),
      (.invalidClaim, .invalidClaim),
      (.unsupportedPolicy, .unsupportedPolicy),
      (.invalidCurrentAccount, .invalidCurrentAccount),
      (
        .trustedRootUnavailable(.permissionDenied),
        .trustedRootUnavailable(.permissionDenied)
      ),
      (.trustedRootChanged, .trustedRootChanged),
      (.candidateMissing, .candidateMissing),
      (.candidateChanged, .candidateChanged),
      (.candidateUnsafe, .candidateUnsafe),
      (.traversalLimitExceeded, .traversalLimitExceeded),
      (.ageRequirementNotSatisfied, .ageRequirementNotSatisfied),
      (
        .quarantineRootUnavailable(.readOnlyFileSystem),
        .quarantineRootUnavailable(.readOnlyFileSystem)
      ),
      (.quarantineRootUnsafe, .quarantineRootUnsafe),
      (.exclusiveRenameUnsupported, .exclusiveRenameUnsupported),
      (.invalidDestinationName, .invalidDestinationName),
      (.destinationCollisionLimitExceeded, .destinationCollisionLimitExceeded),
      (.quarantineJournalBusy, .quarantineJournalBusy),
      (
        .quarantineJournalUnavailable(.resourceLimit),
        .quarantineJournalUnavailable(.resourceLimit)
      ),
      (
        .preRenameValidationUnavailable(.pathChanged),
        .preRenameValidationUnavailable(.pathChanged)
      ),
      (.renameRejected(.crossDevice), .renameRejected(.crossDevice)),
    ]

    for (reason, expected) in cases {
      let result = CleanupQuarantineFrontendExecutor.project(
        makeReport(status: .notMoved(reason), durabilityState: .notRecorded)
      )
      #expect(result.outcome == .notMoved(expected))
    }
  }

  @Test("Every system failure category remains bounded")
  func systemFailureReasons() throws {
    let cases: [(CleanupQuarantineSystemFailure, CleanupQuarantineFrontendSystemFailure)] = [
      (.permissionDenied, .permissionDenied),
      (.pathChanged, .pathChanged),
      (.unsupported, .unsupported),
      (.crossDevice, .crossDevice),
      (.readOnlyFileSystem, .readOnlyFileSystem),
      (.noSpace, .noSpace),
      (.resourceLimit, .resourceLimit),
      (.invalidMetadata, .invalidMetadata),
      (.inputOutput, .inputOutput),
      (.destinationExists, .destinationExists),
      (.unspecified, .unspecified),
    ]

    for (failure, expected) in cases {
      let result = CleanupQuarantineFrontendExecutor.project(
        makeReport(
          status: .notMoved(.renameRejected(failure)),
          durabilityState: .notRecorded
        )
      )
      #expect(result.outcome == .notMoved(.renameRejected(expected)))
    }
  }

  @Test("Every rollback and manual-recovery reason remains bounded")
  func rollbackAndManualRecoveryReasons() throws {
    let rollbackCases: [FrontendRollbackCase] = [
      (.movedObjectDidNotMatchApproval, .movedObjectDidNotMatchApproval),
      (.postMoveValidationUnavailable, .postMoveValidationUnavailable),
    ]
    for (reason, expected) in rollbackCases {
      let result = CleanupQuarantineFrontendExecutor.project(
        makeReport(status: .rolledBack(reason), durabilityState: .notRecorded)
      )
      #expect(result.outcome == .rolledBack(expected))
    }

    let recoveryCases: [FrontendManualRecoveryCase] = [
      (.quarantineJournalUnsafe, .quarantineJournalUnsafe),
      (.durabilityRecordingFailed, .durabilityRecordingFailed),
      (.renameOutcomeIndeterminate, .renameOutcomeIndeterminate),
      (.destinationCouldNotBeVerified, .destinationCouldNotBeVerified),
      (.parentBindingChanged, .parentBindingChanged),
      (.sourceNameOccupied, .sourceNameOccupied),
      (.sourceCouldNotBeVerified, .sourceCouldNotBeVerified),
      (.restoredObjectDidNotMatchApproval, .restoredObjectDidNotMatchApproval),
      (.rollbackFailed, .rollbackFailed),
      (.rollbackOutcomeIndeterminate, .rollbackOutcomeIndeterminate),
    ]
    for (reason, expected) in recoveryCases {
      let withLocation = CleanupQuarantineFrontendExecutor.project(
        makeReport(
          status: .manualRecoveryRequired(location: testLocation(), reason: reason),
          durabilityState: .unresolved(transactionID: nil)
        )
      )
      let withoutLocation = CleanupQuarantineFrontendExecutor.project(
        makeReport(
          status: .manualRecoveryRequired(location: nil, reason: reason),
          durabilityState: .unresolved(transactionID: nil)
        )
      )
      #expect(
        withLocation.outcome
          == .manualRecoveryRequired(locationWasObserved: true, reason: expected)
      )
      #expect(
        withoutLocation.outcome
          == .manualRecoveryRequired(locationWasObserved: false, reason: expected)
      )
    }
  }

  @Test("Every namespace mutation and authorization-consumption failure is bounded")
  func boundaryMappings() throws {
    for (mutation, expected) in [
      (CleanupQuarantineRootMutation.none, CleanupQuarantineFrontendNamespaceMutation.none),
      (.created, .quarantineRootCreated),
      (.indeterminate, .indeterminate),
    ] {
      let result = CleanupQuarantineFrontendExecutor.project(
        makeReport(
          status: .notMoved(.cancelled),
          durabilityState: .notRecorded,
          quarantineRootMutation: mutation
        )
      )
      #expect(result.namespaceMutation == expected)
    }

    #expect(
      CleanupQuarantineFrontendExecutor.project(.unsupportedContractVersion)
        == .invalidAuthorization
    )
    #expect(
      CleanupQuarantineFrontendExecutor.project(.authorizationDoesNotBelongToAttempt)
        == .invalidAuthorization
    )
    #expect(
      CleanupQuarantineFrontendExecutor.project(.authorizationAlreadyConsumed)
        == .authorizationAlreadyConsumed
    )
    #expect(
      CleanupQuarantineFrontendExecutor.project(.authorizationCancelled)
        == .authorizationCancelled
    )
  }

  @Test("The facade consumes one authorization and bounds a repeated call")
  func facadeExecutionIsSingleUse() async throws {
    let fixture = try NPMQuarantinePreflightFixture()
    defer { fixture.remove() }
    let authorization = try await fixture.makeAuthorization()
    let executor = CleanupQuarantineFrontendExecutor(
      executor: CleanupQuarantineExecutor(
        preflight: fixture.preflight(),
        mover: supportedExecutionTestMover(
          nonceBytes: { seededDeterministicNonce(0x31, attempt: $0) }
        )
      )
    )

    let first = await executor.execute(authorization)
    let second = await executor.execute(authorization)

    #expect(first.isDurablyQuarantined)
    #expect(first.outcome == .durablyQuarantined(sourceNameWasRecreated: false))
    #expect(!first.performedPermanentDeletion)
    #expect(first.guaranteedFreedBytes == 0)
    #expect(second.outcome == .notStarted(.authorizationAlreadyConsumed))
    #expect(second.durabilityEvidence == .notRecorded)
    #expect(second.namespaceMutation == .none)
  }

  private func makeReport(
    status: CleanupQuarantineExecutionStatus,
    durabilityState: CleanupQuarantineDurabilityState,
    quarantineRootMutation: CleanupQuarantineRootMutation = .none,
    cancellationWasObservedAfterRename: Bool = false
  ) -> CleanupQuarantineExecutionReport {
    CleanupQuarantineExecutionReport(
      path: ScanRelativePath(rawComponents: [Array("_cacache".utf8)]),
      ruleRevision: RuleRevision(
        identifier: RuleIdentifier(rawValue: "devsift.cache.npm")!,
        version: RuleVersion(rawValue: 5)!
      ),
      status: status,
      durabilityState: durabilityState,
      quarantineRootMutation: quarantineRootMutation,
      cancellationWasObservedAfterRename: cancellationWasObservedAfterRename
    )
  }

  private func testLocation() -> CleanupQuarantineLocation {
    CleanupQuarantineLocation(
      relativePath: ScanRelativePath(
        rawComponents: [
          Array(".devsift-quarantine-v1".utf8),
          Array("item-v1-00112233445566778899aabbccddeeff".utf8),
        ]
      ),
      observedIdentity: FileIdentity(device: 7, inode: 11)
    )
  }

  private func kind(
    of outcome: CleanupQuarantineFrontendOutcome
  ) -> FrontendOutcomeKind {
    switch outcome {
    case .notStarted:
      .notStarted
    case .durablyQuarantined:
      .durablyQuarantined
    case .quarantinedWithoutTerminalReceipt:
      .quarantinedWithoutTerminalReceipt
    case .notMoved:
      .notMoved
    case .rolledBack:
      .rolledBack
    case .manualRecoveryRequired:
      .manualRecoveryRequired
    }
  }
}

private enum FrontendOutcomeKind: Equatable {
  case notStarted
  case durablyQuarantined
  case quarantinedWithoutTerminalReceipt
  case notMoved
  case rolledBack
  case manualRecoveryRequired
}

private typealias FrontendDurabilityCase = (
  CleanupQuarantineDurabilityState,
  CleanupQuarantineFrontendDurabilityEvidence
)

private typealias FrontendNotMovedCase = (
  CleanupQuarantineNotMovedReason,
  CleanupQuarantineFrontendNotMovedReason
)

private typealias FrontendRollbackCase = (
  CleanupQuarantineRollbackReason,
  CleanupQuarantineFrontendRollbackReason
)

private typealias FrontendManualRecoveryCase = (
  CleanupQuarantineManualRecoveryReason,
  CleanupQuarantineFrontendManualRecoveryReason
)
