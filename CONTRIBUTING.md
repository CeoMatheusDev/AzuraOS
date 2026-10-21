# Contributing to AzuraOS

Thank you for helping to build AzuraOS. This document describes how to
contribute in a way that keeps the project verifiable.

## Before you start

AzuraOS is an operating system written from zero. The project is at the M1
milestone: the boot chain works in QEMU, and nothing else does yet. Work on
a subsystem that has not been designed yet is welcome, but it must come with
the design that the code implements.

Read these first:

* `AGENTS.md` — the working rules.
* `docs/STATUS.txt` — what exists and what is pending.
* `docs/adr/` — the decisions already taken, and why.

## Setting up

```sh
zig version                 # must print 0.17.0
zig build                    # build both artifacts
zig build test               # unit tests + the two QEMU boot tests
```

Requirements: Zig 0.17.0, QEMU, the OVMF firmware (`edk2-ovmf`) and
`mtools`. On Fedora:

```sh
sudo dnf install zig qemu-system-x86 edk2-ovmf mtools
```

Note that the `zig` package of the distribution may not be 0.17.0; install
the official release and verify it with `tools/verify-zig-release.sh`.

## Making a change

1. Open an issue describing the problem and the proposed approach. For a
   large change, an ADR draft is better than code.
2. Work on a short lived branch: `feat/...`, `fix/...` or `docs/...`.
3. Keep the commits small and focused. One logical change per commit.
4. Make sure `zig build test` passes and that the serial log of the boot
   test still shows the expected sequence.
5. Open a pull request that explains **what** changed, **why**, and **how it
   was verified** (the commands and their real output).

## Style

* The Zig formatting rules of the language reference apply; run
  `zig fmt --check` before committing.
* Comments explain the *why*, not the *what*. Document the invariants of the
  code, especially in the kernel, the bootloader and the parsers.
* Keep the existing naming conventions: `camelCase` for functions and
  types, `snake_case` for variables, and the file names in `snake_case`.

## What needs a human review

Changes to the following always require a human review before they are
merged:

* the memory management unit, the page tables and the allocator,
* the interrupt handling and the exception paths,
* the boot protocol and any ABI change,
* the drivers,
* the parsers (ELF, and later AZX, PE and ELF for the compatibility layers),
* anything related to security: capabilities, permissions, isolation.

## Reporting a bug

Open an issue with:

* what you did, what you expected and what happened,
* the full serial log of the run (`zig-out/boot/serial.log`),
* the output of `zig version` and `uname -a`,
* the steps to reproduce.

A screenshot of the graphical console is welcome for anything visual.

## Security issues

Do not open a public issue. See `SECURITY.md`.

## Licensing

AzuraOS is licensed under the Apache License, Version 2.0; see `LICENSE` and
`docs/adr/ADR-0006-apache-2-0-license.md`.

Contributions are accepted under the same license. As Apache-2.0 section 5
states, a contribution intentionally submitted for inclusion in the project
is licensed under the terms of the license, without additional terms, unless
you explicitly state otherwise in writing. There is no separate contributor
license agreement to sign.

A contribution that copies code from another project must say so in the pull
request, name the source and its license, and keep the notices that license
requires. Code under a license that is incompatible with Apache-2.0 is not
linked into the kernel or the bootloader.
