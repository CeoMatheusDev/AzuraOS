//! GOP (EFI_GRAPHICS_OUTPUT_PROTOCOL) discovery and software drawing.
//!
//! The framebuffer is used as proof that the firmware handed us a usable
//! linear framebuffer. The bootloader paints a static gradient plus a mock
//! window so the QEMU screenshot is unambiguous evidence, and it forwards the
//! geometry to the kernel through `boot_info.framebuffer`.

const std = @import("std");
const uefi = std.os.uefi;
const shared = @import("shared");

const GraphicsOutput = uefi.protocol.GraphicsOutput;

/// Framebuffer geometry and pixel layout, normalised across GOP formats.
pub const Info = struct {
    base: u64,
    size: u64,
    width: u32,
    height: u32,
    stride: u32,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    reserved_mask: u32,

    /// Convert an 8-bit RGB triple into the framebuffer's native pixel word.
    pub fn packPixel(self: Info, r: u8, g: u8, b: u8) u32 {
        var value: u32 = 0;
        value |= (@as(u32, r) * self.red_mask) / 0xff;
        value |= (@as(u32, g) * self.green_mask) / 0xff;
        value |= (@as(u32, b) * self.blue_mask) / 0xff;
        return value;
    }
};

/// Find the GOP protocol and describe the active mode.
pub fn init() ?Info {
    const boot_services = uefi.system_table.boot_services orelse return null;

    const handles = (boot_services.locateHandleBuffer(.{
        .by_protocol = &GraphicsOutput.guid,
    }) catch return null) orelse return null;

    for (handles) |handle| {
        const gop = boot_services.openProtocol(GraphicsOutput, handle, .{
            .get_protocol = .{},
        }) catch continue;
        if (gop == null) continue;

        const gop_ptr = gop.?;
        const mode = gop_ptr.mode;
        const info = mode.info;

        const pixel_format: uefi.protocol.GraphicsOutput.PixelFormat = info.pixel_format;

        var masks = info.pixel_information;
        switch (pixel_format) {
            .red_green_blue_reserved_8_bit_per_color => {
                masks.red_mask = 0x0000_00ff;
                masks.green_mask = 0x0000_ff00;
                masks.blue_mask = 0x00ff_0000;
                masks.reserved_mask = 0xff00_0000;
            },
            .blue_green_red_reserved_8_bit_per_color => {
                masks.red_mask = 0x00ff_0000;
                masks.green_mask = 0x0000_ff00;
                masks.blue_mask = 0x0000_00ff;
                masks.reserved_mask = 0xff00_0000;
            },
            .bit_mask => {},
            .blt_only => return null,
        }

        return Info{
            .base = mode.frame_buffer_base,
            .size = mode.frame_buffer_size,
            .width = info.horizontal_resolution,
            .height = info.vertical_resolution,
            .stride = info.pixels_per_scan_line,
            .red_mask = masks.red_mask,
            .green_mask = masks.green_mask,
            .blue_mask = masks.blue_mask,
            .reserved_mask = masks.reserved_mask,
        };
    }

    return null;
}

/// Convert the discovered geometry into the shared boot ABI structure.
pub fn toBootAbi(info: Info) shared.framebuffer {
    return .{
        .base = info.base,
        .size = info.size,
        .width = info.width,
        .height = info.height,
        .stride = info.stride,
        .pixel_format = .bit_mask,
        .red_mask = info.red_mask,
        .green_mask = info.green_mask,
        .blue_mask = info.blue_mask,
        .reserved_mask = info.reserved_mask,
    };
}

/// Paint the boot splash: a vertical gradient plus a mock application window.
///
/// Drawing is best effort. A failure to map the framebuffer must not abort
/// the boot, so every access is bounds checked against the reported size.
pub fn drawSplash(info: Info) void {
    if (info.base == 0 or info.size == 0) return;
    if (info.width == 0 or info.height == 0) return;

    const pixels: [*]u32 = @ptrFromInt(info.base);

    // Background: vertical gradient from deep blue to near black.
    var y: u32 = 0;
    while (y < info.height) : (y += 1) {
        const t = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(info.height));
        const r: u8 = @intFromFloat(12.0 + 8.0 * t);
        const g: u8 = @intFromFloat(28.0 + 26.0 * t);
        const b: u8 = @intFromFloat(64.0 + 48.0 * t);
        const pixel = info.packPixel(r, g, b);
        fillRow(pixels, info, y, pixel);
    }

    // Mock window: a card in the upper left area. It is deliberately not
    // centred, because the firmware console prints its own text in the
    // middle of the screen and the screenshot must show both.
    const win_w: u32 = info.width / 2;
    const win_h: u32 = info.height / 3;
    if (win_w < 8 or win_h < 8) return;
    const win_x: u32 = info.width / 12;
    const win_y: u32 = info.height / 12;

    const border = info.packPixel(96, 168, 240);
    const body = info.packPixel(28, 34, 48);
    const title = info.packPixel(18, 22, 32);

    var row: u32 = 0;
    while (row < win_h) : (row += 1) {
        const py = win_y + row;
        if (py >= info.height) break;
        var col: u32 = 0;
        while (col < win_w) : (col += 1) {
            const px = win_x + col;
            if (px >= info.width) break;
            const is_border = row < 2 or col < 2 or row >= win_h - 2 or col >= win_w - 2;
            const is_title_bar = row < 24;
            const color = if (is_border)
                border
            else if (is_title_bar)
                title
            else
                body;
            writePixel(pixels, info, px, py, color);
        }
    }
}

fn fillRow(pixels: [*]u32, info: Info, y: u32, color: u32) void {
    var x: u32 = 0;
    while (x < info.width) : (x += 1) {
        writePixel(pixels, info, x, y, color);
    }
}

/// Write one pixel, refusing to touch memory outside the reported framebuffer.
fn writePixel(pixels: [*]u32, info: Info, x: u32, y: u32, color: u32) void {
    const offset = @as(u64, y) * info.stride + @as(u64, x) * 4;
    if (offset + 4 > info.size) return;
    pixels[@intCast(offset / 4)] = color;
}
