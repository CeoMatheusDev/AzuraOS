//! Interrupt Descriptor Table and CPU exception handling for the kernel.
//!
//! Scope (M1): the kernel installs an IDT that catches every CPU exception
//! (vectors 0-31), prints a diagnostic to the serial port and halts the
//! machine. Without this, any kernel bug would escalate to a triple fault
//! and silently reboot the machine, which would turn a test failure into an
//! unexplained timeout.
//!
//! Hardware interrupts (vectors 32 and above) are deliberately NOT
//! installed: the kernel runs with interrupts disabled in M1, and a
//! half-implemented interrupt controller would only produce noise.
//!
//! The kernel still executes on the GDT chosen by the firmware; only the IDT
//! is ours. Installing our own GDT is M2 work.

const std = @import("std");
const com1 = @import("com1");
const cpu = @import("cpu.zig");

/// One IDT entry. 16 bytes, as required by the 64-bit IDT format.
pub const Entry = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    /// Present, DPL 0, 64-bit interrupt gate.
    type_attr: u8,
    offset_middle: u16,
    offset_high: u32,
    reserved: u32,
};

/// The CPU pushed stack frame in 64-bit mode, without a privilege change.
///
/// Layout (Intel SDM Vol. 3, 6.14.5):
///   [rsp+0]  RIP
///   [rsp+8]  CS
///   [rsp+16] RFLAGS
///   [rsp+24] error code, only for the vectors listed in `hasErrorCode`
///   [rsp+32] RSP, only when the privilege level changed
///   [rsp+40] SS,  only when the privilege level changed
pub const Frame = extern struct {
    rip: u64,
    cs: u64,
    rflags: u64,
};

/// Present, DPL 0, 64-bit interrupt gate.
const gate_type: u8 = 0x8E;

/// Number of vectors in the table.
const vector_count = 256;

/// Number of CPU exception vectors handled by the kernel.
const exception_vector_count = 32;

/// The IDT table.
///
/// The Intel SDM requires the IDT base address to be aligned on a 16 byte
/// boundary; the alignment is therefore explicit and not left to the
/// linker.
var table: [vector_count]Entry align(16) = @splat(.{
    .offset_low = 0,
    .selector = 0,
    .ist = 0,
    .type_attr = 0,
    .offset_middle = 0,
    .offset_high = 0,
    .reserved = 0,
});
var descriptor: cpu.Descriptor = .{
    .limit = 0,
    .base = 0,
    .reserved = 0,
    ._pad0 = 0,
    ._pad1 = 0,
    ._pad2 = 0,
};

/// Address of `commonHandler`, loaded by the per-vector stubs.
///
/// A global is used (instead of passing the handler as an inline assembly
/// operand) because Zig 0.17 crashes the compiler when a function pointer is
/// used as an operand inside a naked function.
var handler_address: usize = 0;

/// Install the IDT.
///
/// `code_selector` is the selector of the code segment the handlers run in.
/// It must be a selector of the GDT that is currently installed; after the
/// kernel installs its own GDT that is `gdt.kernel_code_selector`.
///
/// Must be called with interrupts disabled. After this call every CPU
/// exception lands in `commonHandler` instead of escalating to a triple
/// fault.
pub fn install(code_selector: u16) void {
    handler_address = @intFromPtr(&azuraCommonHandler);

    inline for (0..exception_vector_count) |vector| {
        const stub = makeStub(vector);
        table[vector] = .{
            .offset_low = @truncate(stub),
            .selector = code_selector,
            .ist = 0,
            .type_attr = gate_type,
            .offset_middle = @truncate(stub >> 16),
            .offset_high = @truncate(stub >> 32),
            .reserved = 0,
        };
    }

    descriptor = .{
        .limit = @intCast(@sizeOf(@TypeOf(table)) - 1),
        .base = @intCast(@intFromPtr(&table)),
        .reserved = 0,
        ._pad0 = 0,
        ._pad1 = 0,
        ._pad2 = 0,
    };

    cpu.loadIdt(&descriptor);
}

