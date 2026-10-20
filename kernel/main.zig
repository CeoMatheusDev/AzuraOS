//! AzuraOS kernel entry point (M1).
//!
//! The kernel is a freestanding ELF64 image loaded by the UEFI bootloader.
//! The bootloader jumps here with RDI pointing at the `boot_info` structure
//! described in shared/boot_info.zig.
//!
//! Scope of this milestone:
//!   * validate the boot protocol contract,
//!   * install the IDT so CPU faults are reported instead of rebooting,
//!   * print the handover information to the serial port,
//!   * stop the machine in a controlled way.
//!
//! NOT in this milestone: own GDT, own page tables, ExitBootServices,
//! heap, scheduler, drivers. Those are M2 and later.

const std = @import("std");
const shared = @import("shared");
const com1 = @import("com1");
const shared_framebuffer = @import("framebuffer");
const build_options = @import("build_options");

const cpu = @import("arch/x86_64/cpu.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");

/// Number of memory map entries printed in the boot log.
const memory_map_preview = 8;

/// Kernel entry point. The build system points the ELF entry symbol here.
///
/// Invariants:
///   * RSP points at a 16 KiB stack allocated by the bootloader,
///   * RDI points at a valid `boot_info` structure,
///   * the CPU is in 64-bit long mode with interrupts disabled.
pub export fn azura_kernel_entry(boot_info: *shared.boot_info) noreturn {
    com1.init();
    com1.write("[azura] === AzuraOS kernel v0.1.0 (M1) ===\n");

    if (boot_info.magic != shared.magic) {
        com1.print("[azura] FATAL: bad boot magic 0x{x}\n", .{boot_info.magic});
        cpu.haltForever();
    }
    if (boot_info.version != shared.version) {
        com1.print("[azura] FATAL: boot protocol version {d}, expected {d}\n", .{
            boot_info.version,
            shared.version,
        });
        cpu.haltForever();
    }
    if (boot_info.size < @sizeOf(shared.boot_info)) {
        com1.print("[azura] FATAL: boot_info too small: {d} bytes\n", .{boot_info.size});
        cpu.haltForever();
    }

    com1.print("[azura] boot protocol: version {d}, {d} bytes\n", .{
        boot_info.version,
        boot_info.size,
    });
    com1.print("[azura] kernel image: 0x{x}..0x{x}\n", .{
        boot_info.kernel_start,
        boot_info.kernel_end,
    });
    com1.print("[azura] stack top: 0x{x}\n", .{boot_info.stack_top});
    com1.print("[azura] memory map: {d} entries\n", .{boot_info.memory_map_count});

    printMemoryMap(boot_info);
    printFramebuffer(boot_info);

    // The IDT is installed first, with the selector that is active at this
    // moment. That way a fault during the GDT switch is reported by the
    // handler instead of escalating to a triple fault, which would reboot
    // the machine with no diagnostic at all.
    const initial_selector = cpu.codeSelector();
    idt.install(initial_selector);
    com1.print("[azura] IDT installed, provisional selector 0x{x}\n", .{initial_selector});

    // Install the GDT the kernel owns. Until now the kernel was running on
    // the GDT the firmware built, which only worked by accident.
    gdt.init();
    printGdt();

    // The handlers now run in the kernel's own code segment, so the IDT has
    // to name that selector.
    idt.install(gdt.kernel_code_selector);

    // Check that every entry really points at the beginning of its stub.
    if (idt.verifyEntries()) |vector| {
        com1.print("[azura] FATAL: IDT entry for vector {d} does not point at its stub\n", .{vector});
        cpu.haltForever();
    }
    com1.write("[azura] IDT installed, exception handling active\n");

    if (build_options.fault_inject) {
        com1.write("[azura] fault injection requested, executing an invalid opcode\n");
        // #UD (vector 6): must be caught by the handler installed above.
        asm volatile ("ud2");
        com1.write("[azura] ERROR: the invalid opcode did not fault\n");
    }

    com1.write("[azura] boot complete, halting\n");
    cpu.haltForever();
}

