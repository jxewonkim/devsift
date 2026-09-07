#!/bin/sh

set -eu

LC_ALL=C
export LC_ALL

fail() {
  printf 'release app verification failed: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  fail "usage: $0 adhoc|signed|release APP_BUNDLE EXPECTED_VERSION [EXPECTED_TEAM_ID]"
fi

verification_mode=$1
app_bundle=$2
expected_version=$3
expected_team_id=${4:-}

case "$verification_mode" in
  adhoc)
    [ "$#" -eq 3 ] \
      || fail "ad-hoc verification does not accept a team identifier"
    ;;
  signed | release)
    [ "$#" -eq 4 ] \
      || fail "$verification_mode verification requires the expected Apple team identifier"
    printf '%s\n' "$expected_team_id" | grep -Eq '^[A-Z0-9]{10}$' \
      || fail "expected Apple team identifier must contain 10 uppercase letters or digits"
    ;;
  *)
    fail "verification mode must be adhoc, signed, or release"
    ;;
esac

[ "$(uname -s)" = "Darwin" ] || fail "verification requires macOS"

printf '%s\n' "$expected_version" \
  | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-alpha\.[1-9][0-9]*$' \
  || fail "expected version is not a canonical alpha semantic version"

short_version=${expected_version%-alpha.*}

[ -d "$app_bundle" ] || fail "application bundle is missing: $app_bundle"
[ ! -L "$app_bundle" ] || fail "application bundle must not be a symbolic link"
[ "$(basename -- "$app_bundle")" = "DevSift.app" ] \
  || fail "application bundle must be named DevSift.app"

app_parent=$(CDPATH= cd -- "$(dirname -- "$app_bundle")" && pwd -P)
app_bundle="$app_parent/DevSift.app"

for command_name in awk cmp codesign file find grep lipo nm otool plutil sed stat strings tr wc; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required command is unavailable: $command_name"
done
if [ "$verification_mode" = "release" ]; then
  for command_name in spctl xcrun; do
    command -v "$command_name" >/dev/null 2>&1 \
      || fail "required command is unavailable: $command_name"
  done
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/../.." && pwd -P)
build_number_file="$repository_root/APP_BUILD_NUMBER"
[ -f "$build_number_file" ] && [ ! -L "$build_number_file" ] \
  || fail "repository APP_BUILD_NUMBER is unavailable for comparison"
build_number_line_count=$(awk 'END { print NR }' "$build_number_file")
[ "$build_number_line_count" -eq 1 ] \
  || fail "APP_BUILD_NUMBER must contain exactly one line"
build_number_newline_count=$(wc -l < "$build_number_file" | tr -d '[:space:]')
[ "$build_number_newline_count" -eq 1 ] \
  || fail "APP_BUILD_NUMBER must end with exactly one newline"
apple_bundle_version=$(sed -n '1p' "$build_number_file")
printf '%s\n' "$apple_bundle_version" | grep -Eq '^[1-9][0-9]{0,3}$' \
  || fail "APP_BUILD_NUMBER must be a canonical positive integer of at most four digits"

contents="$app_bundle/Contents"
info_plist="$contents/Info.plist"
executable="$contents/MacOS/DevSift"
license="$contents/Resources/LICENSE"
version_file="$contents/Resources/VERSION"
signature_resources="$contents/_CodeSignature/CodeResources"
stapled_ticket="$contents/CodeResources"

expected_members=$(printf '%s\n' \
  "." \
  "Contents" \
  "Contents/Info.plist" \
  "Contents/MacOS" \
  "Contents/MacOS/DevSift" \
  "Contents/Resources" \
  "Contents/Resources/LICENSE" \
  "Contents/Resources/VERSION" \
  "Contents/_CodeSignature" \
  "Contents/_CodeSignature/CodeResources")
if [ "$verification_mode" = "release" ]; then
  expected_members=$(printf '%s\n%s\n' "$expected_members" "Contents/CodeResources" | sort)
