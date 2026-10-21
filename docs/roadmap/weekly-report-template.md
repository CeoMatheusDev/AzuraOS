# Weekly report template

AzuraOS keeps its running log in `docs/STATUS.txt`. This template is the
short report that goes with it.

## How to produce the report

Run these commands in order and keep their real output. A step that cannot
be executed is reported as **not executed**, with the reason. Never write
"works", "done" or "safe" without the output that proves it.

```sh
# 1. The environment the evidence was produced on.
uname -a
zig version
qemu-system-x86_64 --version | head -1
rpm -q edk2-ovmf mtools 2>/dev/null

# 2. Build and the whole test suite.
zig fmt --check boot kernel shared tools
zig build test

# 3. The boot evidence.
zig build esp
zig build boot
tr -d '\r' < zig-out/boot/serial.log | sed 's/\x1b\[[0-9;]*[A-Za-z]//g'

# 4. The state of the tree.
git log --oneline -10
git status --short
```

## The report itself

```markdown
# AzuraOS — relatório semanal (YYYY-MM-DD)

## Ambiente
Fedora <version> x86_64, Zig <version>, QEMU <version>, OVMF <version>.

## Marcos
| Marco | Etapa | Estado | Evidência |
| ----- | ----- | ------ | --------- |
| M1 Boot | — | concluído | docs/testing/m1-boot-evidence.md |
| M2 Kernel minimum | M2.1 GDT própria | concluído / em andamento | ADR-0004 |
| M2 | M2.2 ExitBootServices | não iniciado | — |

## Testes executados
| Comando | Resultado | Saída relevante |
| ------- | --------- | --------------- |
| zig build unit-test | 19/19 PASS | — |
| zig build boot-test | PASS | log de boot integral em zig-out/test-boot/serial.log |
| zig build fault-test | PASS | KERNEL FAULT: vector 6, cs=0x8 |

## Métricas
- artefatos: <sha256 do .efi e do .elf>
- boot: <linhas do log, número de entradas do mapa de memória>
- framebuffer: <geometria> e checksum <valor> idêntico no bootloader e no kernel

## Pendências
- <item com o motivo e quem depende dele>

## Limitações conhecidas
- <limitação não escondida; por exemplo: ainda sem ExitBootServices, sem TSS,
  sem hardware real>

## Riscos
- <risco e o que dispara a próxima ação>

## Próximo passo
<uma ação, com o critério de aceitação>
```

## Rules for the report

* The numbers come from the commands above, not from memory.
* A test that was not executed is listed as not executed, with the reason.
* The CI workflow exists but is not a passing test until it has run
  successfully on GitHub Actions. Until then, it is listed as "written, not
  executed".
* Nothing is pushed and no tag is created without explicit authorisation.
  The M1 and M2 commits stay local until the owner decides.
