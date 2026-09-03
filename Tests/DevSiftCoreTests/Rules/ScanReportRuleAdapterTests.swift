import Foundation
import Testing

@testable import DevSiftCore

@Suite("Scan report rule adapter")
struct ScanReportRuleAdapterTests {
  @Test("Adapter classifies top-level items only and cannot produce reclaimable output")
  func topLevelOnlyAndFailClosed() async throws {
    let items = [
      ruleSummary(rawComponents: [Array("uv".utf8)]),
      ruleSummary(rawComponents: [Array("ordinary".utf8)]),
    ]
    let request = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/synthetic/Caches", isDirectory: true),
      report: completeScanReport(topLevelItems: items),
      referenceUnixSeconds: 1_000_000
    )

    let result = try await ExplainableRuleClassifier().classify(request)

    #expect(result.evaluations.count == 2)
    #expect(result.evaluations.allSatisfy { $0.path != .root })
    #expect(result.evaluations.allSatisfy { $0.disposition == .protected })
    let uv = try #require(
      result.evaluations.first { $0.path.rawComponents == [Array("uv".utf8)] }
    )
    #expect(uv.matchState == .possibleMatch)
    #expect(
      uv.findings.first {
        $0.identifier == testCheckIdentifier("identity-matches-scan")
      }?.state == .unknown(.notCollected)
    )
    #expect(
      uv.findings.contains {
        $0.state == .unknown(.notCollected)
      }
    )
  }

  @Test("Adapter projects age only from complete, valid scan observations")
  func newestModificationEvidenceBoundary() {
    let known = ruleSummary(
      rawComponents: [Array("known".utf8)],
      newestContentModificationUnixSeconds: 123
    )
    let missing = ruleSummary(rawComponents: [Array("missing".utf8)])
    let invalid = ruleSummary(
      rawComponents: [Array("invalid".utf8)],
      newestContentModificationUnixSeconds: -1
    )
    let incomplete = ruleSummary(
      rawComponents: [Array("incomplete".utf8)],
      isComplete: false,
      newestContentModificationUnixSeconds: 456
    )
    let report = ScanReport(
      root: ruleSummary(rawComponents: [], isComplete: false),
      topLevelItems: [known, missing, invalid, incomplete],
      topLevelItemCount: 4,
      topLevelItemsWereSuppressed: false,
      hardLinkAccountingIsComplete: true,
      traversalDetailsWereDiscarded: false,
      issues: [
        ScanIssue(
          path: incomplete.path,
          operation: .readMetadata,
          reason: .permissionDenied,
          impact: .descendantsSkipped
        )
      ],
      suppressedIssueCount: 0
    )
    let observations = ScanReportRuleAdapter.observations(
      for: RuleClassificationRequest(
        root: URL(fileURLWithPath: "/synthetic/root", isDirectory: true),
        report: report,
        referenceUnixSeconds: 1_000
      )
    )
    let observationsByPath = Dictionary(
      uniqueKeysWithValues: observations.map { ($0.summary.path, $0) }
    )
    let facts = Dictionary(uniqueKeysWithValues: observations.map { ($0.summary.path, $0.facts) })

    #expect(facts[known.path]?.newestContentModificationUnixSeconds == .known(123))
    #expect(
      facts[missing.path]?.newestContentModificationUnixSeconds == .unknown(.notCollected)
    )
    #expect(
      facts[invalid.path]?.newestContentModificationUnixSeconds == .unknown(.invalidMetadata)
    )
    #expect(
      facts[incomplete.path]?.newestContentModificationUnixSeconds == .unknown(.incompleteScan)
    )
    #expect(
      observationsByPath[incomplete.path]?.integrity.identityMatchesScan
        == .unknown(.incompleteScan)
    )
  }

  @Test("Evidence cardinality mismatches fail closed")
  func evidenceCardinalityMismatch() throws {
    let build = ruleSummary(
      rawComponents: [Array(".build".utf8)],
      scanTimeIdentity: FileIdentity(device: 1, inode: 2)
    )
    let cache = ruleSummary(
      rawComponents: [Array("_cacache".utf8)],
      scanTimeIdentity: FileIdentity(device: 1, inode: 3)
    )
    let report = ScanReport(
      root: ruleSummary(
        rawComponents: [],
        scanTimeIdentity: FileIdentity(device: 1, inode: 1)
      ),
      topLevelItems: [build, cache],
      topLevelItemCount: 2,
      topLevelItemsWereSuppressed: false,
      hardLinkAccountingIsComplete: true,
      traversalDetailsWereDiscarded: false,
      issues: [],
      suppressedIssueCount: 0
    )
    let observations = ScanReportRuleAdapter.observations(
      for: RuleClassificationRequest(
        root: URL(fileURLWithPath: "/synthetic", isDirectory: true),
        report: report,
        referenceUnixSeconds: 100
      ),
      evidence: RuleEvidenceObservation(candidates: [])
    )
    let observationsByPath = Dictionary(
      uniqueKeysWithValues: observations.map { ($0.summary.path, $0) }
    )
    let buildObservation = try #require(observationsByPath[build.path])
    let cacheObservation = try #require(observationsByPath[cache.path])

    #expect(buildObservation.integrity.identityMatchesScan == .unknown(.invalidMetadata))
    #expect(buildObservation.facts.trustedLocation == .unknown(.notCollected))
    #expect(buildObservation.facts.generatedContentMarker == .unknown(.invalidMetadata))
    #expect(cacheObservation.integrity.identityMatchesScan == .unknown(.invalidMetadata))
    #expect(cacheObservation.facts.trustedLocation == .unknown(.invalidMetadata))
    #expect(cacheObservation.facts.generatedContentMarker == .unknown(.notCollected))
  }

  @Test("Incomplete input overrides injected trusted-location evidence")
  func incompleteTrustedLocationEvidence() throws {
    let item = ruleSummary(
      rawComponents: [Array("_cacache".utf8)],
      scanTimeIdentity: FileIdentity(device: 1, inode: 2),
      isComplete: false
    )
    let report = ScanReport(
      root: ruleSummary(
        rawComponents: [],
        scanTimeIdentity: FileIdentity(device: 1, inode: 1),
        isComplete: false
      ),
      topLevelItems: [item],
      topLevelItemCount: 1,
      topLevelItemsWereSuppressed: false,
      hardLinkAccountingIsComplete: true,
      traversalDetailsWereDiscarded: false,
      issues: [],
      suppressedIssueCount: 0
    )
    let observations = ScanReportRuleAdapter.observations(
      for: RuleClassificationRequest(
        root: URL(fileURLWithPath: "/synthetic/.npm", isDirectory: true),
        report: report,
        referenceUnixSeconds: 100
      ),
      evidence: RuleEvidenceObservation(
        candidates: [
          CandidateRuleEvidence(
            identityMatchesScan: .known(true),
            trustedLocation: .known(true),
            generatedContentMarker: .unknown(.notCollected)
          )
        ]
      )
    )
    let observation = try #require(observations.first)

    #expect(observation.integrity.identityMatchesScan == .unknown(.incompleteScan))
    #expect(observation.facts.trustedLocation == .unknown(.incompleteScan))
  }

  @Test("Descriptor-scanned age rounds conservatively and stays protected")
  func descriptorScannedAgeRemainsProtected() async throws {
    let fixture = try ScannerFixture()
    defer { fixture.remove() }

    let build = try fixture.makeDirectory(".build")
    let payload = try fixture.write(".build/payload.bin", bytes: [1])
    let workspaceState = try fixture.write(".build/workspace-state.json", bytes: Array("{}".utf8))
    _ = try fixture.write("Package.swift", bytes: [])
    try fixture.setModificationTime(50, for: build)
    try fixture.setModificationTime(75, for: workspaceState)
    try fixture.setModificationTime(100, for: payload, nanoseconds: 1)

    let scan = try await AllocatedSizeScanner().scan(root: fixture.root)
    let boundaryTooEarly = try await ExplainableRuleClassifier().classify(
      RuleClassificationRequest(
        root: fixture.root,
        report: scan,
        referenceUnixSeconds: 100 + 7 * 24 * 60 * 60
      )
    )
    let boundaryDecision = try #require(
      boundaryTooEarly.evaluations.first {
        $0.path.rawComponents == [Array(".build".utf8)]
      }
    )
    let boundaryAge = try #require(
      boundaryDecision.findings.first {
        $0.identifier == testCheckIdentifier("age-requirement")
      }
    )
    #expect(boundaryAge.state == .failed)
    #expect(boundaryDecision.disposition == .protected)

    let classification = try await ExplainableRuleClassifier().classify(
      RuleClassificationRequest(
        root: fixture.root,
        report: scan,
        referenceUnixSeconds: 101 + 7 * 24 * 60 * 60
      )
    )
    let decision = try #require(
      classification.evaluations.first { $0.path.rawComponents == [Array(".build".utf8)] }
    )
    let age = try #require(
      decision.findings.first { $0.identifier == testCheckIdentifier("age-requirement") }
    )
    let identity = try #require(
      decision.findings.first {
        $0.identifier == testCheckIdentifier("identity-matches-scan")
      }
    )
    let marker = try #require(
      decision.findings.first {
        $0.identifier == testCheckIdentifier("generated-content-marker")
      }
    )

    #expect(age.state == .satisfied)
    #expect(identity.state == .satisfied)
    #expect(marker.state == .satisfied)
    #expect(decision.rule?.identifier == testRuleIdentifier("devsift.swiftpm.build"))
    #expect(decision.rule?.version == testRuleVersion(2))
    #expect(decision.rule.map { decision.matchingRules == [$0] } == true)
    #expect(
      decision.findings.first {
        $0.identifier == testCheckIdentifier("activity-requirement")
      }?.state == .unknown(.notCollected)
    )
    #expect(decision.matchState == .possibleMatch)
    #expect(decision.disposition == .protected)
  }

  @Test("SwiftPM manifest evidence uses an exact raw top-level sibling")
  func swiftPackageManifestRawSibling() async throws {
    let build = ruleSummary(rawComponents: [Array(".build".utf8)])
    let exactManifest = ruleSummary(
      rawComponents: [Array("Package.swift".utf8)],
      kind: .regularFile
    )
    let nearManifest = ruleSummary(
      rawComponents: [Array("package.swift".utf8)],
      kind: .regularFile
    )
    let classifier = ExplainableRuleClassifier()

    let exact = try await classifier.classify(
      RuleClassificationRequest(
        root: URL(fileURLWithPath: "/synthetic/Project", isDirectory: true),
        report: completeScanReport(topLevelItems: [build, exactManifest]),
        referenceUnixSeconds: 1_000_000
      )
    )
    let near = try await classifier.classify(
      RuleClassificationRequest(
        root: URL(fileURLWithPath: "/synthetic/Project", isDirectory: true),
        report: completeScanReport(topLevelItems: [build, nearManifest]),
        referenceUnixSeconds: 1_000_000
      )
    )

    let exactBuild = try #require(
      exact.evaluations.first { $0.path.rawComponents == [Array(".build".utf8)] }
    )
    let nearBuild = try #require(
      near.evaluations.first { $0.path.rawComponents == [Array(".build".utf8)] }
    )
    #expect(
      exactBuild.findings.first {
        $0.identifier == testCheckIdentifier("package-manifest-sibling")
      }?.state == .satisfied
    )
    #expect(
      nearBuild.findings.first {
        $0.identifier == testCheckIdentifier("package-manifest-sibling")
      }?.state == .failed
    )
    #expect(exactBuild.disposition == .protected)
    #expect(nearBuild.disposition == .protected)
  }

  @Test("DeviceSupport root recognition uses the selected URL raw basename")
  func rawRootBasename() async throws {
    let version = ruleSummary(rawComponents: [Array("17.4 (21E217)".utf8)])
    let report = completeScanReport(topLevelItems: [version])
    let classifier = ExplainableRuleClassifier()

    let exact = try await classifier.classify(
      RuleClassificationRequest(
        root: URL(fileURLWithPath: "/synthetic/iOS DeviceSupport", isDirectory: true),
        report: report,
        referenceUnixSeconds: 4_000_000
      )
    )
    let near = try await classifier.classify(
      RuleClassificationRequest(
        root: URL(fileURLWithPath: "/synthetic/IOS DeviceSupport", isDirectory: true),
        report: report,
        referenceUnixSeconds: 4_000_000
      )
    )

    #expect(exact.evaluations.first?.matchState == .possibleMatch)
    #expect(near.evaluations.first?.matchState == .unrecognized)
    #expect(exact.evaluations.first?.disposition == .protected)
    #expect(near.evaluations.first?.disposition == .protected)
  }

  @Test("Suppressed top-level output yields no invented candidates")
  func suppressedOutput() async throws {
    let report = ScanReport(
      root: ruleSummary(rawComponents: [], isComplete: false),
      topLevelItems: [],
      topLevelItemCount: 100,
      topLevelItemsWereSuppressed: true,
      hardLinkAccountingIsComplete: true,
      traversalDetailsWereDiscarded: false,
      issues: [],
      suppressedIssueCount: 0
    )

    let result = try await ExplainableRuleClassifier().classify(
      RuleClassificationRequest(
        root: URL(fileURLWithPath: "/synthetic/Caches", isDirectory: true),
        report: report,
        referenceUnixSeconds: 1_000_000
      )
    )
    #expect(result.evaluations.isEmpty)
  }
}