fi

actual_members=$(
  find "$app_bundle" -print \
    | awk -v root="$app_bundle" '
        $0 == root { print "."; next }
        index($0, root "/") == 1 { print substr($0, length(root) + 2); next }
        { exit 1 }
      ' \
    | sort
)
[ "$actual_members" = "$expected_members" ] \
  || fail "application bundle membership differs from the fixed $verification_mode allowlist"

[ -d "$contents" ] && [ ! -L "$contents" ] \
  || fail "Contents must be a real directory"
[ -d "$contents/MacOS" ] && [ ! -L "$contents/MacOS" ] \
  || fail "Contents/MacOS must be a real directory"
[ -d "$contents/Resources" ] && [ ! -L "$contents/Resources" ] \
  || fail "Contents/Resources must be a real directory"
[ -d "$contents/_CodeSignature" ] && [ ! -L "$contents/_CodeSignature" ] \
  || fail "Contents/_CodeSignature must be a real directory"

for regular_file in \
  "$info_plist" \
  "$executable" \
  "$license" \
  "$version_file" \
  "$signature_resources"; do
  [ -f "$regular_file" ] && [ ! -L "$regular_file" ] \
    || fail "bundle member must be a real regular file: $regular_file"
done
if [ "$verification_mode" = "release" ]; then
  [ -f "$stapled_ticket" ] && [ ! -L "$stapled_ticket" ] \
    || fail "release bundle is missing its real stapled ticket"
else
  [ ! -e "$stapled_ticket" ] && [ ! -L "$stapled_ticket" ] \
    || fail "$verification_mode bundle unexpectedly contains a stapled ticket"
fi

assert_mode() {
  path=$1
  expected_mode=$2
  actual_mode=$(stat -f '%Lp' "$path")
  [ "$actual_mode" = "$expected_mode" ] \
    || fail "$path has mode $actual_mode instead of $expected_mode"
}

assert_mode "$app_bundle" 755
assert_mode "$contents" 755
assert_mode "$contents/MacOS" 755
assert_mode "$contents/Resources" 755
assert_mode "$contents/_CodeSignature" 755
assert_mode "$info_plist" 644
assert_mode "$executable" 755
assert_mode "$license" 644
assert_mode "$version_file" 644
assert_mode "$signature_resources" 644
if [ "$verification_mode" = "release" ]; then
  assert_mode "$stapled_ticket" 644
fi
[ -x "$executable" ] || fail "main executable is not executable"

plutil -lint "$info_plist" >/dev/null \
  || fail "Info.plist is invalid"

expected_plist_keys=$(printf '%s\n' \
  "CFBundleDevelopmentRegion" \
  "CFBundleDisplayName" \
  "CFBundleExecutable" \
  "CFBundleIdentifier" \
  "CFBundleInfoDictionaryVersion" \
  "CFBundleName" \
  "CFBundlePackageType" \
  "CFBundleShortVersionString" \
  "CFBundleVersion" \
  "DevSiftReleaseVersion" \
  "LSApplicationCategoryType" \
  "LSMinimumSystemVersion" \
  "NSHighResolutionCapable")
actual_plist_keys=$(
  plutil -p "$info_plist" \
    | sed -n 's/^  "\([^"]*\)" =>.*/\1/p' \
    | sort
)
[ "$actual_plist_keys" = "$expected_plist_keys" ] \
  || fail "Info.plist keys differ from the reviewed allowlist"

assert_plist_value() {
  key=$1
  expected_value=$2
  actual_value=$(plutil -extract "$key" raw -o - "$info_plist" 2>/dev/null) \
    || fail "Info.plist is missing $key"
  [ "$actual_value" = "$expected_value" ] \
    || fail "Info.plist $key is $actual_value instead of $expected_value"
}

