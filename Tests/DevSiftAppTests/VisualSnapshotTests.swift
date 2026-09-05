import AppKit
import Foundation
import SwiftUI
import Testing

@testable import DevSiftApp
@testable import DevSiftCore

@MainActor
@Suite("Opt-in native visual snapshots")
struct VisualSnapshotTests {
  @Test("Render representative dashboard states when a snapshot directory is configured")
  func renderDashboardStates() async throws {
    guard let outputPath = ProcessInfo.processInfo.environment["DEVSIFT_SNAPSHOT_DIR"] else {
      return
    }

    let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )

    let emptyModel = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(AppTestReportFactory.report())),
      securityScope: SecurityScopeSpy()
    )
    try render(
      ScanDashboardView(viewModel: emptyModel),
      appearance: .aqua,
      to: outputDirectory.appendingPathComponent("empty-light.png")
    )

    let scanRoot = URL(
      fileURLWithPath: "/private/tmp/DevSiftVisualFixture/synthetic-cache",
      isDirectory: true
    )
    let gatedScanner = GatedScanner()
    let scanningModel = ScanViewModel(
      scanner: gatedScanner,
      securityScope: SecurityScopeSpy()
    )
    let scanningTask = scanningModel.startScan(at: scanRoot)
    try #require(await gatedScanner.waitUntilStarted(scanRoot))
    try render(
      ScanDashboardView(viewModel: scanningModel),
      appearance: .aqua,
      to: outputDirectory.appendingPathComponent("scanning-light.png")
    )
    scanningModel.cancelScan()
    try await gatedScanner.resolve(scanRoot, with: .report(AppTestReportFactory.report()))
    await scanningTask.value

    let gatedClassifier = GatedRuleClassifier()
    let classifyingModel = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(representativeReport())),
      classifier: gatedClassifier,
      securityScope: SecurityScopeSpy()
    )
    let classifyingTask = classifyingModel.startScan(at: scanRoot)
    try #require(await gatedClassifier.waitUntilStarted(scanRoot))
    try render(
      ScanDashboardView(viewModel: classifyingModel),
      appearance: .aqua,
      to: outputDirectory.appendingPathComponent("classifying-light.png")
    )
    try await gatedClassifier.resolve(scanRoot, with: .classify)
    await classifyingTask.value

    let resultModel = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(representativeReport())),
      securityScope: SecurityScopeSpy()
    )
    await resultModel.startScan(at: scanRoot).value
    try render(
      ScanDashboardView(
        viewModel: resultModel,
        policyDetailsInitiallyExpanded: true
      ),
      appearance: .aqua,
      size: CGSize(width: 900, height: 620),
      to: outputDirectory.appendingPathComponent("policy-expanded-minimum-light.png")
    )

    // Capture both constrained variants before the wider result windows so
    // AppKit cannot carry a prior table scroll offset into their view cache.
    let partialRoot = URL(
      fileURLWithPath:
        "/private/tmp/DevSiftVisualFixture/a-long-synthetic-root-name-for-minimum-window-checks",
      isDirectory: true
    )
    let partialModel = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(representativePartialReport())),
      securityScope: SecurityScopeSpy()
    )
    await partialModel.startScan(at: partialRoot).value
    try render(
      ScanDashboardView(viewModel: partialModel),
      appearance: .aqua,
      size: CGSize(width: 900, height: 620),
      to: outputDirectory.appendingPathComponent("partial-minimum-light.png")
    )

    try render(
      ScanDashboardView(
        viewModel: resultModel,
        policyDetailsInitiallyExpanded: true
      ),
      appearance: .aqua,
      to: outputDirectory.appendingPathComponent("policy-expanded-light.png")
    )
    try render(
      ScanDashboardView(viewModel: resultModel),
      appearance: .aqua,
      to: outputDirectory.appendingPathComponent("result-light.png")
    )
    try render(
      ScanDashboardView(viewModel: resultModel),
      appearance: .darkAqua,
      to: outputDirectory.appendingPathComponent("result-dark.png")
    )
    try render(
      ScanDashboardView(viewModel: resultModel),
      appearance: .aqua,
      size: CGSize(width: 900, height: 620),
      to: outputDirectory.appendingPathComponent("result-minimum-light.png")
    )

    let reviewRoot = URL(
      fileURLWithPath: "/private/tmp/DevSiftVisualFixture/Caches",
      isDirectory: true
    )
    let selectionModel = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(representativePlanningReport())),
      classifier: SyntheticEligibleRuleClassifier(),
      securityScope: SecurityScopeSpy(),
      referenceUnixSeconds: { 1_000_000 }
    )
    await selectionModel.startScan(at: reviewRoot).value
    guard case .result(_, let planningPresentation) = selectionModel.phase else {
      throw SnapshotError.couldNotPrepareDraft
    }
    let selections = planningPresentation.items.compactMap(\.cleanupSelection)
    guard selections.count == 1 else {
      throw SnapshotError.couldNotPrepareDraft
    }
    for selection in selections {
      selectionModel.setCleanupCandidate(selection, isIncluded: true)
    }
    try render(
      ScanDashboardView(viewModel: selectionModel),
      appearance: .aqua,
      size: CGSize(width: 900, height: 620),
      to: outputDirectory.appendingPathComponent("draft-selection-minimum-light.png")
    )

    // Closing a rendered window intentionally invalidates its in-memory draft.
    // Use a fresh model to represent the separate review window snapshot.
    let reviewModel = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(representativePlanningReport())),
      classifier: SyntheticEligibleRuleClassifier(),
      securityScope: SecurityScopeSpy(),
      referenceUnixSeconds: { 1_000_000 }
    )
    await reviewModel.startScan(at: reviewRoot).value
    guard case .result(_, let reviewPresentation) = reviewModel.phase else {
      throw SnapshotError.couldNotPrepareDraft
    }
    let reviewSelections = reviewPresentation.items.compactMap(\.cleanupSelection)
    guard reviewSelections.count == 1 else {
      throw SnapshotError.couldNotPrepareDraft
    }
    for selection in reviewSelections {
      reviewModel.setCleanupCandidate(selection, isIncluded: true)
    }
    guard let reviewTask = reviewModel.prepareCleanupReview() else {
      throw SnapshotError.couldNotPrepareDraft
    }
    await reviewTask.value
    guard case .review = reviewModel.cleanupReviewPhase else {
      throw SnapshotError.couldNotPrepareDraft
    }
    try render(
      ScanDashboardView(viewModel: reviewModel),
      appearance: .aqua,
      size: CGSize(width: 900, height: 620),
      to: outputDirectory.appendingPathComponent("draft-review-minimum-light.png")
    )

    let darkReviewModel = ScanViewModel(
      scanner: ImmediateScanner(outcome: .report(representativePlanningReport())),
      classifier: SyntheticEligibleRuleClassifier(),
      securityScope: SecurityScopeSpy(),
      referenceUnixSeconds: { 1_000_000 }
    )
    await darkReviewModel.startScan(at: reviewRoot).value
    guard case .result(_, let darkReviewPresentation) = darkReviewModel.phase else {
      throw SnapshotError.couldNotPrepareDraft
    }
    let darkReviewSelections = darkReviewPresentation.items.compactMap(\.cleanupSelection)
    guard darkReviewSelections.count == 1 else {
      throw SnapshotError.couldNotPrepareDraft
    }
    for selection in darkReviewSelections {
      darkReviewModel.setCleanupCandidate(selection, isIncluded: true)
    }
    guard let darkReviewTask = darkReviewModel.prepareCleanupReview() else {
      throw SnapshotError.couldNotPrepareDraft
    }
    await darkReviewTask.value
    guard case .review = darkReviewModel.cleanupReviewPhase else {
      throw SnapshotError.couldNotPrepareDraft
    }
    try render(
      ScanDashboardView(viewModel: darkReviewModel),
      appearance: .darkAqua,
      to: outputDirectory.appendingPathComponent("draft-review-dark.png")
    )

    let npmReviewRoot = URL(
      fileURLWithPath: "/private/tmp/DevSiftVisualFixture/.npm",
      isDirectory: true
    )
    for (appearance, suffix) in snapshotAppearances {
      let npmReviewModel = ScanViewModel(
        scanner: ImmediateScanner(outcome: .report(representativeNPMReport())),
        classifier: SnapshotNPMRuleClassifier(),
        securityScope: SecurityScopeSpy(),
        referenceUnixSeconds: { 1_000_000 },
        supportsCleanupQuarantine: { true }
      )
      await npmReviewModel.startScan(at: npmReviewRoot).value
      guard case .result(_, let npmPresentation) = npmReviewModel.phase,
        let npmSelection = npmPresentation.items.first?.cleanupSelection
      else {
        throw SnapshotError.couldNotPrepareDraft
      }
      npmReviewModel.setCleanupCandidate(npmSelection, isIncluded: true)
      guard let npmReviewTask = npmReviewModel.prepareCleanupReview() else {
        throw SnapshotError.couldNotPrepareDraft
      }
      await npmReviewTask.value
      guard case .review = npmReviewModel.cleanupReviewPhase,
        npmReviewModel.cleanupQuarantineAvailability == .available
      else {
        throw SnapshotError.couldNotPrepareDraft
      }
      try render(
        ScanDashboardView(viewModel: npmReviewModel),
        appearance: appearance,
        size: CGSize(width: 1_000, height: 900),
        to: outputDirectory.appendingPathComponent("npm-quarantine-review-\(suffix).png")
      )
    }

    let quarantineResult = CleanupQuarantineResultPresentation(
      result: CleanupQuarantineFrontendExecutionResult(
        outcome: .durablyQuarantined(sourceNameWasRecreated: false),
        durabilityEvidence: .terminalReceiptRecorded(producedByRecovery: false),
        namespaceMutation: .quarantineRootCreated,
        cancellationWasObservedAfterRename: false
      )
    )
    for (appearance, suffix) in snapshotAppearances {
      try render(
        CleanupQuarantineResultView(
          root: npmReviewRoot,
          result: quarantineResult,
          rescan: {},
          openRecovery: {}
        )
        .background(Color(nsColor: .windowBackgroundColor)),
        appearance: appearance,
        size: CGSize(width: 900, height: 620),
        to: outputDirectory.appendingPathComponent("quarantine-result-\(suffix).png")
      )
    }

    for (appearance, suffix) in snapshotAppearances {
      let inventoryModel = QuarantineRecoveryViewModel(
        workflow: SnapshotRecoveryWorkflow(
          inventories: [.success(snapshotRecoveryInventory())]
        )
      )
      await inventoryModel.loadInventory().value
      try render(
        QuarantineRecoveryView(viewModel: inventoryModel),
        appearance: appearance,
        size: CGSize(width: 800, height: 700),
        to: outputDirectory.appendingPathComponent("recovery-inventory-\(suffix).png")
      )

      let confirmationModel = QuarantineRecoveryViewModel(
        workflow: SnapshotRecoveryWorkflow(
          inventories: [.success(snapshotRecoveryInventory())],
          preparation: .success(snapshotPreparedRestore())
        )
      )
      await confirmationModel.loadInventory().value
      guard case .loaded(let confirmationInventory) = confirmationModel.inventoryState,
        let confirmationRow = confirmationInventory.rows.first,
        let preparation = confirmationModel.requestRestore(
          for: confirmationRow.id
        )
      else {
        throw SnapshotError.couldNotPrepareRecovery
      }
      await preparation.value
      guard case .awaitingConfirmation = confirmationModel.restoreState else {
        throw SnapshotError.couldNotPrepareRecovery
      }
      try render(
        QuarantineRecoveryView(viewModel: confirmationModel),
        appearance: appearance,
        size: CGSize(width: 800, height: 760),
        to: outputDirectory.appendingPathComponent("restore-confirmation-\(suffix).png")
      )

      let resultModel = QuarantineRecoveryViewModel(
        workflow: SnapshotRecoveryWorkflow(
          inventories: [
            .success(snapshotRecoveryInventory()),
            .success(QuarantineRecoveryWorkflowInventory(items: [])),
          ],
          preparation: .success(snapshotPreparedRestore()),
          execution: .success(snapshotRestoreResult())
        )
      )
      await resultModel.loadInventory().value
      guard case .loaded(let resultInventory) = resultModel.inventoryState,
        let resultRow = resultInventory.rows.first,
        let resultPreparation = resultModel.requestRestore(for: resultRow.id)
      else {
        throw SnapshotError.couldNotPrepareRecovery
      }
      await resultPreparation.value
      guard case .awaitingConfirmation(let confirmation) = resultModel.restoreState,
        let restore = resultModel.confirmAndRestore(
          confirmationID: confirmation.id,
          exactStatementWasConfirmed: true,
          npmWasStopped: true,
          postQuarantineChangesWereAccepted: true
        )
      else {
        throw SnapshotError.couldNotPrepareRecovery
      }
      await restore.value
      guard case .finished = resultModel.restoreState else {
        throw SnapshotError.couldNotPrepareRecovery
      }
      try render(
        QuarantineRecoveryView(viewModel: resultModel),
        appearance: appearance,
        size: CGSize(width: 800, height: 700),
        to: outputDirectory.appendingPathComponent("restore-result-\(suffix).png")
      )
    }
  }

  private func render<Content: View>(
    _ view: Content,
    appearance: NSAppearance.Name,
    size: CGSize = CGSize(width: 1_200, height: 760),
    to destination: URL
  ) throws {
    let hostingView = NSHostingView(
      rootView:
        view
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        .transaction { transaction in
          transaction.disablesAnimations = true
        }
    )
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = hostingView
    window.orderFrontRegardless()
    defer {
      window.makeFirstResponder(nil)
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    hostingView.frame = window.contentView?.bounds ?? CGRect(origin: .zero, size: size)
    for _ in 0..<10 {
      hostingView.needsLayout = true
      window.contentView?.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      hostingView.layoutSubtreeIfNeeded()
      hostingView.displayIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
      throw SnapshotError.couldNotCreateBitmap
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw SnapshotError.couldNotEncodePNG
    }
    try data.write(to: destination, options: .atomic)
  }

  private func representativeReport() -> ScanReport {
    let rows = [
      row("DerivedData", gibibytes: 45.5, entries: 4_280),
      row("17.4 (21E217)", gibibytes: 11.3, entries: 1_420),
      row("_cacache", gibibytes: 10.0, entries: 1_160),
      row("Homebrew", gibibytes: 5.7, entries: 840),
      row(
        "windows-installer.iso",
        gibibytes: 4.9,
        entries: 1,
        kind: .regularFile
      ),
    ]
    let allocatedBytes = gibibytes(78.1)
    return AppTestReportFactory.report(
      root: AppTestReportFactory.item(
        logicalBytes: gibibytes(82.6),
        allocatedBytes: allocatedBytes,
        hardLinkExclusiveAllocatedBytes: gibibytes(76.8),
        counts: AppTestReportFactory.counts(
          regularFiles: 7_118,
          directories: 583,
          symbolicLinks: 1
        )
      ),
      topLevelItems: rows
    )
  }

  private func representativePartialReport() -> ScanReport {
    let partialRow = row(
      "uv",
      gibibytes: 6.4,
      entries: 420,
      isComplete: false
    )
    let issue = ScanIssue(
      path: partialRow.path,
      operation: .readMetadata,
      reason: .permissionDenied,
      impact: .descendantsSkipped,
      systemCode: 13
    )
    return AppTestReportFactory.report(
      root: AppTestReportFactory.item(
        logicalBytes: gibibytes(8.1),
        allocatedBytes: gibibytes(7.2),
        hardLinkExclusiveAllocatedBytes: gibibytes(6.9),
        counts: AppTestReportFactory.counts(regularFiles: 418, directories: 3),
        unknownAllocatedItemCount: 1,
        isComplete: false
      ),
      topLevelItems: [partialRow],
      hardLinkAccountingIsComplete: false,
      issues: [issue],
      suppressedIssueCount: 2
    )
  }

  private func representativePlanningReport() -> ScanReport {
    let device: UInt64 = 42
    let uv = AppTestReportFactory.item(
      rawComponents: [Array("uv".utf8)],
      scanTimeIdentity: FileIdentity(device: device, inode: 2),
      logicalBytes: gibibytes(6.8),
      allocatedBytes: gibibytes(6.4),
      hardLinkExclusiveAllocatedBytes: gibibytes(6.1),
      counts: AppTestReportFactory.counts(regularFiles: 419, directories: 1),
      newestContentModificationUnixSeconds: 0
    )
    let npm = AppTestReportFactory.item(
      rawComponents: [Array("_cacache".utf8)],
      scanTimeIdentity: FileIdentity(device: device, inode: 3),
      logicalBytes: gibibytes(3.5),
      allocatedBytes: gibibytes(3.1),
      hardLinkExclusiveAllocatedBytes: gibibytes(2.9),
      counts: AppTestReportFactory.counts(regularFiles: 719, directories: 1),
      possibleSharedContentFileCount: 2,
      newestContentModificationUnixSeconds: 0
    )
    return AppTestReportFactory.report(
      root: AppTestReportFactory.item(
        scanTimeIdentity: FileIdentity(device: device, inode: 1),
        logicalBytes: gibibytes(10.3),
        allocatedBytes: gibibytes(9.5),
        hardLinkExclusiveAllocatedBytes: gibibytes(9.0),
        counts: AppTestReportFactory.counts(regularFiles: 1_138, directories: 3),
        possibleSharedContentFileCount: 2,
        newestContentModificationUnixSeconds: 0
      ),
      topLevelItems: [uv, npm]
    )
  }

  private func representativeNPMReport() -> ScanReport {
    let device: UInt64 = 126
    let candidate = AppTestReportFactory.item(
      rawComponents: [Array("_cacache".utf8)],
      scanTimeIdentity: FileIdentity(device: device, inode: 2),
      logicalBytes: gibibytes(3.5),
      allocatedBytes: gibibytes(3.1),
      hardLinkExclusiveAllocatedBytes: gibibytes(2.9),
      counts: AppTestReportFactory.counts(regularFiles: 719, directories: 1),
      possibleSharedContentFileCount: 2,
      newestContentModificationUnixSeconds: 0
    )
    return AppTestReportFactory.report(
      root: AppTestReportFactory.item(
        scanTimeIdentity: FileIdentity(device: device, inode: 1),
        logicalBytes: gibibytes(3.5),
        allocatedBytes: gibibytes(3.1),
        hardLinkExclusiveAllocatedBytes: gibibytes(2.9),
        counts: AppTestReportFactory.counts(regularFiles: 719, directories: 2),
        possibleSharedContentFileCount: 2,
        newestContentModificationUnixSeconds: 0
      ),
      topLevelItems: [candidate]
    )
  }

  private func row(
    _ name: String,
    gibibytes: Double,
    entries: UInt64,
    kind: FileSystemEntryKind = .directory,
    isComplete: Bool = true
  ) -> ScanItemSummary {
    let allocatedBytes = self.gibibytes(gibibytes)
    let directories: UInt64 = kind == .directory ? 1 : 0
    let regularFiles = entries - directories
    return AppTestReportFactory.item(
      rawComponents: [Array(name.utf8)],
      kind: kind,
      logicalBytes: allocatedBytes + (allocatedBytes / 10),
      allocatedBytes: allocatedBytes,
      hardLinkExclusiveAllocatedBytes: allocatedBytes - (allocatedBytes / 100),
      counts: AppTestReportFactory.counts(
        regularFiles: regularFiles,
        directories: directories
      ),
      isComplete: isComplete
    )
  }

  private func gibibytes(_ value: Double) -> UInt64 {
    UInt64(value * 1_024 * 1_024 * 1_024)
  }

  private var snapshotAppearances: [(NSAppearance.Name, String)] {
    [(.aqua, "light"), (.darkAqua, "dark")]
  }
}

