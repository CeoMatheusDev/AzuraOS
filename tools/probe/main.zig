// M0.1 toolchain probe only. Not a bootable kernel.
// No libc, no allocator, no firmware interaction.
pub export fn _start() noreturn {
    while (true) {
        asm volatile ("pause");
    }
}
