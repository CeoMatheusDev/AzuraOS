//! Minimal, strict ELF64 loader for the AzuraOS kernel image.
//!
//! Security notes: this parser is the trust boundary between the firmware
//! and a binary that the bootloader did not build. It therefore accepts only
//! the narrowest possible shape of file (ELF64, little endian, x86_64,
//! ET_EXEC) and validates every offset and size against the actual buffer
//! length before touching it. Any inconsistency is a hard failure, never a
//! best-effort guess.
//!
//! The loader deliberately does NOT support:
//!   * ET_DYN / position independent images (no relocation support yet),
//!   * PT_INTERP (a kernel must not need a dynamic loader),
//!   * PT_DYNAMIC,
//!   * overlapping or out of order PT_LOAD segments.
//! Those are future work and each needs its own review.

const std = @import("std");

pub const Error = error{
    /// The buffer is too small to even hold an ELF header.
    Truncated,
    /// Missing the 0x7F 'E' 'L' 'F' magic.
    NotAnElf,
    /// EI_CLASS is not ELFCLASS64.
    NotElf64,
    /// EI_DATA is not ELFDATA2LSB.
    NotLittleEndian,
    /// e_machine is not EM_X86_64.
    NotX86_64,
    /// e_type is not ET_EXEC.
    NotExecutable,
    /// e_ehsize does not match the ELF64 header size.
    BadHeaderSize,
    /// e_phentsize does not match the ELF64 program header size.
    BadProgramHeaderSize,
    /// e_phnum is zero or the program header table is out of bounds.
    BadProgramHeaderTable,
    /// A PT_LOAD segment references bytes outside the file.
    SegmentOutOfFile,
    /// A PT_LOAD segment has memsz < filesz, or its address range overflows.
    SegmentBadSize,
    /// No PT_LOAD segment was present.
    NoLoadableSegment,
    /// The entry point is outside every loaded segment.
    EntryPointOutsideImage,
};

const elf_magic = "\x7fELF";

const ei_class = 4;
const ei_data = 5;

const elfclass64: u8 = 2;
const elfdata2lsb: u8 = 1;

const et_exec: u16 = 2;
const em_x86_64: u16 = 62;

const pt_load: u32 = 1;

const ehdr_size = 64;
const phdr_size = 56;

/// Summary of a successful load.
pub const LoadedImage = struct {
    /// ELF entry point (virtual address).
    entry: u64,
    /// Lowest physical address written by the loader.
    start: u64,
    /// Highest physical address written by the loader (exclusive).
    end: u64,
    /// Number of PT_LOAD segments copied.
    load_count: u32,
};

/// Parse the ELF header and program header table without loading anything.
///
/// Exposed separately so the bootloader can validate the image and report
/// precise diagnostics before it starts writing to memory.
pub fn inspect(bytes: []const u8) Error!Header {
    if (bytes.len < ehdr_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], elf_magic)) return error.NotAnElf;
    if (bytes[ei_class] != elfclass64) return error.NotElf64;
    if (bytes[ei_data] != elfdata2lsb) return error.NotLittleEndian;

    const header = Header{
        .type = readU16(bytes, 16),
        .machine = readU16(bytes, 18),
        .entry = readU64(bytes, 24),
        .phoff = readU64(bytes, 32),
        .phentsize = readU16(bytes, 54),
        .phnum = readU16(bytes, 56),
        .ehsize = readU16(bytes, 52),
    };

    if (header.type != et_exec) return error.NotExecutable;
    if (header.machine != em_x86_64) return error.NotX86_64;
    if (header.ehsize != ehdr_size) return error.BadHeaderSize;
    if (header.phentsize != phdr_size) return error.BadProgramHeaderSize;
    if (header.phnum == 0) return error.BadProgramHeaderTable;

    // The program header table must lie completely inside the file.
    const table_bytes = @as(u64, header.phnum) * @as(u64, header.phentsize);
    if (header.phoff > bytes.len) return error.BadProgramHeaderTable;
    if (table_bytes > bytes.len - header.phoff) return error.BadProgramHeaderTable;

    return header;
}

/// The subset of the ELF header this loader cares about.
pub const Header = struct {
    type: u16,
    machine: u16,
    entry: u64,
    phoff: u64,
    phentsize: u16,
    phnum: u16,
    ehsize: u16,
};

/// One PT_LOAD segment, validated.
pub const Segment = struct {
    offset: u64,
    vaddr: u64,
    filesz: u64,
    memsz: u64,
    flags: u32,
};