private enum SnapshotError: Error {
  case couldNotCreateBitmap
  case couldNotEncodePNG
  case couldNotPrepareDraft
  case couldNotPrepareRecovery
}

private struct SnapshotNPMRuleClassifier: RuleClassifying, Sendable {
  func classify(
    _ request: RuleClassificationRequest
  ) async throws -> RuleClassificationReport {
    let observations = request.report.topLevelItems.map { summary in
      RuleObservation(
        summary: summary,
        selectedRootBasename: .known(Array(".npm".utf8)),
        integrity: RuleScanIntegrity(
          reportIsComplete: true,
          itemIsComplete: true,
          topLevelItemsWereSuppressed: false,
          traversalDetailsWereDiscarded: false,
          suppressedIssueCount: 0,
          unknownAllocatedItemCount: 0,
          sizeOverflowed: false,
          hardLinkAccountingIsComplete: true,
          identityMatchesScan: .known(true)
        ),
        facts: RuleObservationFacts(
          trustedLocation: .known(true),
          accountOwnedCacheNamespace: .known(true),
          generatedContentMarker: .known(true),
          newestContentModificationUnixSeconds: .known(
            summary.newestContentModificationUnixSeconds ?? 0
          ),
          activity: .unknown(.notCollected),
          protectedDescendantPresent: .known(false)
        )
      )
    }
    return try await ExplainableRuleClassifier().classify(
      observations: observations,
      referenceUnixSeconds: request.referenceUnixSeconds
    ).binding(to: request)
  }
}

