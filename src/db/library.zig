//! THE LIBRARY: kr8's database, `$KR8_HOME/kr8.db` (~/.config/kr8).
//!
//! TAGS BELONG TO THE SOUND, NOT THE PATH. A `sound` is one fingerprint -
//! (length, wyhash64) of a WAV's data chunk, the audio only. A `file` is a
//! path where a sound was seen. Tags and notes hang off the sound, so a
//! move in Finder heals on the next scan, copies share tags, and
//! duplicates are just "a sound with two files".
//!
//! ROOTS are the indexed folders. Paths are stored relative to their root
//! (a moved library is one root edit). Files outside every root - tagged
//! while browsing a pack that is not a root yet - are LOOSE: root_id 0 and
//! an absolute path; adding a root later adopts them. Roots never nest:
//! adding a folder that holds a root ABSORBS it (its rows are re-pointed,
//! nothing is rehashed); adding one inside a root is refused.
//!
//! Sounds are never deleted by a scan: a sound whose files are gone keeps
//! its tags, and they come back when the file does.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const wav = @import("../audio/wav.zig");

pub const SCHEMA =
    \\CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
    \\CREATE TABLE IF NOT EXISTS root(
    \\  id INTEGER PRIMARY KEY,
    \\  path TEXT UNIQUE NOT NULL,
    \\  added INTEGER);
    \\CREATE TABLE IF NOT EXISTS sound(
    \\  id INTEGER PRIMARY KEY,
    \\  dlen INTEGER NOT NULL, dhash INTEGER NOT NULL,
    \\  frames INTEGER, rate INTEGER, bits INTEGER, channels INTEGER, fmt INTEGER,
    \\  loop_start INTEGER, loop_end INTEGER, root_note INTEGER, flags INTEGER,
    \\  UNIQUE(dlen, dhash));
    \\CREATE TABLE IF NOT EXISTS file(
    \\  id INTEGER PRIMARY KEY,
    \\  root_id INTEGER NOT NULL,
    \\  path TEXT NOT NULL,
    \\  size INTEGER, mtime INTEGER,
    \\  sound_id INTEGER NOT NULL REFERENCES sound(id),
    \\  seen INTEGER,
    \\  UNIQUE(root_id, path));
    \\CREATE INDEX IF NOT EXISTS file_sound ON file(sound_id);
    \\CREATE TABLE IF NOT EXISTS tag(
    \\  id INTEGER PRIMARY KEY,
    \\  name TEXT UNIQUE NOT NULL COLLATE NOCASE,
    \\  created INTEGER);
    \\CREATE TABLE IF NOT EXISTS sound_tag(
    \\  sound_id INTEGER NOT NULL REFERENCES sound(id) ON DELETE CASCADE,
    \\  tag_id INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
    \\  added INTEGER,
    \\  PRIMARY KEY(sound_id, tag_id));
    \\CREATE INDEX IF NOT EXISTS sound_tag_tag ON sound_tag(tag_id);
    \\CREATE TABLE IF NOT EXISTS note(
    \\  sound_id INTEGER PRIMARY KEY REFERENCES sound(id) ON DELETE CASCADE,
    \\  text TEXT NOT NULL,
    \\  updated INTEGER);
    \\INSERT OR IGNORE INTO meta(key, value) VALUES('schema', '1');
    \\INSERT OR IGNORE INTO meta(key, value) VALUES('scan_gen', '0');
;

pub const FLAG_WAVETABLE: i64 = 1;
pub const TAG_MAX = 32;

/// `$KR8_HOME/kr8.db`, NUL-terminated; the folder is created.
pub fn dbPath(buf: []u8) ?[:0]const u8 {
    const config = @import("../app/config.zig");
    var hb: [std.fs.max_path_bytes]u8 = undefined;
    const home = config.homePath(&hb) orelse return null;
    std.fs.cwd().makePath(home) catch return null;
    return std.fmt.bufPrintZ(buf, "{s}/kr8.db", .{home}) catch null;
}

pub fn now() i64 {
    return std.time.timestamp();
}

// ------------------------------------------------------------ fingerprint

pub const Print = struct { dlen: u64, dhash: u64 };

/// Hash the data chunk (the samples, nothing else).
pub fn fingerprint(f: std.fs.File, info: wav.Info) !Print {
    var h = std.hash.Wyhash.init(0);
    var buf: [64 * 1024]u8 = undefined;
    var off = info.data_offset;
    var left = info.data_len;
    while (left > 0) {
        const n: usize = @intCast(@min(left, buf.len));
        const got = try f.preadAll(buf[0..n], off);
        if (got == 0) break;
        h.update(buf[0..got]);
        off += got;
        left -= got;
    }
    return .{ .dlen = info.data_len, .dhash = h.final() };
}

