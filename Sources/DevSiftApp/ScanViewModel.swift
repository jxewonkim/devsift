import DevSiftCore
import Foundation
import Observation

enum ScanFailure: Equatable, Sendable {
  case scan(ScanError)
  case unexpected

  var title: String {
    switch self {
    case .scan:
      "This folder could not be scanned"
    case .unexpected:
      "The scan could not be completed"
    }
  }

  var message: String {
    switch self {
    case .scan(let error):
      error.errorDescription ?? "The selected folder could not be read."
    case .unexpected:
      "An unexpected error occurred. No files were changed."
    }
  }
}

enum ScanDashboardPhase: Equatable, Sendable {
  case empty
  case scanning(URL)
  case result(URL, ScanPresentation)
  case cancelled(URL)
  case failed(URL, ScanFailure)

  var root: URL? {
    switch self {
    case .empty:
      nil
    case .scanning(let root), .result(let root, _), .cancelled(let root),
      .failed(let root, _):
      root
    }
  }
}

@MainActor
@Observable
final class ScanViewModel {
  private(set) var phase: ScanDashboardPhase = .empty

  @ObservationIgnored private let scanner: any FileSystemScanning
  @ObservationIgnored private let limits: ScanLimits
  @ObservationIgnored private let securityScope: any SecurityScopedResourceAccessing
  @ObservationIgnored private var activeScanID: UUID?
  @ObservationIgnored private var scanTask: Task<Void, Never>?

  init(
    scanner: any FileSystemScanning = AllocatedSizeScanner(),
    limits: ScanLimits = ScanLimits(),
    securityScope: any SecurityScopedResourceAccessing = FoundationSecurityScopedResourceAccess()
  ) {
    self.scanner = scanner
    self.limits = limits
    self.securityScope = securityScope
  }

  var isScanning: Bool {
    if case .scanning = phase {
      return true
    }
    return false
  }

  var canRescan: Bool {
    phase.root != nil && !isScanning
  }

  @discardableResult
  func startScan(at root: URL) -> Task<Void, Never> {
    invalidateActiveScan()

    let scanID = UUID()
    activeScanID = scanID
    phase = .scanning(root)

    let scanner = scanner
    let limits = limits
    let securityScope = securityScope
    let task = Task { [weak self] in
      do {
        try Task.checkCancellation()
        let didStartSecurityScope = securityScope.startAccessing(root)
        defer {
          if didStartSecurityScope {
            securityScope.stopAccessing(root)
          }
        }

        let report = try await scanner.scan(ScanRequest(root: root, limits: limits))
        try Task.checkCancellation()
        let presentation = try await ScanPresentation.prepare(report: report)
        try Task.checkCancellation()
        self?.finish(scanID: scanID, phase: .result(root, presentation))
      } catch is CancellationError {
        self?.finish(scanID: scanID, phase: .cancelled(root))
      } catch let error as ScanError {
        self?.finish(scanID: scanID, phase: .failed(root, .scan(error)))
      } catch {
        self?.finish(scanID: scanID, phase: .failed(root, .unexpected))
      }
    }
    scanTask = task
    return task
  }

  @discardableResult
  func rescan() -> Task<Void, Never>? {
    guard let root = phase.root else {
      return nil
    }
    return startScan(at: root)
  }

  func cancelScan() {
    guard case .scanning(let root) = phase else {
      return
    }

    invalidateActiveScan()
    phase = .cancelled(root)
  }

  func stopForWindowClosure() {
    invalidateActiveScan()
  }

  private func invalidateActiveScan() {
    activeScanID = nil
    let task = scanTask
    scanTask = nil
    task?.cancel()
  }

  private func finish(scanID: UUID, phase: ScanDashboardPhase) {
    guard scanID == activeScanID else {
      return
    }

    activeScanID = nil
    scanTask = nil
    self.phase = phase
  }
}
