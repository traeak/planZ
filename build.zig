const std = @import("std");

pub fn build(b: *std.Build) void {
    // The kernel has 8K process stacks; Debug frames are too big for that.
    const optimize = b.option(
        std.lang.Optimize,
        "optimize",
        "Kernel and loader optimization mode (default safe)",
    ) orelse .safe;
    const firmware = b.option(
        []const u8,
        "firmware",
        "UEFI firmware image for QEMU",
    ) orelse "/usr/share/qemu/edk2-x86_64-code.fd";
    // Westmere is a 2010 processor: the oldest hardware planZ aims at.
    const cpu = b.option([]const u8, "cpu", "QEMU cpu model (default Westmere)") orelse "Westmere";
    const memory = b.option([]const u8, "mem", "QEMU memory size (default 512M)") orelse "512M";

    const bootinfo = b.createModule(.{ .root_source_file = b.path("src/boot/bootinfo.zig") });

    // The kernel: freestanding, no floating point or vector registers
    // (they belong to user processes), no red zone (interrupts run on
    // the interrupted stack), linked in the top 2GiB.
    const x86 = std.Target.x86;
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = x86.featureSet(&.{.soft_float}),
        .cpu_features_sub = x86.featureSet(&.{ .mmx, .sse, .sse2, .avx, .avx2 }),
    });
    const kernel = b.addExecutable(.{
        .name = "planz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/kernel.zig"),
            .target = kernel_target,
            .optimize = optimize,
            .code_model = .kernel,
            .red_zone = false,
            .pic = false,
            .omit_frame_pointer = false,
            .single_threaded = true,
            .imports = &.{.{ .name = "bootinfo", .module = bootinfo }},
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    kernel.setLinkerScript(b.path("src/kernel/arch/amd64/kernel.ld"));
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.pie = false;

    const loader = b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot/loader.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .uefi,
                .abi = .msvc,
            }),
            .optimize = optimize,
            .imports = &.{.{ .name = "bootinfo", .module = bootinfo }},
        }),
    });

    // zig-out/esp is the EFI system partition QEMU boots from.
    const install_loader = b.addInstallFile(loader.getEmittedBin(), "esp/EFI/BOOT/BOOTX64.EFI");
    const install_kernel = b.addInstallFile(kernel.getEmittedBin(), "esp/planz");
    b.getInstallStep().dependOn(&install_loader.step);
    b.getInstallStep().dependOn(&install_kernel.step);

    // The same tree from the build cache, for QEMU to boot from.
    const esp = b.addWriteFiles();
    _ = esp.addCopyFile(loader.getEmittedBin(), "EFI/BOOT/BOOTX64.EFI");
    _ = esp.addCopyFile(kernel.getEmittedBin(), "planz");

    const qemu_args: []const []const u8 = &.{
        "qemu-system-x86_64",
        "-machine",
        "q35",
        "-cpu",
        cpu,
        "-m",
        memory,
        "-drive",
        b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{firmware}),
        "-net",
        "none",
        "-serial",
        "stdio",
        "-no-reboot",
    };

    const run = b.addSystemCommand(qemu_args);
    addEsp(run, esp);
    run.addPassthruArgs();
    b.step("run", "Boot the kernel in QEMU (serial console on stdio)").dependOn(&run.step);

    const boot_test = b.addSystemCommand(&.{ "sh", "tools/boottest.sh", "60", "Plan 9" });
    boot_test.addArgs(qemu_args);
    boot_test.addArgs(&.{ "-display", "none" });
    addEsp(boot_test, esp);
    b.step("test-boot", "Boot in headless QEMU and check the serial output").dependOn(&boot_test.step);
}

/// Give QEMU the directory as a FAT disk.
fn addEsp(run: *std.Build.Step.Run, esp: *std.Build.Step.WriteFile) void {
    run.addArg("-drive");
    run.addPrefixedDirectoryArg("format=raw,file=fat:rw:", esp.getDirectory());
}
