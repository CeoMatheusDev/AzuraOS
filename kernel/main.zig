//! AzuraOS kernel entry point.
//!
//! The kernel is a freestanding ELF64 image loaded by the UEFI bootloader.
//! The bootloader jumps here with RDI pointing at the `boot_info` structure
//! described in shared/boot_info.zig, after it has called ExitBootServices.
//!
//! Scope of this milestone (M2.3):
//!   * validate the boot protocol contract,
//!   * prove that the boot services are gone and that the environment they
//!     left behind (stack, GDT, IDT, framebuffer, memory map) is still valid,
//!   * install the IDT so CPU faults are reported instead of rebooting,
//!   * install a TSS whose IST1 stack takes over on #NMI, #DF and #MC,
//!   * build a physical frame allocator from the pre-ExitBootServices map,
//!     reserve everything the kernel still owns and exercise allocation and
//!     release at boot,
//!   * stop the machine in a controlled way.
//!
//! NOT in this milestone: the kernel's own page tables (M2.4), heap,
//! scheduler and drivers.

const std = @import("std");
const shared = @import("shared");
const com1 = @import("com1");
const shared_framebuffer = @import("framebuffer");
const build_options = @import("build_options");

const cpu = @import("arch/x86_64/cpu.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const tss = @import("arch/x86_64/tss.zig");
const frames = @import("mm/frames.zig");
const paging = @import("arch/x86_64/paging.zig");

extern var __text_start: u8;
extern var __text_end: u8;
extern var __rodata_start: u8;
extern var __rodata_end: u8;
extern var __data_start: u8;
extern var __data_end: u8;
extern var __bss_start: u8;
extern var __bss_end: u8;

/// Number of memory map entries printed in the boot log.
const memory_map_preview = 8;

/// Bytes per page in the UEFI memory map.
const page_size: u64 = 4096;

/// Pattern written to the kernel stack after the handover. The value is
/// arbitrary but distinctive, so a mismatch is unambiguous in the log.
const stack_probe_pattern: u64 = 0x5a17_c0de_1234_5678;

/// Pattern written into the frames during the allocator self-test.
const frame_probe_pattern: u64 = 0xa5a5_5a5a_0f0f_f0f0;

/// Bitmap for the physical frame allocator. It covers up to 4 GiB (one bit
/// per 4 KiB frame, 128 KiB in total); the prefix used at boot depends on the
/// highest conventional address in the memory map. The buffer lives in
/// `.bss`, so the bootloader zeroes it and the kernel pays no file size for
/// it.
var frame_bitmap: [frames.max_bitmap_bytes]u8 align(16) = undefined;

/// The allocator built from the boot memory map. It is initialised after the
/// exception environment is verified, so a fault during the self-test is
/// reported by the kernel handler instead of rebooting.
var frame_allocator: frames.Allocator = undefined;

/// Kernel entry point. The build system points the ELF entry symbol here.
///
/// Invariants:
///   * RSP points at a 16 KiB stack allocated by the bootloader,
///   * RDI points at a valid `boot_info` structure,
///   * the CPU is in 64-bit long mode with interrupts disabled.
pub export fn azura_kernel_entry(boot_info: *shared.boot_info) noreturn {
    com1.init();
    com1.write("[azura] === AzuraOS kernel v0.1.0 (M2.3) ===\n");

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
    // the machine with no diagnostic at all. The critical gates stay on the
    // interrupted stack: the kernel's TSS is not loaded yet.
    const initial_selector = cpu.codeSelector();
    idt.install(initial_selector, false);
    com1.print("[azura] IDT installed, provisional selector 0x{x}\n", .{initial_selector});

    // The TSS has to exist before the GDT, because the GDT carries its
    // descriptor. The IST stack is probed now, while a failure is still a
    // boot error and not a fault during a fault.
    tss.init(boot_info.stack_top);
    printTss(boot_info);
    if (tss.probeStack()) |address| {
        com1.print("[azura] IST1 stack: writable at 0x{x}\n", .{address});
    } else {
        com1.write("[azura] FATAL: the IST1 stack is not writable\n");
        cpu.haltForever();
    }

    // Install the GDT the kernel owns. Until now the kernel was running on
    // the GDT the firmware built, which only worked by accident.
    gdt.init(tss.encodeDescriptor(tss.address(), tss.limit()));
    printGdt();

    // Load the task register and prove that the processor really uses the
    // TSS the kernel built. `ltr` itself faults if the descriptor is not a
    // present TSS, so this also validates the GDT entry with the processor's
    // own checks.
    tss.load();
    verifyTss();

    // The handlers now run in the kernel's own code segment, so the IDT has
    // to name that selector. The TSS is loaded, so the critical vectors can
    // name IST1 from now on.
    idt.install(gdt.kernel_code_selector, true);

    // Check that every entry really points at the beginning of its stub.
    if (idt.verifyEntries()) |vector| {
        com1.print("[azura] FATAL: IDT entry for vector {d} does not point at its stub\n", .{vector});
        cpu.haltForever();
    }
    if (idt.verifyIst()) |vector| {
        com1.print("[azura] FATAL: IDT entry for vector {d} does not use the required IST stack\n", .{vector});
        cpu.haltForever();
    }
    com1.write("[azura] IDT: IST 1 active for vectors 2, 8 and 18\n");
    com1.write("[azura] IDT installed, exception handling active\n");

    // Prove that the environment the firmware left behind is still usable
    // after the transition. The GDT was checked by printGdt and the IDT
    // entries by verifyEntries; the stack and the IDT register are checked
    // here, and printMemoryMap/printFramebuffer above proved that the map
    // and the framebuffer are readable.
    verifyStack(boot_info);
    verifyIdt();

    // The map and the exception environment are trusted now. Build the
    // allocator and prove that it can hand out and take back real frames.
    initFrames(boot_info);

    // Replace the firmware's page tables with our own. The identity map
    // keeps every virtual address the kernel is currently using valid, so
    // the switch is transparent; the old tables are released afterwards.
    initPaging(boot_info);

    com1.write("[azura] post-ExitBootServices: stack=ok gdt=ok idt=ok tss=ok ist=ok frames=ok framebuffer=ok memory_map=ok\n");

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
    /// #DF (vector 8), forced by hiding the #GP gate from the IDT. The
    /// vector uses IST1, so the handler must run on the alternate stack.
    double_fault,
    /// #PF (vector 14). Reads an address that is not mapped, so the
    /// handler reports the faulting address in CR2.
    page_fault,

    /// Parse the value of the `fault-mode` build option.
    fn parse(text: []const u8) ?FaultMode {
        if (std.mem.eql(u8, text, "invalid_opcode")) return .invalid_opcode;
        if (std.mem.eql(u8, text, "bad_segment")) return .bad_segment;
        if (std.mem.eql(u8, text, "double_fault")) return .double_fault;
        if (std.mem.eql(u8, text, "page_fault")) return .page_fault;
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
        .double_fault => {
            com1.write("[azura] fault injection requested, hiding vector 13 to force a double fault\n");
            // Keep vectors 0..8 visible and hide the rest. `int $13` then
            // finds the #GP gate outside the IDT limit; the delivery of the
            // #GP fails for the same reason and the processor escalates to
            // #DF. Vector 8 is inside the limit and names IST1, so the
            // handler runs on the alternate stack.
            var descriptor = idt.readInstalledDescriptor();
            descriptor.limit = 9 * @sizeOf(idt.Entry) - 1;
            cpu.loadIdt(&descriptor);
            asm volatile ("int $13");
        },
        .page_fault => {
            com1.write("[azura] fault injection requested, reading an unmapped page\n");
            const probe: *volatile u64 = @ptrFromInt(0xdead0000);
            _ = probe.*;
        },
    }

    com1.write("[azura] ERROR: the injected fault did not fault\n");
    cpu.haltForever();
}

/// Print the TSS state and refuse impossible values before the processor is
/// allowed to depend on it.
fn printTss(boot_info: *shared.boot_info) void {
    const state = tss.state();

    com1.print("[azura] TSS: selector=0x{x} base=0x{x} limit={d}\n", .{
        tss.selector,
        tss.address(),
        tss.limit(),
    });
    com1.print("[azura] TSS: rsp0=0x{x} ist1=0x{x} iomap_base={d}\n", .{
        state.rsp0,
        state.ist1,
        state.iomap_base,
    });
    com1.print("[azura] IST1 stack: base=0x{x} top=0x{x}\n", .{
        tss.stackBase(),
        tss.stackTop(),
    });

    if (state.rsp0 != boot_info.stack_top) {
        com1.print("[azura] FATAL: TSS rsp0 0x{x} is not the boot stack top 0x{x}\n", .{
            state.rsp0,
            boot_info.stack_top,
        });
        cpu.haltForever();
    }
    if (state.ist1 != tss.stackTop()) {
        com1.print("[azura] FATAL: TSS IST1 0x{x} is not the top of the alternate stack 0x{x}\n", .{
            state.ist1,
            tss.stackTop(),
        });
        cpu.haltForever();
    }
    // A base at or below the limit would make the processor read an I/O
    // permission bitmap out of the TSS itself.
    if (state.iomap_base != tss.size) {
        com1.print("[azura] FATAL: TSS I/O map base {d} is not the disabled value {d}\n", .{
            state.iomap_base,
            tss.size,
        });
        cpu.haltForever();
    }
}

/// Prove that the processor loaded the TSS the kernel built.
///
/// `ltr` would have faulted on an invalid descriptor; this check closes the
/// remaining gap, where the descriptor is valid but points at another object
/// or at a stale address.
fn verifyTss() void {
    const task_register = cpu.taskRegister();
    com1.print("[azura] TSS loaded, task register=0x{x}\n", .{task_register});
    if (task_register != tss.selector) {
        com1.print("[azura] FATAL: TR is 0x{x}, expected 0x{x}\n", .{ task_register, tss.selector });
        cpu.haltForever();
    }

    const descriptor = gdt.readSystemDescriptor(tss.selector) orelse {
        com1.write("[azura] FATAL: the TSS descriptor does not fit the GDT\n");
        cpu.haltForever();
    };
    const decoded = tss.decodeDescriptor(descriptor);
    com1.print("[azura] TSS descriptor: base=0x{x} limit={d} access=0x{x} flags=0x{x}\n", .{
        decoded.base,
        decoded.limit,
        decoded.access,
        decoded.flags,
    });

    // `ltr` marks the descriptor busy (type 9 -> type 11), so the access
    // byte must have changed from the value the kernel encoded. Checking for
    // the busy type proves both that the descriptor describes our TSS and
    // that the processor accepted it.
    const busy_tss: u8 = 0x8b; // present, DPL 0, system, busy 64-bit TSS
    if (decoded.base != tss.address() or decoded.limit != tss.limit() or decoded.access != busy_tss) {
        com1.write("[azura] FATAL: the TSS descriptor in the GDT does not describe the kernel TSS\n");
        cpu.haltForever();
    }

    const state = tss.state();
    if (state.ist1 != tss.stackTop()) {
        com1.print("[azura] FATAL: the loaded TSS has IST1=0x{x}, expected 0x{x}\n", .{
            state.ist1,
            tss.stackTop(),
        });
        cpu.haltForever();
    }
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

/// Build the physical frame allocator from the map the bootloader handed
/// over, reserve everything the kernel still owns and prove the pool works.
///
/// Policy (ADR-0009):
///   * only `conventional` memory becomes free;
///   * the boot services stay quarantined: the kernel is still running on
///     the firmware's page tables, and those tables live in boot services
///     memory. Reclaiming it before M2.4 would free the tables under the
///     running kernel;
///   * the kernel image, the boot stack, the boot_info structure, the map
///     buffer and the framebuffer are reserved explicitly, even though the
///     map already describes most of them as loader data;
///   * memory above 4 GiB is ignored by the bitmap and counted in the log.
fn initFrames(boot_info: *shared.boot_info) void {
    var highest: u64 = 0;
    var boot_services_pages: u64 = 0;
    var ignored_pages: u64 = 0;

    var index: u32 = 0;
    while (index < boot_info.memory_map_count) : (index += 1) {
        const descriptor = descriptorAt(boot_info, index);
        if (descriptor.number_of_pages == 0) continue;

        // The allocator revalidates the ranges it will mark. `printMemoryMap`
        // already rejected a wrapping descriptor, but the allocator must not
        // depend on another function having run first.
        const max_pages = (std.math.maxInt(u64) - descriptor.physical_start) / page_size;
        if (descriptor.number_of_pages > max_pages) {
            com1.print("[azura] FATAL: memory map entry {d} wraps the address space\n", .{index});
            cpu.haltForever();
        }
        const end = descriptor.physical_start + descriptor.number_of_pages * page_size;
        const is_conventional = descriptor.type == @backingInt(shared.memory_type.conventional);
        const is_boot_services = descriptor.type == @backingInt(shared.memory_type.boot_services_code) or
            descriptor.type == @backingInt(shared.memory_type.boot_services_data);

        // The bitmap covers conventional memory and, ahead of time, the
        // boot services regions that M2.4 may reclaim. Boot services stay
        // used in M2.3, so covering them costs a few used bits but means the
        // pool does not have to be resized when the page tables become the
        // kernel's own.
        if (is_conventional or is_boot_services) {
            if (descriptor.physical_start < frames.max_physical_address) {
                highest = @max(highest, @min(end, frames.max_physical_address));
            }
        }
        if (is_conventional and end > frames.max_physical_address) {
            const above = @max(descriptor.physical_start, frames.max_physical_address);
            ignored_pages += (end - above) / page_size;
        }
        if (is_boot_services) {
            boot_services_pages += descriptor.number_of_pages;
        }
    }

    if (highest == 0) {
        com1.write("[azura] FATAL: the memory map has no conventional memory\n");
        cpu.haltForever();
    }

    const frame_count_64 = (highest + page_size - 1) / page_size;
    if (frame_count_64 == 0 or frame_count_64 > @as(u64, frames.max_frames)) {
        com1.print("[azura] FATAL: the memory map needs {d} frames, the bitmap covers {d}\n", .{
            frame_count_64,
            frames.max_frames,
        });
        cpu.haltForever();
    }
    const frame_count: usize = @intCast(frame_count_64);
    const bitmap_bytes = (frame_count + 7) / 8;
    if (bitmap_bytes > frame_bitmap.len) {
        com1.print("[azura] FATAL: the frame bitmap needs {d} bytes, {d} are available\n", .{
            bitmap_bytes,
            frame_bitmap.len,
        });
        cpu.haltForever();
    }

    frame_allocator = frames.Allocator.init(frame_bitmap[0..bitmap_bytes], frame_count) catch {
        com1.write("[azura] FATAL: could not initialise the frame allocator\n");
        cpu.haltForever();
    };

    // Free only the conventional descriptors. Boot services, loader code and
    // data, runtime services, ACPI, reserved and MMIO all stay used.
    index = 0;
    while (index < boot_info.memory_map_count) : (index += 1) {
        const descriptor = descriptorAt(boot_info, index);
        if (descriptor.type != @backingInt(shared.memory_type.conventional)) continue;
        if (descriptor.number_of_pages == 0) continue;

        const max_pages = (std.math.maxInt(u64) - descriptor.physical_start) / page_size;
        if (descriptor.number_of_pages > max_pages) {
            com1.print("[azura] FATAL: memory map entry {d} wraps the address space\n", .{index});
            cpu.haltForever();
        }
        const end = descriptor.physical_start + descriptor.number_of_pages * page_size;
        frame_allocator.markFreeRange(descriptor.physical_start, end);
    }

    // Keep the first MiB out of the pool. UEFI labels the real-mode IVT, the
    // BDA and the firmware's low scratch area as conventional after
    // ExitBootServices, but nothing in the kernel needs them, and reserving
    // them turns a null-pointer dereference into a fault instead of a write
    // to a valid frame.
    frame_allocator.reserveRange(0, 1024 * 1024);

    // Reserve the ranges the policy cannot express through the memory type,
    // plus the structures the kernel is actively using.
    frame_allocator.reserveRange(boot_info.kernel_start, boot_info.kernel_end);
    frame_allocator.reserveRange(boot_info.stack_base, boot_info.stack_top);

    const info_start = @intFromPtr(boot_info);
    frame_allocator.reserveRange(info_start, info_start + @sizeOf(shared.boot_info));

    const map_bytes = @as(u64, boot_info.memory_map_count) * @as(u64, boot_info.memory_map_descriptor_size);
    if (boot_info.memory_map == 0 or map_bytes > std.math.maxInt(u64) - boot_info.memory_map) {
        com1.write("[azura] FATAL: the memory map range wraps the address space\n");
        cpu.haltForever();
    }
    frame_allocator.reserveRange(boot_info.memory_map, boot_info.memory_map + map_bytes);

    if (boot_info.framebuffer_present != 0) {
        const framebuffer = boot_info.framebuffer;
        if (framebuffer.size > std.math.maxInt(u64) - framebuffer.base) {
            com1.write("[azura] FATAL: the framebuffer range wraps the address space\n");
            cpu.haltForever();
        }
        frame_allocator.reserveRange(framebuffer.base, framebuffer.base + framebuffer.size);
    }

    const stats = frame_allocator.stats();
    if (stats.free == 0) {
        com1.write("[azura] FATAL: the frame allocator has no free frame\n");
        cpu.haltForever();
    }
    com1.print("[azura] frame allocator: {d} frames, {d} free, {d} used ({d} MiB covered)\n", .{
        stats.total,
        stats.free,
        stats.used,
        frame_allocator.capacityBytes() / (1024 * 1024),
    });
    com1.print("[azura] frame allocator: bitmap={d} bytes, boot_services={d} MiB quarantined, above 4 GiB={d} MiB ignored\n", .{
        bitmap_bytes,
        boot_services_pages * page_size / (1024 * 1024),
        ignored_pages * page_size / (1024 * 1024),
    });
    com1.write("[azura] frame allocator: reserved low 1 MiB, kernel image, boot stack, boot_info, map and framebuffer\n");

    frameSelfTest(boot_info);
}

/// Allocate three frames, write both ends of each one, release them and
/// reallocate the lowest one. A frame that overlaps kernel-owned memory, an
/// unmapped frame or a broken bit operation stops the boot.
fn frameSelfTest(boot_info: *shared.boot_info) void {
    const free_before = frame_allocator.stats().free;
    if (free_before < 3) {
        com1.print("[azura] FATAL: the frame self-test needs 3 free frames, {d} available\n", .{free_before});
        cpu.haltForever();
    }

    var addresses: [3]u64 = undefined;
    for (&addresses) |*slot| {
        const address = frame_allocator.allocate() orelse {
            com1.write("[azura] FATAL: the frame self-test could not allocate a frame\n");
            cpu.haltForever();
        };
        slot.* = address;

        if (address % page_size != 0 or address >= frame_allocator.capacityBytes()) {
            com1.print("[azura] FATAL: the frame allocator returned an invalid address 0x{x}\n", .{address});
            cpu.haltForever();
        }
        if (overlapsOwnedRange(address, boot_info)) {
            com1.print("[azura] FATAL: the frame allocator returned kernel-owned memory 0x{x}\n", .{address});
            cpu.haltForever();
        }

        const expected = frame_probe_pattern ^ address;
        const head: *volatile u64 = @ptrFromInt(address);
        head.* = expected;
        if (head.* != expected) {
            com1.print("[azura] FATAL: frame write/read mismatch at 0x{x}\n", .{address});
            cpu.haltForever();
        }

        const tail_address = address + page_size - @sizeOf(u64);
        const tail: *volatile u64 = @ptrFromInt(tail_address);
        const tail_expected = ~expected;
        tail.* = tail_expected;
        if (tail.* != tail_expected) {
            com1.print("[azura] FATAL: frame tail write/read mismatch at 0x{x}\n", .{tail_address});
            cpu.haltForever();
        }
    }
    if (frame_allocator.stats().free != free_before - 3) {
        com1.write("[azura] FATAL: the frame allocator lost track of the self-test allocations\n");
        cpu.haltForever();
    }

    const lowest = @min(addresses[0], @min(addresses[1], addresses[2]));
    for (addresses) |address| {
        frame_allocator.release(address) catch {
            com1.print("[azura] FATAL: could not release the self-test frame 0x{x}\n", .{address});
            cpu.haltForever();
        };
    }
    if (frame_allocator.stats().free != free_before) {
        com1.write("[azura] FATAL: the frame allocator did not recover the self-test frames\n");
        cpu.haltForever();
    }

    const reused = frame_allocator.allocate() orelse {
        com1.write("[azura] FATAL: the frame allocator did not reuse a released frame\n");
        cpu.haltForever();
    };
    if (reused != lowest) {
        com1.print("[azura] FATAL: the frame allocator reused 0x{x}, expected the lowest released frame 0x{x}\n", .{
            reused,
            lowest,
        });
        cpu.haltForever();
    }
    frame_allocator.release(reused) catch {
        com1.print("[azura] FATAL: could not release the reused frame 0x{x}\n", .{reused});
        cpu.haltForever();
    };
    if (frame_allocator.stats().free != free_before) {
        com1.write("[azura] FATAL: the frame allocator did not recover the reused frame\n");
        cpu.haltForever();
    }

    com1.print("[azura] frame allocator: self-test ok, allocated 0x{x} 0x{x} 0x{x} and reused 0x{x}\n", .{
        addresses[0],
        addresses[1],
        addresses[2],
        reused,
    });
}

/// Whether the frame at `address` overlaps memory the kernel must keep, even
/// if the allocator's policy were wrong. This is a second, independent guard
/// for the boot self-test.
fn overlapsOwnedRange(address: u64, boot_info: *shared.boot_info) bool {
    const end = address + page_size;
    if (rangeOverlaps(address, end, boot_info.kernel_start, boot_info.kernel_end)) return true;
    if (rangeOverlaps(address, end, boot_info.stack_base, boot_info.stack_top)) return true;

    const info_start = @intFromPtr(boot_info);
    if (rangeOverlaps(address, end, info_start, info_start + @sizeOf(shared.boot_info))) return true;

    const map_bytes = @as(u64, boot_info.memory_map_count) * @as(u64, boot_info.memory_map_descriptor_size);
    if (rangeOverlaps(address, end, boot_info.memory_map, boot_info.memory_map + map_bytes)) return true;

    if (boot_info.framebuffer_present != 0) {
        const framebuffer = boot_info.framebuffer;
        if (rangeOverlaps(address, end, framebuffer.base, framebuffer.base + framebuffer.size)) return true;
    }
    return false;
}

fn rangeOverlaps(a_start: u64, a_end: u64, b_start: u64, b_end: u64) bool {
    return a_start < b_end and b_start < a_end;
}

/// Build and install the kernel's own 4-level page tables.
///
/// The tables identity-map every region the kernel or the firmware may touch
/// (conventional, loader, boot services, runtime services, ACPI, persistent
/// and PAL memory, plus the framebuffer MMIO) and then overwrite the kernel
/// image pages with W^X permissions. The switch is made with interrupts
/// disabled and the old tables are released only after the new CR3 is active.
fn initPaging(boot_info: *shared.boot_info) void {
    const efer_before = cpu.readEfer();
    cpu.enableNx();
    const efer_after = cpu.readEfer();
    com1.print("[azura] paging: EFER before=0x{x} after=0x{x}\n", .{ efer_before, efer_after });

    const old_cr3 = cpu.readCr3();
    com1.print("[azura] paging: building tables, old CR3=0x{x}\n", .{old_cr3});

    const pml4 = paging.allocTable(&frame_allocator) orelse {
        com1.write("[azura] FATAL: could not allocate the PML4\n");
        cpu.haltForever();
    };

    const data_flags = paging.Flags{
        .present = true,
        .writable = true,
        .no_execute = true,
    };

    var index: u32 = 0;
    while (index < boot_info.memory_map_count) : (index += 1) {
        const descriptor = descriptorAt(boot_info, index);
        if (descriptor.number_of_pages == 0) continue;

        const map_type = descriptor.type;
        if (map_type == @backingInt(shared.memory_type.unusable)) continue;

        const start = descriptor.physical_start;
        const size = descriptor.number_of_pages * page_size;

        if (map_type == @backingInt(shared.memory_type.memory_mapped_io) or
            map_type == @backingInt(shared.memory_type.memory_mapped_io_port_space))
        {
            if (boot_info.framebuffer_present != 0 and start == boot_info.framebuffer.base) {
                const framebuffer = boot_info.framebuffer;
                if (!paging.mapRange(pml4, framebuffer.base, framebuffer.base, framebuffer.size, data_flags, &frame_allocator)) {
                    com1.write("[azura] FATAL: could not map the framebuffer\n");
                    cpu.haltForever();
                }
            }
            continue;
        }

        if (!paging.mapRange(pml4, start, start, size, data_flags, &frame_allocator)) {
            com1.print("[azura] FATAL: could not map memory map entry {d}\n", .{index});
            cpu.haltForever();
        }
    }
    com1.write("[azura] paging: descriptors mapped\n");

    // W^X for the kernel image. The identity map above made every page
    // writable; overwrite the sections that must not be.
    const text_start = @intFromPtr(&__text_start);
    const text_end = @intFromPtr(&__text_end);
    const rodata_start = @intFromPtr(&__rodata_start);
    const rodata_end = @intFromPtr(&__rodata_end);
    const data_start = @intFromPtr(&__data_start);
    const data_end = @intFromPtr(&__data_end);
    const bss_start = @intFromPtr(&__bss_start);
    const bss_end = @intFromPtr(&__bss_end);

    if (text_end > text_start) {
        if (!paging.mapRange(pml4, text_start, text_start, text_end - text_start, .{
            .present = true,
            .writable = false,
            .no_execute = false,
        }, &frame_allocator)) {
            com1.write("[azura] FATAL: could not map the kernel text\n");
            cpu.haltForever();
        }
    }
    if (rodata_end > rodata_start) {
        if (!paging.mapRange(pml4, rodata_start, rodata_start, rodata_end - rodata_start, .{
            .present = true,
            .writable = false,
            .no_execute = true,
        }, &frame_allocator)) {
            com1.write("[azura] FATAL: could not map the kernel rodata\n");
            cpu.haltForever();
        }
    }
    if (data_end > data_start) {
        if (!paging.mapRange(pml4, data_start, data_start, data_end - data_start, data_flags, &frame_allocator)) {
            com1.write("[azura] FATAL: could not map the kernel data\n");
            cpu.haltForever();
        }
    }
    if (bss_end > bss_start) {
        if (!paging.mapRange(pml4, bss_start, bss_start, bss_end - bss_start, data_flags, &frame_allocator)) {
            com1.write("[azura] FATAL: could not map the kernel bss\n");
            cpu.haltForever();
        }
    }
    com1.write("[azura] paging: W^X applied, switching CR3\n");

    cpu.writeCr3(@intFromPtr(pml4));
    com1.write("[azura] paging: CR3 written\n");

    // Release the firmware's tables. They are distinct from the ones just
    // built, so this cannot free a page the new tree needs.
    freeOldPageTables(old_cr3);

    // The kernel now owns its page tables, so the boot services quarantine
    // from ADR-0007 can be released. The descriptors are identity mapped
    // above and the frames are returned to the pool.
    const free_before_bs = frame_allocator.stats().free;
    var bs_index: u32 = 0;
    while (bs_index < boot_info.memory_map_count) : (bs_index += 1) {
        const descriptor = descriptorAt(boot_info, bs_index);
        if (descriptor.type != @backingInt(shared.memory_type.boot_services_code) and
            descriptor.type != @backingInt(shared.memory_type.boot_services_data))
        {
            continue;
        }
        if (descriptor.number_of_pages == 0) continue;
        const end = descriptor.physical_start + descriptor.number_of_pages * page_size;
        frame_allocator.markFreeRange(descriptor.physical_start, end);
    }
    com1.print("[azura] paging: released boot services quarantine, free frames {d} -> {d}\n", .{
        free_before_bs,
        frame_allocator.stats().free,
    });

    if (cpu.readCr3() != @intFromPtr(pml4)) {
        com1.write("[azura] FATAL: CR3 did not accept the new page tables\n");
        cpu.haltForever();
    }

    com1.print("[azura] paging: new page tables at 0x{x}, CR3=0x{x}\n", .{
        @intFromPtr(pml4),
        cpu.readCr3(),
    });
    com1.print("[azura] paging: text=0x{x}..0x{x} rodata=0x{x}..0x{x} data=0x{x}..0x{x} bss=0x{x}..0x{x}\n", .{
        text_start,
        text_end,
        rodata_start,
        rodata_end,
        data_start,
        data_end,
        bss_start,
        bss_end,
    });
}

/// Walk the firmware's page table tree and return its frames to the pool.
fn freeOldPageTables(old_cr3: u64) void {
    const old_pml4: *const paging.Table = @ptrFromInt(old_cr3 & paging.address_mask);
    var idx4: usize = 0;
    while (idx4 < paging.entries_per_table) : (idx4 += 1) {
        const p4e = old_pml4[idx4];
        if (p4e & 1 == 0) continue;
        if (p4e & (1 << 7) != 0) continue;
        const pdpt: *const paging.Table = @ptrFromInt(p4e & paging.address_mask);
        var idx3: usize = 0;
        while (idx3 < paging.entries_per_table) : (idx3 += 1) {
            const pdpe = pdpt[idx3];
            if (pdpe & 1 == 0) continue;
            if (pdpe & (1 << 7) != 0) continue;
            const pd: *const paging.Table = @ptrFromInt(pdpe & paging.address_mask);
            var idx2: usize = 0;
            while (idx2 < paging.entries_per_table) : (idx2 += 1) {
                const pde = pd[idx2];
                if (pde & 1 == 0) continue;
                if (pde & (1 << 7) != 0) continue;
                const pt: *const paging.Table = @ptrFromInt(pde & paging.address_mask);
                frame_allocator.release(@intFromPtr(pt)) catch {};
            }
            frame_allocator.release(@intFromPtr(pd)) catch {};
        }
        frame_allocator.release(@intFromPtr(pdpt)) catch {};
    }
    frame_allocator.release(old_cr3 & paging.address_mask) catch {};
}
