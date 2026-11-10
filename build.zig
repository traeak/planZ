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
    // Its AMD counterpart in QEMU is Opteron_G4 (Bulldozer), which must be
    // given as "Opteron_G4,+xsaveopt": QEMU's emulator hangs on enabling
    // XSAVE for a model that has XSAVE but not XSAVEOPT.
    const cpu = b.option([]const u8, "cpu", "QEMU cpu model (default SandyBridge)") orelse "SandyBridge";
    const memory = b.option([]const u8, "mem", "QEMU memory size (default 512M)") orelse "512M";
    // Unmodified 9front binaries, to check binary compatibility.  They
    // are not in the repository; see "Reference binaries" in PLAN.md for
    // what the directory must hold.
    const ref = b.option([]const u8, "ref", "Directory of 9front reference files, e.g. ref");

    const fmt = b.createModule(.{ .root_source_file = b.path("src/lib/fmt.zig") });
    const fcall = b.createModule(.{ .root_source_file = b.path("src/lib/fcall.zig") });
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
    // planZ's own user programs, linked as Plan 9 a.out files, which the
    // kernel carries in its data: initcode, the first process, and the
    // /boot/boot it execs.
    const initcode = addUserProgram(b, "initcode", "src/user/initcode.zig", optimize);
    const bootprog = addUserProgram(b, "boot", "src/user/boot.zig", optimize);

    b.getInstallStep().dependOn(&b.addInstallFile(initcode, "user/initcode").step);
    b.getInstallStep().dependOn(&b.addInstallFile(bootprog, "user/boot").step);

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
                .{ .name = "fcall", .module = fcall },
            },
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    kernel.root_module.addAnonymousImport("initcode", .{ .root_source_file = initcode });
    kernel.root_module.addAnonymousImport("bootprog", .{ .root_source_file = bootprog });
    // An empty file stands for "no stock binaries given".
    kernel.root_module.addAnonymousImport("stockecho", .{
        .root_source_file = if (ref) |dir| b.path(b.pathJoin(&.{ dir, "root/amd64/bin/echo" })) else b.addWriteFiles().add("none", ""),
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
    addEsp(b, run, loader, kernel, null, null);
    run.addPassthruArgs();
    b.step("run", "Boot the kernel in QEMU (serial console on stdio)").dependOn(&run.step);

    // Boot tests: each boots headless with its own plan9.ini and waits
    // for a line on the serial console.
    const test_boot = b.step("test-boot", "Boot in headless QEMU and check the serial output");
    const BootTest = struct { ini: ?[]const u8, expect: []const u8 };
    const boot_tests = [_]BootTest{
        .{
            .ini = null,
            .expect = if (ref != null)
                "selftest ok|usertest ok|hello from stock 9front echo"
            else
                "selftest ok|usertest ok",
        },
        .{ .ini = "*selftest=fault\n*schedtest=1\n", .expect = "panic: kernel fault: write addr=0x1234" },
    };
    for (boot_tests) |t| {
        const bt = b.addSystemCommand(&.{ "sh", "tools/boottest.sh", "60", t.expect });
        bt.addArgs(qemu_args);
        bt.addArgs(&.{ "-display", "none" });
        addEsp(b, bt, loader, kernel, t.ini, null);
        test_boot.dependOn(&bt.step);
    }

    // With the reference files: boot 9front's own boot program, paqfs
    // and boot file system, with the console on the serial port.
    if (ref) |dir| {
        const ini9 = "console=0\n";

        const run9 = b.addSystemCommand(qemu_args);
        addEsp(b, run9, loader, kernel, ini9, dir);
        run9.addPassthruArgs();
        b.step("run9", "Boot stock 9front user programs in QEMU (serial console on stdio)").dependOn(&run9.step);

        // At bootrc's question, ask for a shell and use it.
        // The conversation: what to wait for, then what to type.
        // (ps is not in the boot file system; cat reads what it reads.)
        const chat = b.addSystemCommand(&.{ "sh", "tools/bootchat.sh", "120" });
        chat.addArgs(&.{
            "bootargs is", "!rc",
            "% ",          "echo planz^9front",
            "planz9front", "ls /dev/cons /dev/time",
            "/dev/time",   "cat /dev/pid && echo pid^ok",
            "pidok",       "cat /proc/1/status | sed 1q && echo st^ok",
            "stok",        "ls /proc | sed 3q && cat /dev/time && echo time^ok",
            "timeok",      "ls /bin | grep -c . && echo union^ok",
            "unionok",     "--",
        });
        chat.addArgs(qemu_args);
        chat.addArgs(&.{ "-display", "none" });
        addEsp(b, chat, loader, kernel, ini9, dir);
        const test9 = b.step("test-9front", "Boot stock 9front user programs to a shell and use it");
        test9.dependOn(&chat.step);
    }

    // The portable kernel must compile for the architectures planZ means
    // to reach later, against an architecture layer that does nothing.
    const check_ports = b.step("check-ports", "Compile the portable kernel for aarch64 and riscv64");
    for ([_]std.Target.Cpu.Arch{ .aarch64, .riscv64 }) |cpu_arch| {
        const obj = b.addObject(.{
            .name = b.fmt("portcheck-{s}", .{@tagName(cpu_arch)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/kernel/portcheck.zig"),
                .target = b.resolveTargetQuery(.{ .cpu_arch = cpu_arch, .os_tag = .freestanding, .abi = .none }),
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "bootinfo", .module = bootinfo },
                    .{ .name = "fmt", .module = fmt },
                    .{ .name = "fcall", .module = fcall },
                },
            }),
        });
        // Any initcode will do for a compile check.
        obj.root_module.addAnonymousImport("initcode", .{ .root_source_file = initcode });
        check_ports.dependOn(&obj.step);
    }

    // Unit tests of the parts that do not need the machine, run on the host.
    const test_step = b.step("test", "Run host unit tests");
    for ([_][]const u8{ "src/lib/fmt.zig", "src/lib/fcall.zig", "src/kernel/port/lib.zig" }) |file| {
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = b.graph.host,
        }) });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}

