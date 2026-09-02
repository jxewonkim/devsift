import Darwin
import Foundation

public struct AllocatedSizeScanner: FileSystemScanning, Sendable {
  typealias MetadataTransform =
    @Sendable (ScanRelativePath, FileMetadata) throws -> FileMetadata
  typealias Checkpoint = @Sendable (UInt64) throws -> Void
  typealias DirectoryHook = @Sendable (ScanRelativePath) throws -> Void
  typealias RootHook = @Sendable () throws -> Void

  private let transformMetadata: MetadataTransform
  private let checkpoint: Checkpoint
  private let afterRootValidation: RootHook
  private let beforeOpeningDirectory: DirectoryHook

  public init() {
    transformMetadata = { _, metadata in metadata }
    checkpoint = { _ in try Task.checkCancellation() }
    afterRootValidation = {}
    beforeOpeningDirectory = { _ in }
  }

  init(
    metadataTransform: @escaping MetadataTransform = { _, metadata in metadata },
    checkpoint: @escaping Checkpoint = { _ in try Task.checkCancellation() },
    afterRootValidation: @escaping RootHook = {},
    beforeOpeningDirectory: @escaping DirectoryHook = { _ in }
  ) {
    transformMetadata = metadataTransform
    self.checkpoint = checkpoint
    self.afterRootValidation = afterRootValidation
    self.beforeOpeningDirectory = beforeOpeningDirectory
  }

  public func scan(_ request: ScanRequest) async throws -> ScanReport {
    let priority = Task.currentPriority
    let worker = Task.detached(priority: priority) {
      try scanOnWorker(request)
    }

    return try await withTaskCancellationHandler {
      do {
        let report = try await worker.value
        try Task.checkCancellation()
        return report
      } catch {
        try Task.checkCancellation()
        throw error
      }
    } onCancel: {
      worker.cancel()
    }
  }

  public func scan(root: URL, limits: ScanLimits = ScanLimits()) async throws -> ScanReport {
    try await scan(ScanRequest(root: root, limits: limits))
  }

  private func scanOnWorker(_ request: ScanRequest) throws -> ScanReport {
    try checkpoint(0)
    try validateLocalRootURL(request.root)

    let initialRootMetadata = try validatedRootMetadata(at: request.root)
    try afterRootValidation()

    let rootDescriptor: Int32
    do {
      rootDescriptor = try openRootDirectory(at: request.root)
    } catch {
      let code = posixCode(for: error)
      if code == ELOOP || code == ENOENT || code == ENOTDIR {
        throw ScanError.rootChangedDuringValidation
      }
      throw ScanError.rootUnavailable(operation: .validateRoot, systemCode: code)
    }

    let openedRootMetadata: FileMetadata
    do {
      openedRootMetadata = try FileMetadata.read(fromDescriptor: rootDescriptor)
    } catch {
      closeIgnoringErrors(rootDescriptor)
      throw ScanError.rootUnavailable(
        operation: .validateRoot,
        systemCode: posixCode(for: error)
      )
    }

    guard
      openedRootMetadata.kind == .directory,
      openedRootMetadata.identity == initialRootMetadata.identity
    else {
      closeIgnoringErrors(rootDescriptor)
      throw ScanError.rootChangedDuringValidation
    }

    var state = TraversalState(limits: request.limits, rootMetadata: openedRootMetadata)
    let outcome = try walkDirectory(
      ownedDescriptor: rootDescriptor,
      path: .root,
      rootDevice: openedRootMetadata.identity.device,
      state: &state
    )

    if outcome == .entryLimitReached {
      state = TraversalState(limits: request.limits, rootMetadata: openedRootMetadata)
      state.discardDetailsForEntryLimit()
      state.append(
        ScanIssue(
          path: .root,
          operation: .listDirectory,
          reason: .resourceLimit,
          impact: .descendantsSkipped
        )
      )
    }

    return state.finish()
  }

