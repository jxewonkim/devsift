import Darwin
import Foundation

/// A single validated POSIX path component suitable for an `*at` syscall.
struct DescriptorPathComponent: Equatable, Sendable {
  let bytes: [UInt8]

  init?(_ bytes: [UInt8]) {
    guard
      !bytes.isEmpty,
      bytes.count <= Int(NAME_MAX),
      !bytes.contains(0),
      !bytes.contains(0x2F),
      bytes != [0x2E],
      bytes != [0x2E, 0x2E]
    else {
      return nil
    }
    self.bytes = bytes
  }

  func withCString<Result>(
    _ body: (UnsafePointer<CChar>) throws -> Result
  ) rethrows -> Result {
    var terminatedBytes = bytes.map { CChar(bitPattern: $0) }
    terminatedBytes.append(0)
    return try terminatedBytes.withUnsafeBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }
}

struct DescriptorAbsolutePath {
  let components: [DescriptorPathComponent]

  init?(rawBytes: [UInt8]) {
    guard
      !rawBytes.isEmpty,
      rawBytes.count <= Int(PATH_MAX),
      rawBytes.first == 0x2F,
      rawBytes.last != 0x2F
    else {
      return nil
    }

    let rawComponents = rawBytes.dropFirst().split(
      separator: 0x2F,
      omittingEmptySubsequences: false
    )
    var validated: [DescriptorPathComponent] = []
    validated.reserveCapacity(rawComponents.count)
    for rawComponent in rawComponents {
      guard let component = DescriptorPathComponent(Array(rawComponent)) else {
        return nil
      }
      validated.append(component)
    }
    components = validated
  }
}

enum DescriptorObservationError: Error {
  case bindingChanged
  case crossedVolume
  case markerEntryLimitExceeded
  case protectedDescendantLimitExceeded
  case posix(Int32)
}

/// Descriptor reads normally cooperate with task cancellation. A filesystem
/// mutation that may already have linearized must explicitly ignore task
/// cancellation until its outcome has been reconciled and recorded.
enum DescriptorCancellationPolicy: Sendable {
  case observeTaskCancellation
  case ignoreTaskCancellation

  func checkpoint() throws {
    switch self {
    case .observeTaskCancellation:
      try Task.checkCancellation()
    case .ignoreTaskCancellation:
      break
    }
  }
}

struct DescriptorStatSnapshot: Sendable {
  let identity: FileIdentity
  let kind: FileSystemEntryKind
  let ownerUID: uid_t
  let permissionMode: mode_t
  let flags: UInt32
  let linkCount: UInt64
  let generation: UInt32
  let birthSeconds: Int
  let birthNanoseconds: Int
  let changeSeconds: Int
  let changeNanoseconds: Int
  let modificationSeconds: Int
  let modificationNanoseconds: Int

  static func read(
    from descriptor: Int32,
    cancellationPolicy: DescriptorCancellationPolicy = .observeTaskCancellation
  ) throws -> DescriptorStatSnapshot {
    var information = stat()
    try descriptorRetryingInterrupted(cancellationPolicy: cancellationPolicy) {
      guard Darwin.fstat(descriptor, &information) == 0 else {
        throw DescriptorObservationError.posix(errno)
      }
    }
    return DescriptorStatSnapshot(information: information)
  }

  static func read(
    at parentDescriptor: Int32,
    component: DescriptorPathComponent,
    cancellationPolicy: DescriptorCancellationPolicy = .observeTaskCancellation
  ) throws -> DescriptorStatSnapshot {
    var information = stat()
    try descriptorRetryingInterrupted(cancellationPolicy: cancellationPolicy) {
      try component.withCString { pointer in
        guard
          Darwin.fstatat(
            parentDescriptor,
            pointer,
            &information,
            AT_SYMLINK_NOFOLLOW
          ) == 0
        else {
          throw DescriptorObservationError.posix(errno)
        }
      }
    }
    return DescriptorStatSnapshot(information: information)
  }

  init(information: stat) {
    identity = FileIdentity(
      device: UInt64(bitPattern: Int64(information.st_dev)),
      inode: UInt64(information.st_ino)
    )
    kind = descriptorEntryKind(for: information.st_mode)
    ownerUID = information.st_uid
    permissionMode = information.st_mode & mode_t(0o7777)
    flags = information.st_flags
    linkCount = UInt64(information.st_nlink)
    generation = information.st_gen
    birthSeconds = information.st_birthtimespec.tv_sec
    birthNanoseconds = information.st_birthtimespec.tv_nsec
    changeSeconds = information.st_ctimespec.tv_sec
    changeNanoseconds = information.st_ctimespec.tv_nsec
    modificationSeconds = information.st_mtimespec.tv_sec
    modificationNanoseconds = information.st_mtimespec.tv_nsec
  }

