import Darwin
import Foundation
import Testing

@testable import DevSiftCore

@Suite("Descriptor quarantine purge capacity observer")
struct DescriptorQuarantinePurgeCapacityObserverTests {
  @Test("Interrupted-syscall bound exactly follows the sealed purge policy")
  func interruptionBoundMatchesJournalPolicy() {
    #expect(
      UInt32(
        exactly: DescriptorQuarantinePurgeCapacityObserver.maximumInterruptedSystemCallAttempts)
        == QuarantinePurgeJournalResourceBoundsV1.current.maximumInterruptedSystemCallAttempts
    )
  }

  @Test("Pre-intent observation binds one held descriptor, device, fsid, and f_bavail")
  func observesHeldVolume() {
    let probe = PurgeCapacityObserverProbe(
      fstatResults: [.success(.init(device: 42))],
      fstatfsResults: [
        .success(
          .init(
            blockSize: 4_096,
            availableBlockCount: 7,
            fileSystemIDFirst: -12,
            fileSystemIDSecond: 34
          )
        )
      ]
    )
    let observer = DescriptorQuarantinePurgeCapacityObserver(
      dependencies: probe.dependencies()
    )

    #expect(
      observer.observeBeforeIntent(fromHeldDescriptor: 91, expectedDevice: 42)
        == .success(
          QuarantinePurgeCapacityObservationV1(
            volumeIdentity: QuarantinePurgeVolumeIdentityV1(
              device: 42,
              fileSystemIDFirst: -12,
              fileSystemIDSecond: 34
            ),
            availableBytes: 28_672
          )
        )
    )
    #expect(probe.observation.fstatDescriptors == [91])
    #expect(probe.observation.fstatfsDescriptors == [91])
  }

  @Test("Expected device mismatch rejects the sample before fstatfs")
  func rejectsExpectedDeviceMismatch() {
    let probe = PurgeCapacityObserverProbe(
      fstatResults: [.success(.init(device: 43))],
      fstatfsResults: [.success(purgeCapacityFileSystemValue())]
    )
    let observer = DescriptorQuarantinePurgeCapacityObserver(
      dependencies: probe.dependencies()
    )

    #expect(
      observer.observeBeforeIntent(fromHeldDescriptor: 92, expectedDevice: 42)
        == .failure(.expectedDeviceMismatch)
    )
    #expect(probe.observation.fstatDescriptors == [92])
    #expect(probe.observation.fstatfsDescriptors.isEmpty)
  }

  @Test("Expected volume requires both exact fsid words")
  func rejectsExpectedFileSystemIDMismatch() {
    let observer = purgeCapacityObserver(
      fileSystemValue: purgeCapacityFileSystemValue(
        fileSystemIDFirst: 7,
        fileSystemIDSecond: 8
      )
    )
    let expectedDevice = UInt64(42)
    let mismatches = [
      QuarantinePurgeVolumeIdentityV1(
        device: expectedDevice,
        fileSystemIDFirst: 6,
        fileSystemIDSecond: 8
      ),
      QuarantinePurgeVolumeIdentityV1(
        device: expectedDevice,
        fileSystemIDFirst: 7,
        fileSystemIDSecond: 9
      ),
    ]

    for expectedVolume in mismatches {
      #expect(
        observer.observe(
          fromHeldDescriptor: 93,
          expectedDevice: expectedDevice,
          expectedVolumeIdentity: expectedVolume
        ) == .failure(.expectedVolumeMismatch)
      )
    }
  }

  @Test("An inconsistent expected device and volume is rejected without a syscall")
  func rejectsInconsistentExpectation() {
    let probe = PurgeCapacityObserverProbe(
      fstatResults: [.success(.init(device: 42))],
      fstatfsResults: [.success(purgeCapacityFileSystemValue())]
    )
    let observer = DescriptorQuarantinePurgeCapacityObserver(
      dependencies: probe.dependencies()
    )

    #expect(
      observer.observe(
        fromHeldDescriptor: 94,
        expectedDevice: 42,
        expectedVolumeIdentity: QuarantinePurgeVolumeIdentityV1(
          device: 41,
          fileSystemIDFirst: 7,
          fileSystemIDSecond: 8
        )
      ) == .failure(.expectedVolumeMismatch)
    )
    #expect(probe.observation.fstatDescriptors.isEmpty)
    #expect(probe.observation.fstatfsDescriptors.isEmpty)
  }

  @Test("Zero block size is an invalid mandatory pre-intent observation")
  func rejectsInvalidFileSystemStatistics() {
    let observer = purgeCapacityObserver(
      fileSystemValue: purgeCapacityFileSystemValue(blockSize: 0)
    )

    #expect(
      observer.observeBeforeIntent(fromHeldDescriptor: 95, expectedDevice: 42)
        == .failure(.invalidFileSystemStatistics)
    )
  }

  @Test("Available-byte multiplication overflow rejects the pre-intent observation")
  func rejectsAvailableByteCountOverflow() {
    let observer = purgeCapacityObserver(
      fileSystemValue: purgeCapacityFileSystemValue(
        blockSize: 2,
        availableBlockCount: UInt64.max
      )
    )

    #expect(
      observer.observeBeforeIntent(fromHeldDescriptor: 96, expectedDevice: 42)
        == .failure(.availableByteCountOverflow)
    )
  }

  @Test("Syscall failures map to bounded pre-intent failures")
  func mapsSystemCallFailures() {
    let fstatFailure = DescriptorQuarantinePurgeCapacityObserver(
      dependencies: DescriptorQuarantinePurgeCapacityObserverDependencies(
        fstat: { _ in
          .failure(DescriptorQuarantinePurgeCapacityPOSIXError(code: EACCES))
        },
        fstatfs: { _ in .success(purgeCapacityFileSystemValue()) }
      )
    )
    #expect(
      fstatFailure.observeBeforeIntent(fromHeldDescriptor: 97, expectedDevice: 42)
        == .failure(.unavailable(.permissionDenied))
    )

    let fstatfsFailure = DescriptorQuarantinePurgeCapacityObserver(
      dependencies: DescriptorQuarantinePurgeCapacityObserverDependencies(
        fstat: { _ in .success(.init(device: 42)) },
        fstatfs: { _ in
          .failure(DescriptorQuarantinePurgeCapacityPOSIXError(code: EIO))
        }
      )
    )
    #expect(
      fstatfsFailure.observeBeforeIntent(fromHeldDescriptor: 98, expectedDevice: 42)
        == .failure(.unavailable(.inputOutput))
    )
  }

  @Test("Interrupted syscalls retry at most three times")
  func retriesInterruptedSystemCallsWithinBound() {
    let interrupted = DescriptorQuarantinePurgeCapacityPOSIXError(code: EINTR)
    let successProbe = PurgeCapacityObserverProbe(
      fstatResults: [
        .failure(interrupted),
        .failure(interrupted),
        .success(.init(device: 42)),
      ],
      fstatfsResults: [.success(purgeCapacityFileSystemValue())]
    )
    let successfulObserver = DescriptorQuarantinePurgeCapacityObserver(
      dependencies: successProbe.dependencies()
    )
    #expect(
      successfulObserver.observeBeforeIntent(fromHeldDescriptor: 99, expectedDevice: 42)
        == .success(purgeCapacityObservation())
    )
    #expect(successProbe.observation.fstatDescriptors == [99, 99, 99])

    let failureProbe = PurgeCapacityObserverProbe(
      fstatResults: [
        .failure(interrupted),
        .failure(interrupted),
        .failure(interrupted),
        .success(.init(device: 42)),
      ],
      fstatfsResults: [.success(purgeCapacityFileSystemValue())]
    )
    let failingObserver = DescriptorQuarantinePurgeCapacityObserver(
      dependencies: failureProbe.dependencies()
    )
    #expect(
      failingObserver.observeBeforeIntent(fromHeldDescriptor: 100, expectedDevice: 42)
        == .failure(.unavailable(.inputOutput))
    )
    #expect(failureProbe.observation.fstatDescriptors == [100, 100, 100])
    #expect(failureProbe.observation.fstatfsDescriptors.isEmpty)
  }

  @Test("Post-attempt failure and volume drift remain explicitly unavailable")
  func postObservationNeverInventsZero() {
    let before = purgeCapacityObservation(availableBytes: 12_288)
    let unavailableObserver = DescriptorQuarantinePurgeCapacityObserver(
      dependencies: DescriptorQuarantinePurgeCapacityObserverDependencies(
        fstat: { _ in .success(.init(device: 42)) },
        fstatfs: { _ in
          .failure(DescriptorQuarantinePurgeCapacityPOSIXError(code: EIO))
        }
      )
    )
    #expect(
      unavailableObserver.observeAfterAttempt(fromHeldDescriptor: 101, matching: before)
        == .unavailable
    )

    let driftedVolumeObserver = purgeCapacityObserver(
      fileSystemValue: purgeCapacityFileSystemValue(fileSystemIDSecond: 9)
    )
    #expect(
      driftedVolumeObserver.observeAfterAttempt(fromHeldDescriptor: 101, matching: before)
        == .unavailable
    )
  }

  @Test("Comparison describes increase, unchanged, decrease, and unavailable")
  func comparesObservedCapacityWithoutCausalClaim() {
    let before = purgeCapacityObservation(availableBytes: 10)

    #expect(
      DescriptorQuarantinePurgeCapacityObserver.compare(
        observationBefore: before,
        observationAfter: .available(purgeCapacityObservation(availableBytes: 18))
      ) == .increase(amount: 8)
    )
    #expect(
      DescriptorQuarantinePurgeCapacityObserver.compare(
        observationBefore: before,
        observationAfter: .available(purgeCapacityObservation(availableBytes: 10))
      ) == .unchanged
    )
    #expect(
      DescriptorQuarantinePurgeCapacityObserver.compare(
        observationBefore: before,
        observationAfter: .available(purgeCapacityObservation(availableBytes: 3))
      ) == .decrease(amount: 7)
    )
    #expect(
      DescriptorQuarantinePurgeCapacityObserver.compare(
        observationBefore: before,
        observationAfter: .unavailable
      ) == .unavailable
    )
    #expect(
      DescriptorQuarantinePurgeCapacityObserver.compare(
        observationBefore: before,
        observationAfter: .available(
          purgeCapacityObservation(fileSystemIDFirst: 99, availableBytes: 20)
        )
      ) == .unavailable
    )
  }

  @Test("Production observer can read a temporary-directory descriptor without mutation")
  func productionReadOnlySmoke() throws {
    let descriptor = NSTemporaryDirectory().withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }
    try #require(descriptor >= 0)
    defer { _ = Darwin.close(descriptor) }

    var information = stat()
    try #require(Darwin.fstat(descriptor, &information) == 0)
    let expectedDevice = UInt64(bitPattern: Int64(information.st_dev))

    let result = DescriptorQuarantinePurgeCapacityObserver().observeBeforeIntent(
      fromHeldDescriptor: descriptor,
      expectedDevice: expectedDevice
    )
    switch result {
    case .success(let observation):
      #expect(observation.volumeIdentity.device == expectedDevice)
    case .failure(let failure):
      Issue.record("Expected a read-only capacity observation, received \(failure)")
    }
  }
}