// ------------------------------------------------------------ indexer

/// Fingerprint one file and write its `sound` + `file` rows. Used by the
/// scanner (its own connection) and by the UI (tagging an unknown file).
pub const Indexer = struct {
    ins_sound: sqlite.Stmt,
    get_sound: sqlite.Stmt,
    up_file: sqlite.Stmt,

    pub fn init(db: *sqlite.Db) !Indexer {
        var a = try db.prepare(
            \\INSERT INTO sound(dlen, dhash, frames, rate, bits, channels, fmt,
            \\  loop_start, loop_end, root_note, flags)
            \\VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            \\ON CONFLICT(dlen, dhash) DO NOTHING
        );
        errdefer a.deinit();
        var b = try db.prepare("SELECT id FROM sound WHERE dlen = ?1 AND dhash = ?2");
        errdefer b.deinit();
        const c = try db.prepare(
            \\INSERT INTO file(root_id, path, size, mtime, sound_id, seen)
            \\VALUES(?1, ?2, ?3, ?4, ?5, ?6)
            \\ON CONFLICT(root_id, path) DO UPDATE SET
            \\  size = excluded.size, mtime = excluded.mtime,
            \\  sound_id = excluded.sound_id, seen = excluded.seen
        );
        return .{ .ins_sound = a, .get_sound = b, .up_file = c };
    }

    pub fn deinit(self: *Indexer) void {
        self.ins_sound.deinit();
        self.get_sound.deinit();
        self.up_file.deinit();
    }

    /// Returns the sound id. `abs` is read; `root_id`/`path` key the row.
    pub fn index(self: *Indexer, abs: []const u8, root_id: i64, path: []const u8, size: u64, mtime: i64, gen: i64) !i64 {
        var f = try std.fs.cwd().openFile(abs, .{});
        defer f.close();
        const info = try wav.read(f);
        const fp = try fingerprint(f, info);
        const dlen: i64 = @intCast(fp.dlen);
        const dhash: i64 = @bitCast(fp.dhash);

        const s = &self.ins_sound;
        try s.bindInt(1, dlen);
        try s.bindInt(2, dhash);
        try s.bindInt(3, @intCast(info.frames));
        try s.bindInt(4, info.rate);
        try s.bindInt(5, info.bits);
        try s.bindInt(6, info.channels);
        try s.bindInt(7, @intFromEnum(info.format));
        try s.bindInt(8, info.loop_start);
        try s.bindInt(9, info.loop_end);
        try s.bindInt(10, if (info.root_note) |n| n else -1);
        try s.bindInt(11, if (info.wavetable) FLAG_WAVETABLE else 0);
        try s.run();

        const g = &self.get_sound;
        defer g.reset();
        try g.bindInt(1, dlen);
        try g.bindInt(2, dhash);
        if (!try g.step()) return error.SoundMissing;
        const sid = g.int(0);

        const u = &self.up_file;
        try u.bindInt(1, root_id);
        try u.bindText(2, path);
        try u.bindInt(3, @intCast(size));
        try u.bindInt(4, mtime);
        try u.bindInt(5, sid);
        try u.bindInt(6, gen);
        try u.run();
        return sid;
    }
};

// ------------------------------------------------------------ roots

pub const Root = struct { id: i64, path: []u8 };

/// Where `abs` lives: (root id, path relative to it), or (0, abs) loose.
pub const Place = struct { root_id: i64, path: []const u8 };

pub fn placeIn(roots: []const Root, abs: []const u8) Place {
    for (roots) |r| {
        if (std.mem.startsWith(u8, abs, r.path) and abs.len > r.path.len + 1 and abs[r.path.len] == '/')
            return .{ .root_id = r.id, .path = abs[r.path.len + 1 ..] };
    }
    return .{ .root_id = 0, .path = abs };
}

/// `inner` is `outer` or below it.
pub fn isWithin(inner: []const u8, outer: []const u8) bool {
    if (std.mem.eql(u8, inner, outer)) return true;
    return std.mem.startsWith(u8, inner, outer) and inner.len > outer.len and
        (inner[outer.len] == '/' or std.mem.eql(u8, outer, "/"));
}

// ------------------------------------------------------------ the library

