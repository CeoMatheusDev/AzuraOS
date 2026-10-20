//! AzuraOS UEFI bootloader — stage 1 of the boot chain.
//!
//! Responsibilities of this stage (M1 scope):
//!   1. Bring up the COM1 serial port and emit a machine readable boot log.
//!   2. Discover the GOP framebuffer and paint a boot splash (visible proof).
//!   3. Read the kernel image (`azura-kernel.elf`) from the EFI System Partition.
//!   4. Validate and copy the kernel's PT_LOAD segments into RAM.
//!   5. Allocate the initial kernel stack and build the `boot_info` structure.
//!   6. Jump to the kernel entry point with RDI = &boot_info.
//!
//! The bootloader does NOT call ExitBootServices and does NOT touch the
//! page tables: the kernel still runs inside the firmware's flat 64-bit
//! environment. Taking over the machine (own GDT, own page tables, memory
//! map handover) is M2 work and is tracked in docs/roadmap/milestones.md.

const std = @import("std");
const uefi = std.os.uefi;
const shared = @import("shared");

const console = @import("console.zig");
const elf_loader = @import("elf_loader.zig");
const framebuffer = @import("framebuffer.zig");
const com1 = @import("com1");
const shared_framebuffer = @import("framebuffer");

/// Name of the kernel image inside the EFI System Partition.
const kernel_file_name = "azura-kernel.elf";

/// Size of the initial kernel stack (16 KiB).
const kernel_stack_size = 16 * 1024;

/// Upper bound for the program header table we are willing to parse.
const max_program_headers = 64;

/// Arguments handed to the kernel in a way that does not depend on the
/// register allocator: the values live in memory and are loaded explicitly.
const JumpArguments = extern struct {
    entry: u64,
    boot_info: u64,
    stack_top: u64,
};

var jump_arguments: JumpArguments = undefined;

pub fn main() void {
    com1.init();
    com1.write("[azura] === AzuraOS UEFI bootloader v0.1.0 (M1) ===\n");
    console.print("AzuraOS bootloader v0.1.0\n", .{});

    const boot_services = uefi.system_table.boot_services orelse {
        com1.write("[azura] FATAL: no boot services available\n");
        halt();
    };

    // --- 1. Firmware identification -------------------------------------
    const vendor = uefi.system_table.firmware_vendor;
    var vendor_buffer: [64]u8 = undefined;
    com1.print("[azura] firmware vendor: {s}\n", .{utf16ToAscii(vendor, &vendor_buffer)});

    // --- 2. Framebuffer -------------------------------------------------
    var framebuffer_info: ?framebuffer.Info = null;
    if (framebuffer.init()) |info| {
        framebuffer_info = info;
        com1.print(
            "[azura] framebuffer: {d}x{d} stride={d} bytes={d}\n",
            .{ info.width, info.height, info.stride, info.size },
        );
    } else {
        com1.write("[azura] framebuffer: NONE (GOP not found)\n");
    }

    // --- 3. Kernel image ------------------------------------------------
    // The pool allocations made from here on are never released: the
    // bootloader never returns from EfiMain, and the firmware only reclaims
    // pool memory when the image is unloaded.
    const image_bytes = readKernelImage(boot_services) catch |err| {
        com1.print("[azura] FATAL: cannot read {s}: {s}\n", .{ kernel_file_name, @errorName(err) });
        halt();
    };
    com1.print("[azura] kernel image: {d} bytes\n", .{image_bytes.len});

    const header = elf_loader.inspect(image_bytes) catch |err| {
        com1.print("[azura] FATAL: invalid kernel ELF: {s}\n", .{@errorName(err)});
        halt();
    };

    var segment_buffer: [max_program_headers]elf_loader.Segment = undefined;
    const segments = elf_loader.collectSegments(image_bytes, header, &segment_buffer) catch |err| {
        com1.print("[azura] FATAL: invalid kernel ELF segments: {s}\n", .{@errorName(err)});
        halt();
    };

    // --- 4. Memory map, to prove the load range is real RAM -------------
    const memory_map = fetchMemoryMap(boot_services) orelse {
        com1.write("[azura] FATAL: cannot read the firmware memory map\n");
        halt();
    };
    com1.print("[azura] memory map: {d} entries\n", .{memory_map.count});

    // --- 5. Load the kernel ---------------------------------------------
    for (segments) |segment| {
        if (!isUsableRange(memory_map, segment.vaddr, segment.memsz)) {
            com1.print(
                "[azura] FATAL: kernel segment at 0x{x} ({d} bytes) is not in conventional memory\n",
                .{ segment.vaddr, segment.memsz },
            );
            dumpMemoryMap(memory_map, 24);
            halt();
        }
    }

    const loaded = elf_loader.load(image_bytes, header, segments) catch |err| {
        com1.print("[azura] FATAL: cannot load kernel: {s}\n", .{@errorName(err)});
        halt();
    };
    com1.print(
        "[azura] kernel loaded: entry=0x{x} range=0x{x}..0x{x} segments={d}\n",
        .{ loaded.entry, loaded.start, loaded.end, loaded.load_count },
    );

    // --- 6. Initial stack -----------------------------------------------
    const stack = boot_services.allocatePool(.loader_data, kernel_stack_size) catch {
        com1.write("[azura] FATAL: cannot allocate the kernel stack\n");
        halt();
    };
    const stack_top = @intFromPtr(stack.ptr) + stack.len;
    com1.print("[azura] kernel stack: {d} bytes, top=0x{x}\n", .{ stack.len, stack_top });

    // --- 7. Final memory map (after every allocation) -------------------
    const final_map = fetchMemoryMap(boot_services) orelse memory_map;
    com1.print("[azura] final memory map: {d} entries\n", .{final_map.count});

    // --- 8. Hand over ---------------------------------------------------
    var info: shared.boot_info = .{
        .magic = shared.magic,
        .version = shared.version,
        .size = @sizeOf(shared.boot_info),
        .kernel_entry = loaded.entry,
        .kernel_start = loaded.start,
        .kernel_end = loaded.end,
        .stack_top = stack_top,
        .memory_map = @intFromPtr(final_map.ptr),
        .memory_map_count = final_map.count,
        .memory_map_descriptor_size = final_map.descriptor_size,
        .framebuffer_present = if (framebuffer_info != null) 1 else 0,
        ._reserved0 = 0,
        .framebuffer = if (framebuffer_info) |fb| framebuffer.toBootAbi(fb) else std.mem.zeroes(shared.framebuffer),
        .firmware_vendor = @intFromPtr(vendor),
        .firmware_revision = uefi.system_table.firmware_revision,
        ._reserved1 = 0,
    };

    com1.write("[azura] jumping to the kernel entry point\n");

    // The splash is painted last, on purpose. The firmware console writes
    // at a cursor position this code does not control, so painting earlier
    // would let the console text land anywhere on top of the graphics. The
    // console line below is printed after the splash, which proves that the
    // text path is still alive on top of the graphics.
    if (framebuffer_info) |fb| {
        framebuffer.drawSplash(fb);
    }
    console.print("AzuraOS: handing over to the kernel\n", .{});

    // The checksum of the framebuffer as it is now. It is computed after
    // every write, including the console text above, because the console
    // draws into the same framebuffer. The kernel recomputes it after the
    // handover and the automated test compares the two values.
    if (framebuffer_info) |fb| {
        const sum = shared_framebuffer.checksum(fb.base, fb.stride, fb.height);
        com1.print("[azura] framebuffer checksum: 0x{x}\n", .{sum});
    }

    jump_arguments = .{
        .entry = loaded.entry,
        .boot_info = @intFromPtr(&info),
        .stack_top = stack_top,
    };

    jumpToKernel();
}

