//! Global Descriptor Table of the kernel.
//!
//! Until M2.1 the kernel ran on the GDT that the firmware built, which means
//! the kernel only worked because the firmware happened to provide a flat
//! 64-bit code segment. This module installs a GDT that the kernel owns:
//!
//!   selector 0x00  null
//!   selector 0x08  kernel code (long mode, base 0, limit 4 GiB)
//!   selector 0x10  kernel data (base 0, limit 4 GiB)
//!
//! Both segments have base 0, so the flat memory layout the kernel was
//! linked for is preserved.
//!
//! Invariants:
//!   * the table is 8 byte aligned and lives in the first 4 GiB,
//!   * after `init` the CS register holds `kernel_code_selector`,
//!   * the IDT must be (re)installed with `kernel_code_selector` afterwards,
//!     because an IDT entry names the code segment the handler runs in.

const std = @import("std");
const com1 = @import("com1");
const cpu = @import("cpu.zig");
const tss = @import("tss.zig");

/// Selector of the kernel code segment.
pub const kernel_code_selector: u16 = 0x08;

/// Selector of the kernel data segment.
pub const kernel_data_selector: u16 = 0x10;

/// One GDT entry, 8 bytes.
///
/// Layout (Intel SDM Vol. 3, 3.4.5):
///   bits 0-15   limit, bits 0-15
///   bits 16-31  base, bits 0-15
///   bits 32-39  base, bits 16-23
///   bits 40-47  access byte
///   bits 48-51  limit, bits 16-19
///   bits 52-55  flags (G, D/B, L, AVL)
///   bits 56-63  base, bits 24-31
pub const Entry = extern struct {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: u8,
    limit_high_flags: u8,
    base_high: u8,

    /// Build the null descriptor.
    pub fn nullDescriptor() Entry {
        return .{ .limit_low = 0, .base_low = 0, .base_middle = 0, .access = 0, .limit_high_flags = 0, .base_high = 0 };
    }

    /// Build a long mode code segment: present, ring 0, executable, readable.
    ///
    /// The 8 byte form is used because long mode ignores the base and the
    /// limit; the base is still zero so the flat layout is kept.
    ///
    /// `limit_high_flags` holds the limit's bits 16 to 19 in its LOW nibble
    /// and the flags (granularity, default operand size, long mode) in its
    /// HIGH nibble. Swapping the two nibbles silently produces a segment with
    /// a 44 MiB limit instead of 4 GiB, and the fault only shows up much
    /// later, when the kernel touches an address above it.
    pub fn longCode() Entry {
        return .{
            .limit_low = 0xffff,
            .base_low = 0,
            .base_middle = 0,
            .access = 0x9a, // present, ring 0, code, execute/read
            .limit_high_flags = 0xaf, // limit high 0xf, granularity 4 KiB, long mode
            .base_high = 0,
        };
    }

    /// Build a data segment: present, ring 0, readable, writable.
    pub fn data() Entry {
        return .{
            .limit_low = 0xffff,
            .base_low = 0,
            .base_middle = 0,
            .access = 0x92, // present, ring 0, data, read/write
            .limit_high_flags = 0xcf, // limit high 0xf, granularity 4 KiB, 32 bit default
            .base_high = 0,
        };
    }
};

/// The GDTR pseudo-descriptor: a 16 bit limit and a 64 bit base.
///
/// The layout is **packed** on purpose. The processor reads the limit from
/// the first two bytes and the base from the next eight, with no padding in
/// between. An `extern struct` would align the base to offset 8, and the
/// processor would then load the GDT from address 0.
pub const PseudoDescriptor = packed struct {
    limit: u16,
    base: u64,
};

/// Number of entries in the table.
///
/// The table is larger than the three segments the kernel needs, because it
/// also has to carry a copy of the code segment at the selector the
/// firmware was using. See `init`.
const entry_count = 16;

/// The GDT the kernel builds.
///
///   0x00  null
///   0x08  kernel code (long mode, base 0, limit 4 GiB)
///   0x10  kernel data (base 0, limit 4 GiB)
///   0x18  free, reserved for the TSS
///   ...   a copy of the kernel code segment at the selector the firmware
///         was using, so an IDT installed before the switch stays valid
///         during the transition
var table: [entry_count]Entry align(8) = undefined;

