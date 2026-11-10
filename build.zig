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
    // Sandy Bridge is a 2011 processor: the oldest hardware planZ aims at.
    // Its AMD counterpart in QEMU is Opteron_G4 (Bulldozer).
    const cpu = b.option([]const u8, "cpu", "QEMU cpu model (default SandyBridge)") orelse "SandyBridge";
    const memory = b.option([]const u8, "mem", "QEMU memory size (default 512M)") orelse "512M";

    const fmt = b.createModule(.{ .root_source_file = b.path("src/lib/fmt.zig") });
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
            .imports = &.{
                .{ .name = "bootinfo", .module = bootinfo },
                .{ .name = "fmt", .module = fmt },
            },
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
    addEsp(b, run, loader, kernel, null);
    run.addPassthruArgs();
    b.step("run", "Boot the kernel in QEMU (serial console on stdio)").dependOn(&run.step);

    // Boot tests: each boots headless with its own plan9.ini and waits
    // for a line on the serial console.
    const test_boot = b.step("test-boot", "Boot in headless QEMU and check the serial output");
    const BootTest = struct { ini: ?[]const u8, expect: []const u8 };
    const boot_tests = [_]BootTest{
        .{ .ini = null, .expect = "selftest ok" },
        .{ .ini = "*selftest=fault\n", .expect = "panic: kernel fault: write addr=0x1234" },
    };
    for (boot_tests) |t| {
        const bt = b.addSystemCommand(&.{ "sh", "tools/boottest.sh", "60", t.expect });
        bt.addArgs(qemu_args);
        bt.addArgs(&.{ "-display", "none" });
        addEsp(b, bt, loader, kernel, t.ini);
        test_boot.dependOn(&bt.step);
    }

    // Unit tests of the parts that do not need the machine, run on the host.
    const unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib/fmt.zig"),
        .target = b.graph.host,
    }) });
    b.step("test", "Run host unit tests").dependOn(&b.addRunArtifact(unit).step);
}

/// Give QEMU a FAT disk holding the loader, the kernel and, if given, a
/// plan9.ini.  The directory lives in the build cache.
fn addEsp(
    b: *std.Build,
    run: *std.Build.Step.Run,
    loader: *std.Build.Step.Compile,
    kernel: *std.Build.Step.Compile,
    ini: ?[]const u8,
) void {
    const esp = b.addWriteFiles();
    _ = esp.addCopyFile(loader.getEmittedBin(), "EFI/BOOT/BOOTX64.EFI");
    _ = esp.addCopyFile(kernel.getEmittedBin(), "planz");
    if (ini) |text| _ = esp.add("plan9.ini", text);
    run.addArg("-drive");
    run.addPrefixedDirectoryArg("format=raw,file=fat:rw:", esp.getDirectory());
}