  func sameBinding(as other: DescriptorStatSnapshot) -> Bool {
    identity == other.identity
      && kind == other.kind
      && generation == other.generation
      && birthSeconds == other.birthSeconds
      && birthNanoseconds == other.birthNanoseconds
  }

  func sameMutationState(as other: DescriptorStatSnapshot) -> Bool {
    changeSeconds == other.changeSeconds
      && changeNanoseconds == other.changeNanoseconds
      && modificationSeconds == other.modificationSeconds
      && modificationNanoseconds == other.modificationNanoseconds
  }

  func sameProtectedDescendantState(as other: DescriptorStatSnapshot) -> Bool {
    sameBinding(as: other)
      && sameMutationState(as: other)
      && ownerUID == other.ownerUID
      && linkCount == other.linkCount
  }

  /// Whole-second upper bound used by age policy. Subsecond timestamps round
  /// upward so truncation can never make an entry appear older than observed.
  var conservativeModificationUnixSeconds: Int64? {
    guard
      let seconds = Int64(exactly: modificationSeconds),
      seconds >= 0,
      modificationNanoseconds >= 0,
      modificationNanoseconds < 1_000_000_000
    else {
      return nil
    }
    guard modificationNanoseconds > 0 else {
      return seconds
    }
    let (ceiling, overflow) = seconds.addingReportingOverflow(1)
    return overflow ? nil : ceiling
  }
}

