//! A DIR PANE: one folder's listing, its cursor and scroll, and its `/`
//! filter. No drawing, no audio - the app moves it, the view draws it.
//!
//! - `..` first (not at /), then folders, then files - each group in
//!   NATURAL order, case-insensitive: "SC (97)" before "SC (101)".
//! - Dot files are hidden.
//! - The filter is WORDS: every space-separated word must be a
//!   case-insensitive substring of the name (m64: exact, not fuzzy).
//!   `..` hides while a filter is set.
//! - WAV headers are read lazily (`info`), only for rows that get looked at.
//! - MARKS (`v`, `V`) live on the entries; a reload keeps them by name,
//!   a new folder starts unmarked.
//! - A SEARCH PANE (`showResults`) lists library hits from anywhere: its
//!   entries' names are ABSOLUTE paths, `dir()` is "" (it is no folder),
//!   and it remembers the folder it was opened from (`backDir`).

const std = @import("std");
const wav = @import("../audio/wav.zig");
const library = @import("../db/library.zig");

pub const PATH_MAX = std.fs.max_path_bytes;
pub const FILTER_MAX = 48;
pub const QUERY_MAX = 200;

pub const Mode = enum { dir, query };

pub const Kind = enum { parent, dir, audio, other };

pub const Counts = struct { wavs: u32 = 0, dirs: u32 = 0, other: u32 = 0 };

pub const Entry = struct {
    name: []u8, // gpa-owned ("" for the parent row)
    kind: Kind,
    size: u64 = 0,
    info: ?wav.Info = null,
    info_tried: bool = false,
    /// marked with `v` (copy/tag act on the marks when there are any)
    marked: bool = false,
    /// what the library knows (tags, copies, note), as of `facts_gen`
    facts: library.Facts = .{},
    facts_gen: u32 = 0,
    /// a folder's contents, counted on first ask (the info row)
    counts: ?Counts = null,

    pub fn isFile(self: *const Entry) bool {
        return self.kind == .audio or self.kind == .other;
    }
};

