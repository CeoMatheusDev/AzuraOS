# ADR-0010 — The kernel's own page tables

- Status: accepted
- Date: 2026-10-21
- Milestone: M2.4
- Related: ADR-0003, ADR-0007, ADR-0009,
  `docs/specs/boot-protocol-v2.md`, `docs/specs/m2.4-own-paging.md`,
  `docs/testing/m2.4-paging-evidence.md`

## Context

M2.3 left the kernel with a frame allocator and the firmware's page tables
still active. The kernel could allocate physical memory but could not
control how it was mapped: execution, write and read permissions were
whatever the firmware had decided, and the NX bit was not under the kernel's
control.

M2.4 replaces the firmware tables with tables the kernel builds itself,
using the frame allocator, and switches `CR3`. After the switch the firmware
tables are released and, with them, the boot services quarantine from
ADR-0007.

## Decision

### 1. One size, one tree

The kernel uses 4-level x86_64 paging with 4 KiB leaves. A single size
keeps the walk, the permission logic and the allocator in agreement; large
pages are a mapping optimisation and are deferred.

`EFER.NXE` is enabled before any table is built, so the NX bit is valid.
The NX bit is only defined for **leaf** entries (PML4, PDPT and PD entries
that point at a table must keep it clear; setting it there is a reserved
bit and raises #GP).

### 2. What gets mapped

The new tables identity-map every descriptor in the pre-`ExitBootServices`
map except `unusable` memory and MMIO other than the framebuffer:

| Descriptor type | Treatment |
| --------------- | --------- |
| `conventional`, `loader_*`, `boot_services_*`, `runtime_services_*`, `acpi_*`, `persistent_memory`, `pal_code`, `reserved` | identity mapped, read/write, no execute |
| `memory_mapped_io` | only the framebuffer range is mapped, read/write, no execute |
| `unusable` | not mapped |

The kernel image is then re-mapped with W^X permissions, overwriting the
writable identity mapping:

| Section | Permissions |
| ------- | ----------- |
| `.text` | read, execute |
| `.rodata` | read, no execute |
| `.data`, `.bss` | read, write, no execute |

The boot stack, `boot_info`, the memory map buffer and the framebuffer keep
read/write, no execute. The kernel sections are aligned to 4 KiB in the
linker script so that a permission boundary never shares a page with a
neighbouring section.

### 3. Building and switching

Table frames come from the frame allocator, so the pool that owns data
frames also owns table frames and the quarantine policy stays in one place.
Each new table is zeroed before use. Intermediate tables are allocated
lazily, one per non-empty index.

The switch happens with interrupts disabled:

1. enable NXE;
2. allocate the PML4;
3. map the descriptors, then the kernel sections;
4. write the PML4 address to `CR3`;
5. release the firmware's table frames;
6. release every boot services descriptor to the allocator;
7. read `CR3` back and log it.

The identity map keeps every virtual address the kernel is using valid, so
the switch is transparent: `RIP`, `RSP`, the GDT, the IDT, the TSS and the
framebuffer all keep working.

### 4. Releasing the firmware tables and the quarantine

After the switch the firmware tables are no longer reachable by the MMU.
They are walked and every table frame is returned to the pool. The boot
services descriptors are then freed as well, which adds their frames to the
allocatable pool and closes the quarantine opened by ADR-0007.

The walk only releases frames the pool can accept; frames outside the
covered range are ignored.

### 5. Diagnostics

The page fault handler reports `CR2` in addition to the vector, `RIP`, `CS`,
`RFLAGS`, error code and handler stack. A controlled page fault
(`-Dfault-mode=page_fault`) reads `0xdead0000` and the handler reports
vector 14 with that address, which proves the new tables are active and
that an unmapped access is reported instead of escalating.

## Alternatives rejected

* **Reuse the firmware's page tables.** Rejected: the kernel could not set
  W^X or NX, and the quarantine could never be released.
* **2 MiB or 1 GiB leaves for the bulk identity map.** Rejected for M2.4:
  large leaves make W^X impossible at section granularity and complicate
  the walk and the permission tests. The allocator and the tables agree on
  4 KiB; large pages can be added later as an optimisation.
* **Set NX on intermediate entries.** Rejected: the bit is reserved there
  and raises #GP when the entry is used. Only leaves carry it.
* **Keep the boot services quarantine after the switch.** Rejected: the whole
  point of owning the page tables is that the kernel can release that
  memory. The walk of the old tables provides the list of frames to free.
* **Free the old tables before switching.** Rejected: the CPU is still using
  them to fetch the switch instruction and the handler that would report a
  failure.

## Consequences

* The kernel no longer depends on the firmware's mapping. `CR3` is a value
  the kernel chose and logged on every boot.
* W^X holds for the kernel image: `.text` is executable and not writable,
  `.rodata` is readable and not executable, `.data` and `.bss` are writable
  and not executable.
* The allocatable pool grows by the boot services frames (about 9,920 frames,
  ~39 MiB, on the 512 MiB test machine) after the switch.
* The firmware's table frames are returned to the pool as well.
* Memory above 4 GiB and the framebuffer are handled as in M2.3: the
  framebuffer is mapped, memory above the bitmap limit is not allocatable.
* There is still no user mode, no per-process address spaces and no TLB
  shootdown: the kernel runs on one CPU with interrupts disabled. Those are
  later milestones.
* The controlled page fault test is an injected fault, not a spontaneous one.

## References

* `docs/adr/ADR-0007-memory-ownership-after-exitbootservices.md` — the
  quarantine this milestone closes.
* `docs/adr/ADR-0009-physical-frame-allocator.md` — the pool the tables
  are built from.
* `docs/specs/boot-protocol-v2.md` — the map and the kernel image range.
* `docs/specs/m2.4-own-paging.md` — acceptance criteria.
* `docs/testing/m2.4-paging-evidence.md` — measured evidence.
* `kernel/arch/x86_64/paging.zig` — the page table implementation.
* `kernel/arch/x86_64/cpu.zig` — `writeCr3`, `enableNx`, `readCr2`.
* `kernel/arch/x86_64/idt.zig` — the page fault report.
* Intel SDM Vol. 3A, 4.1–4.8 (paging) and 4.1.4 (NX).
