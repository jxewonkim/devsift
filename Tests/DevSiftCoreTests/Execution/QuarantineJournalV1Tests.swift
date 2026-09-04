import Foundation
import Testing

@testable import DevSiftCore

@Suite("Quarantine journal v1 canonical codec")
struct QuarantineJournalV1Tests {
  @Test("Intent bytes are deterministic, canonical, and round trip losslessly")
  func intentRoundTrip() throws {
    let intent = validIntent()

    let first = try QuarantineJournalV1Codec.encode(intent)
    let second = try QuarantineJournalV1Codec.encode(intent)

    #expect(first == second)
    #expect(try QuarantineJournalV1Codec.decodeIntent(first) == intent)
    #expect(first.count < QuarantineJournalV1Codec.maximumEncodedByteCount)
    #expect(!(intent as Any is any Encodable))
    #expect(!(intent.npmRootBinding as Any is any Encodable))

    let text = try #require(String(data: first, encoding: .utf8))
    #expect(!text.contains("\n"))
    #expect(text.first == "{")
    #expect(text.last == "}")
    #expect(text.hasPrefix("{\"candidateBinding\":"))
    #expect(text.contains("\"sourceComponents\":[\"X2NhY2FjaGU=\"]"))
    #expect(text.hasSuffix("\"version\":\"1\"}"))
  }

  @Test("Intent decoder rejects empty, oversized, and malformed documents")
  func intentRejectsInvalidDocumentEnvelope() throws {
    expectCodecError(.emptyDocument) {
      try QuarantineJournalV1Codec.decodeIntent(Data())
    }
    expectCodecError(.documentTooLarge) {
      try QuarantineJournalV1Codec.decodeIntent(
        Data(repeating: 0x20, count: QuarantineJournalV1Codec.maximumEncodedByteCount + 1)
      )
    }
    expectCodecError(.malformedDocument) {
      try QuarantineJournalV1Codec.decodeIntent(Data("{".utf8))
    }
  }

  @Test("Intent decoder rejects future schemas and versions")
  func intentRejectsFutureFormat() throws {
    let bytes = try QuarantineJournalV1Codec.encode(validIntent())
    let futureSchema = try replacingFirst(
      in: bytes,
      "devsift.quarantine-intent",
      with: "devsift.quarantine-future"
    )
    let futureVersion = try replacingFirst(
      in: bytes,
      "\"version\":\"1\"}",
      with: "\"version\":\"2\"}"
    )

    expectCodecError(.unsupportedSchema) {
      try QuarantineJournalV1Codec.decodeIntent(futureSchema)
    }
    expectCodecError(.unsupportedVersion) {
      try QuarantineJournalV1Codec.decodeIntent(futureVersion)
    }
  }

  @Test("Intent decoder rejects unknown and duplicate fields")
  func intentRejectsUnknownAndDuplicateFields() throws {
    let bytes = try QuarantineJournalV1Codec.encode(validIntent())
    let unknown = try insertingBeforeFinalBrace(
      in: bytes,
      fragment: ",\"unknown\":\"value\""
    )
    let duplicate = try insertingAfterOpeningBrace(
      in: bytes,
      fragment: "\"schema\":\"devsift.quarantine-intent\","
    )

    expectCodecError(.nonCanonicalDocument) {
      try QuarantineJournalV1Codec.decodeIntent(unknown)
    }
    expectCodecError(.nonCanonicalDocument) {
      try QuarantineJournalV1Codec.decodeIntent(duplicate)
    }
  }

  @Test("Intent decoder rejects JSON bytes that are not canonical")
  func intentRejectsNonCanonicalJSON() throws {
    let bytes = try QuarantineJournalV1Codec.encode(validIntent())
    var whitespace = Data([0x20])
    whitespace.append(bytes)

    expectCodecError(.nonCanonicalDocument) {
      try QuarantineJournalV1Codec.decodeIntent(whitespace)
    }
  }

  @Test("Intent decoder rejects invalid Base64 and noncanonical integers")
  func intentRejectsInvalidScalarEncoding() throws {
    let bytes = try QuarantineJournalV1Codec.encode(validIntent())
    let invalidBase64 = try replacingFirst(
      in: bytes,
      "\"X2NhY2FjaGU=\"",
      with: "\"not+base64***\""
    )
    let leadingZero = try replacingFirst(
      in: bytes,
      "\"device\":\"11\"",
      with: "\"device\":\"011\""
    )

    expectCodecError(.malformedDocument) {
      try QuarantineJournalV1Codec.decodeIntent(invalidBase64)
    }
    expectCodecError(.malformedDocument) {
      try QuarantineJournalV1Codec.decodeIntent(leadingZero)
    }
  }