/// What a row shows about a file: its sound, its copies, tags, note.
pub const Facts = struct {
    sound: i64 = 0, // 0 = not in the library
    files: u32 = 0,
    has_note: bool = false,
    tags_buf: [80]u8 = undefined,
    tags_len: u8 = 0,

    pub fn tags(self: *const Facts) []const u8 {
        return self.tags_buf[0..self.tags_len];
    }
};

pub const TagRow = struct { id: i64, name: []u8, count: i64 };

pub const Library = struct {
    gpa: std.mem.Allocator,
    db: sqlite.Db,
    roots: std.ArrayList(Root) = .empty,
    /// bumps on every change a row could show (tags, notes, scans)
    gen: u32 = 1,
    idx: Indexer,
    q_file: sqlite.Stmt,
    q_count: sqlite.Stmt,
    q_tags: sqlite.Stmt,
    q_note: sqlite.Stmt,

    pub fn open(gpa: std.mem.Allocator, path: [:0]const u8) !*Library {
        var db = try sqlite.Db.open(path);
        errdefer db.close();
        try db.exec(SCHEMA);
        const self = try gpa.create(Library);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .db = db,
            .idx = undefined,
            .q_file = undefined,
            .q_count = undefined,
            .q_tags = undefined,
            .q_note = undefined,
        };
        self.idx = try Indexer.init(&self.db);
        self.q_file = try self.db.prepare("SELECT sound_id, size, mtime FROM file WHERE root_id = ?1 AND path = ?2");
        self.q_count = try self.db.prepare("SELECT COUNT(*) FROM file WHERE sound_id = ?1");
        self.q_tags = try self.db.prepare(
            \\SELECT t.name FROM sound_tag st JOIN tag t ON t.id = st.tag_id
            \\WHERE st.sound_id = ?1 ORDER BY t.name
        );
        self.q_note = try self.db.prepare("SELECT text FROM note WHERE sound_id = ?1");
        try self.loadRoots();
        return self;
    }

    pub fn close(self: *Library) void {
        self.idx.deinit();
        self.q_file.deinit();
        self.q_count.deinit();
        self.q_tags.deinit();
        self.q_note.deinit();
        self.freeRoots();
        self.roots.deinit(self.gpa);
        self.db.close();
        self.gpa.destroy(self);
    }

    fn freeRoots(self: *Library) void {
        for (self.roots.items) |r| self.gpa.free(r.path);
        self.roots.clearRetainingCapacity();
    }

    pub fn loadRoots(self: *Library) !void {
        self.freeRoots();
        var st = try self.db.prepare("SELECT id, path FROM root ORDER BY path");
        defer st.deinit();
        while (try st.step()) {
            const p = try self.gpa.dupe(u8, st.text(1));
            try self.roots.append(self.gpa, .{ .id = st.int(0), .path = p });
        }
    }

    pub fn place(self: *const Library, abs: []const u8) Place {
        return placeIn(self.roots.items, abs);
    }

    pub fn scanGen(self: *Library) i64 {
        var st = self.db.prepare("SELECT value FROM meta WHERE key = 'scan_gen'") catch return 0;
        defer st.deinit();
        if (!(st.step() catch false)) return 0;
        return std.fmt.parseInt(i64, st.text(0), 10) catch 0;
    }

    // ---------------------------------------------------- roots

    pub const AddResult = struct { id: i64, absorbed: usize, adopted: usize };

    /// Add `abs` (a real path) as a root: refuse one inside a root, absorb
    /// roots and loose files below it.
    pub fn addRoot(self: *Library, abs: []const u8) !AddResult {
        for (self.roots.items) |r| {
            if (isWithin(abs, r.path)) return error.InsideRoot;
        }
        try self.db.exec("BEGIN");
        errdefer self.db.exec("ROLLBACK") catch {};
        var ins = try self.db.prepare("INSERT INTO root(path, added) VALUES(?1, ?2)");
        defer ins.deinit();
        try ins.bindText(1, abs);
        try ins.bindInt(2, now());
        try ins.run();
        const id = self.db.lastId();

        var res: AddResult = .{ .id = id, .absorbed = 0, .adopted = 0 };
        // roots below: re-point their rows ("sub/" prefix), drop the root
        var mv = try self.db.prepare("UPDATE file SET root_id = ?1, path = ?2 || path WHERE root_id = ?3");
        defer mv.deinit();
        var del = try self.db.prepare("DELETE FROM root WHERE id = ?1");
        defer del.deinit();
        for (self.roots.items) |r| {
            if (!isWithin(r.path, abs)) continue;
            var pb: [std.fs.max_path_bytes]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&pb, "{s}/", .{r.path[abs.len + 1 ..]});
            try mv.bindInt(1, id);
            try mv.bindText(2, prefix);
            try mv.bindInt(3, r.id);
            try mv.run();
            try del.bindInt(1, r.id);
            try del.run();
            res.absorbed += 1;
        }
        // loose files below: adopt them
        var pb2: [std.fs.max_path_bytes]u8 = undefined;
        const loose_prefix = try std.fmt.bufPrint(&pb2, "{s}/", .{abs});
        var cnt = try self.db.prepare("SELECT COUNT(*) FROM file WHERE root_id = 0 AND substr(path, 1, ?1) = ?2");
        defer cnt.deinit();
        try cnt.bindInt(1, @intCast(loose_prefix.len));
        try cnt.bindText(2, loose_prefix);
        if (try cnt.step()) res.adopted = @intCast(cnt.int(0));
        var ad = try self.db.prepare(
            \\UPDATE OR IGNORE file SET root_id = ?1, path = substr(path, ?2)
            \\WHERE root_id = 0 AND substr(path, 1, ?3) = ?4
        );
        defer ad.deinit();
        try ad.bindInt(1, id);
        try ad.bindInt(2, @intCast(loose_prefix.len + 1));
        try ad.bindInt(3, @intCast(loose_prefix.len));
        try ad.bindText(4, loose_prefix);
        try ad.run();
        try self.db.exec("COMMIT");
        try self.loadRoots();
        self.gen +%= 1;
        return res;
    }

    /// Forget a root and its file rows; its sounds keep their tags.
    pub fn removeRoot(self: *Library, abs: []const u8) !void {
        var id: ?i64 = null;
        for (self.roots.items) |r| if (std.mem.eql(u8, r.path, abs)) {
            id = r.id;
        };
        const rid = id orelse return error.NotARoot;
        try self.db.exec("BEGIN");
        errdefer self.db.exec("ROLLBACK") catch {};
        var a = try self.db.prepare("DELETE FROM file WHERE root_id = ?1");
        defer a.deinit();
        try a.bindInt(1, rid);
        try a.run();
        var b = try self.db.prepare("DELETE FROM root WHERE id = ?1");
        defer b.deinit();
        try b.bindInt(1, rid);
        try b.run();
        try self.db.exec("COMMIT");
        try self.loadRoots();
        self.gen +%= 1;
    }

    pub fn rootFileCount(self: *Library, id: i64) i64 {
        var st = self.db.prepare("SELECT COUNT(*) FROM file WHERE root_id = ?1") catch return 0;
        defer st.deinit();
        st.bindInt(1, id) catch return 0;
        if (!(st.step() catch false)) return 0;
        return st.int(0);
    }

    // ---------------------------------------------------- lookups

    /// The sound of the file at `abs` as the library knows it (0 = unknown).
    pub fn soundOf(self: *Library, abs: []const u8) i64 {
        const pl = self.place(abs);
        const q = &self.q_file;
        defer q.reset();
        q.bindInt(1, pl.root_id) catch return 0;
        q.bindText(2, pl.path) catch return 0;
        if (!(q.step() catch false)) return 0;
        return q.int(0);
    }

    /// Everything a row shows about `abs`.
    pub fn facts(self: *Library, abs: []const u8, out: *Facts) void {
        out.* = .{};
        const sid = self.soundOf(abs);
        if (sid == 0) return;
        out.sound = sid;
        {
            const q = &self.q_count;
            defer q.reset();
            q.bindInt(1, sid) catch return;
            if (q.step() catch false) out.files = @intCast(q.int(0));
        }
        {
            const q = &self.q_tags;
            defer q.reset();
            q.bindInt(1, sid) catch return;
            var n: usize = 0;
            while (q.step() catch false) {
                const t = q.text(0);
                const need = t.len + @intFromBool(n > 0);
                if (n + need > out.tags_buf.len) break;
                if (n > 0) {
                    out.tags_buf[n] = ' ';
                    n += 1;
                }
                @memcpy(out.tags_buf[n..][0..t.len], t);
                n += t.len;
            }
            out.tags_len = @intCast(n);
        }
        {
            const q = &self.q_note;
            defer q.reset();
            q.bindInt(1, sid) catch return;
            out.has_note = q.step() catch false;
        }
    }

    pub fn note(self: *Library, sid: i64, buf: []u8) []const u8 {
        const q = &self.q_note;
        defer q.reset();
        q.bindInt(1, sid) catch return "";
        if (!(q.step() catch false)) return "";
        const t = q.text(0);
        const n = @min(t.len, buf.len);
        @memcpy(buf[0..n], t[0..n]);
        return buf[0..n];
    }

    /// The sound of `abs`, indexing it first when the library has not seen
    /// it (or it changed). Loose when it is outside every root.
    pub fn ensureSound(self: *Library, abs: []const u8) !i64 {
        const st = try std.fs.cwd().statFile(abs);
        const mtime: i64 = @intCast(@divTrunc(st.mtime, std.time.ns_per_ms));
        const pl = self.place(abs);
        {
            const q = &self.q_file;
            defer q.reset();
            try q.bindInt(1, pl.root_id);
            try q.bindText(2, pl.path);
            if (try q.step()) {
                if (q.int(1) == @as(i64, @intCast(st.size)) and q.int(2) == mtime) return q.int(0);
            }
        }
        const sid = try self.idx.index(abs, pl.root_id, pl.path, st.size, mtime, self.scanGen());
        self.gen +%= 1;
        return sid;
    }

    // ---------------------------------------------------- tags

    /// Lowercase, spaces to '-', no leading '#', at most TAG_MAX bytes.
    pub fn normTag(raw: []const u8, buf: *[TAG_MAX]u8) []const u8 {
        var n: usize = 0;
        for (raw) |ch| {
            if (n >= buf.len) break;
            if (n == 0 and (ch == '#' or ch == ' ')) continue;
            buf[n] = if (ch == ' ') '-' else std.ascii.toLower(ch);
            n += 1;
        }
        while (n > 0 and buf[n - 1] == '-') n -= 1;
        return buf[0..n];
    }

    pub fn tagId(self: *Library, name: []const u8, create: bool) !?i64 {
        if (create) {
            var ins = try self.db.prepare("INSERT INTO tag(name, created) VALUES(?1, ?2) ON CONFLICT(name) DO NOTHING");
            defer ins.deinit();
            try ins.bindText(1, name);
            try ins.bindInt(2, now());
            try ins.run();
        }
        var q = try self.db.prepare("SELECT id FROM tag WHERE name = ?1");
        defer q.deinit();
        try q.bindText(1, name);
        if (!try q.step()) return null;
        return q.int(0);
    }

    pub fn tagName(self: *Library, id: i64, buf: []u8) []const u8 {
        var q = self.db.prepare("SELECT name FROM tag WHERE id = ?1") catch return "";
        defer q.deinit();
        q.bindInt(1, id) catch return "";
        if (!(q.step() catch false)) return "";
        const t = q.text(0);
        const n = @min(t.len, buf.len);
        @memcpy(buf[0..n], t[0..n]);
        return buf[0..n];
    }

    pub fn hasTag(self: *Library, sid: i64, tid: i64) bool {
        var q = self.db.prepare("SELECT 1 FROM sound_tag WHERE sound_id = ?1 AND tag_id = ?2") catch return false;
        defer q.deinit();
        q.bindInt(1, sid) catch return false;
        q.bindInt(2, tid) catch return false;
        return q.step() catch false;
    }

    pub fn setTag(self: *Library, sid: i64, tid: i64, on: bool) !void {
        var q = if (on)
            try self.db.prepare("INSERT OR IGNORE INTO sound_tag(sound_id, tag_id, added) VALUES(?1, ?2, ?3)")
        else
            try self.db.prepare("DELETE FROM sound_tag WHERE sound_id = ?1 AND tag_id = ?2");
        defer q.deinit();
        try q.bindInt(1, sid);
        try q.bindInt(2, tid);
        if (on) try q.bindInt(3, now());
        try q.run();
        self.gen +%= 1;
    }

    /// Every tag with how many sounds carry it, most used first.
    pub fn listTags(self: *Library, gpa: std.mem.Allocator) ![]TagRow {
        var out: std.ArrayList(TagRow) = .empty;
        errdefer {
            for (out.items) |t| gpa.free(t.name);
            out.deinit(gpa);
        }
        var q = try self.db.prepare(
            \\SELECT t.id, t.name, COUNT(st.sound_id) AS n FROM tag t
            \\LEFT JOIN sound_tag st ON st.tag_id = t.id
            \\GROUP BY t.id ORDER BY n DESC, t.name
        );
        defer q.deinit();
        while (try q.step()) {
            const name = try gpa.dupe(u8, q.text(1));
            errdefer gpa.free(name);
            try out.append(gpa, .{ .id = q.int(0), .name = name, .count = q.int(2) });
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn freeTags(gpa: std.mem.Allocator, tags: []TagRow) void {
        for (tags) |t| gpa.free(t.name);
        gpa.free(tags);
    }

    /// Give sound `to` every tag of sound `from` (a cut inherits its source's tags).
    pub fn copyTags(self: *Library, from: i64, to: i64) !void {
        var q = try self.db.prepare(
            \\INSERT OR IGNORE INTO sound_tag(sound_id, tag_id, added)
            \\SELECT ?2, tag_id, ?3 FROM sound_tag WHERE sound_id = ?1
        );
        defer q.deinit();
        try q.bindInt(1, from);
        try q.bindInt(2, to);
        try q.bindInt(3, now());
        try q.run();
        self.gen +%= 1;
    }

    // ---------------------------------------------------- notes

    /// Set the note of a sound; an empty text deletes it.
    pub fn setNote(self: *Library, sid: i64, text: []const u8) !void {
        if (text.len == 0) {
            var q = try self.db.prepare("DELETE FROM note WHERE sound_id = ?1");
            defer q.deinit();
            try q.bindInt(1, sid);
            try q.run();
        } else {
            var q = try self.db.prepare(
                \\INSERT INTO note(sound_id, text, updated) VALUES(?1, ?2, ?3)
                \\ON CONFLICT(sound_id) DO UPDATE SET text = excluded.text, updated = excluded.updated
            );
            defer q.deinit();
            try q.bindInt(1, sid);
            try q.bindText(2, text);
            try q.bindInt(3, now());
            try q.run();
        }
        self.gen +%= 1;
    }

    // ---------------------------------------------------- numbers

    /// Search the library (syntax: see `termSql`).
    pub fn find(self: *Library, gpa: std.mem.Allocator, query: []const u8) !Found {
        return libFind(self, gpa, query);
    }

    pub fn findCount(self: *Library, gpa: std.mem.Allocator, query: []const u8) !i64 {
        return libFindCount(self, gpa, query);
    }

    pub const Stats = struct { sounds: i64 = 0, files: i64 = 0, dupe_sounds: i64 = 0, tagged: i64 = 0, tags: i64 = 0 };

    pub fn stats(self: *Library) Stats {
        var s: Stats = .{};
        const one = struct {
            fn f(db: *sqlite.Db, sql: [:0]const u8) i64 {
                var q = db.prepare(sql) catch return 0;
                defer q.deinit();
                if (!(q.step() catch false)) return 0;
                return q.int(0);
            }
        }.f;
        s.sounds = one(&self.db, "SELECT COUNT(*) FROM sound");
        s.files = one(&self.db, "SELECT COUNT(*) FROM file");
        s.dupe_sounds = one(&self.db, "SELECT COUNT(*) FROM (SELECT sound_id FROM file GROUP BY sound_id HAVING COUNT(*) > 1)");
        s.tagged = one(&self.db, "SELECT COUNT(DISTINCT sound_id) FROM sound_tag");
        s.tags = one(&self.db, "SELECT COUNT(*) FROM tag");
        return s;
    }
};

// ------------------------------------------------------------ find

pub const FIND_LIMIT = 5000;

pub const FindError = error{ EmptyQuery, UnknownIs, BadLength };

const Bind = union(enum) { text: []const u8, int: i64 };

/// One search term as SQL over `file f JOIN sound s` (see `find`).
/// Words are matched EXACTLY (a case-insensitive substring), never fuzzy.
fn termSql(tok: []const u8, sql: *std.ArrayList(u8), binds: *std.ArrayList(Bind), gpa: std.mem.Allocator, lower: []u8) !void {
    var t = tok;
    var neg = false;
    if (t.len > 1 and t[0] == '-') {
        neg = true;
        t = t[1..];
    }
    const n = binds.items.len + 1; // this term's ?N
    var w = sql.writer(gpa);
    if (t[0] == '#' and t.len > 1) {
        var tb: [TAG_MAX]u8 = undefined;
        const name = Library.normTag(t[1..], &tb);
        const owned = lower[0..name.len];
        @memcpy(owned, name);
        try binds.append(gpa, .{ .text = owned });
        try w.print("{s}EXISTS(SELECT 1 FROM sound_tag st JOIN tag t ON t.id = st.tag_id " ++
            "WHERE st.sound_id = f.sound_id AND t.name = ?{d})", .{ if (neg) "NOT " else "", n });
        return;
    }
    if (t[0] == '<' or t[0] == '>') {
        var num = t[1..];
        var mul: f64 = 1000; // seconds by default
        if (std.mem.endsWith(u8, num, "ms")) {
            num = num[0 .. num.len - 2];
            mul = 1;
        } else if (std.mem.endsWith(u8, num, "s")) num = num[0 .. num.len - 1];
        const v = std.fmt.parseFloat(f64, num) catch return error.BadLength;
        try binds.append(gpa, .{ .int = @intFromFloat(v * mul) });
        try w.print("(s.rate > 0 AND s.frames * 1000 / s.rate {s} ?{d})", .{ t[0..1], n });
        return;
    }
    if (std.mem.startsWith(u8, t, "is:")) {
        const k = t[3..];
        const frag: []const u8 = if (std.mem.eql(u8, k, "dupe"))
            "(SELECT COUNT(*) FROM file f2 WHERE f2.sound_id = f.sound_id) > 1"
        else if (std.mem.eql(u8, k, "mono"))
            "s.channels = 1"
        else if (std.mem.eql(u8, k, "stereo"))
            "s.channels = 2"
        else if (std.mem.eql(u8, k, "loop"))
            "s.loop_end > s.loop_start"
        else if (std.mem.eql(u8, k, "wavetable"))
            "(s.flags & 1) != 0"
        else if (std.mem.eql(u8, k, "tagged"))
            "EXISTS(SELECT 1 FROM sound_tag st WHERE st.sound_id = f.sound_id)"
        else if (std.mem.eql(u8, k, "untagged"))
            "NOT EXISTS(SELECT 1 FROM sound_tag st WHERE st.sound_id = f.sound_id)"
        else if (std.mem.eql(u8, k, "noted"))
            "EXISTS(SELECT 1 FROM note nt WHERE nt.sound_id = f.sound_id)"
        else
            return error.UnknownIs;
        try w.print("{s}({s})", .{ if (neg) "NOT " else "", frag });
        return;
    }
    // a word: the path (folders + name), a tag or the note contains it
    const owned = lower[0..t.len];
    for (t, 0..) |ch, i| owned[i] = std.ascii.toLower(ch);
    try binds.append(gpa, .{ .text = owned });
    try w.print("{s}(instr(lower(f.path), ?{d}) > 0" ++
        " OR EXISTS(SELECT 1 FROM sound_tag st JOIN tag t ON t.id = st.tag_id" ++
        " WHERE st.sound_id = f.sound_id AND instr(lower(t.name), ?{d}) > 0)" ++
        " OR EXISTS(SELECT 1 FROM note nt WHERE nt.sound_id = f.sound_id AND instr(lower(nt.text), ?{d}) > 0))", .{ if (neg) "NOT " else "", n, n, n });
}

/// The query as a prepared statement: `head` + WHERE every term.
fn findStmt(self: *Library, gpa: std.mem.Allocator, query: []const u8, head: []const u8, tail: []const u8, scratch: []u8) !sqlite.Stmt {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    var binds: std.ArrayList(Bind) = .empty;
    defer binds.deinit(gpa);
    try sql.appendSlice(gpa, head);
    try sql.appendSlice(gpa, " WHERE 1");
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    var used: usize = 0;
    var terms: usize = 0;
    while (it.next()) |tok| {
        if (used + tok.len > scratch.len) break;
        try sql.appendSlice(gpa, " AND ");
        try termSql(tok, &sql, &binds, gpa, scratch[used..]);
        used += tok.len;
        terms += 1;
    }
    if (terms == 0) return error.EmptyQuery;
    try sql.appendSlice(gpa, tail);
    try sql.append(gpa, 0);
    var st = try self.db.prepare(sql.items[0 .. sql.items.len - 1 :0]);
    errdefer st.deinit();
    for (binds.items, 0..) |b, i| switch (b) {
        .text => |v| try st.bindText(@intCast(i + 1), v),
        .int => |v| try st.bindInt(@intCast(i + 1), v),
    };
    return st;
}

const FIND_HEAD = "FROM file f JOIN sound s ON s.id = f.sound_id LEFT JOIN root r ON r.id = f.root_id";

/// How many files match (the FIND prompt counts as you type).
fn libFindCount(self: *Library, gpa: std.mem.Allocator, query: []const u8) !i64 {
    var scratch: [512]u8 = undefined;
    var st = try findStmt(self, gpa, query, "SELECT COUNT(*) " ++ FIND_HEAD, "", &scratch);
    defer st.deinit();
    if (!try st.step()) return 0;
    return st.int(0);
}

pub const Found = struct {
    paths: [][]u8,
    truncated: bool,

    pub fn deinit(self: *Found, gpa: std.mem.Allocator) void {
        for (self.paths) |p| gpa.free(p);
        gpa.free(self.paths);
    }
};

/// Every matching file as an absolute path (at most FIND_LIMIT).
fn libFind(self: *Library, gpa: std.mem.Allocator, query: []const u8) !Found {
    var scratch: [512]u8 = undefined;
    var st = try findStmt(self, gpa, query, "SELECT CASE WHEN f.root_id = 0 THEN f.path ELSE r.path || '/' || f.path END " ++ FIND_HEAD, std.fmt.comptimePrint(" LIMIT {d}", .{FIND_LIMIT + 1}), &scratch);
    defer st.deinit();
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    var truncated = false;
    while (try st.step()) {
        if (out.items.len >= FIND_LIMIT) {
            truncated = true;
            break;
        }
        try out.append(gpa, try gpa.dupe(u8, st.text(0)));
    }
    return .{ .paths = try out.toOwnedSlice(gpa), .truncated = truncated };
}

// ------------------------------------------------------------------ tests

test "placeIn and isWithin" {
    var a = "/s/trackers".*;
    const roots = [_]Root{.{ .id = 3, .path = &a }};
    const p = placeIn(&roots, "/s/trackers/Breaks/Amen.wav");
    try std.testing.expectEqual(@as(i64, 3), p.root_id);
    try std.testing.expectEqualStrings("Breaks/Amen.wav", p.path);
    try std.testing.expectEqual(@as(i64, 0), placeIn(&roots, "/s/trackers2/x.wav").root_id);
    try std.testing.expect(isWithin("/s/trackers/x", "/s"));
    try std.testing.expect(!isWithin("/s2", "/s"));
}

test "find: words, tags, lengths, is:" {
    const gpa = std.testing.allocator;
    const lib = try Library.open(gpa, ":memory:");
    defer lib.close();
    try lib.db.exec(
        \\INSERT INTO root(id, path) VALUES(1, '/lib');
        \\INSERT INTO sound(id, dlen, dhash, frames, rate, channels, flags) VALUES
        \\  (1, 10, 1, 22050, 44100, 1, 0), (2, 20, 2, 441000, 44100, 2, 0), (3, 30, 3, 4410, 44100, 1, 1);
        \\INSERT INTO file(root_id, path, sound_id) VALUES
        \\  (1, 'Techstep Kicks/BD_01.wav', 1), (1, 'Breaks/Amen.wav', 2),
        \\  (1, 'copies/BD_01.wav', 1), (0, '/elsewhere/wt.wav', 3);
        \\INSERT INTO tag(id, name) VALUES(1, 'good');
        \\INSERT INTO sound_tag(sound_id, tag_id) VALUES(2, 1);
        \\INSERT INTO note(sound_id, text) VALUES(3, 'Serum table');
    );
    try std.testing.expectEqual(@as(i64, 1), try lib.findCount(gpa, "kick")); // the folder name counts
    try std.testing.expectEqual(@as(i64, 2), try lib.findCount(gpa, "bd_01"));
    try std.testing.expectEqual(@as(i64, 1), try lib.findCount(gpa, "#good"));
    try std.testing.expectEqual(@as(i64, 1), try lib.findCount(gpa, "good")); // a word finds tags too
    try std.testing.expectEqual(@as(i64, 0), try lib.findCount(gpa, "good -#good"));
    try std.testing.expectEqual(@as(i64, 3), try lib.findCount(gpa, "<1s"));
    try std.testing.expectEqual(@as(i64, 1), try lib.findCount(gpa, ">2s"));
    try std.testing.expectEqual(@as(i64, 2), try lib.findCount(gpa, "is:dupe"));
    try std.testing.expectEqual(@as(i64, 1), try lib.findCount(gpa, "serum is:wavetable"));
    try std.testing.expectEqual(@as(i64, 1), try lib.findCount(gpa, "bd -copies"));
    try std.testing.expectError(error.UnknownIs, lib.findCount(gpa, "is:nope"));
    try std.testing.expectError(error.EmptyQuery, lib.findCount(gpa, "  "));
    var f = try lib.find(gpa, "amen");
    defer f.deinit(gpa);
    try std.testing.expectEqualStrings("/lib/Breaks/Amen.wav", f.paths[0]);
    var g = try lib.find(gpa, "wt");
    defer g.deinit(gpa);
    try std.testing.expectEqualStrings("/elsewhere/wt.wav", g.paths[0]); // loose: absolute
}

test "normTag" {
    var b: [TAG_MAX]u8 = undefined;
    try std.testing.expectEqualStrings("dark-kick", Library.normTag("#Dark Kick ", &b));
}
