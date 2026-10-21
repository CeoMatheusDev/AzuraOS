# ADR-0005 — The exception frame has two shapes, and the stub fixes up the ABI

- Status: accepted
- Date: 2026-10-20
- Milestone: M2.1 (review of PR #1)
- Related: ADR-0001, ADR-0004

## Context

The M1 exception handler received the CPU's stack frame as a pointer and
read three fixed offsets out of it: RIP at 0, CS at 8 and RFLAGS at 16. The
error code, for the vectors that push one, was read from offset 24.

The review of PR #1 found two independent defects in that code, both of
them invisible in the M1 build and fatal in a stricter one.

### The frame is not the same shape for every vector

Intel SDM Vol. 3A, 6.14.5 and 7.14.2: in 64-bit mode the processor pushes
SS, RSP, RFLAGS, CS and RIP, in that order. Every push moves the stack
pointer down by 8 bytes, so RIP ends up at the **lowest** address of the
frame. The error code, when the vector pushes one, is pushed **after** the
RIP value, so it lands at the lowest address of the frame, **below** RIP.

```
without an error code:  [RIP] [CS] [RFLAGS] [RSP] [SS]                 (40 bytes)
with an error code:     [error code] [RIP] [CS] [RFLAGS] [RSP] [SS]   (48 bytes)
```

The frame is therefore one word longer for the vectors that push an error
code, and every field after the error code is shifted by one word.

The M1 code assumed the error code was the **last** word, at offset 24. It
is the **first** word, at offset 0. And the set of vectors that push an
error code was wrong: vector 13 (#GP) was excluded, on the grounds that
"the error code is only pushed when the fault was caused by an instruction
fetch". That rule is a legacy mode rule. In 64-bit mode a #GP **always**
pushes an error code (Intel SDM Vol. 3A, 7.3.1, Table 7-1, and the
"Exception Error Code" section of the #GP chapter).

The observable effect is that the handler reports the error code as the
RIP, the RIP as the CS, and the CS as the RFLAGS.

### The stub did not satisfy the ABI it calls through

The System V AMD64 ABI imposes two conditions on a call. Immediately
**before** the `call`, `RSP` must be a multiple of 16; at the **first
instruction of the callee**, after the return address has been pushed,
`RSP % 16` must be 8. The direction flag must also be clear.

The processor guarantees neither on an exception entry. It aligns the stack
pointer to a 16 byte boundary **before** pushing the frame (Intel SDM
Vol. 3A, 7.14.2), and the frame is 40 bytes long for the vectors that push
no error code and 48 bytes long for the vectors that push one. The parity
of the frame base therefore depends on the vector: for #UD the handler was
entered with `RSP % 16 == 0` instead of 8, and for #PF with 8.

The direction flag is not touched by the processor at all, and a faulting
instruction may well have set it.

The M1 build did not notice, because the code the handler happens to run
does not use any instruction that requires an aligned stack pointer. A
stricter build does: with the original sources and `ReleaseSafe`, the
handler itself faulted with a #GP before it could report anything, and the
fault was reported as `vector 13` instead of the `vector 6` that actually
happened. The original fault was hidden by a fault of the reporter.

## Decision

### The frame is decoded per vector, not per offset

`kernel/arch/x86_64/exception.zig` holds the exception model as pure logic:
the raw frame (six 8 byte words, named by position), the decoded context,
`decodeFrame` and `hasErrorCode`.

`hasErrorCode` lists the vectors that push an error code in 64-bit mode:
8, 10, 11, 12, 13, 14, 17, 21, 29 and 30. `decodeFrame` uses it to pick
the shape and to say where each field is. A single fixed layout is not
possible, and the module exists so that the classification and the layout
live in one place and can be unit tested.

The module has no inline assembly and no dependency on the machine, so it
is covered by the host unit tests. `kernel/arch/x86_64/idt.zig` keeps only
what touches the processor.

### The stub fixes up the ABI before the call

The per-vector stub aligns the stack pointer and clears the direction flag
before it calls the handler:

```
movq $<vector>, %rdi     the vector number
movq %rsp, %rsi         the pointer to the CPU's stack frame
andq $-16, %rsp         RSP % 16 == 0 immediately before the call
cld                     the ABI demands a clear direction flag
callq azuraCommonHandler
```

The frame pointer is read **before** the alignment, so the frame itself is
never touched: `andq` only lowers the stack pointer, and the CPU's frame
stays where it was pushed.

The stub clobbers RDI, RSI, RSP and the flags. Nothing is saved, because
the stub never returns: the handler halts the machine and the interrupted
context is never resumed. A future change that resumes the faulting code
would have to save and restore the whole register state before this stub
would be correct.

The bytes of this prologue are part of the contract and are checked at
boot: `idt.verifyEntries` reads them at the address every IDT entry names,
so a stub that lost the fixup stops the machine at boot with a diagnostic
instead of corrupting the handler's stack alignment silently.

### The fault injection test covers both shapes

`tests/boot/test-m1-fault-handler.sh` injects two faults and checks both
reports:

| Injection | Vector | Error code | Frame |
| --------- | ------ | ---------- | ----- |
| `invalid_opcode` | 6 (#UD) | none | 40 bytes |
| `bad_segment` | 13 (#GP) | the selector | 48 bytes |

The second one loads the selector 0xa0 into ES. The index is far beyond
the limit of the kernel's own GDT, so the processor raises a #GP and
reports the selector as the error code.

The test also requires the code selector in the report to be `0x8`, the
kernel's own. A frame read at the wrong offset reports an address there
instead, which is how the misreading was detected.

## Consequences

* The handler reports the fault that actually happened, in every build
  configuration, and it reports the register state of the faulting
  instruction.
* The exception model is testable on the host. The stub itself is not:
  Zig 0.17 refuses to compile an inline assembly label reference in a test
  build, so the stubs cannot be instantiated on the host. That check
  lives in the kernel and is exercised by the QEMU boot test.
* The model is deliberately dumb. It decodes a frame; it does not save the
  rest of the machine state. The handler never returns, so there is
  nothing to restore. A kernel that wants to resume the faulting
  instruction needs a different design, and this ADR does not cover it.
* The IST field of the IDT is still zero and there is still no TSS, so a
  fault that happens while the kernel stack cannot be written down is
  still fatal. See ADR-0004. *(Updated by ADR-0008: M2.2b installs a TSS
  and routes `#NMI`, `#DF` and `#MC` to IST1.)*

## References

* Intel SDM Vol. 3A, 6.14.5 (protected mode exception stack frames),
  7.3.1 (Table 7-1, protected mode exceptions and interrupts), 7.14.2
  (64-bit mode stack frame) and the per-vector sections of chapter 7.
* System V AMD64 ABI, 3.2.2 (stack alignment) and 3.2.1 (direction flag).
* `kernel/arch/x86_64/exception.zig` — the exception model and its tests.
* `kernel/arch/x86_64/idt.zig` — the stub, the entry check and the handler.
