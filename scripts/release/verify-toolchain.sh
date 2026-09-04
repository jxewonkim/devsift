#!/bin/sh

set -eu

fail() {
  printf 'release toolchain verification failed: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 0 ] || fail "usage: $0"
[ "$(uname -s)" = "Darwin" ] || fail "release builds require macOS"
[ "$(uname -m)" = "arm64" ] || fail "release builds require an arm64 host"

expected_developer_directory=/Applications/Xcode_16.4.app/Contents/Developer
[ "${DEVELOPER_DIR:-}" = "$expected_developer_directory" ] \
  || fail "DEVELOPER_DIR must select Xcode 16.4"

for command_name in xcodebuild xcrun; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required command is unavailable: $command_name"
done

expected_xcode=$(printf '%s\n%s' 'Xcode 16.4' 'Build version 16F6')
actual_xcode=$(xcodebuild -version)
[ "$actual_xcode" = "$expected_xcode" ] \
  || fail "expected Xcode 16.4 build 16F6"

sdk_version=$(xcrun --sdk macosx --show-sdk-version)
[ "$sdk_version" = "15.5" ] || fail "expected the macOS 15.5 SDK"

expected_swift_path="$expected_developer_directory/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
swift_path=$(xcrun --find swift)
[ "$swift_path" = "$expected_swift_path" ] \
  || fail "Swift does not come from the pinned Xcode toolchain"
[ "$(command -v swift)" = "/usr/bin/swift" ] \
  || fail "the unprefixed swift command must be Apple's xcrun shim"

expected_swift='Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)'
actual_swift=$(xcrun swift --version | sed -n '1p')
[ "$actual_swift" = "$expected_swift" ] \
  || fail "expected Apple Swift 6.1.2 from Xcode 16.4"
[ "$(swift --version | sed -n '1p')" = "$expected_swift" ] \
  || fail "the unprefixed swift command bypasses the pinned toolchain"

printf 'release toolchain verified: Xcode 16.4 (16F6), macOS SDK 15.5, Swift 6.1.2\n'
