#!/usr/bin/env bash
# Read-only M0.1 inventory; no package installation or privileged operations.
set -u
printf '%s\n' 'AZURAOS_M01_REPORT_BEGIN'
printf 'os='; if [[ -r /etc/fedora-release ]]; then cat /etc/fedora-release; else printf 'NOT_FEDORA_OR_UNAVAILABLE\n'; fi
printf 'machine='; uname -m
printf 'kernel='; uname -r
for tool in zig git qemu-system-x86_64 readelf sha256sum file; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%s=FOUND\n' "$tool"
    if [[ "$tool" == zig ]]; then
      printf 'zig_version='; zig version || printf 'ERROR\n'
    fi
  else
    printf '%s=NOT_FOUND\n' "$tool"
  fi
done
if command -v rpm >/dev/null 2>&1; then
  if rpm -q edk2-ovmf >/dev/null 2>&1; then printf 'ovmf_rpm=INSTALLED\n'; else printf 'ovmf_rpm=NOT_INSTALLED\n'; fi
else
  printf 'ovmf_rpm=RPM_NOT_AVAILABLE\n'
fi
printf '%s\n' 'AZURAOS_M01_REPORT_END'
