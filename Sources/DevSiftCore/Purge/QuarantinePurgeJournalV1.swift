import CryptoKit
import Foundation

/// Stable identity for the volume used by one purge capacity observation.
///
/// The two filesystem identifier words preserve Darwin's `fsid_t` value. This
/// is a domain value rather than a wire DTO and is deliberately not `Codable`.
struct QuarantinePurgeVolumeIdentityV1: Equatable, Sendable {
  let device: UInt64
  let fileSystemIDFirst: Int32
  let fileSystemIDSecond: Int32
}

/// One raw, non-root available-capacity sample from a held filesystem.
struct QuarantinePurgeCapacityObservationV1: Equatable, Sendable {
  let volumeIdentity: QuarantinePurgeVolumeIdentityV1
  let availableBytes: UInt64
}

/// Identifies which separately authorized pass obtained the post-attempt
/// capacity observation (or discovered that it was unavailable).
enum QuarantinePurgeCapacityObservationProvenanceV1: String, Equatable, Sendable {
  case initialAttempt = "initial-attempt"
  case explicitRetry = "explicit-retry"
  case recovery
}

/// A terminal namespace observation remains valid even when capacity cannot be
/// sampled. Absence here must never be converted to a synthetic zero value.
enum QuarantinePurgePostCapacityObservationV1: Equatable, Sendable {
  case available(QuarantinePurgeCapacityObservationV1)
  case unavailable
}

/// Immutable aggregate limits sealed into every purge intent.
///
/// The values are part of the irreversible-operation policy. The intent
/// factory always selects `current`; callers cannot broaden them for an
/// individual purge attempt.
struct QuarantinePurgeJournalResourceBoundsV1: Equatable, Sendable {
  static let current = QuarantinePurgeJournalResourceBoundsV1(
    maximumEntries: 1_000_000,
    maximumDepth: 32,
    maximumEntriesPerDirectory: 100_000,
    maximumRawNameBytes: 64 * 1_024 * 1_024,
    maximumInterruptedSystemCallAttempts: 3,
    maximumSynchronizationOperations: 1_000_002
  )

  let maximumEntries: UInt64
  let maximumDepth: UInt32
  let maximumEntriesPerDirectory: UInt64
  let maximumRawNameBytes: UInt64
  let maximumInterruptedSystemCallAttempts: UInt32
  let maximumSynchronizationOperations: UInt64

  fileprivate var hasValidRelationships: Bool {
    let (derivedSynchronizationOperations, overflow) = maximumEntries.addingReportingOverflow(2)
    return !overflow
      && maximumEntries > 0
      && maximumDepth > 0
      && maximumEntriesPerDirectory > 0
      && maximumRawNameBytes > 0
      && maximumInterruptedSystemCallAttempts > 0
      && maximumSynchronizationOperations == derivedSynchronizationOperations
  }
}

/// Immutable evidence authorizing one receipt-bound quarantine purge attempt.
struct QuarantinePurgeJournalIntentV1: Equatable, Sendable {
  static let schemaIdentifier = "devsift.quarantine-purge-intent"
  static let formatVersion: UInt32 = 1
  static let currentPurgePolicyRevision: UInt32 = 1

  let purgeTransactionID: String
  let quarantineTransactionID: String
  let quarantineIntentDigest: [UInt8]
  let quarantineReceiptDigest: [UInt8]
  let npmRootBinding: QuarantineJournalFileBindingV1
  let quarantineRootBinding: QuarantineJournalFileBindingV1
  let candidateBinding: QuarantineJournalFileBindingV1
  let sourceComponents: [[UInt8]]
  let quarantineItemComponent: [UInt8]
  let purgeWorkComponent: [UInt8]
  let purgePolicyRevision: UInt32
  let resourceBounds: QuarantinePurgeJournalResourceBoundsV1
  let capacityBefore: QuarantinePurgeCapacityObservationV1

