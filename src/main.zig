//! kr8 - a keyboard-driven terminal sample browser.
//!
//!   kr8 [DIR ...]      open one pane per DIR (up to 4); no DIR = the
//!                      panes of the last session (or the current folder)

const std = @import("std");
const app = @import("app/app.zig");
const cli = @import("cli.zig");
const term = @import("app/term.zig");
const build_options = @import("build_options");

/// zig `defer`s don't run on @panic: restore the terminal first, or a
/// crash strands the shell in raw mode on the alternate screen.
pub const panic = std.debug.FullPanic(panicRestore);

fn panicRestore(msg: []const u8, first_trace_addr: ?usize) noreturn {
    term.panicCleanup();
    std.debug.defaultPanic(msg, first_trace_addr);
}

const USAGE =
    \\kr8 - browse, audition and (soon) tag samples
    \\
    \\usage: kr8 [options] [DIR ...]
    \\
    \\  DIR ...           open a pane per folder (max 4); none = last session
    \\  --no-audio        don't open the audio device
    \\  --volume 0-100    start at this preview volume (- + change it)
    \\  --scheme NAME     colour scheme (T cycles them in the app)
    \\  -V, --version
    \\  -h, --help
    \\
    \\testing:
    \\  --dump-screen     run headless, print the text layer
    \\  --shot FILE.png   run headless, save the pixel layer
    \\  --frames N        headless frames to run (default 30)
    \\  --size COLSxROWS  headless screen size (default 120x36)
    \\  --keys SCRIPT     scripted keys: "5:j,8:space,12:text=kick"
    \\
    \\KR8_HOME=DIR moves the config and the library (default ~/.config/kr8).
    \\
    \\
;

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // library housekeeping: kr8 root ... / scan / tags (a folder named like
    // one of these opens as ./root)
    if (args.len > 1 and cli.isCommand(args[1])) {
        const rest = try allocator.alloc([]const u8, args.len - 1);
        defer allocator.free(rest);
        for (args[1..], 0..) |a, i| rest[i] = a;
        return cli.run(allocator, rest);
    }

    var opts: app.Options = .{};
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--no-audio")) {
            opts.no_audio = true;
        } else if (std.mem.eql(u8, a, "--volume")) {
            i += 1;
            if (i >= args.len) return usage("--volume needs 0-100");
            const v = std.fmt.parseInt(u8, args[i], 10) catch return usage("--volume needs 0-100");
            opts.volume = @as(f32, @floatFromInt(@min(v, 100))) / 100.0;
        } else if (std.mem.eql(u8, a, "--scheme")) {
            i += 1;
            if (i >= args.len) return usage("--scheme needs a name");
            opts.scheme = args[i];
        } else if (std.mem.eql(u8, a, "--dump-screen")) {
            opts.headless = true;
            opts.dump = true;
        } else if (std.mem.eql(u8, a, "--shot")) {
            i += 1;
            if (i >= args.len) return usage("--shot needs a .png path");
            opts.headless = true;
            opts.shot = args[i];
        } else if (std.mem.eql(u8, a, "--frames")) {
            i += 1;
            if (i >= args.len) return usage("--frames needs a number");
            opts.frames = std.fmt.parseInt(u64, args[i], 10) catch return usage("--frames needs a number");
        } else if (std.mem.eql(u8, a, "--size")) {
            i += 1;
            if (i >= args.len) return usage("--size needs COLSxROWS");
            const x = std.mem.indexOfScalar(u8, args[i], 'x') orelse return usage("--size needs COLSxROWS");
            opts.cols = std.fmt.parseInt(usize, args[i][0..x], 10) catch return usage("--size needs COLSxROWS");
            opts.rows = std.fmt.parseInt(usize, args[i][x + 1 ..], 10) catch return usage("--size needs COLSxROWS");
        } else if (std.mem.eql(u8, a, "--keys")) {
            i += 1;
            if (i >= args.len) return usage("--keys needs a script");
            opts.keys = args[i];
        } else if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            std.fs.File.stdout().writeAll("kr8 " ++ build_options.version ++ "\n") catch {};
            return 0;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.fs.File.stdout().writeAll(USAGE) catch {};
            std.fs.File.stdout().writeAll(cli.USAGE) catch {};
            return 0;
        } else if (std.mem.startsWith(u8, a, "--")) {
            std.debug.print("kr8: unknown option {s}\n\n{s}", .{ a, USAGE });
            return 2;
        } else {
            try dirs.append(allocator, a);
        }
    }
    if (opts.headless) {
        opts.cols = @max(opts.cols, 80);
        opts.rows = @max(opts.rows, 24);
    }
    opts.dirs = dirs.items;
    return app.run(allocator, opts);
}

fn usage(msg: []const u8) u8 {
    std.debug.print("kr8: {s}\n\n{s}", .{ msg, USAGE });
    return 2;
}

test {
    _ = @import("audio/wav.zig");
    _ = @import("app/pane.zig");
    _ = @import("app/copier.zig");
    _ = @import("db/library.zig");
    _ = @import("app/view.zig");
    _ = @import("app/ui/motion.zig");
}