// --- Boot services helpers --------------------------------------------------

/// Copy a NUL terminated UTF-16 string into an ASCII buffer.
///
/// The Zig 0.17 formatter cannot print a UTF-16 slice, and the firmware
/// vendor string is the only UTF-16 value the bootloader reports. Non ASCII
/// code units are replaced with '?' so the log stays byte deterministic.
fn utf16ToAscii(source: [*:0]const u16, buffer: []u8) []const u8 {
    var index: usize = 0;
    while (index < buffer.len and source[index] != 0) : (index += 1) {
        buffer[index] = if (source[index] < 0x80) @as(u8, @truncate(source[index])) else '?';
    }
    return buffer[0..index];
}

const MemoryMap = struct {
    ptr: [*]const u8,
    count: u32,
    descriptor_size: u32,
};

/// Read the firmware memory map into pool memory that is never released.
fn fetchMemoryMap(boot_services: *uefi.tables.BootServices) ?MemoryMap {
    // The firmware may grow the map between calls, so retry with a larger
    // buffer when the first attempt reports "buffer too small".
    var size: usize = 32 * 1024;
    while (size <= 1024 * 1024) : (size *= 2) {
        const buffer = boot_services.allocatePool(.loader_data, size) catch return null;
        const map = boot_services.getMemoryMap(buffer) catch |err| switch (err) {
            error.BufferTooSmall => continue,
            else => return null,
        };
        return .{
            .ptr = map.ptr,
            .count = @intCast(map.info.len),
            .descriptor_size = @intCast(map.info.descriptor_size),
        };
    }
    return null;
}

/// Check that [base, base+length) is entirely covered by conventional memory.
///
/// The firmware splits conventional memory into several regions, so the check
/// merges the coverage instead of requiring the range to fit inside a single
/// region.
fn isUsableRange(memory_map: MemoryMap, base: u64, length: u64) bool {
    if (length == 0) return true;
    const end = base + length;

    var covered = base;
    var progress = true;
    while (covered < end and progress) {
        progress = false;
        var index: usize = 0;
        while (index < memory_map.count) : (index += 1) {
            const descriptor = descriptorAt(memory_map, index);
            if (descriptor.type != @intFromEnum(shared.memory_type.conventional)) continue;
            const region_start = descriptor.physical_start;
            const region_end = region_start + descriptor.number_of_pages * 4096;
            if (region_start <= covered and region_end > covered) {
                covered = region_end;
                progress = true;
            }
        }
    }
    return covered >= end;
}

