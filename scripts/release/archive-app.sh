#!/bin/sh

set -eu

LC_ALL=C
TZ=UTC
export LC_ALL TZ

fail() {
  printf 'app archive failed: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -ne 3 ]; then
  fail "usage: $0 APP_BUNDLE OUTPUT_DIRECTORY EXPECTED_VERSION"
fi

[ "$(uname -s)" = "Darwin" ] || fail "archiving requires macOS"

app_bundle=$1
output_directory=$2
expected_version=$3

printf '%s\n' "$expected_version" \
  | LC_ALL=C grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-alpha\.[1-9][0-9]*$' \
  || fail "expected version is not a canonical alpha semantic version"

[ -d "$app_bundle" ] || fail "app bundle is missing: $app_bundle"
[ ! -L "$app_bundle" ] || fail "app bundle must not be a symbolic link"
[ "$(basename -- "$app_bundle")" = "DevSift.app" ] \
  || fail "app bundle must be named DevSift.app"
[ -n "$output_directory" ] || fail "output directory must not be empty"

for command_name in \
  awk chmod codesign cp find grep plutil sed shasum sort touch tr unzip wc xattr zip; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required command is unavailable: $command_name"
done

app_parent=$(CDPATH= cd -- "$(dirname -- "$app_bundle")" && pwd -P)
app_bundle="$app_parent/DevSift.app"

if [ -e "$output_directory" ]; then
  [ -d "$output_directory" ] \
    || fail "output path exists and is not a directory: $output_directory"
  [ ! -L "$output_directory" ] \
    || fail "output directory must not be a symbolic link"
else
  mkdir -p "$output_directory"
fi
output_directory=$(CDPATH= cd -- "$output_directory" && pwd -P)

case "$output_directory/" in
  "$app_bundle"/*)
    fail "output directory must not be inside the app bundle"
    ;;
esac

info_plist="$app_bundle/Contents/Info.plist"
executable="$app_bundle/Contents/MacOS/DevSift"
license="$app_bundle/Contents/Resources/LICENSE"
version_file="$app_bundle/Contents/Resources/VERSION"
signature_resources="$app_bundle/Contents/_CodeSignature/CodeResources"
stapled_ticket="$app_bundle/Contents/CodeResources"

for required_file in \
  "$info_plist" \
  "$executable" \
  "$license" \
  "$version_file" \
  "$signature_resources"; do
  [ -f "$required_file" ] || fail "required bundle file is missing: $required_file"
  [ ! -L "$required_file" ] \
    || fail "bundle files must not be symbolic links: $required_file"
done
[ -x "$executable" ] || fail "bundle executable is not executable"

actual_version=$(plutil -extract DevSiftReleaseVersion raw -o - "$info_plist")
[ "$actual_version" = "$expected_version" ] \
  || fail "bundle version $actual_version does not match $expected_version"
resource_version=$(sed -n '1p' "$version_file")
[ "$resource_version" = "$expected_version" ] \
  || fail "resource VERSION $resource_version does not match $expected_version"
[ "$(awk 'END { print NR }' "$version_file")" -eq 1 ] \
  || fail "resource VERSION must contain exactly one line"

expected_tree=$(printf '%s\n' \
  "DevSift.app" \
  "DevSift.app/Contents" \
  "DevSift.app/Contents/Info.plist" \
  "DevSift.app/Contents/MacOS" \
  "DevSift.app/Contents/MacOS/DevSift" \
  "DevSift.app/Contents/Resources" \
  "DevSift.app/Contents/Resources/LICENSE" \
  "DevSift.app/Contents/Resources/VERSION" \
  "DevSift.app/Contents/_CodeSignature" \
  "DevSift.app/Contents/_CodeSignature/CodeResources")

if [ -e "$stapled_ticket" ]; then
  [ -f "$stapled_ticket" ] || fail "stapled ticket is not a regular file"
  [ ! -L "$stapled_ticket" ] || fail "stapled ticket must not be a symbolic link"
  expected_tree=$(printf '%s\n%s' \
    "$expected_tree" \
    "DevSift.app/Contents/CodeResources")
fi

actual_tree=$(
  find "$app_bundle" -print \
    | awk -v root="$app_parent/" '
        index($0, root) == 1 { print substr($0, length(root) + 1); next }
        { exit 1 }
      ' \
    | sort
)
expected_tree=$(printf '%s\n' "$expected_tree" | sort)
[ "$actual_tree" = "$expected_tree" ] \
  || fail "bundle membership differs from the fixed allowlist"

chmod 0755 \
  "$app_bundle" \
  "$app_bundle/Contents" \
  "$app_bundle/Contents/MacOS" \
  "$app_bundle/Contents/Resources" \
  "$app_bundle/Contents/_CodeSignature" \
  "$executable"
chmod 0644 \
  "$info_plist" \
  "$license" \
  "$version_file" \
  "$signature_resources"
if [ -f "$stapled_ticket" ]; then
  chmod 0644 "$stapled_ticket"
fi

chmod -N \
  "$app_bundle" \
  "$app_bundle/Contents" \
  "$app_bundle/Contents/MacOS" \
  "$app_bundle/Contents/Resources" \
  "$app_bundle/Contents/_CodeSignature" \
  "$info_plist" \
  "$executable" \
  "$license" \
  "$version_file" \
  "$signature_resources"
if [ -f "$stapled_ticket" ]; then
  chmod -N "$stapled_ticket"
fi

touch -t 200001010000 \
  "$info_plist" \
  "$executable" \
  "$license" \
  "$version_file" \
  "$signature_resources"
if [ -f "$stapled_ticket" ]; then
  touch -t 200001010000 "$stapled_ticket"
fi
touch -t 200001010000 \
  "$app_bundle/Contents/MacOS" \
  "$app_bundle/Contents/Resources" \
  "$app_bundle/Contents/_CodeSignature" \
  "$app_bundle/Contents" \
  "$app_bundle"

codesign --verify --all-architectures --strict --verbose=2 "$app_bundle"

archive_name="DevSift-$expected_version-macos-universal.zip"
archive_path="$output_directory/$archive_name"
checksum_path="$output_directory/SHA256SUMS"
[ ! -e "$archive_path" ] || fail "archive already exists: $archive_path"
[ ! -L "$archive_path" ] || fail "archive path must not be a symbolic link"
[ ! -e "$checksum_path" ] || fail "checksum file already exists: $checksum_path"
[ ! -L "$checksum_path" ] || fail "checksum path must not be a symbolic link"

archive_stage=$(mktemp -d /private/tmp/devsift-app-archive.XXXXXX)
case "$archive_stage" in
  /private/tmp/devsift-app-archive.*) ;;
  *) fail "temporary archive path is outside the fixed namespace" ;;
esac

cleanup() {
  case "${archive_stage:-}" in
    /private/tmp/devsift-app-archive.*)
      rm -rf -- "$archive_stage"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

temporary_archive="$archive_stage/$archive_name"
(
  cd "$app_parent"
  COPYFILE_DISABLE=1 zip -X -q -9 "$temporary_archive" \
    "DevSift.app/" \
    "DevSift.app/Contents/" \
    "DevSift.app/Contents/Info.plist" \
    "DevSift.app/Contents/MacOS/" \
    "DevSift.app/Contents/MacOS/DevSift" \
    "DevSift.app/Contents/Resources/" \
    "DevSift.app/Contents/Resources/LICENSE" \
    "DevSift.app/Contents/Resources/VERSION" \
    "DevSift.app/Contents/_CodeSignature/" \
    "DevSift.app/Contents/_CodeSignature/CodeResources"
  if [ -f "$stapled_ticket" ]; then
    COPYFILE_DISABLE=1 zip -X -q -9 "$temporary_archive" \
      "DevSift.app/Contents/CodeResources"
  fi
)

expected_members=$(printf '%s\n' \
  "DevSift.app/" \
  "DevSift.app/Contents/" \
  "DevSift.app/Contents/Info.plist" \
  "DevSift.app/Contents/MacOS/" \
  "DevSift.app/Contents/MacOS/DevSift" \
  "DevSift.app/Contents/Resources/" \
  "DevSift.app/Contents/Resources/LICENSE" \
  "DevSift.app/Contents/Resources/VERSION" \
  "DevSift.app/Contents/_CodeSignature/" \
  "DevSift.app/Contents/_CodeSignature/CodeResources")
if [ -f "$stapled_ticket" ]; then
  expected_members=$(printf '%s\n%s' \
    "$expected_members" \
    "DevSift.app/Contents/CodeResources")
fi
actual_members=$(unzip -Z1 "$temporary_archive")
[ "$actual_members" = "$expected_members" ] \
  || fail "archive membership differs from the fixed allowlist"
unzip -tq "$temporary_archive" >/dev/null \
  || fail "archive integrity verification failed"

cp "$temporary_archive" "$archive_path"
xattr -c "$archive_path"
chmod 0644 "$archive_path"
touch -t 200001010000 "$archive_path"

(
  cd "$output_directory"
  shasum -a 256 "$archive_name" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
chmod 0644 "$checksum_path"
xattr -c "$checksum_path"
touch -t 200001010000 "$checksum_path"

printf 'app archive prepared:\n%s\n%s\n' \
  "$archive_path" \
  "$checksum_path"
