#!/usr/bin/env bash
# Build the bootable EFI System Partition image for the M1 boot chain.
#
# Usage: tools/make-esp.sh <output-image> <bootloader.efi> <kernel.elf>
#
# The image is a FAT16 volume with the UEFI fallback boot path populated:
#
#   EFI/BOOT/BOOTX64.EFI   the AzuraOS UEFI bootloader
#   azura-kernel.elf       the kernel image loaded by the bootloader
#
# OVMF's platform boot manager picks up the removable media fallback path
# EFI/BOOT/BOOTX64.EFI, so no Boot#### variable has to be written into the
# firmware NVRAM.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <output-image> <bootloader.efi> <kernel.elf>" >&2
  exit 2
fi

out_image=$1
bootloader=$2
kernel=$3

for tool in mformat mmd mcopy; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found in PATH (install the mtools package)" >&2
    exit 1
  fi
done

for artifact in "$bootloader" "$kernel"; do
  if [[ ! -f "$artifact" ]]; then
    echo "ERROR: missing artifact: $artifact" >&2
    exit 1
  fi
done

out_dir=$(dirname "$out_image")
image_size_mb=64

mkdir -p "$out_dir"

# A fixed size FAT16 volume: deterministic content and enough room for the
# kernel to grow without changing the layout.
rm -f "$out_image"
dd if=/dev/zero of="$out_image" bs=1M count="$image_size_mb" status=none

# The FAT type is chosen by mtools from the volume size (FAT16 for 64 MiB).
# Forcing FAT32 here would produce a volume with far fewer than the 65525
# clusters the UEFI FAT driver requires, and the firmware would refuse to
# mount it.
mformat -i "$out_image" -v AZURA ::
mmd -i "$out_image" ::/EFI ::/EFI/BOOT
mcopy -i "$out_image" "$bootloader" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$out_image" "$kernel" ::/azura-kernel.elf

echo "ESP image: $out_image ($(stat -c %s "$out_image") bytes)"
mdir -i "$out_image" ::/EFI/BOOT
mdir -i "$out_image" ::/