private actor SnapshotRecoveryWorkflow: QuarantineRecoveryWorkflowHandling {
  private var inventories:
    [Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>]
  private let preparation:
    Result<
      QuarantineRecoveryPreparedRestore,
      QuarantineRestorePreparationFailure
    >
  private let execution:
    Result<
      QuarantineRecoveryWorkflowExecutionResult,
      QuarantineRecoveryWorkflowExecutionFailure
    >

  init(
    inventories: [Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>],
    preparation: Result<
      QuarantineRecoveryPreparedRestore,
      QuarantineRestorePreparationFailure
    > = .failure(.inventoryChanged),
    execution: Result<
      QuarantineRecoveryWorkflowExecutionResult,
      QuarantineRecoveryWorkflowExecutionFailure
    > = .failure(.execution(.cancelled))
  ) {
    self.inventories = inventories
    self.preparation = preparation
    self.execution = execution
  }

  func reconcileAndLoadInventory()
    -> Result<QuarantineRecoveryWorkflowInventory, QuarantineInventoryLoadFailure>
  {
    guard !inventories.isEmpty else {
      return .success(QuarantineRecoveryWorkflowInventory(items: []))
    }
    return inventories.removeFirst()
  }

  func beginRestore(
    for item: QuarantineRecoveryWorkflowItemHandle
  ) -> Result<QuarantineRecoveryPreparedRestore, QuarantineRestorePreparationFailure> {
    preparation
  }

  func authorizeAndRestore(
    _ preparedRestore: QuarantineRecoveryPreparedRestoreHandle,
    statement: QuarantineRestoreConfirmationStatement
  ) -> Result<
    QuarantineRecoveryWorkflowExecutionResult,
    QuarantineRecoveryWorkflowExecutionFailure
  > {
    execution
  }

  func cancelPendingRestore() {}
}

