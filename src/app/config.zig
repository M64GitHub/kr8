//! User config - `~/.config/kr8/config.zon` (DUET/qartz's config.zig,
//! reshaped for kr8): the 8 favorite folders, the open panes and their
//! folders, the AUTO and LOOP switches, the colour scheme.
//!
//! `KR8_HOME=<dir>` moves the whole kr8 home (this file, later the tag
//! database): tests and screenshots point it at a scratch dir so they
//! never touch the real one.
//!
//! Reads are forgiving (missing file = defaults, unknown fields ignored);
//! writes go through a temp file + rename so a crash never eats it.

const std = @import("std");

pub const N_FAVS = 8;
pub const MAX_PANES = 4;

/// The on-disk shape: flat scalar fields, "" = unset - hand-editable, and
/// flat because std.zon's comptime parser chokes on array fields.
const Disk = struct {
    fav1: []const u8 = "",
    fav2: []const u8 = "",
    fav3: []const u8 = "",
    fav4: []const u8 = "",
    fav5: []const u8 = "",
    fav6: []const u8 = "",
    fav7: []const u8 = "",
    fav8: []const u8 = "",
    pane1: []const u8 = "",
    pane2: []const u8 = "",
    pane3: []const u8 = "",
    pane4: []const u8 = "",
    focus: u8 = 0,
    /// the copy target pane, 1-based; 0 = not chosen
    target: u8 = 0,
    auto: bool = true,
    loop: bool = false,
    scheme: []const u8 = "",
    /// the tag `x` toggles (by name)
    armed: []const u8 = "",
};

pub const Config = struct {
    gpa: std.mem.Allocator,
    favorites: [N_FAVS]?[]u8 = @splat(null),
    panes: [MAX_PANES]?[]u8 = @splat(null),
    focus: u8 = 0,
    target: u8 = 0,
    auto: bool = true,
    loop: bool = false,
    scheme: ?[]u8 = null,
    armed: ?[]u8 = null,

    pub fn deinit(self: *Config) void {
        for (&self.favorites) |*f| freeOpt(self.gpa, f);
        for (&self.panes) |*p| freeOpt(self.gpa, p);
        freeOpt(self.gpa, &self.scheme);
        freeOpt(self.gpa, &self.armed);
    }

    pub fn setArmed(self: *Config, name: ?[]const u8) void {
        setOpt(self.gpa, &self.armed, name);
        self.save();
    }

    pub fn favorite(self: *const Config, slot: usize) ?[]const u8 {
        if (slot >= N_FAVS) return null;
        return self.favorites[slot];
    }

    pub fn setFavorite(self: *Config, slot: usize, dir: ?[]const u8) void {
        if (slot >= N_FAVS) return;
        setOpt(self.gpa, &self.favorites[slot], dir);
        self.save();
    }

    pub fn setScheme(self: *Config, name: []const u8) void {
        setOpt(self.gpa, &self.scheme, name);
        self.save();
    }

    /// Remember the open panes' folders (null = no such pane) - no write;
    /// the caller saves once.
    pub fn setPane(self: *Config, i: usize, dir: ?[]const u8) void {
        if (i >= MAX_PANES) return;
        setOpt(self.gpa, &self.panes[i], dir);
    }

    pub fn save(self: *const Config) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = configPath(&path_buf) orelse return;
        const dir_path = std.fs.path.dirname(path) orelse return;
        std.fs.cwd().makePath(dir_path) catch return;

        var disk: Disk = .{};
        inline for (0..N_FAVS) |i| {
            @field(disk, std.fmt.comptimePrint("fav{d}", .{i + 1})) = self.favorites[i] orelse "";
        }
        inline for (0..MAX_PANES) |i| {
            @field(disk, std.fmt.comptimePrint("pane{d}", .{i + 1})) = self.panes[i] orelse "";
        }
        disk.focus = self.focus;
        disk.target = self.target;
        disk.auto = self.auto;
        disk.loop = self.loop;
        disk.scheme = self.scheme orelse "";
        disk.armed = self.armed orelse "";

        var aw = std.Io.Writer.Allocating.init(self.gpa);
        defer aw.deinit();
        std.zon.stringify.serialize(disk, .{}, &aw.writer) catch return;

        var dir = std.fs.cwd().openDir(dir_path, .{}) catch return;
        defer dir.close();
        var af = dir.atomicFile(std.fs.path.basename(path), .{ .write_buffer = &.{} }) catch return;
        defer af.deinit();
        af.file_writer.interface.writeAll(aw.writer.buffered()) catch return;
        af.finish() catch return;
    }
};

pub fn load(gpa: std.mem.Allocator) Config {
    var cfg = Config{ .gpa = gpa };
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = configPath(&path_buf) orelse return cfg;
    const src = std.fs.cwd().readFileAllocOptions(gpa, path, 1 << 20, null, .of(u8), 0) catch return cfg;
    defer gpa.free(src);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(gpa);
    const raw = std.zon.parse.fromSlice(Disk, gpa, src, &diag, .{ .ignore_unknown_fields = true }) catch {
        std.debug.print("kr8: {s}: parse failed - using defaults\n", .{path});
        return cfg;
    };
    defer std.zon.parse.free(gpa, raw);

    inline for (0..N_FAVS) |i| {
        const f = @field(raw, std.fmt.comptimePrint("fav{d}", .{i + 1}));
        if (f.len > 0) cfg.favorites[i] = gpa.dupe(u8, f) catch null;
    }
    inline for (0..MAX_PANES) |i| {
        const p = @field(raw, std.fmt.comptimePrint("pane{d}", .{i + 1}));
        if (p.len > 0) cfg.panes[i] = gpa.dupe(u8, p) catch null;
    }
    cfg.focus = raw.focus;
    cfg.target = raw.target;
    cfg.auto = raw.auto;
    cfg.loop = raw.loop;
    if (raw.scheme.len > 0) cfg.scheme = gpa.dupe(u8, raw.scheme) catch null;
    if (raw.armed.len > 0) cfg.armed = gpa.dupe(u8, raw.armed) catch null;
    return cfg;
}

fn freeOpt(gpa: std.mem.Allocator, p: *?[]u8) void {
    if (p.*) |s| gpa.free(s);
    p.* = null;
}

fn setOpt(gpa: std.mem.Allocator, p: *?[]u8, val: ?[]const u8) void {
    const copy: ?[]u8 = if (val) |v| (gpa.dupe(u8, v) catch return) else null;
    freeOpt(gpa, p);
    p.* = copy;
}

/// $KR8_HOME, else ~/.config/kr8
pub fn homePath(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("KR8_HOME")) |p| {
        if (p.len > buf.len) return null;
        @memcpy(buf[0..p.len], p);
        return buf[0..p.len];
    }
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/kr8", .{home}) catch null;
}

fn configPath(buf: *[std.fs.max_path_bytes]u8) ?[]u8 {
    var hb: [std.fs.max_path_bytes]u8 = undefined;
    const h = homePath(&hb) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/config.zon", .{h}) catch null;
}
