#!/bin/sh

set -eu

LC_ALL=C
TZ=UTC
export LC_ALL TZ

fail() {
  printf 'app packaging failed: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -ne 1 ]; then
  fail "usage: $0 OUTPUT_DIRECTORY"
fi

[ "$(uname -s)" = "Darwin" ] || fail "packaging requires macOS"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/../.." && pwd -P)
output_directory=$1
signing_identity=${DEVSIFT_APP_SIGNING_IDENTITY:--}
expected_team_id=${DEVSIFT_APPLE_TEAM_ID:-}

[ -n "$output_directory" ] || fail "output directory must not be empty"
[ ! -e "$output_directory" ] \
  || fail "output directory already exists: $output_directory"
[ ! -L "$output_directory" ] \
  || fail "output directory must not be a symbolic link"
[ -n "$signing_identity" ] || fail "signing identity must not be empty"

if [ "$signing_identity" = "-" ]; then
  [ -z "$expected_team_id" ] \
    || fail "DEVSIFT_APPLE_TEAM_ID must be unset for ad-hoc signing"
  verification_mode=adhoc
else
  printf '%s\n' "$expected_team_id" | LC_ALL=C grep -Eq '^[A-Z0-9]{10}$' \
    || fail "DEVSIFT_APPLE_TEAM_ID must be a 10-character Apple team ID"
  verification_mode=signed
fi

for command_name in \
  awk chmod codesign cp grep install_name_tool lipo otool plutil sed shasum \
  sort strip swift tr unzip wc xattr zip; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required command is unavailable: $command_name"
done

info_template="$repository_root/packaging/DevSiftApp/Info.plist.template"
entitlements="$repository_root/packaging/DevSiftApp/DevSift.entitlements"
license_source="$repository_root/LICENSE"
version_source="$repository_root/VERSION"

for source_file in \
  "$info_template" \
  "$entitlements" \
  "$license_source" \
  "$version_source"; do
  [ -f "$source_file" ] || fail "packaging input is missing: $source_file"
  [ ! -L "$source_file" ] \
    || fail "packaging inputs must not be symbolic links: $source_file"
done

"$script_directory/verify-metadata.sh"
version=$(sed -n '1p' "$version_source")
marketing_version=${version%-alpha.*}
alpha_number=${version##*.}
[ "$alpha_number" -le 255 ] \
  || fail "alpha sequence exceeds Apple's CFBundleVersion limit of 255"
bundle_version="${marketing_version}a${alpha_number}"

plutil -lint "$info_template" >/dev/null \
  || fail "Info.plist template is invalid"
plutil -lint "$entitlements" >/dev/null \
  || fail "entitlements plist is invalid"
entitlement_key_count=$(plutil -convert json -o - "$entitlements" | grep -Eo '"[^"]+"[[:space:]]*:' | wc -l | tr -d '[:space:]')
[ "$entitlement_key_count" -eq 0 ] \
  || fail "release entitlements must remain empty"

mkdir -p "$output_directory"
output_directory=$(CDPATH= cd -- "$output_directory" && pwd -P)

stage_root=$(mktemp -d /private/tmp/devsift-app-stage.XXXXXX)
case "$stage_root" in
  /private/tmp/devsift-app-stage.*) ;;
  *) fail "temporary staging path is outside the fixed namespace" ;;
esac

cleanup() {
  case "${stage_root:-}" in
    /private/tmp/devsift-app-stage.*)
      rm -rf -- "$stage_root"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

arm_scratch="$stage_root/build-arm64"
x86_scratch="$stage_root/build-x86_64"
prefix_map="$repository_root=."
stage_prefix_map="$stage_root=.app-build"

build_slice() {
  architecture=$1
  triple="$architecture-apple-macosx14.0"
  scratch=$2

  (
    cd "$repository_root"
    swift build \
      --scratch-path "$scratch" \
      --configuration release \
      --product DevSiftApp \
      --triple "$triple" \
      -debug-info-format none \
      -Xswiftc -file-prefix-map \
      -Xswiftc "$prefix_map" \
      -Xswiftc -debug-prefix-map \
      -Xswiftc "$prefix_map" \
      -Xswiftc -file-prefix-map \
      -Xswiftc "$stage_prefix_map" \
      -Xswiftc -debug-prefix-map \
      -Xswiftc "$stage_prefix_map" \
      -Xswiftc -no-toolchain-stdlib-rpath
  )
}

build_slice arm64 "$arm_scratch"
build_slice x86_64 "$x86_scratch"

