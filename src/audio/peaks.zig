//! Waveform overviews, computed OFF the UI thread.
//!
//! The UI asks for the file under the cursor every frame (`get`); a miss
//! posts it as THE wanted file (`request`) - one slot, newest wins, so
//! scrolling past fifty files decodes at most the one you stopped on. A
//! decode that is no longer wanted is cancelled mid-file. Results land in
//! a small LRU, so going back and forth is free.
//!
//! Headless runs set `sync`: the request is decoded on the spot, so a
//! dump or screenshot is deterministic.

const std = @import("std");
const audio = @import("audio.zig");

pub const BUCKETS = 1024;
const SLOTS = 48;
const PATH_MAX = std.fs.max_path_bytes;

pub const Peaks = struct {
    mins: [BUCKETS]f32 = @splat(0),
    maxs: [BUCKETS]f32 = @splat(0),
    frames: u64 = 0,
    /// the largest |sample|, for the display gain and the dB readout
    peak: f32 = 0,
    failed: bool = false,
};

const Slot = struct {
    used: bool = false,
    stamp: u64 = 0,
    path: [PATH_MAX]u8 = undefined,
    path_len: usize = 0,
    peaks: Peaks = .{},

    fn is(self: *const Slot, path: []const u8) bool {
        return self.used and std.mem.eql(u8, self.path[0..self.path_len], path);
    }
};

pub const Cache = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    quit: bool = false,
    sync: bool = false,

    slots: []Slot,
    clock: u64 = 0,

    want: [PATH_MAX + 1]u8 = undefined,
    want_len: usize = 0,
    has_want: bool = false,
    busy: [PATH_MAX]u8 = undefined,
    busy_len: usize = 0,
    is_busy: bool = false,
    cancel: c_int = 0,

    gpa: std.mem.Allocator,
    /// the worker's scratch result (big: kept off its stack)
    scratch: *Peaks,

    pub fn init(gpa: std.mem.Allocator, sync: bool) !*Cache {
        const self = try gpa.create(Cache);
        errdefer gpa.destroy(self);
        const slots = try gpa.alloc(Slot, SLOTS);
        errdefer gpa.free(slots);
        for (slots) |*s| s.* = .{};
        const scratch = try gpa.create(Peaks);
        self.* = .{ .gpa = gpa, .slots = slots, .scratch = scratch, .sync = sync };
        if (!sync) self.thread = try std.Thread.spawn(.{}, worker, .{self});
        return self;
    }

    pub fn deinit(self: *Cache) void {
        self.mutex.lock();
        self.quit = true;
        @atomicStore(c_int, &self.cancel, 1, .seq_cst);
        self.cond.signal();
        self.mutex.unlock();
        if (self.thread) |t| t.join();
        self.gpa.destroy(self.scratch);
        self.gpa.free(self.slots);
        self.gpa.destroy(self);
    }

    /// Copy the overview of `path` into `out` if it is ready.
    pub fn get(self: *Cache, path: []const u8, out: *Peaks) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots) |*s| {
            if (s.is(path)) {
                self.clock += 1;
                s.stamp = self.clock;
                out.* = s.peaks;
                return true;
            }
        }
        return false;
    }

    /// Make `path` the one file being decoded next (a no-op when it is
    /// cached or already in the works).
    pub fn request(self: *Cache, path: []const u8) void {
        if (path.len > PATH_MAX) return;
        if (self.sync) {
            for (self.slots) |*s| if (s.is(path)) return;
            var cancel: c_int = 0;
            compute(path, self.scratch, &cancel);
            self.mutex.lock();
            defer self.mutex.unlock();
            self.store(path, self.scratch);
            return;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots) |*s| if (s.is(path)) return;
        if (self.is_busy and std.mem.eql(u8, self.busy[0..self.busy_len], path)) {
            self.has_want = false; // the worker is on it already
            return;
        }
        @memcpy(self.want[0..path.len], path);
        self.want_len = path.len;
        self.has_want = true;
        if (self.is_busy) @atomicStore(c_int, &self.cancel, 1, .seq_cst);
        self.cond.signal();
    }

    fn store(self: *Cache, path: []const u8, p: *const Peaks) void {
        var victim: *Slot = &self.slots[0];
        for (self.slots) |*s| {
            if (!s.used) {
                victim = s;
                break;
            }
            if (s.stamp < victim.stamp) victim = s;
        }
        self.clock += 1;
        victim.used = true;
        victim.stamp = self.clock;
        @memcpy(victim.path[0..path.len], path);
        victim.path_len = path.len;
        victim.peaks = p.*;
    }

    fn worker(self: *Cache) void {
        var path_buf: [PATH_MAX]u8 = undefined;
        while (true) {
            self.mutex.lock();
            while (!self.has_want and !self.quit) self.cond.wait(&self.mutex);
            if (self.quit) {
                self.mutex.unlock();
                return;
            }
            const n = self.want_len;
            @memcpy(path_buf[0..n], self.want[0..n]);
            @memcpy(self.busy[0..n], self.want[0..n]);
            self.busy_len = n;
            self.is_busy = true;
            self.has_want = false;
            @atomicStore(c_int, &self.cancel, 0, .seq_cst);
            self.mutex.unlock();

            compute(path_buf[0..n], self.scratch, &self.cancel);

            self.mutex.lock();
            self.is_busy = false;
            if (@atomicLoad(c_int, &self.cancel, .seq_cst) == 0) self.store(path_buf[0..n], self.scratch);
            self.mutex.unlock();
        }
    }
};

fn compute(path: []const u8, out: *Peaks, cancel: *c_int) void {
    var zbuf: [PATH_MAX + 1]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    out.* = .{};
    var frames: u64 = 0;
    const r = audio.peaks(zbuf[0..path.len :0], &out.mins, &out.maxs, &frames, @ptrCast(cancel));
    out.frames = frames;
    out.failed = r == .failed;
    var pk: f32 = 0;
    for (out.mins, out.maxs) |lo, hi| pk = @max(pk, @max(-lo, hi));
    out.peak = pk;
}