/// Build a user program for the Plan 9 amd64 ABI and return its a.out.
/// The linker script writes the a.out header, so the flat binary of the
/// link is the executable.
fn addUserProgram(b: *std.Build, name: []const u8, root: []const u8, optimize: std.lang.Optimize) std.Build.LazyPath {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .freestanding, .abi = .none }),
            // Debug code is several times larger, and initcode must fit in a page.
            .optimize = if (optimize == .debug) .small else optimize,
            .pic = false,
            .single_threaded = true,
            .strip = true,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    exe.setLinkerScript(b.path("src/user/user.ld"));
    exe.entry = .{ .symbol_name = "_start" };
    exe.pie = false;
    return exe.addObjCopy(.{ .format = .binary }).getOutput();
}

/// Give QEMU a FAT disk holding the loader, the kernel and, if given, a
/// plan9.ini.  The directory lives in the build cache.
fn addEsp(
    b: *std.Build,
    run: *std.Build.Step.Run,
    loader: *std.Build.Step.Compile,
    kernel: *std.Build.Step.Compile,
    ini: ?[]const u8,
    /// Reference directory to take 9front's boot files from, or null.
    ref: ?[]const u8,
) void {
    const esp = b.addWriteFiles();
    _ = esp.addCopyFile(loader.getEmittedBin(), "EFI/BOOT/BOOTX64.EFI");
    _ = esp.addCopyFile(kernel.getEmittedBin(), "planz");
    if (ini) |text| _ = esp.add("plan9.ini", text);
    if (ref) |dir| {
        _ = esp.addCopyFile(b.path(b.pathJoin(&.{ dir, "boot/boot" })), "boot/boot");
        _ = esp.addCopyFile(b.path(b.pathJoin(&.{ dir, "boot/bootfs.paq" })), "boot/bootfs.paq");
        _ = esp.addCopyFile(b.path(b.pathJoin(&.{ dir, "root/amd64/bin/paqfs" })), "boot/paqfs");
        _ = esp.addCopyFile(b.path(b.pathJoin(&.{ dir, "root/amd64/bin/auth/factotum" })), "boot/factotum");
    }
    run.addArg("-drive");
    run.addPrefixedDirectoryArg("format=raw,file=fat:rw:", esp.getDirectory());
}
