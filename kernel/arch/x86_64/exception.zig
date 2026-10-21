//! The exception model of the kernel: how a CPU exception is classified and
//! how the stack frame the processor pushed is read back.
//!
//! This module is pure logic. It has no inline assembly and no dependency
//! on the machine, so it is verified by the host unit tests; the part of
//! the exception path that touches the processor lives in `idt.zig` and is
//! verified by the QEMU boot and fault tests.

const std = @import("std");

/// The CPU-pushed exception frame in 64-bit mode, as the raw 8 byte words
/// the processor wrote on the stack.
///
/// Intel SDM Vol. 3A, 6.14.5 and 7.14.2:
///   * SS and RSP are pushed unconditionally in 64-bit mode, even when the
///     privilege level does not change;
///   * the pushes happen in the order SS, RSP, RFLAGS, CS and RIP, and every
///     push moves the stack pointer DOWN by 8 bytes, so RIP ends up at the
///     LOWEST address of the frame;
///   * the error code, when the vector pushes one, is pushed AFTER the RIP
///     value, so it lands at the lowest address of the frame, BELOW RIP.
///
/// The frame therefore has two shapes, and only the vector says which one
/// to expect:
///
///   without an error code:  [RIP] [CS] [RFLAGS] [RSP] [SS]
///   with an error code:     [error code] [RIP] [CS] [RFLAGS] [RSP] [SS]
///
/// The fields are named by position and not by meaning, because the meaning
/// of a word depends on the shape. `decodeFrame` turns the raw words into
/// the values they represent.
///
/// The frame is always 8 byte aligned: the processor aligns the stack
/// pointer to a 16 byte boundary before pushing the frame, and every word
/// of the frame is 8 bytes wide.
pub const Frame = extern struct {
    word0: u64,
    word1: u64,
    word2: u64,
    word3: u64,
    word4: u64,
    word5: u64,
};

/// The CPU context at the moment of the fault, decoded from the frame.
pub const Context = struct {
    /// The address of the instruction that caused the fault.
    rip: u64,
    /// The code segment the faulting instruction was running in.
    cs: u64,
    /// The flags at the moment of the fault.
    rflags: u64,
    /// The error code the CPU pushed, when the vector pushes one.
    error_code: ?u64,
};

/// Decode the frame the stub passed to the handler.
///
/// `frame` points at the lowest address of the frame the CPU pushed. The
/// offsets depend on whether the vector pushes an error code, so the vector
/// is needed to read it; see `hasErrorCode`.
pub fn decodeFrame(vector: u8, frame: *const Frame) Context {
    if (hasErrorCode(vector)) {
        return .{
            .rip = frame.word1,
            .cs = frame.word2,
            .rflags = frame.word3,
            .error_code = frame.word0,
        };
    }
    return .{
        .rip = frame.word0,
        .cs = frame.word1,
        .rflags = frame.word2,
        .error_code = null,
    };
}

