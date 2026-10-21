# ADR-0007 — Memory ownership after `ExitBootServices`

- Status: accepted
- Date: 2026-10-21
- Milestone: M2.2
- Related: ADR-0002, ADR-0003, `docs/specs/boot-protocol-v2.md`,
  `docs/specs/m2.2-exitbootservices.md`

## Context

`ExitBootServices` transfers the machine from the firmware to the kernel. At
that moment the firmware stops managing memory, and the boot services code
and data it owned become free. The kernel receives the memory map that was
taken **before** the call, because after the call there is no boot service
left to take another one. That snapshot still labels the boot services
regions as firmware memory even though they are free by the time the kernel
reads it.

M2.2 does not include an allocator: the physical memory manager is M2.3.
Without a written policy, the first allocator would have to guess which
descriptors it may hand out, and a wrong guess is either a corruption of
firmware state that is still in use or memory that does not exist. The
policy therefore belongs to the milestone that creates the ownership
question, not to the allocator that consumes it.

The framebuffer is a special case: it is memory mapped I/O, not RAM, and the
kernel reads it after the transition to prove the mapping survived.

## Decision

The pre-`ExitBootServices` memory map is the authoritative inventory of
physical memory until M2.3 replaces it with the allocator's own structure.
Every page the kernel touches must be covered by a descriptor that this
policy allows it to touch.

### 1. Classification

| UEFI type | Policy |
| --------- | ------ |
| `loader_code`, `loader_data` | **Owned by the kernel.** The kernel image, the initial stack, `boot_info` and the memory map buffer live here. Not free. |
| `conventional` | **Free.** The allocator may hand it out in M2.3. |
| `boot_services_code`, `boot_services_data` | **Free at the transition, quarantined until M2.3.** The allocator may use them only after it has reclassified them and recorded that the firmware no longer owns them. |
| `runtime_services_code`, `runtime_services_data` | **Reserved.** Never allocatable. Runtime services may still use them after the transition. |
| `acpi_reclaim` | **Reserved until consumed.** Holds ACPI tables; M3 may copy or parse them, after which the memory can be released explicitly. |
| `acpi_nvs` | **Reserved.** Never allocatable. |
| `unusable`, `reserved`, `pal_code` | **Never touched.** |
| `memory_mapped_io`, `memory_mapped_io_port_space` | **Not RAM.** Only the framebuffer range described by `boot_info.framebuffer` is accessed, and only after the geometry is validated against `size`. |
| `persistent_memory` | **Reserved.** Not allocatable in M2. |

Unknown type values are treated as reserved. A firmware may define OEM types;
none of them is memory the kernel may allocate without a specific decision.

### 2. The kernel image is reserved by the protocol, not by the map

The bootloader loads the kernel at its link address and validates that the
range is conventional memory, but it does not change the firmware map. The
map therefore still reports `[kernel_start, kernel_end)` as conventional.
The range is reserved by `boot_info`, and M2.3 must subtract it (and every
other loader range) before it hands out a page.

The stack, `boot_info` and the map buffer are allocated from the firmware
pool, so they do appear in the map as `loader_data`; the kernel checks that
the map describes its own buffer.

### 3. Order of use

1. In M2.2 the kernel only **reads** memory: the boot information, the map,
   the framebuffer and its own stack. It allocates nothing.
2. M2.3 builds the frame allocator from the map, applying the table above,
   and records the reclassification of the boot services regions.
3. Until that reclassification exists, no code may use a boot services page.
   The pages are free in hardware terms; they are not yet free in the
   kernel's bookkeeping.
4. The memory map buffer must not be freed or reused while it is the only
   record. M2.3 may copy it into its own structure first.

### 4. Evidence in the log

The kernel reports the map key, the conventional, boot services and loader
totals, and the type of the descriptor that covers the map buffer. These
values are the audit trail for the policy: a boot where the map buffer is
not `loader_data`, or where a descriptor wraps around the address space, is
refused instead of being used.

## Alternatives rejected

* **Allocate boot services memory immediately after `ExitBootServices`.**
  Rejected: the firmware's teardown is not specified to leave those pages in
  a known state, and the kernel has no way to tell stale firmware data from
  free memory before it has an allocator.
* **Trust the map as post-transition truth without reclassification.**
  Rejected: the snapshot predates the transition by construction. Treating
  it as final would either leak the boot services memory or, worse, let the
  kernel reuse a page the firmware still touches through a runtime service.
* **Reserve the kernel image by editing the map in the bootloader.**
  Rejected for M2.2: the UEFI specification does not provide a supported way
  to change the type of an arbitrary range, and the protocol already carries
  the exact range.
* **Treat the framebuffer as conventional memory.** Rejected: it is MMIO;
  writing to it through an allocator would corrupt the display, and reading
  it as RAM would fault or return device state.

## Consequences

* M2.2 is read-only with respect to physical memory. Its checks prove the
  environment survived; they do not build on it yet.
* M2.3 has a written input: conventional memory plus the reclassified boot
  services regions, minus the loader ranges, the kernel image, ACPI, runtime
  services and MMIO.
* The totals in the boot log are not "free memory": they are the inventory
  the allocator will start from.
* If AzuraOS later calls runtime services, the runtime regions stay reserved
  and the policy does not change.

## References

* `shared/boot_info.zig` — the fields the policy reads.
* `docs/specs/boot-protocol-v2.md` — the handover contract.
* `docs/specs/m2.2-exitbootservices.md` — the acceptance criteria.
* UEFI Specification 2.10, the memory map description and the Boot Services
  chapter (`GetMemoryMap` and `ExitBootServices`).