  init(
    purgeTransactionID: String,
    quarantineTransactionID: String,
    quarantineIntentDigest: [UInt8],
    quarantineReceiptDigest: [UInt8],
    npmRootBinding: QuarantineJournalFileBindingV1,
    quarantineRootBinding: QuarantineJournalFileBindingV1,
    candidateBinding: QuarantineJournalFileBindingV1,
    sourceComponents: [[UInt8]],
    quarantineItemComponent: [UInt8],
    purgeWorkComponent: [UInt8],
    purgePolicyRevision: UInt32 = Self.currentPurgePolicyRevision,
    resourceBounds: QuarantinePurgeJournalResourceBoundsV1 = .current,
    capacityBefore: QuarantinePurgeCapacityObservationV1
  ) {
    self.purgeTransactionID = purgeTransactionID
    self.quarantineTransactionID = quarantineTransactionID
    self.quarantineIntentDigest = quarantineIntentDigest
    self.quarantineReceiptDigest = quarantineReceiptDigest
    self.npmRootBinding = npmRootBinding
    self.quarantineRootBinding = quarantineRootBinding
    self.candidateBinding = candidateBinding
    self.sourceComponents = sourceComponents
    self.quarantineItemComponent = quarantineItemComponent
    self.purgeWorkComponent = purgeWorkComponent
    self.purgePolicyRevision = purgePolicyRevision
    self.resourceBounds = resourceBounds
    self.capacityBefore = capacityBefore
  }
}

enum QuarantinePurgeJournalReceiptOutcomeV1: String, Equatable, Sendable {
  case notPurged = "not-purged"
  case itemAbsent = "item-absent"
}

/// Immutable terminal namespace and capacity evidence for one purge intent.
struct QuarantinePurgeJournalReceiptV1: Equatable, Sendable {
  static let schemaIdentifier = "devsift.quarantine-purge-receipt"
  static let formatVersion: UInt32 = 1

  let purgeTransactionID: String
  let purgeIntentDigest: [UInt8]
  let outcome: QuarantinePurgeJournalReceiptOutcomeV1
  let quarantineNameWasRecreated: Bool
  let producedByRecovery: Bool
  let capacityObservationProvenance: QuarantinePurgeCapacityObservationProvenanceV1
  let capacityAfter: QuarantinePurgePostCapacityObservationV1
}

enum QuarantinePurgeJournalCodecError: Error, Equatable, Sendable {
  case emptyDocument
  case documentTooLarge
  case malformedDocument
  case nonCanonicalDocument
  case unsupportedSchema
  case unsupportedVersion
  case invalidPurgeTransactionID
  case invalidQuarantineTransactionID
  case invalidDigest
  case invalidBinding
  case invalidSourcePath
  case invalidQuarantineItem
  case invalidPurgeWorkItem
  case invalidCapacityObservation
  case resourceBoundsDrift
  case policyDrift
  case invalidQuarantineRecordPair
  case quarantineReceiptNotPurgeable
  case invalidReceiptRelationships
  case receiptDoesNotMatchIntent
}

/// Strict canonical codec for the private quarantine-purge journal namespace.
enum QuarantinePurgeJournalV1Codec {
  static let maximumEncodedByteCount = 32 * 1_024

  static func makeIntent(
    purgeTransactionID: String,
    capacityBefore: QuarantinePurgeCapacityObservationV1,
    canonicalQuarantineIntentBytes intentBytes: Data,
    canonicalQuarantineReceiptBytes receiptBytes: Data
  ) throws -> QuarantinePurgeJournalIntentV1 {
    let pair = try quarantinePair(
      canonicalIntentBytes: intentBytes,
      canonicalReceiptBytes: receiptBytes
    )
    let intent = QuarantinePurgeJournalIntentV1(
      purgeTransactionID: purgeTransactionID,
      quarantineTransactionID: pair.intent.transactionID,
      quarantineIntentDigest: digest(intentBytes),
      quarantineReceiptDigest: digest(receiptBytes),
      npmRootBinding: pair.intent.npmRootBinding,
      quarantineRootBinding: pair.intent.quarantineRootBinding,
      candidateBinding: pair.intent.candidateBinding,
      sourceComponents: pair.intent.sourceComponents,
      quarantineItemComponent: pair.quarantineItemComponent,
      purgeWorkComponent: purgeWorkComponent(for: purgeTransactionID),
      resourceBounds: .current,
      capacityBefore: capacityBefore
    )
    try validateIntentStructure(intent)
    guard
      intent.purgePolicyRevision
        == QuarantinePurgeJournalIntentV1.currentPurgePolicyRevision
    else {
      throw QuarantinePurgeJournalCodecError.policyDrift
    }
    return intent
  }

