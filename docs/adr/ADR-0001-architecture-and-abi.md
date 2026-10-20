# ADR-0001 — AzuraOS architecture and ABI

- Status: accepted
- Date: 2026-10-20
- Milestone: M0/M1
- Supersedes: none

## Context

AzuraOS is an independent, open source operating system written primarily in
Zig, targeting x86_64 first. The project starts from zero: there is no
existing kernel, bootloader, driver or userland to inherit from. The
decisions taken here constrain every later milestone, so they are recorded
explicitly instead of being implied by the code.

The master prompt (AzuraOS_AI_PROMPT.txt) sets the boundaries: a hybrid
modular kernel, UEFI boot on x86_64, Unix-like principles without reusing the
Linux kernel, a native executable format, and no claim of compatibility that
has not been demonstrated.

## Decision

### 1. Boot chain

    firmware (OVMF)  ->  UEFI bootloader  ->  kernel

The bootloader is a **PE/COFF UEFI application** (`x86_64-uefi` target). It
is the only component that talks to the firmware. The kernel is a
**freestanding ELF64 x86_64 image** (`x86_64-freestanding` target).

The bootloader reads the kernel from the EFI System Partition, validates it,
copies it into RAM, builds a boot information structure and jumps to the
kernel entry point.

*Rationale.* A UEFI application is the only portable way to run before the
kernel owns the machine. Keeping the firmware interaction in a single,
small, auditable component keeps the kernel free of UEFI specifics and makes
the handover contract the only coupling between the two.

*Consequence.* Two artifacts must be built and must agree on the boot
protocol. The protocol lives in exactly one file, `shared/boot_info.zig`,
which is compiled into both artifacts, so a mismatch is a compile error and
not a runtime surprise.

### 2. Boot protocol

The handover is a single `boot_info` structure passed by pointer in RDI to
the kernel entry point, plus a stack pointer set by the bootloader. The
structure is a fixed layout `extern struct` with no pointers, no slices and no
optionals, and it carries a magic value and a version number.

*Rationale.* A versioned, fixed layout structure is the smallest possible
contract. It can be described in a document, implemented in another language
later, and validated with a single size assertion.

*Consequence.* Any incompatible change to the layout requires bumping the
magic and the version. The bootloader refuses to hand over an unknown
version, and the kernel refuses to start with an unknown magic.

### 3. Language and ABI

* The kernel and the bootloader are written in **Zig**.
* Anything that must be callable from C uses the **C ABI** (`callconv(.c)`),
  so the same binary can be linked against a C library later.
* Internal interfaces use plain Zig types; the C ABI is applied at the
  boundary, not everywhere.
* Assembly is used only where Zig cannot express the operation: the IDT
  stubs, the `lidt` instruction and the control transfer to the kernel.

*Rationale.* Zig gives a freestanding target, a static binary with no
runtime dependencies, and checked arithmetic. A C ABI at the boundary keeps
the door open for the native userland libraries planned for M6.

*Consequence.* The `std` library is only partially usable in these targets.
`std.debug.print` pulls in the POSIX threading layer and does not compile
for `x86_64-uefi` or `x86_64-freestanding`; the project therefore uses
`std.fmt.bufPrint` into a fixed buffer plus its own port I/O driver
(`shared/com1.zig`).

### 4. Architecture abstraction

Architecture specific code lives under `kernel/arch/<arch>/` and
`boot/uefi/` is currently x86_64 only. AArch64 is a later milestone.

*Rationale.* The abstractions that matter (the boot protocol, the serial
driver, the ELF loader) are architecture independent already; the CPU
specific parts are isolated so a second architecture does not force a rewrite
of the shared code.

*Consequence.* No multi-architecture build is attempted today. The AArch64
port will show whether the split is adequate.

### 5. Native executable format (AZX)

A native format (`.azx`) is **not** defined yet. The first native
executables will be ELF64, which is already supported by the loader.

*Rationale.* Defining a format before there is a working loader, a working
toolchain and a working userland produces a specification nobody can test.
The prompt also requires studying the trade-offs against ELF first.

*Consequence.* M6 will produce a versioned AZX specification, a fuzzable
parser and a loader, and only then a toolchain that emits it.

### 6. Security posture of the M1 milestone

* The bootloader is the trust boundary: it parses a binary it did not build.
  The ELF parser accepts only ELF64 / little endian / x86_64 / ET_EXEC and
  validates every offset and size against the actual buffer.
* The kernel load address is fixed and checked against the firmware memory
  map before anything is copied (see ADR-0003).
* The kernel installs an IDT that reports CPU exceptions and halts the
  machine, instead of letting them escalate to a triple fault.
* Interrupts stay disabled in M1. Hardware interrupt handling, and the
  privilege separation between the two stages, are M2 work.

*Rationale.* The prompt requires least privilege, rigorous validation and
no silent corruption. A minimal, auditable stage is worth more than a broad
but unverified one.

### 7. What this ADR does NOT decide

* The scheduler and the process model (M3).
* The VFS, the block layer and the file systems (M4).
* The compositor, the window manager and the desktop shell (M5).
* The AZX format and the native toolchain (M6).
* The Linux and Windows compatibility layers (M7).
* Secure boot, verified boot and the update path (M8).

## Consequences

* The project can be built and booted end to end on a stock Fedora host with
  `zig build boot`, which is the acceptance criterion of M1.
* Two artifacts and one shared header file form the whole coupling between
  the stages.
* The M1 kernel runs on the firmware's GDT and page tables. It does not call
  `ExitBootServices`. Owning the machine is M2 work, and is explicitly
  tracked as such.

## References

* UEFI Specification 2.10, sections 3 (Boot Services) and 32 (Loading
  Applications).
* Intel 64 and IA-32 Architectures Software Developer's Manual, volumes 2
  and 3 (interrupt handling, IDT format, memory map).
* `docs/specs/boot-protocol-v1.md` — the normative description of the
  handover.
* `docs/adr/ADR-0002-boot-protocol.md` — the protocol decision in detail.
* `docs/adr/ADR-0003-kernel-load-address.md` — the fixed load address.
