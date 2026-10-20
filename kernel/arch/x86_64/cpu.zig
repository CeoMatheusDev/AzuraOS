//! Low level x86_64 primitives used by the kernel.
//!
//! Everything here is architecture specific and assumes the CPU is already in
//! 64-bit long mode, which is guaranteed for the M1 boot chain because the
//! UEFI bootloader hands over a long mode environment.

const std = @import("std");

/// The 10-byte pseudo-descriptor format used by LIDT/LGDT in 64-bit mode.
///
/// Layout (Intel SDM Vol. 3, Table 9-1 adapted for 64-bit mode):
///   offset 0-1  : limit (16 bits)
///   offset 2-5  : base (32 bits; the upper 32 bits are ignored)
///   offset 6-7  : reserved
///   offset 8-9  : reserved (upper base bits, ignored in 64-bit mode)
///   offset 10+  : padding, so the CPU's 10 byte read never touches
///                 unrelated memory
pub const Descriptor = packed struct {
    limit: u16,
    base: u32,
    reserved: u32,
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
};

comptime {
    if (@sizeOf(Descriptor) < 10) @compileError("Descriptor must cover the 10 byte CPU read");
}

/// Load the Interrupt Descriptor Table register.
pub fn loadIdt(descriptor: *const Descriptor) void {
    // `lidtq` is required: the operand size suffix makes the assembler emit
    // the 64-bit form, and the descriptor address is taken from the register.
    asm volatile ("movq %[ptr], %%rax\n\tlidtq (%%rax)"
        :
        : [ptr] "r" (descriptor),
        : .{ .memory = true, .rax = true });
}

/// Read the Interrupt Descriptor Table register back.
///
/// The values are extracted inside the assembly block and returned through
/// output operands. Writing them into a memory operand and reading that
/// memory from Zig is not reliable: the compiler may keep a separate copy
/// of the buffer and hand the caller the copy instead of what the CPU wrote.
pub fn readIdt() Descriptor {
    var buffer: [16]u8 align(16) = undefined;
    var limit: u32 = undefined;
    var base: u32 = undefined;

    asm volatile (
        \\ movq %[ptr], %%rcx
        \\ sidtq (%%rcx)
        \\ movzwl (%%rcx), %%eax
        \\ movl 2(%%rcx), %%edx
        : [limit] "={eax}" (limit),
          [base] "={edx}" (base),
        : [ptr] "{rcx}" (&buffer),
        : .{ .memory = true });

    return .{
        .limit = @truncate(limit),
        .base = base,
        .reserved = 0,
        ._pad0 = 0,
        ._pad1 = 0,
        ._pad2 = 0,
    };
}

/// Read the current code segment selector.
///
/// Using the live selector instead of a hardcoded 0x08 keeps the kernel
/// independent of the GDT layout chosen by the firmware. The M1 kernel still
/// runs on the firmware's GDT; installing our own GDT is M2 work.
pub fn codeSelector() u16 {
    return asm volatile ("movw %%cs, %%ax"
        : [ax] "={ax}" (-> u16),
    );
}

/// Disable hardware interrupts.
pub fn disableInterrupts() void {
    asm volatile ("cli");
}

/// Halt the CPU until the next interrupt.
pub fn halt() void {
    asm volatile ("hlt");
}

/// Stop the machine in a controlled way.
///
/// Interrupts stay disabled and the CPU idles in the halt state. The
/// firmware watchdog is not armed, so the machine stays in this state until
/// the test harness terminates QEMU.
pub fn haltForever() noreturn {
    disableInterrupts();
    while (true) {
        halt();
    }
}

/// Emit a CPU "no operation" (used as a low level yield point).
pub fn pause() void {
    asm volatile ("pause");
}