  static func encode(_ intent: QuarantinePurgeJournalIntentV1) throws -> Data {
    try validateIntentStructure(intent)
    guard
      intent.purgePolicyRevision
        == QuarantinePurgeJournalIntentV1.currentPurgePolicyRevision
    else {
      throw QuarantinePurgeJournalCodecError.policyDrift
    }
    return try encodeCanonicalIntent(intent)
  }

  static func encode(
    _ intent: QuarantinePurgeJournalIntentV1,
    matchingQuarantineIntentBytes quarantineIntentBytes: Data,
    matchingQuarantineReceiptBytes quarantineReceiptBytes: Data
  ) throws -> Data {
    try validate(
      intent,
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes
    )
    return try encode(intent)
  }

  static func decodeIntent(_ bytes: Data) throws -> QuarantinePurgeJournalIntentV1 {
    try validateInputSize(bytes)
    let wire: PurgeIntentWire = try decode(bytes)
    let intent = try wire.domainValue()
    try validateIntentStructure(intent)
    guard try encodeCanonicalIntent(intent) == bytes else {
      throw QuarantinePurgeJournalCodecError.nonCanonicalDocument
    }
    return intent
  }

  static func decodeIntent(
    _ bytes: Data,
    matchingQuarantineIntentBytes quarantineIntentBytes: Data,
    matchingQuarantineReceiptBytes quarantineReceiptBytes: Data
  ) throws -> QuarantinePurgeJournalIntentV1 {
    let intent = try decodeIntent(bytes)
    try validate(
      intent,
      canonicalQuarantineIntentBytes: quarantineIntentBytes,
      canonicalQuarantineReceiptBytes: quarantineReceiptBytes
    )
    return intent
  }

  static func validate(
    _ intent: QuarantinePurgeJournalIntentV1,
    canonicalQuarantineIntentBytes intentBytes: Data,
    canonicalQuarantineReceiptBytes receiptBytes: Data
  ) throws {
    try validateIntentStructure(intent)
    let pair = try quarantinePair(
      canonicalIntentBytes: intentBytes,
      canonicalReceiptBytes: receiptBytes
    )
    guard
      intent.quarantineTransactionID == pair.intent.transactionID,
      intent.quarantineIntentDigest == digest(intentBytes),
      intent.quarantineReceiptDigest == digest(receiptBytes),
      intent.npmRootBinding == pair.intent.npmRootBinding,
      intent.quarantineRootBinding == pair.intent.quarantineRootBinding,
      intent.candidateBinding == pair.intent.candidateBinding,
      intent.sourceComponents == pair.intent.sourceComponents,
      intent.quarantineItemComponent == pair.quarantineItemComponent
    else {
      throw QuarantinePurgeJournalCodecError.invalidQuarantineRecordPair
    }
  }

  static func makeReceipt(
    outcome: QuarantinePurgeJournalReceiptOutcomeV1,
    quarantineNameWasRecreated: Bool = false,
    producedByRecovery: Bool,
    capacityObservationProvenance:
      QuarantinePurgeCapacityObservationProvenanceV1,
    capacityAfter: QuarantinePurgePostCapacityObservationV1,
    canonicalPurgeIntentBytes intentBytes: Data
  ) throws -> QuarantinePurgeJournalReceiptV1 {
    let intent = try decodeIntent(intentBytes)
    let receipt = QuarantinePurgeJournalReceiptV1(
      purgeTransactionID: intent.purgeTransactionID,
      purgeIntentDigest: digest(intentBytes),
      outcome: outcome,
      quarantineNameWasRecreated: quarantineNameWasRecreated,
      producedByRecovery: producedByRecovery,
      capacityObservationProvenance: capacityObservationProvenance,
      capacityAfter: capacityAfter
    )
    try validate(receipt, matching: intent, canonicalIntentBytes: intentBytes)
    return receipt
  }

  static func encode(_ receipt: QuarantinePurgeJournalReceiptV1) throws -> Data {
    try validateReceiptStructure(receipt)
    return try encodeBounded(PurgeReceiptWire(receipt))
  }

  static func encode(
    _ receipt: QuarantinePurgeJournalReceiptV1,
    matchingIntentBytes intentBytes: Data
  ) throws -> Data {
    let intent = try decodeIntent(intentBytes)
    try validate(receipt, matching: intent, canonicalIntentBytes: intentBytes)
    return try encode(receipt)
  }

