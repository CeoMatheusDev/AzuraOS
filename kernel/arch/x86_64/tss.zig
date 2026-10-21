//! Task State Segment and the alternate stack for critical faults.
//!
//! The kernel needs a TSS for one reason in this milestone: without it the
//! processor has no IST (interrupt stack table), so a fault taken while the
//! kernel stack is unusable would escalate to a triple fault and reboot the
//! machine silently. The TSS gives the processor an alternate stack (IST1)
//! for `#DF`, `#NMI` and `#MC`; see `ist.zig` for the policy.
//!
//! Layout (Intel SDM Vol. 3, Figure 7-11 and 7.14.2):
//!
//!   offset  size  field
//!   0       4     reserved
//!   4       8     RSP0 (stack for a ring 3 -> ring 0 transition)
//!   12      8     RSP1
//!   20      8     RSP2
//!   28      8     reserved
//!   36      8     IST1
//!   44..92  8x6   IST2..IST7
//!   92      8     reserved
//!   100     2     reserved
//!   102     2     I/O map base
//!
//! The structure is **packed**: RSP0 starts at offset 4, not at offset 8.
//! The processor reads the fields at their documented offsets, so padding
//! would make it read the wrong values. The last field ends at byte 104;
//! Zig rounds `@sizeOf` up to the struct alignment (112), so the GDT limit
//! and the I/O map base use the architectural size constant `size`.
//!
//! The TSS descriptor is a 16 byte system descriptor and therefore occupies
//! two GDT slots. It lives at selector 0x18 (indices 3 and 4); see `gdt.zig`.

const std = @import("std");
const cpu = @import("cpu.zig");

/// Selector of the TSS descriptor in the kernel GDT (index 3, ring 0).
pub const selector: u16 = 0x18;

/// Size of the alternate stack. 16 KiB matches the boot stack and leaves
/// room for the exception frame plus the formatted fault report.
pub const stack_size: usize = 16 * 1024;

/// Architectural size of the 64-bit TSS. Zig rounds `@sizeOf(Tss)` up to the
/// struct's alignment, so the GDT limit and the I/O map base use this value.
pub const size: u16 = 104;

/// Access byte of an available 64-bit TSS: present, DPL 0, system, type 9.
pub const access_byte: u8 = 0x89;

/// The 64-bit TSS as the processor reads it.
pub const Tss = packed struct {
    reserved0: u32,
    rsp0: u64,
    rsp1: u64,
    rsp2: u64,
    reserved1: u64,
    ist1: u64,
    ist2: u64,
    ist3: u64,
    ist4: u64,
    ist5: u64,
    ist6: u64,
    ist7: u64,
    reserved2: u64,
    reserved3: u16,
    iomap_base: u16,
};

comptime {
    if (@bitSizeOf(Tss) != size * 8) @compileError("the 64-bit TSS is 104 bytes");
    if (@bitOffsetOf(Tss, "rsp0") != 32) @compileError("RSP0 is at byte offset 4");
    if (@bitOffsetOf(Tss, "ist1") != 288) @compileError("IST1 is at byte offset 36");
    if (@bitOffsetOf(Tss, "iomap_base") != 816) @compileError("the I/O map base is at byte offset 102");
}

/// The fields of the TSS descriptor after decoding, for verification.
pub const DecodedDescriptor = struct {
    base: u64,
    limit: u16,
    access: u8,
    /// The flags nibble (G, D/B, L, AVL). Zero means byte granularity.
    flags: u8,
};

/// The TSS the processor uses. It lives in `.bss` and is filled by `init`.
var tss: Tss align(16) = std.mem.zeroes(Tss);

/// The alternate stack. It must stay mapped for as long as the TSS is
/// loaded, so it is a static object and not an allocation.
var ist_stack: [stack_size]u8 align(16) = undefined;

/// The value written by `probeStack`, to prove the stack is writable before
/// a fault needs it.
const stack_probe_pattern: u64 = 0x157a_c0de_1234_5678;

/// Prepare the TSS and the IST1 stack.
///
/// `rsp0` is the stack the processor uses on a ring 3 -> ring 0 transition.
/// There is no user mode yet; the boot stack is used so the field is never
/// zero and a future transition cannot load an empty stack pointer by
/// accident.
pub fn init(rsp0: u64) void {
    tss = std.mem.zeroes(Tss);
    tss.rsp0 = rsp0;
    tss.ist1 = stackTop();
    // With no I/O permission bitmap the base must point past the limit of
    // the TSS. The kernel does not use port I/O from user mode yet.
    tss.iomap_base = size;
}

/// Load the task register with `selector`.
///
/// The GDT must already carry the descriptor, otherwise the instruction
/// raises #GP. Called after `gdt.init` and before the IDT entries that use
/// IST are installed.
pub fn load() void {
    cpu.loadTaskRegister(selector);
}

/// The current values of the TSS.
pub fn state() Tss {
    return tss;
}

/// Base address of the TSS, for the GDT descriptor.
pub fn address() u64 {
    return @intFromPtr(&tss);
}

/// Limit of the TSS: the last valid byte offset (103).
pub fn limit() u16 {
    return size - 1;
}

/// Base address of the IST1 stack.
pub fn stackBase() u64 {
    return @intFromPtr(&ist_stack);
}

/// Top of the IST1 stack (the address just past its last byte).
pub fn stackTop() u64 {
    return stackBase() + stack_size;
}