pub const Pane = struct {
    gpa: std.mem.Allocator,
    dir_buf: [PATH_MAX]u8 = undefined,
    dir_len: usize = 0,
    entries: std.ArrayList(Entry) = .empty,
    /// indices into `entries` that pass the filter, in display order
    view: std.ArrayList(u32) = .empty,
    cursor: usize = 0, // index into `view`
    scroll: usize = 0, // first visible row
    filter_buf: [FILTER_MAX]u8 = undefined,
    filter_len: usize = 0,
    /// typing into the filter line right now
    typing: bool = false,
    mode: Mode = .dir,
    query_buf: [QUERY_MAX]u8 = undefined,
    query_len: usize = 0,
    /// the folder a search pane goes back to
    back_buf: [PATH_MAX]u8 = undefined,
    back_len: usize = 0,
    /// the search hit FIND_LIMIT
    truncated: bool = false,
    err: ?anyerror = null,

    pub fn deinit(self: *Pane) void {
        self.clearEntries();
        self.entries.deinit(self.gpa);
        self.view.deinit(self.gpa);
    }

    fn clearEntries(self: *Pane) void {
        for (self.entries.items) |e| self.gpa.free(e.name);
        self.entries.clearRetainingCapacity();
        self.view.clearRetainingCapacity();
    }

    pub fn dir(self: *const Pane) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }

    pub fn filter(self: *const Pane) []const u8 {
        return self.filter_buf[0..self.filter_len];
    }

    pub fn isQuery(self: *const Pane) bool {
        return self.mode == .query;
    }

    pub fn query(self: *const Pane) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn backDir(self: *const Pane) []const u8 {
        return self.back_buf[0..self.back_len];
    }

    /// What a row shows as the name (a search hit: the file name only).
    pub fn displayName(self: *const Pane, e: *const Entry) []const u8 {
        return if (self.mode == .query) std.fs.path.basename(e.name) else e.name;
    }

    /// Turn the pane into a SEARCH PANE showing `paths` (absolute; copied).
    pub fn showResults(self: *Pane, q: []const u8, paths: []const []const u8, truncated: bool) !void {
        if (self.mode == .dir and self.dir_len > 0) {
            @memcpy(self.back_buf[0..self.dir_len], self.dir());
            self.back_len = self.dir_len;
        }
        self.clearEntries();
        self.mode = .query;
        self.dir_len = 0;
        const n = @min(q.len, QUERY_MAX);
        @memcpy(self.query_buf[0..n], q[0..n]);
        self.query_len = n;
        self.truncated = truncated;
        for (paths) |path| {
            try self.entries.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, path),
                .kind = if (isAudioName(path)) .audio else .other,
            });
        }
        std.mem.sort(Entry, self.entries.items, {}, entryLess);
        self.filter_len = 0;
        self.typing = false;
        try self.refilter();
        self.cursor = 0;
        self.scroll = 0;
    }

    /// Open `path` (made absolute and normalised). On failure the pane
    /// keeps its folder and the error is returned.
    pub fn open(self: *Pane, path: []const u8, reselect: ?[]const u8) !void {
        var abs_buf: [PATH_MAX]u8 = undefined;
        const abs = try std.fs.cwd().realpath(path, &abs_buf);
        var d = try std.fs.openDirAbsolute(abs, .{ .iterate = true });
        defer d.close();

        self.clearEntries();
        @memcpy(self.dir_buf[0..abs.len], abs);
        self.dir_len = abs.len;
        self.err = null;
        self.mode = .dir;
        self.truncated = false;

        if (!std.mem.eql(u8, abs, "/"))
            try self.entries.append(self.gpa, .{ .name = try self.gpa.dupe(u8, ""), .kind = .parent });

        var it = d.iterate();
        while (it.next() catch null) |e| {
            if (e.name.len == 0 or e.name[0] == '.') continue;
            var kind: Kind = switch (e.kind) {
                .directory => .dir,
                else => if (isAudioName(e.name)) .audio else .other,
            };
            var size: u64 = 0;
            if (e.kind == .sym_link or e.kind == .unknown) {
                // follow it: a link to a folder is a folder
                const st = d.statFile(e.name) catch continue;
                if (st.kind == .directory) kind = .dir;
                size = st.size;
            }
            try self.entries.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, e.name),
                .kind = kind,
                .size = size,
            });
        }
        std.mem.sort(Entry, self.entries.items, {}, entryLess);

        self.filter_len = 0;
        self.typing = false;
        try self.refilter();
        self.cursor = 0;
        self.scroll = 0;
        if (reselect) |name| {
            _ = self.select(name);
        } else if (self.view.items.len > 1 and self.entryAt(0).kind == .parent) {
            self.cursor = 1; // land on the first real entry
        }
    }

    pub fn reload(self: *Pane) !void {
        var keep: [PATH_MAX]u8 = undefined;
        const d = self.dir();
        @memcpy(keep[0..d.len], d);
        var name_buf: [256]u8 = undefined;
        var name: ?[]const u8 = null;
        if (self.current()) |e| {
            const n = @min(e.name.len, name_buf.len);
            @memcpy(name_buf[0..n], e.name[0..n]);
            name = name_buf[0..n];
        }
        const f_len = self.filter_len;
        var f_buf: [FILTER_MAX]u8 = undefined;
        @memcpy(f_buf[0..f_len], self.filter_buf[0..f_len]);
        var marks: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = marks.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            marks.deinit(self.gpa);
        }
        for (self.entries.items) |e| if (e.marked) {
            const k = try self.gpa.dupe(u8, e.name);
            marks.put(self.gpa, k, {}) catch self.gpa.free(k);
        };
        try self.open(keep[0..d.len], name);
        if (marks.count() > 0) for (self.entries.items) |*e| {
            if (marks.contains(e.name)) e.marked = true;
        };
        @memcpy(self.filter_buf[0..f_len], f_buf[0..f_len]);
        self.filter_len = f_len;
        try self.refilter();
        if (name) |n| _ = self.select(n);
    }

    /// Put the cursor on the entry called `name`; false if not shown.
    pub fn select(self: *Pane, name: []const u8) bool {
        for (self.view.items, 0..) |idx, i| {
            if (std.mem.eql(u8, self.entries.items[idx].name, name)) {
                self.cursor = i;
                return true;
            }
        }
        return false;
    }

    pub fn entryAt(self: *const Pane, row: usize) *Entry {
        return &self.entries.items[self.view.items[row]];
    }

    pub fn rows(self: *const Pane) usize {
        return self.view.items.len;
    }

    pub fn current(self: *const Pane) ?*Entry {
        if (self.cursor >= self.view.items.len) return null;
        return self.entryAt(self.cursor);
    }

    /// `dir/name` into `buf`, NUL-terminated (for the C side).
    pub fn pathOf(self: *const Pane, e: *const Entry, buf: *[PATH_MAX + 1]u8) ?[:0]const u8 {
        if (self.mode == .query) return std.fmt.bufPrintZ(buf, "{s}", .{e.name}) catch null;
        const d = self.dir();
        const sep: []const u8 = if (std.mem.endsWith(u8, d, "/")) "" else "/";
        const s = std.fmt.bufPrintZ(buf, "{s}{s}{s}", .{ d, sep, e.name }) catch return null;
        return s;
    }

    /// The WAV header of an audio entry (read once, on first ask).
    pub fn info(self: *const Pane, e: *Entry) ?wav.Info {
        if (e.kind != .audio) return null;
        if (!e.info_tried) {
            e.info_tried = true;
            var buf: [PATH_MAX + 1]u8 = undefined;
            if (self.pathOf(e, &buf)) |p| e.info = wav.readPath(p) catch null;
        }
        return e.info;
    }

    /// The library's facts about an audio entry, re-read when the
    /// library changed since (its `gen` moved).
    pub fn facts(self: *const Pane, lib: *library.Library, e: *Entry) *const library.Facts {
        if (e.kind == .audio and e.facts_gen != lib.gen) {
            e.facts_gen = lib.gen;
            var buf: [PATH_MAX + 1]u8 = undefined;
            if (self.pathOf(e, &buf)) |p| lib.facts(p, &e.facts) else e.facts = .{};
        }
        return &e.facts;
    }

    /// What a folder holds (one listing, on first ask).
    pub fn counts(self: *const Pane, e: *Entry) ?Counts {
        if (e.kind != .dir) return null;
        if (e.counts == null) {
            var c: Counts = .{};
            var buf: [PATH_MAX + 1]u8 = undefined;
            const p = self.pathOf(e, &buf) orelse return null;
            var d = std.fs.openDirAbsolute(p, .{ .iterate = true }) catch return null;
            defer d.close();
            var it = d.iterate();
            while (it.next() catch null) |x| {
                if (x.name.len == 0 or x.name[0] == '.') continue;
                if (x.kind == .directory) {
                    c.dirs += 1;
                } else if (isAudioName(x.name)) c.wavs += 1 else c.other += 1;
            }
            e.counts = c;
        }
        return e.counts;
    }

    // ------------------------------------------------------- cursor

    pub fn move(self: *Pane, delta: isize) void {
        const n = self.rows();
        if (n == 0) return;
        const cur: isize = @intCast(self.cursor);
        const next = std.math.clamp(cur + delta, 0, @as(isize, @intCast(n - 1)));
        self.cursor = @intCast(next);
    }

    pub fn home(self: *Pane) void {
        self.cursor = 0;
    }

    pub fn end(self: *Pane) void {
        self.cursor = self.rows() -| 1;
    }

    /// Keep the cursor `margin` rows away from the edges of a `height`-row window.
    pub fn follow(self: *Pane, height: usize) void {
        if (height == 0) return;
        const margin: usize = if (height > 8) 2 else 0;
        if (self.cursor < self.scroll + margin) self.scroll = self.cursor -| margin;
        if (self.cursor + margin >= self.scroll + height) self.scroll = self.cursor + margin + 1 -| height;
        const max_scroll = self.rows() -| height;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
    }

    // ------------------------------------------------------- marks

    /// `v`: flip the mark on the cursor file, then move down.
    pub fn toggleMark(self: *Pane) bool {
        const e = self.current() orelse return false;
        if (!e.isFile()) return false;
        e.marked = !e.marked;
        self.move(1);
        return true;
    }

    /// `V`: any marks -> clear them all; none -> mark every file shown.
    pub fn markAll(self: *Pane) usize {
        if (self.markedCount() > 0) {
            for (self.entries.items) |*e| e.marked = false;
            return 0;
        }
        var n: usize = 0;
        for (self.view.items) |idx| {
            const e = &self.entries.items[idx];
            if (!e.isFile()) continue;
            e.marked = true;
            n += 1;
        }
        return n;
    }

    pub fn clearMarks(self: *Pane) void {
        for (self.entries.items) |*e| e.marked = false;
    }

    pub fn markedCount(self: *const Pane) usize {
        var n: usize = 0;
        for (self.entries.items) |e| n += @intFromBool(e.marked);
        return n;
    }

    // ------------------------------------------------------- filter

    pub fn filterType(self: *Pane, ch: u8) void {
        if (self.filter_len >= FILTER_MAX) return;
        self.filter_buf[self.filter_len] = ch;
        self.filter_len += 1;
        self.refilterKeep();
    }

    pub fn filterBackspace(self: *Pane) void {
        if (self.filter_len == 0) return;
        self.filter_len -= 1;
        self.refilterKeep();
    }

    pub fn filterClear(self: *Pane) void {
        self.filter_len = 0;
        self.typing = false;
        self.refilterKeep();
    }

    /// Refilter, keeping the cursor on the same entry when it survives.
    fn refilterKeep(self: *Pane) void {
        const keep: ?u32 = if (self.cursor < self.view.items.len) self.view.items[self.cursor] else null;
        self.refilter() catch return;
        self.cursor = 0;
        if (keep) |k| {
            for (self.view.items, 0..) |idx, i| if (idx == k) {
                self.cursor = i;
                return;
            };
        }
        // the old entry is gone: the first match, past `..`
        if (self.view.items.len > 1 and self.entryAt(0).kind == .parent) self.cursor = 1;
    }

    fn refilter(self: *Pane) !void {
        self.view.clearRetainingCapacity();
        const q = self.filter();
        for (self.entries.items, 0..) |e, i| {
            if (q.len > 0 and e.kind == .parent) continue;
            if (!matchWords(e.name, q)) continue;
            try self.view.append(self.gpa, @intCast(i));
        }
        if (self.cursor >= self.view.items.len) self.cursor = self.view.items.len -| 1;
    }
};

