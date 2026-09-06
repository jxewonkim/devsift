import Darwin
import Foundation

/// A bounded reason why a held-volume capacity sample could not be trusted.
///
/// This type deliberately carries neither paths nor raw dependency errors.
enum DescriptorQuarantinePurgeCapacityObservationFailure: Error, Equatable, Sendable {
  case unavailable(CleanupQuarantineSystemFailure)
  case expectedDeviceMismatch
  case expectedVolumeMismatch
  case invalidFileSystemStatistics
  case availableByteCountOverflow
}

/// A descriptive comparison between two same-volume raw capacity samples.
///
/// The amount is only an observed change in non-root available capacity. It is
/// never evidence that this process reclaimed or consumed those bytes.
enum QuarantinePurgeObservedCapacityChange: Equatable, Sendable {
  case increase(amount: UInt64)
  case unchanged
  case decrease(amount: UInt64)
  case unavailable
}

struct DescriptorQuarantinePurgeFStatValue: Equatable, Sendable {
  let device: UInt64
}

struct DescriptorQuarantinePurgeFStatFSValue: Equatable, Sendable {
  let blockSize: UInt64
  let availableBlockCount: UInt64
  let fileSystemIDFirst: Int32
  let fileSystemIDSecond: Int32
}

struct DescriptorQuarantinePurgeCapacityPOSIXError: Error, Equatable, Sendable {
  let code: Int32
}

/// Injectable syscall boundary for deterministic capacity-observer tests.
/// Production defaults call `fstat` and `fstatfs` on the same held descriptor.
struct DescriptorQuarantinePurgeCapacityObserverDependencies: Sendable {
  typealias FStat =
    @Sendable (Int32) -> Result<
      DescriptorQuarantinePurgeFStatValue,
      DescriptorQuarantinePurgeCapacityPOSIXError
    >
  typealias FStatFS =
    @Sendable (Int32) -> Result<
      DescriptorQuarantinePurgeFStatFSValue,
      DescriptorQuarantinePurgeCapacityPOSIXError
    >

  var fstat: FStat
  var fstatfs: FStatFS

  init(
    fstat: @escaping FStat = descriptorQuarantinePurgeCapacityFStat,
    fstatfs: @escaping FStatFS = descriptorQuarantinePurgeCapacityFStatFS
  ) {
    self.fstat = fstat
    self.fstatfs = fstatfs
  }
}

/// Reads non-root available capacity from a descriptor whose lifetime remains
/// owned by the caller. It never discovers or reopens a volume by path.
struct DescriptorQuarantinePurgeCapacityObserver: Sendable {
  static let maximumInterruptedSystemCallAttempts =
    Int(
      exactly: QuarantinePurgeJournalResourceBoundsV1.current
        .maximumInterruptedSystemCallAttempts
    ) ?? 0

  private let dependencies: DescriptorQuarantinePurgeCapacityObserverDependencies

  init(
    dependencies: DescriptorQuarantinePurgeCapacityObserverDependencies =
      DescriptorQuarantinePurgeCapacityObserverDependencies()
  ) {
    self.dependencies = dependencies
  }

  /// Obtains the mandatory pre-intent observation. Any failure, invalid value,
  /// or overflow must prevent the irreversible intent from being published.
  func observeBeforeIntent(
    fromHeldDescriptor descriptor: Int32,
    expectedDevice: UInt64
  ) -> Result<
    QuarantinePurgeCapacityObservationV1,
    DescriptorQuarantinePurgeCapacityObservationFailure
  > {
    observe(
      fromHeldDescriptor: descriptor,
      expectedDevice: expectedDevice,
      expectedVolumeIdentity: nil
    )
  }

  /// Obtains a sample while requiring the exact device and both filesystem-ID
  /// words from an earlier observation.
  func observe(
    fromHeldDescriptor descriptor: Int32,
    expectedDevice: UInt64,
    expectedVolumeIdentity: QuarantinePurgeVolumeIdentityV1?
  ) -> Result<
    QuarantinePurgeCapacityObservationV1,
    DescriptorQuarantinePurgeCapacityObservationFailure
  > {
    if let expectedVolumeIdentity,
      expectedVolumeIdentity.device != expectedDevice
    {
      return .failure(.expectedVolumeMismatch)
    }

    let descriptorStatus: DescriptorQuarantinePurgeFStatValue
    switch retryInterrupted({ dependencies.fstat(descriptor) }) {
    case .success(let value):
      descriptorStatus = value
    case .failure(let error):
      return .failure(.unavailable(descriptorJournalFailure(for: error.code)))
    }
    guard descriptorStatus.device == expectedDevice else {
      return .failure(.expectedDeviceMismatch)
    }

    let fileSystemStatus: DescriptorQuarantinePurgeFStatFSValue
    switch retryInterrupted({ dependencies.fstatfs(descriptor) }) {
    case .success(let value):
      fileSystemStatus = value
    case .failure(let error):
      return .failure(.unavailable(descriptorJournalFailure(for: error.code)))
    }
    guard fileSystemStatus.blockSize > 0 else {
      return .failure(.invalidFileSystemStatistics)
    }

    let identity = QuarantinePurgeVolumeIdentityV1(
      device: descriptorStatus.device,
      fileSystemIDFirst: fileSystemStatus.fileSystemIDFirst,
      fileSystemIDSecond: fileSystemStatus.fileSystemIDSecond
    )
    if let expectedVolumeIdentity, identity != expectedVolumeIdentity {
      return .failure(.expectedVolumeMismatch)
    }

    let (availableBytes, overflow) = fileSystemStatus.availableBlockCount
      .multipliedReportingOverflow(by: fileSystemStatus.blockSize)
    guard !overflow else {
      return .failure(.availableByteCountOverflow)
    }
    return .success(
      QuarantinePurgeCapacityObservationV1(
        volumeIdentity: identity,
        availableBytes: availableBytes
      )
    )
  }

