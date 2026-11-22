//! THE DETAIL VIEW's model: one file, decoded into memory (a mono mix,
//! for drawing and for finding zero crossings), the visible window
//! (zoom), the edit cursor, and the IN/OUT range. No drawing, no audio.
//!
//! Positions are FRAMES in the file's own rate. The range is [in, out).
//! Writing a range re-reads the file (all channels, 16-bit) - the mono
//! mix is only for the eye.

const std = @import("std");
const audio = @import("../audio/audio.zig");

pub const PATH_MAX = std.fs.max_path_bytes;
/// ~11 minutes at 44.1 kHz: past that the mix would not be "a sample"
pub const MAX_FRAMES: u64 = 30_000_000;

pub const Detail = struct {
    gpa: std.mem.Allocator,
    path_buf: [PATH_MAX + 1]u8 = undefined,
    path_len: usize = 0,
    rate: u32 = 0,
    channels: u32 = 0,
    frames: u64 = 0,
    /// the channels averaged, one value per frame
    mono: []f32 = &.{},
    peak: f32 = 0,
    view_start: u64 = 0,
    view_len: u64 = 1,
    cursor: u64 = 0,
    in: ?u64 = null,
    out: ?u64 = null,

    pub fn load(gpa: std.mem.Allocator, file: []const u8) !*Detail {
        const self = try gpa.create(Detail);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa };
        if (file.len > PATH_MAX) return error.NameTooLong;
        @memcpy(self.path_buf[0..file.len], file);
        self.path_buf[file.len] = 0;
        self.path_len = file.len;

        var dec = try audio.Decoder.open(self.path(), false);
        defer dec.close();
        if (dec.frames > MAX_FRAMES) return error.TooLong;
        self.rate = dec.rate;
        self.channels = dec.channels;
        const mono = try gpa.alloc(f32, @intCast(@max(dec.frames, 1)));
        errdefer gpa.free(mono);
        var chunk: [4096 * 8]f32 = undefined;
        const ch: usize = dec.channels;
        const per = chunk.len / ch;
        var at: usize = 0;
        var pk: f32 = 0;
        while (at < mono.len) {
            const want = @min(per, mono.len - at);
            const got: usize = @intCast(dec.readF32(chunk[0 .. want * ch]));
            if (got == 0) break;
            for (0..got) |i| {
                var sum: f32 = 0;
                for (0..ch) |c| sum += chunk[i * ch + c];
                const v = sum / @as(f32, @floatFromInt(ch));
                mono[at + i] = v;
                pk = @max(pk, @abs(v));
            }
            at += got;
        }
        self.mono = mono[0..@max(at, 1)];
        self.frames = at;
        self.peak = pk;
        self.fitAll();
        return self;
    }

    pub fn deinit(self: *Detail) void {
        self.gpa.free(self.mono);
        self.gpa.destroy(self);
    }

    pub fn path(self: *const Detail) [:0]const u8 {
        return self.path_buf[0..self.path_len :0];
    }

    pub fn name(self: *const Detail) []const u8 {
        return std.fs.path.basename(self.path_buf[0..self.path_len]);
    }

    pub fn secs(self: *const Detail, f: u64) f64 {
        if (self.rate == 0) return 0;
        return @as(f64, @floatFromInt(f)) / @as(f64, @floatFromInt(self.rate));
    }

    // ------------------------------------------------------------- view

    pub fn fitAll(self: *Detail) void {
        self.view_start = 0;
        self.view_len = @max(self.frames, 1);
    }

    /// The range fills the view (with a little air), else the whole file.
    pub fn fitRange(self: *Detail) void {
        const r = self.range() orelse return self.fitAll();
        const len = r.out - r.in;
        const air = len / 16;
        self.view_start = r.in -| air;
        self.view_len = @min(len + 2 * air, self.frames -| self.view_start);
        self.view_len = @max(self.view_len, 1);
    }

    /// Zoom by `factor` (< 1 = in) keeping the cursor where it is on screen.
    pub fn zoom(self: *Detail, factor: f64, min_len: u64) void {
        const old: f64 = @floatFromInt(self.view_len);
        var nl: u64 = @intFromFloat(@max(1, old * factor));
        nl = std.math.clamp(nl, @max(min_len, 1), @max(self.frames, 1));
        const cur = std.math.clamp(self.cursor, self.view_start, self.view_start + self.view_len);
        const rel = @as(f64, @floatFromInt(cur - self.view_start)) / old;
        const left: u64 = @intFromFloat(rel * @as(f64, @floatFromInt(nl)));
        self.view_len = nl;
        self.view_start = @min(cur -| left, self.frames -| nl);
    }

    /// Move the cursor by `cols` screen columns of a `width`-column view.
    pub fn moveCursor(self: *Detail, cols: i64, width: usize) void {
        const per: f64 = @as(f64, @floatFromInt(self.view_len)) / @as(f64, @floatFromInt(@max(width, 1)));
        const step: i64 = @intFromFloat(@max(1, @round(per * @as(f64, @floatFromInt(@abs(cols))))));
        const delta: i64 = if (cols < 0) -step else step;
        const c: i64 = @intCast(self.cursor);
        self.cursor = @intCast(std.math.clamp(c + delta, 0, @as(i64, @intCast(self.frames -| 1))));
        self.follow();
    }

    pub fn setCursor(self: *Detail, f: u64) void {
        self.cursor = @min(f, self.frames -| 1);
        self.follow();
    }

    /// Scroll so the cursor is in view.
    pub fn follow(self: *Detail) void {
        if (self.cursor < self.view_start) self.view_start = self.cursor;
        if (self.cursor >= self.view_start + self.view_len)
            self.view_start = @min(self.cursor + 1 -| self.view_len, self.frames -| self.view_len);
    }

    // ------------------------------------------------------------- range

    pub const Range = struct { in: u64, out: u64 };

    pub fn range(self: *const Detail) ?Range {
        const i = self.in orelse return null;
        const o = self.out orelse return null;
        if (o <= i) return null;
        return .{ .in = i, .out = o };
    }

    /// `[`: IN at the cursor (an OUT before it moves to the end).
    pub fn setIn(self: *Detail) void {
        self.in = self.cursor;
        if (self.out) |o| if (o <= self.cursor) {
            self.out = self.frames;
        };
    }

    /// `]`: OUT at the cursor (exclusive: the cursor frame is the first one out).
    pub fn setOut(self: *Detail) void {
        self.out = @max(self.cursor, 1);
        if (self.in) |i| if (i >= self.out.?) {
            self.in = 0;
        };
        if (self.in == null) self.in = 0;
    }

    pub fn clearRange(self: *Detail) void {
        self.in = null;
        self.out = null;
    }

    /// The nearest frame at or after a sign change of the mix, within
    /// ~10 ms of `f`; `f` itself when there is none.
    pub fn zeroNear(self: *const Detail, f: u64) u64 {
        if (self.mono.len < 2) return f;
        const reach: u64 = @max(self.rate / 100, 1);
        var d: u64 = 0;
        while (d <= reach) : (d += 1) {
            for ([_]i64{ 1, -1 }) |sign| {
                const pos_i: i64 = @as(i64, @intCast(f)) + sign * @as(i64, @intCast(d));
                if (pos_i < 1 or pos_i >= @as(i64, @intCast(self.mono.len))) continue;
                const p: usize = @intCast(pos_i);
                const a = self.mono[p - 1];
                const b = self.mono[p];
                if (b == 0 or (a < 0) != (b < 0)) return p;
            }
        }
        return f;
    }

    /// `0`: both ends of the range onto zero crossings (no click at a loop).
    pub fn snapRange(self: *Detail) bool {
        const r = self.range() orelse return false;
        const ni = self.zeroNear(r.in);
        const no = self.zeroNear(r.out);
        if (no <= ni) return false;
        self.in = ni;
        self.out = no;
        return true;
    }

    // ------------------------------------------------------------- tempo

    pub const Tempo = struct { label: []const u8, bpm: f64 };

    /// A range is probably a whole number of bars (or beats): the first
    /// reading that lands between 70 and 190 bpm.
    pub fn tempo(self: *const Detail) ?Tempo {
        const r = self.range() orelse return null;
        const len = self.secs(r.out - r.in);
        if (len <= 0) return null;
        const tries = [_]struct { []const u8, f64 }{
            .{ "1 bar", 4 }, .{ "2 bars", 8 }, .{ "4 bars", 16 }, .{ "half a bar", 2 },
            .{ "8 bars", 32 }, .{ "1 beat", 1 },
        };
        for (tries) |t| {
            const bpm = 60.0 * t[1] / len;
            if (bpm >= 70 and bpm <= 190) return .{ .label = t[0], .bpm = bpm };
        }
        return null;
    }
};

