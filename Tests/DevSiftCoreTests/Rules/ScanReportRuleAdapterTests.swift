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
      uv.findings.contains {
        $0.state == .unknown(.notCollected)
      }
    )
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
