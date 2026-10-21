# ADR-0009 — Physical frame allocator and the boot services quarantine

- Status: accepted
- Date: 2026-10-21
- Milestone: M2.3
- Related: ADR-0002, ADR-0003, ADR-0007, ADR-0008,
  `docs/specs/boot-protocol-v2.md`, `docs/specs/m2.3-physical-frames.md`,
  `docs/testing/m2.3-frames-evidence.md`

## Context

M2.2 handed the kernel a validated pre-`ExitBootServices` memory map and
wrote the ownership policy in ADR-0007. M2.3 is the first milestone that may
write to physical memory the firmware no longer owns, so it has to answer
questions the policy deliberately left to the allocator:

* what the allocation unit is and where the bookkeeping lives;
* which descriptors become free, and in which order the exceptions are
  applied;
* how the allocator avoids the firmware page tables, which are still the
  active ones until M2.4;
* what happens to memory above the range the bookkeeping can describe;
* how allocation, release and the boundaries are tested.

The central constraint of M2.3 is that the kernel still runs on the
firmware's page tables. `CR3` points at a page table tree in boot services
memory. ADR-0007 allows boot services memory to be reclassified, but doing
that correctly requires knowing every page of that tree and every firmware
structure still in use. Walking the tree at this point would duplicate M2.4
and would itself depend on the firmware mapping it is trying to replace.

## Decision

### 1. Unit, representation and storage

The allocation unit is a 4 KiB frame, the granularity of the UEFI memory map
and of the x86_64 page tables. One bit per frame records the state:

* `1`: used or reserved — never handed out;
* `0`: free — can be handed out.

The bitmap lives in the kernel's `.bss`, in a static 128 KiB buffer. That
covers `4 GiB / 4 KiB = 1,048,576` frames. A 512 MiB machine uses only the
first 16 KiB of the buffer; the allocator slices it to the size the map
actually needs. A static buffer was chosen because M2.3 has no heap and
because the bitmap must exist before the first allocation; it is not itself
allocated from the pool it manages.

### 2. What becomes free

Only `conventional` descriptors become free. The remaining policy is:

| UEFI type | M2.3 treatment |
| --------- | -------------- |
| `conventional` | freed, then the explicit reservations below are applied |
| `loader_code`, `loader_data` | stays used; the kernel image, stack, `boot_info` and map buffer are here |
| `boot_services_code`, `boot_services_data` | **covered by the bitmap but kept used**; counted as quarantined |
| `runtime_services_*` | stays used |
| `acpi_reclaim`, `acpi_nvs` | stays used; ACPI is not consumed yet |
| `unusable`, `reserved`, `pal_code` | stays used |
| `memory_mapped_io`, `memory_mapped_io_port_space` | stays used; the framebuffer is reserved explicitly as well |
| `persistent_memory` | stays used |
| unknown types | stays used |

Boot services are included in the bitmap's covered range even though they
are not freed. That keeps the pool's address space equal to the machine the
map describes and means M2.4 can release those ranges without resizing or
reinitialising the bitmap. The bits are used, so no allocation can touch
them.

### 3. The boot services stay quarantined through M2.3

ADR-0007 says the boot services regions "may be used only after [the kernel]
has reclassified them and recorded that the firmware no longer owns them".
This ADR records the opposite decision for M2.3: **they are not reclassified
as free yet**.

The reason is the active page table tree. The kernel does not know which
boot services pages hold the PML4, the PDPTs, the PDs, the PTs or the
firmware's other live structures. Reserving only the page that `CR3` names
would leave the lower levels of the tree allocatable. Reserving the whole
descriptor that contains `CR3` would still assume the tree is physically
contiguous. Until the kernel installs its own page tables in M2.4, the only
safe policy is to keep the entire class used.

The boot log reports the quarantined total. M2.4 must free it only after its
own page tables are active and it has identified every firmware structure it
still needs. ADR-0007 remains the ownership policy; this section records the
M2.3 implementation choice, not a change to the policy.

### 4. Explicit reservations

After the conventional descriptors are freed, the allocator reserves, in
this order:

1. the first 1 MiB;
2. `[kernel_start, kernel_end)` from `boot_info`, which includes the TSS,
   the IST stack and the bitmap itself;
3. `[stack_base, stack_top)`;
4. the `boot_info` structure;
5. the memory map buffer;
6. the framebuffer range, when present.

The low 1 MiB is not required by UEFI: the map reports it as conventional.
It is reserved because the real-mode IVT, the BIOS data area and firmware
scratch memory live there, and because a null-pointer dereference must fault
instead of writing to a valid frame. The cost is 256 frames, 0.05% of the
512 MiB test machine.

Items 3–6 are already described as `loader_data` or MMIO and therefore
already used. They are reserved again on purpose: the allocator must not
depend on a second subsystem having classified the map correctly. Reserving
an already used range is idempotent.

The framebuffer reservation is outside the bitmap's covered range on the
test machine (it is at 2 GiB, above the 511 MiB highest usable address), so
it is a no-op there. It becomes meaningful on a machine whose MMIO range is
below the highest conventional address.

### 5. Allocation and release

Allocation is first-fit with a rotating hint:

* the hint starts at frame 0;
* a successful allocation starts the next scan immediately after the frame
  it returned;
* releasing a frame moves the hint back to the lowest released frame, so a
  free followed by an allocation reuses the frame instead of scanning from
  the beginning.

