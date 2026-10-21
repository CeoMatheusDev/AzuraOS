# M1 boot evidence

> Historical record of M1. The statements below about the GDT and about
> `ExitBootServices` describe the M1 artifacts; M2.1 and M2.2 superseded
> them. Current evidence: `docs/testing/m2.2-exitbootservices-evidence.md`.

Everything on this page was produced by running the commands shown, on the
machine described below. Nothing here is a projection of what the code
should do.

## Environment

| Item | Value |
| ---- | ----- |
| Host | Fedora Linux 44 (KDE Plasma Desktop Edition), x86_64, kernel 7.2.10-200.fc44 |
| Compiler | Zig 0.17.0 (`/home/matheus/.local/opt/zig/0.17.0/zig`) |
| Emulator | QEMU 10.2.2 (`qemu-10.2.2-1.fc44`) |
| Firmware | edk2-ovmf 20260812-8.fc44 (`/usr/share/edk2/ovmf/OVMF_CODE.fd`) |
| Image tools | mtools 4.0.49-3.fc44 |
| Machine under test | `q35`, 512 MiB RAM, 1 vCPU, TCG |

## Artifacts

| Artifact | Size | SHA-256 |
| -------- | ---- | ------- |
| `zig-out/bin/azura-bootloader.efi` | 64000 bytes | `ae61a0900adf386e7a278189b403339efff7cf84fbfdffc4f7acd4ec73920537` |
| `zig-out/bin/azura-kernel.elf` | 17552 bytes | `035d143eccd88917a19b4726910fb13fc11d71fa9e1a7d20b40b46e81211f21c` |

The two artifacts are **byte identical across clean rebuilds** on this host
(`rm -rf .zig-cache zig-out && zig build`, then `cmp` against the previous
copy: both reported no difference). This is repeatability on one machine with
one toolchain, not hermetic reproducibility across machines.

The bootloader is a PE32+ image for EFI applications, the kernel is a
statically linked, stripped ELF64 `ET_EXEC` for x86_64, loaded at
`0x100000`.

## The boot

Command:

```sh
zig build esp
bash tools/run-qemu-m1.sh zig-out/azura-esp.img zig-out/boot
```

Serial log (`zig-out/boot/serial.log`, carriage returns and the firmware's
terminal escape sequences removed):

```
BdsDxe: loading Boot0002 "UEFI QEMU HARDDISK QM00011 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x5,0xFFFF,0x0)
BdsDxe: starting Boot0002 "UEFI QEMU HARDDISK QM00011 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x5,0xFFFF,0x0)
[azura] === AzuraOS UEFI bootloader v0.1.0 (M1) ===
AzuraOS bootloader v0.1.0
[azura] firmware vendor: EDK II
[azura] framebuffer: 1280x800 stride=1280 bytes=4096000
[azura] kernel image: 17552 bytes
[azura] memory map: 85 entries
[azura] kernel loaded: entry=0x100000 range=0x100000..0x104300 segments=3
[azura] kernel stack: 16384 bytes, top=0x1dff5018
[azura] final memory map: 86 entries
[azura] framebuffer checksum: 0xd43a1e5ec0808a0d
[azura] jumping to the kernel entry point
AzuraOS: handing over to the kernel
[azura] === AzuraOS kernel v0.1.0 (M1) ===
[azura] boot protocol: version 1, 136 bytes
[azura] kernel image: 0x100000..0x104300
[azura] stack top: 0x1dff5018
[azura] memory map: 86 entries
[azura] conventional memory: 463 MiB
[azura]   map[0] conventional phys=0x0 pages=135
[azura]   map[1] boot_services_data phys=0x87000 pages=1
[azura]   map[2] conventional phys=0x88000 pages=24
[azura]   map[3] conventional phys=0x100000 pages=1792
[azura]   map[4] acpi_nvs phys=0x800000 pages=8
[azura]   map[5] conventional phys=0x808000 pages=3
[azura]   map[6] acpi_nvs phys=0x80b000 pages=1
[azura]   map[7] conventional phys=0x80c000 pages=6
[azura]   ... 78 more entries
[azura] framebuffer: 1280x800 stride=1280 base=0x80000000 size=4096000
[azura] framebuffer masks: r=0xff0000 g=0xff00 b=0xff
[azura] framebuffer checksum: 0xd43a1e5ec0808a0d
[azura] IDT installed, exception handling active
[azura] boot complete, halting
```

The first two lines come from the OVMF boot manager; everything from the
third line on is AzuraOS.

### What this proves

* The firmware loaded `EFI/BOOT/BOOTX64.EFI` from the FAT EFI System
  Partition on the emulated SATA disk, without any NVRAM entry.
* The bootloader brought up COM1 and produced a deterministic log.
* The bootloader found the GOP framebuffer (1280x800, 4 MiB, BGRX masks).
* The bootloader read `azura-kernel.elf` (17552 bytes) from the ESP,
  validated it, and copied its three `PT_LOAD` segments to `0x100000`.
* The kernel received a valid `boot_info` (136 bytes, protocol version 1),
  read the firmware memory map (86 entries, 463 MiB of conventional memory)
  and the framebuffer geometry.
