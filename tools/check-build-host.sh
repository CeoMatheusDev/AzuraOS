#!/usr/bin/env bash
# Read-only host capability check. Does not install or change system state.
set -u
printf '%s\n' 'AzuraOS M0.1 — build host prerequisites (read-only)'
for tool in zig file readelf sha256sum bash git; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf 'FOUND %-12s %s\n' "$tool" "$(command -v "$tool")"
  else
    printf 'MISSING %s\n' "$tool"
  fi
done
if command -v zig >/dev/null 2>&1; then
  printf 'zig version: '
  zig version || printf 'ERROR: zig version failed\n' >&2
fi
printf 'host architecture: '
uname -m