assert_plist_value CFBundleDevelopmentRegion en
assert_plist_value CFBundleDisplayName DevSift
assert_plist_value CFBundleExecutable DevSift
assert_plist_value CFBundleIdentifier io.github.jxewonkim.devsift
assert_plist_value CFBundleInfoDictionaryVersion 6.0
assert_plist_value CFBundleName DevSift
assert_plist_value CFBundlePackageType APPL
assert_plist_value CFBundleShortVersionString "$short_version"
assert_plist_value CFBundleVersion "$apple_bundle_version"
assert_plist_value DevSiftReleaseVersion "$expected_version"
assert_plist_value LSApplicationCategoryType public.app-category.utilities
assert_plist_value LSMinimumSystemVersion 14.0
assert_plist_value NSHighResolutionCapable true

[ -f "$repository_root/LICENSE" ] && [ ! -L "$repository_root/LICENSE" ] \
  || fail "repository LICENSE is unavailable for comparison"
cmp "$repository_root/LICENSE" "$license" \
  || fail "bundled LICENSE differs from the repository license"

version_line_count=$(awk 'END { print NR }' "$version_file")
[ "$version_line_count" -eq 1 ] \
  || fail "bundled VERSION must contain exactly one line"
version_newline_count=$(wc -l < "$version_file" | tr -d '[:space:]')
[ "$version_newline_count" -eq 1 ] \
  || fail "bundled VERSION must end with exactly one newline"
actual_version=$(sed -n '1p' "$version_file")
[ "$actual_version" = "$expected_version" ] \
  || fail "bundled VERSION is $actual_version instead of $expected_version"

file "$executable" | grep -Fq 'Mach-O universal binary' \
  || fail "main executable is not a Mach-O universal binary"
architectures=$(lipo -archs "$executable")
set -- $architectures
[ "$#" -eq 2 ] || fail "main executable must contain exactly two architectures"
has_arm64=false
has_x86_64=false
for architecture in "$@"; do
  case "$architecture" in
    arm64) has_arm64=true ;;
    x86_64) has_x86_64=true ;;
    *) fail "main executable contains unexpected architecture: $architecture" ;;
  esac
done
[ "$has_arm64" = true ] || fail "main executable is missing its arm64 slice"
[ "$has_x86_64" = true ] || fail "main executable is missing its x86_64 slice"

for architecture in arm64 x86_64; do
  load_commands=$(otool -l -arch "$architecture" "$executable")

  uuid_count=$(
    printf '%s\n' "$load_commands" \
      | awk '$1 == "cmd" && $2 == "LC_UUID" { count += 1 } END { print count + 0 }'
  )
  [ "$uuid_count" -eq 1 ] \
    || fail "$architecture slice must contain exactly one LC_UUID"

  signature_count=$(
    printf '%s\n' "$load_commands" \
      | awk '$1 == "cmd" && $2 == "LC_CODE_SIGNATURE" { count += 1 } END { print count + 0 }'
  )
  [ "$signature_count" -eq 1 ] \
    || fail "$architecture slice must contain exactly one LC_CODE_SIGNATURE"

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
      /usr/lib/swift | @loader_path | @executable_path/../Frameworks \
        | @executable_path/../lib) ;;
      *) fail "$architecture slice has an unsafe runtime path: $runtime_path" ;;
    esac
  done <<EOF
$runtime_paths
EOF

  dependencies=$(
    otool -L -arch "$architecture" "$executable" \
      | awk 'NR > 1 { print $1 }'
  )
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

if strings -a "$executable" \
  | grep -Eq '/Users/|/home/|/private/var/folders/|/private/tmp/devsift-|/Volumes/'; then
  fail "main executable contains a local build or account path"
fi
if nm -a "$executable" 2>/dev/null \
  | grep -Eq '/Users/|/home/|/private/var/folders/|/private/tmp/devsift-|/Volumes/'; then
  fail "main executable symbols contain a local build or account path"
fi

codesign --verify --all-architectures --strict --verbose=2 "$app_bundle"
signature_details=$(codesign --display --verbose=4 "$app_bundle" 2>&1)
printf '%s\n' "$signature_details" \
  | grep -Fxq 'Identifier=io.github.jxewonkim.devsift' \
  || fail "code-signing identifier does not match the bundle identifier"
