//! Physical frame allocator.
//!
//! The unit of allocation is a 4 KiB page frame. Every frame below
//! `max_physical_address` has one bit in a bitmap: 1 means "used or
//! reserved", 0 means "free". The bitmap starts with every bit set; the
//! kernel frees the descriptors the memory policy allows and then reserves
//! the ranges that the map cannot express (the kernel image, for example;
//! see ADR-0007).
//!
//! Why a bitmap and not a free list or a buddy allocator:
//!
//!   * it has no metadata per free frame and no pointer to corrupt;
//!   * allocation and release are O(number of frames) in the worst case but
//!     effectively O(1) with the rotating hint, and the code is small enough
//!     to be verified on the host;
//!   * fragmentation is not a concern yet: M2.3 allocates single frames and
//!     M2.4 will decide how they are mapped.
//!
//! The allocator is pure bookkeeping: it never dereferences the addresses it
//! hands out. The caller is responsible for the mapping. In M2.3 the kernel
//! still runs on the firmware's identity map, so a frame below the firmware's
//! mapped RAM is directly writable; the boot self-test relies on that and the
//! limitation is recorded in ADR-0009.
//!
//! Invariants:
//!   * `bitmap.len` is exactly `ceil(frame_count / 8)`;
//!   * bits at or beyond `frame_count` in the last byte are 1;
//!   * `free_frames` equals the number of zero bits below `frame_count`;
//!   * `hint` is always a valid frame index when `frame_count` is non-zero.

const std = @import("std");

/// Size of one physical frame.
pub const page_size: u64 = 4096;

/// Highest physical address the bitmap covers. Memory above this limit is
/// ignored by M2.3 and reported at boot; the limit keeps the static bitmap at
/// 128 KiB for a 4 GiB address space.
pub const max_physical_address: u64 = 4 * 1024 * 1024 * 1024;

/// Number of frames covered by `max_physical_address`.
pub const max_frames: usize = max_physical_address / page_size;

/// Size of the bitmap for `max_frames`, in bytes (one bit per frame).
pub const max_bitmap_bytes: usize = max_frames / 8;

pub const Error = error{
    /// The frame count or the bitmap is empty, or the bitmap is too small.
    InvalidAddress,
    /// The address is unaligned or outside the covered range.
    OutOfRange,
    /// The frame was already free when `release` was called.
    AlreadyFree,
};

pub const Stats = struct {
    total: usize,
    free: usize,
    used: usize,
};