  @Test("Intent rejects transaction, binding, source, and destination drift")
  func intentRejectsInvalidDomainRelationships() throws {
    let baseline = validIntent()
    let uppercaseTransaction = intent(
      from: baseline,
      transactionID: "00112233445566778899AABBCCDDEEFF"
    )
    let crossVolume = intent(
      from: baseline,
      quarantineRootBinding: binding(device: 12, inode: 101)
    )
    let wrongSource = intent(
      from: baseline,
      sourceComponents: [Array("cache".utf8)]
    )
    var duplicates = baseline.destinationComponents
    duplicates[15] = duplicates[0]
    let duplicateDestinations = intent(from: baseline, destinationComponents: duplicates)
    var unsafe = baseline.destinationComponents
    unsafe[0] = Array("item-v1-00112233445566778899AABBCCDDEEFF".utf8)
    let unsafeDestination = intent(from: baseline, destinationComponents: unsafe)

    expectCodecError(.invalidTransactionID) {
      try QuarantineJournalV1Codec.encode(uppercaseTransaction)
    }
    expectCodecError(.invalidBinding) {
      try QuarantineJournalV1Codec.encode(crossVolume)
    }
    expectCodecError(.invalidSourcePath) {
      try QuarantineJournalV1Codec.encode(wrongSource)
    }
    expectCodecError(.invalidDestinationPlan) {
      try QuarantineJournalV1Codec.encode(duplicateDestinations)
    }
    expectCodecError(.invalidDestinationPlan) {
      try QuarantineJournalV1Codec.encode(unsafeDestination)
    }
  }

  @Test("New intent rejects non-current policy and decode rejects unsupported policy")
  func intentRejectsPolicyDrift() throws {
    let baseline = validIntent()
    let driftedPolicy = QuarantineJournalPolicyV1(
      classification: QuarantineJournalPolicyV1.current.classification,
      catalog: QuarantineJournalPolicyRevisionV1(
        identifier: "devsift.builtin-rules",
        version: 7
      ),
      npmRule: QuarantineJournalPolicyV1.current.npmRule
    )
    let drifted = intent(from: baseline, policy: driftedPolicy)

    expectCodecError(.policyDrift) {
      try QuarantineJournalV1Codec.encode(drifted)
    }

    let bytes = try QuarantineJournalV1Codec.encode(baseline)
    let alteredBytes = try replacingFirst(
      in: bytes,
      "devsift.cache.npm",
      with: "devsift.cache.yarn"
    )
    expectCodecError(.policyDrift) {
      try QuarantineJournalV1Codec.decodeIntent(alteredBytes)
    }
  }

  @Test("Intent SHA-256 covers the exact canonical bytes")
  func exactIntentDigest() throws {
    let bytes = try QuarantineJournalV1Codec.encode(validIntent())
    let digest = try QuarantineJournalV1Codec.intentDigest(
      forCanonicalIntentBytes: bytes
    )

    #expect(digest.count == 32)
    #expect(
      hex(digest) == "fac4f5711c5aafc90fcab7cfb6d956dc29d682d4ba866b992f34e5c7bda016b4"
    )