  private func walkDirectory(
    ownedDescriptor descriptor: Int32,
    path: ScanRelativePath,
    rootDevice: UInt64,
    state: inout TraversalState
  ) throws -> TraversalOutcome {
    guard let stream = Darwin.fdopendir(descriptor) else {
      let code = errno
      closeIgnoringErrors(descriptor)
      state.append(
        issue(
          for: FileMetadataError(code: code),
          path: path,
          operation: .listDirectory,
          impact: .descendantsSkipped
        )
      )
      return .completed
    }
    defer { _ = Darwin.closedir(stream) }

    let anchorDescriptor = Darwin.dirfd(stream)

    while true {
      try Task.checkCancellation()
      errno = 0

      guard let entry = Darwin.readdir(stream) else {
        let code = errno
        if code != 0 {
          state.append(
            issue(
              for: FileMetadataError(code: code),
              path: path,
              operation: .listDirectory,
              impact: .descendantsSkipped
            )
          )
        }
        return .completed
      }

      let name = fileSystemName(from: entry)
      if name.bytes == [0x2E] || name.bytes == [0x2E, 0x2E] {
        continue
      }

      guard state.scannedEntryCount < state.limits.maximumEntries else {
        return .entryLimitReached
      }

      state.scannedEntryCount += 1
      try checkpoint(state.scannedEntryCount)

      let childPath = path.appending(rawComponent: name.bytes)
      guard childPath.rawComponents.count <= Int(state.limits.maximumDepth) else {
        state.append(
          ScanIssue(
            path: childPath,
            operation: .listDirectory,
            reason: .depthLimitReached,
            impact: .entrySkipped
          )
        )
        continue
      }

      let observedMetadata: FileMetadata
      do {
        observedMetadata = try FileMetadata.read(at: anchorDescriptor, name: name)
      } catch {
        state.append(
          issue(
            for: error,
            path: childPath,
            operation: .readMetadata,
            impact: .descendantsSkipped
          )
        )
        continue
      }

      guard observedMetadata.identity.device == rootDevice else {
        state.append(crossVolumeIssue(at: childPath))
        continue
      }

      if observedMetadata.kind != .directory {
        do {
          let metadata = try transformMetadata(childPath, observedMetadata)
          guard metadata.identity.device == rootDevice else {
            state.append(crossVolumeIssue(at: childPath))
            continue
          }
          state.observe(path: childPath, metadata: metadata)
        } catch {
          state.append(
            issue(
              for: error,
              path: childPath,
              operation: .readMetadata,
              impact: .entrySkipped
            )
          )
        }
        continue
      }

      if childPath.rawComponents.count == Int(state.limits.maximumDepth) {
        do {
          let metadata = try transformMetadata(childPath, observedMetadata)
          guard metadata.identity.device == rootDevice else {
            state.append(crossVolumeIssue(at: childPath))
            continue
          }
          state.observe(path: childPath, metadata: metadata)
          state.append(
            ScanIssue(
              path: childPath,
              operation: .listDirectory,
              reason: .depthLimitReached,
              impact: .descendantsSkipped
            )
          )
        } catch {
          state.append(
            issue(
              for: error,
              path: childPath,
              operation: .readMetadata,
              impact: .descendantsSkipped
            )
          )
        }
        continue
      }

      try beforeOpeningDirectory(childPath)

      let childDescriptor: Int32
      do {
        childDescriptor = try openChildDirectory(at: anchorDescriptor, name: name)
      } catch {
        let code = posixCode(for: error)
        if code == ELOOP || code == ENOTDIR {
          state.append(changedDirectoryIssue(at: childPath))
        } else {
          state.append(
            issue(
              for: error,
              path: childPath,
              operation: .listDirectory,
              impact: .descendantsSkipped
            )
          )
        }
        continue
      }

      let openedMetadata: FileMetadata
      do {
        openedMetadata = try FileMetadata.read(fromDescriptor: childDescriptor)
      } catch {
        closeIgnoringErrors(childDescriptor)
        state.append(
          issue(
            for: error,
            path: childPath,
            operation: .readMetadata,
            impact: .descendantsSkipped
          )
        )
        continue
      }

      guard
        openedMetadata.kind == .directory,
        openedMetadata.identity == observedMetadata.identity
      else {
        closeIgnoringErrors(childDescriptor)
        state.append(changedDirectoryIssue(at: childPath))
        continue
      }

      let metadata: FileMetadata
      do {
        metadata = try transformMetadata(childPath, openedMetadata)
      } catch {
        closeIgnoringErrors(childDescriptor)
        state.append(
          issue(
            for: error,
            path: childPath,
            operation: .readMetadata,
            impact: .descendantsSkipped
          )
        )
        continue
      }

      guard metadata.identity.device == rootDevice else {
        closeIgnoringErrors(childDescriptor)
        state.append(crossVolumeIssue(at: childPath))
        continue
      }

      state.observe(path: childPath, metadata: metadata)
      let outcome = try walkDirectory(
        ownedDescriptor: childDescriptor,
        path: childPath,
        rootDevice: rootDevice,
        state: &state
      )
      if outcome == .entryLimitReached {
        return outcome
      }
    }
  }

