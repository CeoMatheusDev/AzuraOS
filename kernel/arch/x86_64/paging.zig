//! x86_64 4-level paging.
//!
//! The module owns the shape of a page table and the operations that build
//! one. It does not own the physical memory it allocates: every table frame
//! comes from the frame allocator in `kernel/mm/frames.zig`, so the pool that
//! hands out data frames also hands out table frames, and the quarantine
//! policy stays in one place.
//!
//! The kernel uses 4 KiB pages everywhere in M2.4. Large pages are a mapping
//! optimisation, not a requirement, and using one size keeps the walk and the
//! permission logic uniform. The allocator and the page tables agree on the
//! 4 KiB unit.
//!
//! The entry format is the standard 64-bit PTE. Bit 63 is NX and is only
//! valid when EFER.NXE is set; `cpu.enableNx` must be called before any
//! table that uses it is loaded.

const frames = @import("../../mm/frames.zig");

pub const page_size: u64 = 4096;
pub const entries_per_table: usize = 512;

/// Mask that extracts the physical address from a page table entry.
pub const address_mask: u64 = 0x000ffffffffff000;

/// Page table flags. Only the bits the kernel needs in M2.4 are named; the
/// rest are left clear and the hardware sets Accessed and Dirty itself.
pub const Flags = struct {
    present: bool = true,
    writable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    page_size: bool = false,
    global: bool = false,
    no_execute: bool = false,
};

/// A page table is 512 64-bit entries, 4 KiB in total.
pub const Table = [entries_per_table]u64;

/// Build a page table entry from a physical address and a set of flags.
pub fn entry(phys: u64, flags: Flags) u64 {
    var value: u64 = phys & address_mask;
    if (flags.present) value |= 1;
    if (flags.writable) value |= 1 << 1;
    if (flags.user) value |= 1 << 2;
    if (flags.write_through) value |= 1 << 3;
    if (flags.cache_disable) value |= 1 << 4;
    if (flags.accessed) value |= 1 << 5;
    if (flags.dirty) value |= 1 << 6;
    if (flags.page_size) value |= 1 << 7;
    if (flags.global) value |= 1 << 8;
    if (flags.no_execute) value |= @as(u64, 1) << 63;
    return value;
}

/// Index of `virt` in each level of the tree.
pub fn pml4Index(virt: u64) usize {
    return @intCast((virt >> 39) & 0x1ff);
}
pub fn pdptIndex(virt: u64) usize {
    return @intCast((virt >> 30) & 0x1ff);
}
pub fn pdIndex(virt: u64) usize {
    return @intCast((virt >> 21) & 0x1ff);
}
pub fn ptIndex(virt: u64) usize {
    return @intCast((virt >> 12) & 0x1ff);
}

/// Allocate a zeroed page table frame from the pool.
pub fn allocTable(allocator: *frames.Allocator) ?*Table {
    const address = allocator.allocate() orelse return null;
    const table: *Table = @ptrFromInt(address);
    @memset(table, 0);
    return table;
}

/// Map one 4 KiB page. Intermediate tables are allocated as needed.
///
/// Returns false if the pool is exhausted. The caller must treat a false
/// result as a fatal boot error: a partially built tree is not safe to load.
pub fn mapPage(pml4: *Table, virt: u64, phys: u64, flags: Flags, allocator: *frames.Allocator) bool {
    const p4i = pml4Index(virt);
    if (pml4[p4i] == 0) {
        const table = allocTable(allocator) orelse return false;
        pml4[p4i] = entry(@intFromPtr(table), .{
            .present = true,
            .writable = true,
            .no_execute = false,
        });
    }
    const pdpt: *Table = @ptrFromInt(pml4[p4i] & address_mask);

    const pdi = pdptIndex(virt);
    if (pdpt[pdi] == 0) {
        const table = allocTable(allocator) orelse return false;
        pdpt[pdi] = entry(@intFromPtr(table), .{
            .present = true,
            .writable = true,
            .no_execute = false,
        });
    }
    const pd: *Table = @ptrFromInt(pdpt[pdi] & address_mask);

    const pdii = pdIndex(virt);
    if (pd[pdii] == 0) {
        const table = allocTable(allocator) orelse return false;
        pd[pdii] = entry(@intFromPtr(table), .{
            .present = true,
            .writable = true,
            .no_execute = false,
        });
    }
    const pt: *Table = @ptrFromInt(pd[pdii] & address_mask);

    pt[ptIndex(virt)] = entry(phys, flags);
    return true;
}

