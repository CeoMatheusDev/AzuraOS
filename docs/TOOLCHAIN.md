# AzuraOS — Toolchain policy (M0.1)

- Compiler selected: Zig 0.17.0 (stable release published October 2026).
- Host: Fedora Linux x86_64; only x86_64 target is in scope.
- Target design: UEFI application (x86_64-uefi) for loader; freestanding x86_64 ELF64 for kernel. Actual flags/linker entry must be verified against Zig 0.17.0 before implementation.
- Build system: Zig build graph; no host libc/runtime linked into kernel. External build/test tools allowed.
- Reproducibility: use exact Zig release, pinned archive checksum/signature, explicit CPU baseline, target, optimization mode, linker settings and no network dependencies. Compare artifact hashes across clean builds once compiled. Hash and binary not yet verified.
- First gate: execute tools/check-toolchain.sh on Fedora, obtain actual `zig version`, `zig env`, and tool paths. Do not copy assumptions from ChatGPT container to Fedora. **DONE**: the gate was executed on Fedora 44, `zig version` reports 0.17.0, and the build API was verified by compiling.
- `build.zig` and `build.zig.zon` now exist and are verified by execution (see `docs/testing/m1-boot-evidence.md`).
- Licensing undecided; do not add LICENSE.

## Verified host inventory (2026-10-20)

| Tool | Version | Command used |
| ---- | ------- | ------------ |
| Zig | 0.17.0 | `zig version` |
| QEMU | 10.2.2 | `qemu-system-x86_64 --version` |
| OVMF | edk2-ovmf-20260812-8.fc44 | `rpm -q edk2-ovmf` |
| mtools | 4.0.49-3.fc44 | `rpm -q mtools` |
| binutils | present | `readelf -hW` |

`zig env` reports the standard library at
`/home/matheus/.local/opt/zig/0.17.0/lib/std`; the API used by this
repository (the UEFI bindings, the build graph, the inline assembly rules)
was read from that tree and not from memory.

### Zig 0.17.0 API notes that cost time to discover

These are recorded because they will bite again:

* The UEFI bindings live in `std.os.uefi`, not `std.uefi`.
* `std.debug.print` does not compile for `x86_64-uefi` or
  `x86_64-freestanding`: it pulls in `std.Io.Threaded`, which needs POSIX.
  Use `std.fmt.bufPrint` into a fixed buffer instead.
* Inline assembly clobbers use the struct syntax: `: .{ .memory = true }`.
* A memory operand in inline assembly needs an explicit size modifier that
  Zig accepts; `lidt` therefore has to be written as `lidtq (%%rax)` with
  the descriptor address in a register.
* Passing a function pointer as an inline assembly operand inside a naked
  function crashes the Zig 0.17.0 compiler. A global holding the address is
  used instead.
* The Zig 0.17.0 build API uses `b.createModule` / `b.addModule` with an
  `imports` list; relative imports cannot cross the module root, so the code
  shared by the two stages is a build module.

References:
- https://ziglang.org/download/
- https://ziglang.org/documentation/0.17.0/
- https://ziglang.org/learn/build-system/

## Official release pin (verified against release index on 2026-10-18)

- Release: `0.17.0`, dated 2026-10-01.
- Host archive: `zig-x86_64-linux-0.17.0.tar.xz`.
- SHA-256: `1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026`.
- Source of expected checksum: `https://ziglang.org/download/index.json`, field `0.17.0.x86_64-linux.shasum`.
- Verify locally with `bash tools/verify-zig-release.sh /path/to/zig-x86_64-linux-0.17.0.tar.xz` before extraction.
- SHA-256 protects against accidental corruption when the expected value is obtained from a trusted source; it does not independently prove publisher authenticity.
- The downloaded archive has NOT been verified or executed in this session.

### Fedora read-only acceptance gate

Run `bash tools/check-toolchain.sh` and share its full output. If Zig 0.17.0 is already installed, also run `zig env` (review output before sharing to avoid exposing local paths if desired). No package installation is authorized by this instruction.

### Reproducibility constraints

Separate host and target artifacts, record compiler archive checksum and compiler version, avoid timestamps and absolute source paths in emitted binaries where possible, and compare hashes from two clean builds using the same host/toolchain. Identical output has NOT been demonstrated. Bootloader PE/COFF and kernel ELF64 targets are architectural plans, not validated build invocations.