  private func validatedRootMetadata(at url: URL) throws -> FileMetadata {
    let metadata: FileMetadata

    do {
      metadata = try FileMetadata.read(from: url)
    } catch {
      throw rootError(for: error)
    }

    guard metadata.kind != .symbolicLink else {
      throw ScanError.rootIsSymbolicLink
    }
    guard metadata.kind == .directory else {
      throw ScanError.rootIsNotDirectory
    }
    return metadata
  }
}

private enum TraversalOutcome {
  case completed
  case entryLimitReached
}

private struct TraversalState {
  let limits: ScanLimits
  var scannedEntryCount: UInt64 = 0
  private var aggregator: ScanAggregator
  private var issues: ScanIssueCollector

  init(limits: ScanLimits, rootMetadata: FileMetadata) {
    self.limits = limits
    aggregator = ScanAggregator(rootMetadata: rootMetadata, limits: limits)
    issues = ScanIssueCollector(limit: limits.maximumRecordedIssues)
  }

  mutating func observe(path: ScanRelativePath, metadata: FileMetadata) {
    for aggregationIssue in aggregator.observe(path: path, metadata: metadata) {
      append(aggregationIssue)
    }
  }

  mutating func append(_ issue: ScanIssue) {
    issues.append(issue)
  }

  mutating func discardDetailsForEntryLimit() {
    aggregator.discardDetailsForEntryLimit()
  }

  mutating func finish() -> ScanReport {
    for aggregationIssue in aggregator.finalizeHardLinks() {
      append(aggregationIssue)
    }
    for overflowIssue in aggregator.overflowIssues() {
      append(overflowIssue)
    }

    let issueSnapshot = issues.snapshot()
    return aggregator.report(
      issues: issueSnapshot.issues,
      suppressedIssueCount: issueSnapshot.suppressedCount
    )
  }
}

private struct ScanAggregator {
  private var root: SummaryAccumulator
  private var topLevel: [[UInt8]: SummaryAccumulator] = [:]
  private var topLevelItemCount: UInt64 = 0
  private var topLevelItemsWereSuppressed = false
  private var hardLinks: [FileIdentity: HardLinkGroup] = [:]
  private var incompleteTopLevelComponents: Set<[UInt8]> = []
  private var trackedHardLinkEntryCount: UInt64 = 0
  private var trackedHardLinkPathBytes: UInt64 = 0
  private var hardLinkAccountingIsComplete = true
  private var traversalDetailsWereDiscarded = false
  private let maximumTopLevelItems: UInt32
  private let maximumTrackedHardLinkEntries: UInt32
  private let maximumTrackedHardLinkPathBytes: UInt64

  init(rootMetadata: FileMetadata, limits: ScanLimits) {
    root = SummaryAccumulator(path: .root, kind: .directory)
    root.observePath(kind: .directory)
    root.observeModificationTime(rootMetadata.modificationUnixSeconds)
    root.addApparentContribution(rootMetadata)
    root.addExclusiveAllocatedContribution(rootMetadata)
    maximumTopLevelItems = limits.maximumTopLevelItems
    maximumTrackedHardLinkEntries = limits.maximumTrackedHardLinkEntries
    maximumTrackedHardLinkPathBytes = limits.maximumTrackedHardLinkPathBytes
  }

