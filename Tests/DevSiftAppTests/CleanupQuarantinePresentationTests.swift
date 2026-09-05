import DevSiftCore
import Testing

@testable import DevSiftApp

@Suite("Cleanup quarantine result presentation")
struct CleanupQuarantinePresentationTests {
  @Test("Only a terminal receipt is presented as a durable quarantine")
  func durableSuccess() {
    let presentation = CleanupQuarantineResultPresentation(
      result: result(
        outcome: .durablyQuarantined(sourceNameWasRecreated: false),
        durability: .terminalReceiptRecorded(
          transactionID: "00112233445566778899aabbccddeeff",
          producedByRecovery: false
        )
      )
    )

    #expect(presentation.tone == .success)
    #expect(presentation.title == "Moved to quarantine")
    #expect(presentation.durabilityMessage == "A terminal receipt was durably recorded.")
    #expect(!presentation.performedPermanentDeletion)
    #expect(presentation.guaranteedFreedBytes == 0)
    #expect(!presentation.message.contains("00112233445566778899aabbccddeeff"))
  }

  @Test("A moved item without a terminal receipt remains a recovery warning")
  func receiptlessMove() {
    let presentation = CleanupQuarantineResultPresentation(
      result: result(
        outcome: .quarantinedWithoutTerminalReceipt(sourceNameWasRecreated: true),
        durability: .intentRecorded(transactionID: "11223344556677889900aabbccddeeff"),
        mutation: .quarantineRootCreated,
        cancellationAfterRename: true
      )
    )

    #expect(presentation.tone == .warning)
    #expect(presentation.title == "Move needs recovery")
    #expect(presentation.message.contains("may have moved"))
    #expect(presentation.durabilityMessage.contains("receipt is still pending"))
    #expect(presentation.namespaceMessage?.contains("created") == true)
    #expect(presentation.cancellationMessage?.contains("finished reconciliation") == true)
    #expect(!presentation.message.contains("11223344556677889900aabbccddeeff"))
  }

  @Test("Bounded failures produce actionable text without claiming no mutation")
  func boundedFailures() {
    let cases: [(CleanupQuarantineFrontendOutcome, String)] = [
      (.notStarted(.authorizationAlreadyConsumed), "already used"),
      (.notMoved(.candidateChanged), "changed"),
      (.notMoved(.exclusiveRenameUnsupported), "protected rename"),
      (.notMoved(.quarantineJournalBusy), "journal lock"),
      (.notMoved(.renameRejected(.permissionDenied)), "denied access"),
      (.rolledBack(.postMoveValidationUnavailable), "moved the item back"),
      (
        .manualRecoveryRequired(
          locationWasObserved: false,
          reason: .renameOutcomeIndeterminate
        ),
        "indeterminate"
      ),
    ]

    for (outcome, expectedText) in cases {
      let presentation = CleanupQuarantineResultPresentation(
        result: result(outcome: outcome, durability: .unresolved(transactionID: nil))
      )
      #expect(presentation.tone != .success)
      #expect(presentation.message.localizedCaseInsensitiveContains(expectedText))
      #expect(!presentation.performedPermanentDeletion)
      #expect(presentation.guaranteedFreedBytes == 0)
    }
  }

  @Test("Workflow failures expose only their bounded stage and disposition")
  func boundedWorkflowFailures() {
    let cases: [(CleanupQuarantineWorkflowStageFailure, String)] = [
      (.cancelled(.reviewConfirmation), "cancelled during review confirmation"),
      (.rejected(.approval), "rejected during approval"),
      (.failed(.authorizationAttempt), "complete authorization preparation"),
      (.failed(.authorizationIssuance), "complete one-time authorization"),
    ]

    for (failure, expectedText) in cases {
      let presentation = CleanupQuarantineFailurePresentation(failure: failure)
      #expect(presentation.title == "Quarantine did not start")
      #expect(presentation.message.localizedCaseInsensitiveContains(expectedText))
      #expect(!presentation.message.contains("/private/"))
      #expect(!presentation.message.contains("NSPOSIXErrorDomain"))
    }
  }

  private func result(
    outcome: CleanupQuarantineFrontendOutcome,
    durability: CleanupQuarantineFrontendDurabilityEvidence,
    mutation: CleanupQuarantineFrontendNamespaceMutation = .none,
    cancellationAfterRename: Bool = false
  ) -> CleanupQuarantineFrontendExecutionResult {
    CleanupQuarantineFrontendExecutionResult(
      outcome: outcome,
      durabilityEvidence: durability,
      namespaceMutation: mutation,
      cancellationWasObservedAfterRename: cancellationAfterRename
    )
  }
}
