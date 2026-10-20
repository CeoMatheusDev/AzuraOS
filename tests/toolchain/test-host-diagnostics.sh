#!/usr/bin/env bash
# Smoke-test the host inventory scripts without requiring Zig or QEMU.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
for script in check-toolchain.sh check-build-host.sh; do
  bash -n "$root/tools/$script"
  bash "$root/tools/$script" >"$tmp/$script.stdout" 2>"$tmp/$script.stderr" || {
    printf 'FAIL: %s exited nonzero\n' "$script" >&2
    cat "$tmp/$script.stderr" >&2
    exit 1
  }
  if [[ ! -s "$tmp/$script.stdout" ]]; then
    printf 'FAIL: %s produced no output\n' "$script" >&2
    exit 1
  fi
  printf 'PASS: %s syntax and execution (current environment only)\n' "$script"
done
