//! The command line: library housekeeping that happens twice a year.
//!
//!   kr8 root add DIR    index a folder (absorbs roots inside it) and scan it
//!   kr8 root rm DIR     forget a root (its sounds keep their tags)
//!   kr8 root list       the roots and their file counts
//!   kr8 scan            bring the library in line with the disk now
//!   kr8 tags            every tag and how many sounds carry it

const std = @import("std");
const library = @import("db/library.zig");
const scanner = @import("db/scanner.zig");

pub fn isCommand(word: []const u8) bool {
    return std.mem.eql(u8, word, "root") or std.mem.eql(u8, word, "scan") or std.mem.eql(u8, word, "tags");
}

pub const USAGE =
    \\library commands:
    \\  kr8 root add DIR    index a folder and scan it (a root inside it is absorbed)
    \\  kr8 root rm DIR     forget a root (its sounds keep their tags)
    \\  kr8 root list       the roots and their file counts
    \\  kr8 scan            rescan every root now
    \\  kr8 tags            every tag and how many sounds carry it
    \\
;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(s) catch {};
}

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var pb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const db_path = library.dbPath(&pb) orelse {
        out("kr8: no home folder for the library (HOME / KR8_HOME)\n", .{});
        return 1;
    };
    const lib = library.Library.open(gpa, db_path) catch |e| {
        out("kr8: can't open {s}: {s}\n", .{ db_path, @errorName(e) });
        return 1;
    };
    defer lib.close();

    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "scan")) {
        if (lib.roots.items.len == 0) {
            out("no roots yet - add one: kr8 root add ~/TRACKBASE/samples/trackers\n", .{});
            return 1;
        }
        return scanNow(gpa, lib, db_path);
    }
    if (std.mem.eql(u8, cmd, "tags")) {
        const tags = lib.listTags(gpa) catch return 1;
        defer library.Library.freeTags(gpa, tags);
        if (tags.len == 0) out("no tags yet - t in kr8 makes one\n", .{});
        for (tags) |t| out("{d:>6}  {s}\n", .{ @as(u64, @intCast(t.count)), t.name });
        return 0;
    }
    // root ...
    if (args.len < 2) {
        out("{s}", .{USAGE});
        return 2;
    }
    const sub = args[1];
    if (std.mem.eql(u8, sub, "list")) {
        if (lib.roots.items.len == 0) out("no roots yet - kr8 root add DIR\n", .{});
        for (lib.roots.items) |r| out("{d:>7} files  {s}\n", .{ @as(u64, @intCast(lib.rootFileCount(r.id))), r.path });
        const st = lib.stats();
        out("library: {d} sounds in {d} files, {d} sounds have copies, {d} tagged, {d} tags  ({s})\n", .{ st.sounds, st.files, st.dupe_sounds, st.tagged, st.tags, db_path });
        return 0;
    }
    if (args.len < 3) {
        out("kr8 root {s} needs a folder\n", .{sub});
        return 2;
    }
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fs.cwd().realpath(args[2], &rb) catch |e| {
        out("kr8: {s}: {s}\n", .{ args[2], @errorName(e) });
        return 1;
    };
    if (std.mem.eql(u8, sub, "add")) {
        const res = lib.addRoot(abs) catch |e| {
            if (e == error.InsideRoot) {
                out("{s} is already in the library (inside a root - see kr8 root list)\n", .{abs});
            } else out("kr8: can't add {s}: {s}\n", .{ abs, @errorName(e) });
            return 1;
        };
        out("root added: {s}\n", .{abs});
        if (res.absorbed > 0) out("  absorbed {d} root(s) inside it - no rehashing needed\n", .{res.absorbed});
        if (res.adopted > 0) out("  adopted {d} loose file(s) tagged before\n", .{res.adopted});
        return scanNow(gpa, lib, db_path);
    }
    if (std.mem.eql(u8, sub, "rm")) {
        lib.removeRoot(abs) catch |e| {
            if (e == error.NotARoot) {
                out("{s} is not a root - kr8 root list shows them\n", .{abs});
            } else out("kr8: {s}\n", .{@errorName(e)});
            return 1;
        };
        out("root removed: {s} (its sounds keep their tags; adding it again brings them back)\n", .{abs});
        return 0;
    }
    out("{s}", .{USAGE});
    return 2;
}

fn scanNow(gpa: std.mem.Allocator, lib: *library.Library, db_path: [:0]const u8) u8 {
    const t0 = std.time.milliTimestamp();
    const sc = scanner.Scanner.start(gpa, db_path) catch |e| {
        out("kr8: scan failed to start: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer sc.deinit();
    const stdout = std.fs.File.stdout();
    const tty = stdout.isTty();
    while (sc.prog.running.load(.seq_cst)) {
        if (tty) out("\rscanning {d}/{d}  (new or changed: {d})   ", .{ sc.prog.done.load(.seq_cst), sc.prog.total.load(.seq_cst), sc.prog.hashed.load(.seq_cst) });
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    sc.join();
    if (tty) out("\r", .{});
    if (sc.err) |e| {
        out("scan failed: {s}\n", .{@errorName(e)});
        return 1;
    }
    const ms = std.time.milliTimestamp() - t0;
    out("scanned {d} files in {d}.{d} s - {d} new or changed, {d} unreadable\n", .{
        sc.prog.done.load(.seq_cst),                        @divTrunc(ms, 1000), @divTrunc(@mod(ms, 1000), 100),
        sc.prog.hashed.load(.seq_cst), sc.prog.failed.load(.seq_cst),
    });
    const st = lib.stats();
    out("library: {d} sounds in {d} files, {d} sounds have copies, {d} tagged\n", .{ st.sounds, st.files, st.dupe_sounds, st.tagged });
    return 0;
}