  mutating func observe(path: ScanRelativePath, metadata: FileMetadata) -> [ScanIssue] {
    guard let topLevelComponent = path.topLevelRawComponent else {
      return []
    }

    var aggregationIssues: [ScanIssue] = []

    if path.rawComponents.count == 1 {
      saturatingIncrement(&topLevelItemCount)

      if !topLevelItemsWereSuppressed,
        topLevel.count >= Int(maximumTopLevelItems)
      {
        topLevel.removeAll(keepingCapacity: false)
        topLevelItemsWereSuppressed = true
        aggregationIssues.append(
          ScanIssue(
            path: .root,
            operation: .listDirectory,
            reason: .resourceLimit,
            impact: .estimateDegraded
          )
        )
      }
    }

    if !topLevelItemsWereSuppressed {
      ensureTopLevel(
        topLevelComponent,
        kind: path.rawComponents.count == 1 ? metadata.kind : .other
      )
    }

    root.observePath(kind: metadata.kind)
    root.observeModificationTime(metadata.modificationUnixSeconds)
    root.addApparentContribution(metadata)
    if !topLevelItemsWereSuppressed {
      topLevel[topLevelComponent]?.observePath(kind: metadata.kind)
      topLevel[topLevelComponent]?.observeModificationTime(metadata.modificationUnixSeconds)
      topLevel[topLevelComponent]?.addApparentContribution(metadata)

      if path.rawComponents.count == 1 {
        topLevel[topLevelComponent]?.kind = metadata.kind
      }
    }

    guard metadata.kind == .regularFile, metadata.hardLinkCount > 1 else {
      root.addExclusiveAllocatedContribution(metadata)
      if !topLevelItemsWereSuppressed {
        topLevel[topLevelComponent]?.addExclusiveAllocatedContribution(metadata)
      }
      return aggregationIssues
    }

    guard hardLinkAccountingIsComplete else {
      return aggregationIssues
    }

    let pathByteCount = path.rawComponents.reduce(into: UInt64(0)) { total, component in
      _ = saturatingAdd(UInt64(component.count), to: &total)
    }
    let (newTrackedPathBytes, pathByteOverflow) =
      trackedHardLinkPathBytes.addingReportingOverflow(pathByteCount)

    guard
      trackedHardLinkEntryCount < UInt64(maximumTrackedHardLinkEntries),
      !pathByteOverflow,
      newTrackedPathBytes <= maximumTrackedHardLinkPathBytes
    else {
      hardLinks.removeAll(keepingCapacity: false)
      hardLinkAccountingIsComplete = false
      aggregationIssues.append(
        ScanIssue(
          path: .root,
          operation: .measureSize,
          reason: .resourceLimit,
          impact: .estimateDegraded
        )
      )
      return aggregationIssues
    }
    trackedHardLinkEntryCount += 1
    trackedHardLinkPathBytes = newTrackedPathBytes

    if var group = hardLinks[metadata.identity] {
      group.observe(path: path, metadata: metadata)
      hardLinks[metadata.identity] = group
      return aggregationIssues
    }

    hardLinks[metadata.identity] = HardLinkGroup(path: path, metadata: metadata)
    return aggregationIssues
  }

