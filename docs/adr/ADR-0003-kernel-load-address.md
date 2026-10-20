# ADR-0003 — Fixed kernel load address

- Status: accepted
- Date: 2026-10-20
- Milestone: M1
- Related: ADR-0002

## Context

The kernel is a non relocatable `ET_EXEC` image: the code and the data
contain absolute addresses, so the image is only valid at the address it was
linked at.

Two options exist:

* **Fixed address.** The kernel is linked at a known physical address and the
  bootloader copies it exactly there.
* **Relocatable image.** The kernel is linked as `ET_DYN` (PIE) and the
  bootloader applies the relative relocations before the transfer. The
  kernel can then be placed in any free region.

The Zig default for a freestanding executable is `0x1000000` (16 MiB). The
first boot attempt with that address failed: on OVMF, the region
`0x900000..0x12E0000` is `boot_services_data` — firmware scratch memory — so
loading the kernel there would have corrupted the firmware.

## Decision

The kernel is linked at **`0x100000` (1 MiB)** through
`kernel/linker.ld`, and the bootloader verifies the whole load range against
the firmware memory map before it copies anything.

*Rationale.*

* 1 MiB is the conventional kernel load address and is left as conventional
  memory by OVMF (verified: the map reports `conventional` from `0x100000`
  for 7 MiB).
* The memory map check turns a silent corruption into an explicit boot
  failure with a diagnostic.
* Position independent kernels are a real improvement, but they need a
  relocation-capable loader and a PIE toolchain path. That is a meaningful
  chunk of work that is not required to prove the boot chain.

*Consequence.* On a firmware that does not leave 1 MiB free, the boot fails
with:

    [azura] FATAL: kernel segment at 0x100000 (NNNN bytes) is not in conventional memory

and the memory map is printed. The fix in that case is a different link
address, not a code change.

## Alternatives considered

* **Keep 0x1000000.** Rejected: it is firmware scratch memory on OVMF.
* **Allocate the pages with `AllocatePages` at the link address.** This
  would fail on the same address, and does not solve the general problem.
  It is still worth doing once the kernel owns the memory, to make the
  reservation explicit.
* **ET_DYN with relocations.** Deferred to a later milestone; it removes the
  fixed address constraint entirely and is the right long term answer.

## References

* `kernel/linker.ld`
* `boot/uefi/main.zig` — `isUsableRange` and `fetchMemoryMap`.
* The measured OVMF memory map is in `docs/testing/m1-boot-evidence.md`.
