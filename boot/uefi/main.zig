//! AzuraOS UEFI bootloader — stage 1 of the boot chain.
//!
//! Responsibilities of this stage:
//!   1. Bring up the COM1 serial port and emit a machine readable boot log.
//!   2. Discover the GOP framebuffer and paint a boot splash (visible proof).
//!   3. Read the kernel image (`azura-kernel.elf`) from the EFI System Partition.
//!   4. Validate and copy the kernel's PT_LOAD segments into RAM.
//!   5. Allocate the initial kernel stack and build the `boot_info` structure.
//!   6. Call ExitBootServices with the key of the final memory map.
//!   7. Jump to the kernel entry point with RDI = &boot_info.
//!
//! The bootloader does not touch the page tables: after the handover the
//! kernel still runs on the firmware's flat 64-bit mapping. Installing the
//! kernel's own page tables is M2.4 and is tracked in
//! docs/roadmap/milestones.md.

const std = @import("std");
const uefi = std.os.uefi;
const shared = @import("shared");
const build_options = @import("build_options");

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

/// How many times ExitBootServices is attempted before the bootloader gives
/// up. The UEFI specification allows the map to change between the key being
/// read and the call; a stale key is answered by taking a new snapshot, and
/// the loop is bounded so a broken firmware cannot hang the boot.
const max_exit_attempts: u32 = 4;

/// Upper bound for the memory map buffer, in bytes. A firmware that reports
/// more than this is not describing a machine this bootloader will boot.
const max_memory_map_bytes: usize = 8 * 1024 * 1024;

/// Upper bound for one memory map descriptor. The UEFI descriptor is 40 or
/// 48 bytes; anything this large is a broken size and must not be used as a
/// stride.
const max_memory_map_descriptor_size: usize = 4096;

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
    com1.write("[azura] === AzuraOS UEFI bootloader v0.1.0 (M2.2) ===\n");
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
    const stack_base = @intFromPtr(stack.ptr);
    const stack_top = stack_base + stack.len;
    com1.print("[azura] kernel stack: {d} bytes, base=0x{x} top=0x{x}\n", .{
        stack.len,
        stack_base,
        stack_top,
    });

    // --- 7. Boot information --------------------------------------------
    // Allocated from the firmware pool instead of living on the bootloader's
    // stack: the structure must survive the transition, and the stack it
    // would otherwise live on belongs to the firmware image, which is not
    // memory the kernel may rely on after ExitBootServices.
    const info_memory = boot_services.allocatePool(.loader_data, @sizeOf(shared.boot_info)) catch {
        com1.write("[azura] FATAL: cannot allocate the boot information\n");
        halt();
    };
    const info: *shared.boot_info = @ptrCast(@alignCast(info_memory.ptr));
    info.* = std.mem.zeroes(shared.boot_info);
    info.magic = shared.magic;
    info.version = shared.version;
    info.size = @sizeOf(shared.boot_info);
    info.kernel_entry = loaded.entry;
    info.kernel_start = loaded.start;
    info.kernel_end = loaded.end;
    info.stack_base = stack_base;
    info.stack_top = stack_top;
    info.framebuffer_present = if (framebuffer_info != null) 1 else 0;
    info.framebuffer = if (framebuffer_info) |fb| framebuffer.toBootAbi(fb) else std.mem.zeroes(shared.framebuffer);
    info.firmware_vendor = @intFromPtr(vendor);
    info.firmware_revision = uefi.system_table.firmware_revision;
    com1.print("[azura] boot information: {d} bytes at 0x{x}\n", .{
        @sizeOf(shared.boot_info),
        @intFromPtr(info),
    });

    // The splash is painted last, on purpose. The firmware console writes
    // at a cursor position this code does not control, so painting earlier
    // would let the console text land anywhere on top of the graphics. The
    // console line below is printed after the splash, which proves that the
    // text path is still alive on top of the graphics.
    //
    // Both writes happen BEFORE ExitBootServices: the console is a firmware
    // service, and no firmware service may be called afterwards.
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

    // --- 8. Final memory map, then ExitBootServices ---------------------
    // Every allocation is done. The map fetched here is the last one the
    // firmware produces before the first ExitBootServices attempt, and its
    // key is the one the call must see. Between this snapshot and the call
    // nothing allocates and no firmware service is called: either would
    // change the map and make the key stale. If the firmware rejects the
    // key anyway, leaveBootServices takes a new snapshot before retrying.
    var final_map = fetchMemoryMap(boot_services) orelse {
        com1.write("[azura] FATAL: cannot read the final memory map\n");
        halt();
    };
    com1.print("[azura] final memory map: {d} entries, key=0x{x}\n", .{
        final_map.count,
        @backingInt(final_map.key),
    });
    applyMemoryMap(info, final_map);

    jump_arguments = .{
        .entry = loaded.entry,
        .boot_info = @intFromPtr(info),
        .stack_top = stack_top,
    };

    leaveBootServices(boot_services, &final_map, info);
}

/// Copy the map into the boot information structure handed to the kernel.
fn applyMemoryMap(info: *shared.boot_info, map: MemoryMap) void {
    info.memory_map = @intFromPtr(map.ptr);
    info.memory_map_count = map.count;
    info.memory_map_descriptor_size = map.descriptor_size;
    info.memory_map_key = @intCast(@backingInt(map.key));
}