  mutating func finalizeHardLinks() -> [ScanIssue] {
    guard hardLinkAccountingIsComplete else {
      return []
    }

    var aggregationIssues: [ScanIssue] = []
    let groups = hardLinks.values.sorted { $0.representativePath < $1.representativePath }

    for group in groups {
      let linkCountIsInconsistent =
        group.observedCount > group.maximumReportedLinkCount
      let groupChangedDuringScan = group.changedDuringScan || linkCountIsInconsistent

      if groupChangedDuringScan {
        aggregationIssues.append(
          ScanIssue(
            path: group.representativePath,
            operation: .readMetadata,
            reason: .changedDuringScan,
            impact: .estimateDegraded,
            systemCode: EAGAIN
          )
        )
        incompleteTopLevelComponents.formUnion(group.countByTopLevelComponent.keys)
      }

      root.addDuplicateHardLinks(group.observedCount > 0 ? group.observedCount - 1 : 0)
      for (component, count) in group.countByTopLevelComponent {
        topLevel[component]?.addDuplicateHardLinks(count > 0 ? count - 1 : 0)
      }

      let linkAccountingIsCertain =
        !groupChangedDuringScan
        && group.maximumReportedLinkCount == group.observedCount
      let hasExternalLinks = group.maximumReportedLinkCount > group.observedCount

      if hasExternalLinks {
        root.addUnobservedHardLinkFile()
        for component in group.countByTopLevelComponent.keys {
          topLevel[component]?.addUnobservedHardLinkFile()
        }
      }

      if linkAccountingIsCertain {
        root.addExclusiveAllocatedContribution(group.metadata)
      } else {
        root.addNonExclusiveHardLinkFiles(group.observedCount)
      }

      let belongsToOneTopLevelItem = group.countByTopLevelComponent.count == 1
      for (component, count) in group.countByTopLevelComponent {
        if linkAccountingIsCertain, belongsToOneTopLevelItem {
          topLevel[component]?.addExclusiveAllocatedContribution(group.metadata)
        } else {
          topLevel[component]?.addNonExclusiveHardLinkFiles(count)
        }
      }
    }

    return aggregationIssues
  }

  mutating func discardDetailsForEntryLimit() {
    topLevel.removeAll(keepingCapacity: false)
    topLevelItemCount = 0
    topLevelItemsWereSuppressed = true
    hardLinks.removeAll(keepingCapacity: false)
    hardLinkAccountingIsComplete = false
    traversalDetailsWereDiscarded = true
  }

  func overflowIssues() -> [ScanIssue] {
    var result: [ScanIssue] = []
    if root.hasSizeOverflow {
      result.append(sizeOverflowIssue(at: .root))
    }

    result.append(
      contentsOf: topLevel.values
        .filter(\.hasSizeOverflow)
        .map { sizeOverflowIssue(at: $0.path) }
        .sorted()
    )
    return result
  }

  func report(issues: [ScanIssue], suppressedIssueCount: UInt64) -> ScanReport {
    let hasUnknownSuppressedIssues = suppressedIssueCount > 0
    let rootIsComplete = issues.isEmpty && !hasUnknownSuppressedIssues
    var incompleteTopLevelComponents = self.incompleteTopLevelComponents
    var allTopLevelItemsAreIncomplete =
      hasUnknownSuppressedIssues || !hardLinkAccountingIsComplete

    for issue in issues {
      if let component = issue.path.topLevelRawComponent {
        incompleteTopLevelComponents.insert(component)
      } else if issue.impact == .descendantsSkipped {
        allTopLevelItemsAreIncomplete = true
      }
    }

    let topLevelItems = topLevel.values
      .map { accumulator in
        accumulator.summary(
          isComplete: !allTopLevelItemsAreIncomplete
            && !incompleteTopLevelComponents.contains(accumulator.path.rawComponents[0])
        )
      }
      .sorted { $0.path < $1.path }

    return ScanReport(
      root: root.summary(isComplete: rootIsComplete),
      topLevelItems: topLevelItems,
      topLevelItemCount: topLevelItemCount,
      topLevelItemsWereSuppressed: topLevelItemsWereSuppressed,
      hardLinkAccountingIsComplete: hardLinkAccountingIsComplete,
      traversalDetailsWereDiscarded: traversalDetailsWereDiscarded,
      issues: issues,
      suppressedIssueCount: suppressedIssueCount
    )
  }

  private mutating func ensureTopLevel(_ component: [UInt8], kind: FileSystemEntryKind) {
    if topLevel[component] == nil {
      topLevel[component] = SummaryAccumulator(
        path: ScanRelativePath(rawComponents: [component]),
        kind: kind
      )
    }
  }
}

private struct HardLinkGroup {
  private(set) var representativePath: ScanRelativePath
  private(set) var metadata: FileMetadata
  private(set) var observedCount: UInt64 = 1
  private(set) var maximumReportedLinkCount: UInt64
  private(set) var countByTopLevelComponent: [[UInt8]: UInt64]
  private(set) var changedDuringScan = false

