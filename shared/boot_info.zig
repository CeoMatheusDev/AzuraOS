//! AzuraOS boot protocol — shared ABI between the UEFI bootloader and the kernel.
//!
//! This file is compiled into BOTH the bootloader (boot/uefi) and the kernel
//! (kernel/). It is the single normative definition of the handover contract;
//! see docs/specs/boot-protocol-v1.md and docs/adr/ADR-0002-boot-protocol.md.
//!
//! Rules for this file:
//!   * `extern struct` layouts only — no Zig-specific runtime representation.
//!   * No pointers to Zig objects, no slices, no optionals.
//!   * Every field is fixed width so the layout is identical on both sides.
//!   * 0 is the "absent" sentinel for every address/pointer field.
//!
//! Bump `version` and `magic` on ANY incompatible layout change.

const std = @import("std");

/// "AZURAS1" in big-endian byte order. Rejects a kernel built against a
/// different contract instead of interpreting garbage.
pub const magic: u64 = 0x415a5552414f5331;

/// Current boot protocol revision.
pub const version: u32 = 1;

/// The UEFI memory types, flattened to plain integers so the kernel does not
/// need to depend on the UEFI headers. Values follow the UEFI 2.10
/// specification, section 2.3.4 (Table 9).
pub const memory_type = enum(u32) {
    reserved = 0,
    loader_code = 1,
    loader_data = 2,
    boot_services_code = 3,
    boot_services_data = 4,
    runtime_services_code = 5,
    runtime_services_data = 6,
    conventional = 7,
    unusable = 8,
    acpi_reclaim = 9,
    acpi_nvs = 10,
    memory_mapped_io = 11,
    memory_mapped_io_port_space = 12,
    pal_code = 13,
    persistent_memory = 14,
    _,
};

/// Human readable name of a UEFI memory type.
///
/// The value is taken as a raw integer on purpose: the firmware may report a
/// type outside the range defined by the specification, for example an OEM
/// specific one, and converting an out of range value into an enum is
/// undefined behaviour in Zig.
pub fn memoryTypeName(value: u32) []const u8 {
    return switch (value) {
        0 => "reserved",
        1 => "loader_code",
        2 => "loader_data",
        3 => "boot_services_code",
        4 => "boot_services_data",
        5 => "runtime_services_code",
        6 => "runtime_services_data",
        7 => "conventional",
        8 => "unusable",
        9 => "acpi_reclaim",
        10 => "acpi_nvs",
        11 => "memory_mapped_io",
        12 => "memory_mapped_io_port_space",
        13 => "pal_code",
        14 => "persistent_memory",
        else => "unknown",
    };
}

/// One entry of the physical memory map handed to the kernel.
///
/// The layout is the UEFI `EFI_MEMORY_DESCRIPTOR`: a 32 bit type, 4 bytes
/// of padding, then the 64 bit fields.
pub const memory_descriptor = extern struct {
    /// Raw UEFI memory type. See `memoryTypeName`.
    type: u32,
    physical_start: u64,
    virtual_start: u64,
    number_of_pages: u64,
    attribute: u64,
};

/// GOP pixel layout. The masks are only meaningful when `pixel_format` is
/// `.bit_mask`; for the two 8-bit-per-colour formats the masks are derived
/// from the format and stored explicitly so the kernel never has to guess.
pub const pixel_format = enum(u32) {
    red_green_blue_reserved_8_bit_per_color = 0,
    blue_green_red_reserved_8_bit_per_color = 1,
    bit_mask = 2,
    blt_only = 3,
};

/// Linear framebuffer description (GOP). `base` is a physical address; the
/// UEFI environment identity-maps it, and the kernel is responsible for
/// mapping it once it owns the page tables.
pub const framebuffer = extern struct {
    base: u64,
    size: u64,
    width: u32,
    height: u32,
    /// Bytes per scanline, not necessarily width * 4.
    stride: u32,
    pixel_format: pixel_format,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    reserved_mask: u32,
};

/// The structure handed to the kernel entry point in RDI.
pub const boot_info = extern struct {
    /// Must equal `magic`.
    magic: u64,
    /// Must equal `version`.
    version: u32,
    /// `sizeof(boot_info)` of the producer, for forward compatibility.
    size: u32,

    /// Virtual address of the kernel entry point (ELF e_entry).
    kernel_entry: u64,
    /// Lowest and highest physical byte touched by the loaded kernel image.
    kernel_start: u64,
    kernel_end: u64,
    /// Initial stack pointer for the kernel (exclusive top of a stack page).
    stack_top: u64,

    /// Pointer to an array of `memory_map_count` `memory_descriptor`s, or 0.
    memory_map: u64,
    memory_map_count: u32,
    /// `sizeof(memory_descriptor)` as reported by the firmware (normally 40).
    memory_map_descriptor_size: u32,

    /// 1 when `framebuffer` holds valid data, 0 otherwise.
    framebuffer_present: u32,
    _reserved0: u32,
    framebuffer: framebuffer,

    /// Pointer to a NUL-terminated UTF-16 firmware vendor string, or 0.
    firmware_vendor: u64,
    firmware_revision: u32,
    _reserved1: u32,
};

comptime {
    // The layout must be stable; a silent change here breaks the contract
    // between two independently built artifacts.
    if (@sizeOf(boot_info) != 136) @compileError("boot_info layout changed");
    if (@sizeOf(memory_descriptor) != 40) @compileError("memory_descriptor layout changed");
    if (@sizeOf(framebuffer) != 48) @compileError("framebuffer layout changed");
}
