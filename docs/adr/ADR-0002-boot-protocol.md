# ADR-0002 — Boot protocol between the UEFI bootloader and the kernel

- Status: accepted
- Date: 2026-10-20
- Milestone: M1
- Related: ADR-0001, ADR-0003, `docs/specs/boot-protocol-v1.md`

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

The bootloader loads the kernel segments at their link address and then:

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
* the initial stack pointer,
* a pointer to the firmware memory map, its entry count and the firmware's
  descriptor size,
* the framebuffer geometry and pixel masks,
* the firmware vendor string and revision.

All address fields are plain integers; `0` means "absent". There are no
pointers to Zig objects, no slices and no optionals.

*Rationale.* A fixed layout can be validated with a compile time size
assertion, described in a specification, and implemented in another
language later without a C header generator.

*Consequence.* The structure is 136 bytes. The compile time assertions in
`shared/boot_info.zig` fail the build if the layout ever changes by
accident.

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

The magic is `"AZURAS1"` and the version is `1`. Any incompatible change to
the structure, the call convention or the semantics of a field requires a new
magic and a new version.

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
* `docs/specs/boot-protocol-v1.md` — the field by field specification.
* UEFI Specification 2.10, section 2.3.4 (memory map) and 3.4 (boot
  services).
