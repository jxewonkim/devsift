import CryptoKit
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Quarantine purge journal v1 canonical codec")
struct QuarantinePurgeJournalV1Tests {
  @Test("Purge intent derives exact record, component, binding, and capacity values")
  func intentDerivationAndRoundTrip() throws {
    let pair = try validPurgeQuarantinePair(selectedDestinationOrdinal: 7)
    let capacityBefore = purgeCapacity(availableBytes: 8_192)
    let intent = try QuarantinePurgeJournalV1Codec.makeIntent(
      purgeTransactionID: purgeTransactionID,
      capacityBefore: capacityBefore,
      canonicalQuarantineIntentBytes: pair.intentBytes,
      canonicalQuarantineReceiptBytes: pair.receiptBytes
    )

    let first = try QuarantinePurgeJournalV1Codec.encode(
      intent,
      matchingQuarantineIntentBytes: pair.intentBytes,
      matchingQuarantineReceiptBytes: pair.receiptBytes
    )
    let second = try QuarantinePurgeJournalV1Codec.encode(intent)

    #expect(first == second)
    #expect(try QuarantinePurgeJournalV1Codec.decodeIntent(first) == intent)
    #expect(
      try QuarantinePurgeJournalV1Codec.decodeIntent(
        first,
        matchingQuarantineIntentBytes: pair.intentBytes,
        matchingQuarantineReceiptBytes: pair.receiptBytes
      ) == intent
    )
    #expect(intent.purgeTransactionID == purgeTransactionID)
    #expect(intent.quarantineTransactionID == pair.intent.transactionID)
    #expect(intent.quarantineIntentDigest == purgeTestDigest(pair.intentBytes))
    #expect(intent.quarantineReceiptDigest == purgeTestDigest(pair.receiptBytes))
    #expect(intent.npmRootBinding == pair.intent.npmRootBinding)
    #expect(intent.quarantineRootBinding == pair.intent.quarantineRootBinding)
    #expect(intent.candidateBinding == pair.intent.candidateBinding)
    #expect(intent.sourceComponents == pair.intent.sourceComponents)
    #expect(intent.quarantineItemComponent == pair.intent.destinationComponents[7])
    #expect(
      intent.purgeWorkComponent
        == Array(".purge-work-v1-\(purgeTransactionID)".utf8)
    )
    #expect(intent.capacityBefore == capacityBefore)
    #expect(intent.resourceBounds == .current)
    #expect(intent.resourceBounds.maximumEntries == 1_000_000)
    #expect(intent.resourceBounds.maximumDepth == 32)
    #expect(intent.resourceBounds.maximumEntriesPerDirectory == 100_000)
    #expect(intent.resourceBounds.maximumRawNameBytes == 64 * 1_024 * 1_024)
    #expect(intent.resourceBounds.maximumInterruptedSystemCallAttempts == 3)
    #expect(intent.resourceBounds.maximumSynchronizationOperations == 1_000_002)
    #expect(
      intent.purgePolicyRevision
        == QuarantinePurgeJournalIntentV1.currentPurgePolicyRevision
    )
    #expect(first.count < QuarantinePurgeJournalV1Codec.maximumEncodedByteCount)
    #expect(!(intent as Any is any Encodable))
    #expect(!(capacityBefore as Any is any Encodable))
    #expect(!(intent.resourceBounds as Any is any Encodable))

    let text = try #require(String(data: first, encoding: .utf8))
    #expect(!text.contains("\n"))
    #expect(text.hasPrefix("{\"candidateBinding\":"))
    #expect(text.contains("\"sourceComponents\":[\"X2NhY2FjaGU=\"]"))
    #expect(text.contains("\"fileSystemIDFirst\":\"-7\""))
    #expect(text.hasSuffix("\"version\":\"1\"}"))
  }

  @Test("Purge intent requires one canonical matching quarantined receipt")
  func intentRejectsInvalidOriginalPair() throws {
    let pair = try validPurgeQuarantinePair(selectedDestinationOrdinal: 3)
    let notMovedReceipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .notMoved,
      producedByRecovery: false,
      canonicalIntentBytes: pair.intentBytes
    )
    let notMovedBytes = try QuarantineJournalV1Codec.encode(
      notMovedReceipt,
      matchingIntentBytes: pair.intentBytes
    )
    let otherPair = try validPurgeQuarantinePair(
      quarantineTransactionID: String(repeating: "c", count: 32),
      selectedDestinationOrdinal: 3
    )
    var noncanonicalIntentBytes = pair.intentBytes
    noncanonicalIntentBytes.append(0x20)

    expectPurgeCodecError(.quarantineReceiptNotPurgeable) {
      try QuarantinePurgeJournalV1Codec.makeIntent(
        purgeTransactionID: purgeTransactionID,
        capacityBefore: purgeCapacity(),
        canonicalQuarantineIntentBytes: pair.intentBytes,
        canonicalQuarantineReceiptBytes: notMovedBytes
      )
    }
    expectPurgeCodecError(.invalidQuarantineRecordPair) {
      try QuarantinePurgeJournalV1Codec.makeIntent(
        purgeTransactionID: purgeTransactionID,
        capacityBefore: purgeCapacity(),
        canonicalQuarantineIntentBytes: pair.intentBytes,
        canonicalQuarantineReceiptBytes: otherPair.receiptBytes
      )
    }
    expectPurgeCodecError(.invalidQuarantineRecordPair) {
      try QuarantinePurgeJournalV1Codec.makeIntent(
        purgeTransactionID: purgeTransactionID,
        capacityBefore: purgeCapacity(),
        canonicalQuarantineIntentBytes: noncanonicalIntentBytes,
        canonicalQuarantineReceiptBytes: pair.receiptBytes
      )
    }
  }

  @Test("Purge intent exact-pair validation detects record and digest drift")
  func intentRejectsExactOriginalRecordDrift() throws {
    let pair = try validPurgeQuarantinePair(selectedDestinationOrdinal: 5)
    let intent = try purgeIntent(from: pair)
    let alteredReceipt = try QuarantineJournalV1Codec.makeReceipt(
      outcome: .quarantined,
      selectedDestinationOrdinal: 6,
      producedByRecovery: true,
      canonicalIntentBytes: pair.intentBytes
    )
    let alteredReceiptBytes = try QuarantineJournalV1Codec.encode(
      alteredReceipt,
      matchingIntentBytes: pair.intentBytes
    )
    let driftedDigest = copyPurgeIntent(
      intent,
      quarantineReceiptDigest: Array(repeating: 0xFF, count: SHA256.byteCount)
    )

    expectPurgeCodecError(.invalidQuarantineRecordPair) {
      try QuarantinePurgeJournalV1Codec.validate(
        intent,
        canonicalQuarantineIntentBytes: pair.intentBytes,
        canonicalQuarantineReceiptBytes: alteredReceiptBytes
      )
    }
    expectPurgeCodecError(.invalidQuarantineRecordPair) {
      try QuarantinePurgeJournalV1Codec.encode(
        driftedDigest,
        matchingQuarantineIntentBytes: pair.intentBytes,
        matchingQuarantineReceiptBytes: pair.receiptBytes
      )
    }
  }

  @Test("Intent decoder rejects empty, oversized, and malformed documents")
  func intentRejectsInvalidDocumentEnvelope() {
    expectPurgeCodecError(.emptyDocument) {
      try QuarantinePurgeJournalV1Codec.decodeIntent(Data())
    }
    expectPurgeCodecError(.documentTooLarge) {
      try QuarantinePurgeJournalV1Codec.decodeIntent(
        Data(
          repeating: 0x20,
          count: QuarantinePurgeJournalV1Codec.maximumEncodedByteCount + 1
        )
      )
    }
    expectPurgeCodecError(.malformedDocument) {
      try QuarantinePurgeJournalV1Codec.decodeIntent(Data("{".utf8))
    }
  }

  @Test("Intent decoder rejects unknown formats and noncanonical JSON")
  func intentRejectsFormatAndCanonicalityDrift() throws {
    let pair = try validPurgeQuarantinePair()
    let bytes = try QuarantinePurgeJournalV1Codec.encode(purgeIntent(from: pair))
    let futureSchema = try purgeReplacingFirst(
      in: bytes,
      "devsift.quarantine-purge-intent",
      with: "devsift.quarantine-purge-future"
    )
    let futureVersion = try purgeReplacingFirst(
      in: bytes,
      "\"version\":\"1\"}",
      with: "\"version\":\"2\"}"
    )
    let unknown = try purgeInsertingBeforeFinalBrace(
      in: bytes,
      fragment: ",\"unknown\":\"value\""
    )
    let duplicate = try purgeInsertingAfterOpeningBrace(
      in: bytes,
      fragment: "\"schema\":\"devsift.quarantine-purge-intent\","
    )
    var leadingWhitespace = Data([0x20])
    leadingWhitespace.append(bytes)

    expectPurgeCodecError(.unsupportedSchema) {
      try QuarantinePurgeJournalV1Codec.decodeIntent(futureSchema)
    }
    expectPurgeCodecError(.unsupportedVersion) {
      try QuarantinePurgeJournalV1Codec.decodeIntent(futureVersion)
    }
    for candidate in [unknown, duplicate, leadingWhitespace] {
      expectPurgeCodecError(.nonCanonicalDocument) {
        try QuarantinePurgeJournalV1Codec.decodeIntent(candidate)
      }
    }
  }

  @Test("Intent decoder rejects noncanonical Base64 and decimal strings")
  func intentRejectsInvalidScalarEncoding() throws {
    let pair = try validPurgeQuarantinePair()
    let bytes = try QuarantinePurgeJournalV1Codec.encode(purgeIntent(from: pair))
    let invalidBase64 = try purgeReplacingFirst(
      in: bytes,
      "\"sourceComponents\":[\"X2NhY2FjaGU=\"]",
      with: "\"sourceComponents\":[\"***\"]"
    )
    let leadingZero = try purgeReplacingFirst(
      in: bytes,
      "\"purgePolicyRevision\":\"1\"",
      with: "\"purgePolicyRevision\":\"01\""
    )
    let signedLeadingZero = try purgeReplacingFirst(
      in: bytes,
      "\"fileSystemIDFirst\":\"-7\"",
      with: "\"fileSystemIDFirst\":\"-07\""
    )

    for candidate in [invalidBase64, leadingZero, signedLeadingZero] {
      expectPurgeCodecError(.malformedDocument) {
        try QuarantinePurgeJournalV1Codec.decodeIntent(candidate)
      }
    }
  }

  @Test("Intent rejects identifier, binding, component, policy, and capacity drift")
  func intentRejectsInvalidDomainRelationships() throws {
    let pair = try validPurgeQuarantinePair()
    let baseline = try purgeIntent(from: pair)

    expectPurgeCodecError(.invalidPurgeTransactionID) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeIntent(
          baseline,
          purgeTransactionID: "ffeeddccbbaa998877665544332211GG"
        )
      )
    }
    expectPurgeCodecError(.invalidQuarantineTransactionID) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeIntent(
          baseline,
          quarantineTransactionID: baseline.purgeTransactionID
        )
      )
    }
    expectPurgeCodecError(.invalidDigest) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeIntent(baseline, quarantineIntentDigest: [0])
      )
    }
    expectPurgeCodecError(.invalidBinding) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeIntent(
          baseline,
          quarantineRootBinding: purgeBinding(device: 12, inode: 101)
        )
      )
    }
    expectPurgeCodecError(.invalidSourcePath) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeIntent(baseline, sourceComponents: [Array("cache".utf8)])
      )
    }
    expectPurgeCodecError(.invalidQuarantineItem) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeIntent(
          baseline,
          quarantineItemComponent: Array(
            "item-v1-00112233445566778899AABBCCDDEEFF".utf8
          )
        )
      )
    }
    expectPurgeCodecError(.invalidPurgeWorkItem) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeIntent(
          baseline,
          purgeWorkComponent: Array(".purge-work-v1-other".utf8)
        )
      )
    }
    expectPurgeCodecError(.invalidCapacityObservation) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeIntent(
          baseline,
          capacityBefore: purgeCapacity(device: 12)
        )
      )
    }
    expectPurgeCodecError(.resourceBoundsDrift) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeIntent(
          baseline,
          resourceBounds: QuarantinePurgeJournalResourceBoundsV1(
            maximumEntries: 1_000_001,
            maximumDepth: 32,
            maximumEntriesPerDirectory: 100_000,
            maximumRawNameBytes: 64 * 1_024 * 1_024,
            maximumInterruptedSystemCallAttempts: 3,
            maximumSynchronizationOperations: 1_000_003
          )
        )
      )
    }
    expectPurgeCodecError(.policyDrift) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeIntent(baseline, purgePolicyRevision: 0)
      )
    }
    expectPurgeCodecError(.policyDrift) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeIntent(baseline, purgePolicyRevision: 2)
      )
    }
  }

  @Test("Intent decode rejects zero and future purge policy revisions")
  func intentDecodeRejectsUnsupportedPolicy() throws {
    let pair = try validPurgeQuarantinePair()
    let bytes = try QuarantinePurgeJournalV1Codec.encode(purgeIntent(from: pair))
    let zero = try purgeReplacingFirst(
      in: bytes,
      "\"purgePolicyRevision\":\"1\"",
      with: "\"purgePolicyRevision\":\"0\""
    )
    let future = try purgeReplacingFirst(
      in: bytes,
      "\"purgePolicyRevision\":\"1\"",
      with: "\"purgePolicyRevision\":\"2\""
    )

    expectPurgeCodecError(.policyDrift) {
      try QuarantinePurgeJournalV1Codec.decodeIntent(zero)
    }
    expectPurgeCodecError(.policyDrift) {
      try QuarantinePurgeJournalV1Codec.decodeIntent(future)
    }
  }

  @Test("Intent decode rejects zero and future aggregate resource bounds")
  func intentDecodeRejectsUnsupportedResourceBounds() throws {
    let pair = try validPurgeQuarantinePair()
    let bytes = try QuarantinePurgeJournalV1Codec.encode(purgeIntent(from: pair))
    let zero = try purgeReplacingFirst(
      in: bytes,
      "\"maximumDepth\":\"32\"",
      with: "\"maximumDepth\":\"0\""
    )
    let future = try purgeReplacingFirst(
      in: bytes,
      "\"maximumEntries\":\"1000000\"",
      with: "\"maximumEntries\":\"1000001\""
    )
    let invalidSynchronizationRelationship = try purgeReplacingFirst(
      in: bytes,
      "\"maximumSynchronizationOperations\":\"1000002\"",
      with: "\"maximumSynchronizationOperations\":\"1000001\""
    )
    let futureInterruptedAttemptBound = try purgeReplacingFirst(
      in: bytes,
      "\"maximumInterruptedSystemCallAttempts\":\"3\"",
      with: "\"maximumInterruptedSystemCallAttempts\":\"4\""
    )

    for candidate in [
      zero,
      future,
      invalidSynchronizationRelationship,
      futureInterruptedAttemptBound,
    ] {
      expectPurgeCodecError(.resourceBoundsDrift) {
        try QuarantinePurgeJournalV1Codec.decodeIntent(candidate)
      }
    }
  }

  @Test("Purge intent SHA-256 covers the exact canonical bytes")
  func exactPurgeIntentDigest() throws {
    let pair = try validPurgeQuarantinePair()
    let bytes = try QuarantinePurgeJournalV1Codec.encode(purgeIntent(from: pair))
    let digest = try QuarantinePurgeJournalV1Codec.purgeIntentDigest(
      forCanonicalIntentBytes: bytes
    )

    #expect(digest == purgeTestDigest(bytes))
    #expect(digest.count == SHA256.byteCount)

    var noncanonical = bytes
    noncanonical.append(0x20)
    expectPurgeCodecError(.nonCanonicalDocument) {
      try QuarantinePurgeJournalV1Codec.purgeIntentDigest(
        forCanonicalIntentBytes: noncanonical
      )
    }
  }

  @Test("Item-absent receipt round trips with same-volume raw capacity evidence")
  func itemAbsentReceiptRoundTrip() throws {
    let pair = try validPurgeQuarantinePair()
    let intentBytes = try QuarantinePurgeJournalV1Codec.encode(purgeIntent(from: pair))
    let capacityAfter = purgeCapacity(availableBytes: 12_288)
    let receipt = try QuarantinePurgeJournalV1Codec.makeReceipt(
      outcome: .itemAbsent,
      quarantineNameWasRecreated: true,
      producedByRecovery: false,
      capacityObservationProvenance: .initialAttempt,
      capacityAfter: .available(capacityAfter),
      canonicalPurgeIntentBytes: intentBytes
    )

    let first = try QuarantinePurgeJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )
    let second = try QuarantinePurgeJournalV1Codec.encode(receipt)

    #expect(first == second)
    #expect(
      try QuarantinePurgeJournalV1Codec.decodeReceipt(
        first,
        matchingIntentBytes: intentBytes
      ) == receipt
    )
    #expect(receipt.purgeIntentDigest == purgeTestDigest(intentBytes))
    #expect(receipt.quarantineNameWasRecreated)
    #expect(!receipt.producedByRecovery)
    #expect(receipt.capacityObservationProvenance == .initialAttempt)
    #expect(receipt.capacityAfter == .available(capacityAfter))
    #expect(!(receipt as Any is any Encodable))

    let text = try #require(String(data: first, encoding: .utf8))
    #expect(text.hasPrefix("{\"capacityAfter\":"))
    #expect(text.contains("\"outcome\":\"item-absent\""))
    #expect(text.hasSuffix("\"version\":\"1\"}"))
  }

  @Test("Unavailable post-capacity remains explicit on a recovered not-purged receipt")
  func unavailableCapacityRoundTrip() throws {
    let pair = try validPurgeQuarantinePair()
    let intentBytes = try QuarantinePurgeJournalV1Codec.encode(purgeIntent(from: pair))
    let receipt = try QuarantinePurgeJournalV1Codec.makeReceipt(
      outcome: .notPurged,
      producedByRecovery: true,
      capacityObservationProvenance: .recovery,
      capacityAfter: .unavailable,
      canonicalPurgeIntentBytes: intentBytes
    )
    let bytes = try QuarantinePurgeJournalV1Codec.encode(
      receipt,
      matchingIntentBytes: intentBytes
    )

    #expect(
      try QuarantinePurgeJournalV1Codec.decodeReceipt(
        bytes,
        matchingIntentBytes: intentBytes
      ) == receipt
    )
    let text = try #require(String(data: bytes, encoding: .utf8))
    #expect(!text.contains("\"capacityAfter\":"))
    #expect(text.contains("\"capacityAfterStatus\":\"unavailable\""))
  }

  @Test("Receipt rejects impossible outcome, retry, and recovery relationships")
  func receiptRejectsInvalidRelationships() throws {
    let pair = try validPurgeQuarantinePair()
    let intentBytes = try QuarantinePurgeJournalV1Codec.encode(purgeIntent(from: pair))
    let baseline = try QuarantinePurgeJournalV1Codec.makeReceipt(
      outcome: .notPurged,
      producedByRecovery: false,
      capacityObservationProvenance: .initialAttempt,
      capacityAfter: .unavailable,
      canonicalPurgeIntentBytes: intentBytes
    )

    expectPurgeCodecError(.invalidReceiptRelationships) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeReceipt(baseline, quarantineNameWasRecreated: true)
      )
    }
    expectPurgeCodecError(.invalidReceiptRelationships) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeReceipt(baseline, capacityObservationProvenance: .explicitRetry)
      )
    }
    expectPurgeCodecError(.invalidReceiptRelationships) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeReceipt(baseline, producedByRecovery: true)
      )
    }
    expectPurgeCodecError(.invalidReceiptRelationships) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeReceipt(
          baseline,
          outcome: .itemAbsent,
          capacityObservationProvenance: .recovery
        )
      )
    }

    let retry = copyPurgeReceipt(
      baseline,
      outcome: .itemAbsent,
      capacityObservationProvenance: .explicitRetry
    )
    #expect(
      try QuarantinePurgeJournalV1Codec.decodeReceipt(
        QuarantinePurgeJournalV1Codec.encode(retry)
      ) == retry)
  }

  @Test("Receipt binds its exact intent and the same observed volume")
  func receiptRejectsIntentAndVolumeMismatch() throws {
    let pair = try validPurgeQuarantinePair()
    let intent = try purgeIntent(from: pair)
    let intentBytes = try QuarantinePurgeJournalV1Codec.encode(intent)
    let valid = try QuarantinePurgeJournalV1Codec.makeReceipt(
      outcome: .itemAbsent,
      producedByRecovery: false,
      capacityObservationProvenance: .initialAttempt,
      capacityAfter: .available(purgeCapacity(availableBytes: 16_384)),
      canonicalPurgeIntentBytes: intentBytes
    )

    expectPurgeCodecError(.invalidDigest) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeReceipt(valid, purgeIntentDigest: [0])
      )
    }
    expectPurgeCodecError(.receiptDoesNotMatchIntent) {
      try QuarantinePurgeJournalV1Codec.validate(
        copyPurgeReceipt(
          valid,
          purgeTransactionID: String(repeating: "d", count: 32)
        ),
        matching: intent,
        canonicalIntentBytes: intentBytes
      )
    }
    expectPurgeCodecError(.receiptDoesNotMatchIntent) {
      try QuarantinePurgeJournalV1Codec.validate(
        copyPurgeReceipt(
          valid,
          purgeIntentDigest: Array(repeating: 0xFF, count: SHA256.byteCount)
        ),
        matching: intent,
        canonicalIntentBytes: intentBytes
      )
    }
    expectPurgeCodecError(.invalidCapacityObservation) {
      try QuarantinePurgeJournalV1Codec.encode(
        copyPurgeReceipt(
          valid,
          capacityAfter: .available(purgeCapacity(fileSystemIDSecond: 10))
        ),
        matchingIntentBytes: intentBytes
      )
    }
  }

  @Test("Receipt decoder rejects invalid envelopes and future relationships")
  func receiptRejectsInvalidEnvelopeAndFormat() throws {
    let pair = try validPurgeQuarantinePair()
    let intentBytes = try QuarantinePurgeJournalV1Codec.encode(purgeIntent(from: pair))
    let receipt = try QuarantinePurgeJournalV1Codec.makeReceipt(
      outcome: .itemAbsent,
      producedByRecovery: false,
      capacityObservationProvenance: .initialAttempt,
      capacityAfter: .available(purgeCapacity()),
      canonicalPurgeIntentBytes: intentBytes
    )
    let bytes = try QuarantinePurgeJournalV1Codec.encode(receipt)
    let futureSchema = try purgeReplacingFirst(
      in: bytes,
      "devsift.quarantine-purge-receipt",
      with: "devsift.quarantine-purge-future"
    )
    let futureVersion = try purgeReplacingFirst(
      in: bytes,
      "\"version\":\"1\"}",
      with: "\"version\":\"2\"}"
    )
    let futureOutcome = try purgeReplacingFirst(
      in: bytes,
      "\"outcome\":\"item-absent\"",
      with: "\"outcome\":\"future\""
    )
    let futureProvenance = try purgeReplacingFirst(
      in: bytes,
      "\"capacityObservationProvenance\":\"initial-attempt\"",
      with: "\"capacityObservationProvenance\":\"future\""
    )
    let futureCapacityStatus = try purgeReplacingFirst(
      in: bytes,
      "\"capacityAfterStatus\":\"available\"",
      with: "\"capacityAfterStatus\":\"future\""
    )

    expectPurgeCodecError(.emptyDocument) {
      try QuarantinePurgeJournalV1Codec.decodeReceipt(Data())
    }
    expectPurgeCodecError(.documentTooLarge) {
      try QuarantinePurgeJournalV1Codec.decodeReceipt(
        Data(
          repeating: 0x20,
          count: QuarantinePurgeJournalV1Codec.maximumEncodedByteCount + 1
        )
      )
    }
    expectPurgeCodecError(.malformedDocument) {
      try QuarantinePurgeJournalV1Codec.decodeReceipt(Data("{".utf8))
    }
    expectPurgeCodecError(.unsupportedSchema) {
      try QuarantinePurgeJournalV1Codec.decodeReceipt(futureSchema)
    }
    expectPurgeCodecError(.unsupportedVersion) {
      try QuarantinePurgeJournalV1Codec.decodeReceipt(futureVersion)
    }
    for candidate in [futureOutcome, futureProvenance] {
      expectPurgeCodecError(.invalidReceiptRelationships) {
        try QuarantinePurgeJournalV1Codec.decodeReceipt(candidate)
      }
    }
    expectPurgeCodecError(.invalidCapacityObservation) {
      try QuarantinePurgeJournalV1Codec.decodeReceipt(futureCapacityStatus)
    }
  }

  @Test("Receipt decoder rejects unknown, duplicate, scalar, and whitespace drift")
  func receiptRejectsNonCanonicalRecords() throws {
    let pair = try validPurgeQuarantinePair()
    let intentBytes = try QuarantinePurgeJournalV1Codec.encode(purgeIntent(from: pair))
    let receipt = try QuarantinePurgeJournalV1Codec.makeReceipt(
      outcome: .notPurged,
      producedByRecovery: true,
      capacityObservationProvenance: .recovery,
      capacityAfter: .unavailable,
      canonicalPurgeIntentBytes: intentBytes
    )
    let bytes = try QuarantinePurgeJournalV1Codec.encode(receipt)
    let unknown = try purgeInsertingBeforeFinalBrace(
      in: bytes,
      fragment: ",\"x\":false"
    )
    let duplicate = try purgeInsertingAfterOpeningBrace(
      in: bytes,
      fragment: "\"schema\":\"devsift.quarantine-purge-receipt\","
    )
    let invalidBase64 = try purgeReplacingFirst(
      in: bytes,
      "\"purgeIntentDigest\":\"",
      with: "\"purgeIntentDigest\":\"***"
    )
    var whitespace = bytes
    whitespace.append(0x0A)

    for candidate in [unknown, duplicate, whitespace] {
      expectPurgeCodecError(.nonCanonicalDocument) {
        try QuarantinePurgeJournalV1Codec.decodeReceipt(candidate)
      }
    }
    expectPurgeCodecError(.malformedDocument) {
      try QuarantinePurgeJournalV1Codec.decodeReceipt(invalidBase64)
    }
  }

  @Test("Receipt capacity status and payload must agree")
  func receiptRejectsCapacityAvailabilityDrift() throws {
    let pair = try validPurgeQuarantinePair()
    let intentBytes = try QuarantinePurgeJournalV1Codec.encode(purgeIntent(from: pair))
    let available = try QuarantinePurgeJournalV1Codec.makeReceipt(
      outcome: .itemAbsent,
      producedByRecovery: false,
      capacityObservationProvenance: .initialAttempt,
      capacityAfter: .available(purgeCapacity()),
      canonicalPurgeIntentBytes: intentBytes
    )
    let availableBytes = try QuarantinePurgeJournalV1Codec.encode(available)
    let unavailable = try QuarantinePurgeJournalV1Codec.makeReceipt(
      outcome: .itemAbsent,
      producedByRecovery: false,
      capacityObservationProvenance: .explicitRetry,
      capacityAfter: .unavailable,
      canonicalPurgeIntentBytes: intentBytes
    )
    let unavailableBytes = try QuarantinePurgeJournalV1Codec.encode(unavailable)
    let payloadWhenUnavailable = try purgeReplacingFirst(
      in: availableBytes,
      "\"capacityAfterStatus\":\"available\"",
      with: "\"capacityAfterStatus\":\"unavailable\""
    )
    let missingPayloadWhenAvailable = try purgeReplacingFirst(
      in: unavailableBytes,
      "\"capacityAfterStatus\":\"unavailable\"",
      with: "\"capacityAfterStatus\":\"available\""
    )

    for candidate in [payloadWhenUnavailable, missingPayloadWhenAvailable] {
      expectPurgeCodecError(.invalidCapacityObservation) {
        try QuarantinePurgeJournalV1Codec.decodeReceipt(candidate)
      }
    }
  }
}

