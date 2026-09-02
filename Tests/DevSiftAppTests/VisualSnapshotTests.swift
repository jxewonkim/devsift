import AppKit
import DevSiftCore
import Foundation
import SwiftUI
import Testing

@testable import DevSiftApp

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
  }

  private func render(
    _ view: ScanDashboardView,
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
}

private enum SnapshotError: Error {
  case couldNotCreateBitmap
  case couldNotEncodePNG
}
