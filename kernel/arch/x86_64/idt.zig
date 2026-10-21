//! Interrupt Descriptor Table and CPU exception handling for the kernel.
//!
//! Scope (M1): the kernel installs an IDT that catches every CPU exception
//! (vectors 0-31), prints a diagnostic to the serial port and halts the
//! machine. Without this, any kernel bug would escalate to a triple fault
//! and silently reboot the machine, which would turn a test failure into
//! an unexplained timeout.
//!
//! Hardware interrupts (vectors 32 and above) are deliberately NOT
//! installed: the kernel runs with interrupts disabled in M1, and a
//! half-implemented interrupt controller would only produce noise.
//!
//! The kernel installs the IDT twice: once with the selector that is
//! active when the kernel starts, so that a fault during the GDT switch is
//! still reported, and once with the kernel's own code selector after the
//! switch. See `install`.
//!
//! The frame layout and the classification of the vectors are in
//! `exception.zig`, which holds no inline assembly and is verified by the
//! host unit tests. The part of this module that touches the processor is
//! verified by the QEMU boot and fault tests.

const com1 = @import("com1");
const cpu = @import("cpu.zig");
const exception = @import("exception.zig");
const tss = @import("tss.zig");
const gdt = @import("gdt.zig");

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

/// The CPU-pushed exception frame. See `exception.zig`.
pub const Frame = exception.Frame;

