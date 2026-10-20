#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if ! command -v zig >/dev/null 2>&1; then
  echo 'ERROR: zig not found in PATH' >&2
  exit 1
fi
if [[ "$(zig version)" != '0.17.0' ]]; then
  echo 'ERROR: this probe expects Zig 0.17.0' >&2
  exit 1
fi
mkdir -p zig-out
zig build-exe tools/probe/main.zig -target x86_64-freestanding -O ReleaseSmall -femit-bin=zig-out/azura-m01-probe.elf
file zig-out/azura-m01-probe.elf
readelf -h zig-out/azura-m01-probe.elf
bash tools/check-kernel-elf.sh zig-out/azura-m01-probe.elf
sha256sum zig-out/azura-m01-probe.elf
