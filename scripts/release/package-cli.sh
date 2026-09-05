#!/bin/sh

set -eu

LC_ALL=C
TZ=UTC
export LC_ALL TZ

fail() {
  printf 'release packaging failed: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -ne 1 ]; then
  fail "usage: $0 OUTPUT_DIRECTORY"
fi

[ "$(uname -s)" = "Darwin" ] || fail "packaging requires macOS"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/../.." && pwd -P)
output_directory=$1

[ -n "$output_directory" ] || fail "output directory must not be empty"
[ ! -e "$output_directory" ] \
  || fail "output directory already exists: $output_directory"
[ ! -L "$output_directory" ] \
  || fail "output directory must not be a symbolic link"

for command_name in codesign gzip install_name_tool lipo shasum strip swift tar xattr; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required command is unavailable: $command_name"
done

"$script_directory/verify-metadata.sh"
version=$(sed -n '1p' "$repository_root/VERSION")
release_notes="$repository_root/docs/releases/v$version.md"
[ -f "$release_notes" ] || fail "release notes are missing: $release_notes"
[ ! -L "$release_notes" ] || fail "release notes must not be a symbolic link"

mkdir -p "$output_directory"
output_directory=$(CDPATH= cd -- "$output_directory" && pwd -P)

stage_root=$(mktemp -d /private/tmp/devsift-release-stage.XXXXXX)
case "$stage_root" in
  /private/tmp/devsift-release-stage.*) ;;
  *) fail "temporary staging path is outside the fixed namespace" ;;
esac

cleanup() {
  case "${stage_root:-}" in
    /private/tmp/devsift-release-stage.*)
      rm -rf -- "$stage_root"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

arm_scratch="$stage_root/build-arm64"
x86_scratch="$stage_root/build-x86_64"
prefix_map="$repository_root=."
stage_prefix_map="$stage_root=.release-build"

build_slice() {
  architecture=$1
  triple="$architecture-apple-macosx14.0"
  scratch=$2

  (
    cd "$repository_root"
    swift build \
      --scratch-path "$scratch" \
      --configuration release \
      --product devsift \
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

arm_binary="$arm_scratch/arm64-apple-macosx/release/devsift"
x86_binary="$x86_scratch/x86_64-apple-macosx/release/devsift"
[ -f "$arm_binary" ] || fail "arm64 build did not produce devsift"
[ -f "$x86_binary" ] || fail "x86_64 build did not produce devsift"
[ "$(lipo -archs "$arm_binary")" = "arm64" ] \
  || fail "arm64 build contains an unexpected slice"
[ "$(lipo -archs "$x86_binary")" = "x86_64" ] \
  || fail "x86_64 build contains an unexpected slice"

universal_binary="$stage_root/devsift"
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
    /usr/lib/swift | @loader_path | @executable_path/../lib)
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
codesign --force --sign - --timestamp=none "$universal_binary"
"$script_directory/verify-cli.sh" "$universal_binary" "$version"

bundle_name="devsift-$version-macos-universal"
bundle_directory="$stage_root/$bundle_name"
mkdir "$bundle_directory"
cp "$repository_root/LICENSE" "$bundle_directory/LICENSE"
cp "$release_notes" "$bundle_directory/RELEASE_NOTES.md"
cp "$repository_root/VERSION" "$bundle_directory/VERSION"
cp "$universal_binary" "$bundle_directory/devsift"

chmod 0755 "$bundle_directory"
chmod 0644 \
  "$bundle_directory/LICENSE" \
  "$bundle_directory/RELEASE_NOTES.md" \
  "$bundle_directory/VERSION"
chmod 0755 "$bundle_directory/devsift"
chmod -N \
  "$bundle_directory" \
  "$bundle_directory/LICENSE" \
  "$bundle_directory/RELEASE_NOTES.md" \
  "$bundle_directory/VERSION" \
  "$bundle_directory/devsift"
xattr -cr "$bundle_directory"
touch -t 200001010000 \
  "$bundle_directory/LICENSE" \
  "$bundle_directory/RELEASE_NOTES.md" \
  "$bundle_directory/VERSION" \
  "$bundle_directory/devsift" \
  "$bundle_directory"

archive_name="$bundle_name.tar.gz"
archive_path="$output_directory/$archive_name"
checksum_path="$output_directory/SHA256SUMS"
notes_output_path="$output_directory/RELEASE_NOTES.md"
uncompressed_archive="$stage_root/$bundle_name.tar"

COPYFILE_DISABLE=1 tar \
  --format ustar \
  --uid 0 \
  --gid 0 \
  --uname root \
  --gname wheel \
  --no-recursion \
  -cf "$uncompressed_archive" \
  -C "$stage_root" \
  "$bundle_name/" \
  "$bundle_name/LICENSE" \
  "$bundle_name/RELEASE_NOTES.md" \
  "$bundle_name/VERSION" \
  "$bundle_name/devsift"
gzip -n -9 -c "$uncompressed_archive" > "$archive_path"
xattr -c "$archive_path"

expected_members=$(printf '%s\n' \
  "$bundle_name/" \
  "$bundle_name/LICENSE" \
  "$bundle_name/RELEASE_NOTES.md" \
  "$bundle_name/VERSION" \
  "$bundle_name/devsift")
actual_members=$(tar -tzf "$archive_path")
[ "$actual_members" = "$expected_members" ] \
  || fail "archive membership differs from the fixed allowlist"

expected_metadata=$(printf '%s\n' \
  "drwxr-xr-x root wheel $bundle_name/" \
  "-rw-r--r-- root wheel $bundle_name/LICENSE" \
  "-rw-r--r-- root wheel $bundle_name/RELEASE_NOTES.md" \
  "-rw-r--r-- root wheel $bundle_name/VERSION" \
  "-rwxr-xr-x root wheel $bundle_name/devsift")
actual_metadata=$(
  tar -tvzf "$archive_path" \
    | awk '{ print substr($1, 1, 10) " " $3 " " $4 " " $NF }'
)
[ "$actual_metadata" = "$expected_metadata" ] \
  || fail "archive type, mode, or owner metadata is not canonical"

cp "$release_notes" "$notes_output_path"
chmod 0644 "$notes_output_path"
xattr -c "$notes_output_path"
touch -t 200001010000 "$archive_path" "$notes_output_path"

(
  cd "$output_directory"
  shasum -a 256 "$archive_name" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
chmod 0644 "$checksum_path"
xattr -c "$checksum_path"
touch -t 200001010000 "$checksum_path"

printf 'release package prepared:\n%s\n%s\n%s\n' \
  "$archive_path" \
  "$checksum_path" \
  "$notes_output_path"
