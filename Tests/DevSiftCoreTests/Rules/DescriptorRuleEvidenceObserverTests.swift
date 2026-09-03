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
      case .caseVariantRegularFile:
        _ = try fixture.write(".build/WORKSPACE-STATE.JSON", bytes: [1])
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

  @Test("npm marker requires an exact raw direct-child directory pair")
  func npmMarkerBoundary() async throws {
    for markerKind in NPMMarkerFixtureKind.allCases {
      let fixture = try ScannerFixture()
      defer { fixture.remove() }

      let home = try resolvedFixtureURL(
        fixture.makeDirectory("synthetic-home", under: fixture.container)
      )
      let npmRoot = try fixture.makeDirectory(".npm", under: home)
      let cache = try fixture.makeDirectory("_cacache", under: npmRoot)
      let outsideSentinel = try fixture.write("sentinel", bytes: [0xA5], under: fixture.outside)

      switch markerKind {
      case .exactPair:
        _ = try makeNPMMarkerPair(in: cache, fixture: fixture)
      case .missingContent:
        _ = try fixture.makeDirectory("index-v5", under: cache)
      case .missingIndex:
        _ = try fixture.makeDirectory("content-v2", under: cache)
      case .wrongKind:
        _ = try fixture.write("content-v2", bytes: [1], under: cache)
        _ = try fixture.makeDirectory("index-v5", under: cache)
      case .wrongIndexKind:
        _ = try fixture.makeDirectory("content-v2", under: cache)
        _ = try fixture.write("index-v5", bytes: [1], under: cache)
      case .symbolicLink:
        _ = try fixture.makeSymbolicLink(
          "content-v2",
          destination: fixture.outside,
          under: cache
        )
        _ = try fixture.makeDirectory("index-v5", under: cache)
      case .indexSymbolicLink:
        _ = try fixture.makeDirectory("content-v2", under: cache)
        _ = try fixture.makeSymbolicLink(
          "index-v5",
          destination: fixture.outside,
          under: cache
        )
      case .caseVariants:
        _ = try fixture.makeDirectory("CONTENT-V2", under: cache)
        _ = try fixture.makeDirectory("INDEX-V5", under: cache)
      case .nestedPair:
        _ = try fixture.makeDirectory("nested/content-v2", under: cache)
        _ = try fixture.makeDirectory("nested/index-v5", under: cache)
      }

      let scan = try await AllocatedSizeScanner().scan(root: npmRoot)
      let rootBefore = try treeSnapshot(at: npmRoot)
      let outsideBefore = try treeSnapshot(at: fixture.outside)
      let observation = try await DescriptorRuleEvidenceObserver(
        rawHomeProvider: { .known(rawPathBytes(home)) }
      ).observe(request(root: npmRoot, report: scan))
      let evidence = try #require(observation.candidates.first)

      #expect(
        evidence.generatedContentMarker == .known(markerKind == .exactPair),
        "Unexpected npm marker result for \(markerKind)"
      )
      #expect(evidence.identityMatchesScan == .known(true))
      #expect(evidence.trustedLocation == .known(true))
      #expect(try Data(contentsOf: outsideSentinel) == Data([0xA5]))
      #expect(try treeSnapshot(at: npmRoot) == rootBefore)
      #expect(try treeSnapshot(at: fixture.outside) == outsideBefore)
    }
  }

  @Test("Generated-marker policies remain isolated by exact candidate name")
  func generatedMarkerPolicyIsolation() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let home = try resolvedFixtureURL(
      fixture.makeDirectory("synthetic-home", under: fixture.container)
    )
    for candidateName in ["_cacache", "uv", "Homebrew", ".build", "ordinary"] {
      let candidate = try fixture.makeDirectory(candidateName)
      _ = try makeNPMMarkerPair(in: candidate, fixture: fixture)
    }

    let scan = try await AllocatedSizeScanner().scan(root: fixture.root)
    let observation = try await DescriptorRuleEvidenceObserver(
      rawHomeProvider: { .known(rawPathBytes(home)) }
    ).observe(request(root: fixture.root, report: scan))
    let evidence = try evidenceByPath(report: scan, observation: observation)

    #expect(evidence[path("_cacache")]?.generatedContentMarker == .known(true))
    #expect(evidence[path("_cacache")]?.trustedLocation == .known(false))
    #expect(evidence[path(".build")]?.generatedContentMarker == .known(false))
    for candidateName in ["uv", "Homebrew", "ordinary"] {
      #expect(
        evidence[path(candidateName)]?.generatedContentMarker == .unknown(.notCollected)
      )
    }
  }

  @Test("Generated-marker enumeration enforces its exact entry bound")
  func generatedMarkerEntryBound() async throws {
    for extraEntryCount in [254, 255] {
      let fixture = try ScannerFixture()
      defer { fixture.remove() }

      let home = try resolvedFixtureURL(
        fixture.makeDirectory("synthetic-home", under: fixture.container)
      )
      let npmRoot = try fixture.makeDirectory(".npm", under: home)
      let cache = try fixture.makeDirectory("_cacache", under: npmRoot)
      _ = try makeNPMMarkerPair(in: cache, fixture: fixture)
      for index in 0..<extraEntryCount {
        _ = try fixture.makeDirectory(
          String(format: "noise-%03d", index),
          under: cache
        )
      }

      let scan = try await AllocatedSizeScanner().scan(root: npmRoot)
      let observation = try await DescriptorRuleEvidenceObserver(
        rawHomeProvider: { .known(rawPathBytes(home)) }
      ).observe(request(root: npmRoot, report: scan))
      let marker = try #require(observation.candidates.first?.generatedContentMarker)
      let expected: RuleObserved<Bool> =
        extraEntryCount == 254 ? .known(true) : .unknown(.resourceLimit)

      #expect(marker == expected)
    }
  }

  @Test("A stable false marker requirement outranks sibling metadata uncertainty")
  func generatedMarkerFalsePrecedence() {
    let metadataError = RuleObserved<Bool>.unknown(.permissionDenied)
    let wrongKind = RuleObserved<Bool>.known(false)

    #expect(
      combineGeneratedMarkerRequirements([metadataError, wrongKind]) == .known(false)
    )
    #expect(
      combineGeneratedMarkerRequirements([wrongKind, metadataError]) == .known(false)
    )
    #expect(
      combineGeneratedMarkerRequirements([.known(true), metadataError]) == metadataError
    )
  }

  @Test("An npm marker swap before metadata validation cannot preserve true evidence")
  func npmMarkerMetadataRace() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let home = try resolvedFixtureURL(
      fixture.makeDirectory("synthetic-home", under: fixture.container)
    )
    let npmRoot = try fixture.makeDirectory(".npm", under: home)
    let cache = try fixture.makeDirectory("_cacache", under: npmRoot)
    let markerPair = try makeNPMMarkerPair(in: cache, fixture: fixture)
    let outsideSentinel = try fixture.write("sentinel", bytes: [0x5A], under: fixture.outside)
    let outsideBefore = try treeSnapshot(at: fixture.outside)
    let scan = try await AllocatedSizeScanner().scan(root: npmRoot)

    let observer = DescriptorRuleEvidenceObserver(
      rawHomeProvider: { .known(rawPathBytes(home)) },
      beforeMarkerMetadataValidation: { path in
        guard path.rawComponents == [Array("_cacache".utf8)] else { return }
        try FileManager.default.moveItem(
          at: markerPair.content,
          to: cache.appendingPathComponent("original-content-v2")
        )
        try FileManager.default.createSymbolicLink(
          at: markerPair.content,
          withDestinationURL: fixture.outside
        )
      }
    )
    let observation = try await observer.observe(request(root: npmRoot, report: scan))
    let evidence = try #require(observation.candidates.first)

    #expect(evidence.identityMatchesScan == .unknown(.changedDuringObservation))
    #expect(evidence.trustedLocation == .unknown(.changedDuringObservation))
    #expect(evidence.generatedContentMarker == .unknown(.changedDuringObservation))
    #expect(try Data(contentsOf: outsideSentinel) == Data([0x5A]))
    #expect(try treeSnapshot(at: fixture.outside) == outsideBefore)
  }

  @Test("npm marker observation maps errors without discarding stable identity or location")
  func npmMarkerErrorIsolation() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let home = try resolvedFixtureURL(
      fixture.makeDirectory("synthetic-home", under: fixture.container)
    )
    let npmRoot = try fixture.makeDirectory(".npm", under: home)
    let cache = try fixture.makeDirectory("_cacache", under: npmRoot)
    _ = try makeNPMMarkerPair(in: cache, fixture: fixture)
    let scan = try await AllocatedSizeScanner().scan(root: npmRoot)
    let observer = DescriptorRuleEvidenceObserver(
      rawHomeProvider: { .known(rawPathBytes(home)) },
      beforeMarkerObservation: { path in
        guard path.rawComponents == [Array("_cacache".utf8)] else { return }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
      }
    )

    let observation = try await observer.observe(request(root: npmRoot, report: scan))
    let evidence = try #require(observation.candidates.first)

    #expect(evidence.identityMatchesScan == .known(true))
    #expect(evidence.trustedLocation == .known(true))
    #expect(evidence.generatedContentMarker == .unknown(.permissionDenied))
  }

  @Test("Cancellation during bounded marker enumeration aborts the whole observation")
  func generatedMarkerEnumerationCancellation() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let home = try resolvedFixtureURL(
      fixture.makeDirectory("synthetic-home", under: fixture.container)
    )
    let npmRoot = try fixture.makeDirectory(".npm", under: home)
    let cache = try fixture.makeDirectory("_cacache", under: npmRoot)
    _ = try makeNPMMarkerPair(in: cache, fixture: fixture)
    for index in 0..<32 {
      _ = try fixture.makeDirectory("noise-\(index)", under: cache)
    }
    let scan = try await AllocatedSizeScanner().scan(root: npmRoot)
    let gate = MarkerCancellationGate(cancelAfterArmedCheckpoints: 8)
    let observer = DescriptorRuleEvidenceObserver(
      checkpoint: { try gate.checkpoint() },
      rawHomeProvider: { .known(rawPathBytes(home)) },
      beforeMarkerObservation: { path in
        guard path.rawComponents == [Array("_cacache".utf8)] else { return }
        gate.arm()
      }
    )

    await expectCancellation {
      _ = try await observer.observe(request(root: npmRoot, report: scan))
    }
    #expect(gate.armedCheckpointCount == 8)
  }

  @Test("Trusted cache locations require an exact home-relative root and candidate pair")
  func trustedCacheLocationMatrix() async throws {
    for trustedRoot in TrustedCacheFixtureRoot.allCases {
      let fixture = try ScannerFixture()
      defer { fixture.remove() }

      let home = try resolvedFixtureURL(
        fixture.makeDirectory("synthetic-home", under: fixture.container)
      )
      let root = try fixture.makeDirectory(trustedRoot.relativePath, under: home)
      for candidate in TrustedCacheFixtureRoot.allCases {
        _ = try fixture.makeDirectory(candidate.candidateName, under: root)
      }

      let scan = try await AllocatedSizeScanner().scan(root: root)
      let observation = try await DescriptorRuleEvidenceObserver(
        rawHomeProvider: { .known(rawPathBytes(home)) }
      ).observe(request(root: root, report: scan))
      let evidence = try evidenceByPath(report: scan, observation: observation)

      for candidate in TrustedCacheFixtureRoot.allCases {
        let path = ScanRelativePath(rawComponents: [Array(candidate.candidateName.utf8)])
        #expect(
          evidence[path]?.trustedLocation
            == .known(candidate == trustedRoot),
          "Unexpected trust for \(candidate.candidateName) under \(trustedRoot.relativePath)"
        )
      }
    }
  }

  @Test("Trusted cache names elsewhere fail while lexical near misses stay uncollected")
  func trustedCacheNearMisses() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let home = try resolvedFixtureURL(
      fixture.makeDirectory("synthetic-home", under: fixture.container)
    )
    let elsewhere = try resolvedFixtureURL(
      fixture.makeDirectory("elsewhere", under: fixture.container)
    )
    let exactNames = TrustedCacheFixtureRoot.allCases.map(\.candidateName)
    let nearNames = ["UV", "uv-cache", "_cacache-copy", "homebrew", "Homebrew "]
    for name in exactNames {
      _ = try fixture.makeDirectory(name, under: elsewhere)
    }

    let scan = try await AllocatedSizeScanner().scan(root: elsewhere)
    let observation = try await DescriptorRuleEvidenceObserver(
      rawHomeProvider: { .known(rawPathBytes(home)) }
    ).observe(request(root: elsewhere, report: scan))
    let evidence = try evidenceByPath(report: scan, observation: observation)

    for name in exactNames {
      let path = ScanRelativePath(rawComponents: [Array(name.utf8)])
      #expect(evidence[path]?.trustedLocation == .known(false))
    }

    for name in nearNames {
      let nearFixture = try ScannerFixture()
      defer { nearFixture.remove() }
      let nearHome = try resolvedFixtureURL(
        nearFixture.makeDirectory("synthetic-home", under: nearFixture.container)
      )
      let nearRoot = try resolvedFixtureURL(
        nearFixture.makeDirectory("elsewhere", under: nearFixture.container)
      )
      _ = try nearFixture.makeDirectory(name, under: nearRoot)
      let nearScan = try await AllocatedSizeScanner().scan(root: nearRoot)
      let nearObservation = try await DescriptorRuleEvidenceObserver(
        rawHomeProvider: { .known(rawPathBytes(nearHome)) }
      ).observe(request(root: nearRoot, report: nearScan))
      let nearEvidence = try #require(nearObservation.candidates.first)
      #expect(nearEvidence.trustedLocation == .unknown(.notCollected))
    }
  }

  @Test("Xcode and SwiftPM candidates do not gain location evidence in this increment")
  func unsupportedTrustedLocations() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let home = try resolvedFixtureURL(
      fixture.makeDirectory("synthetic-home", under: fixture.container)
    )
    let xcode = try fixture.makeDirectory("Library/Developer/Xcode", under: home)
    _ = try fixture.makeDirectory("DerivedData", under: xcode)
    _ = try fixture.makeDirectory(".build", under: xcode)
    let deviceSupport = try fixture.makeDirectory("iOS DeviceSupport", under: xcode)
    _ = try fixture.makeDirectory("17.4 (21E217)", under: deviceSupport)

    for root in [xcode, deviceSupport] {
      let scan = try await AllocatedSizeScanner().scan(root: root)
      let observation = try await DescriptorRuleEvidenceObserver(
        rawHomeProvider: { .known(rawPathBytes(home)) }
      ).observe(request(root: root, report: scan))

      #expect(
        observation.candidates.allSatisfy {
          $0.trustedLocation == .unknown(.notCollected)
        }
      )
    }
  }

  @Test("An intermediate home symlink cannot manufacture trusted location evidence")
  func trustedLocationDoesNotFollowIntermediateHomeSymlink() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let outsideHome = try resolvedFixtureURL(
      fixture.makeDirectory("redirected-home", under: fixture.outside)
    )
    let npmRoot = try fixture.makeDirectory(".npm", under: outsideHome)
    _ = try fixture.makeDirectory("_cacache", under: npmRoot)
    let sentinel = try fixture.write("sentinel", bytes: [0xA5], under: outsideHome)
    let declaredHome = try fixture.makeSymbolicLink(
      "synthetic-home",
      destination: outsideHome,
      under: try resolvedFixtureURL(fixture.container)
    )
    let selectedRoot = declaredHome.appendingPathComponent(".npm", isDirectory: true)
    let scan = try await AllocatedSizeScanner().scan(root: selectedRoot)
    let beforeOutside = try treeSnapshot(at: fixture.outside)

    let observation = try await DescriptorRuleEvidenceObserver(
      rawHomeProvider: { .known(rawPathBytes(declaredHome)) }
    ).observe(request(root: selectedRoot, report: scan))

    #expect(observation.candidates.first?.trustedLocation != .known(true))
    #expect(try Data(contentsOf: sentinel) == Data([0xA5]))
    #expect(try treeSnapshot(at: fixture.outside) == beforeOutside)
  }

  @Test("A final location-binding swap invalidates previously collected trust")
  func finalTrustedLocationBinding() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let home = try resolvedFixtureURL(
      fixture.makeDirectory("synthetic-home", under: fixture.container)
    )
    let npmRoot = try fixture.makeDirectory(".npm", under: home)
    _ = try fixture.makeDirectory("_cacache", under: npmRoot)
    let replacement = try fixture.makeDirectory("replacement", under: fixture.container)
    _ = try fixture.makeDirectory("_cacache", under: replacement)
    let scan = try await AllocatedSizeScanner().scan(root: npmRoot)

    let observer = DescriptorRuleEvidenceObserver(
      rawHomeProvider: { .known(rawPathBytes(home)) },
      beforeFinalLocationValidation: {
        try FileManager.default.moveItem(
          at: npmRoot,
          to: fixture.container.appendingPathComponent("original-npm")
        )
        try FileManager.default.moveItem(
          at: replacement,
          to: home.appendingPathComponent(".npm")
        )
      }
    )
    let observation = try await observer.observe(request(root: npmRoot, report: scan))

    #expect(observation.candidates.first?.trustedLocation != .known(true))
    #expect(
      observation.candidates.first?.trustedLocation
        == .unknown(.changedDuringObservation)
    )
  }

  @Test("Replacing an exact trusted cache candidate invalidates its location evidence")
  func trustedCandidateReplacementBeforeOpen() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let home = try resolvedFixtureURL(
      fixture.makeDirectory("synthetic-home", under: fixture.container)
    )
    let npmRoot = try fixture.makeDirectory(".npm", under: home)
    let cache = try fixture.makeDirectory("_cacache", under: npmRoot)
    _ = try makeNPMMarkerPair(in: cache, fixture: fixture)
    let replacement = try fixture.makeDirectory("replacement", under: fixture.container)
    _ = try makeNPMMarkerPair(in: replacement, fixture: fixture)
    let outsideSentinel = try fixture.write("sentinel", bytes: [3], under: fixture.outside)
    let scan = try await AllocatedSizeScanner().scan(root: npmRoot)

    let observer = DescriptorRuleEvidenceObserver(
      rawHomeProvider: { .known(rawPathBytes(home)) },
      beforeOpeningCandidate: { path in
        guard path.rawComponents == [Array("_cacache".utf8)] else { return }
        try FileManager.default.moveItem(
          at: cache,
          to: fixture.container.appendingPathComponent("original-cache")
        )
        try FileManager.default.moveItem(
          at: replacement,
          to: npmRoot.appendingPathComponent("_cacache")
        )
      }
    )
    let observation = try await observer.observe(request(root: npmRoot, report: scan))
    let evidence = try #require(observation.candidates.first)

    #expect(evidence.identityMatchesScan == .unknown(.changedDuringObservation))
    #expect(evidence.trustedLocation == .unknown(.changedDuringObservation))
    #expect(evidence.generatedContentMarker == .unknown(.changedDuringObservation))
    #expect(try Data(contentsOf: outsideSentinel) == Data([3]))
  }

  @Test("Unavailable and malformed home evidence remains structured unknown")
  func trustedLocationHomeProviderFailures() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let home = try resolvedFixtureURL(
      fixture.makeDirectory("synthetic-home", under: fixture.container)
    )
    let npmRoot = try fixture.makeDirectory(".npm", under: home)
    _ = try fixture.makeDirectory("_cacache", under: npmRoot)
    let scan = try await AllocatedSizeScanner().scan(root: npmRoot)

    for reason: RuleUnknownReason in [.permissionDenied, .resourceLimit, .invalidMetadata] {
      let observation = try await DescriptorRuleEvidenceObserver(
        rawHomeProvider: { .unknown(reason) }
      ).observe(request(root: npmRoot, report: scan))
      #expect(observation.candidates.first?.identityMatchesScan == .known(true))
      #expect(observation.candidates.first?.trustedLocation == .unknown(reason))
    }

    for malformedHome in [Array("relative-home".utf8), [0x2F, 0x00]] {
      let observation = try await DescriptorRuleEvidenceObserver(
        rawHomeProvider: { .known(malformedHome) }
      ).observe(request(root: npmRoot, report: scan))
      #expect(
        observation.candidates.first?.trustedLocation
          == .unknown(.invalidMetadata)
      )
    }
  }

  @Test("Trusted location and an npm marker cannot make runtime cleanup eligible")
  func trustedLocationAndNPMMarkerStayProtected() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let home = try resolvedFixtureURL(
      fixture.makeDirectory("synthetic-home", under: fixture.container)
    )
    let npmRoot = try fixture.makeDirectory(".npm", under: home)
    let cache = try fixture.makeDirectory("_cacache", under: npmRoot)
    let markerPair = try makeNPMMarkerPair(in: cache, fixture: fixture)
    try fixture.setModificationTime(100, for: markerPair.content)
    try fixture.setModificationTime(100, for: markerPair.index)
    try fixture.setModificationTime(100, for: cache)
    let scan = try await AllocatedSizeScanner().scan(root: npmRoot)
    let treeBefore = try treeSnapshot(at: npmRoot)
    let classifier = try ExplainableRuleClassifier(
      rules: BuiltInRuleCatalog.rules,
      evidenceObserver: DescriptorRuleEvidenceObserver(
        rawHomeProvider: { .known(rawPathBytes(home)) }
      )
    )
    let report = try await classifier.classify(
      RuleClassificationRequest(
        root: npmRoot,
        report: scan,
        referenceUnixSeconds: 100 + 7 * 24 * 60 * 60
      )
    )
    let evaluation = try #require(
      report.evaluations.first {
        $0.path.rawComponents == [Array("_cacache".utf8)]
      }
    )
    let states = Dictionary(
      uniqueKeysWithValues: evaluation.findings.map { ($0.identifier.rawValue, $0.state) }
    )

    #expect(states["trusted-location"] == .satisfied)
    #expect(states["tool-ownership"] == .unknown(.notCollected))
    #expect(states["generated-content-marker"] == .satisfied)
    #expect(states["no-protected-descendants"] == .unknown(.notCollected))
    #expect(states["activity-requirement"] == .unknown(.notCollected))
    #expect(states["age-requirement"] == .satisfied)
    #expect(evaluation.matchState == .possibleMatch)
    #expect(evaluation.disposition == .protected)
    #expect(evaluation.rule?.version == testRuleVersion(2))
    let visibleText =
      ([
        evaluation.displayName,
        evaluation.responsibleTool,
        evaluation.explanation,
        evaluation.path.description,
      ] + evaluation.findings.map(\.explanation)).joined(separator: "\n")
    #expect(!visibleText.contains(home.path))
    #expect(try treeSnapshot(at: npmRoot) == treeBefore)
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

  @Test("Incomplete and duplicate cache observations cannot retain runtime evidence")
  func trustedLocationInvalidInputNormalization() async throws {
    let missingRoot = URL(fileURLWithPath: "/devsift-observer-does-not-exist")
    let rootIdentity = FileIdentity(device: 10, inode: 20)
    let cacheIdentity = FileIdentity(device: 10, inode: 21)
    let incompleteCache = ruleSummary(
      rawComponents: [Array("_cacache".utf8)],
      scanTimeIdentity: cacheIdentity,
      isComplete: false
    )
    let incompleteReport = ScanReport(
      root: ruleSummary(
        rawComponents: [],
        scanTimeIdentity: rootIdentity,
        isComplete: false
      ),
      topLevelItems: [incompleteCache],
      topLevelItemCount: 1,
      topLevelItemsWereSuppressed: false,
      hardLinkAccountingIsComplete: true,
      traversalDetailsWereDiscarded: false,
      issues: [],
      suppressedIssueCount: 0
    )
    let incomplete = try await DescriptorRuleEvidenceObserver(
      rawHomeProvider: { .known(Array("/synthetic-home".utf8)) }
    ).observe(request(root: missingRoot, report: incompleteReport))
    #expect(
      incomplete.candidates.first?.trustedLocation
        == .unknown(.incompleteScan)
    )
    #expect(
      incomplete.candidates.first?.generatedContentMarker
        == .unknown(.incompleteScan)
    )

    let cache = ruleSummary(
      rawComponents: [Array("_cacache".utf8)],
      scanTimeIdentity: cacheIdentity
    )
    let duplicate = try await DescriptorRuleEvidenceObserver(
      rawHomeProvider: { .known(Array("/synthetic-home".utf8)) }
    ).observe(
      request(
        root: missingRoot,
        report: identifiedReport(rootIdentity: rootIdentity, items: [cache, cache])
      )
    )
    #expect(
      duplicate.candidates.allSatisfy {
        $0.trustedLocation == .unknown(.invalidMetadata)
          && $0.generatedContentMarker == .unknown(.invalidMetadata)
      }
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
  case caseVariantRegularFile
}

