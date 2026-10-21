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

/// Load the task register with a TSS selector.
///
/// The selector must name a present TSS descriptor in the GDT that is
/// currently loaded; otherwise the instruction raises #GP. See `tss.zig`.
pub fn loadTaskRegister(selector: u16) void {
    asm volatile ("ltrw %[selector]"
        :
        : [selector] "r" (selector),
        : .{ .memory = true });
}

/// Read the task register back.
///
/// A value different from the selector the kernel loaded means the processor
/// is using another TSS (or none), and the IST stacks in the IDT would point
/// into memory the kernel does not control.
pub fn taskRegister() u16 {
    return asm volatile ("strw %[value]"
        : [value] "=r" (-> u16),
    );
}

/// Disable hardware interrupts.
pub fn disableInterrupts() void {
    asm volatile ("cli");
}

/// Read the current page table base (CR3).
///
/// The kernel does not own the page tables yet: the value belongs to the
/// firmware. It is read back and logged so the transition can be verified
/// instead of assumed.
pub fn readCr3() u64 {
    return asm volatile ("movq %%cr3, %[value]"
        : [value] "=r" (-> u64),
    );
}

/// Write a new page table base (CR3).
///
/// The caller must have built a complete, valid page table tree before
/// calling this: the instruction does not validate the tree and a bad
/// value raises #GP or faults on the next memory access.
pub fn writeCr3(value: u64) void {
    asm volatile ("movq %[value], %%cr3"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

/// Read EFER (for diagnostics).
pub fn readEfer() u64 {
    return readMsr(0xc0000080);
}

/// Enable the no-execute page protection bit in EFER.
///
/// NX is only meaningful when this bit is set. Writing page table entries
/// with the NX bit before enabling it raises #GP when the entry is used.
pub fn enableNx() void {
    // EFER is MSR 0xC0000080. Bit 11 is NXE.
    const efer: u64 = readMsr(0xc0000080);
    writeMsr(0xc0000080, efer | (1 << 11));
}

fn readMsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | low;
}

fn writeMsr(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}

/// Read the faulting virtual address (CR2).
pub fn readCr2() u64 {
    return asm volatile ("movq %%cr2, %[value]"
        : [value] "=r" (-> u64),
    );
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

/// Load a segment selector that names no descriptor in the current GDT.
///
/// The index of the selector is far beyond the limit of the table the
/// kernel installs, so the processor raises a general protection exception
/// and reports the selector as the error code (Intel SDM Vol. 3A, 6.14.5).
///
/// The instruction never returns: the exception is raised by the load
/// itself.
pub fn loadInvalidSegmentSelector() void {
    asm volatile (
        \\ movl $0xa0, %%eax
        \\ movw %%ax, %%es
        ::: .{ .memory = true, .rax = true });
}