arm_binary="$arm_scratch/arm64-apple-macosx/release/DevSiftApp"
x86_binary="$x86_scratch/x86_64-apple-macosx/release/DevSiftApp"
[ -f "$arm_binary" ] || fail "arm64 build did not produce DevSiftApp"
[ -f "$x86_binary" ] || fail "x86_64 build did not produce DevSiftApp"
[ "$(lipo -archs "$arm_binary")" = "arm64" ] \
  || fail "arm64 build contains an unexpected slice"
[ "$(lipo -archs "$x86_binary")" = "x86_64" ] \
  || fail "x86_64 build contains an unexpected slice"

universal_binary="$stage_root/DevSift"
lipo -create "$arm_binary" "$x86_binary" -output "$universal_binary"

rpath_inventory="$stage_root/rpaths.txt"
: > "$rpath_inventory"
for architecture in arm64 x86_64; do
  otool -l -arch "$architecture" "$universal_binary" \
    | awk '
        $1 == "cmd" { in_rpath = ($2 == "LC_RPATH"); next }
        in_rpath && $1 == "path" { print $2; in_rpath = 0 }
      ' >> "$rpath_inventory"
done
sort -u "$rpath_inventory" > "$stage_root/rpaths-unique.txt"

while IFS= read -r runtime_path; do
  [ -n "$runtime_path" ] || continue
  case "$runtime_path" in
    /usr/lib/swift | @loader_path | @executable_path/../Frameworks)
      ;;
    /Applications/Xcode*.app/Contents/Developer/Toolchains/*.xctoolchain/usr/lib/swift-*/macosx)
      install_name_tool -delete_rpath "$runtime_path" "$universal_binary"
      ;;
    *)
      fail "refusing unknown runtime path: $runtime_path"
      ;;
  esac
done < "$stage_root/rpaths-unique.txt"

strip -S "$universal_binary"
xattr -c "$universal_binary"
chmod 0755 "$universal_binary"

app_bundle="$stage_root/DevSift.app"
contents="$app_bundle/Contents"
macos_directory="$contents/MacOS"
resources_directory="$contents/Resources"
mkdir -p "$macos_directory" "$resources_directory"

cp "$universal_binary" "$macos_directory/DevSift"
sed \
  -e "s/__DEVSIFT_MARKETING_VERSION__/$marketing_version/g" \
  -e "s/__DEVSIFT_BUNDLE_VERSION__/$bundle_version/g" \
  -e "s/__DEVSIFT_RELEASE_VERSION__/$version/g" \
  "$info_template" > "$contents/Info.plist"
cp "$license_source" "$resources_directory/LICENSE"
cp "$version_source" "$resources_directory/VERSION"

if LC_ALL=C grep -Eq '__DEVSIFT_[A-Z_]+__' "$contents/Info.plist"; then
  fail "Info.plist contains an unresolved template placeholder"
fi
plutil -lint "$contents/Info.plist" >/dev/null \
  || fail "rendered Info.plist is invalid"

chmod 0755 \
  "$app_bundle" \
  "$contents" \
  "$macos_directory" \
  "$resources_directory" \
  "$macos_directory/DevSift"
chmod 0644 \
  "$contents/Info.plist" \
  "$resources_directory/LICENSE" \
  "$resources_directory/VERSION"
chmod -N \
  "$app_bundle" \
  "$contents" \
  "$macos_directory" \
  "$resources_directory" \
  "$macos_directory/DevSift" \
  "$contents/Info.plist" \
  "$resources_directory/LICENSE" \
  "$resources_directory/VERSION"
xattr -cr "$app_bundle"

if [ "$verification_mode" = adhoc ]; then
  codesign \
    --force \
    --sign - \
    --options runtime \
    --entitlements "$entitlements" \
    --generate-entitlement-der \
    --timestamp=none \
    "$app_bundle"
  "$script_directory/verify-app-bundle.sh" \
    adhoc "$app_bundle" "$version"
else
  codesign \
    --force \
    --sign "$signing_identity" \
    --options runtime \
    --entitlements "$entitlements" \
    --generate-entitlement-der \
    --timestamp \
    "$app_bundle"
  "$script_directory/verify-app-bundle.sh" \
    signed "$app_bundle" "$version" "$expected_team_id"
fi

"$script_directory/archive-app.sh" \
  "$app_bundle" "$output_directory" "$version"

if [ "$verification_mode" = adhoc ]; then
  "$script_directory/verify-app-bundle.sh" \
    adhoc "$app_bundle" "$version"
else
  "$script_directory/verify-app-bundle.sh" \
    signed "$app_bundle" "$version" "$expected_team_id"
fi

mv "$app_bundle" "$output_directory/DevSift.app"

printf 'app package prepared:\n%s\n%s\n%s\n' \
  "$output_directory/DevSift.app" \
  "$output_directory/DevSift-$version-macos-universal.zip" \
  "$output_directory/SHA256SUMS"
