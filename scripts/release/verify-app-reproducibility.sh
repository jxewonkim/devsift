#!/bin/sh

set -eu

fail() {
  printf 'release app reproducibility verification failed: %s\n' "$*" >&2
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
[ ! -L "$output_directory" ] \
  || fail "output directory must not be a symbolic link"
[ -z "${DEVSIFT_APP_SIGNING_IDENTITY:-}" ] \
  || fail "reproducibility verification accepts only the ad-hoc signing path"
[ -z "${DEVSIFT_APPLE_TEAM_ID:-}" ] \
  || fail "reproducibility verification accepts no Apple team identifier"

comparison_root=$(mktemp -d /private/tmp/devsift-app-compare.XXXXXX)
case "$comparison_root" in
  /private/tmp/devsift-app-compare.*) ;;
  *) fail "comparison path is outside the fixed temporary namespace" ;;
esac

cleanup() {
  case "${comparison_root:-}" in
    /private/tmp/devsift-app-compare.*)
      rm -rf -- "$comparison_root"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

comparison_output="$comparison_root/output"
TZ=UTC "$script_directory/package-app.sh" "$output_directory"
TZ=Asia/Seoul "$script_directory/package-app.sh" "$comparison_output"

version=$(sed -n '1p' "$repository_root/VERSION")
archive_name="DevSift-$version-macos-universal.zip"

cmp "$output_directory/$archive_name" "$comparison_output/$archive_name" \
  || fail "independent app archives differ"
cmp "$output_directory/SHA256SUMS" "$comparison_output/SHA256SUMS" \
  || fail "independent app checksums differ"

printf 'release app reproducibility verified: %s\n' "$archive_name"
