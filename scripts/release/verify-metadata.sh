#!/bin/sh

set -eu

fail() {
  printf 'release metadata verification failed: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -gt 1 ]; then
  fail "usage: $0 [vMAJOR.MINOR.PATCH-alpha.NUMBER]"
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/../.." && pwd -P)
version_file="$repository_root/VERSION"
status_file="$repository_root/Sources/DevSiftCore/DevSiftStatus.swift"
changelog_file="$repository_root/CHANGELOG.md"

[ -f "$version_file" ] || fail "VERSION is missing"
[ ! -L "$version_file" ] || fail "VERSION must not be a symbolic link"

version_line_count=$(awk 'END { print NR }' "$version_file")
[ "$version_line_count" -eq 1 ] || fail "VERSION must contain exactly one line"

newline_count=$(wc -l < "$version_file" | tr -d '[:space:]')
[ "$newline_count" -eq 1 ] || fail "VERSION must end with one newline"

version=$(sed -n '1p' "$version_file")
printf '%s\n' "$version" \
  | LC_ALL=C grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-alpha\.[1-9][0-9]*$' \
  || fail "VERSION is not a canonical alpha semantic version"

[ "$version" != "0.0.0-dev" ] || fail "development placeholders cannot be released"
[ -f "$status_file" ] || fail "DevSiftStatus.swift is missing"

status_line="    version: \"$version\","
status_count=$(LC_ALL=C grep -Fxc "$status_line" "$status_file" || true)
[ "$status_count" -eq 1 ] \
  || fail "DevSiftStatus.current.version does not exactly match VERSION"

if [ "$#" -eq 1 ]; then
  tag=$1
  expected_tag="v$version"
  [ "$tag" = "$expected_tag" ] \
    || fail "tag $tag does not match expected tag $expected_tag"

  [ -f "$changelog_file" ] || fail "CHANGELOG.md is missing"
  release_heading_count=$(
    LC_ALL=C grep -Ec \
      "^## \[$version\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" \
      "$changelog_file" || true
  )
  [ "$release_heading_count" -eq 1 ] \
    || fail "CHANGELOG.md must contain one dated release heading for $version"
fi

printf 'release metadata verified: %s\n' "$version"
