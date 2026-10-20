/* AzuraOS kernel link script (x86_64, freestanding).
 *
 * The kernel is a non relocatable ET_EXEC image: it is loaded at exactly the
 * address it was linked at. The address below must be free in the firmware
 * memory map; the UEFI bootloader verifies the whole range against the map
 * before it copies the image, and refuses to boot otherwise.
 *
 * 0x100000 (1 MiB) is used because it is the conventional kernel load
 * address and it is left as conventional memory by OVMF. See
 * docs/adr/ADR-0003-kernel-load-address.md.
 *
 * The script only changes the base address; the section layout keeps the
 * default LLD behaviour. Any section that is not listed explicitly becomes
 * an orphan and is placed after the listed ones, which is exactly what the
 * default script would do.
 */

ENTRY(azura_kernel_entry)

SECTIONS
{
    . = 0x100000;

    .text : {
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
        *(.eh_frame_hdr)
        *(.eh_frame)
    }

    .data : {
        *(.data .data.*)
        *(.got .got.plt)
    }

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }
}
