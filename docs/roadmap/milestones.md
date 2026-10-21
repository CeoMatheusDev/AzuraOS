# AzuraOS milestones

The roadmap of the master prompt, with the state of each milestone and what
"done" means for it. A milestone is only closed when its acceptance criteria
have been executed and the evidence is recorded in `docs/testing/`.

## M0 — Engineering

**Acceptance:** a documented command reproduces the build and the tool test.

State: **done**.

* Toolchain policy, pinned to Zig 0.17.0 (`docs/TOOLCHAIN.md`).
* Build contract and invariants (`docs/BUILD_CONTRACT.md`).
* Reproducible build graph (`build.zig`), package manifest
  (`build.zig.zon`).
* Static ELF gate for the kernel artifact (`tools/check-kernel-elf.sh`).
* Diagnostics for the host and for Fedora
  (`tools/check-toolchain.sh`, `tools/fedora-m01-report.sh`).
* Architecture decision records.

## M1 — Boot

**Acceptance:** the UEFI image boots in QEMU, writes to the serial port and
the framebuffer, stops safely; the log and a screenshot exist; the test is
automated, bounded by a timeout and has a verifiable exit status.

State: **done**, evidence in `docs/testing/m1-boot-evidence.md`.

* UEFI bootloader, freestanding kernel, versioned boot protocol.
* Serial log, framebuffer splash, memory map handover.
* IDT with reported CPU exceptions.
* `zig build boot`, `zig build boot-test`, `zig build fault-test`.

## M2 — Kernel minimum

**Acceptance:** stress tests of the allocator, controlled page faults, and no
regression of the boot.

In progress. M2.1 is merged into `main` (PR #1), M2.2 is merged into `main`
(PR #2, `02e5f3d`), M2.2b (TSS and IST) is merged into `main` (PR #5,
`c376528`) and M2.3 (physical frame allocator) is merged into `main`
(PR #6, `870b677`).

| Step | Content | State |
| ---- | ------- | ----- |
| M2.1 | Own GDT, own segments | done, `docs/adr/ADR-0004-kernel-gdt.md` |
| M2.2 | `ExitBootServices` with the memory map key | done, merged in `02e5f3d`; evidence in `docs/testing/m2.2-exitbootservices-evidence.md`; ownership policy in `docs/adr/ADR-0007-memory-ownership-after-exitbootservices.md` |
| M2.2b | TSS and IST stacks for `#NMI`, `#DF` and `#MC` | done, merged in `c376528`; evidence in `docs/testing/m2.2b-tss-ist-evidence.md`; decision in `docs/adr/ADR-0008-tss-and-ist.md` |
| M2.3 | Physical memory manager, frame allocation and release | done, merged in `870b677` (PR #6); evidence in `docs/testing/m2.3-frames-evidence.md`; decision in `docs/adr/ADR-0009-physical-frame-allocator.md` |
| M2.4 | Own paging, W^X, NX, controlled page faults | not started |
| M2.5 | Kernel heap, allocation and fragmentation tests | not started |
| M2.6 | Timer, monotonic clock, verified interrupts | not started |
| M2.7 | Serial and framebuffer drivers without the firmware | not started |
| M2.8 | Regression: M1 still works | the boot tests run on every step |

The order matters. Before calling `ExitBootServices`, the bootloader has to
guarantee that the code, the stack, the page tables, the GDT, the IDT and the
framebuffer stay accessible, and it has to handle the memory map key change
the specification requires.

`ExitBootServices` and the installation of the kernel's own page tables are
distinct operations and may be split into steps, as long as the sequence
guarantees that no address the kernel still needs becomes unmapped. M2.2
implements the first operation and leaves the firmware mapping in place; the
acceptance criteria are in `docs/specs/m2.2-exitbootservices.md` and the
measured evidence in `docs/testing/m2.2-exitbootservices-evidence.md`.

A TSS with an alternate stack for critical faults, in particular `#DF`, is
needed before interrupts become complex or processes are isolated. Without it
a fault on the kernel stack cannot be reported. It was implemented right
after M2.2 as M2.2b; the decision is in `docs/adr/ADR-0008-tss-and-ist.md`
and the acceptance criteria in `docs/specs/m2.2b-tss-ist.md`.

M2.3 implements the frame allocator over conventional memory and defers the
boot services reclassification to M2.4. The firmware page tables are still
active and live in boot services memory, so freeing those ranges now would
free the page tables under the kernel. ADR-0009 records the decision, the
4 GiB bitmap limit and the boot self-test; the acceptance criteria are in
`docs/specs/m2.3-physical-frames.md`. It is merged in `870b677` (PR #6)
with CI green on `main` (run 39635441041).

## M3 — Execution

**Acceptance:** two separate processes exchange messages without touching
each other's memory.

Not started. Planned content: threads, a preemptive scheduler, the syscall
interface, process isolation, capabilities and IPC.

## M4 — Storage

**Acceptance:** read and write with restart and failure tests.

Not started. Planned content: the VFS, the initramfs, the virtio block
driver, a first file system, the userland and a shell.

## M5 — Desktop

**Acceptance:** windows can be opened, moved and resized in QEMU, with
measured RAM usage and latency.

Not started. Planned content: input, a software rasteriser, a compositor,
fonts, windows, the taskbar, the launcher, the explorer and the settings.

## M6 — Native ecosystem

**Acceptance:** a native application runs in isolation, the parser has tests
and the permission policy is enforced.

Not started. Planned content: the fundamental libraries, the loader, the
versioned AZX specification, packaging and the first applications.

## M7 — Compatibility

**Acceptance:** a matrix of real programs and known failures.

Not started. Planned content: the Linux ELF loader and ABI, then the PE/Win32
subsystem, then RPM and AppImage handling. "Compatible" is never used
without a scope.

## M8 — Hardware and production

**Acceptance:** tests on physical machines and a performance regression
suite.

Not started. Planned content: the hardware drivers, AArch64, accelerated
graphics, audio, networking, hardening, benchmarks, signed updates and
verified boot.

## Versioning

The project follows SemVer 2.0.0. While the system is pre-1.0 the internal
milestones are published as `0.x.y`. The first `1.0.0-alpha.1` pre-release
is only justified when the milestones M0 to M5 are closed and the boot
chain, the memory management and the process model are all verified. Tags
are annotated and `alpha`, `beta` and `rc` are marked as pre-releases.