/// A bitmap frame allocator over a caller-provided buffer.
///
/// The buffer is not owned by the allocator: the kernel keeps it in `.bss`
/// and the host tests keep it on the stack.
pub const Allocator = struct {
    bitmap: []u8,
    frame_count: usize,
    free_frames: usize,
    /// Where the next scan starts. It moves forward after an allocation and
    /// back to the lowest released frame after a release, so a free followed
    /// by an allocation reuses the same frame instead of scanning the whole
    /// bitmap.
    hint: usize,

    /// Prepare an allocator whose frames are all used.
    ///
    /// `bitmap` must have room for `frame_count` bits. The extra bits in the
    /// last byte are set, so a scan can never observe them as free.
    pub fn init(bitmap: []u8, frame_count: usize) Error!Allocator {
        if (frame_count == 0 or bitmap.len == 0) return error.InvalidAddress;
        if (frame_count > bitmap.len * 8) return error.InvalidAddress;

        const used_bytes = (frame_count + 7) / 8;
        if (used_bytes > bitmap.len) return error.InvalidAddress;

        @memset(bitmap[0..used_bytes], 0xff);
        return .{
            .bitmap = bitmap[0..used_bytes],
            .frame_count = frame_count,
            .free_frames = 0,
            .hint = 0,
        };
    }

    pub fn stats(self: *const Allocator) Stats {
        return .{
            .total = self.frame_count,
            .free = self.free_frames,
            .used = self.frame_count - self.free_frames,
        };
    }

    /// Highest byte address covered by the allocator.
    pub fn capacityBytes(self: *const Allocator) u64 {
        return @as(u64, self.frame_count) * page_size;
    }

    /// Whether the frame that contains `address` is used or reserved.
    /// Unaligned and out-of-range addresses count as used (not allocatable).
    pub fn isUsed(self: *const Allocator, address: u64) bool {
        const index = self.frameIndex(address) orelse return true;
        return self.isFrameUsed(index);
    }

    /// Free every frame completely covered by `[start, end)`.
    ///
    /// Ranges are clipped to the covered address space and aligned inwards:
    /// a partially covered frame is not freed. Calling this twice is
    /// harmless; a frame that is already free does not change the count.
    pub fn markFreeRange(self: *Allocator, start: u64, end: u64) void {
        const range = self.coveredRange(start, end) orelse return;
        var index = range.start;
        while (index < range.end) : (index += 1) {
            self.setFrameUsed(index, false);
        }
    }

    /// Mark every frame touched by `[start, end)` as used.
    ///
    /// Unlike `markFreeRange`, this aligns outwards: a partially touched
    /// frame is reserved, never handed out. Reserving is idempotent.
    pub fn reserveRange(self: *Allocator, start: u64, end: u64) void {
        const range = self.touchedRange(start, end) orelse return;
        var index = range.start;
        while (index < range.end) : (index += 1) {
            self.setFrameUsed(index, true);
        }
    }

    /// Allocate the next free frame, or null when the pool is exhausted.
    ///
    /// The scan starts at the hint and wraps once. A successful allocation
    /// advances the hint, so a sequence of allocations does not rescan the
    /// already allocated prefix.
    pub fn allocate(self: *Allocator) ?u64 {
        if (self.free_frames == 0) return null;

        var scanned: usize = 0;
        var index = self.hint;
        while (scanned < self.frame_count) : (scanned += 1) {
            if (!self.isFrameUsed(index)) {
                self.setFrameUsed(index, true);
                self.hint = if (index + 1 == self.frame_count) 0 else index + 1;
                return @as(u64, index) * page_size;
            }
            index += 1;
            if (index == self.frame_count) index = 0;
        }
        return null;
    }

    /// Return a frame to the pool.
    ///
    /// The address must be page aligned and inside the covered range, and the
    /// frame must currently be used. Double frees and unaligned releases are
    /// errors, not silent no-ops: a caller that gets either wrong has a
    /// bookkeeping bug that would otherwise corrupt the pool.
    ///
    /// The bitmap records "used" and "free", not "allocated by a caller" and
    /// "reserved by the policy". The caller must therefore never release a
    /// frame it did not receive from `allocate`; the kernel reserves ranges
    /// before it hands the allocator to anyone and the boot self-test only
    /// releases its own frames.
    pub fn release(self: *Allocator, address: u64) Error!void {
        if (address % page_size != 0) return error.OutOfRange;
        const index64 = address / page_size;
        if (index64 >= self.frame_count) return error.OutOfRange;

        const index: usize = @intCast(index64);
        if (!self.isFrameUsed(index)) return error.AlreadyFree;

        self.setFrameUsed(index, false);
        if (index < self.hint) self.hint = index;
    }

    fn frameIndex(self: *const Allocator, address: u64) ?usize {
        if (address % page_size != 0) return null;
        const index64 = address / page_size;
        if (index64 >= self.frame_count) return null;
        return @intCast(index64);
    }

    fn isFrameUsed(self: *const Allocator, index: usize) bool {
        return self.bitmap[index / 8] & bitFor(index) != 0;
    }

    fn setFrameUsed(self: *Allocator, index: usize, used: bool) void {
        const mask = bitFor(index);
        const byte = &self.bitmap[index / 8];
        const was_used = byte.* & mask != 0;
        if (used == was_used) return;

        if (used) {
            byte.* |= mask;
            self.free_frames -= 1;
        } else {
            byte.* &= ~mask;
            self.free_frames += 1;
        }
    }

    const FrameRange = struct {
        start: usize,
        end: usize,
    };

    /// Frames completely covered by the range, aligned inwards.
    fn coveredRange(self: *const Allocator, start: u64, end: u64) ?FrameRange {
        if (end <= start) return null;

        const capacity = self.capacityBytes();
        const clipped_start = @min(start, capacity);
        const clipped_end = @min(end, capacity);
        if (clipped_end <= clipped_start) return null;

        const first = ceilDiv(clipped_start, page_size);
        const last = clipped_end / page_size;
        if (last <= first) return null;

        return .{
            .start = @intCast(first),
            .end = @intCast(@min(last, self.frame_count)),
        };
    }

    /// Frames touched by the range, aligned outwards.
    fn touchedRange(self: *const Allocator, start: u64, end: u64) ?FrameRange {
        if (end <= start) return null;

        const capacity = self.capacityBytes();
        const clipped_start = @min(start, capacity);
        const clipped_end = @min(end, capacity);
        if (clipped_end <= clipped_start) return null;

        const first = clipped_start / page_size;
        const last = ceilDiv(clipped_end, page_size);
        if (last <= first) return null;

        return .{
            .start = @intCast(first),
            .end = @intCast(@min(last, self.frame_count)),
        };
    }
};

