import DevSiftCore
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@Suite("Quarantine recovery presentation")
struct QuarantineRecoveryPresentationTests {
  @Test("Row IDs are deterministic only within one loaded presentation generation")
  func deterministicRowLocalIDs() {
    let inventory = workflowInventory(
      readiness: QuarantineInventoryRestoreReadiness(
        originalSource: .missing,
        quarantinedItem: .available
      )
    )

    let first = QuarantineRecoveryInventoryPresentation.prepare(
      inventory: inventory,
      generation: 7
    )
    let repeated = QuarantineRecoveryInventoryPresentation.prepare(
      inventory: inventory,
      generation: 7
    )
    let refreshed = QuarantineRecoveryInventoryPresentation.prepare(
      inventory: inventory,
      generation: 8
    )

    #expect(first.rows.map(\.id) == repeated.rows.map(\.id))
    #expect(first.rows.map(\.id) != refreshed.rows.map(\.id))
    #expect(first.rows[0].id.customMirror.children.first?.label == "opaqueRow")
  }

  @Test("Only a clear source and available quarantined item can restore")
  func readinessPresentation() {
    let cases:
      [(
        QuarantineInventoryRestoreReadiness,
        Bool,
        QuarantineRecoveryPresentationTone,
        QuarantineRecoveryPresentationTone
      )] = [
        (
          QuarantineInventoryRestoreReadiness(
            originalSource: .missing,
            quarantinedItem: .available
          ),
          true,
          .success,
          .success
        ),
        (
          QuarantineInventoryRestoreReadiness(
            originalSource: .expectedObjectPresent,
            quarantinedItem: .available
          ),
          false,
          .warning,
          .success
        ),
        (
          QuarantineInventoryRestoreReadiness(
            originalSource: .otherObjectPresent,
            quarantinedItem: .unsafe
          ),
          false,
          .failure,
          .failure
        ),
        (
          QuarantineInventoryRestoreReadiness(
            originalSource: .missing,
            quarantinedItem: .traversalLimitExceeded
          ),
          false,
          .success,
          .warning
        ),
      ]

    for (readiness, canRestore, sourceTone, itemTone) in cases {
      let presentation = QuarantineRecoveryInventoryPresentation.prepare(
        inventory: workflowInventory(readiness: readiness),
        generation: 1
      )
      let row = presentation.rows[0]
      #expect(row.canRestore == canRestore)
      #expect(row.source.tone == sourceTone)
      #expect(row.quarantinedItem.tone == itemTone)
    }
  }

  @Test("A durable no-overwrite outcome is the only success presentation")
  func durableRestorePresentation() {
    let presentation = QuarantineRecoveryResultPresentation(
      result: QuarantineRecoveryWorkflowExecutionResult(
        status: .restored(quarantineNameWasRecreated: false),
        durability: .receiptRecorded(producedByRecovery: false),
        cancellationWasObservedAfterRename: false,
        isDurablyRestored: true
      )
    )

    #expect(presentation.tone == .success)
    #expect(presentation.title == "Cache restored")
    #expect(presentation.message.contains("without overwrite"))
    #expect(!presentation.performedPermanentDeletion)
    #expect(!presentation.overwroteExistingItem)
  }

  @Test("A recreated quarantine item name is not described as a recreated namespace")
  func quarantineItemNameWasRecreated() {
    let presentation = QuarantineRecoveryResultPresentation(
      result: QuarantineRecoveryWorkflowExecutionResult(
        status: .restored(quarantineNameWasRecreated: true),
        durability: .receiptRecorded(producedByRecovery: true),
        cancellationWasObservedAfterRename: false,
        isDurablyRestored: true
      )
    )

    #expect(presentation.message.contains("another object"))
    #expect(presentation.message.contains("former quarantine item name"))
    #expect(!presentation.message.contains("namespace was recreated"))
  }

  @Test("Every bounded failure remains actionable and contains no raw identifier")
  func boundedFailures() {
    let identifier = String(repeating: "a", count: 32)
    let issues = [
      QuarantineRecoveryIssuePresentation(loadFailure: .manualRecoveryRequired),
      QuarantineRecoveryIssuePresentation(preparationFailure: .inventoryChanged),
      QuarantineRecoveryIssuePresentation(
        workflowFailure: .authorization(.confirmationStatementMismatch)
      ),
      QuarantineRecoveryIssuePresentation(
        workflowFailure: .execution(.authorizationAlreadyConsumed)
      ),
    ]

    for issue in issues {
      #expect(!issue.title.isEmpty)
      #expect(!issue.message.isEmpty)
      #expect(!issue.title.contains(identifier))
      #expect(!issue.message.contains(identifier))
      #expect(!issue.message.contains("/Users/"))
    }

    let cancelledLoad = QuarantineRecoveryIssuePresentation(loadFailure: .cancelled)
    #expect(cancelledLoad.message.contains("before a current inventory was published"))
    #expect(!cancelledLoad.message.localizedCaseInsensitiveContains("nothing changed"))
  }
}

private func workflowInventory(
  readiness: QuarantineInventoryRestoreReadiness
) -> QuarantineRecoveryWorkflowInventory {
  let identity = QuarantineRecoveryInventoryIdentity()
  return QuarantineRecoveryWorkflowInventory(
    items: [
      QuarantineRecoveryWorkflowInventoryItem(
        handle: QuarantineRecoveryWorkflowItemHandle(identity: identity, ordinal: 0),
        responsibleTool: "npm",
        originalName: "_cacache",
        readiness: readiness,
        quarantineReceiptWasProducedByRecovery: false
      )
    ]
  )
}
