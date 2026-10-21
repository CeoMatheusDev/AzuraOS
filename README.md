# AzuraOS

An independent, open source operating system, written primarily in Zig.

AzuraOS is being built from zero: kernel, bootloader, HAL, memory
management, scheduler, IPC, drivers, userland, libraries and a desktop
environment. Nothing is inherited from an existing kernel, and no
compatibility is claimed unless it has been demonstrated.

> **Status: M2.2 (`ExitBootServices`) implemented on its branch.** The
> bootloader now hands the machine over with the boot services gone, and the
> kernel proves that the stack, the GDT, the IDT, the framebuffer and the
> memory map survived. The merge into `main` is pending; M1 is the latest
> state on `main`.

## Current state

| Milestone | State | Evidence |
| --------- | ----- | -------- |
| M0 Engineering | done | `docs/STATUS.txt`, `docs/TOOLCHAIN.md`, reproducible build graph |
| M1 Boot | done | `docs/testing/m1-boot-evidence.md` |
| M2.1 Kernel GDT | done, merged in `1e87504` (PR #1) | `docs/adr/ADR-0004-kernel-gdt.md` |
| CI (GitHub Actions) | **passing** | run 39537277273 (main, `1e87504`) |
| M2.2 `ExitBootServices` | done on `feat/m2-exit-boot-services`, merge pending | `docs/testing/m2.2-exitbootservices-evidence.md` |
| M3 Execution | not started | — |

The boot chain implemented today:

```
OVMF (UEFI firmware)
  └─ EFI/BOOT/BOOTX64.EFI      azura-bootloader.efi   (PE/COFF, x86_64-uefi)
       ├─ reads azura-kernel.elf from the EFI System Partition
       ├─ validates the ELF64 image and the firmware memory map
       ├─ copies the PT_LOAD segments to 0x100000
       ├─ takes the final memory map and calls ExitBootServices with its key
       └─ jumps to azura_kernel_entry with RDI = &boot_info
            └─ azura-kernel.elf  (ELF64, x86_64-freestanding)
                 ├─ validates the boot protocol (including the transition)
                 ├─ proves stack, GDT, IDT, framebuffer and map survived
                 ├─ installs the IDT (CPU exceptions are reported, not fatal)
                 └─ halts
```

## Requirements

Verified on Fedora Linux 44 (x86_64):

| Tool | Version used | Notes |
| ---- | ------------ | ----- |
| Zig | 0.17.0 | Exact version required; `tools/build-m01-probe.sh` refuses anything else. |
| QEMU | 10.2.2 | `qemu-system-x86_64`. |
| OVMF | edk2-ovmf 20260812 | Provides the UEFI firmware and the GOP framebuffer. |
| mtools | 4.0.49 | Builds the FAT EFI System Partition image. |
| binutils | any recent | `readelf` is used by the ELF gate. |

No runtime dependency is linked into the kernel or the bootloader: both are
freestanding.

## Build and run

```sh
# Build both artifacts (the kernel ELF is checked by a static gate).
zig build

# Build the EFI System Partition image.
zig build esp

# Boot it in QEMU with OVMF; prints the serial log and saves a screenshot.
zig build boot
```

`zig build boot` leaves the evidence in `zig-out/boot/`:

* `serial.log` — the COM1 capture of the whole boot,
* `screen.ppm` / `screen.png` — a screenshot of the graphical console (an
  illustration; the framebuffer proof is the checksum in the serial log).

## Tests

```sh
zig build unit-test       # host unit tests (ELF parser, IDT helpers)
zig build boot-test       # boots the image in QEMU and checks the boot sequence
zig build fault-test      # boots a fault injection kernel and checks the handler
zig build ebs-retry-test  # boots with a stale memory map key and checks the retry
zig build test            # all of the above
```

Every QEMU test is bounded by a timeout and exits with a verifiable status:
`0` pass, `1` fail, `2` cannot run (missing tool or missing image).

The expected boot log, produced by the current artifacts, is (trimmed: the
memory map preview and a few setup lines are omitted):

```
[azura] === AzuraOS UEFI bootloader v0.1.0 (M2.2) ===
[azura] firmware vendor: EDK II
[azura] framebuffer: 1280x800 stride=1280 bytes=4096000
[azura] kernel image: 25872 bytes
[azura] memory map: 85 entries
[azura] kernel loaded: entry=0x100000 range=0x100000..0x106400 segments=3
[azura] kernel stack: 16384 bytes, base=0x1e00d018 top=0x1e011018
[azura] boot information: 160 bytes at 0x1e6ab018
[azura] framebuffer checksum: 0xd43a1e5ec0808a0d
[azura] final memory map: 85 entries, key=0x731
[azura] ExitBootServices: attempt 1, key=0x731, entries=85
[azura] ExitBootServices: success
[azura] boot services exited, map key=0x731
[azura] jumping to the kernel entry point
[azura] === AzuraOS kernel v0.1.0 (M2.2) ===
[azura] boot protocol: version 2, 160 bytes
[azura] boot services: exited, memory map key=0x731
[azura] page tables: the firmware's (CR3=0x1f401000), the kernel's own are M2.4
[azura] kernel image: 0x100000..0x106400
[azura] stack: base=0x1e00d018 top=0x1e011018
[azura] memory map: 85 entries
[azura] memory: conventional=464 MiB boot_services=42 MiB loader=144 KiB
[azura] memory map buffer: 0x1e6a9018 (loader_data)
[azura] framebuffer: 1280x800 stride=1280 base=0x80000000 size=4096000
[azura] framebuffer checksum: 0xd43a1e5ec0808a0d
[azura] IDT installed, exception handling active
[azura] stack: writable at 0x1e010d60, inside 0x1e00d018..0x1e011018
[azura] IDT: base=0x1053d0 limit=4095
[azura] post-ExitBootServices: stack=ok gdt=ok idt=ok framebuffer=ok memory_map=ok
[azura] boot complete, halting
```

The boot test also asserts that the memory map key the kernel receives is the
one the successful `ExitBootServices` call used, and the retry test forces a
stale key to check that the bootloader refreshes it instead of giving up.

The framebuffer checksum is computed by the bootloader over the pixels it
painted and recomputed by the kernel after the handover. The boot test
asserts that the two values are equal, which proves that the kernel sees
exactly the framebuffer the bootloader left behind. This is used instead of
a screenshot, because the QEMU `screendump` monitor command does not
faithfully capture the GOP framebuffer of the emulated video device (see
`docs/testing/m1-boot-evidence.md`).

## Repository layout

```
boot/uefi/          UEFI bootloader (stage 1)
kernel/             kernel (stage 2) and the x86_64 architecture code
shared/             code compiled into both stages: the boot protocol and the serial driver
tools/              build, image and QEMU helpers
tests/boot/         automated QEMU boot tests
tests/build/        tests for the static ELF gate
tests/toolchain/    tests for the toolchain diagnostics
docs/adr/           architecture decision records
docs/specs/         normative specifications (the boot protocol)
docs/testing/       measured evidence
```

## Documentation

* `docs/adr/ADR-0001-architecture-and-abi.md` — the architecture and the ABI.
* `docs/adr/ADR-0002-boot-protocol.md` — the bootloader/kernel contract.
* `docs/adr/ADR-0003-kernel-load-address.md` — why the kernel is linked at 1 MiB.
* `docs/adr/ADR-0004-kernel-gdt.md` — the kernel's own GDT, and the descriptor
  layout that must not be got wrong.
* `docs/adr/ADR-0005-exception-frame-and-abi.md` — the exception frame, the
  ABI fixup in the stub, and the two defects the review of PR #1 found.
* `docs/adr/ADR-0006-apache-2-0-license.md` — the license decision, the
  rejected alternatives and the dependency policy.
* `docs/adr/ADR-0007-memory-ownership-after-exitbootservices.md` — which
  physical memory the kernel may touch after the transition, and when.
* `docs/specs/boot-protocol-v2.md` — field by field specification.
* `docs/testing/m1-boot-evidence.md` — the measured evidence of M1.
* `docs/testing/m2.2-exitbootservices-evidence.md` — the measured evidence
  of the transition, the stale key retry and the fault path after it.
* `docs/STATUS.txt` — the running status log.
* `docs/TOOLCHAIN.md` — the toolchain policy.
* `docs/BUILD_CONTRACT.md` — the build invariants.
* `AGENTS.md` — the rules that apply to AI contributions.
* `CONTRIBUTING.md` — how to contribute.
* `SECURITY.md` — how to report a security issue.

## Scope and honesty

* Nothing in this repository is claimed to be more than it is. The boot log
  above is real output captured from QEMU; the screenshot is a real frame
  buffer capture.
* There is no graphical desktop, no userland, no filesystem and no driver
  yet. The roadmap lives in `docs/roadmap/milestones.md`.
* The kernel still runs on the firmware's page tables; it does not install
  its own until M2.4. The boot log prints the CR3 it inherited on every boot.
* The memory map is the pre-`ExitBootServices` snapshot. The boot services
  regions are free in hardware terms but are not allocated until M2.3; see
  ADR-0007.

## License

AzuraOS is licensed under the [Apache License, Version 2.0](LICENSE).
The full text is in `LICENSE`, the attribution notice is in `NOTICE`, and
the decision, with the alternatives that were rejected and the consequences
for dependencies and compatibility layers, is recorded in
`docs/adr/ADR-0006-apache-2-0-license.md`.

Contributions are accepted under the same license, without a separate
contributor license agreement; see `CONTRIBUTING.md`.