fn bitFor(index: usize) u8 {
    return @as(u8, 1) << @as(u3, @intCast(index % 8));
}

fn ceilDiv(value: u64, divisor: u64) u64 {
    return value / divisor + @intFromBool(value % divisor != 0);
}

// --- Unit tests -------------------------------------------------------------

const testing = std.testing;

test "init marks every frame used" {
    var bitmap: [16]u8 = undefined;
    var allocator = try Allocator.init(&bitmap, 128);

    try testing.expectEqual(@as(usize, 128), allocator.stats().total);
    try testing.expectEqual(@as(usize, 0), allocator.stats().free);
    try testing.expectEqual(@as(usize, 128), allocator.stats().used);
    try testing.expect(allocator.isUsed(0));
    try testing.expect(allocator.isUsed(127));
    try testing.expect(allocator.allocate() == null);
}

test "init rejects an empty bitmap and an undersized buffer" {
    var bitmap: [2]u8 = undefined;
    try testing.expectError(error.InvalidAddress, Allocator.init(&bitmap, 0));
    try testing.expectError(error.InvalidAddress, Allocator.init(&bitmap, 17));
    try testing.expectError(error.InvalidAddress, Allocator.init(bitmap[0..0], 1));
}

test "free, allocate and release reuse the same frame" {
    var bitmap: [4]u8 = undefined;
    var allocator = try Allocator.init(&bitmap, 32);
    allocator.markFreeRange(0x1000, 0x4000);

    try testing.expectEqual(@as(usize, 3), allocator.stats().free);
    try testing.expectEqual(@as(u64, 0x1000), allocator.allocate().?);
    try testing.expectEqual(@as(u64, 0x2000), allocator.allocate().?);
    try testing.expectEqual(@as(u64, 0x3000), allocator.allocate().?);
    try testing.expect(allocator.allocate() == null);
    try testing.expectEqual(@as(usize, 0), allocator.stats().free);

    try allocator.release(0x2000);
    try testing.expectEqual(@as(usize, 1), allocator.stats().free);
    try testing.expect(!allocator.isUsed(0x2000));
    try testing.expectEqual(@as(u64, 0x2000), allocator.allocate().?);
    try testing.expectEqual(@as(usize, 0), allocator.stats().free);
}

test "release rejects unaligned, out of range and double frees" {
    var bitmap: [4]u8 = undefined;
    var allocator = try Allocator.init(&bitmap, 32);
    // The covered capacity is 32 * 4096 = 0x20000.
    allocator.markFreeRange(0, 32 * page_size);

    try testing.expectError(error.OutOfRange, allocator.release(0x1001));
    try testing.expectError(error.OutOfRange, allocator.release(0x20000));
    try testing.expectError(error.OutOfRange, allocator.release(0xffff_ffff_ffff_f000));

    const address = allocator.allocate().?;
    try allocator.release(address);
    try testing.expectError(error.AlreadyFree, allocator.release(address));
}

test "reserve aligns outwards and wins over a free range" {
    var bitmap: [4]u8 = undefined;
    var allocator = try Allocator.init(&bitmap, 32);
    allocator.markFreeRange(0, 32 * page_size);
    try testing.expectEqual(@as(usize, 32), allocator.stats().free);

    // Frames 1 and 2 are touched: the start is inside frame 1 and the end is
    // one byte inside frame 2.
    allocator.reserveRange(0x1001, 0x2001);
    try testing.expectEqual(@as(usize, 30), allocator.stats().free);
    try testing.expect(allocator.isUsed(0x1000));
    try testing.expect(allocator.isUsed(0x2000));
    try testing.expect(!allocator.isUsed(0x3000));

    // Reserving again is a no-op.
    allocator.reserveRange(0x1001, 0x2001);
    try testing.expectEqual(@as(usize, 30), allocator.stats().free);
}

test "free aligns inwards and does not release partial frames" {
    var bitmap: [1]u8 = undefined;
    var allocator = try Allocator.init(&bitmap, 8);

    // Frame 0 is completely covered; frame 1 ends at 4097, so it is only
    // partially covered and must stay used.
    allocator.markFreeRange(0, 4097);
    try testing.expectEqual(@as(usize, 1), allocator.stats().free);
    try testing.expect(!allocator.isUsed(0));
    try testing.expect(allocator.isUsed(4096));

    // An empty range changes nothing.
    allocator.markFreeRange(8192, 8192);
    try testing.expectEqual(@as(usize, 1), allocator.stats().free);
}

