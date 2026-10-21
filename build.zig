const std = @import("std");

// AzuraOS build graph.
//
// Milestone M1 produces two independent artifacts:
//   * azura-bootloader.efi  — UEFI application (PE/COFF), runs inside OVMF
//   * azura-kernel.elf     — freestanding ELF64 x86_64, loaded by the
//                             bootloader from the EFI System Partition
//
// The two share exactly one thing: the boot protocol ABI in shared/boot_info.zig.
// That file is compiled into both artifacts, so the contract cannot drift
// between them without breaking the build.

pub fn build(b: *std.Build) void {
    // ------------------------------------------------------------------
    // Shared modules
    // ------------------------------------------------------------------

    // The boot protocol ABI. Imported by both stages as @import("shared").
    const shared_module = b.addModule("shared", .{
        .root_source_file = b.path("shared/boot_info.zig"),
    });

    // Polled COM1 driver, shared so both stages format the log identically.
    const com1_module = b.addModule("com1", .{
        .root_source_file = b.path("shared/com1.zig"),
    });

    // Framebuffer verification, shared so both stages compute the same
    // checksum over the same pixels.
    const framebuffer_module = b.addModule("framebuffer", .{
        .root_source_file = b.path("shared/framebuffer.zig"),
    });

    // ------------------------------------------------------------------
    // Stage 1: UEFI bootloader
    // ------------------------------------------------------------------

    // Test only. When set, the bootloader touches the pool between the final
    // memory map snapshot and ExitBootServices, which changes the map and
    // makes the key stale. The firmware must answer EFI_INVALID_PARAMETER and
    // the bootloader must refresh the map and retry. A normal build leaves it
    // off.
    const stale_map_key = b.option(bool, "stale-map-key", "Invalidate the memory map key before ExitBootServices (test only)") orelse false;

    const bootloader_options = b.addOptions();
    bootloader_options.addOption(bool, "stale_map_key", stale_map_key);

    const bootloader_module = b.createModule(.{
        .root_source_file = b.path("boot/uefi/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .uefi,
        }),
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "shared", .module = shared_module },
            .{ .name = "com1", .module = com1_module },
            .{ .name = "framebuffer", .module = framebuffer_module },
            .{ .name = "build_options", .module = bootloader_options.createModule() },
        },
    });

    const bootloader = b.addExecutable(.{
        .name = "azura-bootloader",
        .root_module = bootloader_module,
    });
    b.installArtifact(bootloader);

    const bootloader_step = b.step("bootloader", "Build the UEFI bootloader (PE/COFF .efi)");
    bootloader_step.dependOn(&b.addInstallArtifact(bootloader, .{}).step);

    // ------------------------------------------------------------------
    // Stage 2: kernel
    // ------------------------------------------------------------------

    // The fault the kernel injects on purpose, to exercise the exception
    // handler. "none" by default: the injection is only enabled by the
    // automated tests, never by a normal build.
    //
    //   none             the kernel does not inject anything
    //   invalid_opcode   #UD (vector 6), which pushes no error code
    //   bad_segment      #GP (vector 13), which pushes an error code
    //
    // The two vectors have different exception frame shapes, so both are
    // needed to cover the frame decoding.
    const fault_mode = b.option([]const u8, "fault-mode", "Which fault the kernel injects: none, invalid_opcode or bad_segment") orelse "none";

    const kernel_options = b.addOptions();
    kernel_options.addOption([]const u8, "fault_mode", fault_mode);

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
        }),
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "shared", .module = shared_module },
            .{ .name = "com1", .module = com1_module },
            .{ .name = "framebuffer", .module = framebuffer_module },
            .{ .name = "build_options", .module = kernel_options.createModule() },
        },
    });

    const kernel = b.addExecutable(.{
        .name = "azura-kernel.elf",
        .root_module = kernel_module,
    });
    // The kernel is loaded by the bootloader at a fixed physical address, so
    // it is linked at that address instead of the Zig default.
    kernel.setLinkerScript(b.path("kernel/linker.ld"));
    // The kernel is entered directly by the bootloader at this symbol, with
    // RDI pointing at the boot_info structure. See shared/boot_info.zig.
    kernel.entry = .{ .symbol_name = "azura_kernel_entry" };
    b.installArtifact(kernel);

    const kernel_step = b.step("kernel", "Build the freestanding kernel (ELF64)");
    kernel_step.dependOn(&b.addInstallArtifact(kernel, .{}).step);

    // ------------------------------------------------------------------
    // Static ELF gate for the kernel artifact
    // ------------------------------------------------------------------

    const elf_gate = b.addSystemCommand(&.{ "bash", "tools/check-kernel-elf.sh" });
    elf_gate.addArtifactArg(kernel);
    const elf_gate_step = b.step("kernel-elf-gate", "Validate the structure of the built kernel ELF");
    elf_gate_step.dependOn(&elf_gate.step);
    kernel_step.dependOn(&elf_gate.step);

    // ------------------------------------------------------------------
    // M0.1 toolchain probe (kept: it is the validated freestanding proof)
    // ------------------------------------------------------------------

    const probe = b.addSystemCommand(&.{ "bash", "tools/build-m01-probe.sh" });
    const probe_step = b.step("probe", "Build and inspect the freestanding ELF probe");
    probe_step.dependOn(&probe.step);

    const repeat = b.addSystemCommand(&.{ "bash", "tools/check-m01-rebuild.sh" });
    const repeat_step = b.step("rebuild-check", "Compare two probe builds on this host");
    repeat_step.dependOn(&repeat.step);

    // ------------------------------------------------------------------
    // Bootable disk image and QEMU run
    // ------------------------------------------------------------------

    // Path of the disk image, relative to the build root (the working
    // directory of every Run step). The path is an option so the fault
    // injection test can build into its own directory instead of replacing
    // the normal image.
    const esp_image = b.option([]const u8, "esp-image", "Path of the generated ESP image") orelse "zig-out/azura-esp.img";

    const esp = b.addSystemCommand(&.{ "bash", "tools/make-esp.sh" });
    esp.addArg(esp_image);
    esp.addArtifactArg(bootloader);
    esp.addArtifactArg(kernel);
    const esp_step = b.step("esp", "Build the EFI System Partition image");
    esp_step.dependOn(&esp.step);

    const qemu = b.addSystemCommand(&.{ "bash", "tools/run-qemu-m1.sh" });
    qemu.addArg(esp_image);
    qemu.has_side_effects = true;
    // The image must exist before QEMU is started: the dependency is on the
    // Run step itself, not only on the wrapper step, otherwise the two could
    // run in parallel.
    qemu.step.dependOn(&esp.step);
    const qemu_step = b.step("boot", "Boot the image in QEMU/OVMF and capture the serial log");
    qemu_step.dependOn(&qemu.step);

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    // The standard target options may only be requested once per build.
    const host_target = b.standardTargetOptions(.{});

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("boot/uefi/elf_loader.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });

    const shared_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("shared/framebuffer.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });

    // The GDT encoder is architecture specific but pure logic, so it is
    // verified on the host as well.
    const gdt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/arch/x86_64/gdt.zig"),
            .target = host_target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "com1", .module = com1_module },
            },
        }),
    });

    // The exception model (the frame layout and the classification of the
    // vectors) is pure logic too, so it is verified on the host as well.
    //
    // The IDT module itself cannot be: Zig 0.17 refuses to compile an
    // inline assembly label reference in a test build, so the per-vector
    // stubs cannot be instantiated on the host. The stub is verified in
    // the kernel instead, by `idt.verifyEntries`, which the QEMU boot
    // test exercises.
    const exception_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/arch/x86_64/exception.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    // Pure TSS descriptor encoding: test on the host before wiring LTR/IST.
    const tss_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/arch/x86_64/tss.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    const tss_test_run = b.addRunArtifact(tss_tests);
    const unit_test_run = b.addRunArtifact(unit_tests);
    const shared_test_run = b.addRunArtifact(shared_tests);
    const gdt_test_run = b.addRunArtifact(gdt_tests);
    const exception_test_run = b.addRunArtifact(exception_tests);
    const unit_test_step = b.step("unit-test", "Run the host unit tests");
    unit_test_step.dependOn(&unit_test_run.step);
    unit_test_step.dependOn(&shared_test_run.step);
    unit_test_step.dependOn(&gdt_test_run.step);
    unit_test_step.dependOn(&tss_test_run.step);
    unit_test_step.dependOn(&exception_test_run.step);

    const boot_test = b.addSystemCommand(&.{ "bash", "tests/boot/test-m1-boot.sh" });
    boot_test.addArg(esp_image);
    boot_test.has_side_effects = true;
    boot_test.step.dependOn(&esp.step);
    const boot_test_step = b.step("boot-test", "Run the automated M1 boot test in QEMU");
    boot_test_step.dependOn(&boot_test.step);

    const fault_test = b.addSystemCommand(&.{ "bash", "tests/boot/test-m1-fault-handler.sh" });
    fault_test.has_side_effects = true;
    const fault_test_step = b.step("fault-test", "Run the kernel exception handler test in QEMU");
    fault_test_step.dependOn(&fault_test.step);

    const ebs_retry_test = b.addSystemCommand(&.{ "bash", "tests/boot/test-m2.2-ebs-retry.sh" });
    ebs_retry_test.has_side_effects = true;
    const ebs_retry_test_step = b.step("ebs-retry-test", "Run the ExitBootServices stale key retry test in QEMU");
    ebs_retry_test_step.dependOn(&ebs_retry_test.step);

    const test_step = b.step("test", "Run every test: unit tests, boot test, fault handler test and the ExitBootServices retry test");
    test_step.dependOn(unit_test_step);
    test_step.dependOn(boot_test_step);
    test_step.dependOn(&fault_test.step);
    test_step.dependOn(&ebs_retry_test.step);
}
