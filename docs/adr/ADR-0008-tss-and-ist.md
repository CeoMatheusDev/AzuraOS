# ADR-0008 — TSS and IST stacks for critical faults

- Status: accepted
- Date: 2026-10-21
- Milestone: M2.2b
- Related: ADR-0004, ADR-0005, `docs/specs/m2.2b-tss-ist.md`,
  `docs/testing/m2.2b-tss-ist-evidence.md`

## Context

After M2.1 the kernel owns its GDT and after M2.2 it owns the machine, but
every CPU exception still runs on the stack the interrupted context was using.
That is acceptable for an ordinary fault on a healthy kernel stack, and it is
not acceptable for the faults that exist precisely because the stack may be
broken:

* `#DF` (vector 8) is raised when a fault cannot be delivered. A corrupted
  kernel stack is one of the classic ways to get there, so the handler must
  not need that stack;
* `#NMI` (vector 2) cannot be masked and may arrive while the stack is being
  switched or repaired;
* `#MC` (vector 18) reports a machine check that may have corrupted the
  current context.

Without a TSS the processor has no IST, so a `#DF` on a bad stack escalates to
a triple fault: the machine resets with no diagnostic, and an automated test
sees a reboot instead of a failure. The user raised this requirement during
M2.2; the M2.2 specification explicitly deferred it to a separate step
because it changes machine state (GDT, TSS and IDT) and needs its own
evidence.

## Decision

### 1. One TSS, one alternate stack

The kernel builds a 64-bit TSS of the architectural size, 104 bytes, and a
16 KiB IST1 stack in `.bss`. IST1 is used by `#NMI`, `#DF` and `#MC`; every
other vector keeps IST 0 and runs on the interrupted stack. The policy lives
in `kernel/arch/x86_64/ist.zig` and is host-tested.

A second alternate stack per vector is not justified yet: the three critical
vectors all halt the machine after reporting, so they can share a stack as
long as they cannot nest. NMI can nest on #DF in theory; the handler does not
return, and a nested critical fault on the same IST would overwrite the
outer frame only after the outer handler has already printed its report. That
is acceptable for M2.2b and is recorded as a limitation.

### 2. GDT placement

The TSS descriptor is a 16 byte system descriptor and occupies two GDT slots.
It lives at selector `0x18` (indices 3 and 4), which ADR-0004 reserved for the
TSS. The descriptor is encoded by `tss.encodeDescriptor`:

* limit 103, byte granularity, no flags;
* base split across the classic low word and the high word;
* access byte `0x89` (present, DPL 0, system, type 9 — available 64-bit TSS).

`LTR` marks the descriptor busy (type 9 becomes type 11), and the kernel
verifies the busy byte after loading the register. If the firmware's code
selector used during the transition happens to name index 3 or 4, the kernel
refuses to boot instead of overwriting half of the TSS descriptor.

### 3. Fields

| Field | Value | Why |
| ----- | ----- | --- |
| `rsp0` | boot stack top | There is no ring 3 yet. The field must not be zero, and the boot stack is the only kernel stack that exists. A future user mode gets its own per-task stack. |
| `ist1` | top of the 16 KiB alternate stack | The CPU pushes the exception frame downwards from this address. |
| `ist2..ist7` | 0 | Unused. |
| `iomap_base` | 104 | No I/O permission bitmap. Any value above the limit disables it; the exact value is checked at boot. |
| reserved fields | 0 | Prevent stale data from being interpreted by a future feature. |

### 4. Order of installation

The order is part of the contract:

1. install the provisional IDT with the firmware code selector and **IST 0**;
2. fill the TSS and probe the IST stack;
3. build and load the GDT with the TSS descriptor;
4. execute `LTR 0x18` and verify the task register and the descriptor;
5. reinstall the IDT with the kernel code selector and IST 1 for vectors 2,
   8 and 18;
6. verify the stub addresses and the IST fields, then continue the boot.

The provisional IDT cannot name IST1: the kernel TSS is not loaded yet, so the
processor would read IST1 from the firmware's TSS (or from no TSS at all) and
could load a wild stack pointer during the very transition the IDT is meant
to protect.

### 5. Verification and test

The boot path verifies, with values read back from the processor and from
memory:

* the task register reads `0x18`;
* the GDT descriptor decodes to the TSS base, limit 103 and the busy access
  byte;
* `rsp0` is the boot stack top and `ist1` is the top of the alternate stack;
* the alternate stack is writable at its top;
* every exception gate names the IST the policy requires.

A normal boot cannot produce a `#DF`, so the test build hides vector 13 from
the IDT (limit covering vectors 0..8 only) and executes `int $13`. The #GP
gate is outside the limit, delivery of the #GP fails, and the processor raises
`#DF` through vector 8, which is inside the limit and names IST1. The handler
logs the stack it is actually using; the test asserts that this address is
inside the IST range and outside the interrupted stack. A misconfigured TSS
would triple fault, which the banner count detects.

## Alternatives rejected

* **Use the boot stack as the IST stack.** Rejected: the point is to survive a
  fault when the boot stack is unusable.
* **Use a 4 KiB alternate stack.** Rejected: the exception frame, the stub,
  the formatted report and the serial driver need more headroom; 16 KiB
  matches the boot stack and costs about 0.003% of the 512 MiB test machine.
* **Allocate the TSS or the IST stack from a heap.** Rejected: there is no
  heap before M2.5, and the TSS must stay at a stable physical address for as
  long as the task register names it.
* **One IST per critical vector.** Rejected for now: no handler returns, so
  the isolation buys nothing yet and triples the static cost. Revisit when
  NMI handling becomes recoverable.
* **Set the IST fields in the provisional IDT.** Rejected: the TSS is not
  loaded at that point; see the order above.
* **Test only with a software stub instead of a real #DF.** Rejected: only the
  processor can prove that it really switched stacks. The truncated-IDT test
  is a real double fault and fails closed (triple fault) if the TSS is wrong.
* **Enable the I/O permission bitmap now.** Rejected: there is no user mode
  and no port I/O policy yet; an empty bitmap would only add a page the first
  user process could probe.

## Consequences

* The kernel image grows by the 16 KiB IST stack plus the 104-byte TSS. M2.3
  must reserve the whole kernel image, including these objects.
* `#DF`, `#NMI` and `#MC` can now be reported even when the interrupted stack
  is broken. The handler still halts the machine; recovery is a later
  milestone.
* The task register is loaded for the rest of the kernel's life. Code that
  reloads the GDT must keep the TSS descriptor valid or the next `LTR`/task
  switch fails.
* There is still no ring 3 and no hardware task switching; `rsp0` is prepared
  but unused. When user mode arrives, `rsp0` must point at the current task's
  kernel stack, not at the boot stack.
* The double fault test deliberately corrupts the IDT limit. It runs in its
  own image and never in a normal build.

## References

* Intel SDM Vol. 3A, 6.14.5 (interrupt stack table), 7.14.2 (exception
  delivery) and Vol. 3, Figure 7-11 (64-bit TSS) and 3.5.2 (system
  descriptors).
* `kernel/arch/x86_64/tss.zig` — layout, descriptor encoding and tests.
* `kernel/arch/x86_64/ist.zig` — the policy shared by the IDT and the boot
  checks.
* `docs/specs/m2.2b-tss-ist.md` — acceptance criteria.
* `docs/testing/m2.2b-tss-ist-evidence.md` — measured evidence.