  static func decodeReceipt(_ bytes: Data) throws -> QuarantinePurgeJournalReceiptV1 {
    try validateInputSize(bytes)
    let wire: PurgeReceiptWire = try decode(bytes)
    let receipt = try wire.domainValue()
    try validateReceiptStructure(receipt)
    guard try encode(receipt) == bytes else {
      throw QuarantinePurgeJournalCodecError.nonCanonicalDocument
    }
    return receipt
  }

  static func decodeReceipt(
    _ bytes: Data,
    matchingIntentBytes intentBytes: Data
  ) throws -> QuarantinePurgeJournalReceiptV1 {
    let intent = try decodeIntent(intentBytes)
    let receipt = try decodeReceipt(bytes)
    try validate(receipt, matching: intent, canonicalIntentBytes: intentBytes)
    return receipt
  }

  static func purgeIntentDigest(forCanonicalIntentBytes bytes: Data) throws -> [UInt8] {
    _ = try decodeIntent(bytes)
    return digest(bytes)
  }

  static func validate(
    _ receipt: QuarantinePurgeJournalReceiptV1,
    matching intent: QuarantinePurgeJournalIntentV1,
    canonicalIntentBytes intentBytes: Data
  ) throws {
    let decodedIntent = try decodeIntent(intentBytes)
    guard decodedIntent == intent else {
      throw QuarantinePurgeJournalCodecError.receiptDoesNotMatchIntent
    }
    try validateReceiptStructure(receipt)
    guard
      receipt.purgeTransactionID == intent.purgeTransactionID,
      receipt.purgeIntentDigest == digest(intentBytes)
    else {
      throw QuarantinePurgeJournalCodecError.receiptDoesNotMatchIntent
    }
    if case .available(let observation) = receipt.capacityAfter,
      observation.volumeIdentity != intent.capacityBefore.volumeIdentity
    {
      throw QuarantinePurgeJournalCodecError.invalidCapacityObservation
    }
  }

  private static func quarantinePair(
    canonicalIntentBytes intentBytes: Data,
    canonicalReceiptBytes receiptBytes: Data
  ) throws -> (
    intent: QuarantineJournalIntentV1,
    receipt: QuarantineJournalReceiptV1,
    quarantineItemComponent: [UInt8]
  ) {
    let intent: QuarantineJournalIntentV1
    let receipt: QuarantineJournalReceiptV1
    do {
      intent = try QuarantineJournalV1Codec.decodeIntent(intentBytes)
      receipt = try QuarantineJournalV1Codec.decodeReceipt(
        receiptBytes,
        matchingIntentBytes: intentBytes
      )
    } catch {
      throw QuarantinePurgeJournalCodecError.invalidQuarantineRecordPair
    }
    guard receipt.outcome == .quarantined,
      let ordinal = receipt.selectedDestinationOrdinal,
      intent.destinationComponents.indices.contains(ordinal),
      receipt.destinationBinding == intent.candidateBinding
    else {
      throw QuarantinePurgeJournalCodecError.quarantineReceiptNotPurgeable
    }
    let item = intent.destinationComponents[ordinal]
    guard isQuarantineItemComponent(item) else {
      throw QuarantinePurgeJournalCodecError.invalidQuarantineRecordPair
    }
    return (intent, receipt, item)
  }