* The kernel installed its IDT and stopped in a controlled halt.

### What this does not prove

* Nothing was tested on real hardware. Everything here is an emulated
  x86_64 machine with an emulated firmware.
* The kernel does not own the machine: it still runs on the firmware's GDT
  and page tables and never calls `ExitBootServices`.
* There is no userland, no filesystem, no driver and no scheduler.
* The boot is not measured for time: the log has no timestamps, so no boot
  time figure is claimed.

## The framebuffer

### How it is verified

The QEMU `screendump` monitor command does **not** faithfully capture the GOP
linear framebuffer of the emulated video device: on this machine it returns
a surface that shows only the first rows of the framebuffer the guest wrote,
mixed with the firmware's own text rendering. The guest's own view of its
framebuffer is correct, but the picture is not a reliable witness.

The verification therefore does not rely on the picture. Both stages compute
a checksum over the framebuffer they can see:

* the bootloader computes it after it painted the splash and after the
  firmware console wrote its last line,
* the kernel recomputes it after the handover, using the geometry it
  received in `boot_info`,
* the automated test compares the two values.

Both stages printed the same value in the run above:

    [azura] framebuffer checksum: 0xd43a1e5ec0808a0d   (bootloader)
    [azura] framebuffer checksum: 0xd43a1e5ec0808a0d   (kernel)

Equal checksums prove that the kernel sees exactly the pixels the bootloader
wrote, which is a stronger statement than any screenshot. The checksum is an
FNV-1a 64 bit over every 16th row of the framebuffer (the framebuffer is
memory mapped I/O, so reading all 4 MiB would be needlessly slow); the
implementation is `shared/framebuffer.zig` and is compiled into both stages.

During the development of this milestone, a temporary diagnostic build
confirmed the guest side directly: the kernel read back the pixel at rows
0, 100, 200, 207, 208, 300, 500 and 799 and found the value written by the
bootloader in every one of them.

### The picture

`zig-out/boot/screen.png` is a QEMU `screendump` of the graphical console,
converted from PPM to PNG with `tools/ppm-to-png.py`. It shows the gradient
and the boot splash in the upper left area, plus the firmware's console
text. Because of the limitation described above, the picture is an
illustration, not the proof.

Sampling the raw PPM (`zig-out/boot/screen.ppm`, 1280x800) shows the pixels
the bootloader wrote:

| Position | Colour | Meaning |
| -------- | ------ | ------- |
| (5, 5) | (12, 28, 65) | Top of the vertical gradient. |
| (106, 66) | (96, 168, 240) | Border of the mock window. |
| (400, 200) | (28, 34, 48) | Body of the mock window. |

The firmware's own console text is also visible in the capture, which
confirms that the text output and the graphics output are independent
paths.

## The exception handler

Command:

```sh
zig build esp -Dfault-inject=true
bash tools/run-qemu-m1.sh zig-out/azura-esp.img zig-out/boot-fault
```

The kernel is built with a deliberate `ud2` after the IDT is installed. The
relevant part of the serial log:

```
[azura] IDT installed, exception handling active
[azura] fault injection requested, executing an invalid opcode
[azura] KERNEL FAULT: vector 6 (invalid opcode)
[azura] KERNEL FAULT: rip=0x10010e cs=0x38 rflags=0x10002
[azura] KERNEL FAULT: machine halted
```

* Vector 6 is `#UD`, the invalid opcode exception.
* `rip=0x10010e` points inside the kernel's text segment, at the `ud2`
  instruction.
* `cs=0x38` is the code segment selector the firmware was running with; the
  kernel reuses it instead of assuming a GDT layout it does not own.
* `rflags=0x10002` has the reserved bit set, as expected in long mode.
* The machine halted instead of triple faulting, and the firmware did not
  restart: the bootloader banner appears exactly once in the whole log.

## The tests

```sh
zig build unit-test     # 9 tests, all passing
zig build boot-test     # PASS: the M1 boot sequence completed in QEMU/OVMF
zig build fault-test    # PASS: the kernel exception handler reported the fault and halted the machine
```

The QEMU tests are bounded by a timeout (`AZURA_QEMU_TIMEOUT`, 90 s by
default) and exit with `0` (pass), `1` (fail) or `2` (cannot run).

## The memory map observed on OVMF

The first entries of the map reported by the firmware, which is why the
kernel is linked at `0x100000` and not at Zig's default `0x1000000`:

| Index | Type | Physical start | Pages |
| ----- | ---- | -------------- | ----- |
| 0 | conventional | 0x0 | 135 |
| 1 | boot_services_data | 0x87000 | 1 |
| 2 | conventional | 0x88000 | 24 |
| 3 | conventional | 0x100000 | 1792 |
| 4 | acpi_nvs | 0x800000 | 8 |
| 11 | boot_services_data | 0x900000 | 3712 |

`0x1000000` (16 MiB) falls inside entry 11, which is firmware scratch
memory. Loading the kernel there would have corrupted the firmware; the
bootloader refuses to do it and prints the map. See ADR-0003.