private let purgeTransactionID = "ffeeddccbbaa99887766554433221100"

private struct PurgeQuarantinePair {
  let intent: QuarantineJournalIntentV1
  let intentBytes: Data
  let receiptBytes: Data
}

private func validPurgeQuarantinePair(
  quarantineTransactionID: String = "00112233445566778899aabbccddeeff",
  selectedDestinationOrdinal: Int = 7
) throws -> PurgeQuarantinePair {
  let intent = QuarantineJournalIntentV1(
    transactionID: quarantineTransactionID,
    npmRootBinding: purgeBinding(device: 11, inode: 100),
    quarantineRootBinding: purgeBinding(device: 11, inode: 101),
    candidateBinding: purgeBinding(device: 11, inode: 102, linkCount: 5),
    sourceComponents: [Array("_cacache".utf8)],
    destinationComponents: (0..<16).map(purgeDestinationComponent)
  )
  let intentBytes = try QuarantineJournalV1Codec.encode(intent)
  let receipt = try QuarantineJournalV1Codec.makeReceipt(
    outcome: .quarantined,
    selectedDestinationOrdinal: selectedDestinationOrdinal,
    producedByRecovery: false,
    canonicalIntentBytes: intentBytes
  )
  let receiptBytes = try QuarantineJournalV1Codec.encode(
    receipt,
    matchingIntentBytes: intentBytes
  )
  return PurgeQuarantinePair(
    intent: intent,
    intentBytes: intentBytes,
    receiptBytes: receiptBytes
  )
}