  private static func validateIntentStructure(
    _ intent: QuarantinePurgeJournalIntentV1
  ) throws {
    guard isLowercaseHexIdentifier(intent.purgeTransactionID) else {
      throw QuarantinePurgeJournalCodecError.invalidPurgeTransactionID
    }
    guard isLowercaseHexIdentifier(intent.quarantineTransactionID),
      intent.quarantineTransactionID != intent.purgeTransactionID
    else {
      throw QuarantinePurgeJournalCodecError.invalidQuarantineTransactionID
    }
    guard intent.quarantineIntentDigest.count == SHA256.byteCount,
      intent.quarantineReceiptDigest.count == SHA256.byteCount
    else {
      throw QuarantinePurgeJournalCodecError.invalidDigest
    }
    guard
      isValidBinding(intent.npmRootBinding),
      isValidBinding(intent.quarantineRootBinding),
      isValidBinding(intent.candidateBinding),
      intent.npmRootBinding.kind == .directory,
      intent.quarantineRootBinding.kind == .directory,
      intent.candidateBinding.kind == .directory,
      intent.npmRootBinding.device == intent.quarantineRootBinding.device,
      intent.npmRootBinding.device == intent.candidateBinding.device,
      intent.npmRootBinding.ownerUID != 0,
      intent.npmRootBinding.ownerUID == intent.quarantineRootBinding.ownerUID,
      intent.npmRootBinding.ownerUID == intent.candidateBinding.ownerUID
    else {
      throw QuarantinePurgeJournalCodecError.invalidBinding
    }
    let identities = [
      intent.npmRootBinding.inode,
      intent.quarantineRootBinding.inode,
      intent.candidateBinding.inode,
    ]
    guard Set(identities).count == identities.count else {
      throw QuarantinePurgeJournalCodecError.invalidBinding
    }
    guard intent.sourceComponents == [Array("_cacache".utf8)] else {
      throw QuarantinePurgeJournalCodecError.invalidSourcePath
    }
    guard isQuarantineItemComponent(intent.quarantineItemComponent) else {
      throw QuarantinePurgeJournalCodecError.invalidQuarantineItem
    }
    guard intent.purgeWorkComponent == purgeWorkComponent(for: intent.purgeTransactionID) else {
      throw QuarantinePurgeJournalCodecError.invalidPurgeWorkItem
    }
    guard
      intent.capacityBefore.volumeIdentity.device == intent.candidateBinding.device
    else {
      throw QuarantinePurgeJournalCodecError.invalidCapacityObservation
    }
    guard
      intent.resourceBounds.hasValidRelationships,
      intent.resourceBounds == .current
    else {
      throw QuarantinePurgeJournalCodecError.resourceBoundsDrift
    }
    guard intent.purgePolicyRevision > 0,
      intent.purgePolicyRevision
        <= QuarantinePurgeJournalIntentV1.currentPurgePolicyRevision
    else {
      throw QuarantinePurgeJournalCodecError.policyDrift
    }
  }

  private static func validateReceiptStructure(
    _ receipt: QuarantinePurgeJournalReceiptV1
  ) throws {
    guard isLowercaseHexIdentifier(receipt.purgeTransactionID) else {
      throw QuarantinePurgeJournalCodecError.invalidPurgeTransactionID
    }
    guard receipt.purgeIntentDigest.count == SHA256.byteCount else {
      throw QuarantinePurgeJournalCodecError.invalidDigest
    }
    switch receipt.outcome {
    case .notPurged:
      guard !receipt.quarantineNameWasRecreated,
        receipt.capacityObservationProvenance != .explicitRetry
      else {
        throw QuarantinePurgeJournalCodecError.invalidReceiptRelationships
      }
    case .itemAbsent:
      break
    }
    guard
      receipt.producedByRecovery
        == (receipt.capacityObservationProvenance == .recovery)
    else {
      throw QuarantinePurgeJournalCodecError.invalidReceiptRelationships
    }
  }

  private static func isValidBinding(_ binding: QuarantineJournalFileBindingV1) -> Bool {
    binding.birthNanoseconds < 1_000_000_000
      && binding.permissionMode <= 0o7777
      && binding.linkCount > 0
  }

  private static func isQuarantineItemComponent(_ bytes: [UInt8]) -> Bool {
    let prefix = Array("item-v1-".utf8)
    return bytes.count == prefix.count + 32
      && bytes.starts(with: prefix)
      && bytes.dropFirst(prefix.count).allSatisfy(isLowercaseHexDigit)
  }

  private static func purgeWorkComponent(for transactionID: String) -> [UInt8] {
    Array(".purge-work-v1-\(transactionID)".utf8)
  }

  private static func isLowercaseHexIdentifier(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 32 && bytes.allSatisfy(isLowercaseHexDigit)
  }

  private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
  }

  private static func validateInputSize(_ bytes: Data) throws {
    guard !bytes.isEmpty else {
      throw QuarantinePurgeJournalCodecError.emptyDocument
    }
    guard bytes.count <= maximumEncodedByteCount else {
      throw QuarantinePurgeJournalCodecError.documentTooLarge
    }
  }

  private static func encodeCanonicalIntent(
    _ intent: QuarantinePurgeJournalIntentV1
  ) throws -> Data {
    try encodeBounded(PurgeIntentWire(intent))
  }

  private static func encodeBounded<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes: Data
    do {
      bytes = try encoder.encode(value)
    } catch {
      throw QuarantinePurgeJournalCodecError.malformedDocument
    }
    guard bytes.count <= maximumEncodedByteCount else {
      throw QuarantinePurgeJournalCodecError.documentTooLarge
    }
    return bytes
  }

  private static func decode<Value: Decodable>(_ bytes: Data) throws -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: bytes)
    } catch {
      throw QuarantinePurgeJournalCodecError.malformedDocument
    }
  }

  private static func digest(_ bytes: Data) -> [UInt8] {
    Array(SHA256.hash(data: bytes))
  }
}

