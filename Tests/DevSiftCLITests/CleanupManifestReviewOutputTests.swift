import DevSiftCore
import Foundation
import Testing

@testable import DevSiftCLI
@testable import DevSiftCore

@Suite("Cleanup manifest review output")
struct CleanupManifestReviewOutputTests {
  @Test("Redacted output omits path, identity, time, free text, and unselected policy")
  func redactedPrivacyBoundary() throws {
    let rawName = Array("private-client-project".utf8)
    let rawNameBase64 = Data(rawName).base64EncodedString()
    let selectedRevision = CLITestClassificationFactory.revision(
      identifier: "devsift.test.private-selected-rule",
      version: 10
    )
    let privateFindings = CLITestManifestFactory.validFindings().map { finding in
      guard finding.identifier.rawValue == "identity-matches-scan" else {
        return finding
      }
      return CLITestClassificationFactory.finding(
        identifier: "identity-matches-scan",
        kind: .scanIntegrity,
        explanation: "PRIVATE-FINDING-CANARY"
      )
    }
    let entry = CLITestManifestFactory.entry(
      rawName: rawName,
      identity: FileIdentity(device: 7_777_771, inode: 8_888_881),
      ruleRevision: selectedRevision,
      displayName: "PRIVATE-DISPLAY-CANARY",
      responsibleTool: "PRIVATE-TOOL-CANARY",
      classificationExplanation: "PRIVATE-CLASSIFICATION-CANARY",
      findings: privateFindings
    )
    let unselectedRevision = CLITestClassificationFactory.revision(
      identifier: "devsift.test.private-unselected-rule",
      version: 11
    )
    let manifest = try CLITestManifestFactory.manifest(
      entries: [entry],
      provenance: CLITestManifestFactory.provenance(
        ruleRevisions: [selectedRevision, unselectedRevision]
      ),
      referenceUnixSeconds: -7_654_321,
      rootIdentity: FileIdentity(device: 7_777_771, inode: 9_999_991)
    )

    let output = try CleanupManifestReviewJSONEncoder().encode(
      manifest: manifest,
      privacyProfile: .redacted
    )
    let outputText = try utf8String(output)
    let document = try jsonObject(output)
    let disclosures = try dictionary(document["disclosures"])
    let policy = try dictionary(document["policy"])
    let entries = try array(document["entries"])
    let renderedEntry = try dictionary(entries.first)
    let summary = try dictionary(document["summary"])

    #expect(
      Set(document.keys) == [
        "schema",
        "schemaVersion",
        "documentPurpose",
        "executionAuthority",
        "importSupported",
        "canBeApproved",
        "canBeExecuted",
        "sourceManifestContractVersion",
        "privacyProfile",
        "sourceManifestRequiresExplicitApproval",
        "sourceManifestRequiresExecutionRevalidation",
        "disclosures",
        "policy",
        "summary",
        "entries",
      ])
    #expect(document["schema"] as? String == "devsift.cleanup-manifest-review")
    #expect(document["schemaVersion"] as? Int == 2)
    #expect(document["sourceManifestContractVersion"] as? String == "3")
    #expect(document["privacyProfile"] as? String == "redacted")
    #expect(document["documentPurpose"] as? String == "review-only")
    #expect(document["executionAuthority"] as? String == "none")
    #expect(document["importSupported"] as? Bool == false)
    #expect(document["canBeApproved"] as? Bool == false)
    #expect(document["canBeExecuted"] as? Bool == false)
    #expect(document["sourceManifestRequiresExplicitApproval"] as? Bool == true)
    #expect(document["sourceManifestRequiresExecutionRevalidation"] as? Bool == true)
    #expect(document["classificationReferenceUnixSeconds"] == nil)
    #expect(disclosures["absoluteRoot"] as? String == "no-dedicated-field")
    #expect(disclosures["path"] as? String == "document-ordinal")
    #expect(disclosures["filesystemIdentity"] as? String == "omitted")
    #expect(disclosures["referenceTime"] as? String == "omitted")
    #expect(disclosures["explanatoryText"] as? String == "omitted")
    #expect(disclosures["policyRuleRoster"] as? String == "selected-only")
    #expect(disclosures["policyIdentifiers"] as? String == "included")
    #expect(disclosures["findingIdentifiers"] as? String == "included")
    #expect(disclosures["toolUseMayBeInferred"] as? Bool == true)
    #expect(
      Set(disclosures.keys) == [
        "absoluteRoot",
        "path",
        "filesystemIdentity",
        "referenceTime",
        "explanatoryText",
        "policyRuleRoster",
        "policyIdentifiers",
        "findingIdentifiers",
        "toolUseMayBeInferred",
        "quantities",
      ])
    #expect(renderedEntry["candidate"] as? String == "candidate-00001")
    #expect(renderedEntry["path"] == nil)
    #expect(renderedEntry["displayName"] == nil)
    #expect(renderedEntry["responsibleTool"] == nil)
    #expect(renderedEntry["classificationExplanation"] == nil)
    #expect(
      Set(renderedEntry.keys) == [
        "candidate",
        "expectedKind",
        "ruleRevision",
        "disposition",
        "reproducibility",
        "deferredExecutionPreconditions",
        "findings",
        "size",
      ])
    #expect(try array(renderedEntry["deferredExecutionPreconditions"]).isEmpty)
    #expect(Set(summary.keys) == ["entryCount", "totals"])

    #expect(policy["ruleRevisionScope"] as? String == "selected-only")
    let revisions = try array(policy["disclosedRuleRevisions"])
    #expect(revisions.count == 1)
    let disclosedRevision = try dictionary(revisions.first)
    #expect(Set(disclosedRevision.keys) == ["identifier", "version"])
    #expect(disclosedRevision["identifier"] as? String == selectedRevision.identifier.rawValue)
    let redactedFindings = try array(renderedEntry["findings"]).compactMap {
      $0 as? [String: Any]
    }
    let redactedIdentity = try #require(
      redactedFindings.first(where: { finding in
        finding["identifier"] as? String == "identity-matches-scan"
      }))
    #expect(Set(redactedIdentity.keys) == ["identifier", "kind", "state"])
    #expect(outputText.contains(selectedRevision.identifier.rawValue))
    #expect(outputText.contains("identity-matches-scan"))
    #expect(outputText.contains("\"observedLogicalBytes\":\"1024\""))
    for canary in [
      String(bytes: rawName, encoding: .utf8)!,
      rawNameBase64,
      "7777771",
      "8888881",
      "9999991",
      "-7654321",
      "PRIVATE-DISPLAY-CANARY",
      "PRIVATE-TOOL-CANARY",
      "PRIVATE-CLASSIFICATION-CANARY",
      "PRIVATE-FINDING-CANARY",
      unselectedRevision.identifier.rawValue,
    ] {
      #expect(outputText.contains(canary) == false)
    }
    #expect(outputText.contains("\"device\"") == false)
    #expect(outputText.contains("\"inode\"") == false)
  }

  @Test("Exact root-relative output preserves bytes and escapes deceptive display text")
  func exactRootRelativePrivacyBoundary() throws {
    let invalidName = [UInt8](arrayLiteral: 0xFF, 0x0A, 0x1B, 0x5C)
    let deceptiveName = Array("line\n\\\u{202E}name".utf8)
    let deceptiveFindings = CLITestManifestFactory.validFindings().map { finding in
      guard finding.identifier.rawValue == "identity-matches-scan" else {
        return finding
      }
      return CLITestClassificationFactory.finding(
        identifier: "identity-matches-scan",
        kind: .scanIntegrity,
        explanation: "Evidence\n\u{202E}is visible"
      )
    }
    let entries = [
      CLITestManifestFactory.entry(
        rawName: invalidName,
        identity: FileIdentity(device: 42, inode: 3),
        ruleRevision: CLITestManifestFactory.secondaryRuleRevision
      ),
      CLITestManifestFactory.entry(
        rawName: deceptiveName,
        identity: FileIdentity(device: 42, inode: 2),
        displayName: "Display\n\u{202E}name",
        responsibleTool: "Tool\\name",
        classificationExplanation: "Explanation\rline",
        findings: deceptiveFindings
      ),
    ]
    let manifest = try CLITestManifestFactory.manifest(
      entries: entries,
      referenceUnixSeconds: Int64.min
    )

    let output = try CleanupManifestReviewJSONEncoder().encode(
      manifest: manifest,
      privacyProfile: .rootRelativeExact
    )
    let outputText = try utf8String(output)
    let document = try jsonObject(output)
    let disclosures = try dictionary(document["disclosures"])
    let policy = try dictionary(document["policy"])
    let renderedEntries = try array(document["entries"]).map(dictionary)
    let paths = try renderedEntries.map { try dictionary($0["path"]) }

    #expect(
      Set(document.keys) == [
        "schema",
        "schemaVersion",
        "documentPurpose",
        "executionAuthority",
        "importSupported",
        "canBeApproved",
        "canBeExecuted",
        "sourceManifestContractVersion",
        "privacyProfile",
        "sourceManifestRequiresExplicitApproval",
        "sourceManifestRequiresExecutionRevalidation",
        "disclosures",
        "policy",
        "classificationReferenceUnixSeconds",
        "summary",
        "entries",
      ])
    #expect(document["privacyProfile"] as? String == "root-relative-exact")
    #expect(document["classificationReferenceUnixSeconds"] as? String == String(Int64.min))
    #expect(disclosures["path"] as? String == "root-relative-exact")
    #expect(disclosures["filesystemIdentity"] as? String == "omitted")
    #expect(disclosures["referenceTime"] as? String == "exact")
    #expect(disclosures["explanatoryText"] as? String == "included")
    #expect(disclosures["policyRuleRoster"] as? String == "complete")
    #expect(policy["ruleRevisionScope"] as? String == "complete")
    #expect(try array(policy["disclosedRuleRevisions"]).count == 2)
    #expect(
      Set(policy.keys) == [
        "classificationContractRevision",
        "catalogRevision",
        "ruleRevisionScope",
        "disclosedRuleRevisions",
      ])
    #expect(
      Set(renderedEntries[0].keys) == [
        "candidate",
        "path",
        "expectedKind",
        "ruleRevision",
        "disposition",
        "reproducibility",
        "deferredExecutionPreconditions",
        "displayName",
        "responsibleTool",
        "classificationExplanation",
        "findings",
        "size",
      ])
    let completeEntry = renderedEntries[0]
    #expect(completeEntry["displayName"] as? String == "Display\\n\\u{202E}name")
    #expect(completeEntry["responsibleTool"] as? String == "Tool\\\\name")
    #expect(completeEntry["classificationExplanation"] as? String == "Explanation\\rline")
    #expect(completeEntry["expectedKind"] as? String == "directory")
    #expect(completeEntry["disposition"] as? String == "review-required")
    #expect(completeEntry["reproducibility"] as? String == "reproducible")
    let revision = try dictionary(completeEntry["ruleRevision"])
    #expect(Set(revision.keys) == ["identifier", "version"])
    #expect(revision["identifier"] as? String == "devsift.test.manifest-primary")
    #expect(revision["version"] as? String == "7")
    let renderedFindings = try array(completeEntry["findings"]).compactMap {
      $0 as? [String: Any]
    }
    let finding = try #require(
      renderedFindings.first(where: { finding in
        finding["identifier"] as? String == "identity-matches-scan"
      }))
    #expect(Set(finding.keys) == ["identifier", "kind", "state", "explanation"])
    #expect(finding["identifier"] as? String == "identity-matches-scan")
    #expect(finding["kind"] as? String == "scan-integrity")
    #expect(finding["explanation"] as? String == "Evidence\\n\\u{202E}is visible")
    let findingState = try dictionary(finding["state"])
    #expect(Set(findingState.keys) == ["status"])
    #expect(findingState["status"] as? String == "satisfied")
    let size = try dictionary(completeEntry["size"])
    #expect(
      Set(size.keys) == [
        "observedLogicalBytes",
        "observedAllocatedBytes",
        "observedHardLinkExclusiveAllocatedBytes",
        "possibleSharedContentFileCount",
        "sharedContentMetadataUnavailableCount",
        "unobservedHardLinkFileCount",
        "nonExclusiveHardLinkFileCount",
      ])
    #expect(size["observedLogicalBytes"] as? String == "1024")
    #expect(size["observedAllocatedBytes"] as? String == "768")
    #expect(size["observedHardLinkExclusiveAllocatedBytes"] as? String == "512")
    #expect(size["possibleSharedContentFileCount"] as? String == "1")
    #expect(size["sharedContentMetadataUnavailableCount"] as? String == "2")
    #expect(size["unobservedHardLinkFileCount"] as? String == "3")
    #expect(size["nonExclusiveHardLinkFileCount"] as? String == "4")

    let invalidPath = try #require(
      paths.first(where: { path in
        (path["rawComponentsBase64"] as? [String]) == [Data(invalidName).base64EncodedString()]
      }))
    #expect(Set(invalidPath.keys) == ["display", "rawComponentsBase64"])
    #expect(invalidPath["display"] as? String == "\\xFF\\x0A\\x1B\\x5C")

    let deceptivePath = try #require(
      paths.first(where: { path in
        (path["rawComponentsBase64"] as? [String]) == [Data(deceptiveName).base64EncodedString()]
      }))
    let deceptiveDisplay = try #require(deceptivePath["display"] as? String)
    #expect(deceptiveDisplay.contains("\\n"))
    #expect(deceptiveDisplay.contains("\\\\"))
    #expect(deceptiveDisplay.contains("\\u{202E}"))
    #expect(deceptiveDisplay.contains("\n") == false)
    #expect(deceptiveDisplay.unicodeScalars.contains("\u{202E}") == false)
    #expect(outputText.dropLast().contains("\n") == false)
    #expect(outputText.hasSuffix("\n"))
    #expect(outputText.hasSuffix("\n\n") == false)
    #expect(outputText.contains("\"device\"") == false)
    #expect(outputText.contains("\"inode\"") == false)
  }

  @Test("Deferred execution preconditions are explicit in both review profiles")
  func deferredExecutionPreconditions() throws {
    let precondition = RuleDeferredExecutionPrecondition
      .requiresUserAttestationThatResponsibleToolIsStopped
    let findings = CLITestManifestFactory.validFindings().map { finding in
      guard finding.identifier.rawValue == "activity-requirement" else {
        return finding
      }
      return CLITestClassificationFactory.finding(
        identifier: "activity-requirement",
        kind: .activity,
        state: .unknown(.notCollected),
        explanation: "Activity remains unobserved."
      )
    }
    let manifest = try CLITestManifestFactory.manifest(
      entries: [
        CLITestManifestFactory.entry(
          deferredExecutionPreconditions: [precondition],
          findings: findings
        )
      ]
    )

    for profile in CleanupManifestReviewPrivacyProfile.allCases {
      let output = try CleanupManifestReviewJSONEncoder().encode(
        manifest: manifest,
        privacyProfile: profile
      )
      let document = try jsonObject(output)
      let entry = try dictionary(try array(document["entries"]).first)
      let rendered = try dictionary(
        try array(entry["deferredExecutionPreconditions"]).first
      )
      let activity = try #require(
        try array(entry["findings"]).compactMap { $0 as? [String: Any] }.first { finding in
          finding["identifier"] as? String == "activity-requirement"
        }
      )
      let state = try dictionary(activity["state"])

      #expect(Set(rendered.keys) == ["identifier", "policyRevision"])
      #expect(rendered["identifier"] as? String == precondition.rawValue)
      #expect(rendered["policyRevision"] as? String == String(precondition.policyRevision))
      #expect(state["status"] as? String == "unknown")
      #expect(state["reason"] as? String == "not-collected")
      #expect(document["canBeApproved"] as? Bool == false)
      #expect(document["canBeExecuted"] as? Bool == false)
    }
  }

  @Test("Output is repeatable, raw-path ordered, and keeps full-width integers")
  func deterministicFullWidthOutput() throws {
    let firstEntry = CLITestManifestFactory.entry(
      rawName: Array("z-cache".utf8),
      identity: FileIdentity(device: UInt64.max, inode: UInt64.max - 1),
      logicalBytes: .max,
      allocatedBytes: .max,
      hardLinkExclusiveAllocatedBytes: .max,
      possibleSharedContentFileCount: .max,
      sharedContentMetadataUnavailableCount: .max,
      unobservedHardLinkFileCount: .max,
      nonExclusiveHardLinkFileCount: .max
    )
    let secondEntry = CLITestManifestFactory.entry(
      rawName: Array("a-cache".utf8),
      identity: FileIdentity(device: UInt64.max, inode: UInt64.max - 2),
      logicalBytes: 0,
      allocatedBytes: 0,
      hardLinkExclusiveAllocatedBytes: 0,
      possibleSharedContentFileCount: 0,
      sharedContentMetadataUnavailableCount: 0,
      unobservedHardLinkFileCount: 0,
      nonExclusiveHardLinkFileCount: 0
    )
    let forward = try CLITestManifestFactory.manifest(
      entries: [firstEntry, secondEntry],
      referenceUnixSeconds: Int64.max,
      rootIdentity: FileIdentity(device: UInt64.max, inode: 1)
    )
    let reversed = try CLITestManifestFactory.manifest(
      entries: [secondEntry, firstEntry],
      referenceUnixSeconds: Int64.max,
      rootIdentity: FileIdentity(device: UInt64.max, inode: 1)
    )
    let encoder = CleanupManifestReviewJSONEncoder()

    let first = try encoder.encode(manifest: forward, privacyProfile: .rootRelativeExact)
    let second = try encoder.encode(manifest: forward, privacyProfile: .rootRelativeExact)
    let reordered = try encoder.encode(manifest: reversed, privacyProfile: .rootRelativeExact)
    let firstText = try utf8String(first)
    let document = try jsonObject(first)
    let summary = try dictionary(document["summary"])
    let totals = try dictionary(summary["totals"])
    let renderedEntries = try array(document["entries"]).map(dictionary)

    #expect(first == second)
    #expect(first == reordered)
    #expect(document["classificationReferenceUnixSeconds"] as? String == String(Int64.max))
    #expect(totals["observedLogicalBytes"] as? String == String(UInt64.max))
    #expect(totals["observedAllocatedBytes"] as? String == String(UInt64.max))
    #expect(
      totals["observedHardLinkExclusiveAllocatedBytes"] as? String == String(UInt64.max)
    )
    #expect(
      renderedEntries.map { $0["candidate"] as? String } == [
        "candidate-00001", "candidate-00002",
      ])
    let firstPath = try dictionary(renderedEntries[0]["path"])
    #expect(
      firstPath["rawComponentsBase64"] as? [String] == [
        Data("a-cache".utf8).base64EncodedString()
      ])
    #expect(firstText.contains(String(UInt64.max - 1)) == false)
    #expect(firstText.contains(String(UInt64.max - 2)) == false)
  }

  @Test("Empty manifests retain an explicit review-only envelope")
  func emptyManifest() throws {
    let manifest = try CLITestManifestFactory.manifest(entries: [])
    let output = try CleanupManifestReviewJSONEncoder().encode(
      manifest: manifest,
      privacyProfile: .redacted
    )
    let document = try jsonObject(output)
    let summary = try dictionary(document["summary"])

    #expect(try array(document["entries"]).isEmpty)
    #expect(summary["entryCount"] as? String == "0")
    #expect(document["executionAuthority"] as? String == "none")
  }

  @Test("A real planner result crosses the one-way review boundary without path I/O")
  func plannerIntegration() async throws {
    let referenceUnixSeconds: Int64 = 1_000_000
    let rootIdentity = FileIdentity(device: 42, inode: 1)
    let candidateIdentity = FileIdentity(device: 42, inode: 2)
    let candidate = CLITestReportFactory.item(
      rawComponents: [Array("uv".utf8)],
      scanTimeIdentity: candidateIdentity,
      logicalBytes: 2_048,
      allocatedBytes: 1_024,
      newestContentModificationUnixSeconds: 0
    )
    let scanReport = CLITestReportFactory.report(
      root: CLITestReportFactory.item(
        scanTimeIdentity: rootIdentity
      ),
      topLevelItems: [candidate]
    )
    let request = RuleClassificationRequest(
      root: URL(fileURLWithPath: "/synthetic/manifest-review", isDirectory: true),
      report: scanReport,
      referenceUnixSeconds: referenceUnixSeconds
    )
    let observation = RuleObservation(
      summary: candidate,
      selectedRootBasename: .known(Array("Caches".utf8)),
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
        toolOwnership: .known(true),
        generatedContentMarker: .known(true),
        newestContentModificationUnixSeconds: .known(0),
        activity: .known(.inactive),
        protectedDescendantPresent: .known(false),
        siblingPackageManifestPresent: .known(true)
      )
    )
    let report = try await ExplainableRuleClassifier().classify(
      observations: [observation],
      referenceUnixSeconds: referenceUnixSeconds
    ).binding(to: request)
    let revision = try #require(report.evaluations.first?.rule)
    let manifest = try CleanupPlanner().makeManifest(
      CleanupManifestRequest(
        classificationRequest: request,
        classificationReport: report,
        selections: [
          CleanupCandidateSelection(path: candidate.path, ruleRevision: revision)
        ]
      )
    )

    #expect(manifest.entries.count == 1)
    for profile in CleanupManifestReviewPrivacyProfile.allCases {
      let output = try CleanupManifestReviewJSONEncoder().encode(
        manifest: manifest,
        privacyProfile: profile
      )
      let document = try jsonObject(output)
      let renderedEntry = try dictionary(try array(document["entries"]).first)

      #expect(document["sourceManifestContractVersion"] as? String == "3")
      #expect(renderedEntry["candidate"] as? String == "candidate-00001")
      #expect(try array(renderedEntry["deferredExecutionPreconditions"]).isEmpty)
      #expect(try array(renderedEntry["findings"]).count == manifest.entries[0].findings.count)
      #expect(try utf8String(output).contains("/synthetic/manifest-review") == false)
    }
  }

  @Test("Malformed and unsupported manifests fail before projection")
  func invalidManifestBoundaries() throws {
    let entry = CLITestManifestFactory.entry()
    let oldContract = try CLITestManifestFactory.manifest(
      entries: [entry],
      contractVersion:
        CleanupManifestReviewOutputContract.supportedSourceManifestContractVersion - 1
    )
    #expect(
      throws: CleanupManifestReviewExportError.unsupportedManifestContractVersion(
        expected: CleanupManifestReviewOutputContract.supportedSourceManifestContractVersion,
        actual: CleanupManifestReviewOutputContract.supportedSourceManifestContractVersion - 1
      )
    ) {
      try CleanupManifestReviewValidator.validate(oldContract)
    }

    let duplicate = try CLITestManifestFactory.manifest(entries: [entry, entry])
    #expect(throws: CleanupManifestReviewExportError.duplicateEntryPath(index: 1)) {
      try CleanupManifestReviewValidator.validate(duplicate)
    }

    let undeclaredEntry = CLITestManifestFactory.entry(
      ruleRevision: CLITestManifestFactory.secondaryRuleRevision
    )
    let undeclared = try CLITestManifestFactory.manifest(
      entries: [undeclaredEntry],
      provenance: CLITestManifestFactory.provenance(
        ruleRevisions: [CLITestManifestFactory.primaryRuleRevision]
      )
    )
    #expect(throws: CleanupManifestReviewExportError.undeclaredRuleRevision(index: 0)) {
      try CleanupManifestReviewValidator.validate(undeclared)
    }

    let unsatisfied = CLITestManifestFactory.entry(
      findings: [
        CLITestClassificationFactory.finding(
          identifier: "identity-matches-scan",
          kind: .scanIntegrity,
          state: .unknown(.changedDuringObservation)
        )
      ]
    )
    let invalidEvidence = try CLITestManifestFactory.manifest(entries: [unsatisfied])
    #expect(
      throws: CleanupManifestReviewExportError.invalidEntry(
        index: 0,
        issue: .unsatisfiedFinding
      )
    ) {
      try CleanupManifestReviewValidator.validate(invalidEvidence)
    }

    let unpairedPrecondition = try CLITestManifestFactory.manifest(
      entries: [
        CLITestManifestFactory.entry(
          deferredExecutionPreconditions: [.requiresUserAttestationThatResponsibleToolIsStopped]
        )
      ]
    )
    #expect(
      throws: CleanupManifestReviewExportError.invalidEntry(
        index: 0,
        issue: .invalidDeferredExecutionPreconditions
      )
    ) {
      try CleanupManifestReviewValidator.validate(unpairedPrecondition)
    }

    let missingIdentity = try CLITestManifestFactory.manifest(
      entries: [CLITestManifestFactory.entry(findings: [])]
    )
    #expect(
      throws: CleanupManifestReviewExportError.invalidEntry(
        index: 0,
        issue: .missingIdentityFinding
      )
    ) {
      try CleanupManifestReviewValidator.validate(missingIdentity)
    }

    let nonReproducibleReclaimable = try CLITestManifestFactory.manifest(
      entries: [
        CLITestManifestFactory.entry(
          disposition: .reclaimable,
          reproducibility: .conditional
        )
      ]
    )
    #expect(
      throws: CleanupManifestReviewExportError.invalidEntry(
        index: 0,
        issue: .reclaimableIsNotReproducible
      )
    ) {
      try CleanupManifestReviewValidator.validate(nonReproducibleReclaimable)
    }
  }

  @Test("Hostile path shapes fail closed and the byte boundary is exact")
  func pathBoundaries() throws {
    let valid = try CLITestManifestFactory.manifest(
      entries: [CLITestManifestFactory.entry(rawName: [UInt8](repeating: 0x61, count: 255))]
    )
    try CleanupManifestReviewValidator.validate(valid)

    let cases: [([UInt8], CleanupPlanPathIssue)] = [
      ([], .emptyComponent),
      ([0x2E], .currentDirectoryComponent),
      ([0x2E, 0x2E], .parentDirectoryComponent),
      ([0x61, 0x00], .containsNullByte),
      ([0x61, 0x2F], .containsPathSeparator),
      (
        [UInt8](repeating: 0x61, count: 256),
        .componentTooLong(maximum: 255, actual: 256)
      ),
    ]
    for (rawName, issue) in cases {
      let manifest = try CLITestManifestFactory.manifest(
        entries: [CLITestManifestFactory.entry(rawName: rawName)]
      )
      #expect(
        throws: CleanupManifestReviewExportError.invalidEntry(
          index: 0,
          issue: .path(issue)
        )
      ) {
        try CleanupManifestReviewValidator.validate(manifest)
      }
    }
  }

  @Test("Entry limits and output byte limits fail closed")
  func resourceLimits() throws {
    let boundaryFindings = CLITestManifestFactory.validFindings()
    let maximumEntries = (0..<CleanupPlanningLimits.maximumSelections).map { index in
      CLITestManifestFactory.entry(
        rawName: Array(String(format: "%05X", index).utf8),
        identity: FileIdentity(device: 42, inode: UInt64(index + 2)),
        findings: boundaryFindings
      )
    }
    let boundary = try CLITestManifestFactory.manifest(entries: maximumEntries)
    try CleanupManifestReviewValidator.validate(boundary)

    let excessive = try CLITestManifestFactory.manifest(
      entries: maximumEntries + [
        CLITestManifestFactory.entry(
          rawName: Array("overflow".utf8),
          identity: FileIdentity(device: 42, inode: 99_999)
        )
      ]
    )
    #expect(
      throws: CleanupManifestReviewExportError.tooManyEntries(
        maximum: CleanupPlanningLimits.maximumSelections,
        actual: CleanupPlanningLimits.maximumSelections + 1
      )
    ) {
      try CleanupManifestReviewValidator.validate(excessive)
    }

    let emptyManifest = try CLITestManifestFactory.manifest(entries: [])
    let baselineOutput = try CleanupManifestReviewJSONEncoder().encode(
      manifest: emptyManifest,
      privacyProfile: .redacted
    )
    let exactLimitOutput = try CleanupManifestReviewJSONEncoder(
      maximumEncodedBytes: baselineOutput.count
    ).encode(manifest: emptyManifest, privacyProfile: .redacted)
    #expect(exactLimitOutput == baselineOutput)

    let insufficientLimit = baselineOutput.count - 1
    #expect(
      throws: CleanupManifestReviewExportError.outputTooLarge(
        maximumBytes: insufficientLimit,
        projectedBytes: baselineOutput.count
      )
    ) {
      try CleanupManifestReviewJSONEncoder(maximumEncodedBytes: insufficientLimit).encode(
        manifest: emptyManifest,
        privacyProfile: .redacted
      )
    }

    let populatedManifest = try CLITestManifestFactory.manifest()
    let populatedOutput = try CleanupManifestReviewJSONEncoder().encode(
      manifest: populatedManifest,
      privacyProfile: .redacted
    )
    #expect(
      try CleanupManifestReviewJSONEncoder(
        maximumEncodedBytes: populatedOutput.count
      ).encode(manifest: populatedManifest, privacyProfile: .redacted) == populatedOutput
    )
    #expect(
      throws: CleanupManifestReviewExportError.outputTooLarge(
        maximumBytes: populatedOutput.count - 1,
        projectedBytes: populatedOutput.count
      )
    ) {
      try CleanupManifestReviewJSONEncoder(
        maximumEncodedBytes: populatedOutput.count - 1
      ).encode(manifest: populatedManifest, privacyProfile: .redacted)
    }
  }

  @Test("Pre-cancellation returns no review document")
  func cancellation() async throws {
    let manifest = try CLITestManifestFactory.manifest()
    let wasCancelled = await Task {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      do {
        _ = try CleanupManifestReviewJSONEncoder().encode(
          manifest: manifest,
          privacyProfile: .redacted
        )
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }.value

    #expect(wasCancelled)
  }

  @Test("Stored model shape changes force a review of every disclosure decision")
  func storageShapeTripwire() throws {
    let manifest = try CLITestManifestFactory.manifest()
    let entry = try #require(manifest.entries.first)
    let finding = try #require(entry.findings.first)

    #expect(
      CleanupManifest.currentContractVersion
        == CleanupManifestReviewOutputContract.supportedSourceManifestContractVersion
    )
    #expect(
      storedPropertyLabels(of: manifest) == [
        "classificationReferenceUnixSeconds",
        "contractVersion",
        "entries",
        "expectedRootIdentity",
        "policyProvenance",
        "totals",
      ])
    #expect(
      storedPropertyLabels(of: entry) == [
        "classificationExplanation",
        "deferredExecutionPreconditions",
        "displayName",
        "disposition",
        "expectedIdentity",
        "expectedKind",
        "findings",
        "path",
        "reproducibility",
        "responsibleTool",
        "ruleRevision",
        "size",
      ])
    #expect(
      storedPropertyLabels(of: entry.size) == [
        "nonExclusiveHardLinkFileCount",
        "observedAllocatedBytes",
        "observedHardLinkExclusiveAllocatedBytes",
        "observedLogicalBytes",
        "possibleSharedContentFileCount",
        "sharedContentMetadataUnavailableCount",
        "unobservedHardLinkFileCount",
      ])
    #expect(
      storedPropertyLabels(of: manifest.totals) == [
        "nonExclusiveHardLinkFileCount",
        "observedAllocatedBytes",
        "observedHardLinkExclusiveAllocatedBytes",
        "observedLogicalBytes",
        "possibleSharedContentFileCount",
        "sharedContentMetadataUnavailableCount",
        "unobservedHardLinkFileCount",
      ])
    #expect(
      storedPropertyLabels(of: manifest.policyProvenance) == [
        "catalogRevision",
        "classificationContractRevision",
        "ruleRevisions",
      ])
    #expect(storedPropertyLabels(of: entry.ruleRevision) == ["identifier", "version"])
    #expect(
      storedPropertyLabels(of: finding) == [
        "explanation", "identifier", "kind", "state",
      ])
    #expect((manifest as Any) is any Encodable == false)
    #expect((entry as Any) is any Encodable == false)
  }

  private func jsonObject(_ output: Data) throws -> [String: Any] {
    try dictionary(JSONSerialization.jsonObject(with: output))
  }

  private func utf8String(_ output: Data) throws -> String {
    try #require(String(data: output, encoding: .utf8))
  }

  private func dictionary(_ value: Any?) throws -> [String: Any] {
    try #require(value as? [String: Any])
  }

  private func array(_ value: Any?) throws -> [Any] {
    try #require(value as? [Any])
  }

  private func storedPropertyLabels(of value: some Any) -> [String] {
    Mirror(reflecting: value).children.compactMap(\.label).sorted()
  }
}
