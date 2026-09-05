import DevSiftCore
import Foundation
import Observation

enum ScanFailure: Equatable, Sendable {
  case scan(ScanError)
  case classification
  case unexpected

  var title: String {
    switch self {
    case .scan:
      "This folder could not be scanned"
    case .classification:
      "Policy analysis could not be completed"
    case .unexpected:
      "The scan could not be completed"
    }
  }

  var message: String {
    switch self {
    case .scan(let error):
      error.errorDescription ?? "The selected folder could not be read."
    case .classification:
      "The storage observation finished, but its read-only policy report is unavailable. No files were changed."
    case .unexpected:
      "An unexpected error occurred. No files were changed."
    }
  }
}

enum CleanupReviewFailure: Equatable, Sendable {
  case planning

  var title: String {
    "Draft review unavailable"
  }

  var message: String {
    "DevSift could not create a complete in-memory draft from this scan. Nothing was approved or changed."
  }
}

enum CleanupReviewPhase: Equatable, Sendable {
  case unavailable
  case selecting
  case preparing(selectedCount: Int)
  case review(CleanupManifestReviewPresentation)
  case failed(CleanupReviewFailure)

  var isPreparing: Bool {
    if case .preparing = self {
      return true
    }
    return false
  }
}

enum ScanDashboardPhase: Equatable, Sendable {
  case empty
  case scanning(URL)
  case classifying(URL)
  case result(URL, ScanPresentation)
  case cancelled(URL)
  case failed(URL, ScanFailure)

  var root: URL? {
    switch self {
    case .empty:
      nil
    case .scanning(let root), .classifying(let root), .result(let root, _), .cancelled(let root),
      .failed(let root, _):
      root
    }
  }
}

@MainActor
@Observable
final class ScanViewModel {
  private(set) var phase: ScanDashboardPhase = .empty
  private(set) var cleanupReviewPhase: CleanupReviewPhase = .unavailable
  private(set) var selectedCleanupCandidates: Set<CleanupCandidateSelection> = []

  @ObservationIgnored private let scanner: any FileSystemScanning
  @ObservationIgnored private let classifier: any RuleClassifying
  @ObservationIgnored private let cleanupApprover: any CleanupApproving
  @ObservationIgnored private let limits: ScanLimits
  @ObservationIgnored private let securityScope: any SecurityScopedResourceAccessing
  @ObservationIgnored private let referenceUnixSeconds: @Sendable () -> Int64
  @ObservationIgnored private var activeScanID: UUID?
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var cleanupPlanningContext: CleanupPlanningContext?
  @ObservationIgnored private var cleanupApprovalReviewSession: CleanupApprovalReviewSession?
  @ObservationIgnored private var activeCleanupPlanningID: UUID?
  @ObservationIgnored private var cleanupPlanningTask: Task<Void, Never>?

  init(
    scanner: any FileSystemScanning = AllocatedSizeScanner(),
    classifier: any RuleClassifying = ExplainableRuleClassifier(),
    cleanupApprover: any CleanupApproving = CleanupApprover(),
    limits: ScanLimits = ScanLimits(),
    securityScope: any SecurityScopedResourceAccessing = FoundationSecurityScopedResourceAccess(),
    referenceUnixSeconds: @escaping @Sendable () -> Int64 = {
      Int64(Date().timeIntervalSince1970)
    }
  ) {
    self.scanner = scanner
    self.classifier = classifier
    self.cleanupApprover = cleanupApprover
    self.limits = limits
    self.securityScope = securityScope
    self.referenceUnixSeconds = referenceUnixSeconds
  }

  var isWorking: Bool {
    switch phase {
    case .scanning, .classifying:
      return true
    default:
      return false
    }
  }

  var isScanning: Bool {
    if case .scanning = phase {
      return true
    }
    return false
  }

  var canRescan: Bool {
    phase.root != nil && !isWorking
  }

  var cleanupCandidateCount: Int {
    cleanupPlanningContext?.candidates.count ?? 0
  }

  var canPrepareCleanupReview: Bool {
    guard !selectedCleanupCandidates.isEmpty else {
      return false
    }
    switch cleanupReviewPhase {
    case .selecting, .failed:
      return true
    case .unavailable, .preparing, .review:
      return false
    }
  }

  @discardableResult
  func startScan(at root: URL) -> Task<Void, Never> {
    invalidateActiveScan()
    invalidateCleanupReview()

    let scanID = UUID()
    activeScanID = scanID
    phase = .scanning(root)

    let scanner = scanner
    let classifier = classifier
    let limits = limits
    let securityScope = securityScope
    let referenceUnixSeconds = referenceUnixSeconds
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
        guard self?.beginClassification(scanID: scanID, root: root) == true else {
          return
        }

        let classificationRequest = RuleClassificationRequest(
          root: root,
          report: report,
          referenceUnixSeconds: referenceUnixSeconds()
        )
        let classification: RuleClassificationReport
        do {
          classification = try await classifier.classify(classificationRequest)
          try classification.validate(for: classificationRequest)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          self?.finish(scanID: scanID, phase: .failed(root, .classification))
          return
        }

        try Task.checkCancellation()
        let presentation = try await ScanPresentation.prepare(
          report: report,
          classification: classification
        )
        try Task.checkCancellation()
        self?.finishResult(
          scanID: scanID,
          root: root,
          classificationRequest: classificationRequest,
          classification: classification,
          presentation: presentation
        )
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
    let root: URL
    switch phase {
    case .scanning(let activeRoot), .classifying(let activeRoot):
      root = activeRoot
    default:
      return
    }

    invalidateActiveScan()
    phase = .cancelled(root)
  }

  func stopForWindowClosure() {
    invalidateActiveScan()
    invalidateCleanupReview()
  }

