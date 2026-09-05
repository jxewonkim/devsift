#!/bin/sh

set -eu

fail() {
  printf 'release reproducibility verification failed: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -ne 1 ]; then
  fail "usage: $0 OUTPUT_DIRECTORY"
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/../.." && pwd -P)
output_directory=$1

[ ! -e "$output_directory" ] \
  || fail "output directory already exists: $output_directory"

comparison_root=$(mktemp -d /private/tmp/devsift-release-compare.XXXXXX)
case "$comparison_root" in
  /private/tmp/devsift-release-compare.*) ;;
  *) fail "comparison path is outside the fixed temporary namespace" ;;
esac

cleanup() {
  case "${comparison_root:-}" in
    /private/tmp/devsift-release-compare.*)
      rm -rf -- "$comparison_root"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

comparison_output="$comparison_root/output"
TZ=UTC "$script_directory/package-cli.sh" "$output_directory"
TZ=Asia/Seoul "$script_directory/package-cli.sh" "$comparison_output"

version=$(sed -n '1p' "$repository_root/VERSION")
archive_name="devsift-$version-macos-universal.tar.gz"

cmp "$output_directory/$archive_name" "$comparison_output/$archive_name" \
  || fail "independent archives differ"
cmp "$output_directory/SHA256SUMS" "$comparison_output/SHA256SUMS" \
  || fail "independent checksums differ"
cmp "$output_directory/RELEASE_NOTES.md" "$comparison_output/RELEASE_NOTES.md" \
  || fail "independent release-note handoffs differ"

printf 'release reproducibility verified: %s\n' "$archive_name"
