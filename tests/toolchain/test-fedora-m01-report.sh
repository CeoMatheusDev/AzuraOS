#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bash -n "$root/tools/fedora-m01-report.sh"
output="$(bash "$root/tools/fedora-m01-report.sh")"
[[ "$output" == *AZURAOS_M01_REPORT_BEGIN* ]]
[[ "$output" == *AZURAOS_M01_REPORT_END* ]]
[[ "$output" == *machine=* ]]
[[ "$output" == *zig=* ]]
printf '%s\n' 'PASS: diagnostic output contract (current host only)'