/// Read the n-th memory map descriptor of the firmware map.
fn descriptorAt(memory_map: MemoryMap, index: usize) *const shared.memory_descriptor {
    const offset = index * memory_map.descriptor_size;
    return @ptrCast(@alignCast(memory_map.ptr + offset));
}

/// Print the memory map. Used for diagnostics when a load range is refused.
fn dumpMemoryMap(memory_map: MemoryMap, limit: usize) void {
    var index: usize = 0;
    while (index < memory_map.count and index < limit) : (index += 1) {
        const descriptor = descriptorAt(memory_map, index);
        com1.print("[azura]   map[{d}] {s} phys=0x{x} pages={d}\n", .{
            index,
            shared.memoryTypeName(descriptor.type),
            descriptor.physical_start,
            descriptor.number_of_pages,
        });
    }
}

/// Reasons the kernel image could not be read. Kept distinct so the boot log
/// says exactly what went wrong instead of a generic failure.
pub const ImageError = error{
    /// No EFI_SIMPLE_FILE_SYSTEM protocol: the firmware did not expose a
    /// readable volume.
    NoFileSystem,
    /// The volume could not be opened (no media, corrupted, ...).
    NoVolume,
    /// The volume is readable but the kernel file is not on it.
    FileNotFound,
    /// The file exists but is empty.
    EmptyFile,
    /// The firmware could not allocate memory for the image.
    OutOfMemory,
    /// The file could not be read completely.
    ReadFailed,
};

/// Read the kernel image from the EFI System Partition.
fn readKernelImage(boot_services: *uefi.tables.BootServices) ImageError![]u8 {
    const SimpleFileSystem = uefi.protocol.SimpleFileSystem;

    const handles = (boot_services.locateHandleBuffer(.{
        .by_protocol = &SimpleFileSystem.guid,
    }) catch return error.NoFileSystem) orelse return error.NoFileSystem;

    var saw_volume = false;

    for (handles) |handle| {
        const fs = boot_services.openProtocol(SimpleFileSystem, handle, .{
            .get_protocol = .{},
        }) catch continue;
        if (fs == null) continue;

        const root = fs.?.openVolume() catch continue;
        saw_volume = true;
        defer root.close() catch {};

        var name: [kernel_file_name.len + 1]u16 = undefined;
        for (kernel_file_name, 0..) |c, i| name[i] = c;
        name[kernel_file_name.len] = 0;

        const file = root.open(@ptrCast(&name), .read, .{}) catch continue;
        defer file.close() catch {};

        // The file size is taken from EFI_FILE_INFO. File.readSize() cannot
        // be used: it issues a zero length read, and OVMF's FAT driver
        // answers that with "success, 0 bytes" instead of the file size.
        const info_size = file.getInfoSize(.file) catch return error.ReadFailed;
        if (info_size == 0) return error.ReadFailed;
        var info_buffer: [512]u8 align(8) = undefined;
        if (info_size > info_buffer.len) return error.ReadFailed;
        const file_info = file.getInfo(.file, info_buffer[0..info_size]) catch return error.ReadFailed;
        const size = file_info.file_size;
        if (size == 0) return error.EmptyFile;
        if (size > 64 * 1024 * 1024) return error.EmptyFile;

        const buffer = boot_services.allocatePool(.loader_data, size) catch return error.OutOfMemory;
        const read = file.read(buffer) catch return error.ReadFailed;
        if (read != size) return error.ReadFailed;

        return buffer;
    }

    return if (saw_volume) error.FileNotFound else error.NoVolume;
}

// --- Control transfer --------------------------------------------------------

/// Jump to the kernel. Never returns.
///
/// The register values are loaded from a static structure so the result does
/// not depend on how the compiler allocates the inline assembly operands.
fn jumpToKernel() noreturn {
    asm volatile (
        \\ cli
        \\ movq %[args], %%rax
        \\ movq 0(%%rax), %%rcx     // kernel entry point
        \\ movq 8(%%rax), %%rdi     // &boot_info
        \\ movq 16(%%rax), %%rsp    // initial kernel stack pointer
        \\ jmpq *%%rcx
        :
        : [args] "r" (&jump_arguments),
        : .{ .memory = true });
    unreachable;
}

/// Stop the machine in a controlled way when the boot cannot continue.
///
/// Interrupts are disabled and the CPU is put into a halt loop; the firmware
/// watchdog is not armed, so the machine stays in this state until the test
/// harness terminates QEMU.
fn halt() noreturn {
    com1.write("[azura] FATAL: boot aborted, halting\n");
    console.print("BOOT ABORTED\n", .{});
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}
