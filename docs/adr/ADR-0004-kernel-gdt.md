# ADR-0004 — The kernel installs its own GDT

- Status: accepted
- Date: 2026-10-20
- Milestone: M2.1
- Related: ADR-0001, ADR-0002

## Context

Until M2.1 the kernel ran on the GDT that the firmware built. That worked
only by accident: the firmware happened to install a flat 64-bit code segment
and a flat data segment, and the kernel happened not to need a TSS.

A kernel that does not own its descriptors cannot:

* set up a TSS (and therefore cannot use IST stacks, which is how a real
  kernel survives a fault on the kernel stack),
* run a scheduler that switches stacks,
* rely on any segment invariant at all.

The kernel therefore has to build its own GDT. The problem is that the
x86-64 GDT descriptor has a well known and easy to get wrong layout, and the
failure mode is silent.

## Decision

The kernel installs a GDT with this layout:

| Selector | Index | Contents |
| -------- | ----- | -------- |
| 0x00 | 0 | null |
| 0x08 | 1 | kernel code: long mode, base 0, limit 4 GiB |
| 0x10 | 2 | kernel data: base 0, limit 4 GiB |
| 0x18 | 3 | TSS descriptor, bytes 0-7 (see ADR-0008) |
| 0x20 | 4 | TSS descriptor, bytes 8-15 |
| 0x38 | 7 | a copy of the kernel code segment, see below |

The table is 16 entries long, so the GDTR limit is 127.

The kernel code segment is at 0x08 and the data segment at 0x10. The
exception handlers run in the kernel code segment, so the IDT names selector
0x08.

### The transition copy at 0x38

The selector the firmware was using is copied into the new GDT as an alias of
the kernel code segment.

The reason is the order of the two operations. The IDT has to exist before
the GDT is switched, otherwise a fault during the switch would be a triple
fault with no diagnostic. The IDT installed before the switch names the
firmware's code selector. If the new GDT did not define that selector, a
fault taken between the two operations would raise a general protection fault
whose handler would raise it again, in a loop.

With the copy in place, the IDT installed before the switch stays valid
through the transition, and the IDT is reinstalled with selector 0x08 right
after the switch.

### The descriptor layout

This is the part that must be written down, because getting it wrong is
silent:

```
byte 0-1  limit bits 0-15
byte 2-3  base bits 0-15
byte 4    base bits 16-23
byte 5    access
byte 6    limit bits 16-19 | flags      <- the low nibble is the limit,
byte 7    base bits 24-31                  the high nibble is the flags
```

The limit's high bits are in the **low** nibble of byte 6, and the flags
(granularity, default operand size, long mode) are in the **high** nibble.

The kernel code segment is therefore `ffff 0000 009a af 00`: limit 0xfffff,
base 0, access 0x9a (present, ring 0, code, execute/read), flags 0xa
(granularity 4 KiB, long mode).

## The failure that this ADR records

The first implementation used `0xfa` instead of `0xaf` for the code segment
and `0xfc` instead of `0xcf` for the data segment: the two nibbles were
swapped.

The result was a segment whose limit was 0xaffff (704 KiB) scaled by the 4
KiB granularity, that is 44 MiB, instead of 4 GiB. Everything below 44 MiB
worked, which is where the kernel image and the GDT itself live, so the
kernel booted and printed its whole banner.

The failure appeared only when an exception was taken: the processor pushes
the exception frame on the current stack, and the kernel stack lives at
0x1dff5018, far above the 44 MiB limit of the data segment. The push
faulted, the fault could not be reported, and the machine triple faulted and
rebooted in a loop.

Three lessons are encoded in the code:

* the unit tests in `kernel/arch/x86_64/gdt.zig` check the nibbles
  separately, and one test computes the effective limit;
* the kernel reads the GDTR back and compares it with the table it built, and
  checks that CS is the selector it expects, before it trusts the state;
* the fault injection test exists and asserts that a fault is reported
  instead of rebooting the machine.

## Consequences

* The kernel owns its segment state. The firmware's descriptors are no longer
  relied upon, and the kernel stack may live anywhere below 4 GiB.
* The kernel still runs on the firmware's page tables and has not called
  `ExitBootServices`. Owning the memory is the next step of M2.
* The TSS descriptor is now implemented in ADR-0008. It occupies selector
  0x18 (indices 3 and 4), and the IDT uses IST1 for `#NMI`, `#DF` and `#MC`.

## References

* Intel SDM Vol. 3, 3.4.5 (segment descriptor formats) and 3.5.2 (loading a
  GDT).
* `kernel/arch/x86_64/gdt.zig` — the implementation and its unit tests.
* `kernel/arch/x86_64/cpu.zig` — `loadIdt`, the IDTR read back and the
  selector helpers.
