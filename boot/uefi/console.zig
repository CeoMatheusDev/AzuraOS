//! Text output through the firmware EFI_SIMPLE_TEXT_OUTPUT protocol.
//!
//! Used to show the bootloader banner on the graphical console so the QEMU
//! screenshot contains visible evidence, in addition to the serial log.

const std = @import("std");
const uefi = std.os.uefi;

const SimpleTextOutput = uefi.protocol.SimpleTextOutput;

/// Maximum characters in a single console message.
const max_chars = 512;

/// Print a formatted message on the graphical console.
///
/// ASCII only: bytes >= 0x80 are replaced with '?' because the firmware font
/// coverage is implementation defined and the boot log must stay portable.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const con_out = uefi.system_table.con_out orelse return;

    var buffer: [max_chars]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;

    // Zero initialised so the last element is a valid NUL terminator and the
    // sentinel pointer cast below is legal even in safe build modes.
    var wide: [max_chars + 1]u16 = @splat(0);
    var count: usize = 0;
    for (text) |byte| {
        if (count >= max_chars) break;
        wide[count] = if (byte < 0x80) @as(u16, byte) else '?';
        count += 1;
    }
    wide[count] = 0;

    _ = con_out.outputString(@ptrCast(&wide)) catch {};
}
