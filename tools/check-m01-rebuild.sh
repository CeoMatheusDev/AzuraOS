#!/usr/bin/env bash
# Rebuild the M0.1 probe twice with the same toolchain and options.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if ! command -v zig >/dev/null 2>&1 || [[ "$(zig version)" != '0.17.0' ]]; then
  echo 'ERROR: Zig 0.17.0 required' >&2
  exit 1
fi
for cmd in sha256sum cmp readelf file; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd missing" >&2; exit 1; }
done
mkdir -p zig-out
first=$(mktemp)
trap 'rm -f "$first"' EXIT
bash tools/build-m01-probe.sh
cp zig-out/azura-m01-probe.elf "$first"
# Rebuild without deleting Zig caches: checks repeatability in this environment,
# not hermetic reproducibility across clean machines.
rm -f zig-out/azura-m01-probe.elf
bash tools/build-m01-probe.sh
cmp "$first" zig-out/azura-m01-probe.elf
printf 'PASS: two successive Zig 0.17.0 probe builds are byte-identical on this host\n'
sha256sum zig-out/azura-m01-probe.elf
