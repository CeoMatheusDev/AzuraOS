//! Polled COM1 (16550) serial driver, shared by the UEFI bootloader and the
//! kernel.
//!
//! Both stages run in ring 0 on x86_64, so direct port I/O is available in
//! both. Sharing the driver guarantees that the bootloader and the kernel
//! produce byte-identical log formatting, which is what the automated boot
//! test asserts on.
//!
//! The firmware does not install EFI_SERIAL_IO_PROTOCOL on OVMF by default,
//! but the ISA COM1 port is always present on the emulated PC and is mapped
//! by QEMU at 0x3F8.
//!
//! Invariant: every register access is a single byte access to a 16-bit port.

const std = @import("std");

/// COM1 base port (ISA convention; QEMU maps its first 16550A here).
const com1: u16 = 0x3f8;

const r_data = com1 + 0; // Transmitter Holding Register (write) / Data (read)
const r_interrupt_enable = com1 + 1;
const r_fifo = com1 + 2;
const r_line_control = com1 + 3;
const r_modem_control = com1 + 4;
const r_line_status = com1 + 5;

/// Line Status Register bit 5: Transmitter Holding Register Empty.
const lsr_thre: u8 = 0x20;

/// Upper bound on the number of polls of the transmitter register before the
/// write is abandoned. Prevents an infinite hang if the UART is wedged.
const max_transmit_spins: u32 = 1_000_000;

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[value]"
        : [value] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

/// Program COM1 for 8N1 @ 115200 baud and enable the FIFOs.
///
/// Divisor 1 gives 115200 baud from the 1.8432 MHz input clock. The exact
/// baud rate is irrelevant for the log format (plain 8-bit text) but a fixed
/// configuration makes the capture reproducible.
pub fn init() void {
    outb(r_interrupt_enable, 0x00); // no interrupts
    outb(r_line_control, 0x80); // DLAB on: divisor registers accessible
    outb(r_data, 0x01); // divisor low  = 1
    outb(r_interrupt_enable, 0x00); // divisor high = 0
    outb(r_line_control, 0x03); // DLAB off, 8 data bits, no parity, 1 stop bit
    outb(r_fifo, 0xC7); // enable and clear the FIFOs, 14 byte trigger level
    outb(r_modem_control, 0x0B); // DTR | RTS | OUT2
}

/// Write bytes to the serial port, translating LF to CRLF.
///
/// The translation keeps the capture readable on terminals that do not
/// implement ONLCR, and keeps the log byte-for-byte deterministic.
pub fn write(bytes: []const u8) void {
    for (bytes) |byte| {
        if (byte == '\n') writeByte('\r');
        writeByte(byte);
    }
}

fn writeByte(byte: u8) void {
    var spins: u32 = 0;
    while ((inb(r_line_status) & lsr_thre) == 0) : (spins += 1) {
        if (spins > max_transmit_spins) return;
    }
    outb(r_data, byte);
}

/// Formatted write into a fixed stack buffer. Never allocates.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch blk: {
        // Out of space: emit a marker instead of silently dropping the message.
        const marker = "...[truncated]";
        @memcpy(buffer[0..marker.len], marker);
        break :blk buffer[0..marker.len];
    };
    write(text);
}
