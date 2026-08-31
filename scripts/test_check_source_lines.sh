#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
checker="$script_dir/check_source_lines.sh"
tmp_dir=$(mktemp -d -t camera-gps-link-source-lines-test.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/valid sources" "$tmp_dir/empty"
printf 'struct Fixture {}\n' > "$tmp_dir/valid sources/Fixture.swift"

valid_output=$(bash "$checker" "$tmp_dir/valid sources")
if [[ "$valid_output" != *'passed: 1 Swift file(s)'* ]]; then
    printf 'Expected one Swift fixture to pass, received: %s\n' "$valid_output" >&2
    exit 1
fi

awk 'BEGIN { for (line = 1; line <= 1001; line++) print "// fixture" }' > "$tmp_dir/Oversized.swift"
if bash "$checker" "$tmp_dir/Oversized.swift" > "$tmp_dir/oversized.out" 2>&1; then
    printf 'Expected an oversized Swift fixture to fail.\n' >&2
    exit 1
fi
if ! grep -Fq '1001 lines exceeds 1000' "$tmp_dir/oversized.out"; then
    printf 'Oversized failure did not report the line limit.\n' >&2
    exit 1
fi

if bash "$checker" "$tmp_dir/empty" > "$tmp_dir/empty.out" 2>&1; then
    printf 'Expected an empty source scan to fail.\n' >&2
    exit 1
fi
if ! grep -Fq 'no Swift files found' "$tmp_dir/empty.out"; then
    printf 'Empty source scan did not report that no Swift files were found.\n' >&2
    exit 1
fi

if bash "$checker" "$tmp_dir/missing" > "$tmp_dir/missing.out" 2>&1; then
    printf 'Expected source discovery failure to propagate.\n' >&2
    exit 1
fi
if ! grep -Fq 'failed while discovering Swift files' "$tmp_dir/missing.out"; then
    printf 'Source discovery failure was not reported.\n' >&2
    exit 1
fi

printf 'Source line checker regression tests passed.\n'
