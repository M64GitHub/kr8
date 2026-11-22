//! THE SCANNER: brings the library in line with the disk.
//!
//! Walks every root (dot files and folders skipped, WAVs only), then for
//! each file: same size + mtime as the library has -> just mark it seen;
//! else fingerprint it and upsert its sound and file rows. Commits every
//! BATCH files (short transactions: the UI's own writes slip in between,
//! and the panes refresh as the scan goes). At the end, file rows not
//! seen this time are dropped - their sounds stay, tags and all.
//!
//! Runs on its own thread with its own connection (`Scanner`), or inline
//! for the command line (`scanAll`). Progress is atomics only.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const library = @import("library.zig");
const pane = @import("../app/pane.zig");

const BATCH = 400;

pub const Progress = struct {
    total: std.atomic.Value(u32) = .init(0),
    done: std.atomic.Value(u32) = .init(0),
    hashed: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),
    /// steps on every commit: the UI refreshes what it shows
    commits: std.atomic.Value(u32) = .init(0),
    running: std.atomic.Value(bool) = .init(false),
    /// steps when a whole scan has finished
    finished: std.atomic.Value(u32) = .init(0),
    quit: std.atomic.Value(bool) = .init(false),
};

const Item = struct { root_id: i64, root: []const u8, rel: []u8, size: u64, mtime: i64 };

fn hidden(rel: []const u8) bool {
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| if (part.len > 0 and part[0] == '.') return true;
    return false;
}

pub fn scanAll(gpa: std.mem.Allocator, db_path: [:0]const u8, prog: *Progress) !void {
    prog.running.store(true, .seq_cst);
    defer prog.running.store(false, .seq_cst);
    prog.total.store(0, .seq_cst);
    prog.done.store(0, .seq_cst);
    prog.hashed.store(0, .seq_cst);
    prog.failed.store(0, .seq_cst);

    var db = try sqlite.Db.open(db_path);
    defer db.close();
    try db.exec(library.SCHEMA);
    try db.exec("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'scan_gen'");
    var gen: i64 = 0;
    {
        var q = try db.prepare("SELECT value FROM meta WHERE key = 'scan_gen'");
        defer q.deinit();
        if (try q.step()) gen = std.fmt.parseInt(i64, q.text(0), 10) catch 0;
    }

    // the roots
    var roots: std.ArrayList(library.Root) = .empty;
    defer {
        for (roots.items) |r| gpa.free(r.path);
        roots.deinit(gpa);
    }
    {
        var q = try db.prepare("SELECT id, path FROM root");
        defer q.deinit();
        while (try q.step()) try roots.append(gpa, .{ .id = q.int(0), .path = try gpa.dupe(u8, q.text(1)) });
    }

    // every WAV under them (so the total is known before the slow part)
    var items: std.ArrayList(Item) = .empty;
    defer {
        for (items.items) |it| gpa.free(it.rel);
        items.deinit(gpa);
    }
    var walked_ok: std.ArrayList(i64) = .empty; // roots walked to the end
    defer walked_ok.deinit(gpa);
    for (roots.items) |r| {
        var dir = std.fs.openDirAbsolute(r.path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        var complete = true;
        while (true) {
            if (prog.quit.load(.seq_cst)) return;
            const e = walker.next() catch {
                complete = false;
                break;
            } orelse break;
            if (e.kind != .file) continue;
            if (hidden(e.path) or !pane.isAudioName(e.basename)) continue;
            const st = e.dir.statFile(e.basename) catch continue;
            try items.append(gpa, .{
                .root_id = r.id,
                .root = r.path,
                .rel = try gpa.dupe(u8, e.path),
                .size = st.size,
                .mtime = @intCast(@divTrunc(st.mtime, std.time.ns_per_ms)),
            });
            prog.total.store(@intCast(items.items.len), .seq_cst);
        }
        if (complete) try walked_ok.append(gpa, r.id);
    }

    var idx = try library.Indexer.init(&db);
    defer idx.deinit();
    var look = try db.prepare("SELECT size, mtime FROM file WHERE root_id = ?1 AND path = ?2");
    defer look.deinit();
    var touch = try db.prepare("UPDATE file SET seen = ?1 WHERE root_id = ?2 AND path = ?3");
    defer touch.deinit();

    try db.exec("BEGIN");
    var in_tx = true;
    defer if (in_tx) db.exec("COMMIT") catch {};
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (items.items, 0..) |it, i| {
        if (prog.quit.load(.seq_cst)) return;
        var same = false;
        {
            defer look.reset();
            try look.bindInt(1, it.root_id);
            try look.bindText(2, it.rel);
            if (try look.step()) same = look.int(0) == @as(i64, @intCast(it.size)) and look.int(1) == it.mtime;
        }
        if (same) {
            try touch.bindInt(1, gen);
            try touch.bindInt(2, it.root_id);
            try touch.bindText(3, it.rel);
            try touch.run();
        } else {
            const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ it.root, it.rel }) catch continue;
            if (idx.index(abs, it.root_id, it.rel, it.size, it.mtime, gen)) |_| {
                _ = prog.hashed.fetchAdd(1, .seq_cst);
            } else |_| {
                _ = prog.failed.fetchAdd(1, .seq_cst);
            }
        }
        _ = prog.done.fetchAdd(1, .seq_cst);
        if ((i + 1) % BATCH == 0) {
            try db.exec("COMMIT");
            _ = prog.commits.fetchAdd(1, .seq_cst);
            try db.exec("BEGIN");
        }
    }
    // files that are gone (only for roots walked to the end: a walk that
    // hit an unreadable folder must not drop what it could not see)
    var gone = try db.prepare("DELETE FROM file WHERE root_id = ?1 AND (seen IS NULL OR seen <> ?2)");
    defer gone.deinit();
    for (walked_ok.items) |rid| {
        try gone.bindInt(1, rid);
        try gone.bindInt(2, gen);
        try gone.run();
    }
    try db.exec("COMMIT");
    in_tx = false;
    _ = prog.commits.fetchAdd(1, .seq_cst);
    _ = prog.finished.fetchAdd(1, .seq_cst);
}

/// The scan on a thread of its own.
pub const Scanner = struct {
    gpa: std.mem.Allocator,
    prog: Progress = .{},
    thread: ?std.Thread = null,
    path_buf: [std.fs.max_path_bytes + 1]u8 = undefined,
    path_len: usize = 0,
    err: ?anyerror = null,

    pub fn start(gpa: std.mem.Allocator, db_path: [:0]const u8) !*Scanner {
        const self = try gpa.create(Scanner);
        self.* = .{ .gpa = gpa };
        @memcpy(self.path_buf[0..db_path.len], db_path);
        self.path_buf[db_path.len] = 0;
        self.path_len = db_path.len;
        self.prog.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *Scanner) void {
        scanAll(self.gpa, self.path_buf[0..self.path_len :0], &self.prog) catch |e| {
            self.err = e;
        };
        self.prog.running.store(false, .seq_cst);
    }

    /// Wait for it (headless runs, the command line).
    pub fn join(self: *Scanner) void {
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// Stop early (quitting kr8 mid-scan) and free it.
    pub fn deinit(self: *Scanner) void {
        self.prog.quit.store(true, .seq_cst);
        self.join();
        self.gpa.destroy(self);
    }
};