printf '%s\n' "$signature_details" \
  | grep -Eq '^CodeDirectory .* flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' \
  || fail "application signature does not enable the hardened runtime"

temporary_root=$(mktemp -d /private/tmp/devsift-app-verify.XXXXXX)
case "$temporary_root" in
  /private/tmp/devsift-app-verify.*) ;;
  *) fail "temporary entitlement path is outside the fixed namespace" ;;
esac
cleanup() {
  case "${temporary_root:-}" in
    /private/tmp/devsift-app-verify.*)
      rm -rf -- "$temporary_root"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

entitlements="$temporary_root/entitlements.plist"
codesign --display --xml --entitlements "$entitlements" "$app_bundle" \
  >/dev/null 2>&1 \
  || fail "application entitlements could not be extracted"
if [ -e "$entitlements" ] && [ -s "$entitlements" ]; then
  plutil -lint "$entitlements" >/dev/null \
    || fail "embedded application entitlements are invalid"
  entitlement_projection=$(plutil -p "$entitlements")
  empty_entitlement_projection=$(printf '{\n}')
  [ "$entitlement_projection" = "$empty_entitlement_projection" ] \
    || fail "application requests unreviewed entitlements"
fi

if [ "$verification_mode" = "adhoc" ]; then
  printf '%s\n' "$signature_details" | grep -Fxq 'Signature=adhoc' \
    || fail "local application must carry an explicit ad-hoc signature"
  printf '%s\n' "$signature_details" | grep -Fxq 'TeamIdentifier=not set' \
    || fail "ad-hoc application unexpectedly carries a team identifier"
  if printf '%s\n' "$signature_details" | grep -Eq '^Authority='; then
    fail "ad-hoc application unexpectedly carries a signing authority"
  fi
  if printf '%s\n' "$signature_details" | grep -Eq '^Timestamp='; then
    fail "ad-hoc application unexpectedly carries a secure timestamp"
  fi
else
  if printf '%s\n' "$signature_details" | grep -Fxq 'Signature=adhoc'; then
    fail "release application is ad-hoc signed"
  fi
  printf '%s\n' "$signature_details" \
    | grep -Eq '^Authority=Developer ID Application:' \
    || fail "release application is not signed by a Developer ID Application certificate"
  printf '%s\n' "$signature_details" \
    | grep -Fxq "TeamIdentifier=$expected_team_id" \
    || fail "release application team identifier does not match the expected team"
  printf '%s\n' "$signature_details" | grep -Eq '^Timestamp=.+$' \
    || fail "release application signature has no secure timestamp"
  if printf '%s\n' "$signature_details" | grep -Fxq 'Timestamp=none'; then
    fail "release application signature has no secure timestamp"
  fi

  if [ "$verification_mode" = "release" ]; then
    xcrun stapler validate -v "$app_bundle" \
      || fail "release application does not carry a valid notarization ticket"

    if ! gatekeeper_details=$(spctl --assess --type execute --verbose=4 "$app_bundle" 2>&1); then
      printf '%s\n' "$gatekeeper_details" >&2
      fail "Gatekeeper rejected the release application"
    fi
    printf '%s\n' "$gatekeeper_details" | grep -Eq ': accepted$' \
      || fail "Gatekeeper assessment did not report acceptance"
    printf '%s\n' "$gatekeeper_details" | grep -Fxq 'source=Notarized Developer ID' \
      || fail "Gatekeeper did not identify a notarized Developer ID source"
    printf '%s\n' "$gatekeeper_details" \
      | grep -Eq '^origin=Developer ID Application:' \
      || fail "Gatekeeper did not identify a Developer ID Application origin"
  fi
fi

printf 'release app verified: %s (%s; %s)\n' \
  "$expected_version" \
  "$verification_mode" \
  "$architectures"