pub fn isAudioName(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".wav") or std.ascii.eqlIgnoreCase(ext, ".wave");
}

/// Every space-separated word of `q` is a case-insensitive substring of `name`.
pub fn matchWords(name: []const u8, q: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, q, ' ');
    while (it.next()) |w| {
        if (std.ascii.indexOfIgnoreCase(name, w) == null) return false;
    }
    return true;
}

fn rank(k: Kind) u8 {
    return switch (k) {
        .parent => 0,
        .dir => 1,
        .audio, .other => 2,
    };
}

fn entryLess(_: void, a: Entry, b: Entry) bool {
    const ra = rank(a.kind);
    const rb = rank(b.kind);
    if (ra != rb) return ra < rb;
    return naturalLess(a.name, b.name);
}

/// Natural, case-insensitive: digit runs compare as numbers.
pub fn naturalLess(a: []const u8, b: []const u8) bool {
    return naturalOrder(a, b) == .lt;
}

pub fn naturalOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = a[i];
        const cb = b[j];
        if (std.ascii.isDigit(ca) and std.ascii.isDigit(cb)) {
            var ie = i;
            while (ie < a.len and std.ascii.isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and std.ascii.isDigit(b[je])) je += 1;
            // strip leading zeros, then longer = bigger, then digit by digit
            var ia = i;
            while (ia + 1 < ie and a[ia] == '0') ia += 1;
            var jb = j;
            while (jb + 1 < je and b[jb] == '0') jb += 1;
            const la = ie - ia;
            const lb = je - jb;
            if (la != lb) return std.math.order(la, lb);
            const o = std.mem.order(u8, a[ia..ie], b[jb..je]);
            if (o != .eq) return o;
            i = ie;
            j = je;
            continue;
        }
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return std.math.order(la, lb);
        i += 1;
        j += 1;
    }
    const o = std.math.order(a.len - i, b.len - j);
    if (o != .eq) return o;
    return std.mem.order(u8, a, b); // stable tiebreak: "a" vs "A"
}

