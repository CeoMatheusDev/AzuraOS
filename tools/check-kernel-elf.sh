#!/usr/bin/env bash
# Static ELF gate; not proof that the kernel boots.
set -euo pipefail
if (( $# != 1 )); then
  printf 'Usage: %s /path/to/kernel.elf\n' "$0" >&2
  exit 2
fi
kernel=$1
if [[ ! -f "$kernel" || ! -r "$kernel" ]]; then
  printf 'ERROR: missing or unreadable ELF\n' >&2
  exit 2
fi
for tool in readelf grep; do
  command -v "$tool" >/dev/null || { printf 'ERROR: %s unavailable\n' "$tool" >&2; exit 2; }
done
header=$(LC_ALL=C readelf -hW -- "$kernel") || { printf 'ERROR: invalid ELF header\n' >&2; exit 1; }
program=$(LC_ALL=C readelf -lW -- "$kernel") || { printf 'ERROR: invalid program headers\n' >&2; exit 1; }
if ! grep -Eq 'Class:[[:space:]]+ELF64' <<<"$header" ||
   ! grep -Eq 'Data:[[:space:]]+2.s complement, little endian' <<<"$header" ||
   ! grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' <<<"$header" ||
   ! grep -Eq 'Type:[[:space:]]+EXEC \(Executable file\)' <<<"$header"; then
  printf 'ERROR: expected ELF64 little-endian x86_64 ET_EXEC\n' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*(INTERP|DYNAMIC)[[:space:]]' <<<"$program"; then
  printf 'ERROR: ELF contains INTERP or DYNAMIC segment\n' >&2
  exit 1
fi
if ! grep -Eq '^[[:space:]]*LOAD[[:space:]]' <<<"$program"; then
  printf 'ERROR: no PT_LOAD segment\n' >&2
  exit 1
fi
printf 'PASS: ELF64 x86_64 ET_EXEC; PT_LOAD present; no PT_INTERP/PT_DYNAMIC\n'
