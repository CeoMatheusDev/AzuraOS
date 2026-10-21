#!/usr/bin/env bash
# Automated test of the TSS/IST stack for critical faults (M2.2b).
#
# A normal boot cannot exercise the alternate stack: the kernel is healthy and
# #DF only happens when a fault cannot be delivered. This test builds a kernel
# with -Dfault-mode=double_fault, which hides vector 13 from the IDT and then
# executes `int $13`:
#
#   * the #GP gate is outside the IDT limit, so the processor cannot deliver
#     the general protection fault,
#   * delivery of the #GP fails for the same reason, which raises #DF,
#   * the #DF gate is inside the limit and names IST1, so the handler must run
#     on the alternate stack, not on the interrupted one.
#
# The test reads the IST range from the boot log and proves that the handler's
# stack pointer is inside it. A misconfigured TSS would triple fault and the
# firmware would reboot, which the banner count also catches.
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

out_dir="zig-out/test-double-fault"
image="$out_dir/azura-esp.img"

mkdir -p "$out_dir"

# A dedicated image and cache directory: the normal image in zig-out/ must not
# be replaced by one built with the fault injection.
if ! zig build esp \
  -Dfault-mode=double_fault \
  "-Desp-image=$image" \
  --cache-dir "$out_dir/cache" \
  >"$out_dir/build.log" 2>&1; then
  echo "FAIL: could not build the double fault image" >&2
  cat "$out_dir/build.log" >&2
  exit 1
fi

AZURA_QEMU_TIMEOUT=${AZURA_QEMU_TIMEOUT:-90} \
AZURA_QEMU_COMPLETION_MARKER="KERNEL FAULT: machine halted" \
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

# The expected sequence, in order: the kernel installs the TSS and the IST
# gates, reports a healthy environment, raises #DF, and the handler reports
# the fault and halts. A marker that is missing or out of order means the
# handler did not run in the expected state.
expected=(
  "[azura] === AzuraOS UEFI bootloader"
  "[azura] ExitBootServices: success"
  "[azura] === AzuraOS kernel"
  "[azura] TSS: selector=0x18"
  "[azura] IST1 stack: base=0x"
  "[azura] TSS loaded, task register=0x18"
  "[azura] TSS descriptor: base=0x"
  "[azura] IDT: IST 1 active for vectors 2, 8 and 18"
  "[azura] post-ExitBootServices: stack=ok gdt=ok idt=ok tss=ok ist=ok framebuffer=ok memory_map=ok"
  "[azura] KERNEL FAULT: vector 8 (double fault)"
  "[azura] KERNEL FAULT: error_code=0x0"
  "[azura] KERNEL FAULT: machine halted"
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

# The fault report must name the kernel code segment and carry the #DF error
# code (the processor pushes zero).
if ! grep -q -E "^\[azura\] KERNEL FAULT: rip=0x[0-9a-f]+ cs=0x8 rflags=0x[0-9a-f]+$" "$serial_log"; then
  echo "FAIL: the exception report does not contain the register state with cs=0x8" >&2
  grep -a "KERNEL FAULT" "$serial_log" >&2 || true
  failures=$((failures + 1))
fi

# Read the IST range the kernel reported and the stack the handler actually
# used. The handler must be inside the IST stack: that is the whole point of
# the TSS.
ist_base=$(sed -nE 's/.*IST1 stack: base=(0x[0-9a-f]+) top=0x[0-9a-f]+.*/\1/p' "$serial_log" | head -1)
ist_top=$(sed -nE 's/.*IST1 stack: base=0x[0-9a-f]+ top=(0x[0-9a-f]+).*/\1/p' "$serial_log" | head -1)
handler_stack=$(sed -nE 's/.*KERNEL FAULT: handler stack=(0x[0-9a-f]+).*/\1/p' "$serial_log" | head -1)

# The interrupted stack must be a different range; otherwise the report would
# not prove that the processor switched stacks.
boot_base=$(sed -nE 's/.*\[azura\] stack: base=(0x[0-9a-f]+) top=0x[0-9a-f]+.*/\1/p' "$serial_log" | head -1)
boot_top=$(sed -nE 's/.*\[azura\] stack: base=0x[0-9a-f]+ top=(0x[0-9a-f]+).*/\1/p' "$serial_log" | head -1)

if [[ -z "$ist_base" || -z "$ist_top" || -z "$handler_stack" ]]; then
  echo "FAIL: could not read the IST range or the handler stack" >&2
  failures=$((failures + 1))
elif (( handler_stack < ist_base || handler_stack >= ist_top )); then
  echo "FAIL: the handler ran on stack $handler_stack, outside the IST $ist_base..$ist_top" >&2
  failures=$((failures + 1))
fi

if [[ -n "$boot_base" && -n "$boot_top" ]]; then
  if (( handler_stack >= boot_base && handler_stack < boot_top )); then
    echo "FAIL: the handler ran on the interrupted stack $boot_base..$boot_top instead of the IST" >&2
    failures=$((failures + 1))
  fi
fi

# A wrong TSS or a wrong IDT gate would triple fault and reset the machine.
# The firmware would then boot a second time.
bootloader_banners=$(grep -c -F "[azura] === AzuraOS UEFI bootloader" "$serial_log" || true)
kernel_banners=$(grep -c -F "[azura] === AzuraOS kernel" "$serial_log" || true)
if [[ "$bootloader_banners" -ne 1 ]]; then
  echo "FAIL: expected exactly one bootloader banner, found $bootloader_banners" >&2
  failures=$((failures + 1))
fi
if [[ "$kernel_banners" -ne 1 ]]; then
  echo "FAIL: expected exactly one kernel banner, found $kernel_banners" >&2
  failures=$((failures + 1))
fi

if grep -q -E "FATAL|BOOT ABORTED" "$serial_log"; then
  echo "FAIL: the boot log contains a failure marker" >&2
  grep -n -E "FATAL|BOOT ABORTED" "$serial_log" >&2
  failures=$((failures + 1))
fi

if grep -q -F "the injected fault did not fault" "$serial_log"; then
  echo "FAIL: the double fault was not raised" >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -ne 0 ]]; then
  echo "FAIL: the double fault test found $failures problem(s)" >&2
  echo "      serial log: $serial_log" >&2
  exit 1
fi

echo "PASS: the processor switched to the IST stack on a double fault"
echo "      IST:     $ist_base..$ist_top"
echo "      handler: $handler_stack"
echo "      serial log: $serial_log"