/// Collect and validate every PT_LOAD segment of the image.
///
/// The destination buffer is supplied by the caller on purpose: returning a
/// slice of a local array would leave the caller holding a pointer to dead
/// stack memory.
pub fn collectSegments(bytes: []const u8, header: Header, out: []Segment) Error![]Segment {
    var count: usize = 0;

    var index: u16 = 0;
    while (index < header.phnum) : (index += 1) {
        const base = header.phoff + @as(u64, index) * @as(u64, header.phentsize);
        const p_type = readU32(bytes, base);
        if (p_type != pt_load) continue;

        if (count == out.len) return error.BadProgramHeaderTable;

        const segment = Segment{
            .flags = readU32(bytes, base + 4),
            .offset = readU64(bytes, base + 8),
            .vaddr = readU64(bytes, base + 16),
            .filesz = readU64(bytes, base + 32),
            .memsz = readU64(bytes, base + 40),
        };

        if (segment.memsz < segment.filesz) return error.SegmentBadSize;
        // The file range must be inside the image.
        if (segment.offset > bytes.len) return error.SegmentOutOfFile;
        if (segment.filesz > bytes.len - segment.offset) return error.SegmentOutOfFile;
        // The memory range must not wrap around the address space.
        if (segment.memsz > std.math.maxInt(u64) - segment.vaddr) return error.SegmentBadSize;

        out[count] = segment;
        count += 1;
    }

    if (count == 0) return error.NoLoadableSegment;
    return out[0..count];
}

/// Check that the entry point lies inside one of the loaded segments.
///
/// Separated from `load` so it can be verified without touching physical
/// memory: `load` writes to absolute addresses and can therefore only be
/// exercised on real hardware (or in the QEMU boot test).
pub fn validateEntryPoint(header: Header, segments: []const Segment) Error!void {
    for (segments) |segment| {
        if (header.entry >= segment.vaddr and header.entry < segment.vaddr + segment.memsz) {
            return;
        }
    }
    return error.EntryPointOutsideImage;
}

/// Copy the PT_LOAD segments of `bytes` to their physical addresses.
///
/// The caller must have verified that the destination addresses are backed by
/// RAM; this function only guarantees that it never writes outside the
/// segment ranges it validated.
pub fn load(bytes: []const u8, header: Header, segments: []const Segment) Error!LoadedImage {
    try validateEntryPoint(header, segments);

    var lowest: u64 = std.math.maxInt(u64);
    var highest: u64 = 0;
    var loaded: u32 = 0;

    for (segments) |segment| {
        const source = bytes[@intCast(segment.offset)..][0..@intCast(segment.filesz)];

        // UEFI identity-maps RAM, so the physical address is directly
        // addressable. The kernel is linked at a low physical address.
        const destination: [*]u8 = @ptrFromInt(segment.vaddr);

        if (source.len > 0) {
            std.mem.copyForwards(u8, destination[0..source.len], source);
        }
        if (segment.memsz > segment.filesz) {
            @memset(destination[source.len..@intCast(segment.memsz - segment.filesz)], 0);
        }

        const seg_end = segment.vaddr + segment.memsz;
        if (segment.vaddr < lowest) lowest = segment.vaddr;
        if (seg_end > highest) highest = seg_end;
        loaded += 1;
    }

    return .{
        .entry = header.entry,
        .start = lowest,
        .end = highest,
        .load_count = loaded,
    };
}

// --- Little endian readers -------------------------------------------------
//
// The file is validated as little endian up front, so the reads below are
// plain byte combinations rather than endian-switching helpers.

