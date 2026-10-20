# AzuraOS

An independent, open source operating system, written primarily in Zig.

AzuraOS is being built from zero: kernel, bootloader, HAL, memory
management, scheduler, IPC, drivers, userland, libraries and a desktop
environment. Nothing is inherited from an existing kernel, and no
compatibility is claimed unless it has been demonstrated.

> **Status: M1 (boot) reached.** The UEFI bootloader and the kernel boot in
> QEMU/OVMF on x86_64, write a verifiable serial log, paint the firmware
> framebuffer and stop in a controlled way. There is no userland, no
> filesystem and no graphical desktop yet.

## Current state

| Milestone | State | Evidence |
| --------- | ----- | -------- |
| M0 Engineering | done | `docs/STATUS.txt`, `docs/TOOLCHAIN.md`, reproducible build graph |
| M1 Boot | done | `docs/testing/m1-boot-evidence.md` |
| M2.1 Kernel GDT | in progress | `docs/adr/ADR-0004-kernel-gdt.md` |
| M2.2 `ExitBootServices` | not started | — |
| M3 Execution | not started | — |

The boot chain implemented today:

```
OVMF (UEFI firmware)
  └─ EFI/BOOT/BOOTX64.EFI      azura-bootloader.efi   (PE/COFF, x86_64-uefi)
       ├─ reads azura-kernel.elf from the EFI System Partition
       ├─ validates the ELF64 image and the firmware memory map
       ├─ copies the PT_LOAD segments to 0x100000
       └─ jumps to azura_kernel_entry with RDI = &boot_info
            └─ azura-kernel.elf  (ELF64, x86_64-freestanding)
                 ├─ validates the boot protocol
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
zig build unit-test    # host unit tests (ELF parser, IDT helpers)
zig build boot-test    # boots the image in QEMU and checks the boot sequence
zig build fault-test   # boots a fault injection kernel and checks the handler
zig build test         # all of the above
```

Every QEMU test is bounded by a timeout and exits with a verifiable status:
`0` pass, `1` fail, `2` cannot run (missing tool or missing image).

The expected boot log, produced by the current artifacts, is:

```
[azura] === AzuraOS UEFI bootloader v0.1.0 (M1) ===
[azura] firmware vendor: EDK II
[azura] framebuffer: 1280x800 stride=1280 bytes=4096000
[azura] kernel image: 17216 bytes
[azura] memory map: 85 entries
[azura] kernel loaded: entry=0x100000 range=0x100000..0x104240 segments=3
[azura] kernel stack: 16384 bytes, top=0x1dff5018
[azura] final memory map: 86 entries
[azura] jumping to the kernel entry point
[azura] === AzuraOS kernel v0.1.0 (M1) ===
[azura] boot protocol: version 1, 136 bytes
[azura] conventional memory: 463 MiB
[azura] framebuffer: 1280x800 stride=1280 base=0x80000000 size=4096000
[azura] framebuffer checksum: 0xd43a1e5ec0808a0d
[azura] IDT installed, exception handling active
[azura] boot complete, halting
```

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
* `docs/specs/boot-protocol-v1.md` — field by field specification.
* `docs/testing/m1-boot-evidence.md` — the measured evidence of M1.
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
* The kernel still runs on the firmware's GDT and page tables and does not
  call `ExitBootServices`. Owning the machine is M2.

## License

Not yet chosen. The choice is tracked as an open item in
`docs/STATUS.txt`; no empty `LICENSE` file is shipped, and no
copyright is claimed over the code until the decision is made.
