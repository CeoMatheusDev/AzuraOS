# Changelog

All notable changes to AzuraOS are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and
the project follows [Semantic Versioning 2.0.0](https://semver.org/).

Because the project starts from zero, the internal milestones use `0.x.y`
versions until the system is mature enough to justify a `1.0.0-alpha.1`
pre-release. That decision is recorded in `docs/STATUS.txt`.

## [Unreleased]

Nothing yet.

## [0.1.0] — 2026-10-20

Milestone M1: the first boot chain. The UEFI bootloader loads a freestanding
kernel from the EFI System Partition, hands over a versioned boot protocol,
and the kernel reports the machine it found before halting.

### Added

- `boot/uefi/`: the UEFI bootloader (PE/COFF, `x86_64-uefi`).
  - Polled COM1 driver for a verifiable boot log.
  - GOP discovery and a software drawn boot splash.
  - A strict ELF64 loader that accepts only ELF64 / little endian / x86_64
    / `ET_EXEC` and validates every offset and size.
  - Firmware memory map retrieval and a conventional memory check for the
    kernel load range.
  - Allocation of the initial kernel stack and the control transfer to the
    kernel entry point.
- `kernel/`: the kernel (ELF64, `x86_64-freestanding`).
  - Boot protocol validation (magic, version, structure size).
  - A boot log describing the memory map and the framebuffer.
  - An IDT that reports CPU exceptions with their vector, RIP, CS and
    RFLAGS, and halts the machine instead of letting them escalate to a
    triple fault.
  - `kernel/linker.ld`, which places the kernel at the fixed address
    `0x100000`.
- `shared/boot_info.zig`: the normative boot protocol, compiled into both
  stages so a mismatch is a compile error.
- `shared/com1.zig`: the serial driver, shared by both stages.
- `shared/framebuffer.zig`: the framebuffer checksum, computed by the
  bootloader over the pixels it painted and recomputed by the kernel after
  the handover. The boot test asserts that the two values are equal, which
  is the real proof that the framebuffer was written and survived the
  handover; the QEMU `screendump` picture does not capture the GOP
  framebuffer faithfully.
- `build.zig`: the build graph, with the steps `bootloader`, `kernel`,
  `esp`, `boot`, `unit-test`, `boot-test`, `fault-test` and `test`.
- `tools/make-esp.sh`: builds the FAT EFI System Partition image.
- `tools/run-qemu-m1.sh`: boots the image in QEMU with OVMF, captures the
  serial log and takes a screenshot.
- `tools/qemu-screenshot.py` and `tools/ppm-to-png.py`: the screenshot
  helpers, with no dependency outside the Python standard library.
- `tests/boot/test-m1-boot.sh` and `tests/boot/test-m1-fault-handler.sh`:
  the automated QEMU tests, both bounded by a timeout and with a verifiable
  exit status.
- `docs/adr/ADR-0001`, `ADR-0002`, `ADR-0003`, `docs/specs/boot-protocol-v1.md`
  and `docs/testing/m1-boot-evidence.md`.
- `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`.

### Changed

- The repository layout follows the structure proposed by the master prompt:
  `src/kernel/` became `kernel/`, `src/probe/` became `tools/probe/`, and
  the shared code moved to `shared/`.
- The M0.1 freestanding probe moved from `src/probe/` to `tools/probe/`; the
  `zig build probe` and `zig build rebuild-check` steps are unchanged.

### Removed

- `tools/build-m01-kernel-elf.sh` and the `kernel-elf` build step. The
  nonbootable kernel prototype they built is superseded by the real kernel
  produced by `zig build kernel`, which passes the same static ELF gate
  (`tools/check-kernel-elf.sh`).

### Known limitations

- The kernel runs on the firmware's GDT and page tables and does not call
  `ExitBootServices`. Owning the machine is M2 work.
- The kernel load address is fixed at `0x100000` and is validated against
  the firmware memory map; see ADR-0003.
- Hardware interrupts are not handled: the IDT covers CPU exceptions only
  and the kernel runs with interrupts disabled.
- No userland, no filesystem, no drivers and no graphical desktop.

[Unreleased]: https://github.com/CeoMatheusDev/AzuraOS/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/CeoMatheusDev/AzuraOS/releases/tag/v0.1.0
