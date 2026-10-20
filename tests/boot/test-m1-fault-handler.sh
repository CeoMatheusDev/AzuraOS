#!/usr/bin/env bash
# Automated test of the kernel exception handler (M1).
#
# Usage: tests/boot/test-m1-fault-handler.sh
#
# Builds a kernel variant that deliberately executes an invalid opcode and
# checks that:
#   * the exception is reported by the kernel with the right vector,
#   * the machine is halted by the handler instead of triple faulting,
#   * the firmware did not restart (no second bootloader banner).
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

out_dir=${AZURA_TEST_OUT:-zig-out/test-fault}
image="$out_dir/azura-esp.img"

mkdir -p "$out_dir"

# Build a dedicated image with the fault injection enabled. The image is
# written into the test directory so the normal image in zig-out/ is not
# replaced by a deliberately broken kernel. A separate local cache directory
# keeps this nested build from competing with the outer build for the cache
# lock.
zig build esp \
  -Dfault-inject=true \
  -Desp-image="$image" \
  --cache-dir "$out_dir/cache" \
  >"$out_dir/build.log" 2>&1 || {
  echo "FAIL: could not build the fault injection image" >&2
  cat "$out_dir/build.log" >&2
  exit 1
}

export AZURA_QEMU_TIMEOUT=${AZURA_QEMU_TIMEOUT:-90}
export AZURA_QEMU_COMPLETION_MARKER="KERNEL FAULT"

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

if ! grep -q -F "[azura] KERNEL FAULT: vector 6 (invalid opcode)" "$serial_log"; then
  echo "FAIL: the #UD exception was not reported" >&2
  failures=$((failures + 1))
fi

if ! grep -q -E "^\[azura\] KERNEL FAULT: rip=0x[0-9a-f]+ cs=0x[0-9a-f]+ rflags=0x[0-9a-f]+$" "$serial_log"; then
  echo "FAIL: the exception report does not contain the register state" >&2
  failures=$((failures + 1))
fi

if ! grep -q -F "[azura] KERNEL FAULT: machine halted" "$serial_log"; then
  echo "FAIL: the handler did not halt the machine" >&2
  failures=$((failures + 1))
fi

# A triple fault would reset the machine and the firmware would boot again.
bootloader_banners=$(grep -c -F "[azura] === AzuraOS UEFI bootloader" "$serial_log" || true)
if [[ "$bootloader_banners" -ne 1 ]]; then
  echo "FAIL: expected exactly one bootloader banner, found $bootloader_banners" >&2
  failures=$((failures + 1))
fi

if grep -q -F "the invalid opcode did not fault" "$serial_log"; then
  echo "FAIL: the invalid opcode did not trigger an exception" >&2
  failures=$((failures + 1))
fi

if [[ $failures -ne 0 ]]; then
  echo "FAIL: $failures check(s) failed" >&2
  echo "--- serial log ---" >&2
  cat "$serial_log" >&2
  exit 1
fi

echo "PASS: the kernel exception handler reported the fault and halted the machine"
echo "      serial log: $serial_log"
exit 0