  func setCleanupCandidate(
    _ selection: CleanupCandidateSelection,
    isIncluded: Bool
  ) {
    guard
      let context = cleanupPlanningContext,
      context.candidates.contains(selection),
      allowsCleanupSelectionChanges
    else {
      return
    }

    if isIncluded {
      selectedCleanupCandidates.insert(selection)
    } else {
      selectedCleanupCandidates.remove(selection)
    }
    cleanupReviewPhase = .selecting
  }

  func clearCleanupCandidates() {
    guard allowsCleanupSelectionChanges else {
      return
    }
    selectedCleanupCandidates.removeAll(keepingCapacity: true)
    cleanupReviewPhase = .selecting
  }

  @discardableResult
  func prepareCleanupReview() -> Task<Void, Never>? {
    guard
      let context = cleanupPlanningContext,
      canPrepareCleanupReview
    else {
      return nil
    }

    let selections = selectedCleanupCandidates.sorted(by: cleanupSelectionOrder)
    let request = CleanupManifestRequest(
      classificationRequest: context.classificationRequest,
      classificationReport: context.classification,
      selections: selections
    )
    let planningID = UUID()
    activeCleanupPlanningID = planningID
    cleanupReviewPhase = .preparing(selectedCount: selections.count)

    let approver = cleanupApprover
    let worker = Task.detached(priority: .userInitiated) {
      let session = try approver.beginReview(request)
      try Task.checkCancellation()
      let presentation = try CleanupManifestReviewPresentation.prepare(
        manifest: session.reviewedManifest
      )
      return PreparedCleanupReview(session: session, presentation: presentation)
    }
    let task = Task { [weak self] in
      do {
        let prepared = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: {
          worker.cancel()
        }
        try Task.checkCancellation()
        self?.finishCleanupReview(
          planningID: planningID,
          sessionID: context.sessionID,
          prepared: prepared
        )
      } catch is CancellationError {
        self?.finishCleanupReview(
          planningID: planningID,
          sessionID: context.sessionID,
          phase: .selecting
        )
      } catch {
        self?.finishCleanupReview(
          planningID: planningID,
          sessionID: context.sessionID,
          phase: .failed(.planning)
        )
      }
    }
    cleanupPlanningTask = task
    return task
  }

  func cancelCleanupReviewPreparation() {
    guard cleanupReviewPhase.isPreparing else {
      return
    }
    cancelCleanupPlanningTask()
    cleanupReviewPhase = .selecting
  }

  func dismissCleanupReview() {
    guard case .review = cleanupReviewPhase else {
      return
    }
    cleanupApprovalReviewSession = nil
    cleanupReviewPhase = .selecting
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

  private func finishResult(
    scanID: UUID,
    root: URL,
    classificationRequest: RuleClassificationRequest,
    classification: RuleClassificationReport,
    presentation: ScanPresentation
  ) {
    guard scanID == activeScanID else {
      return
    }

    activeScanID = nil
    scanTask = nil
    selectedCleanupCandidates = []
    cleanupPlanningContext = CleanupPlanningContext(
      sessionID: scanID,
      classificationRequest: classificationRequest,
      classification: classification,
      candidates: Set(presentation.items.compactMap(\.cleanupSelection))
    )
    cleanupReviewPhase = .selecting
    phase = .result(root, presentation)
  }

  private func finishCleanupReview(
    planningID: UUID,
    sessionID: UUID,
    phase: CleanupReviewPhase
  ) {
    guard
      planningID == activeCleanupPlanningID,
      cleanupPlanningContext?.sessionID == sessionID
    else {
      return
    }

    activeCleanupPlanningID = nil
    cleanupPlanningTask = nil
    cleanupApprovalReviewSession = nil
    cleanupReviewPhase = phase
  }

  private func finishCleanupReview(
    planningID: UUID,
    sessionID: UUID,
    prepared: PreparedCleanupReview
  ) {
    guard
      planningID == activeCleanupPlanningID,
      cleanupPlanningContext?.sessionID == sessionID
    else {
      return
    }

    activeCleanupPlanningID = nil
    cleanupPlanningTask = nil
    cleanupApprovalReviewSession = prepared.session
    cleanupReviewPhase = .review(prepared.presentation)
  }

  private var allowsCleanupSelectionChanges: Bool {
    switch cleanupReviewPhase {
    case .selecting, .failed:
      return true
    case .unavailable, .preparing, .review:
      return false
    }
  }

  private func invalidateCleanupReview() {
    cancelCleanupPlanningTask()
    cleanupPlanningContext = nil
    cleanupApprovalReviewSession = nil
    selectedCleanupCandidates = []
    cleanupReviewPhase = .unavailable
  }

  private func cancelCleanupPlanningTask() {
    activeCleanupPlanningID = nil
    let task = cleanupPlanningTask
    cleanupPlanningTask = nil
    task?.cancel()
  }

  private func beginClassification(scanID: UUID, root: URL) -> Bool {
    guard scanID == activeScanID else {
      return false
    }
    phase = .classifying(root)
    return true
  }
}

private struct PreparedCleanupReview: Sendable {
  let session: CleanupApprovalReviewSession
  let presentation: CleanupManifestReviewPresentation
}

private struct CleanupPlanningContext: Sendable {
  let sessionID: UUID
  let classificationRequest: RuleClassificationRequest
  let classification: RuleClassificationReport
  let candidates: Set<CleanupCandidateSelection>
}

private func cleanupSelectionOrder(
  _ left: CleanupCandidateSelection,
  _ right: CleanupCandidateSelection
) -> Bool {
  if left.path != right.path {
    return left.path < right.path
  }
  return left.ruleRevision < right.ruleRevision
}
