import DevSiftCore
import Testing

@testable import DevSiftApp

@Suite("Quarantine permanent deletion presentation")
struct QuarantineRecoveryPurgePresentationTests {
  @Test("Initial and retry inventory rows remain distinct and opaque")
  func inventoryRowsAreDistinctAndOpaque() {
    let inventory = purgePresentationInventory()
    let presentation = QuarantineRecoveryInventoryPresentation.prepare(
      inventory: inventory,
      generation: 9
    )

    #expect(presentation.rows.count == 1)
    #expect(presentation.rows[0].canPurge)
    #expect(presentation.purgeRetryRows.count == 1)
    #expect(presentation.purgeRetryRows[0].canRetry)
    #expect(
      presentation.purgeRetryRows[0].retryAvailabilityMessage.contains(
        "separately confirmed retry"
      ))
    #expect(
      presentation.rows[0].id.customMirror.children.first?.label
        == "opaqueRow"
    )
    #expect(
      presentation.purgeRetryRows[0].id.customMirror.children.first?.label
        == "opaqueRetryRow"
    )
    #expect(
      inventory.purgeRetries[0].handle.customMirror.children.first?.label
        == "opaque"
    )
  }

  @Test("Attempt-specific confirmations expose only bounded display values")
  func confirmationStatementsRemainSeparate() {
    let initial = QuarantineRecoveryPurgeConfirmationPresentation(
      target: .initial(QuarantineRecoveryRowID(inventoryGeneration: 1, ordinal: 0)),
      confirmationID: QuarantineRecoveryPurgeConfirmationID(
        identity: QuarantineRecoveryPurgeConfirmationIdentity()
      ),
      preparedPurge: purgePresentationPreparedPurge(kind: .initial)
    )
    let retry = QuarantineRecoveryPurgeConfirmationPresentation(
      target: .explicitRetry(
        QuarantineRecoveryPurgeRetryRowID(inventoryGeneration: 1, ordinal: 0)
      ),
      confirmationID: QuarantineRecoveryPurgeConfirmationID(
        identity: QuarantineRecoveryPurgeConfirmationIdentity()
      ),
      preparedPurge: purgePresentationPreparedPurge(kind: .explicitRetry)
    )

    #expect(initial.requiredStatementIdentifier != retry.requiredStatementIdentifier)
    #expect(!initial.isExplicitRetry)
    #expect(retry.isExplicitRetry)
    #expect(initial.responsibleTool == "npm")
    #expect(initial.originalName == "_cacache")
    #expect(initial.dataRemanenceDisclosure.contains("not secure erase"))
    #expect(initial.dataRemanenceDisclosure.contains("APFS snapshots or clones"))
    #expect(initial.dataRemanenceDisclosure.contains("backups"))
    #expect(initial.dataRemanenceDisclosure.contains("open file descriptors"))
    #expect(initial.dataRemanenceDisclosure.contains("storage-device behavior"))
    #expect(
      initial.id.customMirror.children.first?.label
        == "opaquePurgeConfirmation"
    )
  }

  @Test("Capacity presentation is observational and never claims reclaimed bytes")
  func capacityPresentationIsBounded() {
    let presentation = QuarantineRecoveryPurgeResultPresentation(
      result: QuarantineRecoveryWorkflowPurgeExecutionResult(
        attemptKind: .initial,
        status: .itemAbsent,
        durability: .terminalReceiptRecorded(
          outcome: .itemAbsent,
          producedByRecovery: false
        ),
        capacityObservationProvenance: .initialAttempt,
        observedCapacityChange: .increase(amount: 8_192),
        observedUnlinkCount: 3,
        isDurablyTerminal: true,
        isCrashRecoverable: true,
        performedPermanentDeletion: true,
        requiresExplicitRetry: false
      ))

    #expect(presentation.tone == .success)
    #expect(presentation.capacityMessage.contains("Observed same-volume"))
    #expect(presentation.capacityMessage.contains("not attributed"))
    #expect(!presentation.capacityMessage.localizedCaseInsensitiveContains("reclaimed"))
    #expect(presentation.limitationsMessage.contains("secure erasure"))
    #expect(presentation.limitationsMessage.contains("reclaimed storage"))
    #expect(presentation.observedUnlinkMessage.contains("3"))
  }

  @Test("Partial cancellation requires a separate retry without hiding progress")
  func retryPresentationIsExplicit() {
    let presentation = QuarantineRecoveryPurgeResultPresentation(
      result: QuarantineRecoveryWorkflowPurgeExecutionResult(
        attemptKind: .initial,
        status: .explicitRetryRequired(
          progress: .unlinkProgressObserved,
          reason: .cancelled
        ),
        durability: .intentRecorded,
        observedCapacityChange: .unavailable,
        observedUnlinkCount: 1,
        cancellationWasObserved: true,
        isDurablyTerminal: false,
        isCrashRecoverable: true,
        performedPermanentDeletion: true,
        requiresExplicitRetry: true
      ))

    #expect(presentation.tone == .warning)
    #expect(presentation.requiresExplicitRetry)
    #expect(presentation.message.contains("bounded unlink progress"))
    #expect(presentation.message.contains("pass stopped"))
    #expect(presentation.message.contains("separate explicit confirmation"))
    #expect(presentation.message.contains("Restore is unavailable"))
    #expect(presentation.cancellationMessage != nil)
    #expect(presentation.capacityMessage.contains("unavailable"))
  }

  @Test("Purge issues contain no path, transaction ID, or raw bytes")
  func issuesArePrivacyBounded() {
    let secretID = String(repeating: "d", count: 32)
    let issues = [
      QuarantineRecoveryIssuePresentation(
        purgePreparationFailure: .journalRecordChanged
      ),
      QuarantineRecoveryIssuePresentation(
        purgePreparationFailure: .capacityObservation(.expectedVolumeMismatch)
      ),
      QuarantineRecoveryIssuePresentation(
        purgeWorkflowFailure: .authorization(.confirmationStatementMismatch)
      ),
      QuarantineRecoveryIssuePresentation(
        purgeWorkflowFailure: .execution(.authorizationAlreadyConsumed)
      ),
    ]

    for issue in issues {
      #expect(!issue.title.isEmpty)
      #expect(!issue.message.isEmpty)
      #expect(!issue.title.contains(secretID))
      #expect(!issue.message.contains(secretID))
      #expect(!issue.title.contains("/Users/"))
      #expect(!issue.message.contains("/Users/"))
      #expect(!issue.message.contains("Data("))
    }
  }
}