private func snapshotRecoveryInventory() -> QuarantineRecoveryWorkflowInventory {
  let identity = QuarantineRecoveryInventoryIdentity()
  return QuarantineRecoveryWorkflowInventory(
    items: [
      QuarantineRecoveryWorkflowInventoryItem(
        handle: QuarantineRecoveryWorkflowItemHandle(identity: identity, ordinal: 0),
        responsibleTool: "npm",
        originalName: "_cacache",
        readiness: QuarantineInventoryRestoreReadiness(
          originalSource: .missing,
          quarantinedItem: .available
        ),
        quarantineReceiptWasProducedByRecovery: true
      )
    ]
  )
}

private func snapshotPreparedRestore() -> QuarantineRecoveryPreparedRestore {
  QuarantineRecoveryPreparedRestore(
    handle: QuarantineRecoveryPreparedRestoreHandle(
      identity: QuarantineRecoveryAttemptIdentity()
    ),
    requiredStatement:
      .restoreCurrentQuarantinedContentsWithoutOverwriteWithNPMStoppedAndChangesAccepted,
    responsibleTool: "npm",
    originalName: "_cacache"
  )
}

private func snapshotRestoreResult() -> QuarantineRecoveryWorkflowExecutionResult {
  QuarantineRecoveryWorkflowExecutionResult(
    status: .restored(quarantineNameWasRecreated: false),
    durability: .receiptRecorded(producedByRecovery: false),
    cancellationWasObservedAfterRename: false,
    isDurablyRestored: true
  )
}