/// Write frames [in, out) of `src` as a 16-bit PCM WAV at `dst` (the
/// source's rate and channels). Refuses to overwrite.
pub fn writeRange(src: [:0]const u8, dst: []const u8, in: u64, out: u64) !u64 {
    var dec = try audio.Decoder.open(src, true);
    defer dec.close();
    try dec.seek(in);
    var f = try std.fs.cwd().createFile(dst, .{ .exclusive = true });
    defer f.close();
    errdefer std.fs.cwd().deleteFile(dst) catch {};
    var wbuf: [64 * 1024]u8 = undefined;
    var w = f.writer(&wbuf);
    const io = &w.interface;
    const ch: u32 = dec.channels;
    const total: u64 = out - in;
    const data_len: u64 = total * ch * 2;
    if (data_len > std.math.maxInt(u32) - 36) return error.TooLong;
    try io.writeAll("RIFF");
    try io.writeInt(u32, @intCast(36 + data_len), .little);
    try io.writeAll("WAVEfmt ");
    try io.writeInt(u32, 16, .little);
    try io.writeInt(u16, 1, .little);
    try io.writeInt(u16, @intCast(ch), .little);
    try io.writeInt(u32, dec.rate, .little);
    try io.writeInt(u32, dec.rate * ch * 2, .little);
    try io.writeInt(u16, @intCast(ch * 2), .little);
    try io.writeInt(u16, 16, .little);
    try io.writeAll("data");
    try io.writeInt(u32, @intCast(data_len), .little);
    var chunk: [4096 * 8]i16 = undefined;
    const per = chunk.len / ch;
    var left = total;
    var written: u64 = 0;
    while (left > 0) {
        const want: usize = @intCast(@min(per, left));
        const got: usize = @intCast(dec.readS16(chunk[0 .. want * ch]));
        if (got == 0) break;
        for (chunk[0 .. got * ch]) |smp| try io.writeInt(i16, smp, .little);
        left -= got;
        written += got;
    }
    // a short read (the file ended early): pad with silence so the header holds
    while (left > 0) : (left -= 1) {
        for (0..ch) |_| try io.writeInt(i16, 0, .little);
    }
    try io.flush();
    return written;
}

