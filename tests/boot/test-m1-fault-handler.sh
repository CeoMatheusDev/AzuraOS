#!/usr/bin/env bash
# Automated test of the kernel exception handler (M1).
#
# Usage: tests/boot/test-m1-fault-handler.sh
#
# Builds a kernel variant that deliberately raises a CPU exception and
# checks that:
#   * the exception is reported by the kernel with the right vector,
#   * the machine is halted by the handler instead of triple faulting,
#   * the firmware did not restart (no second bootloader banner).
#
# Two faults are injected, because the exception frame has two shapes:
#
#   invalid_opcode   #UD (vector 6)  the frame carries no error code
#   bad_segment      #GP (vector 13) the frame carries an error code
#
# A handler that reads the frame with a fixed layout misreads every field
# of the second kind, so both faults are needed to cover the decoding.
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

failures=0

# Run one injected fault and check the report.
#
# $1 the fault mode, $2 the expected vector line, $3 the expected error
# code line (empty when the vector pushes no error code).
run_fault() {
  local mode="$1" expected_vector="$2" expected_error_code="$3"
  local out_dir="zig-out/test-fault-$mode"
  local image="$out_dir/azura-esp.img"

  mkdir -p "$out_dir"

  # Build a dedicated image with the fault injection enabled. The image is
  # written into the test directory so the normal image in zig-out/ is not
  # replaced by a deliberately broken kernel. A separate local cache
  # directory keeps this nested build from competing with the outer build
  # for the cache lock.
  if ! zig build esp \
    "-Dfault-mode=$mode" \
    "-Desp-image=$image" \
    --cache-dir "$out_dir/cache" \
    >"$out_dir/build.log" 2>&1; then
    echo "FAIL: could not build the $mode injection image" >&2
    cat "$out_dir/build.log" >&2
    failures=$((failures + 1))
    return
  fi

  AZURA_QEMU_TIMEOUT=${AZURA_QEMU_TIMEOUT:-90} \
  AZURA_QEMU_COMPLETION_MARKER="KERNEL FAULT" \
    bash tools/run-qemu-m1.sh "$image" "$out_dir" >"$out_dir/run.log" 2>&1 || true

  local serial_log="$out_dir/serial.log"
  if [[ ! -f "$serial_log" ]]; then
    echo "FAIL: no serial log was produced for $mode" >&2
    cat "$out_dir/run.log" >&2 || true
    failures=$((failures + 1))
    return
  fi

  # The serial driver emits CRLF; normalise the line endings so the checks
  # below can use anchored patterns.
  local normalized="$out_dir/serial.log.normalized"
  tr -d '\r' <"$serial_log" >"$normalized"
  serial_log="$normalized"

  # The exception must be reported while the kernel is running on its own
  # GDT. The code selector in the report must be the kernel's own (0x08);
  # a wrong value means the frame was read at the wrong offset.
  if ! grep -q -F "[azura] GDT active, the segments are the kernel's own" "$serial_log"; then
    echo "FAIL ($mode): the kernel did not install its own GDT" >&2
    failures=$((failures + 1))
  fi

  # Fault injection is permitted only after the TSS and the final IDT
  # configuration are installed. Assert the complete transition happened.
  if ! grep -q -F "[azura] TSS task register loaded (TR=0x18)" "$serial_log"; then
    echo "FAIL ($mode): the kernel did not confirm the task register" >&2
    failures=$((failures + 1))
  fi
  if ! grep -q -F "[azura] double-fault gate: IST1 configured" "$serial_log"; then
    echo "FAIL ($mode): the kernel did not confirm the IST1 gate" >&2
    failures=$((failures + 1))
  fi

  # The fault is injected after the handover, so the boot services must be
  # gone and the post-ExitBootServices checks must have passed. Without this
  # the exception could be reported by a kernel that never took the machine.
  if ! grep -q -F "[azura] ExitBootServices: success" "$serial_log"; then
    echo "FAIL ($mode): the bootloader did not exit the boot services" >&2
    failures=$((failures + 1))
  fi
  if ! grep -q -F "[azura] post-ExitBootServices: stack=ok gdt=ok idt=ok framebuffer=ok memory_map=ok" "$serial_log"; then
    echo "FAIL ($mode): the kernel did not report a healthy post-ExitBootServices environment" >&2
    failures=$((failures + 1))
  fi

  if ! grep -q -F "$expected_vector" "$serial_log"; then
    echo "FAIL ($mode): expected '$expected_vector'" >&2
    grep -a "KERNEL FAULT" "$serial_log" >&2 || true
    failures=$((failures + 1))
  fi

  if ! grep -q -E "^\[azura\] KERNEL FAULT: rip=0x[0-9a-f]+ cs=0x8 rflags=0x[0-9a-f]+$" "$serial_log"; then
    echo "FAIL ($mode): the exception report does not contain the register state with cs=0x8" >&2
    grep -a "KERNEL FAULT" "$serial_log" >&2 || true
    failures=$((failures + 1))
  fi

  # The error code is only present for the vectors that push one. Its
  # presence, or its absence, is part of the contract.
  if [[ -n "$expected_error_code" ]]; then
    if ! grep -q -F "$expected_error_code" "$serial_log"; then
      echo "FAIL ($mode): expected '$expected_error_code'" >&2
      grep -a "KERNEL FAULT" "$serial_log" >&2 || true
      failures=$((failures + 1))
    fi
  elif grep -q -F "[azura] KERNEL FAULT: error_code=" "$serial_log"; then
    echo "FAIL ($mode): the report contains an error code, but the vector pushes none" >&2
    failures=$((failures + 1))
  fi

  if ! grep -q -F "[azura] KERNEL FAULT: machine halted" "$serial_log"; then
    echo "FAIL ($mode): the handler did not halt the machine" >&2
    failures=$((failures + 1))
  fi

  # A triple fault would reset the machine and the firmware would boot
  # again.
  local bootloader_banners
  bootloader_banners=$(grep -c -F "[azura] === AzuraOS UEFI bootloader" "$serial_log" || true)
  if [[ "$bootloader_banners" -ne 1 ]]; then
    echo "FAIL ($mode): expected exactly one bootloader banner, found $bootloader_banners" >&2
    failures=$((failures + 1))
  fi

  if grep -q -F "the injected fault did not fault" "$serial_log"; then
    echo "FAIL ($mode): the injected fault did not trigger an exception" >&2
    failures=$((failures + 1))
  fi
}

run_fault invalid_opcode \
  "[azura] KERNEL FAULT: vector 6 (invalid opcode)" \
  ""

# The selector 0xa0 names an entry beyond the limit of the kernel's GDT,
# so the processor reports it as the error code of the #GP.
run_fault bad_segment \
  "[azura] KERNEL FAULT: vector 13 (general protection fault)" \
  "[azura] KERNEL FAULT: error_code=0xa0"

if [[ $failures -ne 0 ]]; then
  echo "FAIL: $failures check(s) failed" >&2
  exit 1
fi

echo "PASS: the kernel exception handler reported both injected faults and halted the machine"
echo "      serial logs: zig-out/test-fault-invalid_opcode/serial.log.normalized"
echo "                   zig-out/test-fault-bad_segment/serial.log.normalized"
exit 0
