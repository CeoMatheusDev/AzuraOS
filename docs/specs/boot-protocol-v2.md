# AzuraOS boot protocol, version 2

Normative description of the handover between the UEFI bootloader and the
kernel. The machine readable definition is `shared/boot_info.zig`; this
document explains the fields and the rules.

## Transfer of control

The bootloader performs every allocation, every firmware console write and
the splash before it leaves the boot services. The order is normative:

1. The bootloader loads the kernel, allocates the kernel stack, the
   `boot_info` structure and the memory map buffer from the firmware pool.
2. It paints the splash, prints the console line and computes the
   framebuffer checksum.
3. It takes the final memory map snapshot. The key returned by that call is
   the one `ExitBootServices` must see.
4. It fills the `boot_info` structure, including that key and the map.
5. It calls `ExitBootServices(image_handle, key)`. If the firmware answers
   `EFI_INVALID_PARAMETER`, the map changed after the snapshot: the
   bootloader takes a new snapshot, updates `boot_info` and retries, a
   bounded number of times.
6. On success it sets `boot_services_exited = 1` and calls no firmware
   service again. From this point the machine belongs to the kernel.
7. It disables hardware interrupts (`cli`), sets RSP to `stack_top`, sets RDI
   to the address of `boot_info` and jumps to the ELF entry point.

The entry point is the exported symbol `azura_kernel_entry`, declared with
the C calling convention, so RDI carries its single argument.

The bootloader does **not** install page tables. After the handover the
kernel still runs on the firmware's flat 64-bit mapping; installing the
kernel's own page tables is M2.4. The kernel logs the CR3 it inherited so the
state is never assumed.

## The boot_info structure

Size: 160 bytes. All fields are fixed width.

| Offset | Size | Field | Meaning |
| ------ | ---- | ----- | ------- |
| 0  | 8  | `magic` | `0x415A5552414F5332` (`"AZURAS2"`). |
| 8  | 4  | `version` | Protocol version, currently `2`. |
| 12 | 4  | `size` | `sizeof(boot_info)` of the producer. |
| 16 | 8  | `kernel_entry` | Virtual address of the kernel entry point. |
| 24 | 8  | `kernel_start` | Lowest physical byte written by the loader. |
| 32 | 8  | `kernel_end` | Highest physical byte written by the loader, exclusive. |
| 40 | 8  | `stack_top` | Initial stack pointer for the kernel, exclusive. |
| 48 | 8  | `memory_map` | Pointer to the memory map, or `0`. |
| 56 | 4  | `memory_map_count` | Number of descriptors. |
| 60 | 4  | `memory_map_descriptor_size` | Size of one descriptor, normally `40`. |
| 64 | 4  | `framebuffer_present` | `1` when the framebuffer fields are valid. |
| 68 | 4  | `_reserved0` | Reserved, `0`. |
| 72 | 48 | `framebuffer` | Framebuffer geometry, see below. |
| 120| 8  | `firmware_vendor` | Pointer to a NUL terminated UTF-16 string, or `0`. |
| 128| 4  | `firmware_revision` | UEFI firmware revision. |
| 132| 4  | `_reserved1` | Reserved, `0`. |
| 136| 8  | `stack_base` | Base of the kernel stack, inclusive. |
| 144| 8  | `memory_map_key` | Key used by the successful `ExitBootServices`. |
| 152| 4  | `boot_services_exited` | `1` when the call succeeded, `0` otherwise. |
| 156| 4  | `_reserved2` | Reserved, `0`. |

The protocol 2 fields are appended after the protocol 1 fields on purpose:
the offsets of the original fields do not move.

### The framebuffer structure

| Offset | Size | Field | Meaning |
| ------ | ---- | ----- | ------- |
| 0  | 8 | `base` | Physical address of the linear framebuffer. |
| 8  | 8 | `size` | Size of the framebuffer in bytes. |
| 16 | 4 | `width` | Width in pixels. |
| 20 | 4 | `height` | Height in pixels. |
| 24 | 4 | `stride` | Bytes per scan line. |
| 28 | 4 | `pixel_format` | Always `bit_mask` (2). |
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

The map is the snapshot taken **before** `ExitBootServices`, because after
the call no boot service exists to take another one. It therefore still
classifies the boot services regions as firmware memory. They become free at
the transition, but the kernel does not allocate them until M2.3; the policy
is ADR-0007.

## Rules

### The bootloader must

1. Refuse to hand over if the kernel image is not ELF64, little endian,
   x86_64, `ET_EXEC`.
2. Refuse to hand over if a `PT_LOAD` segment references bytes outside the
   image, or if `p_memsz < p_filesz`, or if the address range overflows.
3. Refuse to hand over if the entry point is outside every loaded segment.
4. Refuse to hand over if the load range is not covered by conventional
   memory.
5. Size the memory map buffer from the size the firmware reports, not from a
   fixed constant, and validate `descriptor_size` before walking it.
6. Take the final memory map snapshot **after** every allocation and pass
   its key to `ExitBootServices`.
7. On `EFI_INVALID_PARAMETER`, take a new snapshot, update `boot_info` and
   retry. The number of attempts is bounded.
8. Call no boot service after a successful `ExitBootServices`.
9. Hand over only after a successful `ExitBootServices`; set
   `boot_services_exited = 1` only in that case.
10. Set `magic` and `version` to the values of the protocol it implements.

### The kernel must

1. Refuse to start if `magic` does not match.
2. Refuse to start if `version` is not supported.
3. Refuse to start if `size` is smaller than the structure it knows.
4. Refuse to start if `boot_services_exited != 1`.
5. Use `memory_map_descriptor_size` to walk the map, not a hard coded
   stride.
6. Treat `framebuffer_present == 0` as "no framebuffer" instead of using
   the framebuffer fields.
7. Treat the memory map as the pre-`ExitBootServices` snapshot and apply
   ADR-0007 before allocating from it.

## Version history

| Version | Change |
| ------- | ------ |
| 1 | Initial protocol: memory map, framebuffer, kernel range, stack. |
| 2 | `ExitBootServices` before the jump: `stack_base`, `memory_map_key` and `boot_services_exited`; magic becomes `"AZURAS2"`. |