/// Print the GDT the kernel just installed, and prove that it is the one
/// the processor is actually using.
///
/// The check reads the GDTR back and compares it with the table this module
/// built, and reads the live CS register. Both must match, otherwise the
/// kernel would still be running on the firmware's descriptors.
fn printGdt() void {
    const descriptor = gdt.readPseudoDescriptor();
    const selector = cpu.codeSelector();

    com1.print("[azura] GDT: base=0x{x} limit={d} (expected 0x{x} / {d})\n", .{
        descriptor.base,
        descriptor.limit,
        gdt.baseAddress(),
        gdt.limit(),
    });
    com1.print("[azura] GDT: code selector=0x{x} data selector=0x{x}\n", .{
        selector,
        gdt.kernel_data_selector,
    });

    if (descriptor.base != gdt.baseAddress() or descriptor.limit != gdt.limit()) {
        com1.write("[azura] FATAL: the processor is not using the kernel GDT\n");
        cpu.haltForever();
    }
    if (selector != gdt.kernel_code_selector) {
        com1.print("[azura] FATAL: CS is 0x{x}, expected 0x{x}\n", .{
            selector,
            gdt.kernel_code_selector,
        });
        cpu.haltForever();
    }
    com1.write("[azura] GDT active, the segments are the kernel's own\n");
}

/// Print a preview of the physical memory map handed over by the bootloader.
fn printMemoryMap(boot_info: *shared.boot_info) void {
    if (boot_info.memory_map == 0 or boot_info.memory_map_count == 0) {
        com1.write("[azura] memory map: EMPTY\n");
        return;
    }
    if (boot_info.memory_map_descriptor_size < @sizeOf(shared.memory_descriptor)) {
        com1.print("[azura] memory map: unexpected descriptor size {d}\n", .{
            boot_info.memory_map_descriptor_size,
        });
        return;
    }

    var index: u32 = 0;
    var conventional_pages: u64 = 0;
    while (index < boot_info.memory_map_count) : (index += 1) {
        const offset = @as(usize, index) * boot_info.memory_map_descriptor_size;
        const descriptor: *const shared.memory_descriptor = @ptrCast(@alignCast(
            @as([*]const u8, @ptrFromInt(boot_info.memory_map)) + offset,
        ));
        if (descriptor.type == @backingInt(shared.memory_type.conventional)) conventional_pages += descriptor.number_of_pages;
    }
    com1.print("[azura] conventional memory: {d} MiB\n", .{conventional_pages * 4096 / (1024 * 1024)});

    var shown: u32 = 0;
    index = 0;
    while (index < boot_info.memory_map_count and shown < memory_map_preview) : (index += 1) {
        const offset = @as(usize, index) * boot_info.memory_map_descriptor_size;
        const descriptor: *const shared.memory_descriptor = @ptrCast(@alignCast(
            @as([*]const u8, @ptrFromInt(boot_info.memory_map)) + offset,
        ));
        com1.print("[azura]   map[{d}] {s} phys=0x{x} pages={d}\n", .{
            index,
            shared.memoryTypeName(descriptor.type),
            descriptor.physical_start,
            descriptor.number_of_pages,
        });
        shown += 1;
    }
    if (boot_info.memory_map_count > memory_map_preview) {
        com1.print("[azura]   ... {d} more entries\n", .{
            boot_info.memory_map_count - memory_map_preview,
        });
    }
}

/// Print the framebuffer geometry handed over by the bootloader.
fn printFramebuffer(boot_info: *shared.boot_info) void {
    if (boot_info.framebuffer_present == 0) {
        com1.write("[azura] framebuffer: NONE\n");
        return;
    }
    const fb = boot_info.framebuffer;
    com1.print("[azura] framebuffer: {d}x{d} stride={d} base=0x{x} size={d}\n", .{
        fb.width,
        fb.height,
        fb.stride,
        fb.base,
        fb.size,
    });
    com1.print("[azura] framebuffer masks: r=0x{x} g=0x{x} b=0x{x}\n", .{
        fb.red_mask,
        fb.green_mask,
        fb.blue_mask,
    });

    // The same checksum the bootloader computed over the pixels it wrote.
    // The automated test compares the two values, which proves that the
    // kernel sees exactly the framebuffer the bootloader left behind.
    const sum = shared_framebuffer.checksum(fb.base, fb.stride, fb.height);
    com1.print("[azura] framebuffer checksum: 0x{x}\n", .{sum});
}
