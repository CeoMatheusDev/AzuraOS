# AzuraOS boot protocol, version 1

Normative description of the handover between the UEFI bootloader and the
kernel. The machine readable definition is `shared/boot_info.zig`; this
document explains the fields and the rules.

## Transfer of control

1. The bootloader disables hardware interrupts (`cli`).
2. The bootloader sets RSP to the top of a 16 KiB stack it allocated from
   the firmware pool. The stack grows down.
3. The bootloader sets RDI to the address of the `boot_info` structure.
4. The bootloader jumps to the ELF entry point of the kernel image.

The entry point is the exported symbol `azura_kernel_entry`, declared with
the C calling convention, so RDI carries its single argument.

The bootloader does not call `ExitBootServices`. The kernel therefore runs
inside the firmware's flat 64-bit environment, with the firmware's GDT
still loaded. Owning the machine is M2 work.

## The boot_info structure

Size: 136 bytes. All fields are fixed width.

| Offset | Size | Field | Meaning |
| ------ | ---- | ----- | ------- |
| 0  | 8  | `magic` | `0x415A5552414F5331` (`"AZURAS1"`). |
| 8  | 4  | `version` | Protocol version, currently `1`. |
| 12 | 4  | `size` | `sizeof(boot_info)` of the producer. |
| 16 | 8  | `kernel_entry` | Virtual address of the kernel entry point. |
| 24 | 8  | `kernel_start` | Lowest physical byte written by the loader. |
| 32 | 8  | `kernel_end` | Highest physical byte written by the loader, exclusive. |
| 40 | 8  | `stack_top` | Initial stack pointer for the kernel. |
| 48 | 8  | `memory_map` | Pointer to the memory map, or `0`. |
| 56 | 4  | `memory_map_count` | Number of descriptors. |
| 60 | 4  | `memory_map_descriptor_size` | Size of one descriptor, normally `40`. |
| 64 | 4  | `framebuffer_present` | `1` when the framebuffer fields are valid. |
| 68 | 4  | `_reserved0` | Reserved, `0`. |
| 72 | 48 | `framebuffer` | Framebuffer geometry, see below. |
| 120| 8  | `firmware_vendor` | Pointer to a NUL terminated UTF-16 string, or `0`. |
| 128| 4  | `firmware_revision` | UEFI firmware revision. |
| 132| 4  | `_reserved1` | Reserved, `0`. |

### The framebuffer structure

| Offset | Size | Field | Meaning |
| ------ | ---- | ----- | ------- |
| 0  | 8 | `base` | Physical address of the linear framebuffer. |
| 8  | 8 | `size` | Size of the framebuffer in bytes. |
| 16 | 4 | `width` | Width in pixels. |
| 20 | 4 | `height` | Height in pixels. |
| 24 | 4 | `stride` | Bytes per scan line. |
| 28 | 4 | `pixel_format` | Always `bit_mask` (2) in version 1. |
| 32 | 4 | `red_mask` | Bit mask of the red channel. |
| 36 | 4 | `green_mask` | Bit mask of the green channel. |
| 40 | 4 | `blue_mask` | Bit mask of the blue channel. |
| 44 | 4 | `reserved_mask` | Bit mask of the reserved channel. |

The masks are normalised by the bootloader: for the two 8-bit-per-colour GOP
formats the masks are derived from the format, so the kernel always uses the
mask based interpretation.

### The memory map

The descriptors use the UEFI `EFI_MEMORY_DESCRIPTOR` layout:

| Offset | Size | Field |
| ------ | ---- | ----- |
| 0  | 4 | `Type` (memory type) |
| 4  | 4 | padding |
| 8  | 8 | `PhysicalStart` |
| 16 | 8 | `VirtualStart` |
| 24 | 8 | `NumberOfPages` |
| 32 | 8 | `Attribute` |

The memory types are the UEFI values: `0` reserved, `1` loader code, `2`
loader data, `3` boot services code, `4` boot services data, `5` runtime
services code, `6` runtime services data, `7` conventional, `8` unusable,
`9` ACPI reclaim, `10` ACPI NVS, `11` memory mapped I/O, `12` memory mapped
I/O port space, `13` PAL code, `14` persistent memory.

## Rules

### The bootloader must

1. Refuse to hand over if the kernel image is not ELF64, little endian,
   x86_64, `ET_EXEC`.
2. Refuse to hand over if a `PT_LOAD` segment references bytes outside the
   image, or if `p_memsz < p_filesz`, or if the address range overflows.
3. Refuse to hand over if the entry point is outside every loaded segment.
4. Refuse to hand over if the load range is not covered by conventional
   memory.
5. Take the final memory map snapshot **after** its own allocations.
6. Set `magic` and `version` to the values of the protocol it implements.

### The kernel must

1. Refuse to start if `magic` does not match.
2. Refuse to start if `version` is not supported.
3. Refuse to start if `size` is smaller than the structure it knows.
4. Use `memory_map_descriptor_size` to walk the map, not a hard coded
   stride.
5. Treat `framebuffer_present == 0` as "no framebuffer" instead of using
   the framebuffer fields.

## Version history

| Version | Change |
| ------- | ------ |
| 1 | Initial protocol: memory map, framebuffer, kernel range, stack. |
