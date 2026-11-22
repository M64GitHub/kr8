//! The audio surface: the C shim's functions (src/audio/shim.c) as Zig.
//! Playback is UI-thread only; `peaks` is called from the peaks worker.

const std = @import("std");

extern fn kr8_audio_init() c_int;
extern fn kr8_audio_uninit() void;
extern fn kr8_play(path: [*:0]const u8, loop: c_int, loop_start: u64, loop_end: u64) c_int;
extern fn kr8_stop() void;
extern fn kr8_tick() void;
extern fn kr8_set_loop(loop: c_int) void;
extern fn kr8_is_playing() c_int;
extern fn kr8_cursor() u64;
extern fn kr8_length() u64;
extern fn kr8_set_volume(v: f32) void;
extern fn kr8_peaks(
    path: [*:0]const u8,
    mins: [*]f32,
    maxs: [*]f32,
    buckets: u32,
    out_frames: *u64,
    cancel: ?*volatile c_int,
) c_int;

/// False when no device could be opened (or headless): every call below
/// is then a quiet no-op, so the browser still browses.
pub var enabled: bool = false;

pub fn init() bool {
    enabled = kr8_audio_init() == 0;
    return enabled;
}

pub fn deinit() void {
    if (enabled) kr8_audio_uninit();
    enabled = false;
}

pub const Loop = struct { start: u64 = 0, end: u64 = 0 };

pub fn play(path: [:0]const u8, loop: bool, span: Loop) bool {
    if (!enabled) return false;
    return kr8_play(path.ptr, @intFromBool(loop), span.start, span.end) == 0;
}

pub fn stop() void {
    if (enabled) kr8_stop();
}

pub fn tick() void {
    if (enabled) kr8_tick();
}

pub fn setLoop(loop: bool) void {
    if (enabled) kr8_set_loop(@intFromBool(loop));
}

pub fn isPlaying() bool {
    return enabled and kr8_is_playing() != 0;
}

/// Frames played, in the file's own rate.
pub fn cursor() u64 {
    return if (enabled) kr8_cursor() else 0;
}

pub fn length() u64 {
    return if (enabled) kr8_length() else 0;
}

pub fn setVolume(v: f32) void {
    if (enabled) kr8_set_volume(v);
}

pub const PeaksResult = enum { ok, cancelled, failed };

/// Decode the whole file into `mins.len` min/max buckets. Thread-safe
/// (its own decoder); `cancel` going non-zero stops it early.
pub fn peaks(path: [:0]const u8, mins: []f32, maxs: []f32, frames: *u64, cancel: *volatile c_int) PeaksResult {
    std.debug.assert(mins.len == maxs.len);
    const rc = kr8_peaks(path.ptr, mins.ptr, maxs.ptr, @intCast(mins.len), frames, cancel);
    return switch (rc) {
        0 => .ok,
        1 => .cancelled,
        else => .failed,
    };
}
