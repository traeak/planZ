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
    const smp = b.option([]const u8, "smp", "QEMU processors (default 4)") orelse "4";
    // Unmodified 9front binaries, to check binary compatibility.  They
    // are not in the repository; see "Reference binaries" in PLAN.md for
    // what the directory must hold.
    disk_image = b.option([]const u8, "disk", "Disk image to attach as a virtio disk, e.g. ref/disk/9front-11952.amd64.qcow2 (never written: changes are discarded)");
    disk_bus = b.option([]const u8, "diskbus", "How the disk image is attached: virtio (default), nvme or ahci") orelse "virtio";
    const ref = b.option([]const u8, "ref", "Directory of 9front reference files, e.g. ref");
    const usb_esp_mb = b.option(u32, "usbesp", "Size in MiB of the boot volume of the USB image (default 40)") orelse 40;

    const fmt = b.createModule(.{ .root_source_file = b.path("src/lib/fmt.zig") });
    const fcall = b.createModule(.{ .root_source_file = b.path("src/lib/fcall.zig") });
    const bootinfo = b.createModule(.{ .root_source_file = b.path("src/boot/bootinfo.zig") });
    // The library of planZ's own user programs, and the pool allocator
    // it shares with the kernel.
    const pool = b.createModule(.{
        .root_source_file = b.path("src/kernel/port/pool.zig"),
        .imports = &.{.{ .name = "fmt", .module = fmt }},
    });
    const libc = b.createModule(.{
        .root_source_file = b.path("src/user/lib/libc.zig"),
        .imports = &.{
            .{ .name = "fmt", .module = fmt },
            .{ .name = "fcall", .module = fcall },
            .{ .name = "pool", .module = pool },
        },
    });

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
    const initcode = addUserProgram(b, "initcode", "src/user/initcode.zig", optimize, libc);
    const bootprog = addUserProgram(b, "boot", "src/user/boot.zig", optimize, libc);

    b.getInstallStep().dependOn(&b.addInstallFile(initcode, "user/initcode").step);
    b.getInstallStep().dependOn(&b.addInstallFile(bootprog, "user/boot").step);

    // Commands written in Zig on the library, installed in
    // zig-out/user/bin by `zig build user`.
    const user_step = b.step("user", "Build the user programs written in Zig into zig-out/user/bin");
    const zcmds = [_][]const u8{ "echo", "cat", "ls", "wc", "libctest" };
    var zbins: [zcmds.len]std.Build.LazyPath = undefined;
    for (zcmds, 0..) |name, i| {
        zbins[i] = addLibcProgram(b, name, b.fmt("src/user/cmd/{s}.zig", .{name}), optimize, libc);
        user_step.dependOn(&b.addInstallFile(zbins[i], b.fmt("user/bin/{s}", .{name})).step);
    }

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
        "-smp",
        smp,
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
            "planz9front", "ls /dev/cons /dev/time && echo ls^ok",
            "lsok",        "cat /dev/pid && echo pid^ok",
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

        // With a disk image as well: take the root file system from the
        // disk, as bootrc offers, and use the system that comes up.
        if (disk_image != null) {
            const dchat = b.addSystemCommand(&.{ "sh", "tools/disktest.sh", "180" });
            dchat.addArgs(qemu_args);
            dchat.addArgs(&.{ "-display", "none" });
            addEsp(b, dchat, loader, kernel, ini9, dir);
            b.step("test-disk", "Boot stock 9front from the disk image and use it").dependOn(&dchat.step);

            // And the network: DHCP, ping, and a file over TCP.
            const nchat = b.addSystemCommand(&.{ "sh", "tools/nettest.sh", "240" });
            nchat.addArgs(qemu_args);
            nchat.addArgs(&.{ "-display", "none" });
            addEsp(b, nchat, loader, kernel, ini9, dir);
            b.step("test-net", "Boot stock 9front from the disk image and use the network").dependOn(&nchat.step);

            // And sound: a tone played through the HDA driver to a wav
            // file, which is checked.
            const achat = b.addSystemCommand(&.{ "sh", "tools/audiotest.sh", "240" });
            achat.addArgs(qemu_args);
            achat.addArgs(&.{ "-display", "none" });
            addEsp(b, achat, loader, kernel, ini9, dir);
            b.step("test-audio", "Boot stock 9front from the disk image and play a tone through the HDA driver").dependOn(&achat.step);

            // planZ's Zig programs beside the stock ones they copy.
            const zchat = b.addSystemCommand(&.{ "sh", "tools/zusertest.sh", "300", "zig-out/user/bin" });
            zchat.addArgs(qemu_args);
            zchat.addArgs(&.{ "-display", "none" });
            addEsp(b, zchat, loader, kernel, ini9, dir);
            zchat.step.dependOn(user_step);
            b.step("test-zuser", "Boot stock 9front and compare planZ's Zig programs with the stock ones").dependOn(&zchat.step);

            // The same through a USB Ethernet adapter, which stock
            // nusb/ether drives from user space over the kernel's USB
            // stack.  The virtio card is still there; the test names
            // the USB interface.
            const unchat = b.addSystemCommand(&.{ "sh", "tools/usbnettest.sh", "240" });
            unchat.addArgs(qemu_args);
            unchat.addArgs(&.{ "-display", "none" });
            addEsp(b, unchat, loader, kernel, ini9, dir);
            b.step("test-usbnet", "Boot stock 9front from the disk image and use the network through a USB adapter").dependOn(&unchat.step);

            // And the screen: rio, a typed key and a moved mouse, once
            // with the PS/2 devices and once with USB ones only.
            const rio = b.step("test-rio", "Boot stock 9front from the disk image into rio and use keyboard and mouse");
            for ([_][]const []const u8{
                &.{},
                &.{ "-machine", "q35,i8042=off", "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-mouse" },
            }) |extra| {
                const rchat = b.addSystemCommand(&.{ "sh", "tools/riotest.sh", "240" });
                rchat.addArgs(qemu_args);
                rchat.addArgs(&.{ "-display", "none" });
                rchat.addArgs(extra);
                addEsp(b, rchat, loader, kernel, ini9 ++ "mouseport=ps2\n", dir);
                rio.dependOn(&rchat.step);
            }

            // A disk image for a USB stick, to boot a real machine with
            // no other disk: the boot volume with tools/usb.ini as its
            // plan9.ini, then the Plan 9 partition of the 9front image
            // for the root.  It is written straight into zig-out (it is
            // 3.8GB, though sparse) and read back as a check.
            const usb_image = "zig-out/planz-usb.img";
            const usb = b.step("usb-image", "Write " ++ usb_image ++ ", a disk image to copy onto a USB stick with dd");
            var usb_write: ?*std.Build.Step.Run = null;
            var usb_check: *std.Build.Step.Run = undefined;
            for ([_][]const u8{ "-o", "--check" }) |how| {
                const mk = b.addSystemCommand(&.{ "python3", "-I", "tools/mkusb.py", how, usb_image });
                mk.addArgs(&.{ "--esp-mb", b.fmt("{d}", .{usb_esp_mb}) });
                mk.addPrefixedFileArg("--disk=", b.path(disk_image.?));
                mk.addPrefixedFileArg("EFI/BOOT/BOOTX64.EFI=", loader.getEmittedBin());
                mk.addPrefixedFileArg("planz=", kernel.getEmittedBin());
                mk.addPrefixedFileArg("plan9.ini=", b.path("tools/usb.ini"));
                mk.addPrefixedFileArg("boot/boot=", b.path(b.pathJoin(&.{ dir, "boot/boot" })));
                mk.addPrefixedFileArg("boot/bootfs.paq=", b.path(b.pathJoin(&.{ dir, "boot/bootfs.paq" })));
                mk.addPrefixedFileArg("boot/paqfs=", b.path(b.pathJoin(&.{ dir, "root/amd64/bin/paqfs" })));
                mk.addPrefixedFileArg("boot/factotum=", b.path(b.pathJoin(&.{ dir, "root/amd64/bin/auth/factotum" })));
                // planZ's Zig programs and the script that installs and
                // checks them (docs/hardware-checklist.md)
                for (zcmds, zbins) |name, bin|
                    mk.addPrefixedFileArg(b.fmt("zig/bin/{s}=", .{name}), bin);
                mk.addPrefixedFileArg("zig/run=", b.path("tools/usbzig.rc"));
                mk.has_side_effects = true;
                if (usb_write) |w| mk.step.dependOn(&w.step);
                usb_write = usb_write orelse mk;
                usb_check = mk;
            }
            usb.dependOn(&usb_check.step);

            // Boot that image in QEMU as the only disk, on USB, with a
            // USB keyboard and pointer and no PS/2 controller.
            const utest = b.addSystemCommand(&.{ "sh", "tools/usbtest.sh", "240", usb_image });
            utest.addArgs(qemu_args);
            utest.addArgs(&.{ "-display", "none" });
            utest.step.dependOn(&usb_check.step);
            b.step("test-usb", "Boot the USB image in QEMU from a USB disk into rio and use it").dependOn(&utest.step);
        }
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
    {
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/drawtest.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "fmt", .module = fmt },
                .{ .name = "fcall", .module = fcall },
            },
        }) });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
    {
        // The pool allocator; see the top of the file.
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/pooltest.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "fmt", .module = fmt },
            },
        }) });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}

