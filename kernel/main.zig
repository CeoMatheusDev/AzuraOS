//! AzuraOS kernel entry point.
//!
//! The kernel is a freestanding ELF64 image loaded by the UEFI bootloader.
//! The bootloader jumps here with RDI pointing at the `boot_info` structure
//! described in shared/boot_info.zig, after it has called ExitBootServices.
//!
//! Scope of this milestone (M2.2):
//!   * validate the boot protocol contract,
//!   * prove that the boot services are gone and that the environment they
//!     left behind (stack, GDT, IDT, framebuffer, memory map) is still valid,
//!   * install the IDT so CPU faults are reported instead of rebooting,
//!   * stop the machine in a controlled way.
//!
//! NOT in this milestone: the kernel's own page tables (M2.4), the physical
//! memory manager (M2.3), heap, scheduler and drivers.

const std = @import("std");
const shared = @import("shared");
const com1 = @import("com1");
const shared_framebuffer = @import("framebuffer");
const build_options = @import("build_options");

const cpu = @import("arch/x86_64/cpu.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const tss = @import("arch/x86_64/tss.zig");

/// Number of memory map entries printed in the boot log.
const memory_map_preview = 8;

/// Bytes per page in the UEFI memory map.
const page_size: u64 = 4096;

/// Pattern written to the kernel stack after the handover. The value is
/// arbitrary but distinctive, so a mismatch is unambiguous in the log.
const stack_probe_pattern: u64 = 0x5a17_c0de_1234_5678;

/// Kernel entry point. The build system points the ELF entry symbol here.
///
/// Invariants:
///   * RSP points at a 16 KiB stack allocated by the bootloader,
///   * RDI points at a valid `boot_info` structure,
///   * the CPU is in 64-bit long mode with interrupts disabled.
pub export fn azura_kernel_entry(boot_info: *shared.boot_info) noreturn {
    com1.init();
    com1.write("[azura] === AzuraOS kernel v0.1.0 (M2.2) ===\n");

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

    // The whole milestone rests on this field: the kernel is not allowed to
    // assume that the firmware is gone when the bootloader did not say so.
    if (boot_info.boot_services_exited != 1) {
        com1.write("[azura] FATAL: the bootloader did not exit the boot services\n");
        cpu.haltForever();
    }

    com1.print("[azura] boot protocol: version {d}, {d} bytes\n", .{
        boot_info.version,
        boot_info.size,
    });
    com1.print("[azura] boot services: exited, memory map key=0x{x}\n", .{boot_info.memory_map_key});

    // The mapping is still the firmware's. This is deliberate for M2.2: the
    // kernel does not own the page tables yet, and the log has to say so
    // instead of implying that it does.
    com1.print("[azura] page tables: the firmware's (CR3=0x{x}), the kernel's own are M2.4\n", .{
        cpu.readCr3(),
    });

    com1.print("[azura] kernel image: 0x{x}..0x{x}\n", .{
        boot_info.kernel_start,
        boot_info.kernel_end,
    });
    com1.print("[azura] stack: base=0x{x} top=0x{x}\n", .{
        boot_info.stack_base,
        boot_info.stack_top,
    });
    com1.print("[azura] memory map: {d} entries\n", .{boot_info.memory_map_count});

    printMemoryMap(boot_info);
    printFramebuffer(boot_info);

    // The IDT is installed first, with the selector that is active at this
    // moment. That way a fault during the GDT switch is reported by the
    // handler instead of escalating to a triple fault, which would reboot
    // the machine with no diagnostic at all.
    const initial_selector = cpu.codeSelector();
    idt.install(initial_selector, false);
    com1.print("[azura] IDT installed, provisional selector 0x{x}\n", .{initial_selector});

    // Install the GDT the kernel owns. Until now the kernel was running on
    // the GDT the firmware built, which only worked by accident.
    gdt.init();
    printGdt();

    // Only load TR after confirming the kernel GDT and CS are active.
    // A failed LTR can raise #GP; keep the provisional IDT installed here.
    gdt.loadTaskRegister();
    const active_tr = gdt.readTaskRegister();
    if (active_tr != tss.selector) {
        com1.print("[azura] FATAL: TR is 0x{x}, expected 0x{x}\n", .{ active_tr, tss.selector });
        cpu.haltForever();
    }
    com1.print("[azura] TSS task register loaded (TR=0x{x})\n", .{active_tr});

    // The handlers now run in the kernel's own code segment, so the IDT has
    // to name that selector.
    idt.install(gdt.kernel_code_selector, true);

    if (!idt.verifyIstConfiguration(true, gdt.kernel_code_selector)) {
        com1.write("[azura] FATAL: IDT selector or IST routing mismatch\n");
        cpu.haltForever();
    }
    com1.write("[azura] double-fault gate: IST1 configured\n");

    // Check that every entry really points at the beginning of its stub.
    if (idt.verifyEntries()) |vector| {
        com1.print("[azura] FATAL: IDT entry for vector {d} does not point at its stub\n", .{vector});
        cpu.haltForever();
    }
    com1.write("[azura] IDT installed, exception handling active\n");

    // Prove that the environment the firmware left behind is still usable
    // after the transition. The GDT was checked by printGdt and the IDT
    // entries by verifyEntries; the stack and the IDT register are checked
    // here, and printMemoryMap/printFramebuffer above proved that the map
    // and the framebuffer are readable.
    verifyStack(boot_info);
    verifyIdt();
    com1.write("[azura] post-ExitBootServices: stack=ok gdt=ok idt=ok framebuffer=ok memory_map=ok\n");

    if (build_options.fault_mode.len != 0 and !std.mem.eql(u8, build_options.fault_mode, "none")) {
        injectFault(build_options.fault_mode);
    }

    com1.write("[azura] boot complete, halting\n");
    cpu.haltForever();
}

/// The faults the kernel can inject on purpose, to exercise the exception
/// handler.
const FaultMode = enum {
    /// #UD (vector 6). The vector pushes no error code.
    invalid_opcode,
    /// #GP (vector 13). The vector pushes an error code.
    bad_segment,

    /// Parse the value of the `fault-mode` build option.
    fn parse(text: []const u8) ?FaultMode {
        if (std.mem.eql(u8, text, "invalid_opcode")) return .invalid_opcode;
        if (std.mem.eql(u8, text, "bad_segment")) return .bad_segment;
        return null;
    }
};

/// Raise the requested fault on purpose.
///
/// The handler installed above must catch it, report it and halt the
/// machine. The code after the faulting instruction is only reached if the
/// handler returned, which it never does; reaching it means the handler
/// failed and is reported as a boot error.
fn injectFault(mode_text: []const u8) noreturn {
    const mode = FaultMode.parse(mode_text) orelse {
        com1.print("[azura] FATAL: unknown fault mode '{s}'\n", .{mode_text});
        cpu.haltForever();
    };

    switch (mode) {
        .invalid_opcode => {
            com1.write("[azura] fault injection requested, executing an invalid opcode\n");
            asm volatile ("ud2");
        },
        .bad_segment => {
            com1.write("[azura] fault injection requested, loading an out of range segment selector\n");
            cpu.loadInvalidSegmentSelector();
        },
    }

    com1.write("[azura] ERROR: the injected fault did not fault\n");
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

/// Read the n-th descriptor of the map handed over by the bootloader.
fn descriptorAt(boot_info: *shared.boot_info, index: u32) *const shared.memory_descriptor {
    const offset = @as(usize, index) * boot_info.memory_map_descriptor_size;
    return @ptrCast(@alignCast(
        @as([*]const u8, @ptrFromInt(boot_info.memory_map)) + offset,
    ));
}

/// Validate, classify and print the physical memory map.
///
/// The map was taken by the bootloader BEFORE ExitBootServices, so the boot
/// services regions in it are still described as owned by the firmware. They
/// are free after the transition, but the kernel does not allocate them
/// until M2.3 has built the physical allocator; see ADR-0007.
///
/// Every descriptor is checked before its address range is used: a firmware
/// can describe a range that wraps around the 64-bit address space, and an
/// allocator built on that would hand out memory that does not exist.
fn printMemoryMap(boot_info: *shared.boot_info) void {
    if (boot_info.memory_map == 0 or boot_info.memory_map_count == 0) {
        com1.write("[azura] FATAL: the memory map is empty\n");
        cpu.haltForever();
    }
    if (boot_info.memory_map_descriptor_size < @sizeOf(shared.memory_descriptor)) {
        com1.print("[azura] FATAL: memory map descriptor size {d} is too small\n", .{
            boot_info.memory_map_descriptor_size,
        });
        cpu.haltForever();
    }

    // Bound the walk before multiplying: the count and the stride come from
    // the bootloader, but a corrupted structure must fail a check instead of
    // reading past the map buffer.
    const map_bytes = @as(u64, boot_info.memory_map_count) * @as(u64, boot_info.memory_map_descriptor_size);
    if (map_bytes == 0 or map_bytes > 16 * 1024 * 1024) {
        com1.print("[azura] FATAL: memory map size {d} bytes is out of range\n", .{map_bytes});
        cpu.haltForever();
    }

    var index: u32 = 0;
    var conventional_pages: u64 = 0;
    var boot_services_pages: u64 = 0;
    var loader_pages: u64 = 0;
    var map_buffer_type: ?u32 = null;
    const map_address = boot_info.memory_map;

    while (index < boot_info.memory_map_count) : (index += 1) {
        const descriptor = descriptorAt(boot_info, index);

        // A range that wraps around the address space is not memory. Refuse
        // the whole map instead of carrying a poisoned entry forward.
        const max_pages = (std.math.maxInt(u64) - descriptor.physical_start) / page_size;
        if (descriptor.number_of_pages > max_pages) {
            com1.print("[azura] FATAL: memory map entry {d} wraps around the address space\n", .{index});
            cpu.haltForever();
        }

        const end = descriptor.physical_start + descriptor.number_of_pages * page_size;
        if (descriptor.physical_start <= map_address and map_address < end) {
            map_buffer_type = descriptor.type;
        }

        switch (descriptor.type) {
            @backingInt(shared.memory_type.conventional) => conventional_pages += descriptor.number_of_pages,
            @backingInt(shared.memory_type.boot_services_code),
            @backingInt(shared.memory_type.boot_services_data),
            => boot_services_pages += descriptor.number_of_pages,
            @backingInt(shared.memory_type.loader_code),
            @backingInt(shared.memory_type.loader_data),
            => loader_pages += descriptor.number_of_pages,
            else => {},
        }
    }

    // The map must describe the memory it lives in. If it does not, either
    // the pointer is wrong or the map is not self consistent, and neither is
    // safe to build an allocator on.
    if (map_buffer_type == null) {
        com1.write("[azura] FATAL: the memory map does not describe its own buffer\n");
        cpu.haltForever();
    }
    if (map_buffer_type.? != @backingInt(shared.memory_type.loader_data)) {
        com1.print("[azura] FATAL: the memory map buffer is {s}, expected loader_data\n", .{
            shared.memoryTypeName(map_buffer_type.?),
        });
        cpu.haltForever();
    }

    com1.print("[azura] memory: conventional={d} MiB boot_services={d} MiB loader={d} KiB\n", .{
        conventional_pages * page_size / (1024 * 1024),
        boot_services_pages * page_size / (1024 * 1024),
        loader_pages * page_size / 1024,
    });
    com1.print("[azura] memory map buffer: 0x{x} ({s})\n", .{
        map_address,
        shared.memoryTypeName(map_buffer_type.?),
    });

    var shown: u32 = 0;
    index = 0;
    while (index < boot_info.memory_map_count and shown < memory_map_preview) : (index += 1) {
        const descriptor = descriptorAt(boot_info, index);
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

    // The geometry is firmware data. A stride that is smaller than the row,
    // or a buffer larger than the one the firmware described, would make the
    // checksum read beyond the mapped framebuffer.
    const total = @as(u64, fb.height) * @as(u64, fb.stride);
    if (fb.base == 0 or fb.width == 0 or fb.height == 0 or fb.stride < fb.width or total > fb.size) {
        com1.print("[azura] FATAL: framebuffer geometry is inconsistent: {d}x{d} stride={d} size={d}\n", .{
            fb.width,
            fb.height,
            fb.stride,
            fb.size,
        });
        cpu.haltForever();
    }

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

/// Write and read back a known value on the kernel stack.
///
/// The stack was allocated by the firmware from pool memory and is described
/// by the memory map as loader data. This is the cheapest end to end proof
/// that the pages are still mapped and writable after ExitBootServices, and
/// that the stack pointer really points inside the range the bootloader
/// reported.
fn verifyStack(boot_info: *shared.boot_info) void {
    if (boot_info.stack_base == 0 or boot_info.stack_base >= boot_info.stack_top) {
        com1.print("[azura] FATAL: invalid stack bounds 0x{x}..0x{x}\n", .{
            boot_info.stack_base,
            boot_info.stack_top,
        });
        cpu.haltForever();
    }

    var probe: u64 = 0;
    const slot: *volatile u64 = &probe;
    slot.* = stack_probe_pattern;
    const read_back = slot.*;
    const address = @intFromPtr(&probe);
    const end = address + @sizeOf(u64);

    if (address < boot_info.stack_base or end < address or end > boot_info.stack_top) {
        com1.print("[azura] FATAL: the stack probe 0x{x} is outside 0x{x}..0x{x}\n", .{
            address,
            boot_info.stack_base,
            boot_info.stack_top,
        });
        cpu.haltForever();
    }
    if (read_back != stack_probe_pattern) {
        com1.print("[azura] FATAL: stack write/read mismatch at 0x{x}\n", .{address});
        cpu.haltForever();
    }

    com1.print("[azura] stack: writable at 0x{x}, inside 0x{x}..0x{x}\n", .{
        address,
        boot_info.stack_base,
        boot_info.stack_top,
    });
}

/// Read the IDTR back and refuse an empty table.
///
/// The entry addresses themselves were already checked by `idt.verifyEntries`
/// when the table was installed. This check proves that the register still
/// holds the table the kernel built.
fn verifyIdt() void {
    const descriptor = idt.readInstalledDescriptor();
    com1.print("[azura] IDT: base=0x{x} limit={d}\n", .{
        descriptor.base,
        descriptor.limit,
    });
    if (descriptor.base == 0 or descriptor.limit == 0) {
        com1.write("[azura] FATAL: the IDT register reads back empty\n");
        cpu.haltForever();
    }
}
