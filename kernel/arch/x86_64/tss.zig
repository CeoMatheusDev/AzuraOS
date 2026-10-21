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
    try std.testing.expectEqual(base,
        @as(u64, entry.base_low) |
        (@as(u64, entry.base_middle) << 16) |
        (@as(u64, entry.base_high) << 24) |
        (@as(u64, entry.base_upper) << 32));
}
