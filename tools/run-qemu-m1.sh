#!/usr/bin/env bash
# Boot the AzuraOS M1 image in QEMU with OVMF and capture the evidence.
#
# Usage: tools/run-qemu-m1.sh [esp-image] [output-directory]
#
# Produces, in the output directory:
#   serial.log    the COM1 capture produced by the bootloader and the kernel
#   screen.ppm    a screenshot of the graphical console (QEMU screendump)
#   screen.png    the same screenshot converted to PNG
#
# The machine is always terminated: the AzuraOS kernel stops in a halt loop
# by design, so the run has to be bounded by a timeout.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

esp_image=${1:-zig-out/azura-esp.img}
out_dir=${2:-zig-out/boot}

timeout_seconds=${AZURA_QEMU_TIMEOUT:-60}

# Marker that proves the guest reached the expected state. The happy path
# waits for the kernel's completion message; the fault injection test waits
# for the exception report instead.
completion_marker=${AZURA_QEMU_COMPLETION_MARKER:-boot complete}

if [[ ! -f "$esp_image" ]]; then
  echo "ERROR: ESP image not found: $esp_image" >&2
  exit 1
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "ERROR: qemu-system-x86_64 not found in PATH" >&2
  exit 1
fi

# Locate the OVMF firmware. The Fedora package installs it in /usr/share/edk2.
ovmf_code=""
ovmf_vars=""
for candidate in \
  /usr/share/edk2/ovmf/OVMF_CODE.fd \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/edk2/x64/OVMF_CODE.fd \
  /usr/share/qemu/ovmf-x86_64-code.bin; do
  if [[ -f "$candidate" ]]; then
    ovmf_code="$candidate"
    ovmf_vars="${candidate%OVMF_CODE.fd}OVMF_VARS.fd"
    break
  fi
done

if [[ -z "$ovmf_code" ]]; then
  echo "ERROR: OVMF firmware not found (install the edk2-ovmf package)" >&2
  exit 1
fi
if [[ ! -f "$ovmf_vars" ]]; then
  echo "ERROR: OVMF variable store not found next to $ovmf_code" >&2
  exit 1
fi

mkdir -p "$out_dir"

serial_log="$out_dir/serial.log"
screen_ppm="$out_dir/screen.ppm"
monitor_socket="$out_dir/monitor.sock"

# The firmware NVRAM is copied so the host installation is never modified.
vars_copy="$out_dir/OVMF_VARS.fd"
cp -f "$ovmf_vars" "$vars_copy"

rm -f "$serial_log" "$screen_ppm" "$monitor_socket"

qemu-system-x86_64 \
  -machine q35 \
  -m 512M \
  -smp 1 \
  -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
  -drive if=pflash,format=raw,file="$vars_copy" \
  -drive if=none,id=esp,format=raw,file="$esp_image" \
  -device ide-hd,drive=esp \
  -net none \
  -display none \
  -serial file:"$serial_log" \
  -monitor unix:"$monitor_socket",server=on,wait=off \
  -no-reboot \
  &
qemu_pid=$!

cleanup() {
  if kill -0 "$qemu_pid" 2>/dev/null; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Wait for the guest to reach the expected state.
deadline=$((SECONDS + timeout_seconds))
boot_complete=0
while (( SECONDS < deadline )); do
  if [[ -f "$serial_log" ]] && grep -q "$completion_marker" "$serial_log"; then
    boot_complete=1
    break
  fi
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

# Give the firmware a moment to settle before grabbing the framebuffer.
sleep 1

# Screenshot through the QEMU monitor. The monitor socket is optional: a
# failure here must not invalidate the serial log.
if [[ -S "$monitor_socket" ]]; then
  if ! python3 tools/qemu-screenshot.py "$monitor_socket" "$screen_ppm"; then
    echo "WARNING: screenshot failed" >&2
  fi
fi

kill -TERM "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true
trap - EXIT

if [[ -f "$screen_ppm" ]]; then
  python3 tools/ppm-to-png.py "$screen_ppm" "$out_dir/screen.png" || true
fi

echo "serial log: $serial_log"
if [[ $boot_complete -eq 1 ]]; then
  echo "boot status: COMPLETE (the guest reached the '$completion_marker' marker)"
else
  echo "boot status: INCOMPLETE (no '$completion_marker' marker within ${timeout_seconds}s)"
fi
exit 0
