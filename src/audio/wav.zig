//! WAV header reader: what a row and the info strip show, without
//! decoding a sample. Walks the RIFF chunks with a pread per chunk header
//! (the data chunk is skipped, not read), so a listing of a hundred files
//! costs a few hundred syscalls.
//!
//! Reads: `fmt ` (format, channels, rate, bits; WAVE_FORMAT_EXTENSIBLE
//! resolved to its subformat), `data` (length -> frames), `smpl` (the
//! first loop and the MIDI unity note), `inst` (root note when no smpl),
//! `clm ` (Serum's wavetable marker).

const std = @import("std");

pub const Format = enum(u16) {
    pcm = 1,
    float = 3,
    _,
};

pub const Info = struct {
    format: Format = .pcm,
    channels: u16 = 0,
    rate: u32 = 0,
    bits: u16 = 0,
    frames: u64 = 0,
    /// the first `smpl` loop, frames, end EXCLUSIVE (smpl stores it inclusive)
    loop_start: u32 = 0,
    loop_end: u32 = 0,
    has_loop: bool = false,
    /// MIDI note from `smpl` (unity) or `inst`
    root_note: ?u8 = null,
    /// a Serum wavetable (`clm ` chunk)
    wavetable: bool = false,
    /// where the sample bytes are (the fingerprint hashes exactly these)
    data_offset: u64 = 0,
    data_len: u64 = 0,

    pub fn seconds(self: Info) f64 {
        if (self.rate == 0) return 0;
        return @as(f64, @floatFromInt(self.frames)) / @as(f64, @floatFromInt(self.rate));
    }
};

pub const Error = error{ NotWav, Truncated, ReadFailed };

pub fn readPath(path: []const u8) Error!Info {
    var f = std.fs.cwd().openFile(path, .{}) catch return error.ReadFailed;
    defer f.close();
    return read(f);
}

pub fn read(f: std.fs.File) Error!Info {
    const size = (f.stat() catch return error.ReadFailed).size;
    var hdr: [12]u8 = undefined;
    if ((f.preadAll(&hdr, 0) catch return error.ReadFailed) < 12) return error.NotWav;
    if (!std.mem.eql(u8, hdr[0..4], "RIFF") or !std.mem.eql(u8, hdr[8..12], "WAVE")) return error.NotWav;

    var info: Info = .{};
    var have_fmt = false;
    var data_len: ?u64 = null;
    var pos: u64 = 12;
    var chunks: usize = 0;
    while (pos + 8 <= size and chunks < 64) : (chunks += 1) {
        var ch: [8]u8 = undefined;
        if ((f.preadAll(&ch, pos) catch return error.ReadFailed) < 8) break;
        const id = ch[0..4];
        const len: u64 = std.mem.readInt(u32, ch[4..8], .little);
        const body = pos + 8;
        if (std.mem.eql(u8, id, "fmt ")) {
            var b: [40]u8 = @splat(0);
            const want: usize = @intCast(@min(len, b.len));
            if ((f.preadAll(b[0..want], body) catch return error.ReadFailed) < 16) return error.Truncated;
            var tag = std.mem.readInt(u16, b[0..2], .little);
            info.channels = std.mem.readInt(u16, b[2..4], .little);
            info.rate = std.mem.readInt(u32, b[4..8], .little);
            info.bits = std.mem.readInt(u16, b[14..16], .little);
            if (tag == 0xFFFE and want >= 26) tag = std.mem.readInt(u16, b[24..26], .little);
            info.format = @enumFromInt(tag);
            have_fmt = true;
        } else if (std.mem.eql(u8, id, "data")) {
            // a writer that died mid-file (or streams) leaves a bogus length
            data_len = if (body + len > size) size - body else len;
            info.data_offset = body;
        } else if (std.mem.eql(u8, id, "smpl")) {
            var b: [60]u8 = @splat(0);
            const want: usize = @intCast(@min(len, b.len));
            const got = f.preadAll(b[0..want], body) catch return error.ReadFailed;
            if (got >= 36) {
                const unity = std.mem.readInt(u32, b[12..16], .little);
                if (unity <= 127) info.root_note = @intCast(unity);
                const n_loops = std.mem.readInt(u32, b[28..32], .little);
                if (n_loops > 0 and got >= 60) {
                    const s = std.mem.readInt(u32, b[44..48], .little);
                    const e = std.mem.readInt(u32, b[48..52], .little);
                    if (e > s) {
                        info.loop_start = s;
                        info.loop_end = e +| 1;
                        info.has_loop = true;
                    }
                }
            }
        } else if (std.mem.eql(u8, id, "inst")) {
            var b: [1]u8 = undefined;
            if ((f.preadAll(&b, body) catch 0) == 1 and info.root_note == null and b[0] <= 127)
                info.root_note = b[0];
        } else if (std.mem.eql(u8, id, "clm ")) {
            info.wavetable = true;
        }
        pos = body + len + (len & 1);
    }
    if (!have_fmt or data_len == null) return error.Truncated;
    const frame_bytes: u64 = @as(u64, info.channels) * ((@as(u64, info.bits) + 7) / 8);
    if (frame_bytes == 0) return error.Truncated;
    info.data_len = data_len.?;
    info.frames = data_len.? / frame_bytes;
    // Placeholder loops are common (746 of the 835 in trackers/ run past
    // the data, often 0..0xFFFFFFFF; 45 more span the whole file): a loop
    // only counts when it lies inside the data and is not the whole file.
    if (info.has_loop) {
        const last: u64 = info.loop_end - 1; // smpl's own inclusive end
        if (last >= info.frames or (info.loop_start == 0 and info.loop_end >= info.frames))
            info.has_loop = false;
    }
    if (!info.has_loop) {
        info.loop_start = 0;
        info.loop_end = 0;
    }
    return info;
}

