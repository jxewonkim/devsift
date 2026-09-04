#!/bin/sh

set -eu

fail() {
  printf 'release CLI verification failed: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -ne 2 ]; then
  fail "usage: $0 BINARY EXPECTED_VERSION"
fi

binary=$1
expected_version=$2

[ "$(uname -s)" = "Darwin" ] || fail "verification requires macOS"
[ -f "$binary" ] || fail "binary is missing: $binary"
[ ! -L "$binary" ] || fail "binary must not be a symbolic link"
[ -x "$binary" ] || fail "binary is not executable"

for command_name in codesign file lipo otool strings; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required command is unavailable: $command_name"
done

architectures=$(lipo -archs "$binary")
set -- $architectures
[ "$#" -eq 2 ] || fail "binary must contain exactly two architectures"

has_arm64=false
has_x86_64=false
for architecture in "$@"; do
  case "$architecture" in
    arm64) has_arm64=true ;;
    x86_64) has_x86_64=true ;;
    *) fail "unexpected architecture: $architecture" ;;
  esac
done
[ "$has_arm64" = true ] || fail "arm64 slice is missing"
[ "$has_x86_64" = true ] || fail "x86_64 slice is missing"

for architecture in arm64 x86_64; do
  load_commands=$(otool -l -arch "$architecture" "$binary")

  uuid_count=$(
    printf '%s\n' "$load_commands" \
      | awk '$1 == "cmd" && $2 == "LC_UUID" { count += 1 } END { print count + 0 }'
  )
  [ "$uuid_count" -eq 1 ] \
    || fail "$architecture slice must contain exactly one LC_UUID"

  minimum_versions=$(
    printf '%s\n' "$load_commands" \
      | awk '
          $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build = 1; next }
          in_build && $1 == "minos" { print $2; in_build = 0 }
        '
  )
  [ "$minimum_versions" = "14.0" ] \
    || fail "$architecture slice must target exactly macOS 14.0"

  runtime_paths=$(
    printf '%s\n' "$load_commands" \
      | awk '
          $1 == "cmd" { in_rpath = ($2 == "LC_RPATH"); next }
          in_rpath && $1 == "path" { print $2; in_rpath = 0 }
        '
  )
  while IFS= read -r runtime_path; do
    [ -n "$runtime_path" ] || continue
    case "$runtime_path" in
      /usr/lib/swift | @loader_path | @executable_path/../lib) ;;
      *) fail "$architecture slice has an unsafe runtime path: $runtime_path" ;;
    esac
  done <<EOF
$runtime_paths
EOF

  dependencies=$(otool -L -arch "$architecture" "$binary" | awk 'NR > 1 { print $1 }')
  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    case "$dependency" in
      /usr/lib/* | /System/Library/*) ;;
      *) fail "$architecture slice has a non-system dependency: $dependency" ;;
    esac
  done <<EOF
$dependencies
EOF
done

if LC_ALL=C strings -a "$binary" \
  | LC_ALL=C grep -Eq '/Users/|/home/|/private/var/folders/|/private/tmp/devsift-|/Volumes/'; then
  fail "binary contains a local build or account path"
fi

codesign --verify --all-architectures --strict --verbose=2 "$binary"
signature_details=$(codesign -dv --verbose=2 "$binary" 2>&1)
printf '%s\n' "$signature_details" | LC_ALL=C grep -Fq 'Signature=adhoc' \
  || fail "binary must carry an explicit ad-hoc signature"
printf '%s\n' "$signature_details" | LC_ALL=C grep -Fq 'TeamIdentifier=not set' \
  || fail "binary unexpectedly carries a team identifier"

actual_version=$("$binary" --version)
[ "$actual_version" = "$expected_version" ] \
  || fail "binary reports $actual_version instead of $expected_version"

expected_status=$(printf '%s\n%s' \
  "DevSift $expected_version (scan-only)" \
  "Read-only scanning and policy classification are available. This build cannot delete, move, or modify files.")
actual_status=$("$binary" status)
[ "$actual_status" = "$expected_status" ] \
  || fail "binary status does not match the read-only release contract"

printf 'release CLI verified: %s (%s)\n' "$expected_version" "$architectures"