private func purgeIntent(
  from pair: PurgeQuarantinePair,
  capacityBefore: QuarantinePurgeCapacityObservationV1 = purgeCapacity()
) throws -> QuarantinePurgeJournalIntentV1 {
  try QuarantinePurgeJournalV1Codec.makeIntent(
    purgeTransactionID: purgeTransactionID,
    capacityBefore: capacityBefore,
    canonicalQuarantineIntentBytes: pair.intentBytes,
    canonicalQuarantineReceiptBytes: pair.receiptBytes
  )
}

private func purgeCapacity(
  device: UInt64 = 11,
  fileSystemIDFirst: Int32 = -7,
  fileSystemIDSecond: Int32 = 9,
  availableBytes: UInt64 = 4_096
) -> QuarantinePurgeCapacityObservationV1 {
  QuarantinePurgeCapacityObservationV1(
    volumeIdentity: QuarantinePurgeVolumeIdentityV1(
      device: device,
      fileSystemIDFirst: fileSystemIDFirst,
      fileSystemIDSecond: fileSystemIDSecond
    ),
    availableBytes: availableBytes
  )
}

private func purgeBinding(
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

private func purgeDestinationComponent(_ ordinal: Int) -> [UInt8] {
  let suffix = String(ordinal, radix: 16)
  let padded = String(repeating: "0", count: 32 - suffix.count) + suffix
  return Array("item-v1-\(padded)".utf8)
}

private func copyPurgeIntent(
  _ baseline: QuarantinePurgeJournalIntentV1,
  purgeTransactionID: String? = nil,
  quarantineTransactionID: String? = nil,
  quarantineIntentDigest: [UInt8]? = nil,
  quarantineReceiptDigest: [UInt8]? = nil,
  npmRootBinding: QuarantineJournalFileBindingV1? = nil,
  quarantineRootBinding: QuarantineJournalFileBindingV1? = nil,
  candidateBinding: QuarantineJournalFileBindingV1? = nil,
  sourceComponents: [[UInt8]]? = nil,
  quarantineItemComponent: [UInt8]? = nil,
  purgeWorkComponent: [UInt8]? = nil,
  purgePolicyRevision: UInt32? = nil,
  resourceBounds: QuarantinePurgeJournalResourceBoundsV1? = nil,
  capacityBefore: QuarantinePurgeCapacityObservationV1? = nil
) -> QuarantinePurgeJournalIntentV1 {
  QuarantinePurgeJournalIntentV1(
    purgeTransactionID: purgeTransactionID ?? baseline.purgeTransactionID,
    quarantineTransactionID: quarantineTransactionID ?? baseline.quarantineTransactionID,
    quarantineIntentDigest: quarantineIntentDigest ?? baseline.quarantineIntentDigest,
    quarantineReceiptDigest: quarantineReceiptDigest ?? baseline.quarantineReceiptDigest,
    npmRootBinding: npmRootBinding ?? baseline.npmRootBinding,
    quarantineRootBinding: quarantineRootBinding ?? baseline.quarantineRootBinding,
    candidateBinding: candidateBinding ?? baseline.candidateBinding,
    sourceComponents: sourceComponents ?? baseline.sourceComponents,
    quarantineItemComponent: quarantineItemComponent ?? baseline.quarantineItemComponent,
    purgeWorkComponent: purgeWorkComponent ?? baseline.purgeWorkComponent,
    purgePolicyRevision: purgePolicyRevision ?? baseline.purgePolicyRevision,
    resourceBounds: resourceBounds ?? baseline.resourceBounds,
    capacityBefore: capacityBefore ?? baseline.capacityBefore
  )
}

private func copyPurgeReceipt(
  _ baseline: QuarantinePurgeJournalReceiptV1,
  purgeTransactionID: String? = nil,
  purgeIntentDigest: [UInt8]? = nil,
  outcome: QuarantinePurgeJournalReceiptOutcomeV1? = nil,
  quarantineNameWasRecreated: Bool? = nil,
  producedByRecovery: Bool? = nil,
  capacityObservationProvenance:
    QuarantinePurgeCapacityObservationProvenanceV1? = nil,
  capacityAfter: QuarantinePurgePostCapacityObservationV1? = nil
) -> QuarantinePurgeJournalReceiptV1 {
  QuarantinePurgeJournalReceiptV1(
    purgeTransactionID: purgeTransactionID ?? baseline.purgeTransactionID,
    purgeIntentDigest: purgeIntentDigest ?? baseline.purgeIntentDigest,
    outcome: outcome ?? baseline.outcome,
    quarantineNameWasRecreated: quarantineNameWasRecreated
      ?? baseline.quarantineNameWasRecreated,
    producedByRecovery: producedByRecovery ?? baseline.producedByRecovery,
    capacityObservationProvenance: capacityObservationProvenance
      ?? baseline.capacityObservationProvenance,
    capacityAfter: capacityAfter ?? baseline.capacityAfter
  )
}

private func purgeTestDigest(_ bytes: Data) -> [UInt8] {
  Array(SHA256.hash(data: bytes))
}

private func purgeReplacingFirst(
  in bytes: Data,
  _ target: String,
  with replacement: String
) throws -> Data {
  let text = try #require(String(data: bytes, encoding: .utf8))
  let range = try #require(text.range(of: target))
  let prefix = String(text[..<range.lowerBound])
  let suffix = String(text[range.upperBound...])
  return Data((prefix + replacement + suffix).utf8)
}

private func purgeInsertingBeforeFinalBrace(
  in bytes: Data,
  fragment: String
) throws -> Data {
  let text = try #require(String(data: bytes, encoding: .utf8))
  #expect(text.last == "}")
  return Data((String(text.dropLast()) + fragment + "}").utf8)
}

private func purgeInsertingAfterOpeningBrace(
  in bytes: Data,
  fragment: String
) throws -> Data {
  let text = try #require(String(data: bytes, encoding: .utf8))
  #expect(text.first == "{")
  return Data(("{" + fragment + text.dropFirst()).utf8)
}

private func expectPurgeCodecError<Value>(
  _ expected: QuarantinePurgeJournalCodecError,
  performing operation: () throws -> Value
) {
  do {
    _ = try operation()
    Issue.record("Expected quarantine purge journal codec error \(expected)")
  } catch let error as QuarantinePurgeJournalCodecError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
}
