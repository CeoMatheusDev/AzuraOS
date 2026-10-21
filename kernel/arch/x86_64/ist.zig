//! Which exception vectors run on the alternate (IST) stack.
//!
//! The TSS provides seven interrupt stack table entries. The kernel uses
//! stack 1 for the faults that must still be reportable when the interrupted
//! stack is the thing that is broken:
//!
//!   #NMI  (vector 2)   cannot be masked and may arrive at any time,
//!   #DF   (vector 8)   is raised when a fault cannot be delivered, which is
//!                      exactly what a corrupted stack causes,
//!   #MC   (vector 18)  reports an unrecoverable machine check.
//!
//! Every other vector keeps IST 0, which means the processor uses the stack
//! the interrupted context was already running on.
//!
//! This module is pure policy: no inline assembly, no machine state. The IDT
//! encodes the number in its gate descriptors and the QEMU tests prove that
//! the processor really switches stacks.

/// The IST entry the critical vectors use. The TSS field is `ist1`.
pub const stack_index: u8 = 1;

pub const vector_nmi: u8 = 2;
pub const vector_double_fault: u8 = 8;
pub const vector_machine_check: u8 = 18;

/// Whether the vector must run on the IST stack.
pub fn usesIst(vector: u8) bool {
    return switch (vector) {
        vector_nmi, vector_double_fault, vector_machine_check => true,
        else => false,
    };
}

/// The IST number encoded in the IDT gate of the vector.
///
/// Zero means "use the interrupted stack", which is the IDT field's own
/// encoding for "no IST" (Intel SDM Vol. 3, 6.14.5).
pub fn number(vector: u8) u8 {
    return if (usesIst(vector)) stack_index else 0;
}

// --- Unit tests -------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "the critical vectors use the alternate stack" {
    try testing.expect(usesIst(vector_nmi));
    try testing.expect(usesIst(vector_double_fault));
    try testing.expect(usesIst(vector_machine_check));
}

test "ordinary faults keep the interrupted stack" {
    // #DE, #UD, #GP and #PF are the vectors the kernel already handles; a
    // wrong policy here would silently move every fault to the IST stack
    // and hide mistakes in the normal stack.
    try testing.expect(!usesIst(0));
    try testing.expect(!usesIst(6));
    try testing.expect(!usesIst(13));
    try testing.expect(!usesIst(14));
}

test "the gate field is one only for the critical vectors" {
    try testing.expectEqual(@as(u8, 1), number(2));
    try testing.expectEqual(@as(u8, 1), number(8));
    try testing.expectEqual(@as(u8, 1), number(18));
    try testing.expectEqual(@as(u8, 0), number(0));
    try testing.expectEqual(@as(u8, 0), number(6));
    try testing.expectEqual(@as(u8, 0), number(13));
    try testing.expectEqual(@as(u8, 0), number(255));
}
