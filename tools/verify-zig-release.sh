#!/usr/bin/env bash
# Verify the official Zig 0.17.0 Linux x86_64 archive. No network access or installation.
set -euo pipefail
readonly expected='1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026'
readonly filename='zig-x86_64-linux-0.17.0.tar.xz'
if (( $# != 1 )); then
  printf 'Usage: %s /path/to/%s\n' "$0" "$filename" >&2
  exit 2
fi
archive=$1
if [[ ! -f "$archive" || ! -r "$archive" ]]; then
  printf 'ERROR: archive missing or unreadable: %s\n' "$archive" >&2
  exit 2
fi
if [[ ${archive##*/} != "$filename" ]]; then
  printf 'ERROR: unexpected archive filename\n' >&2
  exit 2
fi
printf '%s  %s\n' "$expected" "$archive" | sha256sum --check --status || {
  printf 'ERROR: SHA-256 mismatch\n' >&2
  exit 1
}
printf 'OK: SHA-256 matches Zig 0.17.0 official release index\n'
