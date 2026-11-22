//! THE COPY WORKER: one thread that copies files into a folder, so a
//! batch onto a slow SD card (the M8's) never freezes the UI.
//!
//! - NEVER OVERWRITES: a name that exists already gets `_2`, `_3`, ...
//!   before its extension (Kick.wav -> Kick_2.wav). The free name is
//!   found by the worker at copy time, so a batch holding the same name
//!   twice numbers them in order.
//! - Never touches the source: it is opened for reading only.
//! - The UI reads `snapshot()` every frame: progress while busy, and a
//!   `batch` counter that steps when the queue runs dry (the moment to
//!   reload the destination pane and say what happened).

const std = @import("std");

const PATH_MAX = std.fs.max_path_bytes;
const NAME_MAX = 256;

const Job = struct {
    src: []u8, // absolute, gpa-owned
    dst_dir: []u8, // absolute, gpa-owned
};

pub const Snapshot = struct {
    busy: bool = false,
    /// files queued / copied / failed since the queue was last empty
    total: u32 = 0,
    done: u32 = 0,
    failed: u32 = 0,
    /// steps when a batch has finished (the queue ran dry)
    batch: u32 = 0,
    dst_dir: [PATH_MAX]u8 = undefined,
    dst_dir_len: usize = 0,
    /// the name the last file got in the destination (may carry `_2`)
    last_name: [NAME_MAX]u8 = undefined,
    last_name_len: usize = 0,
    /// the first failure of the batch
    err_name: [NAME_MAX]u8 = undefined,
    err_name_len: usize = 0,
    err: ?anyerror = null,

    pub fn dstDir(self: *const Snapshot) []const u8 {
        return self.dst_dir[0..self.dst_dir_len];
    }
    pub fn lastName(self: *const Snapshot) []const u8 {
        return self.last_name[0..self.last_name_len];
    }
    pub fn errName(self: *const Snapshot) []const u8 {
        return self.err_name[0..self.err_name_len];
    }
};

pub const Copier = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    quit: bool = false,
    jobs: std.ArrayList(Job) = .empty,
    snap: Snapshot = .{},

    pub fn init(gpa: std.mem.Allocator) !*Copier {
        const self = try gpa.create(Copier);
        self.* = .{ .gpa = gpa };
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        return self;
    }

    /// Finishes the file in flight, drops the rest of the queue.
    pub fn deinit(self: *Copier) void {
        self.mutex.lock();
        self.quit = true;
        self.cond.signal();
        self.mutex.unlock();
        if (self.thread) |t| t.join();
        for (self.jobs.items) |j| self.freeJob(j);
        self.jobs.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn freeJob(self: *Copier, j: Job) void {
        self.gpa.free(j.src);
        self.gpa.free(j.dst_dir);
    }

    /// Queue `srcs` (absolute paths) for copying into `dst_dir`.
    pub fn submit(self: *Copier, srcs: []const []const u8, dst_dir: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.snap.busy) {
            // a new batch: forget the last one's numbers
            self.snap.total = 0;
            self.snap.done = 0;
            self.snap.failed = 0;
            self.snap.err = null;
            self.snap.err_name_len = 0;
        }
        for (srcs) |s| {
            const src = try self.gpa.dupe(u8, s);
            errdefer self.gpa.free(src);
            const dd = try self.gpa.dupe(u8, dst_dir);
            errdefer self.gpa.free(dd);
            try self.jobs.append(self.gpa, .{ .src = src, .dst_dir = dd });
            self.snap.total += 1;
        }
        const n = @min(dst_dir.len, PATH_MAX);
        @memcpy(self.snap.dst_dir[0..n], dst_dir[0..n]);
        self.snap.dst_dir_len = n;
        self.snap.busy = true;
        self.cond.signal();
    }

    /// Block until the queue is empty (headless runs: deterministic dumps).
    pub fn waitIdle(self: *Copier) void {
        while (true) {
            self.mutex.lock();
            const busy = self.snap.busy;
            self.mutex.unlock();
            if (!busy) return;
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }

    pub fn snapshot(self: *Copier) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.snap;
    }

    fn worker(self: *Copier) void {
        var name_buf: [NAME_MAX]u8 = undefined;
        while (true) {
            self.mutex.lock();
            while (self.jobs.items.len == 0 and !self.quit) self.cond.wait(&self.mutex);
            if (self.quit) {
                self.mutex.unlock();
                return;
            }
            const job = self.jobs.orderedRemove(0);
            self.mutex.unlock();

            const result = copyOne(job.src, job.dst_dir, &name_buf);

            self.mutex.lock();
            switch (result) {
                .ok => |name| {
                    self.snap.done += 1;
                    const n = @min(name.len, NAME_MAX);
                    @memcpy(self.snap.last_name[0..n], name[0..n]);
                    self.snap.last_name_len = n;
                },
                .err => |e| {
                    self.snap.failed += 1;
                    if (self.snap.err == null) {
                        self.snap.err = e;
                        const base = std.fs.path.basename(job.src);
                        const n = @min(base.len, NAME_MAX);
                        @memcpy(self.snap.err_name[0..n], base[0..n]);
                        self.snap.err_name_len = n;
                    }
                },
            }
            if (self.jobs.items.len == 0) {
                self.snap.busy = false;
                self.snap.batch +%= 1;
            }
            self.mutex.unlock();
            self.freeJob(job);
        }
    }
};

