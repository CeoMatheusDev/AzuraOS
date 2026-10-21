//! x86_64 long-mode Task State Segment layout.
//! Pure data definitions; LTR and IST integration require QEMU validation.
const std = @import("std");

pub const Tss = extern struct {
    reserved0: u32 = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    ist1: u64 align(1) = 0,
    ist2: u64 align(1) = 0,
    ist3: u64 align(1) = 0,
    ist4: u64 align(1) = 0,
    ist5: u64 align(1) = 0,
    ist6: u64 align(1) = 0,
    ist7: u64 align(1) = 0,
    reserved2: u64 align(1) = 0,
    reserved3: u16 = 0,
    io_map_base: u16 = 104,
};

/// Available 64-bit TSS descriptor: two contiguous GDT slots.
pub const Descriptor = extern struct {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: u8,
    limit_high_flags: u8,
    base_high: u8,
    base_upper: u32,
    reserved: u32,
};

pub fn descriptor(base: u64) Descriptor {
    const limit: u32 = @sizeOf(Tss) - 1;
    return .{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_middle = @truncate(base >> 16),
        .access = 0x89,
        .limit_high_flags = @truncate((limit >> 16) & 0x0f),
        .base_high = @truncate(base >> 24),
        .base_upper = @truncate(base >> 32),
        .reserved = 0,
    };
}

comptime {
    if (@sizeOf(Tss) != 104) @compileError("invalid TSS size");
    if (@offsetOf(Tss, "rsp0") != 4) @compileError("invalid RSP0 offset");
    if (@offsetOf(Tss, "ist1") != 36) @compileError("invalid IST1 offset");
    if (@offsetOf(Tss, "io_map_base") != 102) @compileError("invalid I/O map offset");
    if (@sizeOf(Descriptor) != 16) @compileError("invalid TSS descriptor size");
}

test "TSS defaults and I/O bitmap boundary" {
    const tss: Tss = .{};
    try std.testing.expectEqual(@as(u16, 104), tss.io_map_base);
    try std.testing.expectEqual(@as(u64, 0), tss.ist1);
}

test "TSS descriptor encodes 64-bit base" {
    const base: u64 = 0x1234_5678_9abc_def0;
    const entry = descriptor(base);
    try std.testing.expectEqual(@as(u8, 0x89), entry.access);
    try std.testing.expectEqual(@as(u16, 103), entry.limit_low);
    try std.testing.expectEqual(@as(u8, 0), entry.limit_high_flags);
    try std.testing.expectEqual(@as(u32, 0), entry.reserved);
    try std.testing.expectEqual(base,
        @as(u64, entry.base_low) |
        (@as(u64, entry.base_middle) << 16) |
        (@as(u64, entry.base_high) << 24) |
        (@as(u64, entry.base_upper) << 32));
}

 
/// Selector 0x18 occupies GDT slots 3 and 4. The firmware CS alias
/// must not overlap either slot while the GDT is being installed.
pub const selector: u16 = 0x18;
pub const descriptor_slot: usize = selector >> 3;
pub const descriptor_slots: usize = 2;

/// An IDT IST field is three bits wide. Zero selects the current stack.
pub const double_fault_ist: u8 = 1;

/// Returns whether a firmware CS selector can coexist with the reserved
/// TSS slots during the firmware-to-kernel GDT transition.
pub fn firmwareSelectorCompatible(firmware_cs: u16) bool {
    if ((firmware_cs & 0x7) != 0) return false;
    const slot: usize = firmware_cs >> 3;
    return slot != descriptor_slot and slot != descriptor_slot + 1;
}

/// Verify a downward-growing stack is usable as an IST stack.
/// Both bounds must be canonical in 48-bit VA mode, and the top aligned.
/// Mapping, reservation, and guard pages are checked separately at boot.
pub fn validIstStack(base: u64, top: u64) bool {
    if (base == 0 or top <= base or top - base < 4096) return false;
    if ((top & 15) != 0) return false;
    return canonical48(base) and canonical48(top) and canonical48(top - 1) and
        ((base >> 47) & 1) == (((top - 1) >> 47) & 1);
}

fn canonical48(address: u64) bool {
    const upper = address >> 48;
    return if ((address & (@as(u64, 1) << 47)) == 0)
        upper == 0
    else
        upper == 0xffff;
}

comptime {
    if (descriptor_slot != 3) @compileError("TSS selector must start at GDT slot 3");
    if (double_fault_ist < 1 or double_fault_ist > 7)
        @compileError("invalid double-fault IST index");
}

test "TSS descriptor occupies reserved GDT slots" {
    try std.testing.expectEqual(@as(usize, 3), descriptor_slot);
    try std.testing.expectEqual(@as(usize, 2), descriptor_slots);
    try std.testing.expect(firmwareSelectorCompatible(0x08));
    try std.testing.expect(firmwareSelectorCompatible(0x38));
    try std.testing.expect(!firmwareSelectorCompatible(0x18));
    try std.testing.expect(!firmwareSelectorCompatible(0x20));
    try std.testing.expect(!firmwareSelectorCompatible(0x1b));
}

test "IST stack boundaries reject invalid ranges" {
    try std.testing.expect(validIstStack(0x100000, 0x104000));
    try std.testing.expect(!validIstStack(0, 0x104000));
    try std.testing.expect(!validIstStack(0x100000, 0x100000));
    try std.testing.expect(!validIstStack(0x100000, 0x100100));
    try std.testing.expect(!validIstStack(0x100000, 0x104008));
    try std.testing.expect(!validIstStack(0x100000, 0x0001_0000_0000_0000));
    try std.testing.expect(!validIstStack(0x0000_7fff_ffff_f000, 0x0000_8000_0000_1000));
    try std.testing.expect(!validIstStack(0x0000_8000_0000_0000, 0x0000_8000_0000_2000));
    // The exclusive end is loaded into RSP and must itself be canonical.
    try std.testing.expect(!validIstStack(0x0000_7fff_ffff_c000, 0x0000_8000_0000_0000));
    try std.testing.expect(validIstStack(0xffff_8000_0000_0000, 0xffff_8000_0000_4000));
}