private func purgeCapacityObserver(
  device: UInt64 = 42,
  fileSystemValue: DescriptorQuarantinePurgeFStatFSValue = purgeCapacityFileSystemValue()
) -> DescriptorQuarantinePurgeCapacityObserver {
  DescriptorQuarantinePurgeCapacityObserver(
    dependencies: DescriptorQuarantinePurgeCapacityObserverDependencies(
      fstat: { _ in .success(.init(device: device)) },
      fstatfs: { _ in .success(fileSystemValue) }
    )
  )
}

private func purgeCapacityFileSystemValue(
  blockSize: UInt64 = 4_096,
  availableBlockCount: UInt64 = 2,
  fileSystemIDFirst: Int32 = 7,
  fileSystemIDSecond: Int32 = 8
) -> DescriptorQuarantinePurgeFStatFSValue {
  DescriptorQuarantinePurgeFStatFSValue(
    blockSize: blockSize,
    availableBlockCount: availableBlockCount,
    fileSystemIDFirst: fileSystemIDFirst,
    fileSystemIDSecond: fileSystemIDSecond
  )
}

private func purgeCapacityObservation(
  device: UInt64 = 42,
  fileSystemIDFirst: Int32 = 7,
  fileSystemIDSecond: Int32 = 8,
  availableBytes: UInt64 = 8_192
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

private struct PurgeCapacityObserverProbeObservation: Equatable {
  let fstatDescriptors: [Int32]
  let fstatfsDescriptors: [Int32]
}

private final class PurgeCapacityObserverProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var remainingFStatResults:
    [Result<DescriptorQuarantinePurgeFStatValue, DescriptorQuarantinePurgeCapacityPOSIXError>]
  private var remainingFStatFSResults:
    [Result<DescriptorQuarantinePurgeFStatFSValue, DescriptorQuarantinePurgeCapacityPOSIXError>]
  private var fstatDescriptors: [Int32] = []
  private var fstatfsDescriptors: [Int32] = []

  init(
    fstatResults: [Result<
      DescriptorQuarantinePurgeFStatValue, DescriptorQuarantinePurgeCapacityPOSIXError
    >],
    fstatfsResults: [Result<
      DescriptorQuarantinePurgeFStatFSValue, DescriptorQuarantinePurgeCapacityPOSIXError
    >]
  ) {
    remainingFStatResults = fstatResults
    remainingFStatFSResults = fstatfsResults
  }

  var observation: PurgeCapacityObserverProbeObservation {
    lock.withLock {
      PurgeCapacityObserverProbeObservation(
        fstatDescriptors: fstatDescriptors,
        fstatfsDescriptors: fstatfsDescriptors
      )
    }
  }

  func dependencies() -> DescriptorQuarantinePurgeCapacityObserverDependencies {
    DescriptorQuarantinePurgeCapacityObserverDependencies(
      fstat: { [self] descriptor in nextFStat(descriptor) },
      fstatfs: { [self] descriptor in nextFStatFS(descriptor) }
    )
  }

  private func nextFStat(
    _ descriptor: Int32
  ) -> Result<DescriptorQuarantinePurgeFStatValue, DescriptorQuarantinePurgeCapacityPOSIXError> {
    lock.withLock {
      fstatDescriptors.append(descriptor)
      guard !remainingFStatResults.isEmpty else {
        return .failure(DescriptorQuarantinePurgeCapacityPOSIXError(code: EIO))
      }
      return remainingFStatResults.removeFirst()
    }
  }

  private func nextFStatFS(
    _ descriptor: Int32
  ) -> Result<DescriptorQuarantinePurgeFStatFSValue, DescriptorQuarantinePurgeCapacityPOSIXError> {
    lock.withLock {
      fstatfsDescriptors.append(descriptor)
      guard !remainingFStatFSResults.isEmpty else {
        return .failure(DescriptorQuarantinePurgeCapacityPOSIXError(code: EIO))
      }
      return remainingFStatFSResults.removeFirst()
    }
  }
}
