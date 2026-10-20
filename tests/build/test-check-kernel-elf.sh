#!/usr/bin/env bash
# Verify rejection cause, not merely a nonzero exit (e.g. permission denied).
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
checker="$root/tools/check-kernel-elf.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
expect_rejection() {
  local expected_code=$1 expected_message=$2 actual
  shift 2
  if bash "$checker" "$@" >"$tmp/out" 2>&1; then
    printf 'FAIL: unexpected success: %s\n' "$*" >&2
    exit 1
  else
    actual=$?
  fi
  if [[ "$actual" -ne "$expected_code" ]] || ! grep -Fq -- "$expected_message" "$tmp/out"; then
    printf 'FAIL: expected exit=%s and message=%q; got exit=%s\n' "$expected_code" "$expected_message" "$actual" >&2
    cat "$tmp/out" >&2
    exit 1
  fi
}
expect_rejection 2 'Usage:'
expect_rejection 2 'missing or unreadable ELF' "$tmp/nonexistent"
printf 'not an ELF\n' >"$tmp/invalid"
expect_rejection 1 'invalid ELF header' "$tmp/invalid"
if [[ -f /bin/true ]]; then
  # A host executable is not necessarily dynamically linked on every system.
  # It must fail our gate, but the specific failure may depend on the host.
  if bash "$checker" /bin/true >"$tmp/out" 2>&1; then
    printf 'FAIL: host /bin/true unexpectedly accepted\n' >&2
    exit 1
  fi
  if ! grep -Eq '^ERROR: (expected ELF64|ELF contains INTERP or DYNAMIC segment|no PT_LOAD segment)' "$tmp/out"; then
    printf 'FAIL: unexpected host ELF rejection cause\n' >&2
    cat "$tmp/out" >&2
    exit 1
  fi
else
  printf 'SKIP: /bin/true not found\n'
fi
printf 'PASS: negative ELF cases rejected for expected reasons\n'