test "natural order" {
    try std.testing.expect(naturalLess("SC (97).wav", "SC (101).wav"));
    try std.testing.expect(naturalLess("Kick_2", "Kick_10"));
    try std.testing.expect(naturalLess("kick", "Kick_1"));
    try std.testing.expect(naturalLess("abc", "ABD"));
    try std.testing.expect(!naturalLess("Kick_10", "Kick_9"));
    try std.testing.expect(naturalLess("a01", "a2"));
}

test "marks: v toggles and moves, V marks shown files / clears" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("sub");
    for ([_][]const u8{ "kick1.wav", "kick2.wav", "snare.wav" }) |n| try tmp.dir.writeFile(.{ .sub_path = n, .data = "" });
    var pb: [PATH_MAX]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pb);
    var p = Pane{ .gpa = std.testing.allocator };
    defer p.deinit();
    try p.open(root, null);
    // rows: .. sub/ kick1 kick2 snare ; the cursor lands on sub/
    try std.testing.expect(!p.toggleMark()); // a folder: no mark
    p.move(1);
    try std.testing.expect(p.toggleMark()); // kick1, cursor -> kick2
    try std.testing.expectEqualStrings("kick2.wav", p.current().?.name);
    try std.testing.expectEqual(@as(usize, 1), p.markedCount());
    try std.testing.expectEqual(@as(usize, 0), p.markAll()); // had marks: cleared
    for ("kick") |ch| p.filterType(ch);
    try std.testing.expectEqual(@as(usize, 2), p.markAll()); // the 2 shown files
    try p.reload();
    try std.testing.expectEqual(@as(usize, 2), p.markedCount()); // kept by name
}

test "filter words" {
    try std.testing.expect(matchWords("Kick_4.wav", "kick"));
    try std.testing.expect(matchWords("Kick_4.wav", "KICK 4"));
    try std.testing.expect(!matchWords("Kick_4.wav", "kck"));
    try std.testing.expect(matchWords("anything", ""));
    try std.testing.expect(!matchWords("Snare_2.wav", "snare 3"));
}