/// Take the machine away from the firmware and jump to the kernel.
///
/// `ExitBootServices` can fail with `EFI_INVALID_PARAMETER` when the memory
/// map changed after the key was read. The UEFI specification allows the map
/// to change between the two calls and requires the caller to fetch it again;
/// a bounded retry is the documented response, not an error path to give up
/// on immediately.
///
/// After a successful call the boot services pointer is dead: the loop below
/// only writes to COM1, which is direct port I/O, and then never returns.
fn leaveBootServices(
    boot_services: *uefi.tables.BootServices,
    map: *MemoryMap,
    info: *shared.boot_info,
) noreturn {
    var attempt: u32 = 1;
    while (attempt <= max_exit_attempts) : (attempt += 1) {
        com1.print("[azura] ExitBootServices: attempt {d}, key=0x{x}, entries={d}\n", .{
            attempt,
            @backingInt(map.key),
            map.count,
        });

        if (build_options.stale_map_key and attempt == 1) {
            // Test only: a pool allocation changes the memory map, so the
            // key read above is stale by the time the firmware sees it.
            _ = boot_services.allocatePool(.loader_data, 4096) catch {};
            com1.write("[azura] ExitBootServices: injected a stale key\n");
        }

        boot_services.exitBootServices(uefi.handle, map.key) catch |err| switch (err) {
            error.InvalidParameter => {
                com1.write("[azura] ExitBootServices: stale key, refreshing the memory map\n");
                const refreshed = fetchMemoryMap(boot_services) orelse {
                    com1.write("[azura] FATAL: cannot refresh the memory map for ExitBootServices\n");
                    halt();
                };
                map.* = refreshed;
                applyMemoryMap(info, refreshed);
                com1.print("[azura] final memory map: {d} entries, key=0x{x}\n", .{
                    refreshed.count,
                    @backingInt(refreshed.key),
                });
                continue;
            },
            else => {
                com1.print("[azura] FATAL: ExitBootServices failed: {s}\n", .{@errorName(err)});
                halt();
            },
        };

        // Success. From here on the firmware is gone: the boot services
        // pointer must not be used again, and neither may the console.
        info.boot_services_exited = 1;
        com1.write("[azura] ExitBootServices: success\n");
        com1.print("[azura] boot services exited, map key=0x{x}\n", .{@backingInt(map.key)});
        com1.write("[azura] jumping to the kernel entry point\n");
        jumpToKernel();
    }

    com1.write("[azura] FATAL: ExitBootServices did not succeed after the retry limit\n");
    halt();
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
    /// The key that belongs to the call which produced this map. It must be
    /// the one passed to ExitBootServices.
    key: uefi.tables.MemoryMapKey,
};

/// Read the firmware memory map into pool memory that is never released.
///
/// The buffer is sized from the size the firmware reports instead of a fixed
/// constant: a fixed size is either wasteful or wrong on a machine with a
/// larger map. The raw `_getMemoryMap` entry point is used instead of the
/// std wrapper because the wrapper divides the byte size by
/// `descriptor_size` before the caller can validate it, and a firmware that
/// reported zero would trap the bootloader. Here every value the firmware
/// writes is checked before it is used.
fn fetchMemoryMap(boot_services: *uefi.tables.BootServices) ?MemoryMap {
    var capacity: usize = 0;
    var attempt: u32 = 0;

    while (attempt < 4) : (attempt += 1) {
        var size: usize = capacity;
        var key: uefi.tables.MemoryMapKey = undefined;
        var descriptor_size: usize = 0;
        var descriptor_version: u32 = 0;

        // The first pass asks for the size with no buffer at all.
        var buffer: ?[]align(8) u8 = null;
        if (capacity != 0) {
            buffer = boot_services.allocatePool(.loader_data, capacity) catch return null;
        }

        const status = boot_services._getMemoryMap(
            &size,
            if (buffer) |b| b.ptr else null,
            &key,
            &descriptor_size,
            &descriptor_version,
        );

        switch (status) {
            .success => {
                const bytes = buffer orelse return null;
                if (descriptor_version != 1) return null;
                if (descriptor_size < @sizeOf(shared.memory_descriptor)) return null;
                if (descriptor_size > max_memory_map_descriptor_size) return null;
                if (size == 0 or size > bytes.len) return null;
                if (size % descriptor_size != 0) return null;
                const count = size / descriptor_size;
                if (count == 0 or count > 1 << 20) return null;
                return .{
                    .ptr = bytes.ptr,
                    .count = @intCast(count),
                    .descriptor_size = @intCast(descriptor_size),
                    .key = key,
                };
            },
            .buffer_too_small => {
                // The firmware wrote the size it needs into `size`. Two
                // descriptors of slack cover the map growing again between
                // this call and the one that succeeds.
                if (descriptor_size < @sizeOf(shared.memory_descriptor)) return null;
                if (descriptor_size > max_memory_map_descriptor_size) return null;
                if (size == 0 or size > max_memory_map_bytes) return null;
                capacity = size + 2 * descriptor_size;
                if (capacity > max_memory_map_bytes) return null;
                continue;
            },
            else => return null,
        }
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
            if (descriptor.type != @backingInt(shared.memory_type.conventional)) continue;
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