// Static lifetime is required: the CPU may access IST1 on any #DF.
var df_stack: [16384]u8 align(16) = @splat(0);
var task_state: tss.Tss = .{};

var pseudo_descriptor: PseudoDescriptor = .{ .limit = 0, .base = 0 };

/// Install the GDT and switch the processor to it.
///
/// After this call the CS register holds `kernel_code_selector` and the data
/// segment registers hold `kernel_data_selector`.
///
/// The firmware's code selector is preserved as an alias of the kernel code
/// segment. The IDT installed before the switch names that selector, and a
/// fault taken between the two operations would otherwise raise a general
/// protection fault whose handler would raise it again, in a loop.
pub fn init() void {
    const previous_selector = cpu.codeSelector();
    const previous_index = previous_selector >> 3;

    var index: usize = 0;
    while (index < entry_count) : (index += 1) {
        table[index] = Entry.nullDescriptor();
    }
    table[1] = Entry.longCode();
    table[2] = Entry.data();

    const stack_base = @intFromPtr(&df_stack);
    const stack_top = stack_base + df_stack.len;
    if (!tss.validIstStack(stack_base, stack_top)) {
        com1.write("[azura] FATAL: invalid IST stack\n");
        cpu.haltForever();
    }
    task_state.ist1 = stack_top;
    const system_descriptor: [2]Entry = @bitCast(tss.descriptor(@intFromPtr(&task_state)));
    table[3] = system_descriptor[0];
    table[4] = system_descriptor[1];

    if (!tss.firmwareSelectorCompatible(previous_selector)) {
        com1.write("[azura] FATAL: firmware CS conflicts with TSS\n");
        cpu.haltForever();
    }
    if (previous_index != 1 and previous_index != 2) {
        if (previous_index >= entry_count) {
            // The firmware uses a selector the table cannot hold. The
            // transition would be unsafe, so the kernel refuses to continue.
            com1.print("[azura] FATAL: firmware code selector 0x{x} does not fit the GDT\n", .{previous_selector});
            cpu.haltForever();
        }
        table[previous_index] = Entry.longCode();
    }

    pseudo_descriptor = .{
        .limit = @sizeOf(@TypeOf(table)) - 1,
        .base = @intFromPtr(&table),
    };

    // The order matters: the data segments are reloaded first, then CS is
    // reloaded with a far return. A far return is the only way to change CS.
    asm volatile (
        \\ movq %[ptr], %%rax
        \\ lgdtq (%%rax)
        \\ movw %[data], %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%ss
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        \\ pushq %[code]
        \\ leaq 1f(%%rip), %%rax
        \\ pushq %%rax
        \\ lretq
        \\1:
        :
        : [ptr] "r" (&pseudo_descriptor),
          [data] "i" (kernel_data_selector),
          [code] "i" (kernel_code_selector),
        : .{ .rax = true, .memory = true });
}

/// Read the GDTR back, to prove which GDT the processor is using.
///
/// The values are extracted inside the assembly block, for the same reason
/// as in `cpu.readIdt`: a memory operand written by the assembly is not
/// reliably read back by the compiler.
pub fn readPseudoDescriptor() PseudoDescriptor {
    var buffer: [16]u8 align(16) = undefined;
    var limit_value: u32 = undefined;
    var base_value: u32 = undefined;

    asm volatile (
        \\ movq %[ptr], %%rcx
        \\ sgdtq (%%rcx)
        \\ movzwl (%%rcx), %%eax
        \\ movl 2(%%rcx), %%edx
        : [limit] "={eax}" (limit_value),
          [base] "={edx}" (base_value),
        : [ptr] "{rcx}" (&buffer),
        : .{ .memory = true });

    return .{
        .limit = @truncate(limit_value),
        .base = base_value,
    };
}

/// Base address of the GDT.
pub fn baseAddress() u64 {
    return @intFromPtr(&table);
}

/// Limit of the GDT.
pub fn limit() u16 {
    return @sizeOf(@TypeOf(table)) - 1;
}

