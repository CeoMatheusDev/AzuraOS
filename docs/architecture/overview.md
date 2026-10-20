# AzuraOS architecture overview

A short map of the system. The decisions behind it are recorded in
`docs/adr/`; the contracts are in `docs/specs/`.

## Layers

```
+---------------------------------------------------------------+
|  Desktop (M5, not started)                                     |
|  shell, compositor, taskbar, launcher, explorer, settings      |
+---------------------------------------------------------------+
|  Applications (M6, not started)                               |
|  native applications, the AZX loader, the package format       |
+---------------------------------------------------------------+
|  Userland (M4, not started)                                   |
|  libc, POSIX subset, the shell, the system services            |
+---------------------------------------------------------------+
|  Kernel (M2+)                                                  |
|  mm (physical/virtual memory, heap)  sched (threads, SMP)     |
|  ipc (messages, capabilities)        syscall (the ABI)        |
|  security (capabilities, ACL, isolation)                      |
|  drivers (serial, framebuffer, timer, PCI, virtio)            |
+---------------------------------------------------------------+
|  Hardware abstraction layer (M2+)                              |
+---------------------------------------------------------------+
```

## The two boot stages

AzuraOS boots in two stages, and the split is deliberate: the kernel must
never contain firmware specific code.

| | Bootloader | Kernel |
| --- | --- | --- |
| Format | PE/COFF, `x86_64-uefi` | ELF64, `x86_64-freestanding` |
| Runs in | the firmware environment | the environment the firmware leaves behind |
| Talks to | the UEFI boot services | the hardware |
| Loads | the kernel | nothing yet |

The only thing the two share is `shared/boot_info.zig`, the boot protocol.
Because that file is compiled into both artifacts, the two sides cannot
disagree about the layout.

## The trust boundaries

```
firmware  --->  bootloader  --->  kernel
   |                |                |
   |                |                +-- hardware
   |                +-- kernel image (parsed as untrusted input)
   +-- memory map, GOP, file system (also treated as untrusted input)
```

* The bootloader treats the kernel image as hostile: only ELF64, little
  endian, x86_64, `ET_EXEC` is accepted, and every offset is checked.
* The bootloader treats the firmware's memory map as hostile too: the
  kernel's load range must be covered by conventional memory.
* The kernel validates the boot protocol before it uses any field of it.

## Source layout

| Path | Content |
| ---- | ------- |
| `boot/uefi/` | The UEFI bootloader: serial, console, framebuffer, ELF loader, memory map, control transfer. |
| `kernel/` | The kernel entry point and the x86_64 architecture code. |
| `kernel/arch/x86_64/` | The parts that are specific to the CPU: the IDT, the exception handlers, the low level primitives. |
| `shared/` | Code compiled into both stages: the boot protocol and the serial driver. |
| `tools/` | The image builder, the QEMU runner and the screenshot helpers. |
| `tests/` | The unit tests, the QEMU boot tests and the toolchain tests. |

## Memory map

The kernel has no virtual memory management yet. The M1 kernel runs with the
firmware's identity mapped page tables and the firmware's GDT, which means:

* physical addresses are directly addressable,
* the kernel is limited to the 4 GiB below the identity window,
* no isolation between the kernel and the firmware exists.

Owning the machine (own GDT, own page tables, `ExitBootServices`) is the
first task of M2.

## Where the desktop comes from

The desktop is not a special mode of the kernel. It is a userland
application that talks to the kernel through syscalls and draws through a
compositor. The visual language (taskbar, windows, launcher) is inspired by
the usability of Windows 10, but every line of code, every icon and every
asset is original to this project.

## Related documents

* `docs/adr/ADR-0001-architecture-and-abi.md`
* `docs/adr/ADR-0002-boot-protocol.md`
* `docs/adr/ADR-0003-kernel-load-address.md`
* `docs/specs/boot-protocol-v1.md`
* `docs/roadmap/milestones.md`
* `docs/testing/m1-boot-evidence.md`
