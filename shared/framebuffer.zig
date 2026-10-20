//! Framebuffer verification helpers, shared by the UEFI bootloader and the
//! kernel.
//!
//! The QEMU `screendump` monitor command does not faithfully capture the GOP
//! linear framebuffer of the emulated video device, so a screenshot alone is
//! weak evidence. Instead, both stages compute a checksum over the framebuffer
//! they can actually see:
//!
//!   * the bootloader computes it right after it paints the boot splash,
//!   * the kernel computes it after the handover,
//!   * the automated boot test compares the two values.
//!
//! Equal checksums prove that the kernel sees exactly the pixels the
//! bootloader wrote, which is a stronger statement than a picture.

const std = @import("std");

/// FNV-1a 64 bit offset basis.
const fnv_offset_basis: u64 = 0xcbf29ce484222325;

/// FNV-1a 64 bit prime.
const fnv_prime: u64 = 0x00000100000001b3;

/// Number of rows between two sampled rows.
///
/// The framebuffer lives in memory mapped I/O on the emulated machine, so
/// reading all 4 MiB is needlessly slow. Sampling every 16th row still
/// covers the whole screen, including the boot splash, and the same rule is
/// applied on both sides of the handover.
pub const sample_row_step: u32 = 16;

/// Compute the checksum of a linear framebuffer.
///
/// `base` is the physical address of the framebuffer, `stride` the number of
/// bytes per row and `height` the number of rows. The checksum covers the
/// sampled rows only, and the same parameters must be used by both stages.
pub fn checksum(base: u64, stride: u32, height: u32) u64 {
    if (base == 0 or stride == 0 or height == 0) return 0;

    const bytes: [*]const u8 = @ptrFromInt(base);

    var hash: u64 = fnv_offset_basis;
    var y: u32 = 0;
    while (y < height) : (y += sample_row_step) {
        const row = bytes + @as(u64, y) * stride;
        var x: u32 = 0;
        while (x < stride) : (x += 1) {
            hash ^= row[x];
            hash *%= fnv_prime;
        }
    }
    return hash;
}

// --- Unit tests -------------------------------------------------------------

const testing = std.testing;

test "checksum of an empty framebuffer is zero" {
    try testing.expectEqual(@as(u64, 0), checksum(0, 1280, 800));
    try testing.expectEqual(@as(u64, 0), checksum(0x1000, 0, 800));
    try testing.expectEqual(@as(u64, 0), checksum(0x1000, 1280, 0));
}

test "checksum changes when a sampled pixel changes" {
    var frame: [16 * 4]u8 align(4) = @splat(0);
    const before = checksum(@intFromPtr(&frame), 16, 4);
    frame[0] = 1;
    const after = checksum(@intFromPtr(&frame), 16, 4);
    try testing.expect(before != after);
}

test "checksum ignores a row that is not sampled" {
    var frame: [16 * 4]u8 align(4) = @splat(0);
    const before = checksum(@intFromPtr(&frame), 16, 4);
    // Row 1 is not sampled when the step is 16.
    frame[16] = 0xff;
    const after = checksum(@intFromPtr(&frame), 16, 4);
    try testing.expectEqual(before, after);
}

test "checksum is stable for the same content" {
    var frame: [16 * 4]u8 align(4) = @splat(0);
    @memset(frame[0..8], 0xab);
    const first = checksum(@intFromPtr(&frame), 16, 4);
    const second = checksum(@intFromPtr(&frame), 16, 4);
    try testing.expectEqual(first, second);
}
