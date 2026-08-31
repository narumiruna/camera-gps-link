#!/usr/bin/env bash
set -euo pipefail

max_lines=1000
file_count=0
failure_count=0

while IFS= read -r -d '' path; do
    file_count=$((file_count + 1))
    line_count=$(wc -l < "$path" | tr -d ' ')
    if ((line_count > max_lines)); then
        printf '%s: %s lines exceeds %s\n' "$path" "$line_count" "$max_lines"
        failure_count=$((failure_count + 1))
    fi
done < <(find ios/CameraGPSLink -type f -name '*.swift' -not -path '*/build/*' -print0 | sort -z)

if ((failure_count > 0)); then
    exit 1
fi

printf 'Source line check passed: %s Swift file(s), maximum %s lines.\n' "$file_count" "$max_lines"
