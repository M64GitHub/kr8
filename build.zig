const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseFast by default: a 60 fps glow compositor wants it, and the
    // tests are the safety net (`zig build test -Doptimize=Debug`)
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

    const dep_movy = b.dependency("movy", .{ .target = target, .optimize = optimize });

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("movy", dep_movy.module("movy"));
    exe_mod.addOptions("build_options", options);

    // miniaudio: the header is compiled once, as C, in the shim; Zig only
    // sees the kr8_* externs (src/audio/audio.zig)
    exe_mod.addIncludePath(b.path("vendor/miniaudio"));
    exe_mod.addIncludePath(b.path("src/audio"));
    exe_mod.addCSourceFile(.{
        .file = b.path("src/audio/shim.c"),
        .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
    });
    // SQLite, the amalgamation compiled in (the library database)
    const dep_sqlite = b.dependency("sqlite", .{});
    exe_mod.addIncludePath(dep_sqlite.path("."));
    exe_mod.addCSourceFile(.{
        .file = dep_sqlite.path("sqlite3.c"),
        .flags = &.{
            "-std=c99",                      "-fno-sanitize=undefined",
            "-DSQLITE_DQS=0",                "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",  "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_SHARED_CACHE",    "-DSQLITE_THREADSAFE=1",
        },
    });
    exe_mod.addCSourceFile(.{ .file = b.path("src/db/sqlite_shim.c"), .flags = &.{"-std=c99"} });
    switch (target.result.os.tag) {
        .macos => {
            // MA_NO_RUNTIME_LINKING in the shim -> the frameworks directly
            for ([_][]const u8{ "CoreFoundation", "CoreAudio", "AudioToolbox", "AudioUnit" }) |fw|
                exe_mod.linkFramework(fw, .{});
        },
        .linux => {
            // miniaudio dlopens ALSA/PulseAudio at runtime - no dev packages
            exe_mod.linkSystemLibrary("pthread", .{});
            exe_mod.linkSystemLibrary("m", .{});
            exe_mod.linkSystemLibrary("dl", .{});
        },
        else => {},
    }

    const exe = b.addExecutable(.{ .name = "kr8", .root_module = exe_mod });
    if (target.result.os.tag == .macos) exe.headerpad_max_install_names = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run kr8").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
