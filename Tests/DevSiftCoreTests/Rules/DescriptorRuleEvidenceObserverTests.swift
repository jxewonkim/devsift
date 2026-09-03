import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor-bound rule evidence observer")
struct DescriptorRuleEvidenceObserverTests {
  @Test("Every retained top-level inode is rebound without following symbolic links")
  func observesAllTopLevelIdentities() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    _ = try fixture.makeDirectory(".build")
    _ = try fixture.write(".build/workspace-state.json", bytes: [1])
    _ = try fixture.makeDirectory("ordinary-directory")
    let outside = try fixture.write("payload.bin", bytes: [2], under: fixture.outside)
    _ = try fixture.write("ordinary-file", bytes: [3])
    _ = try fixture.makeSymbolicLink("outside-link", destination: outside)

    let scan = try await AllocatedSizeScanner().scan(root: fixture.root)
    let observation = try await DescriptorRuleEvidenceObserver().observe(
      request(root: fixture.root, report: scan)
    )
    let evidence = try evidenceByPath(report: scan, observation: observation)

    #expect(observation.candidates.count == scan.topLevelItems.count)
    #expect(evidence.values.allSatisfy { $0.identityMatchesScan == .known(true) })
    #expect(
      evidence[ScanRelativePath(rawComponents: [Array(".build".utf8)])]?
        .generatedContentMarker == .known(true)
    )
    for name in ["ordinary-directory", "ordinary-file", "outside-link"] {
      #expect(
        evidence[ScanRelativePath(rawComponents: [Array(name.utf8)])]?
          .generatedContentMarker == .unknown(.notCollected)
      )
    }
    #expect(try Data(contentsOf: outside) == Data([2]))
  }

  @Test("SwiftPM marker absence and wrong kinds fail without following targets")
  func markerBoundary() async throws {
    for markerKind in MarkerFixtureKind.allCases {
      let fixture = try ScannerFixture()
      defer { fixture.remove() }

      _ = try fixture.makeDirectory(".build")
      let outside = try fixture.write("sentinel", bytes: [9], under: fixture.outside)
      switch markerKind {
      case .absent:
        break
      case .directory:
        _ = try fixture.makeDirectory(".build/workspace-state.json")
      case .symbolicLink:
        _ = try fixture.makeSymbolicLink(
          ".build/workspace-state.json",
          destination: outside
        )
      }

      let scan = try await AllocatedSizeScanner().scan(root: fixture.root)
      let observation = try await DescriptorRuleEvidenceObserver().observe(
        request(root: fixture.root, report: scan)
      )
      let marker = try #require(observation.candidates.first?.generatedContentMarker)

      #expect(marker == .known(false), "Unexpected marker result for \(markerKind)")
      #expect(observation.candidates.first?.identityMatchesScan == .known(true))
      #expect(try Data(contentsOf: outside) == Data([9]))
    }
  }

  @Test("A candidate replacement between lookup and open invalidates both facts")
  func candidateReplacementBeforeOpen() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    _ = try fixture.makeDirectory(".build")
    _ = try fixture.write(".build/workspace-state.json", bytes: [1])
    let replacement = try fixture.makeDirectory("replacement", under: fixture.container)
    _ = try fixture.write(
      "workspace-state.json",
      bytes: [2],
      under: replacement
    )
    let scan = try await AllocatedSizeScanner().scan(root: fixture.root)

    let observer = DescriptorRuleEvidenceObserver(beforeOpeningCandidate: { path in
      guard path.rawComponents == [Array(".build".utf8)] else { return }
      try FileManager.default.moveItem(
        at: fixture.root.appendingPathComponent(".build"),
        to: fixture.container.appendingPathComponent("original-build")
      )
      try FileManager.default.moveItem(
        at: replacement,
        to: fixture.root.appendingPathComponent(".build")
      )
    })
    let observation = try await observer.observe(request(root: fixture.root, report: scan))
    let evidence = try #require(observation.candidates.first)

    #expect(evidence.identityMatchesScan == .unknown(.changedDuringObservation))
    #expect(evidence.generatedContentMarker == .unknown(.changedDuringObservation))
  }

  @Test("A candidate name rebound after observation invalidates both facts")
  func finalCandidateBinding() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    _ = try fixture.makeDirectory(".build")
    _ = try fixture.write(".build/workspace-state.json", bytes: [1])
    let replacement = try fixture.makeDirectory("replacement", under: fixture.container)
    _ = try fixture.write(
      "workspace-state.json",
      bytes: [2],
      under: replacement
    )
    let scan = try await AllocatedSizeScanner().scan(root: fixture.root)

    let observer = DescriptorRuleEvidenceObserver(beforeFinalCandidateValidation: { path in
      guard path.rawComponents == [Array(".build".utf8)] else { return }
      try FileManager.default.moveItem(
        at: fixture.root.appendingPathComponent(".build"),
        to: fixture.container.appendingPathComponent("original-build")
      )
      try FileManager.default.moveItem(
        at: replacement,
        to: fixture.root.appendingPathComponent(".build")
      )
    })
    let observation = try await observer.observe(request(root: fixture.root, report: scan))
    let evidence = try #require(observation.candidates.first)

    #expect(evidence.identityMatchesScan == .unknown(.changedDuringObservation))
    #expect(evidence.generatedContentMarker == .unknown(.changedDuringObservation))
  }

  @Test("A selected root rebound invalidates all facts collected through the held descriptor")
  func finalRootBinding() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    _ = try fixture.makeDirectory(".build")
    _ = try fixture.write(".build/workspace-state.json", bytes: [1])
    let replacementRoot = try fixture.makeDirectory("replacement-root", under: fixture.container)
    let scan = try await AllocatedSizeScanner().scan(root: fixture.root)

    let observer = DescriptorRuleEvidenceObserver(afterRootValidation: {
      try FileManager.default.moveItem(
        at: fixture.root,
        to: fixture.container.appendingPathComponent("original-root")
      )
      try FileManager.default.moveItem(at: replacementRoot, to: fixture.root)
    })
    let observation = try await observer.observe(request(root: fixture.root, report: scan))
    let evidence = try #require(observation.candidates.first)

    #expect(evidence.identityMatchesScan == .unknown(.changedDuringObservation))
    #expect(evidence.generatedContentMarker == .unknown(.changedDuringObservation))
  }

  @Test("Marker read errors remain unknown while a stable candidate identity is known")
  func markerErrorMapping() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    _ = try fixture.makeDirectory(".build")
    _ = try fixture.write(".build/workspace-state.json", bytes: [1])
    let scan = try await AllocatedSizeScanner().scan(root: fixture.root)
    let observer = DescriptorRuleEvidenceObserver(beforeMarkerObservation: { _ in
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    })

    let observation = try await observer.observe(request(root: fixture.root, report: scan))
    let evidence = try #require(observation.candidates.first)

    #expect(evidence.identityMatchesScan == .known(true))
    #expect(evidence.generatedContentMarker == .unknown(.permissionDenied))
  }

  @Test("Resource errors and cancellation fail closed")
  func resourceAndCancellation() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    _ = try fixture.makeDirectory(".build")
    let scan = try await AllocatedSizeScanner().scan(root: fixture.root)
    let resourceObserver = DescriptorRuleEvidenceObserver(beforeOpeningCandidate: { _ in
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EMFILE))
    })
    let resource = try await resourceObserver.observe(request(root: fixture.root, report: scan))

    #expect(resource.candidates.first?.identityMatchesScan == .unknown(.resourceLimit))
    #expect(resource.candidates.first?.generatedContentMarker == .unknown(.resourceLimit))

    let cancelledObserver = DescriptorRuleEvidenceObserver(checkpoint: {
      throw CancellationError()
    })
    await expectCancellation {
      _ = try await cancelledObserver.observe(request(root: fixture.root, report: scan))
    }
  }

  @Test("Legacy, incomplete, duplicate, and malformed reports perform no path I/O")
  func invalidInputBoundaries() async throws {
    let missingRoot = URL(fileURLWithPath: "/devsift-observer-does-not-exist")
    let build = ruleSummary(rawComponents: [Array(".build".utf8)])
    let legacy = try await DescriptorRuleEvidenceObserver().observe(
      request(root: missingRoot, report: completeScanReport(topLevelItems: [build]))
    )
    #expect(legacy.candidates.first?.identityMatchesScan == .unknown(.notCollected))

    let rootIdentity = FileIdentity(device: 10, inode: 20)
    let buildIdentity = FileIdentity(device: 10, inode: 21)
    let incompleteBuild = ruleSummary(
      rawComponents: [Array(".build".utf8)],
      scanTimeIdentity: buildIdentity,
      isComplete: false
    )
    let incompleteReport = ScanReport(
      root: ruleSummary(
        rawComponents: [],
        scanTimeIdentity: rootIdentity,
        isComplete: false
      ),
      topLevelItems: [incompleteBuild],
      topLevelItemCount: 1,
      topLevelItemsWereSuppressed: false,
      hardLinkAccountingIsComplete: true,
      traversalDetailsWereDiscarded: false,
      issues: [],
      suppressedIssueCount: 0
    )
    let incomplete = try await DescriptorRuleEvidenceObserver().observe(
      request(root: missingRoot, report: incompleteReport)
    )
    #expect(incomplete.candidates.first?.identityMatchesScan == .unknown(.incompleteScan))

    let identifiedBuild = ruleSummary(
      rawComponents: [Array(".build".utf8)],
      scanTimeIdentity: buildIdentity
    )
    let duplicateReport = identifiedReport(
      rootIdentity: rootIdentity,
      items: [identifiedBuild, identifiedBuild]
    )
    let duplicate = try await DescriptorRuleEvidenceObserver().observe(
      request(root: missingRoot, report: duplicateReport)
    )
    #expect(
      duplicate.candidates.allSatisfy {
        $0.identityMatchesScan == .unknown(.invalidMetadata)
          && $0.generatedContentMarker == .unknown(.invalidMetadata)
      }
    )

    let malformed = ruleSummary(
      rawComponents: [[0x2E, 0x2E]],
      scanTimeIdentity: buildIdentity
    )
    let malformedObservation = try await DescriptorRuleEvidenceObserver().observe(
      request(
        root: missingRoot,
        report: identifiedReport(rootIdentity: rootIdentity, items: [malformed])
      )
    )
    #expect(
      malformedObservation.candidates.first?.identityMatchesScan
        == .unknown(.invalidMetadata)
    )

    let nulRoot = URL(fileURLWithPath: "/devsift-prefix\0ignored")
    let nulRootObservation = try await DescriptorRuleEvidenceObserver().observe(
      request(
        root: nulRoot,
        report: identifiedReport(rootIdentity: rootIdentity, items: [identifiedBuild])
      )
    )
    #expect(
      nulRootObservation.candidates.first?.identityMatchesScan
        == .unknown(.invalidMetadata)
    )

    let baseRelativeRoot = URL(
      fileURLWithPath: "relative-root",
      relativeTo: URL(fileURLWithPath: "/devsift-observer-base", isDirectory: true)
    )
    #expect(baseRelativeRoot.baseURL != nil)
    let baseRelativeRootObservation = try await DescriptorRuleEvidenceObserver().observe(
      request(
        root: baseRelativeRoot,
        report: identifiedReport(rootIdentity: rootIdentity, items: [identifiedBuild])
      )
    )
    #expect(
      baseRelativeRootObservation.candidates.first?.identityMatchesScan
        == .unknown(.invalidMetadata)
    )
  }

  @Test("Raw syscall components reject traversal and C-string truncation inputs")
  func rawComponentValidation() {
    let invalid: [[UInt8]] = [
      [],
      [0],
      [0x2F],
      [0x2E],
      [0x2E, 0x2E],
      Array(".build/child".utf8),
      Array(".build".utf8) + [0] + Array("ignored".utf8),
      Array(repeating: 0x61, count: Int(NAME_MAX) + 1),
    ]

    for bytes in invalid {
      #expect(DescriptorPathComponent(bytes) == nil)
    }
    #expect(DescriptorPathComponent(Array(".build".utf8)) != nil)
    #expect(DescriptorPathComponent([0xFF]) != nil)
  }
}

private enum MarkerFixtureKind: CaseIterable {
  case absent
  case directory
  case symbolicLink
}

private func request(root: URL, report: ScanReport) -> RuleClassificationRequest {
  RuleClassificationRequest(root: root, report: report, referenceUnixSeconds: 1_000_000)
}

private func identifiedReport(
  rootIdentity: FileIdentity,
  items: [ScanItemSummary]
) -> ScanReport {
  ScanReport(
    root: ruleSummary(rawComponents: [], scanTimeIdentity: rootIdentity),
    topLevelItems: items,
    topLevelItemCount: UInt64(items.count),
    topLevelItemsWereSuppressed: false,
    hardLinkAccountingIsComplete: true,
    traversalDetailsWereDiscarded: false,
    issues: [],
    suppressedIssueCount: 0
  )
}

private func evidenceByPath(
  report: ScanReport,
  observation: RuleEvidenceObservation
) throws -> [ScanRelativePath: CandidateRuleEvidence] {
  #expect(report.topLevelItems.count == observation.candidates.count)
  return Dictionary(
    uniqueKeysWithValues: zip(report.topLevelItems, observation.candidates).map {
      ($0.path, $1)
    }
  )
}