private func purgePresentationInventory() -> QuarantineRecoveryWorkflowInventory {
  let itemIdentity = QuarantineRecoveryInventoryIdentity()
  let retryIdentity = QuarantineRecoveryPurgeRetryInventoryIdentity()
  let readiness = QuarantineInventoryRestoreReadiness(
    originalSource: .missing,
    quarantinedItem: .available
  )
  return QuarantineRecoveryWorkflowInventory(
    items: [
      QuarantineRecoveryWorkflowInventoryItem(
        handle: QuarantineRecoveryWorkflowItemHandle(identity: itemIdentity, ordinal: 0),
        responsibleTool: "npm",
        originalName: "_cacache",
        readiness: readiness,
        purgeReadiness: QuarantineInventoryPurgeReadiness(quarantinedItem: .available),
        quarantineReceiptWasProducedByRecovery: false
      )
    ],
    purgeRetries: [
      QuarantineRecoveryWorkflowPurgeRetryItem(
        handle: QuarantineRecoveryWorkflowPurgeRetryHandle(
          identity: retryIdentity,
          ordinal: 0
        ),
        responsibleTool: "npm",
        originalName: "_cacache"
      )
    ]
  )
}

private func purgePresentationPreparedPurge(
  kind: QuarantinePurgeAttemptKind
) -> QuarantineRecoveryPreparedPurge {
  QuarantineRecoveryPreparedPurge(
    handle: QuarantineRecoveryPreparedPurgeHandle(
      identity: QuarantineRecoveryPurgeAttemptIdentity()
    ),
    attemptKind: kind,
    requiredStatement:
      kind == .initial
      ? .initialPermanentDeletionRisksAccepted
      : .explicitRetryPermanentDeletionRisksAccepted,
    responsibleTool: "npm",
    originalName: "_cacache"
  )
}