private struct PurgeIntentWire: Codable {
  let schema: String
  let version: String
  let purgeTransactionID: String
  let quarantineTransactionID: String
  let quarantineIntentDigest: String
  let quarantineReceiptDigest: String
  let npmRootBinding: PurgeBindingWire
  let quarantineRootBinding: PurgeBindingWire
  let candidateBinding: PurgeBindingWire
  let sourceComponents: [String]
  let quarantineItemComponent: String
  let purgeWorkComponent: String
  let purgePolicyRevision: String
  let resourceBounds: PurgeResourceBoundsWire
  let capacityBefore: PurgeCapacityObservationWire

  init(_ intent: QuarantinePurgeJournalIntentV1) {
    schema = QuarantinePurgeJournalIntentV1.schemaIdentifier
    version = String(QuarantinePurgeJournalIntentV1.formatVersion)
    purgeTransactionID = intent.purgeTransactionID
    quarantineTransactionID = intent.quarantineTransactionID
    quarantineIntentDigest = purgeBase64(intent.quarantineIntentDigest)
    quarantineReceiptDigest = purgeBase64(intent.quarantineReceiptDigest)
    npmRootBinding = PurgeBindingWire(intent.npmRootBinding)
    quarantineRootBinding = PurgeBindingWire(intent.quarantineRootBinding)
    candidateBinding = PurgeBindingWire(intent.candidateBinding)
    sourceComponents = intent.sourceComponents.map(purgeBase64)
    quarantineItemComponent = purgeBase64(intent.quarantineItemComponent)
    purgeWorkComponent = purgeBase64(intent.purgeWorkComponent)
    purgePolicyRevision = String(intent.purgePolicyRevision)
    resourceBounds = PurgeResourceBoundsWire(intent.resourceBounds)
    capacityBefore = PurgeCapacityObservationWire(intent.capacityBefore)
  }

  func domainValue() throws -> QuarantinePurgeJournalIntentV1 {
    guard schema == QuarantinePurgeJournalIntentV1.schemaIdentifier else {
      throw QuarantinePurgeJournalCodecError.unsupportedSchema
    }
    guard
      try purgeParseUInt32(version) == QuarantinePurgeJournalIntentV1.formatVersion
    else {
      throw QuarantinePurgeJournalCodecError.unsupportedVersion
    }
    return try QuarantinePurgeJournalIntentV1(
      purgeTransactionID: purgeTransactionID,
      quarantineTransactionID: quarantineTransactionID,
      quarantineIntentDigest: purgeDecodeBase64(quarantineIntentDigest),
      quarantineReceiptDigest: purgeDecodeBase64(quarantineReceiptDigest),
      npmRootBinding: npmRootBinding.domainValue(),
      quarantineRootBinding: quarantineRootBinding.domainValue(),
      candidateBinding: candidateBinding.domainValue(),
      sourceComponents: sourceComponents.map(purgeDecodeBase64),
      quarantineItemComponent: purgeDecodeBase64(quarantineItemComponent),
      purgeWorkComponent: purgeDecodeBase64(purgeWorkComponent),
      purgePolicyRevision: purgeParseUInt32(purgePolicyRevision),
      resourceBounds: resourceBounds.domainValue(),
      capacityBefore: capacityBefore.domainValue()
    )
  }
}

private struct PurgeResourceBoundsWire: Codable {
  let maximumEntries: String
  let maximumDepth: String
  let maximumEntriesPerDirectory: String
  let maximumRawNameBytes: String
  let maximumInterruptedSystemCallAttempts: String
  let maximumSynchronizationOperations: String

  init(_ bounds: QuarantinePurgeJournalResourceBoundsV1) {
    maximumEntries = String(bounds.maximumEntries)
    maximumDepth = String(bounds.maximumDepth)
    maximumEntriesPerDirectory = String(bounds.maximumEntriesPerDirectory)
    maximumRawNameBytes = String(bounds.maximumRawNameBytes)
    maximumInterruptedSystemCallAttempts = String(
      bounds.maximumInterruptedSystemCallAttempts
    )
    maximumSynchronizationOperations = String(bounds.maximumSynchronizationOperations)
  }