    var noncanonical = bytes
    noncanonical.append(0x20)
    expectCodecError(.nonCanonicalDocument) {
      try QuarantineJournalV1Codec.intentDigest(forCanonicalIntentBytes: noncanonical)
    }
  }

  @Test("Quarantined receipt bytes round trip and match their exact intent")
  func receiptRoundTrip() throws {
    let intentBytes = try QuarantineJournalV1Codec.encode(validIntent())
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .quarantined,
      selectedDestinationOrdinal: 7,
      sourceNameWasRecreated: true,
      producedByRecovery: true,
      canonicalIntentBytes: intentBytes
    )

    let first = try QuarantineJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )
    let second = try QuarantineJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )

    #expect(first == second)
    #expect(
      try QuarantineJournalV1Codec.decodeReceipt(
        first,
        matchingIntentBytes: intentBytes
      ) == receipt
    )
    #expect(!(receipt as Any is any Encodable))
    let text = try #require(String(data: first, encoding: .utf8))
    #expect(text.hasPrefix("{\"destinationBinding\":"))
    #expect(text.hasSuffix("\"version\":\"1\"}"))
  }

  @Test("Not-moved and rolled-back receipts enforce terminal relationships")
  func receiptTerminalRelationships() throws {
    let intentBytes = try QuarantineJournalV1Codec.encode(validIntent())
    let intent = try QuarantineJournalV1Codec.decodeIntent(intentBytes)
    let digest = try QuarantineJournalV1Codec.intentDigest(
      forCanonicalIntentBytes: intentBytes
    )

    let notMoved = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: true,
      canonicalIntentBytes: intentBytes
    )
    #expect(
      try QuarantineJournalV1Codec.decodeReceipt(
        QuarantineJournalV1Codec.encode(notMoved),
        matchingIntentBytes: intentBytes
      ) == notMoved
    )

    let notMovedWithDestination = receipt(
      transactionID: intent.transactionID,
      digest: digest,
      outcome: .notMoved,
      ordinal: 0,
      destinationBinding: intent.candidateBinding
    )
    let quarantinedWithoutDestination = receipt(
      transactionID: intent.transactionID,
      digest: digest,
      outcome: .quarantined
    )
    let recoveredRollback = receipt(
      transactionID: intent.transactionID,
      digest: digest,
      outcome: .rolledBack,
      producedByRecovery: true
    )

    expectCodecError(.invalidReceiptRelationships) {
      try QuarantineJournalV1Codec.encode(notMovedWithDestination)
    }
    expectCodecError(.invalidReceiptRelationships) {
      try QuarantineJournalV1Codec.encode(quarantinedWithoutDestination)
    }
    expectCodecError(.invalidReceiptRelationships) {
      try QuarantineJournalV1Codec.encode(recoveredRollback)
    }
  }

  @Test("Receipt rejects malformed digest and intent mismatches")
  func receiptRejectsDigestAndIntentMismatch() throws {
    let intentBytes = try QuarantineJournalV1Codec.encode(validIntent())
    let intent = try QuarantineJournalV1Codec.decodeIntent(intentBytes)
    let validDigest = try QuarantineJournalV1Codec.intentDigest(
      forCanonicalIntentBytes: intentBytes
    )
    let shortDigest = receipt(
      transactionID: intent.transactionID,
      digest: [0],
      outcome: .notMoved
    )
    let wrongDigest = receipt(
      transactionID: intent.transactionID,
      digest: Array(repeating: 0xFF, count: 32),
      outcome: .notMoved
    )
    let wrongTransaction = receipt(
      transactionID: "ffeeddccbbaa99887766554433221100",
      digest: validDigest,
      outcome: .notMoved
    )

    expectCodecError(.invalidIntentDigest) {
      try QuarantineJournalV1Codec.encode(shortDigest)
    }
    expectCodecError(.receiptDoesNotMatchIntent) {
      try QuarantineJournalV1Codec.validate(
        wrongDigest,
        matching: intent,
        canonicalIntentBytes: intentBytes
      )
    }
    expectCodecError(.receiptDoesNotMatchIntent) {
      try QuarantineJournalV1Codec.validate(
        wrongTransaction,
        matching: intent,
        canonicalIntentBytes: intentBytes
      )
    }
  }

  @Test("Receipt decoder also rejects unknown, duplicate, and noncanonical fields")
  func receiptRejectsNonCanonicalRecords() throws {
    let intentBytes = try QuarantineJournalV1Codec.encode(validIntent())
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: intentBytes
    )
    let bytes = try QuarantineJournalV1Codec.encode(receipt)
    let unknown = try insertingBeforeFinalBrace(in: bytes, fragment: ",\"x\":false")
    let duplicate = try insertingAfterOpeningBrace(
      in: bytes,
      fragment: "\"schema\":\"devsift.quarantine-receipt\","
    )
    var whitespace = bytes
    whitespace.append(0x0A)

    for candidate in [unknown, duplicate, whitespace] {
      expectCodecError(.nonCanonicalDocument) {
        try QuarantineJournalV1Codec.decodeReceipt(candidate)
      }
    }
  }

  @Test("Receipt decoder rejects invalid Base64 and decimal strings")
  func receiptRejectsInvalidScalarEncoding() throws {
    let intentBytes = try QuarantineJournalV1Codec.encode(validIntent())
    let receipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .quarantined,
      selectedDestinationOrdinal: 1,
      producedByRecovery: false,
      canonicalIntentBytes: intentBytes
    )
    let bytes = try QuarantineJournalV1Codec.encode(receipt)
    let invalidBase64 = try replacingFirst(
      in: bytes,
      "\"intentDigest\":\"",
      with: "\"intentDigest\":\"***"
    )
    let leadingZero = try replacingFirst(
      in: bytes,
      "\"selectedDestinationOrdinal\":\"1\"",
      with: "\"selectedDestinationOrdinal\":\"01\""
    )

    expectCodecError(.malformedDocument) {
      try QuarantineJournalV1Codec.decodeReceipt(invalidBase64)
    }
    expectCodecError(.malformedDocument) {
      try QuarantineJournalV1Codec.decodeReceipt(leadingZero)
    }
  }
}

