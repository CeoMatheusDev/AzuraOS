#!/usr/bin/env bash
# Automated M1 boot test.
#
# Usage: tests/boot/test-m1-boot.sh [esp-image]
#
# Boots the image in QEMU with OVMF and checks the serial log against the
# expected boot sequence. The test is bounded by a timeout and always exits
# with a verifiable status:
#
#   0  every expected marker was found, in order, and no failure marker
#   1  the boot did not complete, or a failure marker was present
#   2  the test was invoked incorrectly, or a tool is missing
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

esp_image=${1:-zig-out/azura-esp.img}
out_dir=${AZURA_TEST_OUT:-zig-out/test-boot}

if [[ ! -f "$esp_image" ]]; then
  echo "FAIL: ESP image not found: $esp_image" >&2
  echo "      build it first with: zig build esp" >&2
  exit 2
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "SKIP: qemu-system-x86_64 is not installed" >&2
  exit 2
fi

rm -rf "$out_dir"
mkdir -p "$out_dir"

# The test must never hang: the guest ends in a halt loop by design.
export AZURA_QEMU_TIMEOUT=${AZURA_QEMU_TIMEOUT:-90}
export AZURA_QEMU_COMPLETION_MARKER="boot complete, halting"

bash tools/run-qemu-m1.sh "$esp_image" "$out_dir" >"$out_dir/run.log" 2>&1 || true

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

# The expected boot sequence, in order. Each entry is a fixed string that
# must appear after the previous one.
expected=(
  "[azura] === AzuraOS UEFI bootloader"
  "[azura] firmware vendor:"
  "[azura] framebuffer:"
  "[azura] kernel image:"
  "[azura] memory map:"
  "[azura] kernel loaded: entry="
  "[azura] kernel stack:"
  "[azura] jumping to the kernel entry point"
  "[azura] === AzuraOS kernel"
  "[azura] boot protocol: version 1"
  "[azura] memory map:"
  "[azura] framebuffer:"
  "[azura] IDT installed, exception handling active"
  "[azura] boot complete, halting"
)

position=1
for marker in "${expected[@]}"; do
  # Search only the part of the log after the previous marker, so the order
  # is really checked.
  line=$(tail -n "+$position" "$serial_log" | grep -n -m1 -F -- "$marker" | cut -d: -f1 || true)
  if [[ -z "$line" ]]; then
    echo "FAIL: missing marker (or out of order): $marker" >&2
    failures=$((failures + 1))
    break
  fi
  # The line number is relative to the remainder; make it absolute.
  position=$((position + line - 1))
done

# Nothing in the log may indicate a failure.
if grep -q -E "FATAL|KERNEL FAULT|BOOT ABORTED" "$serial_log"; then
  echo "FAIL: the boot log contains a failure marker" >&2
  grep -n -E "FATAL|KERNEL FAULT|BOOT ABORTED" "$serial_log" >&2
  failures=$((failures + 1))
fi

# The guest must not have rebooted: a triple fault would restart the firmware
# and print the bootloader banner a second time.
bootloader_banners=$(grep -c -F "[azura] === AzuraOS UEFI bootloader" "$serial_log" || true)
if [[ "$bootloader_banners" -ne 1 ]]; then
  echo "FAIL: expected exactly one bootloader banner, found $bootloader_banners" >&2
  failures=$((failures + 1))
fi

# The kernel must have reported a plausible framebuffer.
if ! grep -q -E "^\[azura\] framebuffer: [0-9]+x[0-9]+" "$serial_log"; then
  echo "FAIL: the kernel did not report a framebuffer geometry" >&2
  failures=$((failures + 1))
fi

if [[ $failures -ne 0 ]]; then
  echo "FAIL: $failures check(s) failed" >&2
  echo "--- serial log ---" >&2
  cat "$serial_log" >&2
  exit 1
fi

echo "PASS: the M1 boot sequence completed in QEMU/OVMF"
echo "      serial log: $serial_log"
echo "      screenshot: $out_dir/screen.png"
exit 0