fn readU16(bytes: []const u8, offset: u64) u16 {
    const i: usize = @intCast(offset);
    return @as(u16, bytes[i]) | (@as(u16, bytes[i + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: u64) u32 {
    const i: usize = @intCast(offset);
    return @as(u32, bytes[i]) |
        (@as(u32, bytes[i + 1]) << 8) |
        (@as(u32, bytes[i + 2]) << 16) |
        (@as(u32, bytes[i + 3]) << 24);
}

fn readU64(bytes: []const u8, offset: u64) u64 {
    const i: usize = @intCast(offset);
    return @as(u64, bytes[i]) |
        (@as(u64, bytes[i + 1]) << 8) |
        (@as(u64, bytes[i + 2]) << 16) |
        (@as(u64, bytes[i + 3]) << 24) |
        (@as(u64, bytes[i + 4]) << 32) |
        (@as(u64, bytes[i + 5]) << 40) |
        (@as(u64, bytes[i + 6]) << 48) |
        (@as(u64, bytes[i + 7]) << 56);
}

// --- Unit tests -------------------------------------------------------------

const testing = std.testing;

test "rejects a non ELF buffer" {
    const data: [128]u8 = @splat(0);
    try testing.expectError(error.NotAnElf, inspect(&data));
}

test "rejects a truncated header" {
    const data: [16]u8 = @splat(0);
    try testing.expectError(error.Truncated, inspect(&data));
}

test "rejects a 32 bit ELF" {
    var data: [128]u8 = @splat(0);
    @memcpy(data[0..4], elf_magic);
    data[ei_class] = 1; // ELFCLASS32
    data[ei_data] = elfdata2lsb;
    try testing.expectError(error.NotElf64, inspect(&data));
}

test "rejects a big endian ELF" {
    var data: [128]u8 = @splat(0);
    @memcpy(data[0..4], elf_magic);
    data[ei_class] = elfclass64;
    data[ei_data] = 2; // ELFDATA2MSB
    try testing.expectError(error.NotLittleEndian, inspect(&data));
}

test "rejects a foreign machine type" {
    var data: [128]u8 = @splat(0);
    @memcpy(data[0..4], elf_magic);
    data[ei_class] = elfclass64;
    data[ei_data] = elfdata2lsb;
    writeU16(&data, 16, et_exec);
    writeU16(&data, 18, 183); // EM_AARCH64
    writeU16(&data, 52, ehdr_size);
    writeU16(&data, 54, phdr_size);
    writeU16(&data, 56, 1);
    try testing.expectError(error.NotX86_64, inspect(&data));
}

test "rejects a program header table outside the file" {
    var data: [128]u8 = @splat(0);
    @memcpy(data[0..4], elf_magic);
    data[ei_class] = elfclass64;
    data[ei_data] = elfdata2lsb;
    writeU16(&data, 16, et_exec);
    writeU16(&data, 18, em_x86_64);
    writeU16(&data, 52, ehdr_size);
    writeU16(&data, 54, phdr_size);
    writeU16(&data, 56, 4);
    writeU64(&data, 32, 4096); // e_phoff far past the end
    try testing.expectError(error.BadProgramHeaderTable, inspect(&data));
}

test "rejects a segment whose file range is out of bounds" {
    var data: [256]u8 = @splat(0);
    @memcpy(data[0..4], elf_magic);
    data[ei_class] = elfclass64;
    data[ei_data] = elfdata2lsb;
    writeU16(&data, 16, et_exec);
    writeU16(&data, 18, em_x86_64);
    writeU16(&data, 52, ehdr_size);
    writeU16(&data, 54, phdr_size);
    writeU16(&data, 56, 1);
    writeU64(&data, 32, ehdr_size);
    // PT_LOAD with filesz far beyond the buffer.
    writeU32(&data, ehdr_size, pt_load);
    writeU64(&data, ehdr_size + 8, 0); // p_offset
    writeU64(&data, ehdr_size + 16, 0x100000); // p_vaddr
    writeU64(&data, ehdr_size + 32, 0x10000); // p_filesz
    writeU64(&data, ehdr_size + 40, 0x10000); // p_memsz

    const header = try inspect(&data);
    var buffer: [8]Segment = undefined;
    try testing.expectError(error.SegmentOutOfFile, collectSegments(&data, header, &buffer));
}

test "accepts a well formed single segment image" {
    var data: [256]u8 = @splat(0);
    @memcpy(data[0..4], elf_magic);
    data[ei_class] = elfclass64;
    data[ei_data] = elfdata2lsb;
    writeU16(&data, 16, et_exec);
    writeU16(&data, 18, em_x86_64);
    writeU16(&data, 52, ehdr_size);
    writeU16(&data, 54, phdr_size);
    writeU16(&data, 56, 1);
    writeU64(&data, 32, ehdr_size);
    writeU64(&data, 24, 0x100000 + 0x10); // e_entry inside the segment
    writeU32(&data, ehdr_size, pt_load);
    writeU64(&data, ehdr_size + 8, 128); // p_offset, past the header table
    writeU64(&data, ehdr_size + 16, 0x100000);
    writeU64(&data, ehdr_size + 32, 0x40);
    writeU64(&data, ehdr_size + 40, 0x40);
    data[128] = 0xaa;
    data[129] = 0xbb;

    const header = try inspect(&data);
    var buffer: [8]Segment = undefined;
    const segments = try collectSegments(&data, header, &buffer);
    try testing.expectEqual(@as(usize, 1), segments.len);
    try testing.expectEqual(@as(u64, 0x100000), segments[0].vaddr);
    try testing.expectEqual(@as(u64, 0x40), segments[0].filesz);
    // The segment data must still be valid after the parser returned: the
    // buffer belongs to the caller, never to a local array of the parser.
    try testing.expectEqual(@as(u64, 0x40), buffer[0].filesz);
    try testing.expectEqual(@as(u64, 0x40), buffer[0].memsz);
    try testing.expectEqual(@as(u64, 128), buffer[0].offset);
    try validateEntryPoint(header, segments);
}

test "rejects an entry point outside every segment" {
    var data: [256]u8 = @splat(0);
    @memcpy(data[0..4], elf_magic);
    data[ei_class] = elfclass64;
    data[ei_data] = elfdata2lsb;
    writeU16(&data, 16, et_exec);
    writeU16(&data, 18, em_x86_64);
    writeU16(&data, 52, ehdr_size);
    writeU16(&data, 54, phdr_size);
    writeU16(&data, 56, 1);
    writeU64(&data, 32, ehdr_size);
    writeU64(&data, 24, 0x900000); // entry far away from the segment
    writeU32(&data, ehdr_size, pt_load);
    writeU64(&data, ehdr_size + 8, 128);
    writeU64(&data, ehdr_size + 16, 0x100000);
    writeU64(&data, ehdr_size + 32, 0x40);
    writeU64(&data, ehdr_size + 40, 0x40);

    const header = try inspect(&data);
    var buffer: [8]Segment = undefined;
    const segments = try collectSegments(&data, header, &buffer);
    try testing.expectError(error.EntryPointOutsideImage, validateEntryPoint(header, segments));
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    writeU32(bytes, offset, @truncate(value));
    writeU32(bytes, offset + 4, @truncate(value >> 32));
}