private enum NPMMarkerFixtureKind: CaseIterable, Equatable {
  case exactPair
  case missingContent
  case missingIndex
  case wrongKind
  case wrongIndexKind
  case symbolicLink
  case indexSymbolicLink
  case caseVariants
  case nestedPair
}

private enum TrustedCacheFixtureRoot: CaseIterable {
  case npm
  case homebrew
  case uv

  var relativePath: String {
    switch self {
    case .npm: ".npm"
    case .homebrew: "Library/Caches"
    case .uv: ".cache"
    }
  }

  var candidateName: String {
    switch self {
    case .npm: "_cacache"
    case .homebrew: "Homebrew"
    case .uv: "uv"
    }
  }
}

private func rawPathBytes(_ url: URL) -> [UInt8] {
  Array(url.path.utf8)
}

private func path(_ name: String) -> ScanRelativePath {
  ScanRelativePath(rawComponents: [Array(name.utf8)])
}

private func makeNPMMarkerPair(
  in cache: URL,
  fixture: ScannerFixture
) throws -> (content: URL, index: URL) {
  (
    content: try fixture.makeDirectory("content-v2", under: cache),
    index: try fixture.makeDirectory("index-v5", under: cache)
  )
}

private final class MarkerCancellationGate: @unchecked Sendable {
  private let lock = NSLock()
  private let cancelAfterArmedCheckpoints: Int
  private var isArmed = false
  private var checkpointCount = 0

  init(cancelAfterArmedCheckpoints: Int) {
    self.cancelAfterArmedCheckpoints = cancelAfterArmedCheckpoints
  }

  var armedCheckpointCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return checkpointCount
  }

  func arm() {
    lock.lock()
    isArmed = true
    lock.unlock()
  }

  func checkpoint() throws {
    lock.lock()
    if isArmed {
      checkpointCount += 1
    }
    let shouldCancel = isArmed && checkpointCount == cancelAfterArmedCheckpoints
    lock.unlock()

    if shouldCancel {
      throw CancellationError()
    }
  }
}

private func resolvedFixtureURL(_ url: URL) throws -> URL {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  var failureCode: Int32 = EINVAL
  let succeeded = url.withUnsafeFileSystemRepresentation { path in
    guard let path else {
      return false
    }
    guard Darwin.realpath(path, &buffer) != nil else {
      failureCode = errno
      return false
    }
    return true
  }
  guard succeeded else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(failureCode))
  }
  return buffer.withUnsafeBufferPointer { bytes in
    URL(
      fileURLWithFileSystemRepresentation: bytes.baseAddress!,
      isDirectory: true,
      relativeTo: nil
    )
  }
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