Release rejects an unaligned address, an address outside the covered range
and a frame that is already free. All three are errors, not silent no-ops.
The bitmap does not distinguish "reserved by policy" from "allocated by a
caller"; the caller must only release frames it received from `allocate`.
The kernel's only release path is the boot self-test, which releases its own
three frames.

### 6. Initialisation order and self-test

The allocator is built after the memory map has been validated and after the
GDT, TSS and IDT have been verified. That order is deliberate: the self-test
writes to real frames, and if a frame is not mapped the resulting page fault
must be reported by the kernel's own exception handler instead of escalating
to a triple fault.

The boot path:

1. scans the map, validates that no descriptor wraps the address space,
   finds the highest conventional or boot services address below 4 GiB,
   counts the boot services pages and the conventional pages above 4 GiB;
2. initialises the bitmap with every bit set;
3. frees the conventional descriptors;
4. applies the explicit reservations;
5. logs the total, free and used frame counts, the bitmap size, the
   quarantined boot services and the ignored memory above 4 GiB;
6. allocates three frames, writes a pattern at the first and last 8 bytes of
   each, releases them, allocates again and requires the lowest released
   frame back.

A frame that overlaps kernel-owned memory, an address that is not aligned or
outside the pool, a failed write/read and a wrong reuse all stop the boot
with `FATAL`. The self-test is small on purpose: the exhaustive
exhaust/release/reuse test runs on the host with a synthetic 64 MiB map, where
it can allocate all 16,126 free frames and check every address without
depending on the firmware mapping.

### 7. Address limit

The bitmap describes the first 4 GiB of the physical address space. A
conventional descriptor that crosses the limit is clipped; the pages above
it are counted in `above 4 GiB` in the boot log and are not allocatable.
Boot services above 4 GiB are also outside the bitmap. The limit is a M2.3
constraint, not a permanent architecture decision: M2.4 or M2.5 can replace
the static buffer with a larger structure once the kernel owns its mapping.

## Alternatives rejected

* **Reclassify and free the boot services regions now.** Rejected: the active
  page table tree lives there, and M2.3 cannot prove which pages are still
  in use without doing M2.4 first. Freeing them would let the self-test or a
  future caller overwrite the page tables under the running kernel.
* **Free every conventional descriptor including the first MiB.** Rejected:
  the real-mode IVT, the BDA and firmware scratch memory live there, and a
  null-pointer bug would write to a valid frame. The 1 MiB guard is cheap.
* **Allocate the bitmap itself from the first conventional range.** Rejected:
  the bootstrap would have to find, reserve and identity-map its own
  metadata before it can allocate anything, and M2.3 has no heap. The static
  128 KiB buffer is simpler and fails closed at compile time if the address
  limit changes.
* **Use 2 MiB or 1 GiB frames.** Rejected: the UEFI map is 4 KiB granular
  and small allocations would waste most of a large frame. Large-page
  support belongs to the mapping layer, not to the frame pool.
* **A free list or a buddy allocator.** Rejected for M2.3: both need
  per-frame or per-block metadata and a way to keep it coherent, while the
  kernel only needs single-frame allocation and release. A bitmap cannot
  suffer a corrupted free-list pointer, and it is easy to test exhaustively.
* **Per-frame reference counts.** Rejected: there is one owner and no
  sharing yet. Reference counts can be added when a mapping layer needs
  them, behind a different interface.
* **Not covering boot services in the bitmap until M2.4.** Rejected: the
  pool would report a machine smaller than it is, and M2.4 would have to
  rebuild the bitmap instead of just changing the bits. Covering used ranges
  costs a few bytes and makes the log complete.

## Consequences

* The kernel image grows by the 128 KiB bitmap. In the measured build the
  image ends at `0x12d200` and the first free frame is `0x12e000`; the
  1 MiB guard and the kernel image are reserved before the self-test runs.
* On the 512 MiB QEMU/OVMF machine the allocator reports 130,904 frames
  covered, 118,579 free, 12,325 used and 42 MiB of boot services
  quarantined. The boot services and the firmware page tables are still
  outside the allocatable pool; M2.4 must release them after installing the
  kernel's own page tables.
* The kernel still depends on the firmware's identity mapping to write a
  frame. The self-test only touches frames just above the kernel image,
  which the firmware maps. A future caller that allocates high memory before
  M2.4 could fault; the mapping layer must establish the mapping first.
* Memory above 4 GiB is not allocatable and is reported. A machine with all
  of its conventional memory above 4 GiB has no conventional descriptor
  below the limit and the boot fails with a FATAL; that is intentional
  rather than silently handing out nothing.
* The allocator has no locking. The kernel runs with interrupts disabled and
  has one CPU context; a future scheduler must add a lock or per-CPU pools
  before it allocates concurrently.
* Releasing a reserved frame is not detected. The only release path today is
  the self-test's own frames; a future public API must either track
  reservations separately or take ownership tokens.

## References

* `docs/adr/ADR-0007-memory-ownership-after-exitbootservices.md` — the
  ownership policy this ADR implements.
* `docs/specs/boot-protocol-v2.md` — the map and the kernel image range.
* `docs/specs/m2.3-physical-frames.md` — acceptance criteria.
* `docs/testing/m2.3-frames-evidence.md` — measured evidence.
* UEFI Specification 2.10, `GetMemoryMap` and the memory type table.
* `kernel/mm/frames.zig` — the allocator and its host tests.
* `kernel/main.zig` — `initFrames` and `frameSelfTest`.
