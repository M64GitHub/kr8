//! A thin SQLite wrapper (the amalgamation is compiled into kr8, see
//! build.zig). One `Db` per thread: the UI and the scanner each open their
//! own connection; WAL mode lets the UI read while the scanner writes.

const std = @import("std");
pub const c = @cImport(@cInclude("sqlite3.h"));

/// sqlite3_bind_text with SQLITE_TRANSIENT (sqlite copies the bytes);
/// in C because Zig can't spell the macro's `(destructor)-1` (sqlite_shim.c).
extern fn kr8_bind_text(s: *c.sqlite3_stmt, i: c_int, p: [*]const u8, n: c_int) c_int;

pub const Db = struct {
    h: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Db {
        var h: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX;
        if (c.sqlite3_open_v2(path.ptr, &h, flags, null) != c.SQLITE_OK) {
            if (h) |p| _ = c.sqlite3_close_v2(p);
            return error.SqliteOpen;
        }
        _ = c.sqlite3_busy_timeout(h.?, 5000);
        var db: Db = .{ .h = h.? };
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;");
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close_v2(self.h);
    }

    pub fn exec(self: *Db, sql: [:0]const u8) !void {
        var err: [*c]u8 = null;
        if (c.sqlite3_exec(self.h, sql.ptr, null, null, &err) != c.SQLITE_OK) {
            if (err != null) {
                std.log.err("sqlite: {s}", .{std.mem.span(err)});
                c.sqlite3_free(err);
            }
            return error.SqliteExec;
        }
    }

    pub fn prepare(self: *Db, sql: [:0]const u8) !Stmt {
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.h, sql.ptr, @intCast(sql.len + 1), &s, null) != c.SQLITE_OK) {
            std.log.err("sqlite prepare: {s}\n  {s}", .{ self.errmsg(), sql });
            return error.SqlitePrepare;
        }
        return .{ .s = s.? };
    }

    pub fn errmsg(self: *Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.h));
    }

    pub fn lastId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.h);
    }
};

pub const Stmt = struct {
    s: *c.sqlite3_stmt,

    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.s);
    }

    /// Ready for the next use: reset + clear bindings.
    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.s);
        _ = c.sqlite3_clear_bindings(self.s);
    }

    pub fn bindInt(self: *Stmt, i: c_int, v: i64) !void {
        if (c.sqlite3_bind_int64(self.s, i, v) != c.SQLITE_OK) return error.SqliteBind;
    }

    pub fn bindText(self: *Stmt, i: c_int, v: []const u8) !void {
        if (kr8_bind_text(self.s, i, v.ptr, @intCast(v.len)) != c.SQLITE_OK) return error.SqliteBind;
    }

    /// true = a row is ready, false = done.
    pub fn step(self: *Stmt) !bool {
        const rc = c.sqlite3_step(self.s);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return error.SqliteStep;
    }

    /// Run to completion (INSERT/UPDATE/DELETE), then reset.
    pub fn run(self: *Stmt) !void {
        defer self.reset();
        while (try self.step()) {}
    }

    pub fn int(self: *Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.s, col);
    }

    pub fn text(self: *Stmt, col: c_int) []const u8 {
        const p = c.sqlite3_column_text(self.s, col);
        if (p == null) return "";
        const n = c.sqlite3_column_bytes(self.s, col);
        return p[0..@intCast(n)];
    }
};