/// The decoded context of a fault. See `exception.zig`.
pub const Context = exception.Context;

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
pub fn install(code_selector: u16, task_register_ready: bool) void {
    handler_address = @intFromPtr(&azuraCommonHandler);

    inline for (0..exception_vector_count) |vector| {
        const stub = makeStub(vector);
        table[vector] = .{
            .offset_low = @truncate(stub),
            .selector = code_selector,
            .ist = if (vector == 8 and task_register_ready) tss.double_fault_ist else 0,
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

/// Verify the double-fault gate uses the intended IST only after LTR.
/// The remaining exception vectors must continue using the current stack.
pub fn verifyIstConfiguration(task_register_ready: bool, code_selector: u16) bool {
    for (table[0..exception_vector_count], 0..) |entry, vector| {
        const expected_ist: u8 = if (vector == 8 and task_register_ready)
            tss.double_fault_ist
        else
            0;
        if (entry.ist != expected_ist or entry.selector != code_selector or
            entry.type_attr != gate_type or entry.reserved != 0)
            return false;
    }
    return true;
}

/// Return the saved stack pointer from the CPU's #DF exception frame.
/// This is read-only diagnostics; it does not intentionally provoke a #DF.
pub fn doubleFaultStackPointer(frame: *const Frame) u64 {
    // #DF pushes an error code, followed by RIP, CS, RFLAGS, old RSP, SS.
    return frame.word4;
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
///
/// The stub also fixes up the two conditions the System V ABI imposes on
/// the callee, which the processor does not guarantee on an exception
/// entry:
///
///   * the stack alignment. Immediately before the `call`, `RSP` must be a
///     multiple of 16; at the first instruction of the callee, after the
///     return address has been pushed, `RSP % 16` must be 8. The processor
///     aligns the stack pointer to a 16 byte boundary BEFORE pushing the
///     frame (Intel SDM Vol. 3A, 7.14.2), and the frame is 40 bytes long
///     for the vectors that push no error code and 48 bytes long for the
///     vectors that push one. The parity of the frame base therefore
///     depends on the vector, and without the fix the handler would be
///     entered with a misaligned stack pointer for one of the two classes.
///     Any `movaps` to a 16 byte aligned object inside the handler would
///     then fault with #GP and hide the original fault;
///   * the direction flag must be clear. The processor does not touch it on
///     an exception entry, and a faulting instruction may well have set it.
///
/// The stub clobbers RDI, RSI, RSP and the flags, and the clobber list below
/// names them so that the contract is machine checked rather than only
/// described. Nothing has to be preserved, because the stub never returns:
/// the handler halts the machine, and the context that was interrupted is
/// never resumed. The ABI's caller saved rules are therefore not the reason
/// the list is short — the reason is that there is no caller to return to. A
/// build step that did try to resume the interrupted context would have to
/// save and restore the whole register state first, and this stub would not
/// be enough.
fn makeStub(comptime vector: u8) usize {
    const Stub = struct {
        const vector_id: u8 = vector;

        fn stub() callconv(.naked) void {
            asm volatile (
                \\ movq %[v], %%rdi        // vector number
                \\ movq %%rsp, %%rsi       // pointer to the CPU's stack frame
                \\ andq $-16, %%rsp        // RSP % 16 == 0 immediately before the call
                \\ cld                    // the ABI demands a clear direction flag
                \\ callq azuraCommonHandler
                :
                : [v] "i" (vector_id),
                : .{ .memory = true, .cc = true, .rdi = true, .rsi = true, .rsp = true });
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

/// The instruction that loads the vector number into the first argument
/// register: `movq $<vector>, %rdi`, encoded as `48 c7 c7 <vector>`.
const stub_vector_opcode = [_]u8{ 0x48, 0xc7, 0xc7 };

/// The instructions that follow the vector immediate in every stub.
///
///   `48 89 e6`      `movq %rsp, %rsi`
///   `48 83 e4 f0`   `andq $-16, %rsp`
///   `fc`            `cld`
const stub_fixup = [_]u8{ 0x48, 0x89, 0xe6, 0x48, 0x83, 0xe4, 0xf0, 0xfc };

/// Verify that every installed IDT entry points at the beginning of its stub.
///
/// Reading the bytes the stub must start with, at the address the IDT
/// names, proves that the entry points at the start of the stub and not
/// into the middle of it, which is the failure mode this check exists for.
///
/// The check also covers the stack alignment fixup, so a stub that lost it
/// would be reported at boot instead of corrupting the handler's stack
/// alignment.
///
/// This check runs in the kernel and not in the host unit tests: Zig 0.17
/// refuses to compile an inline assembly label reference in a test build,
/// so the stub cannot be instantiated on the host.
///
/// Returns the vector of the first entry that is wrong, or null when every
/// entry is correct.
pub fn verifyEntries() ?u8 {
    inline for (0..exception_vector_count) |vector| {
        const address = makeStub(vector);
        const entry = table[vector];
        // Verify the address actually installed in the IDT, not just the
        // contents at the expected stub address.
        const installed_address: u64 = @as(u64, entry.offset_low) |
            (@as(u64, entry.offset_middle) << 16) |
            (@as(u64, entry.offset_high) << 32);
        if (installed_address != @as(u64, @intCast(address))) return @intCast(vector);
        const bytes: [*]const u8 = @ptrFromInt(address);

        for (stub_vector_opcode, 0..) |expected, index| {
            if (bytes[index] != expected) return @intCast(vector);
        }
        const immediate: u32 = @as(u32, bytes[3]) |
            (@as(u32, bytes[4]) << 8) |
            (@as(u32, bytes[5]) << 16) |
            (@as(u32, bytes[6]) << 24);
        if (immediate != vector) return @intCast(vector);

        for (stub_fixup, 0..) |expected, index| {
            if (bytes[7 + index] != expected) return @intCast(vector);
        }
    }
    return null;
}

/// Common exception handler. Never returns: the machine is halted so the
/// failure is visible in the serial log instead of restarting the boot.
///
/// Exported so that the per-vector stubs can call it by name.
///
/// Called with the System V C ABI, so the stub must have left the stack
/// pointer 16 byte aligned and the direction flag clear. See `makeStub`.
export fn azuraCommonHandler(vector: u8, frame: *const Frame) callconv(.c) void {
    // Validate the #DF frame on IST1 before dereferencing it.
    if (vector == 8) {
        const bounds = gdt.doubleFaultStackBounds();
        const frame_address = @intFromPtr(frame);
        // #DF pushes six 8-byte words; validate the entire CPU frame, not
        // merely its first byte, without risking an overflowing addition.
        const frame_size: u64 = 6 * @sizeOf(u64);
        const on_ist1 = exception.frameFitsStack(
            frame_address,
            bounds.base,
            bounds.top,
            frame_size,
        );
        com1.print("[azura] DOUBLE FAULT: frame=0x{x} IST1=[0x{x},0x{x}) active={s}\n", .{
            frame_address, bounds.base, bounds.top, if (on_ist1) "yes" else "no",
        });
        if (!on_ist1) {
            com1.write("[azura] KERNEL FAULT: invalid double-fault frame; machine halted\n");
            cpu.haltForever();
        }
    }

    const context = exception.decodeFrame(vector, frame);
    com1.print("[azura] KERNEL FAULT: vector {d} ({s})\n", .{
        vector,
        exception.vectorName(vector),
    });
    com1.print("[azura] KERNEL FAULT: rip=0x{x} cs=0x{x} rflags=0x{x}\n", .{
        context.rip,
        context.cs,
        context.rflags,
    });
    if (context.error_code) |error_code| {
        com1.print("[azura] KERNEL FAULT: error_code=0x{x}\n", .{error_code});
    }
    com1.write("[azura] KERNEL FAULT: machine halted\n");
    cpu.haltForever();
}