// ------------------------------------------------------------------ tests

fn testDetail(gpa: std.mem.Allocator, samples: []const f32) !*Detail {
    const d = try gpa.create(Detail);
    d.* = .{ .gpa = gpa, .rate = 1000, .channels = 1 };
    d.mono = try gpa.dupe(f32, samples);
    d.frames = samples.len;
    d.fitAll();
    return d;
}

test "detail: range, zero crossings, tempo" {
    const gpa = std.testing.allocator;
    // a 1 kHz-rate "file": a slow wave crossing zero at 25, 50, 75
    var s: [100]f32 = undefined;
    for (&s, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * std.math.pi / 25.0);
    const d = try testDetail(gpa, &s);
    defer d.deinit();
    d.setCursor(23);
    d.setIn();
    d.setCursor(77);
    d.setOut();
    try std.testing.expectEqual(Detail.Range{ .in = 23, .out = 77 }, d.range().?);
    try std.testing.expect(d.snapRange());
    try std.testing.expectEqual(@as(u64, 25), d.in.?);
    // sin(3*pi) is a hair off zero in f32: the crossing lands on 75 or 76
    try std.testing.expect(d.out.? == 75 or d.out.? == 76);
    // tempo: 50 frames at 100 Hz = 0.5 s; a bar would be 480 bpm, a beat is 120
    d.rate = 100;
    d.in = 0;
    d.out = 50;
    const t = d.tempo().?;
    try std.testing.expectEqualStrings("1 beat", t.label);
    try std.testing.expectApproxEqAbs(@as(f64, 120), t.bpm, 0.01);
}

test "detail: zoom keeps the cursor on screen" {
    const gpa = std.testing.allocator;
    const s = [_]f32{0} ** 1000;
    const d = try testDetail(gpa, &s);
    defer d.deinit();
    d.setCursor(800);
    d.zoom(0.1, 10);
    try std.testing.expectEqual(@as(u64, 100), d.view_len);
    try std.testing.expect(d.cursor >= d.view_start and d.cursor < d.view_start + d.view_len);
}
