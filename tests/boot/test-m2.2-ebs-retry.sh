#!/usr/bin/env bash
# Automated test of the ExitBootServices stale key retry (M2.2).
#
# A normal boot gets the memory map key right on the first attempt. This test
# builds the bootloader with -Dstale-map-key=true, which allocates pool memory
# between the final memory map snapshot and ExitBootServices. The allocation
# changes the map, so the key is stale by construction. The firmware must
# answer EFI_INVALID_PARAMETER; the bootloader must fetch a new map, use its
# key and succeed on the retry.
#
# Exit status: 0 pass, 1 fail, 2 cannot run.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if ! command -v zig >/dev/null 2>&1; then
  echo "SKIP: zig is not installed" >&2
  exit 2
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "SKIP: qemu-system-x86_64 is not installed" >&2
  exit 2
fi

out_dir="zig-out/test-ebs-retry"
image="$out_dir/azura-esp.img"

mkdir -p "$out_dir"

# A dedicated image and cache directory: the normal image in zig-out/ must not
# be replaced by one built with the stale key injection.
if ! zig build esp \
  -Dstale-map-key=true \
  "-Desp-image=$image" \
  --cache-dir "$out_dir/cache" \
  >"$out_dir/build.log" 2>&1; then
  echo "FAIL: could not build the stale key image" >&2
  cat "$out_dir/build.log" >&2
  exit 1
fi

AZURA_QEMU_TIMEOUT=${AZURA_QEMU_TIMEOUT:-90} \
AZURA_QEMU_COMPLETION_MARKER="boot complete, halting" \
  bash tools/run-qemu-m1.sh "$image" "$out_dir" >"$out_dir/run.log" 2>&1 || true

serial_log="$out_dir/serial.log"
if [[ ! -f "$serial_log" ]]; then
  echo "FAIL: no serial log was produced" >&2
  cat "$out_dir/run.log" >&2 || true
  exit 1
fi

# The serial driver emits CRLF; normalise the line endings so the checks
# below can use anchored patterns.
normalized="$out_dir/serial.log.normalized"
tr -d '\r' <"$serial_log" >"$normalized"
serial_log="$normalized"

failures=0

# The expected sequence, in order: the first call must fail because of the
# injected stale key, the bootloader must say so, take a new snapshot and
# succeed on the second call, and the kernel must accept the new key.
expected=(
  "[azura] === AzuraOS UEFI bootloader"
  "[azura] ExitBootServices: attempt 1, key=0x"
  "[azura] ExitBootServices: injected a stale key"
  "[azura] ExitBootServices: stale key, refreshing the memory map"
  "[azura] final memory map:"
  "[azura] ExitBootServices: attempt 2, key=0x"
  "[azura] ExitBootServices: success"
  "[azura] === AzuraOS kernel"
  "[azura] boot services: exited, memory map key="
  "[azura] post-ExitBootServices: stack=ok gdt=ok idt=ok tss=ok ist=ok framebuffer=ok memory_map=ok"
  "[azura] boot complete, halting"
)

position=1
for marker in "${expected[@]}"; do
  line=$(tail -n "+$position" "$serial_log" | grep -n -m1 -F -- "$marker" | cut -d: -f1 || true)
  if [[ -z "$line" ]]; then
    echo "FAIL: missing marker (or out of order): $marker" >&2
    failures=$((failures + 1))
    break
  fi
  position=$((position + line - 1))
done

# The retry must use a different key. If it does not, the map was not really
# refreshed and the success came from something else.
key_of() {
  grep -m1 -F "ExitBootServices: attempt $1," "$serial_log" |
    sed -E 's/.*key=(0x[0-9a-f]+).*/\1/' || true
}
first_key=$(key_of 1)
second_key=$(key_of 2)
if [[ -z "$first_key" || -z "$second_key" ]]; then
  echo "FAIL: could not read the keys of the two attempts" >&2
  failures=$((failures + 1))
elif [[ "$first_key" == "$second_key" ]]; then
  echo "FAIL: the retry reused the key $first_key; the map was not refreshed" >&2
  failures=$((failures + 1))
fi

# The kernel must have received the key of the call that succeeded.
kernel_key=$(grep -m1 -F "[azura] boot services: exited, memory map key=" "$serial_log" |
  sed -E 's/.*key=(0x[0-9a-f]+).*/\1/' || true)
if [[ -z "$kernel_key" ]]; then
  echo "FAIL: the kernel did not report the memory map key" >&2
  failures=$((failures + 1))
elif [[ "$kernel_key" != "$second_key" ]]; then
  echo "FAIL: the kernel received key $kernel_key, the successful call used $second_key" >&2
  failures=$((failures + 1))
fi

# Nothing in the log may indicate a failure.
if grep -q -E "FATAL|KERNEL FAULT|BOOT ABORTED" "$serial_log"; then
  echo "FAIL: the boot log contains a failure marker" >&2
  grep -n -E "FATAL|KERNEL FAULT|BOOT ABORTED" "$serial_log" >&2
  failures=$((failures + 1))
fi

# The guest must not have rebooted.
bootloader_banners=$(grep -c -F "[azura] === AzuraOS UEFI bootloader" "$serial_log" || true)
if [[ "$bootloader_banners" -ne 1 ]]; then
  echo "FAIL: expected exactly one bootloader banner, found $bootloader_banners" >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -ne 0 ]]; then
  echo "FAIL: the ExitBootServices retry test found $failures problem(s)" >&2
  echo "      serial log: $serial_log" >&2
  exit 1
fi

echo "PASS: the bootloader refreshed a stale memory map key and exited the boot services"
echo "      first key:  $first_key (rejected)"
echo "      second key: $second_key (accepted)"
echo "      serial log: $serial_log"
