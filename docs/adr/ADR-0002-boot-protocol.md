# ADR-0002 — Boot protocol between the UEFI bootloader and the kernel

- Status: accepted
- Date: 2026-10-20 (revision 2: 2026-10-21)
- Milestone: M1 (revision 2: M2.2)
- Related: ADR-0001, ADR-0003, ADR-0007, `docs/specs/boot-protocol-v2.md`

## Context

The UEFI bootloader and the kernel are two separately built artifacts. They
must agree on:

1. how the kernel entry point is called,
2. what the kernel learns about the machine,
3. how the bootloader hands over the memory map,
4. what happens if the kernel image is malformed.

The prompt requires a "stable bootloader-kernel contract" and warns against
inventing APIs without evidence. The contract therefore has to be small,
explicit and testable.

## Decision

### 1. Control transfer

The bootloader loads the kernel segments at their link address and then
(revision 2 inserts `ExitBootServices` before this sequence; see §6):

* disables interrupts (`cli`),
* loads the stack pointer with the top of a 16 KiB stack it allocated,
* loads RDI with the address of the `boot_info` structure,
* jumps to the ELF entry point.

The kernel entry point is the exported symbol `azura_kernel_entry`, with the
C calling convention, so the first argument arrives in RDI.

*Rationale.* RDI/RSP is the natural convention on x86_64 and matches what
the C ABI prescribes for the first argument. The transfer is performed with
a single assembly block that reads its arguments from a static structure, so
the result does not depend on the register allocator.

### 2. The boot information structure

`shared/boot_info.zig` defines a single `extern struct` with:

* `magic` and `version`, checked by both sides,
* `size`, the size of the structure the producer filled in,
* the kernel entry point and the physical range the kernel image occupies,
* the initial stack base and top,
* a pointer to the firmware memory map, its entry count and the firmware's
  descriptor size,
* the framebuffer geometry and pixel masks,
* the firmware vendor string and revision,
* the memory map key and whether `ExitBootServices` succeeded (revision 2).

All address fields are plain integers; `0` means "absent". There are no
pointers to Zig objects, no slices and no optionals.

*Rationale.* A fixed layout can be validated with a compile time size
assertion, described in a specification, and implemented in another
language later without a C header generator.

*Consequence.* The structure is 160 bytes in revision 2 (136 in revision 1).
The compile time assertions in `shared/boot_info.zig` fail the build if the
layout ever changes by accident.

### 3. The memory map

The bootloader copies the firmware memory map into pool memory and passes a
pointer to it. The descriptor layout is the UEFI `EFI_MEMORY_DESCRIPTOR`
(40 bytes), so the kernel can walk it without the UEFI headers.

*Rationale.* The map is the only way the kernel can know which physical
memory is usable. Copying it costs one allocation and makes the data
independent of the firmware's own allocations.

*Consequence.* The map is a snapshot taken at the moment the bootloader
called `GetMemoryMap`. The bootloader takes the final snapshot **after** all
its own allocations, so the map reflects the state the kernel will see.

### 4. Failure behaviour

* The bootloader validates the ELF header, the program header table and
  every segment before it copies a single byte. A malformed image aborts the
  boot with a `[azura] FATAL:` message and the machine is halted.
* The bootloader verifies that the load range is covered by conventional
  memory. If it is not, the boot aborts with the memory map in the log.
* The kernel checks the magic, the version and the size of `boot_info`
  before it uses any field.
* The kernel installs an IDT that reports CPU exceptions and halts.

*Rationale.* Every failure mode has to be visible in the serial log. A
silent boot failure is indistinguishable from a successful boot in an
automated test.

### 5. Versioning

The magic is `"AZURAS2"` and the version is `2`. Any incompatible change to
the structure, the call convention or the semantics of a field requires a new
magic and a new version.

### 6. Revision 2 — `ExitBootServices` (M2.2)

Revision 2 adds the transition itself to the contract:

* The bootloader calls `ExitBootServices` after its last allocation, with the
  key of the final memory map snapshot.
* On `EFI_INVALID_PARAMETER` (the map changed after the snapshot) it takes a
  new snapshot, updates `boot_info` and retries, at most four times.
* After a success it sets `boot_services_exited = 1`, stores the key in
  `memory_map_key`, calls no boot service again and jumps to the kernel.
* If the call cannot succeed, the bootloader does not hand over: it logs
  `FATAL` and halts.
* The kernel refuses to start when `boot_services_exited != 1`.
* `stack_base` is added because the base of the stack was previously
  implicit, and the acquisition checks need both ends of the range.

*Rationale.* The operation has a defined order and a precondition (the key
must match the current map), and both sides must agree on whether the
transition happened. Deriving "the boot services are gone" from "we jumped"
would be an assumption, not evidence.

*Consequence.* The memory map in `boot_info` is the snapshot taken **before**
the call. The boot services regions it describes are free after the
transition, but the kernel does not allocate them until M2.3; see ADR-0007.
The kernel still runs on the firmware page tables, which it reads back and
logs.

## Consequences

* The kernel can be tested in isolation: a test harness can build a
  `boot_info` by hand and call the entry point.
* The bootloader and the kernel cannot be version-skewed at build time,
  because they share the same header.
* The protocol is intentionally minimal. Scheduling, memory management and
  device discovery are not part of it; they belong to M2 and M3 and will
  extend the structure under a new version if needed.

## References

* `shared/boot_info.zig` — the normative definition.
* `docs/specs/boot-protocol-v2.md` — the field by field specification.
* UEFI Specification 2.10, the memory map description and the Boot Services
  chapter.