const Result = union(enum) { ok: []const u8, err: anyerror };

fn copyOne(src: []const u8, dst_dir_path: []const u8, name_buf: *[NAME_MAX]u8) Result {
    var dst_dir = std.fs.openDirAbsolute(dst_dir_path, .{}) catch |e| return .{ .err = e };
    defer dst_dir.close();
    const name = freeName(dst_dir, std.fs.path.basename(src), name_buf) catch |e| return .{ .err = e };
    std.fs.cwd().copyFile(src, dst_dir, name, .{}) catch |e| return .{ .err = e };
    return .{ .ok = name };
}

/// `name` if `dir` has no such entry, else `stem_2.ext`, `stem_3.ext`, ...
pub fn freeName(dir: std.fs.Dir, name: []const u8, buf: *[NAME_MAX]u8) ![]const u8 {
    if (!exists(dir, name)) {
        if (name.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    const ext = std.fs.path.extension(name);
    const stem = name[0 .. name.len - ext.len];
    var i: u32 = 2;
    while (i < 10_000) : (i += 1) {
        const cand = std.fmt.bufPrint(buf, "{s}_{d}{s}", .{ stem, i, ext }) catch return error.NameTooLong;
        if (!exists(dir, cand)) return cand;
    }
    return error.PathAlreadyExists;
}

fn exists(dir: std.fs.Dir, name: []const u8) bool {
    dir.access(name, .{}) catch |e| return e != error.FileNotFound;
    return true;
}

test "freeName numbers before the extension" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [NAME_MAX]u8 = undefined;
    try std.testing.expectEqualStrings("Kick.wav", try freeName(tmp.dir, "Kick.wav", &buf));
    try tmp.dir.writeFile(.{ .sub_path = "Kick.wav", .data = "x" });
    try std.testing.expectEqualStrings("Kick_2.wav", try freeName(tmp.dir, "Kick.wav", &buf));
    try tmp.dir.writeFile(.{ .sub_path = "Kick_2.wav", .data = "x" });
    try std.testing.expectEqualStrings("Kick_3.wav", try freeName(tmp.dir, "Kick.wav", &buf));
}

test "copier copies, never overwrites, reports the batch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("src");
    try tmp.dir.makeDir("dst");
    try tmp.dir.writeFile(.{ .sub_path = "src/a.wav", .data = "AAAA" });
    try tmp.dir.writeFile(.{ .sub_path = "dst/a.wav", .data = "keep me" });
    var pb: [PATH_MAX]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pb);
    var sb: [PATH_MAX]u8 = undefined;
    var db: [PATH_MAX]u8 = undefined;
    const src = try std.fmt.bufPrint(&sb, "{s}/src/a.wav", .{root});
    const dst = try std.fmt.bufPrint(&db, "{s}/dst", .{root});

    const c = try Copier.init(std.testing.allocator);
    defer c.deinit();
    try c.submit(&.{ src, src }, dst);
    var tries: usize = 0;
    while (c.snapshot().batch == 0 and tries < 500) : (tries += 1) std.Thread.sleep(2 * std.time.ns_per_ms);
    const s = c.snapshot();
    try std.testing.expectEqual(@as(u32, 2), s.done);
    try std.testing.expectEqual(@as(u32, 0), s.failed);
    try std.testing.expectEqualStrings("a_3.wav", s.lastName());

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("keep me", try tmp.dir.readFile("dst/a.wav", &buf));
    try std.testing.expectEqualStrings("AAAA", try tmp.dir.readFile("dst/a_2.wav", &buf));
    try std.testing.expectEqualStrings("AAAA", try tmp.dir.readFile("dst/a_3.wav", &buf));
}