/// Map a contiguous range of 4 KiB pages. `size` is rounded up to a page.
pub fn mapRange(pml4: *Table, virt_start: u64, phys_start: u64, size: u64, flags: Flags, allocator: *frames.Allocator) bool {
    const pages = (size + page_size - 1) / page_size;
    var i: u64 = 0;
    while (i < pages) : (i += 1) {
        const virt = virt_start + i * page_size;
        const phys = phys_start + i * page_size;
        if (!mapPage(pml4, virt, phys, flags, allocator)) return false;
    }
    return true;
}

/// Translate a virtual address, or null if it is not present.
pub fn translate(pml4: *const Table, virt: u64) ?u64 {
    const p4e = pml4[pml4Index(virt)];
    if (p4e & 1 == 0) return null;
    const pdpt: *const Table = @ptrFromInt(p4e & address_mask);

    const pdpe = pdpt[pdptIndex(virt)];
    if (pdpe & 1 == 0) return null;
    // 1 GiB page
    if (pdpe & (1 << 7) != 0) {
        return (pdpe & 0x000fffffc0000000) | (virt & 0x3fffffff);
    }
    const pd: *const Table = @ptrFromInt(pdpe & address_mask);

    const pde = pd[pdIndex(virt)];
    if (pde & 1 == 0) return null;
    // 2 MiB page
    if (pde & (1 << 7) != 0) {
        return (pde & 0x000fffffffe00000) | (virt & 0x1fffff);
    }
    const pt: *const Table = @ptrFromInt(pde & address_mask);

    const pte = pt[ptIndex(virt)];
    if (pte & 1 == 0) return null;
    return (pte & address_mask) | (virt & 0xfff);
}

/// Unmap a single 4 KiB page. The tables are left in place.
pub fn unmapPage(pml4: *Table, virt: u64) void {
    const p4e = pml4[pml4Index(virt)];
    if (p4e & 1 == 0) return;
    const pdpt: *Table = @ptrFromInt(p4e & address_mask);
    const pdpe = pdpt[pdptIndex(virt)];
    if (pdpe & 1 == 0) return;
    if (pdpe & (1 << 7) != 0) return; // 1 GiB page, not handled
    const pd: *Table = @ptrFromInt(pdpe & address_mask);
    const pde = pd[pdIndex(virt)];
    if (pde & 1 == 0) return;
    if (pde & (1 << 7) != 0) return; // 2 MiB page, not handled
    const pt: *Table = @ptrFromInt(pde & address_mask);
    pt[ptIndex(virt)] = 0;
}

// --- Unit tests -----------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "entry encodes address and flags" {
    const e = entry(0x123000, .{ .present = true, .writable = true, .no_execute = true });
    try testing.expectEqual(@as(u64, 0x123000), e & address_mask);
    try testing.expect(e & 1 != 0);
    try testing.expect(e & 2 != 0);
    try testing.expect(e & (@as(u64, 1) << 63) != 0);
}

test "indices split a 48-bit address" {
    const virt: u64 = 0x0000_1234_5678_9abc;
    try testing.expectEqual(@as(usize, 0), pml4Index(virt) >> 1); // smoke
    // The low 12 bits are the offset; index 0 of PT selects the first page.
    try testing.expectEqual(@as(usize, 0x178), ptIndex(0x0000_0000_0012_3000));
}

test "mapPage and translate round trip" {
    // 64 frames = 256 KiB of bitmap = 512 KiB of addressable? Actually 64
    // frames of 4 KiB = 256 KiB of RAM described by the bitmap.
    var bitmap: [8]u8 = undefined;
    var allocator = try frames.Allocator.init(&bitmap, 64);
    // Free all 64 frames.
    allocator.markFreeRange(0, 64 * page_size);

    const pml4 = allocTable(&allocator) orelse return error.OutOfMemory;
    const virt: u64 = 0x0000_0000_0040_1000;
    const phys: u64 = 0x0000_0000_0000_5000;
    try testing.expect(mapPage(pml4, virt, phys, .{ .present = true, .writable = true }, &allocator));
    try testing.expectEqual(phys, translate(pml4, virt).?);
    try testing.expect(translate(pml4, virt + page_size) == null);
}
