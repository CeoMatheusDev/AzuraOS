#!/usr/bin/env bash
# Negative-path tests only: no official Zig archive is bundled.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
verifier="$root/tools/verify-zig-release.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
expect_exit() {
  local expected=$1 actual=0
  shift
  "$@" >"$tmp/stdout" 2>"$tmp/stderr" || actual=$?
  if (( actual != expected )); then
    printf 'FAIL: expected exit %d, got %d\n' "$expected" "$actual" >&2
    cat "$tmp/stderr" >&2
    exit 1
  fi
}
expect_exit 2 bash "$verifier"
expect_exit 2 bash "$verifier" "$tmp/missing/zig-x86_64-linux-0.17.0.tar.xz"
printf 'invalid archive\n' >"$tmp/zig-x86_64-linux-0.17.0.tar.xz"
expect_exit 1 bash "$verifier" "$tmp/zig-x86_64-linux-0.17.0.tar.xz"
printf 'invalid archive\n' >"$tmp/unexpected.tar.xz"
expect_exit 2 bash "$verifier" "$tmp/unexpected.tar.xz"
printf 'PASS: 4 negative-path tests; official release verification NOT tested\n'