/// Write and read back a known value at the top of the IST1 stack.
///
/// The stack is only used when a critical fault happens; touching one word
/// at boot proves that the page is mapped and writable while the failure can
/// still be reported as a boot error.
///
/// Returns the probed address, or null when the value did not read back.
pub fn probeStack() ?u64 {
    const probe_address = stackTop() - @sizeOf(u64);
    const slot: *volatile u64 = @ptrFromInt(probe_address);
    slot.* = stack_probe_pattern;
    if (slot.* != stack_probe_pattern) return null;
    return probe_address;
}

/// Encode the 16 byte system descriptor of the TSS.
///
/// The low word carries the limit and the base split across the classic
/// 8 byte descriptor, the access byte says "present, 64-bit available TSS",
/// and the high word carries base bits 63:32.
pub fn encodeDescriptor(base: u64, limit_value: u16) [2]u64 {
    const limit_low: u64 = limit_value & 0xffff;
    const base_low: u64 = base & 0xffff;
    const base_middle: u64 = (base >> 16) & 0xff;
    const base_high: u64 = (base >> 24) & 0xff;
    const limit_high: u64 = (@as(u64, limit_value) >> 16) & 0x0f;

    const low: u64 = limit_low |
        (base_low << 16) |
        (base_middle << 32) |
        (@as(u64, access_byte) << 40) |
        (limit_high << 48) |
        (base_high << 56);

    return .{ low, base >> 32 };
}

/// Decode a system descriptor, to prove the GDT holds what `encodeDescriptor`
/// wrote before the processor is trusted with it.
pub fn decodeDescriptor(descriptor: [2]u64) DecodedDescriptor {
    const low = descriptor[0];
    const high = descriptor[1];

    const base: u64 = ((low >> 16) & 0xffff) |
        (((low >> 32) & 0xff) << 16) |
        (((low >> 56) & 0xff) << 24) |
        ((high & 0xffff_ffff) << 32);

    const limit_value: u16 = @truncate((low & 0xffff) | (((low >> 48) & 0x0f) << 16));

    return .{
        .base = base,
        .limit = limit_value,
        .access = @truncate(low >> 40),
        .flags = @truncate((low >> 52) & 0x0f),
    };
}

// --- Unit tests -------------------------------------------------------------

const testing = std.testing;

test "the TSS has the layout the processor expects" {
    try testing.expectEqual(@as(u16, 104), size);
    try testing.expectEqual(@as(usize, size * 8), @bitSizeOf(Tss));
    try testing.expectEqual(@as(usize, 4), @bitOffsetOf(Tss, "rsp0") / 8);
    try testing.expectEqual(@as(usize, 36), @bitOffsetOf(Tss, "ist1") / 8);
    try testing.expectEqual(@as(usize, 100), @bitOffsetOf(Tss, "reserved3") / 8);
    try testing.expectEqual(@as(usize, 102), @bitOffsetOf(Tss, "iomap_base") / 8);
}

test "the descriptor is a present 64-bit available TSS" {
    const descriptor = encodeDescriptor(0x1234_5678_9abc_def0, 103);
    const decoded = decodeDescriptor(descriptor);

    try testing.expectEqual(@as(u64, 0x1234_5678_9abc_def0), decoded.base);
    try testing.expectEqual(@as(u16, 103), decoded.limit);
    // Present (0x80), system (0x00), type 9 (available 64-bit TSS).
    try testing.expectEqual(@as(u8, 0x89), decoded.access);
    try testing.expectEqual(@as(u8, 0), decoded.flags);
}

test "the descriptor round trips the base above 4 GiB" {
    const base: u64 = 0x0000_0001_ffff_fff0;
    const decoded = decodeDescriptor(encodeDescriptor(base, 103));
    try testing.expectEqual(base, decoded.base);
    try testing.expectEqual(@as(u16, 103), decoded.limit);
    try testing.expectEqual(@as(usize, 16), @sizeOf([2]u64));
}

test "init fills the TSS and keeps the I/O bitmap disabled" {
    init(0xdead_beef_0000_1000);
    const current = state();

    try testing.expectEqual(@as(u64, 0xdead_beef_0000_1000), current.rsp0);
    try testing.expectEqual(stackTop(), current.ist1);
    try testing.expectEqual(@as(u64, 0), current.ist2);
    try testing.expectEqual(@as(u64, 0), current.ist7);
    try testing.expectEqual(@as(u32, 0), current.reserved0);
    // Any value above the limit means "no I/O permission bitmap".
    try testing.expectEqual(@as(u16, 104), current.iomap_base);
    try testing.expectEqual(@as(u16, 103), limit());
}

test "the IST stack probe reaches the top of the stack" {
    init(0);
    const probe_address = probeStack() orelse return error.ProbeFailed;
    try testing.expectEqual(stackTop() - @sizeOf(u64), probe_address);
    try testing.expect(probe_address >= stackBase());
    try testing.expect(probe_address < stackTop());
}

test "the selector names the reserved GDT slot" {
    try testing.expectEqual(@as(u16, 0x18), selector);
    try testing.expectEqual(@as(u16, 0), selector & 0x7);
    try testing.expectEqual(@as(u16, 3), selector >> 3);
    // The descriptor is 16 bytes, so it occupies indices 3 and 4.
    try testing.expectEqual(@as(usize, 2), @sizeOf([2]u64) / 8);
}