// --- Unit tests -------------------------------------------------------------

const testing = std.testing;

test "the null descriptor is all zeroes" {
    const entry = Entry.nullDescriptor();
    try testing.expectEqual(@as(u16, 0), entry.limit_low);
    try testing.expectEqual(@as(u8, 0), entry.access);
    try testing.expectEqual(@as(u8, 0), entry.limit_high_flags);
    const zeros: [8]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &zeros, std.mem.asBytes(&entry));
}

test "the code segment is a present long mode ring 0 segment" {
    const entry = Entry.longCode();
    // Present (0x80), code/data (0x10), execute/read (0x0a).
    try testing.expectEqual(@as(u8, 0x9a), entry.access);
    // Low nibble: bits 16 to 19 of the limit, so the limit is 0xfffff.
    try testing.expectEqual(@as(u8, 0x0f), entry.limit_high_flags & 0x0f);
    // High nibble: granularity 4 KiB (0x8) and long mode (0x2).
    try testing.expectEqual(@as(u8, 0x0a), entry.limit_high_flags >> 4);
    // Base 0 and a 4 GiB limit.
    try testing.expectEqual(@as(u16, 0), entry.base_low);
    try testing.expectEqual(@as(u8, 0), entry.base_middle);
    try testing.expectEqual(@as(u8, 0), entry.base_high);
    try testing.expectEqual(@as(u16, 0xffff), entry.limit_low);
}

test "the data segment is a present ring 0 read write segment" {
    const entry = Entry.data();
    // Present (0x80), code/data (0x10), read/write (0x02).
    try testing.expectEqual(@as(u8, 0x92), entry.access);
    // Low nibble: bits 16 to 19 of the limit, so the limit is 0xfffff.
    try testing.expectEqual(@as(u8, 0x0f), entry.limit_high_flags & 0x0f);
    // High nibble: granularity 4 KiB (0x8) and 32 bit default (0x4).
    try testing.expectEqual(@as(u8, 0x0c), entry.limit_high_flags >> 4);
    try testing.expectEqual(@as(u16, 0), entry.base_low);
    try testing.expectEqual(@as(u16, 0xffff), entry.limit_low);
}

test "the segment limit covers the whole 32 bit address space" {
    // The limit is the low 16 bits plus the high nibble, scaled by the
    // granularity. A wrong nibble order silently shrinks it and the kernel
    // faults much later, when it touches an address above the limit.
    const code = Entry.longCode();
    const code_limit: u32 = @as(u32, code.limit_low) | (@as(u32, code.limit_high_flags & 0x0f) << 16);
    try testing.expectEqual(@as(u32, 0xfffff), code_limit);
    const data = Entry.data();
    const data_limit: u32 = @as(u32, data.limit_low) | (@as(u32, data.limit_high_flags & 0x0f) << 16);
    try testing.expectEqual(@as(u32, 0xfffff), data_limit);
}

test "the selectors are the conventional ones" {
    try testing.expectEqual(@as(u16, 0x08), kernel_code_selector);
    try testing.expectEqual(@as(u16, 0x10), kernel_data_selector);
    // The selectors must be the low three bits of the index times eight.
    try testing.expectEqual(@as(u16, 0), kernel_code_selector & 0x7);
    try testing.expectEqual(@as(u16, 0), kernel_data_selector & 0x7);
    try testing.expectEqual(@as(u16, 1), kernel_code_selector >> 3);
    try testing.expectEqual(@as(u16, 2), kernel_data_selector >> 3);
}

test "the pseudo descriptor has the layout the processor expects" {
    // The processor reads the limit from the first two bytes and the base
    // address from the next eight, with no padding in between. An aligned
    // struct would put the base at offset 8 and the processor would load
    // the GDT from address 0.
    try testing.expectEqual(@as(usize, 0), @offsetOf(PseudoDescriptor, "limit"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(PseudoDescriptor, "base"));
    // The structure is rounded up to its alignment, so it is larger than the
    // 10 bytes the processor reads. That is harmless.
    try testing.expect(@sizeOf(PseudoDescriptor) >= 10);
}