/// Build a user program on the library (src/user/lib): the library's
/// root.zig is the root file and the program's file is the module
/// "program".
fn addLibcProgram(b: *std.Build, name: []const u8, root: []const u8, optimize: std.lang.Optimize, libc: *std.Build.Module) std.Build.LazyPath {
    const program = b.createModule(.{
        .root_source_file = b.path(root),
        .imports = &.{.{ .name = "libc", .module = libc }},
    });
    return addUserProgramRoot(b, name, "src/user/lib/root.zig", optimize, &.{
        .{ .name = "libc", .module = libc },
        .{ .name = "program", .module = program },
    });
}

fn addUserProgram(b: *std.Build, name: []const u8, root: []const u8, optimize: std.lang.Optimize, libc: *std.Build.Module) std.Build.LazyPath {
    return addUserProgramRoot(b, name, root, optimize, &.{.{ .name = "libc", .module = libc }});
}

/// Build a user program for the Plan 9 amd64 ABI and return its a.out.
/// The linker script writes the a.out header, so the flat binary of the
/// link is the executable.
fn addUserProgramRoot(b: *std.Build, name: []const u8, root: []const u8, optimize: std.lang.Optimize, imports: []const std.Build.Module.Import) std.Build.LazyPath {
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
            .imports = imports,
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

    // Devices for the drivers: a network card on QEMU's user-mode
    // network and, when an image is given, a disk.  Both are virtio 1.0
    // only.  The image is opened as a snapshot, so it is never changed.
    run.addArgs(&.{
        "-netdev", "user,id=n0",
        "-device", "virtio-net-pci,netdev=n0,disable-legacy=on",
    });
    if (disk_image) |img| {
        run.addArg("-drive");
        run.addPrefixedFileArg("if=none,id=d0,snapshot=on,file=", b.path(img));
        run.addArgs(&.{ "-device", diskDevice(disk_bus) });
    }
}

var disk_image: ?[]const u8 = null;
var disk_bus: []const u8 = "virtio";

/// The QEMU device that presents drive d0 on the given bus.
fn diskDevice(bus: []const u8) []const u8 {
    if (std.mem.eql(u8, bus, "nvme")) return "nvme,drive=d0,serial=planz0";
    // q35 has an AHCI controller built in; the EFI partition is on its port 0.
    if (std.mem.eql(u8, bus, "ahci")) return "ide-hd,drive=d0,bus=ide.2";
    if (std.mem.eql(u8, bus, "virtio")) return "virtio-blk-pci,drive=d0,disable-legacy=on";
    @panic("-Ddiskbus must be virtio, nvme or ahci");
}