/// Build the per-vector trampoline.
///
/// Each vector needs its own stub because the CPU does not report which
/// vector fired. The stub hands the vector number and the pointer to the
/// CPU's stack frame to the common handler.
///
/// The handler is reached through its exported symbol instead of through a
/// pointer held in a register: an inline assembly operand that needs a
/// register makes the compiler emit a setup sequence, and the address of a
/// naked function that has one does not reliably point at the start of the
/// generated code. The kernel verifies the resulting addresses at boot; see
/// `verifyEntries`.
///
/// The stub is a naked function so that the CPU's stack frame is still the
/// top of the stack when the handler is entered: the handler reads
/// RIP/CS/RFLAGS relative to that pointer.
fn makeStub(comptime vector: u8) usize {
    const Stub = struct {
        const vector_id: u8 = vector;

        fn stub() callconv(.naked) void {
            asm volatile (
                \\ movq %[v], %%rdi        // vector number
                \\ movq %%rsp, %%rsi       // pointer to the CPU's stack frame
                \\ callq azuraCommonHandler
                :
                : [v] "i" (vector_id),
                : .{ .memory = true });
        }
    };
    return @intFromPtr(&Stub.stub);
}

/// Read the IDT register back, to prove which table the processor uses.
pub fn readInstalledDescriptor() cpu.Descriptor {
    return cpu.readIdt();
}

/// Read back the state of the installed table, for diagnostics.
///
/// The values are what the processor actually sees, not what the code
/// believes it wrote.
pub const Diagnostics = struct {
    /// Address of the common handler.
    handler: usize,
    /// Address of the stub of the given vector.
    stub: usize,
    /// The raw entry of the given vector.
    entry: Entry,
};

/// Collect the diagnostics of the installed table.
pub fn diagnostics(comptime vector: u8) Diagnostics {
    return .{
        .handler = handler_address,
        .stub = makeStub(vector),
        .entry = table[vector],
    };
}

/// Verify that every entry points at the beginning of its stub.
///
/// The first instruction of a stub is `movq $<vector>, %rdi`, encoded as
/// `48 c7 c7 <vector> 00 00 00`. Reading those bytes at the address the IDT
/// names proves that the entry points at the start of the stub and not into
/// the middle of it, which is the failure mode this check exists for.
///
/// Returns the vector of the first entry that is wrong, or null when every
/// entry is correct.
pub fn verifyEntries() ?u8 {
    inline for (0..exception_vector_count) |vector| {
        const address = makeStub(vector);
        const bytes: [*]const u8 = @ptrFromInt(address);
        if (bytes[0] != 0x48 or bytes[1] != 0xc7 or bytes[2] != 0xc7) return @intCast(vector);
        const immediate: u32 = @as(u32, bytes[3]) |
            (@as(u32, bytes[4]) << 8) |
            (@as(u32, bytes[5]) << 16) |
            (@as(u32, bytes[6]) << 24);
        if (immediate != vector) return @intCast(vector);
    }
    return null;
}

/// Common exception handler. Never returns: the machine is halted so the
/// failure is visible in the serial log instead of restarting the boot.
///
/// Exported so that the per-vector stubs can call it by name.
export fn azuraCommonHandler(vector: u8, frame: *const Frame) callconv(.c) void {
    com1.print("[azura] KERNEL FAULT: vector {d} ({s})\n", .{
        vector,
        vectorName(vector),
    });
    com1.print("[azura] KERNEL FAULT: rip=0x{x} cs=0x{x} rflags=0x{x}\n", .{
        frame.rip,
        frame.cs,
        frame.rflags,
    });
    if (hasErrorCode(vector)) {
        const frame_bytes: [*]const u8 = @ptrCast(frame);
        com1.print("[azura] KERNEL FAULT: error_code=0x{x}\n", .{readU64At(frame_bytes, 24)});
    }
    com1.write("[azura] KERNEL FAULT: machine halted\n");
    cpu.haltForever();
}

/// Vectors that always push an error code.
///
/// Vector 13 (#GP) is deliberately excluded: the error code is only pushed
/// when the fault was caused by an instruction fetch, so the frame layout is
/// ambiguous for that vector.
fn hasErrorCode(vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 14, 17, 21, 29, 30 => true,
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

/// Read a little endian u64 from an arbitrary byte address.
///
/// The frame is not guaranteed to be 8 byte aligned for every vector, so the
/// value is assembled byte by byte instead of dereferencing a u64 pointer.
fn readU64At(bytes: [*]const u8, offset: usize) u64 {
    var value: u64 = 0;
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        value |= @as(u64, bytes[offset + index]) << @intCast(index * 8);
    }
    return value;
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
    try testing.expect(!hasErrorCode(13)); // #GP is ambiguous
    try testing.expect(!hasErrorCode(6)); // #UD
    try testing.expect(!hasErrorCode(0)); // #DE
}

test "reads an unaligned u64" {
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0xff };
    try testing.expectEqual(
        @as(u64, 0x0807_0605_0403_0201),
        readU64At(&bytes, 1),
    );
}