/// "C-5" style (IT/tracker octave numbering: MIDI 60 = C-5).
pub fn noteName(n: u8, buf: *[4]u8) []const u8 {
    const names = [_][]const u8{ "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-" };
    return std.fmt.bufPrint(buf, "{s}{d}", .{ names[n % 12], n / 12 }) catch "?";
}

// ------------------------------------------------------------------ tests

fn writeTestWav(dir: std.fs.Dir, name: []const u8, extra: []const u8, channels: u16, bits: u16, frames: u32) !void {
    var f = try dir.createFile(name, .{});
    defer f.close();
    var buf: [4096]u8 = undefined;
    var w = f.writer(&buf);
    const io = &w.interface;
    const data_len: u32 = frames * channels * (bits / 8);
    const riff_len: u32 = 4 + (8 + 16) + (8 + data_len) + @as(u32, @intCast(extra.len));
    try io.writeAll("RIFF");
    try io.writeInt(u32, riff_len, .little);
    try io.writeAll("WAVE");
    try io.writeAll("fmt ");
    try io.writeInt(u32, 16, .little);
    try io.writeInt(u16, 1, .little);
    try io.writeInt(u16, channels, .little);
    try io.writeInt(u32, 44100, .little);
    try io.writeInt(u32, 44100 * channels * (bits / 8), .little);
    try io.writeInt(u16, channels * (bits / 8), .little);
    try io.writeInt(u16, bits, .little);
    try io.writeAll("data");
    try io.writeInt(u32, data_len, .little);
    for (0..data_len) |_| try io.writeByte(0);
    try io.writeAll(extra);
    try io.flush();
}

test "wav: fmt + data + a trailing smpl loop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var smpl: [8 + 60]u8 = @splat(0);
    @memcpy(smpl[0..4], "smpl");
    std.mem.writeInt(u32, smpl[4..8], 60, .little);
    std.mem.writeInt(u32, smpl[8 + 12 ..][0..4], 48, .little); // unity C-4
    std.mem.writeInt(u32, smpl[8 + 28 ..][0..4], 1, .little); // one loop
    std.mem.writeInt(u32, smpl[8 + 44 ..][0..4], 100, .little);
    std.mem.writeInt(u32, smpl[8 + 48 ..][0..4], 399, .little);
    try writeTestWav(tmp.dir, "a.wav", &smpl, 2, 24, 441);

    var f = try tmp.dir.openFile("a.wav", .{});
    defer f.close();
    const info = try read(f);
    try std.testing.expectEqual(@as(u16, 2), info.channels);
    try std.testing.expectEqual(@as(u16, 24), info.bits);
    try std.testing.expectEqual(@as(u64, 441), info.frames);
    try std.testing.expect(info.has_loop);
    try std.testing.expectEqual(@as(u32, 100), info.loop_start);
    try std.testing.expectEqual(@as(u32, 400), info.loop_end);
    try std.testing.expectEqual(@as(?u8, 48), info.root_note);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), info.seconds(), 1e-9);
}

test "wav: placeholder loops are no loop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var smpl: [8 + 60]u8 = @splat(0);
    @memcpy(smpl[0..4], "smpl");
    std.mem.writeInt(u32, smpl[4..8], 60, .little);
    std.mem.writeInt(u32, smpl[8 + 28 ..][0..4], 1, .little);
    std.mem.writeInt(u32, smpl[8 + 48 ..][0..4], 0xFFFF_FFFF, .little); // 0 .. 0xFFFFFFFF
    try writeTestWav(tmp.dir, "p.wav", &smpl, 1, 16, 1000);
    std.mem.writeInt(u32, smpl[8 + 48 ..][0..4], 999, .little); // 0 .. last frame = whole file
    try writeTestWav(tmp.dir, "w.wav", &smpl, 1, 16, 1000);
    for ([_][]const u8{ "p.wav", "w.wav" }) |name| {
        var f = try tmp.dir.openFile(name, .{});
        defer f.close();
        try std.testing.expect(!(try read(f)).has_loop);
    }
}

test "wav: not a wav" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "x.wav", .data = "hello there, not riff" });
    var f = try tmp.dir.openFile("x.wav", .{});
    defer f.close();
    try std.testing.expectError(error.NotWav, read(f));
}

test "wav: note names" {
    var b: [4]u8 = undefined;
    try std.testing.expectEqualStrings("C-5", noteName(60, &b));
    try std.testing.expectEqualStrings("A#3", noteName(46, &b));
}
