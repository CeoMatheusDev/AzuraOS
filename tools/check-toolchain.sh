#!/usr/bin/env bash
set -u
printf '%s\n' 'AzuraOS M0.1 — Fedora toolchain inspection (read-only)'
printf 'UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
printf 'OS: '; (source /etc/os-release && printf '%s %s\n' "$ID" "$VERSION_ID")
printf 'Arch: '; uname -m
for tool in zig git qemu-system-x86_64 clang ld.lld; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%s: %s\n' "$tool" "$(command -v "$tool")"
    case "$tool" in
      zig) zig version ;;
      git) git --version ;;
      qemu-system-x86_64) qemu-system-x86_64 --version | head -n 1 ;;
    esac
  else
    printf '%s: NOT FOUND\n' "$tool"
  fi
done
printf '%s\n' 'OVMF candidates:'
for p in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
  if test -f "$p"; then printf '%s\n' "$p"; fi
done
printf '%s\n' 'Installed relevant RPMs:'
if command -v rpm >/dev/null 2>&1; then
  rpm -q zig qemu-system-x86-core edk2-ovmf 2>&1 || :
else
  printf 'rpm: NOT FOUND (non-RPM environment; Fedora inventory pending)\n'
fi