/// Vectors that push an error code in 64-bit mode.
///
/// Intel SDM Vol. 3A, 7.3.1, Table 7-1 ("Error Code" column) and the
/// per-vector sections of chapter 7:
///
///    8  #DF  double fault          (always 0)
///   10  #TS  invalid TSS           (segment selector)
///   11  #NP  segment not present   (segment selector)
///   12  #SS  stack-segment fault   (segment selector)
///   13  #GP  general protection    (segment selector, vector number or 0)
///   14  #PF  page fault            (page fault error code)
///   17  #AC  alignment check       (always 0)
///   21  #CP  control protection    (error code)
///   29  #VC  VMM communication     (error code)
///   30  #SX  security exception    (error code)
///
/// Vector 13 IS in the list: in 64-bit mode a #GP always pushes an error
/// code. The rule that says the error code is pushed only when the fault
/// was caused by an instruction fetch is a legacy mode rule and does not
/// apply here. Vector 9 is not in the list because it is reserved in
/// 64-bit mode.
pub fn hasErrorCode(vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

/// Human readable name of a CPU exception vector.
pub fn vectorName(vector: u8) []const u8 {
    return switch (vector) {
        0 => "divide error",
        1 => "debug",
        2 => "non-maskable interrupt",
        3 => "breakpoint",
        4 => "overflow",
        5 => "bound range exceeded",
        6 => "invalid opcode",
        7 => "device not available",
        8 => "double fault",
        9 => "coprocessor segment overrun",
        10 => "invalid TSS",
        11 => "segment not present",
        12 => "stack-segment fault",
        13 => "general protection fault",
        14 => "page fault",
        15 => "reserved",
        16 => "x87 floating point exception",
        17 => "alignment check",
        18 => "machine check",
        19 => "SIMD floating point exception",
        20 => "virtualization exception",
        21 => "control protection exception",
        28 => "hypervisor injection",
        29 => "VMM communication exception",
        30 => "security exception",
        else => "unknown",
    };
}

// --- Unit tests -------------------------------------------------------------

const testing = std.testing;

test "vector names are defined for the classic exceptions" {
    try testing.expectEqualStrings("page fault", vectorName(14));
    try testing.expectEqualStrings("general protection fault", vectorName(13));
    try testing.expectEqualStrings("invalid opcode", vectorName(6));
    try testing.expectEqualStrings("unknown", vectorName(200));
}

test "error code presence matches the Intel manual" {
    try testing.expect(hasErrorCode(14)); // #PF
    try testing.expect(hasErrorCode(8)); // #DF
    try testing.expect(hasErrorCode(13)); // #GP: 64-bit mode always pushes one
    try testing.expect(hasErrorCode(17)); // #AC
    try testing.expect(!hasErrorCode(6)); // #UD
    try testing.expect(!hasErrorCode(0)); // #DE
    try testing.expect(!hasErrorCode(9)); // reserved in 64-bit mode
    try testing.expect(!hasErrorCode(16)); // #MF
}

test "the vectors with an error code are exactly the 64-bit mode ones" {
    const expected = [_]u8{ 8, 10, 11, 12, 13, 14, 17, 21, 29, 30 };
    for (0..32) |vector| {
        const value: u8 = @intCast(vector);
        const wanted = std.mem.indexOfScalar(u8, &expected, value) != null;
        try testing.expectEqual(wanted, hasErrorCode(value));
    }
}

test "decodes a frame that carries no error code" {
    // The CPU pushes SS, RSP, RFLAGS, CS and RIP, in that order, so RIP
    // ends up at the lowest address of the frame.
    var frame: Frame = undefined;
    frame.word0 = 0xdead_beef_0000_1000; // RIP
    frame.word1 = 0x08; // CS
    frame.word2 = 0x246; // RFLAGS
    frame.word3 = 0x0000_7fff_0000_0000; // RSP
    frame.word4 = 0x10; // SS
    frame.word5 = 0;

    const context = decodeFrame(6, &frame);
    try testing.expectEqual(@as(u64, 0xdead_beef_0000_1000), context.rip);
    try testing.expectEqual(@as(u64, 0x08), context.cs);
    try testing.expectEqual(@as(u64, 0x246), context.rflags);
    try testing.expectEqual(@as(?u64, null), context.error_code);
}

test "decodes a frame that carries an error code" {
    // The error code is pushed after the RIP value, so it lands at the
    // lowest address of the frame and shifts every other field by one word.
    var frame: Frame = undefined;
    frame.word0 = 0x0d; // error code
    frame.word1 = 0xdead_beef_0000_2000; // RIP
    frame.word2 = 0x08; // CS
    frame.word3 = 0x246; // RFLAGS
    frame.word4 = 0x0000_7fff_0000_0000; // RSP
    frame.word5 = 0x10; // SS

    const context = decodeFrame(13, &frame);
    try testing.expectEqual(@as(u64, 0xdead_beef_0000_2000), context.rip);
    try testing.expectEqual(@as(u64, 0x08), context.cs);
    try testing.expectEqual(@as(u64, 0x246), context.rflags);
    try testing.expectEqual(@as(?u64, 0x0d), context.error_code);
}

test "the same raw words decode differently depending on the vector" {
    // This is the defect the frame model exists to prevent: reading the
    // frame with a fixed layout misreads every field of the vectors that
    // push an error code, and misreads the error code itself.
    var frame: Frame = undefined;
    frame.word0 = 0x1111_2222_3333_4444;
    frame.word1 = 0x5555_6666_7777_8888;
    frame.word2 = 0x9999_aaaa_bbbb_cccc;
    frame.word3 = 0xdddd_eeee_ffff_0000;
    frame.word4 = 0;
    frame.word5 = 0;

    const without = decodeFrame(6, &frame);
    const with = decodeFrame(14, &frame);

    try testing.expectEqual(frame.word0, without.rip);
    try testing.expectEqual(frame.word1, without.cs);
    try testing.expectEqual(frame.word2, without.rflags);
    try testing.expectEqual(@as(?u64, null), without.error_code);

    try testing.expectEqual(frame.word1, with.rip);
    try testing.expectEqual(frame.word2, with.cs);
    try testing.expectEqual(frame.word3, with.rflags);
    try testing.expectEqual(@as(?u64, frame.word0), with.error_code);
}

/// True when an entire CPU-pushed exception frame lies within a stack.
/// Uses subtraction after ordering checks to avoid integer overflow.
pub fn frameFitsStack(frame_address: u64, stack_base: u64, stack_top: u64, frame_bytes: u64) bool {
    return stack_base < stack_top and frame_bytes != 0 and
        frame_address >= stack_base and frame_address < stack_top and
        stack_top - frame_address >= frame_bytes;
}

test "exception frame must fit completely within IST stack" {
    const testing = std.testing;
    const base: u64 = 0x1000;
    const top: u64 = 0x5000;
    try testing.expect(frameFitsStack(top - 48, base, top, 48));
    try testing.expect(frameFitsStack(base, base, top, 48));
    try testing.expect(!frameFitsStack(top - 47, base, top, 48));
    try testing.expect(!frameFitsStack(base - 1, base, top, 48));
    try testing.expect(!frameFitsStack(top, base, top, 48));
    try testing.expect(!frameFitsStack(base, top, base, 48));
    try testing.expect(!frameFitsStack(base, base, top, 0));
    try testing.expect(!frameFitsStack(0xffff_ffff_ffff_fff0, base, top, 48));

    // A frame exactly filling the stack is valid; one byte larger is not.
    try testing.expect(frameFitsStack(base, base, top, top - base));
    try testing.expect(!frameFitsStack(base, base, top, top - base + 1));

    // Degenerate and reversed ranges must be rejected, even for a small frame.
    try testing.expect(!frameFitsStack(base, base, base, 1));
    try testing.expect(!frameFitsStack(base, top, base, 1));

    // High-half canonical kernel addresses must not overflow the bounds check.
    const high_base: u64 = 0xffff_ffff_ffff_c000;
    const high_top: u64 = 0xffff_ffff_ffff_f000;
    try testing.expect(frameFitsStack(high_top - 48, high_base, high_top, 48));
    try testing.expect(!frameFitsStack(high_top - 47, high_base, high_top, 48));
    try testing.expect(!frameFitsStack(0xffff_ffff_ffff_fff0, high_base, high_top, 48));
}
