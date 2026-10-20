# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report it privately to the maintainer through the repository's private
security advisory form, or by contacting the maintainer directly. Please
include:

* a description of the issue and its impact,
* the steps to reproduce, ideally with the serial log of the run,
* the version or commit you tested,
* any proof of concept code.

You will get an acknowledgement within a few days. The fix will be
developed in a private branch, verified with the project's test suite
(`zig build test`), and published together with an advisory. The reporter is
credited unless they ask otherwise.

## Scope

AzuraOS is pre-1.0 and most of the system does not exist yet. The following
areas are in scope:

* the boot chain: the UEFI bootloader, the ELF loader and the kernel's
  validation of the boot protocol,
* the kernel's privilege and memory handling, once they exist,
* the parsers: ELF today, AZX, PE/COFF and the Linux ELF loader later,
* the drivers,
* the update and verification path, once it exists.

## Out of scope

* Vulnerabilities in OVMF, QEMU, the Zig compiler or the Linux kernel.
  Report those to their own projects.
* Running untrusted code on AzuraOS. There is no userland and no
  isolation model yet; there is nothing to sandbox.
* Denial of service caused by a malformed image that the bootloader
  correctly refuses to load. The refusal *is* the intended behaviour, and
  the boot log says exactly why.

## Security properties that are already enforced

These are implemented and covered by tests, and a regression in them is a
security bug:

* the bootloader accepts only ELF64, little endian, x86_64, `ET_EXEC`
  images, and validates every program header against the real buffer
  length;
* the entry point must lie inside a loaded segment;
* the kernel load range must be covered by conventional firmware memory;
* the kernel refuses to start with an unknown boot protocol magic, version
  or structure size;
* the kernel installs an IDT, so a fault is reported and the machine is
  halted instead of rebooting in a loop.

## Known gaps

* The kernel runs on the firmware's GDT and page tables and does not call
  `ExitBootServices`. It is not isolated from the firmware.
* Hardware interrupts are not handled; the kernel runs with interrupts
  disabled.
* The kernel load address is fixed and validated, but it is not reserved
  through `AllocatePages`.
* There is no authentication of the kernel image: a modified kernel on the
  EFI System Partition is loaded as long as it is a valid ELF. Signed boot
  and verified boot are M8 work.

## Hardening rules for contributions

* Never trust a length, an offset or an address that comes from data.
* Never write outside a range that was validated against a real bound.
* Never trust the firmware: the bootloader treats the firmware's data as
  untrusted input too.
* Fail closed: a validation error must abort the operation, never continue
  with a partially initialised state.
* No secret, key or token in the source tree, in the build scripts or in
  the logs.
