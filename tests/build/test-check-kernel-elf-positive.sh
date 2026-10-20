#!/usr/bin/env bash
# Host-only positive fixture. Not an AzuraOS kernel or boot test.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
for tool in as ld readelf mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP: %s unavailable\n' "$tool"; exit 77; }
done
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cat > "$tmp/entry.s" <<'ASM'
.global _start
.section .text
_start:
    cli
1:  hlt
    jmp 1b
ASM
as --64 -o "$tmp/entry.o" "$tmp/entry.s"
ld -m elf_x86_64 -nostdlib -static -e _start -o "$tmp/fixture.elf" "$tmp/entry.o"
bash "$root/tools/check-kernel-elf.sh" "$tmp/fixture.elf"
printf 'PASS: host-generated ELF fixture accepted (no Zig compilation or boot performed)\n'