func descriptorOpenRoot(
  _ url: URL,
  cancellationPolicy: DescriptorCancellationPolicy = .observeTaskCancellation
) throws -> Int32 {
  var descriptor: Int32 = -1
  try descriptorRetryingInterrupted(cancellationPolicy: cancellationPolicy) {
    var failureCode: Int32 = EINVAL
    descriptor = url.withUnsafeFileSystemRepresentation { pointer in
      guard let pointer else { return -1 }
      let result = Darwin.open(
        pointer,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      if result < 0 { failureCode = errno }
      return result
    }
    guard descriptor >= 0 else {
      throw DescriptorObservationError.posix(failureCode)
    }
  }
  return descriptor
}

func descriptorOpenCurrentDirectory(
  _ descriptor: Int32,
  cancellationPolicy: DescriptorCancellationPolicy = .observeTaskCancellation
) throws -> Int32 {
  var opened: Int32 = -1
  try descriptorRetryingInterrupted(cancellationPolicy: cancellationPolicy) {
    var failureCode: Int32 = EINVAL
    opened = Darwin.openat(
      descriptor,
      ".",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    if opened < 0 { failureCode = errno }
    guard opened >= 0 else {
      throw DescriptorObservationError.posix(failureCode)
    }
  }
  return opened
}

func descriptorRawName(from entry: UnsafeMutablePointer<dirent>) -> [UInt8] {
  let length = Int(entry.pointee.d_namlen)
  return withUnsafeBytes(of: &entry.pointee.d_name) { rawBuffer in
    Array(rawBuffer.prefix(length))
  }
}

func descriptorOpenDirectory(
  at parentDescriptor: Int32,
  component: DescriptorPathComponent,
  cancellationPolicy: DescriptorCancellationPolicy = .observeTaskCancellation
) throws -> Int32 {
  var descriptor: Int32 = -1
  try descriptorRetryingInterrupted(cancellationPolicy: cancellationPolicy) {
    var failureCode: Int32 = EINVAL
    descriptor = component.withCString { pointer in
      let result = Darwin.openat(
        parentDescriptor,
        pointer,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      if result < 0 { failureCode = errno }
      return result
    }
    guard descriptor >= 0 else {
      throw DescriptorObservationError.posix(failureCode)
    }
  }
  return descriptor
}

func descriptorOpenTrustedDirectory(
  at parentDescriptor: Int32,
  component: DescriptorPathComponent,
  cancellationPolicy: DescriptorCancellationPolicy = .observeTaskCancellation
) throws -> Int32 {
  var descriptor: Int32 = -1
  try descriptorRetryingInterrupted(cancellationPolicy: cancellationPolicy) {
    var failureCode: Int32 = EINVAL
    descriptor = component.withCString { pointer in
      let result = Darwin.openat(
        parentDescriptor,
        pointer,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
      )
      if result < 0 { failureCode = errno }
      return result
    }
    guard descriptor >= 0 else {
      throw DescriptorObservationError.posix(failureCode)
    }
  }
  return descriptor
}

func descriptorSnapshot(
  atAbsoluteComponents components: [DescriptorPathComponent],
  homeComponentCount: Int,
  cancellationPolicy: DescriptorCancellationPolicy = .observeTaskCancellation
) throws -> DescriptorStatSnapshot {
  guard homeComponentCount > 0, homeComponentCount < components.count else {
    throw DescriptorObservationError.posix(EINVAL)
  }

  var descriptor: Int32 = -1
  try descriptorRetryingInterrupted(cancellationPolicy: cancellationPolicy) {
    descriptor = Darwin.open(
      "/",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw DescriptorObservationError.posix(errno)
    }
  }

  do {
    var homeDevice: UInt64?
    var finalSnapshot: DescriptorStatSnapshot?
    for (index, component) in components.enumerated() {
      try cancellationPolicy.checkpoint()
      let childDescriptor = try descriptorOpenTrustedDirectory(
        at: descriptor,
        component: component,
        cancellationPolicy: cancellationPolicy
      )
      descriptorCloseIgnoringErrors(descriptor)
      descriptor = childDescriptor

      let openedComponentCount = index + 1
      guard openedComponentCount >= homeComponentCount else {
        continue
      }
      let snapshot = try DescriptorStatSnapshot.read(
        from: descriptor,
        cancellationPolicy: cancellationPolicy
      )
      if openedComponentCount == homeComponentCount {
        homeDevice = snapshot.identity.device
      } else {
        guard let homeDevice, snapshot.identity.device == homeDevice else {
          throw DescriptorObservationError.crossedVolume
        }
      }
      finalSnapshot = snapshot
    }
    guard let finalSnapshot else {
      throw DescriptorObservationError.posix(EINVAL)
    }
    descriptorCloseIgnoringErrors(descriptor)
    return finalSnapshot
  } catch {
    descriptorCloseIgnoringErrors(descriptor)
    throw error
  }
}

func descriptorAbsolutePath(for url: URL) -> DescriptorRawAbsolutePath? {
  url.withUnsafeFileSystemRepresentation { representation in
    guard let representation else {
      return nil
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(min(Int(PATH_MAX), 256))
    for offset in 0...Int(PATH_MAX) {
      let byte = UInt8(bitPattern: representation[offset])
      if byte == 0 {
        return DescriptorRawAbsolutePath(rawBytes: bytes)
      }
      guard offset < Int(PATH_MAX) else {
        return nil
      }
      bytes.append(byte)
    }
    return nil
  }
}

/// Returns one bounded identity for the current non-root POSIX account. A
/// set-user-ID or root process is intentionally outside this policy.
func currentNonRootAccountUID() -> RuleObserved<uid_t> {
  let realUser = Darwin.getuid()
  let effectiveUser = Darwin.geteuid()
  guard realUser != 0, realUser == effectiveUser else {
    return .unknown(.unsupported)
  }
  return .known(realUser)
}

struct DescriptorRawAbsolutePath {
  let rawComponents: [[UInt8]]

  init?(rawBytes: [UInt8]) {
    guard
      !rawBytes.isEmpty,
      rawBytes.count <= Int(PATH_MAX),
      rawBytes.first == 0x2F
    else {
      return nil
    }
    if rawBytes == [0x2F] {
      rawComponents = []
      return
    }
    rawComponents = rawBytes.dropFirst().split(
      separator: 0x2F,
      omittingEmptySubsequences: false
    ).map(Array.init)
  }
}

func descriptorComponents(
  _ rawComponents: [[UInt8]]
) -> [DescriptorPathComponent]? {
  var result: [DescriptorPathComponent] = []
  result.reserveCapacity(rawComponents.count)
  for rawComponent in rawComponents {
    guard let component = DescriptorPathComponent(rawComponent) else {
      return nil
    }
    result.append(component)
  }
  return result
}

/// Reads the real user's passwd home as bounded raw bytes. Environment-based
/// home overrides are intentionally not trusted policy input.
func currentUIDRawHome() -> RuleObserved<[UInt8]> {
  let realUser = Darwin.getuid()
  let effectiveUser = Darwin.geteuid()
  guard realUser != 0, realUser == effectiveUser else {
    return .unknown(.unsupported)
  }

  let recommendedBufferSize = Darwin.sysconf(_SC_GETPW_R_SIZE_MAX)
  let maximumBufferSize = 64 * 1_024
  guard
    recommendedBufferSize > 0,
    let bufferSize = Int(exactly: recommendedBufferSize),
    bufferSize <= maximumBufferSize
  else {
    return .unknown(.resourceLimit)
  }

  var record = passwd()
  var resolvedRecord: UnsafeMutablePointer<passwd>?
  var buffer = [CChar](repeating: 0, count: bufferSize)
  let result: (status: Int32, bytes: [UInt8]?) = buffer.withUnsafeMutableBufferPointer {
    bufferPointer in
    guard let baseAddress = bufferPointer.baseAddress else {
      return (ENOMEM, nil)
    }
    let status = Darwin.getpwuid_r(
      realUser,
      &record,
      baseAddress,
      bufferPointer.count,
      &resolvedRecord
    )
    guard status == 0, resolvedRecord != nil, let home = record.pw_dir else {
      return (status, nil)
    }
    return (
      status,
      boundedCStringBytes(
        home,
        storageBase: baseAddress,
        storageCount: bufferPointer.count
      )
    )
  }

  guard result.status == 0 else {
    return .unknown(descriptorUnknownReason(forPOSIXCode: result.status))
  }
  guard let bytes = result.bytes else {
    return resolvedRecord == nil ? .unknown(.notCollected) : .unknown(.invalidMetadata)
  }
  guard DescriptorAbsolutePath(rawBytes: bytes) != nil else {
    return .unknown(.invalidMetadata)
  }
  return .known(bytes)
}

func boundedCStringBytes(
  _ value: UnsafePointer<CChar>,
  storageBase: UnsafePointer<CChar>,
  storageCount: Int
) -> [UInt8]? {
  let startAddress = UInt(bitPattern: value)
  let storageAddress = UInt(bitPattern: storageBase)
  let (storageEnd, overflow) = storageAddress.addingReportingOverflow(UInt(storageCount))
  guard
    !overflow,
    startAddress >= storageAddress,
    startAddress < storageEnd
  else {
    return nil
  }

  let available = Int(storageEnd - startAddress)
  var result: [UInt8] = []
  result.reserveCapacity(min(available, Int(PATH_MAX)))
  for offset in 0..<available {
    let byte = UInt8(bitPattern: value[offset])
    if byte == 0 {
      return result
    }
    guard result.count < Int(PATH_MAX) else {
      return nil
    }
    result.append(byte)
  }
  return nil
}

func descriptorRetryingInterrupted(
  maximumAttempts: Int = 3,
  cancellationPolicy: DescriptorCancellationPolicy = .observeTaskCancellation,
  _ operation: () throws -> Void
) throws {
  var attempt = 0
  while true {
    try cancellationPolicy.checkpoint()
    do {
      try operation()
      return
    } catch DescriptorObservationError.posix(EINTR) where attempt + 1 < maximumAttempts {
      attempt += 1
    }
  }
}

func descriptorCloseIgnoringErrors(_ descriptor: Int32) {
  _ = Darwin.close(descriptor)
}

/// Returns whether Darwin exposes any extended ACL for a held descriptor.
///
/// This bounded read intentionally does not observe task cancellation: callers
/// also use it while reconciling a namespace mutation that may have linearized.
func descriptorHasExtendedACL(_ descriptor: Int32) throws -> Bool {
  for attempt in 0..<3 {
    errno = 0
    if let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
      _ = Darwin.acl_free(UnsafeMutableRawPointer(acl))
      return true
    }

    let failureCode = errno
    if failureCode == ENOENT {
      return false
    }
    if failureCode == EINTR, attempt + 1 < 3 {
      continue
    }
    throw DescriptorObservationError.posix(failureCode)
  }
  throw DescriptorObservationError.posix(EINTR)
}

func descriptorEntryKind(for mode: mode_t) -> FileSystemEntryKind {
  switch mode & mode_t(S_IFMT) {
  case mode_t(S_IFREG): .regularFile
  case mode_t(S_IFDIR): .directory
  case mode_t(S_IFLNK): .symbolicLink
  default: .other
  }
}

func descriptorUnknownReason(for error: Error) -> RuleUnknownReason {
  if let observationError = error as? DescriptorObservationError {
    switch observationError {
    case .bindingChanged:
      return .changedDuringObservation
    case .crossedVolume:
      return .changedDuringObservation
    case .markerEntryLimitExceeded:
      return .resourceLimit
    case .protectedDescendantLimitExceeded:
      return .resourceLimit
    case .posix(let code):
      return descriptorUnknownReason(forPOSIXCode: code)
    }
  }

  let nsError = error as NSError
  if nsError.domain == NSPOSIXErrorDomain, let code = Int32(exactly: nsError.code) {
    return descriptorUnknownReason(forPOSIXCode: code)
  }
  return .unspecified
}

func descriptorUnknownReason(forPOSIXCode code: Int32) -> RuleUnknownReason {
  switch code {
  case EACCES, EPERM: .permissionDenied
  case ENOENT, ENOTDIR, ELOOP, ESTALE, EAGAIN, EXDEV:
    .changedDuringObservation
  case EMFILE, ENFILE, ENOMEM, ERANGE: .resourceLimit
  case EINVAL, EOVERFLOW, ENAMETOOLONG: .invalidMetadata
  case ENOTSUP: .unsupported
  default: .unspecified
  }
}