  /// A conclusive namespace outcome remains conclusive if this best-effort
  /// post-attempt sample fails. No failure is converted to a synthetic zero.
  func observeAfterAttempt(
    fromHeldDescriptor descriptor: Int32,
    matching observationBefore: QuarantinePurgeCapacityObservationV1
  ) -> QuarantinePurgePostCapacityObservationV1 {
    switch observe(
      fromHeldDescriptor: descriptor,
      expectedDevice: observationBefore.volumeIdentity.device,
      expectedVolumeIdentity: observationBefore.volumeIdentity
    ) {
    case .success(let observation):
      return .available(observation)
    case .failure:
      return .unavailable
    }
  }

  /// Compares only exact same-volume observations. The result is descriptive,
  /// not a causal or reclaimed-byte claim.
  static func compare(
    observationBefore: QuarantinePurgeCapacityObservationV1,
    observationAfter: QuarantinePurgePostCapacityObservationV1
  ) -> QuarantinePurgeObservedCapacityChange {
    guard case .available(let observationAfter) = observationAfter,
      observationAfter.volumeIdentity == observationBefore.volumeIdentity
    else {
      return .unavailable
    }

    if observationAfter.availableBytes > observationBefore.availableBytes {
      return .increase(
        amount: observationAfter.availableBytes - observationBefore.availableBytes
      )
    }
    if observationAfter.availableBytes < observationBefore.availableBytes {
      return .decrease(
        amount: observationBefore.availableBytes - observationAfter.availableBytes
      )
    }
    return .unchanged
  }

  private func retryInterrupted<Value>(
    _ operation: () -> Result<Value, DescriptorQuarantinePurgeCapacityPOSIXError>
  ) -> Result<Value, DescriptorQuarantinePurgeCapacityPOSIXError> {
    guard Self.maximumInterruptedSystemCallAttempts > 0 else {
      return .failure(DescriptorQuarantinePurgeCapacityPOSIXError(code: EOVERFLOW))
    }
    for attempt in 0..<Self.maximumInterruptedSystemCallAttempts {
      let result = operation()
      if case .failure(let error) = result,
        error.code == EINTR,
        attempt + 1 < Self.maximumInterruptedSystemCallAttempts
      {
        continue
      }
      return result
    }

    // The fixed nonempty range always returns from inside the loop.
    return .failure(DescriptorQuarantinePurgeCapacityPOSIXError(code: EIO))
  }
}

private func descriptorQuarantinePurgeCapacityFStat(
  _ descriptor: Int32
) -> Result<
  DescriptorQuarantinePurgeFStatValue,
  DescriptorQuarantinePurgeCapacityPOSIXError
> {
  var information = stat()
  guard Darwin.fstat(descriptor, &information) == 0 else {
    return .failure(DescriptorQuarantinePurgeCapacityPOSIXError(code: errno))
  }
  return .success(
    DescriptorQuarantinePurgeFStatValue(
      device: UInt64(bitPattern: Int64(information.st_dev))
    )
  )
}

private func descriptorQuarantinePurgeCapacityFStatFS(
  _ descriptor: Int32
) -> Result<
  DescriptorQuarantinePurgeFStatFSValue,
  DescriptorQuarantinePurgeCapacityPOSIXError
> {
  var information = statfs()
  guard Darwin.fstatfs(descriptor, &information) == 0 else {
    return .failure(DescriptorQuarantinePurgeCapacityPOSIXError(code: errno))
  }
  return .success(
    DescriptorQuarantinePurgeFStatFSValue(
      blockSize: UInt64(information.f_bsize),
      availableBlockCount: information.f_bavail,
      fileSystemIDFirst: information.f_fsid.val.0,
      fileSystemIDSecond: information.f_fsid.val.1
    )
  )
}
