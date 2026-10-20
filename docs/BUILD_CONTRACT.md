# AzuraOS — M0.1 build contract (draft; not validated by Zig)

## Scope and invariants

- Host development environment: Fedora Linux x86_64. The ChatGPT container is **not** the host.
- Pin one exact stable Zig release and verify the compiler archive before use. The currently documented candidate is 0.17.0; execution on Fedora is pending.
- No kernel dependency on the host libc, dynamic loader, or runtime libraries.
- Bootloader and kernel are **separate artifacts**. The planned bootloader is PE/COFF x86_64 UEFI; the planned kernel is ELF64 x86_64 freestanding.
- Do not assume the kernel entry ABI, linker script, memory layout, or Zig build APIs before an executable proof with the selected compiler.
- The CPU baseline must not inherit native host features (e.g., Xeon-specific instructions) accidentally.
- No automatic download, network access, or dependency resolution in the production build.
- No timestamps or machine-specific paths intentionally embedded in target artifacts.
- Build failures are fatal; never suppress errors or substitute placeholder binaries.

## M0.1 acceptance gates

1. Capture Fedora release, architecture, Zig version, Zig environment, and compiler binary path.
2. Obtain the official Zig release archive and independently check its SHA-256 against a trusted release index. Record the archive hash, compiler version and provenance.
3. Implement a minimal build graph using the **observed** Zig API; compile a freestanding x86_64 ELF64 probe. This is a toolchain probe, not a bootable kernel.
4. Inspect produced file with `file` and `readelf -h`; confirm architecture, ELF class and expected target ABI. Record actual command output.
5. Repeat from two clean output directories with the same compiler and flags. Compare SHA-256 digests; investigate any mismatch rather than assuming reproducibility.
6. Record all commands, outcomes and limitations in `docs/STATUS.txt`.

## Deferred work

- UEFI application, OVMF execution, boot protocol and kernel handoff belong to later M0 stages.
- AArch64 and RISC-V targets are not built or advertised as supported.
- No license is selected; do not create an empty LICENSE file.

## Evidence policy

A source file existing is not evidence of compilation. A successful compiler invocation is not evidence of bootability. QEMU execution is not evidence of hardware compatibility.