  init(path: ScanRelativePath, metadata: FileMetadata) {
    representativePath = path
    self.metadata = metadata
    maximumReportedLinkCount = metadata.hardLinkCount
    countByTopLevelComponent = path.topLevelRawComponent.map { [$0: 1] } ?? [:]
  }

  mutating func observe(path: ScanRelativePath, metadata: FileMetadata) {
    saturatingIncrement(&observedCount)
    maximumReportedLinkCount = max(maximumReportedLinkCount, metadata.hardLinkCount)
    if let component = path.topLevelRawComponent {
      var count = countByTopLevelComponent[component, default: 0]
      saturatingIncrement(&count)
      countByTopLevelComponent[component] = count
    }

    changedDuringScan = changedDuringScan || self.metadata != metadata

    if path < representativePath {
      representativePath = path
      self.metadata = metadata
    }
  }
}

private struct SummaryAccumulator {
  let path: ScanRelativePath
  var kind: FileSystemEntryKind
  private var logicalBytes: UInt64 = 0
  private var allocatedBytes: UInt64 = 0
  private var hardLinkExclusiveAllocatedBytes: UInt64 = 0
  private var regularFiles: UInt64 = 0
  private var directories: UInt64 = 0
  private var symbolicLinks: UInt64 = 0
  private var other: UInt64 = 0
  private var duplicateHardLinks: UInt64 = 0
  private var unknownAllocatedItemCount: UInt64 = 0
  private var possibleSharedContentFileCount: UInt64 = 0
  private var sharedContentMetadataUnavailableCount: UInt64 = 0
  private var unobservedHardLinkFileCount: UInt64 = 0
  private var nonExclusiveHardLinkFileCount: UInt64 = 0
  private var newestContentModificationUnixSeconds: Int64?
  private var encounteredInvalidModificationTime = false
  private(set) var hasSizeOverflow = false

  init(path: ScanRelativePath, kind: FileSystemEntryKind) {
    self.path = path
    self.kind = kind
  }

  mutating func observePath(kind: FileSystemEntryKind) {
    switch kind {
    case .regularFile:
      saturatingIncrement(&regularFiles)
    case .directory:
      saturatingIncrement(&directories)
    case .symbolicLink:
      saturatingIncrement(&symbolicLinks)
    case .other:
      saturatingIncrement(&other)
    }
  }

  mutating func observeModificationTime(_ unixSeconds: Int64) {
    guard unixSeconds >= 0 else {
      encounteredInvalidModificationTime = true
      return
    }
    newestContentModificationUnixSeconds = max(
      newestContentModificationUnixSeconds ?? unixSeconds,
      unixSeconds
    )
  }

  mutating func addApparentContribution(_ metadata: FileMetadata) {
    hasSizeOverflow =
      saturatingAdd(metadata.size.logicalBytes, to: &logicalBytes) || hasSizeOverflow
    hasSizeOverflow =
      saturatingAdd(metadata.size.allocatedBytes, to: &allocatedBytes) || hasSizeOverflow

    if !metadata.allocatedSizeIsKnown {
      saturatingIncrement(&unknownAllocatedItemCount)
    }
    if metadata.kind == .regularFile {
      switch metadata.mayShareFileContent {
      case .some(true):
        saturatingIncrement(&possibleSharedContentFileCount)
      case .none:
        saturatingIncrement(&sharedContentMetadataUnavailableCount)
      case .some(false):
        break
      }
    }
  }

  mutating func addExclusiveAllocatedContribution(_ metadata: FileMetadata) {
    guard metadata.allocatedSizeIsKnown else {
      return
    }
    hasSizeOverflow =
      saturatingAdd(metadata.size.allocatedBytes, to: &hardLinkExclusiveAllocatedBytes)
      || hasSizeOverflow
  }

  mutating func addDuplicateHardLinks(_ count: UInt64) {
    _ = saturatingAdd(count, to: &duplicateHardLinks)
  }

  mutating func addUnobservedHardLinkFile() {
    saturatingIncrement(&unobservedHardLinkFileCount)
  }

  mutating func addNonExclusiveHardLinkFiles(_ count: UInt64) {
    _ = saturatingAdd(count, to: &nonExclusiveHardLinkFileCount)
  }

