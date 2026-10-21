# AGENTS.md

Rules for AI agents (and humans) contributing to AzuraOS. They encode the
master prompt, `AzuraOS_AI_PROMPT.txt`, into the day to day workflow of this
repository.

## The one rule

**Never claim something works without evidence.** A file existing is not
evidence of compilation. A successful compiler invocation is not evidence of
a bootable kernel. A QEMU run is not evidence of hardware compatibility.
If a step could not be executed, say so explicitly and say why.

## Working method

1. **Inspect before editing.** Read the files, the contracts and the direct
   and indirect dependencies of what you are about to change. Do not guess
   the API of a tool: verify it (`zig version`, `zig help`, the installed
   standard library sources).
2. **One objective at a time.** Keep the changes small and self contained.
3. **State the plan and the risks** before a large change, and ask only
   when a real blocker is missing information.
4. **Write the invariant down.** Every non obvious decision (a memory layout,
   an ABI, a boot order) belongs in a comment, an ADR or a specification.
5. **Run the build and the tests.** Record the real commands and the real
   output. A test that was not executed is reported as not executed.
6. **Update the documentation.** ADRs, `docs/STATUS.txt` and `CHANGELOG.md`
   are part of the change, not an afterthought.
7. **Deliver a report** with: the files changed, the reason, the tests that
   were executed with their results, the measured metrics, the known
   limitations, the remaining risks and the next step.

## Engineering rules

* **Zig 0.17.0 exactly.** The API in this repository was verified against
  that release. Do not upgrade the toolchain without a plan and a full test
  run.
* **No runtime dependency** may be linked into the kernel or the bootloader.
  Both are freestanding. The `std` library is usable only in part: for
  example `std.debug.print` does not compile for `x86_64-uefi` or
  `x86_64-freestanding` because it pulls in the POSIX threading layer.
* **Architecture specific code** belongs in `kernel/arch/<arch>/`. Code that
  is compiled into both stages belongs in `shared/`.
* **The boot protocol** is defined once, in `shared/boot_info.zig`, and is
  compiled into both artifacts. A change to it is a change to the protocol
  version.
* **Error handling is explicit.** A function that can fail returns an error
  union; a function that cannot fail says so. No silent fallbacks and no
  placeholder values.
* **Validate every boundary.** The bootloader parses a binary it did not
  build: every offset, size and address is checked against the real buffer
  before it is used.
* **No secrets** in the code, in the logs, in the prompts or in the
  documentation.
* **No empty files as placeholders.** In particular, never ship an empty
  `LICENSE` file. The license was decided in ADR-0006 (Apache-2.0); changing
  it is an ADR-level decision, not an edit.
* **Small commits**, focused and descriptive. No drive by refactoring and no
  mass reformatting.
* **Do not publish.** Creating a tag, a release or a remote repository
  requires explicit authorisation.

## Testing rules

* Every new behaviour needs a test that can fail.
* Tests must be deterministic and must not depend on the network.
* Anything that touches the machine state (the MMU, interrupts, the ABI,
  drivers, parsers) requires a human review before being merged.
* A test that was not executed is reported as not executed, with the reason.

## Documentation rules

* `docs/adr/` records the decisions, with the context, the alternatives that
  were rejected and the consequences.
* `docs/specs/` records the normative contracts.
* `docs/STATUS.txt` is the running log: what is implemented, what was
  verified, what is pending.
* `docs/testing/` holds the measured evidence, with the commands used.

## Language

The code, the identifiers and the documentation are in English. The status
log and the delivery reports have historically been written in Portuguese,
matching the project's owner; keep whichever is consistent with the file
being edited.