private func validIntent() -> QuarantineJournalIntentV1 {
  QuarantineJournalIntentV1(
    transactionID: "00112233445566778899aabbccddeeff",
    npmRootBinding: binding(device: 11, inode: 100),
    quarantineRootBinding: binding(device: 11, inode: 101),
    candidateBinding: binding(device: 11, inode: 102, linkCount: 5),
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<16).map(destinationComponent)
  )
}

private func binding(
  device: UInt64,
  inode: UInt64,
  linkCount: UInt64 = 3
) -> QuarantineJournalFileBindingV1 {
  QuarantineJournalFileBindingV1(
    device: device,
    inode: inode,
    generation: 7,
    birthSeconds: 1_725_000_000,
    birthNanoseconds: 123_456_789,
    kind: .directory,
    ownerUID: 501,
    permissionMode: 0o700,
    flags: 0,
    linkCount: linkCount
  )
}

private func destinationComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal, radix: 16)
  let padded = String(repeating: "0", count: 32 - suffix.count) + suffix
  return Array("item-v1-\(padded)".utf8)
}

private func intent(
  from baseline: QuarantineJournalIntentV1,
  transactionID: String? = nil,
  npmRootBinding: QuarantineJournalFileBindingV1? = nil,
  quarantineRootBinding: QuarantineJournalFileBindingV1? = nil,
  candidateBinding: QuarantineJournalFileBindingV1? = nil,
  sourceComponents: [[UInt8]]? = nil,
  destinationComponents: [[UInt8]]? = nil,
  policy: QuarantineJournalPolicyV1? = nil
) -> QuarantineJournalIntentV1 {
  QuarantineJournalIntentV1(
    transactionID: transactionID ?? baseline.transactionID,
    npmRootBinding: npmRootBinding ?? baseline.npmRootBinding,
    quarantineRootBinding: quarantineRootBinding ?? baseline.quarantineRootBinding,
    candidateBinding: candidateBinding ?? baseline.candidateBinding,
    sourceComponents: sourceComponents ?? baseline.sourceComponents,
    destinationComponents: destinationComponents ?? baseline.destinationComponents,
    policy: policy ?? baseline.policy
  )
}

private func receipt(
  transactionID: String,
  digest: [UInt8],
  outcome: QuarantineJournalReceiptOutcomeV1,
  ordinal: Int? = nil,
  destinationBinding: QuarantineJournalFileBindingV1? = nil,
  sourceNameWasRecreated: Bool = false,
  producedByRecovery: Bool = false
) -> QuarantineJournalReceiptV1 {
  QuarantineJournalReceiptV1(
    transactionID: transactionID,
    intentDigest: digest,
    outcome: outcome,
    selectedDestinationOrdinal: ordinal,
    destinationBinding: destinationBinding,
    sourceNameWasRecreated: sourceNameWasRecreated,
    producedByRecovery: producedByRecovery
  )
}

private func replacingFirst(
  in bytes: Data,
  _ target: String,
  with replacement: String
) throws -> Data {
  let text = try #require(String(data: bytes, encoding: .utf8))
  let range = try #require(text.range(of: target))
  return Data((text[..<range.lowerBound] + replacement + text[range.upperBound...]).utf8)
}

private func insertingBeforeFinalBrace(in bytes: Data, fragment: String) throws -> Data {
  let text = try #require(String(data: bytes, encoding: .utf8))
  #expect(text.last == "}")
  return Data((text.dropLast() + fragment + "}").utf8)
}

private func insertingAfterOpeningBrace(in bytes: Data, fragment: String) throws -> Data {
  let text = try #require(String(data: bytes, encoding: .utf8))
  #expect(text.first == "{")
  return Data(("{" + fragment + text.dropFirst()).utf8)
}

private func expectCodecError<Value>(
  _ expected: QuarantineJournalCodecError,
  performing operation: () throws -> Value
) {
  do {
    _ = try operation()
    Issue.record("Expected quarantine journal codec error \(expected)")
  } catch let error as QuarantineJournalCodecError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
}

private func hex(_ bytes: [UInt8]) -> String {
  bytes.map { String(format: "%02x", $0) }.joined()
}