  func summary(isComplete: Bool) -> ScanItemSummary {
    ScanItemSummary(
      path: path,
      kind: kind,
      recursiveSize: StorageSize(
        logicalBytes: logicalBytes,
        allocatedBytes: allocatedBytes
      ),
      hardLinkExclusiveAllocatedBytes: hardLinkExclusiveAllocatedBytes,
      counts: ScanEntryCounts(
        regularFiles: regularFiles,
        directories: directories,
        symbolicLinks: symbolicLinks,
        other: other,
        duplicateHardLinks: duplicateHardLinks
      ),
      unknownAllocatedItemCount: unknownAllocatedItemCount,
      possibleSharedContentFileCount: possibleSharedContentFileCount,
      sharedContentMetadataUnavailableCount: sharedContentMetadataUnavailableCount,
      unobservedHardLinkFileCount: unobservedHardLinkFileCount,
      nonExclusiveHardLinkFileCount: nonExclusiveHardLinkFileCount,
      newestContentModificationUnixSeconds: encounteredInvalidModificationTime
        ? -1 : newestContentModificationUnixSeconds,
      sizeOverflowed: hasSizeOverflow,
      isComplete: isComplete
    )
  }
}

private struct ScanIssueCollector {
  private let limit: Int
  private var maximumHeap: [ScanIssue] = []
  private var suppressedCount: UInt64 = 0

  init(limit: UInt32) {
    self.limit = Int(limit)
  }

  mutating func append(_ issue: ScanIssue) {
    guard limit > 0 else {
      saturatingIncrement(&suppressedCount)
      return
    }

    if maximumHeap.count < limit {
      maximumHeap.append(issue)
      siftUp(from: maximumHeap.count - 1)
      return
    }

    saturatingIncrement(&suppressedCount)
    guard let largest = maximumHeap.first, issue < largest else {
      return
    }

    maximumHeap[0] = issue
    siftDown(from: 0)
  }

  func snapshot() -> (issues: [ScanIssue], suppressedCount: UInt64) {
    (maximumHeap.sorted(), suppressedCount)
  }

  private mutating func siftUp(from startIndex: Int) {
    var child = startIndex
    while child > 0 {
      let parent = (child - 1) / 2
      guard maximumHeap[parent] < maximumHeap[child] else {
        return
      }
      maximumHeap.swapAt(parent, child)
      child = parent
    }
  }

  private mutating func siftDown(from startIndex: Int) {
    var parent = startIndex

    while true {
      let left = parent * 2 + 1
      guard left < maximumHeap.count else {
        return
      }

      let right = left + 1
      var largestChild = left
      if right < maximumHeap.count, maximumHeap[left] < maximumHeap[right] {
        largestChild = right
      }

      guard maximumHeap[parent] < maximumHeap[largestChild] else {
        return
      }
      maximumHeap.swapAt(parent, largestChild)
      parent = largestChild
    }
  }
}

private func validateLocalRootURL(_ url: URL) throws {
  let hostIsLocal: Bool
  if let host = url.host, !host.isEmpty {
    hostIsLocal = host.caseInsensitiveCompare("localhost") == .orderedSame
  } else {
    hostIsLocal = true
  }

  guard
    url.isFileURL,
    hostIsLocal,
    url.user == nil,
    url.password == nil,
    url.port == nil,
    url.query == nil,
    url.fragment == nil,
    url.pathComponents.first == "/"
  else {
    throw ScanError.rootMustBeAbsoluteFileURL
  }
}

private func openRootDirectory(at url: URL) throws -> Int32 {
  var failureCode: Int32 = EINVAL
  let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
    guard let path else {
      return -1
    }

    let result = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    if result < 0 {
      failureCode = errno
    }
    return result
  }

  guard descriptor >= 0 else {
    throw FileMetadataError(code: failureCode)
  }
  return descriptor
}