  func domainValue() throws -> QuarantinePurgeJournalResourceBoundsV1 {
    QuarantinePurgeJournalResourceBoundsV1(
      maximumEntries: try purgeParseUInt64(maximumEntries),
      maximumDepth: try purgeParseUInt32(maximumDepth),
      maximumEntriesPerDirectory: try purgeParseUInt64(maximumEntriesPerDirectory),
      maximumRawNameBytes: try purgeParseUInt64(maximumRawNameBytes),
      maximumInterruptedSystemCallAttempts: try purgeParseUInt32(
        maximumInterruptedSystemCallAttempts
      ),
      maximumSynchronizationOperations: try purgeParseUInt64(
        maximumSynchronizationOperations
      )
    )
  }
}

private struct PurgeReceiptWire: Codable {
  let schema: String
  let version: String
  let purgeTransactionID: String
  let purgeIntentDigest: String
  let outcome: String
  let quarantineNameWasRecreated: Bool
  let producedByRecovery: Bool
  let capacityObservationProvenance: String
  let capacityAfterStatus: String
  let capacityAfter: PurgeCapacityObservationWire?

  init(_ receipt: QuarantinePurgeJournalReceiptV1) {
    schema = QuarantinePurgeJournalReceiptV1.schemaIdentifier
    version = String(QuarantinePurgeJournalReceiptV1.formatVersion)
    purgeTransactionID = receipt.purgeTransactionID
    purgeIntentDigest = purgeBase64(receipt.purgeIntentDigest)
    outcome = receipt.outcome.rawValue
    quarantineNameWasRecreated = receipt.quarantineNameWasRecreated
    producedByRecovery = receipt.producedByRecovery
    capacityObservationProvenance = receipt.capacityObservationProvenance.rawValue
    switch receipt.capacityAfter {
    case .available(let observation):
      capacityAfterStatus = "available"
      capacityAfter = PurgeCapacityObservationWire(observation)
    case .unavailable:
      capacityAfterStatus = "unavailable"
      capacityAfter = nil
    }
  }

  func domainValue() throws -> QuarantinePurgeJournalReceiptV1 {
    guard schema == QuarantinePurgeJournalReceiptV1.schemaIdentifier else {
      throw QuarantinePurgeJournalCodecError.unsupportedSchema
    }
    guard
      try purgeParseUInt32(version) == QuarantinePurgeJournalReceiptV1.formatVersion
    else {
      throw QuarantinePurgeJournalCodecError.unsupportedVersion
    }
    guard let outcome = QuarantinePurgeJournalReceiptOutcomeV1(rawValue: outcome),
      let provenance = QuarantinePurgeCapacityObservationProvenanceV1(
        rawValue: capacityObservationProvenance
      )
    else {
      throw QuarantinePurgeJournalCodecError.invalidReceiptRelationships
    }
    let decodedCapacityAfter: QuarantinePurgePostCapacityObservationV1
    switch capacityAfterStatus {
    case "available":
      guard let observation = self.capacityAfter else {
        throw QuarantinePurgeJournalCodecError.invalidCapacityObservation
      }
      decodedCapacityAfter = .available(try observation.domainValue())
    case "unavailable":
      guard self.capacityAfter == nil else {
        throw QuarantinePurgeJournalCodecError.invalidCapacityObservation
      }
      decodedCapacityAfter = .unavailable
    default:
      throw QuarantinePurgeJournalCodecError.invalidCapacityObservation
    }
    return QuarantinePurgeJournalReceiptV1(
      purgeTransactionID: purgeTransactionID,
      purgeIntentDigest: try purgeDecodeBase64(purgeIntentDigest),
      outcome: outcome,
      quarantineNameWasRecreated: quarantineNameWasRecreated,
      producedByRecovery: producedByRecovery,
      capacityObservationProvenance: provenance,
      capacityAfter: decodedCapacityAfter
    )
  }
}

private struct PurgeCapacityObservationWire: Codable {
  let volumeIdentity: PurgeVolumeIdentityWire
  let availableBytes: String

