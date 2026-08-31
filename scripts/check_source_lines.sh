#!/usr/bin/env bash
set -euo pipefail

max_lines=1000
file_count=0
failure_count=0
roots=("$@")
if ((${#roots[@]} == 0)); then
    roots=(ios/CameraGPSLink)
fi

path_list=$(mktemp -t camera-gps-link-source-lines.XXXXXX)
trap 'rm -f "$path_list"' EXIT
if ! find "${roots[@]}" -type f -name '*.swift' -not -path '*/build/*' -print0 > "$path_list"; then
    printf 'Source line check failed while discovering Swift files.\n' >&2
    exit 1
fi

while IFS= read -r -d '' path; do
    file_count=$((file_count + 1))
    line_count=$(wc -l < "$path" | tr -d ' ')
    if ((line_count > max_lines)); then
        printf '%s: %s lines exceeds %s\n' "$path" "$line_count" "$max_lines"
        failure_count=$((failure_count + 1))
    fi
done < "$path_list"

if ((file_count == 0)); then
    printf 'Source line check failed: no Swift files found.\n' >&2
    exit 1
fi

if ((failure_count > 0)); then
    exit 1
fi

printf 'Source line check passed: %s Swift file(s), maximum %s lines.\n' "$file_count" "$max_lines"