private func openChildDirectory(
  at parentDescriptor: Int32,
  name: FileSystemName
) throws -> Int32 {
  var failureCode: Int32 = EINVAL
  let descriptor = name.withCString { namePointer -> Int32 in
    let result = Darwin.openat(
      parentDescriptor,
      namePointer,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    if result < 0 {
      failureCode = errno
    }
    return result
  }

  guard descriptor >= 0 else {
    throw FileMetadataError(code: failureCode)
  }
  return descriptor
}

private func fileSystemName(from entry: UnsafeMutablePointer<dirent>) -> FileSystemName {
  let length = Int(entry.pointee.d_namlen)
  let bytes = withUnsafeBytes(of: &entry.pointee.d_name) { rawBuffer in
    Array(rawBuffer.prefix(length))
  }
  return FileSystemName(bytes: bytes)
}

private func closeIgnoringErrors(_ descriptor: Int32) {
  _ = Darwin.close(descriptor)
}

private func crossVolumeIssue(at path: ScanRelativePath) -> ScanIssue {
  ScanIssue(
    path: path,
    operation: .listDirectory,
    reason: .crossedVolumeBoundary,
    impact: .descendantsSkipped
  )
}

private func changedDirectoryIssue(at path: ScanRelativePath) -> ScanIssue {
  ScanIssue(
    path: path,
    operation: .listDirectory,
    reason: .changedDuringScan,
    impact: .descendantsSkipped,
    systemCode: EAGAIN
  )
}

private func sizeOverflowIssue(at path: ScanRelativePath) -> ScanIssue {
  ScanIssue(
    path: path,
    operation: .measureSize,
    reason: .sizeOverflow,
    impact: .estimateDegraded,
    systemCode: EOVERFLOW
  )
}

private func rootError(for error: Error) -> ScanError {
  let systemCode = posixCode(for: error)
  if systemCode == ENOENT || systemCode == ENOTDIR {
    return .rootNotFound
  }
  return .rootUnavailable(operation: .validateRoot, systemCode: systemCode)
}

private func issue(
  for error: Error,
  path: ScanRelativePath,
  operation: ScanOperation,
  impact: ScanIssueImpact
) -> ScanIssue {
  let systemCode = posixCode(for: error)
  let reason: ScanIssueReason

  switch systemCode {
  case EACCES, EPERM:
    reason = .permissionDenied
  case ENOENT, ENOTDIR:
    reason = .disappeared
  case EAGAIN, ELOOP:
    reason = .changedDuringScan
  case EMFILE, ENFILE:
    reason = .resourceLimit
  case EINVAL, EOVERFLOW:
    reason = .invalidMetadata
  default:
    reason = .ioFailure
  }

  return ScanIssue(
    path: path,
    operation: operation,
    reason: reason,
    impact: impact,
    systemCode: systemCode
  )
}

private func posixCode(for error: Error, remainingDepth: Int = 8) -> Int32? {
  let nsError = error as NSError
  if nsError.domain == NSPOSIXErrorDomain, let code = Int32(exactly: nsError.code) {
    return code
  }

  guard
    remainingDepth > 0,
    let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error
  else {
    return nil
  }
  return posixCode(for: underlyingError, remainingDepth: remainingDepth - 1)
}

private func saturatingIncrement(_ value: inout UInt64) {
  _ = saturatingAdd(1, to: &value)
}

@discardableResult
private func saturatingAdd(_ amount: UInt64, to value: inout UInt64) -> Bool {
  let (sum, overflow) = value.addingReportingOverflow(amount)
  value = overflow ? UInt64.max : sum
  return overflow
}

extension ScanIssue: Comparable {
  public static func < (left: ScanIssue, right: ScanIssue) -> Bool {
    if left.path != right.path {
      return left.path < right.path
    }
    if left.operation != right.operation {
      return left.operation.rawValue < right.operation.rawValue
    }
    if left.reason != right.reason {
      return left.reason.rawValue < right.reason.rawValue
    }
    if left.impact != right.impact {
      return left.impact.rawValue < right.impact.rawValue
    }

    switch (left.systemCode, right.systemCode) {
    case (nil, nil):
      return false
    case (nil, .some):
      return true
    case (.some, nil):
      return false
    case (.some(let leftCode), .some(let rightCode)):
      return leftCode < rightCode
    }
  }
}