  init(_ observation: QuarantinePurgeCapacityObservationV1) {
    volumeIdentity = PurgeVolumeIdentityWire(observation.volumeIdentity)
    availableBytes = String(observation.availableBytes)
  }

  func domainValue() throws -> QuarantinePurgeCapacityObservationV1 {
    QuarantinePurgeCapacityObservationV1(
      volumeIdentity: try volumeIdentity.domainValue(),
      availableBytes: try purgeParseUInt64(availableBytes)
    )
  }
}

private struct PurgeVolumeIdentityWire: Codable {
  let device: String
  let fileSystemIDFirst: String
  let fileSystemIDSecond: String

  init(_ identity: QuarantinePurgeVolumeIdentityV1) {
    device = String(identity.device)
    fileSystemIDFirst = String(identity.fileSystemIDFirst)
    fileSystemIDSecond = String(identity.fileSystemIDSecond)
  }

  func domainValue() throws -> QuarantinePurgeVolumeIdentityV1 {
    QuarantinePurgeVolumeIdentityV1(
      device: try purgeParseUInt64(device),
      fileSystemIDFirst: try purgeParseInt32(fileSystemIDFirst),
      fileSystemIDSecond: try purgeParseInt32(fileSystemIDSecond)
    )
  }
}

private struct PurgeBindingWire: Codable {
  let device: String
  let inode: String
  let generation: String
  let birthSeconds: String
  let birthNanoseconds: String
  let kind: String
  let uid: String
  let mode: String
  let flags: String
  let linkCount: String

  init(_ binding: QuarantineJournalFileBindingV1) {
    device = String(binding.device)
    inode = String(binding.inode)
    generation = String(binding.generation)
    birthSeconds = String(binding.birthSeconds)
    birthNanoseconds = String(binding.birthNanoseconds)
    kind = binding.kind.rawValue
    uid = String(binding.ownerUID)
    mode = String(binding.permissionMode)
    flags = String(binding.flags)
    linkCount = String(binding.linkCount)
  }

  func domainValue() throws -> QuarantineJournalFileBindingV1 {
    guard
      let kind = FileSystemEntryKind(rawValue: kind),
      let generation = UInt32(exactly: try purgeParseUInt64(generation)),
      let birthNanoseconds = UInt32(exactly: try purgeParseUInt64(birthNanoseconds)),
      let ownerUID = UInt32(exactly: try purgeParseUInt64(uid)),
      let permissionMode = UInt32(exactly: try purgeParseUInt64(mode)),
      let flags = UInt32(exactly: try purgeParseUInt64(flags))
    else {
      throw QuarantinePurgeJournalCodecError.invalidBinding
    }
    return try QuarantineJournalFileBindingV1(
      device: purgeParseUInt64(device),
      inode: purgeParseUInt64(inode),
      generation: generation,
      birthSeconds: purgeParseInt64(birthSeconds),
      birthNanoseconds: birthNanoseconds,
      kind: kind,
      ownerUID: ownerUID,
      permissionMode: permissionMode,
      flags: flags,
      linkCount: purgeParseUInt64(linkCount)
    )
  }
}

private func purgeBase64(_ bytes: [UInt8]) -> String {
  Data(bytes).base64EncodedString()
}

private func purgeDecodeBase64(_ value: String) throws -> [UInt8] {
  guard
    let decoded = Data(base64Encoded: value),
    decoded.base64EncodedString() == value
  else {
    throw QuarantinePurgeJournalCodecError.malformedDocument
  }
  return Array(decoded)
}

private func purgeParseUInt32(_ value: String) throws -> UInt32 {
  let parsed = try purgeParseUInt64(value)
  guard let result = UInt32(exactly: parsed) else {
    throw QuarantinePurgeJournalCodecError.malformedDocument
  }
  return result
}

private func purgeParseUInt64(_ value: String) throws -> UInt64 {
  guard let result = UInt64(value), String(result) == value else {
    throw QuarantinePurgeJournalCodecError.malformedDocument
  }
  return result
}

private func purgeParseInt64(_ value: String) throws -> Int64 {
  guard let result = Int64(value), String(result) == value else {
    throw QuarantinePurgeJournalCodecError.malformedDocument
  }
  return result
}

private func purgeParseInt32(_ value: String) throws -> Int32 {
  guard let result = Int32(value), String(result) == value else {
    throw QuarantinePurgeJournalCodecError.malformedDocument
  }
  return result
}