test "ranges are clipped to the covered capacity" {
    var bitmap: [2]u8 = undefined;
    var allocator = try Allocator.init(&bitmap, 16);
    // 16 frames cover 64 KiB.
    allocator.markFreeRange(0, 1 * 1024 * 1024);
    try testing.expectEqual(@as(usize, 16), allocator.stats().free);

    allocator.reserveRange(0, 1 * 1024 * 1024);
    try testing.expectEqual(@as(usize, 0), allocator.stats().free);

    allocator.markFreeRange(0xffff_ffff_ffff_f000, 0xffff_ffff_ffff_ffff);
    try testing.expectEqual(@as(usize, 0), allocator.stats().free);
}

test "stress: exhaust, release and reuse without overlap" {
    // 2048 bytes = 16384 frames = 64 MiB.
    var bitmap: [2048]u8 = undefined;
    var allocator = try Allocator.init(&bitmap, 16 * 1024);
    allocator.markFreeRange(0, 64 * 1024 * 1024);
    // The kernel image and a loader range, in the same layout the kernel
    // reserves at boot.
    allocator.reserveRange(1024 * 1024, 2 * 1024 * 1024);
    allocator.reserveRange(3 * 1024 * 1024, 3 * 1024 * 1024 + 8192);

    const initial_free = allocator.stats().free;
    try testing.expectEqual(@as(usize, 16 * 1024 - 256 - 2), initial_free);

    var seen: [2048]u8 = undefined;
    @memset(&seen, 0);
    var count: usize = 0;
    while (allocator.allocate()) |address| {
        try testing.expectEqual(@as(u64, 0), address % page_size);
        const index: usize = @intCast(address / page_size);
        try testing.expect(index < 16 * 1024);
        try testing.expect(!inRange(address, 1024 * 1024, 2 * 1024 * 1024));
        try testing.expect(!inRange(address, 3 * 1024 * 1024, 3 * 1024 * 1024 + 8192));

        const mask = bitFor(index);
        try testing.expect(seen[index / 8] & mask == 0);
        seen[index / 8] |= mask;
        count += 1;
        try testing.expect(count <= initial_free);
    }
    try testing.expectEqual(initial_free, count);
    try testing.expect(allocator.allocate() == null);
    try testing.expectEqual(@as(usize, 0), allocator.stats().free);

    // Release every third allocated frame; reserved frames are skipped.
    var index: usize = 0;
    var released: usize = 0;
    while (index < 16 * 1024) : (index += 3) {
        const address = @as(u64, index) * page_size;
        if (inRange(address, 1024 * 1024, 2 * 1024 * 1024)) continue;
        if (inRange(address, 3 * 1024 * 1024, 3 * 1024 * 1024 + 8192)) continue;
        if (!allocator.isUsed(address)) continue;
        try allocator.release(address);
        released += 1;
    }
    try testing.expectEqual(released, allocator.stats().free);
    try testing.expect(released > 0);

    // Allocate the released frames again, with a fresh duplicate check.
    var reused: [2048]u8 = undefined;
    @memset(&reused, 0);
    var reallocated: usize = 0;
    while (allocator.allocate()) |address| {
        const frame: usize = @intCast(address / page_size);
        const mask = bitFor(frame);
        try testing.expect(reused[frame / 8] & mask == 0);
        reused[frame / 8] |= mask;
        try testing.expect(!inRange(address, 1024 * 1024, 2 * 1024 * 1024));
        try testing.expect(!inRange(address, 3 * 1024 * 1024, 3 * 1024 * 1024 + 8192));
        reallocated += 1;
    }
    try testing.expectEqual(released, reallocated);
    try testing.expectEqual(@as(usize, 0), allocator.stats().free);

    // Return everything and check the original free count comes back.
    index = 0;
    while (index < 16 * 1024) : (index += 1) {
        const address = @as(u64, index) * page_size;
        if (inRange(address, 1024 * 1024, 2 * 1024 * 1024)) continue;
        if (inRange(address, 3 * 1024 * 1024, 3 * 1024 * 1024 + 8192)) continue;
        if (!allocator.isUsed(address)) continue;
        try allocator.release(address);
    }
    try testing.expectEqual(initial_free, allocator.stats().free);
}

fn inRange(address: u64, start: u64, end: u64) bool {
    return address >= start and address < end;
}
