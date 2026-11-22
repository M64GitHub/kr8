//! The terminal app: a 60 fps loop (qartz's shape) that turns keys into
//! pane moves and playback, and draws through view.zig.
//!
//! PLAYBACK RULES (m64, 2026-11-22):
//!   - SPACE plays / stops the file under the cursor; ENTER replays it
//!     from the start (hammer it on a one-shot).
//!   - AUTO on: the cursor landing on a WAV plays it; leaving the playing
//!     file stops it (a folder or another kind of file is silence).
//!     Keys are drained a whole frame at a time and the cursor is looked
//!     at once per frame, so holding `j` never starts fifty streams.
//!   - LOOP on: the preview loops (between the file's own `smpl` loop
//!     points when it has them).
//!
//! COPY (step 2): `c` copies the cursor file - or the pane's marked files
//! - into the TARGET pane's folder on the copy worker's thread. With two
//! panes the target is the other one; with 3-4 the first `c` asks and the
//! answer is remembered (`C` asks again). A finished batch reloads every
//! pane showing the destination and puts its cursor on the new file.
//!
//! Headless (`--dump-screen`, `--shot`) runs the same loop without a
//! terminal and without audio for `--frames` frames, fed `--keys`.

const std = @import("std");
const movy = @import("movy");
const term_mod = @import("term.zig");
const canvas_mod = @import("ui/canvas.zig");
const theme = @import("ui/theme.zig");
const motion = @import("ui/motion.zig");
const config = @import("config.zig");
const pane_mod = @import("pane.zig");
const view = @import("view.zig");
const audio = @import("../audio/audio.zig");
const peaks_mod = @import("../audio/peaks.zig");
const copier_mod = @import("copier.zig");
const library = @import("../db/library.zig");
const scanner_mod = @import("../db/scanner.zig");

const Pane = pane_mod.Pane;
const Key = movy.input.Key;
const PATH_MAX = pane_mod.PATH_MAX;

const FRAME_NS: i128 = std.time.ns_per_s / 60;
const STATUS_FRAMES: u64 = 60 * 4;

pub const Options = struct {
    headless: bool = false,
    frames: u64 = 30,
    cols: usize = 120,
    rows: usize = 36,
    dump: bool = false,
    shot: ?[:0]const u8 = null,
    keys: []const u8 = "",
    no_audio: bool = false,
    volume: f32 = 1.0,
    scheme: ?[]const u8 = null,
    dirs: []const []const u8 = &.{},
};

const App = struct {
    gpa: std.mem.Allocator,
    cfg: *config.Config,
    panes: [config.MAX_PANES]Pane,
    n: usize = 1,
    focus: usize = 0,
    zoom: bool = false,
    modal: view.Modal = .none,
    fav_sel: usize = 0,
    quit: bool = false,
    frame_no: u64 = 0,
    volume: f32 = 1.0,
    headless: bool = false,
    /// list rows of the focused pane, as last drawn (PgUp/PgDn)
    page_rows: usize = 15,
    /// something on screen changed: draw this frame (idle frames draw
    /// nothing - a browser that sits open on a gig laptop must not burn CPU)
    dirty: bool = true,
    /// keep drawing every frame until this frame (theme crossfade)
    anim_until: u64 = 0,

    status_buf: [160]u8 = undefined,
    status_len: usize = 0,
    status_at: u64 = 0,

    // what is playing (dir and name are slices of play_buf)
    playing: bool = false,
    play_buf: [PATH_MAX + 1]u8 = undefined,
    play_len: usize = 0,
    play_frames: u64 = 0,
    play_rate: u32 = 0,

    /// the cursor file as of the last frame (AUTO compares against it)
    last_cursor: u64 = 0,

    peaks: *peaks_mod.Cache,
    peaks_view: *peaks_mod.Peaks,
    peaks_ok: bool = false,

    copier: *copier_mod.Copier,
    seen_batch: u32 = 0,
    seen_done: u32 = 0,
    /// the remembered copy target (3-4 panes), a pane index
    target: ?usize = null,
    target_sel: usize = 0,
    /// the target picker was opened by `c`: copy once a pane is picked
    copy_after_pick: bool = false,

    help_scroll: usize = 0,

    // ---- the library (step 3)
    lib: ?*library.Library = null,
    scanner: ?*scanner_mod.Scanner = null,
    seen_commits: u32 = 0,
    scan_reported: bool = false,
    armed_id: ?i64 = null,
    armed_buf: [library.TAG_MAX]u8 = undefined,
    armed_len: usize = 0,
    // the tag picker
    tag_rows: []library.TagRow = &.{},
    tag_have: std.ArrayList(u32) = .empty,
    tag_shown: std.ArrayList(usize) = .empty,
    tag_targets: std.ArrayList(i64) = .empty,
    tag_query: [library.TAG_MAX]u8 = undefined,
    tag_query_len: usize = 0,
    tag_new: [library.TAG_MAX]u8 = undefined,
    tag_new_len: usize = 0,
    tag_sel: usize = 0,
    tag_title: [160]u8 = undefined,
    tag_title_len: usize = 0,
    // the find prompt: live match count, or what is wrong with the query
    find_count: i64 = -1,
    find_msg: []const u8 = "",
    // the export confirmation
    export_n: usize = 0,
    export_to: usize = 0,
    // the note prompt
    note_sound: i64 = 0,
    note_title: [160]u8 = undefined,
    note_title_len: usize = 0,
    /// the new-folder / note prompt
    input_buf: [256]u8 = undefined,
    input_len: usize = 0,
    cols: usize = 0,
    rows: usize = 0,

    home_buf: [PATH_MAX]u8 = undefined,
    home_len: usize = 0,

    fn pane(self: *App) *Pane {
        return &self.panes[self.focus];
    }

    fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status_buf, fmt, args) catch blk: {
            break :blk self.status_buf[0..];
        };
        self.status_len = s.len;
        self.status_at = self.frame_no;
    }

    fn status(self: *const App) ?[]const u8 {
        if (self.status_len == 0 or self.frame_no -| self.status_at > STATUS_FRAMES) return null;
        return self.status_buf[0..self.status_len];
    }

    fn statusFade(self: *const App) f32 {
        const age = self.frame_no -| self.status_at;
        const hold = STATUS_FRAMES / 2;
        if (age < hold) return 0;
        return @as(f32, @floatFromInt(age - hold)) / @as(f32, @floatFromInt(STATUS_FRAMES - hold));
    }

    /// `x` toggles this tag from now on (remembered in the config).
    fn arm(self: *App, tid: i64) void {
        const lib = self.lib orelse return;
        const name = lib.tagName(tid, &self.armed_buf);
        if (name.len == 0) return;
        self.armed_len = name.len;
        self.armed_id = tid;
        if (self.cfg.armed == null or !std.mem.eql(u8, self.cfg.armed.?, name)) self.cfg.setArmed(name);
    }

    fn playPath(self: *const App) []const u8 {
        return self.play_buf[0..self.play_len];
    }

    fn isPlayingEntry(self: *const App, p: *const Pane, e: *const pane_mod.Entry) bool {
        if (!self.playing) return false;
        var buf: [PATH_MAX + 1]u8 = undefined;
        const path = p.pathOf(e, &buf) orelse return false;
        return std.mem.eql(u8, path, self.playPath());
    }

    fn deinit(self: *App) void {
        for (self.panes[0..self.n]) |*p| p.deinit();
        library.Library.freeTags(self.gpa, self.tag_rows);
        self.tag_rows = &.{};
        self.tag_have.deinit(self.gpa);
        self.tag_shown.deinit(self.gpa);
        self.tag_targets.deinit(self.gpa);
    }
};

pub fn run(gpa: std.mem.Allocator, opts: Options) !u8 {
    var cfg = config.load(gpa);
    defer cfg.deinit();
    const want = opts.scheme orelse cfg.scheme orelse "DUET";
    theme.apply(theme.schemeByName(want) orelse 0);

    if (!opts.headless and !opts.no_audio) _ = audio.init();
    defer audio.deinit();

    const peaks = try peaks_mod.Cache.init(gpa, opts.headless);
    defer peaks.deinit();
    const peaks_view = try gpa.create(peaks_mod.Peaks);
    defer gpa.destroy(peaks_view);
    const copier = try copier_mod.Copier.init(gpa);
    defer copier.deinit();

    var app: App = .{
        .gpa = gpa,
        .cfg = &cfg,
        .panes = undefined,
        .peaks = peaks,
        .peaks_view = peaks_view,
        .copier = copier,
        .headless = opts.headless,
    };
    for (&app.panes) |*p| p.* = .{ .gpa = gpa };
    if (std.posix.getenv("HOME")) |h| {
        const n = @min(h.len, app.home_buf.len);
        @memcpy(app.home_buf[0..n], h[0..n]);
        app.home_len = n;
    }
    // the library: open it, scan the roots in the background
    var db_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const db_path = library.dbPath(&db_path_buf);
    if (db_path) |dp| app.lib = library.Library.open(gpa, dp) catch null;
    defer if (app.lib) |l| l.close();
    if (app.lib) |l| {
        if (l.roots.items.len > 0) {
            app.scanner = scanner_mod.Scanner.start(gpa, db_path.?) catch null;
            if (opts.headless) if (app.scanner) |sc| sc.join(); // dumps are deterministic
        }
        if (cfg.armed) |name| if (l.tagId(name, false) catch null) |tid| app.arm(tid);
    }
    defer if (app.scanner) |sc| sc.deinit();
    openStartPanes(&app, opts);
    if (cfg.target > 0 and cfg.target <= app.n) app.target = cfg.target - 1;
    defer app.deinit();
    defer saveSession(&app);
    app.last_cursor = cursorKey(&app);

    var term: ?term_mod.TermFrontend = null;
    if (!opts.headless) term = term_mod.TermFrontend.init(gpa) catch |e| switch (e) {
        error.TermTooSmall => return 1,
        else => return e,
    };
    defer if (term) |*t| t.deinit(gpa);

    var cols: usize = if (term) |t| t.cols else opts.cols;
    var rows: usize = if (term) |t| t.rows else opts.rows;
    var frame = try movy.Frame.init(gpa, @intCast(cols), @intCast(rows * 2));
    defer frame.deinit();
    frame.setVignette(0);
    var canvas = try canvas_mod.TextCanvas.init(gpa, cols, rows);
    defer canvas.deinit();

    motion.settled = opts.headless;
    app.volume = opts.volume;
    audio.setVolume(app.volume);
    if (!audio.enabled and !opts.headless) app.setStatus("no audio device - browsing only", .{});

    // the pixel layer is a plain ground today: composite it once (and on a
    // resize), not 60 times a second
    var pix_dirty = true;
    var next_deadline: i128 = std.time.nanoTimestamp();
    while (!app.quit) {
        next_deadline += FRAME_NS;

        if (term) |*t| {
            t.pump(app.frame_no);
            while (try t.next()) |ev| switch (ev) {
                .key => |k| onKey(&app, k),
                .quit => app.quit = true,
                .resize => |sz| {
                    app.dirty = true;
                    pix_dirty = true;
                    const nframe = try movy.Frame.init(gpa, @intCast(sz.cols), @intCast(sz.rows * 2));
                    errdefer nframe.deinit();
                    nframe.setVignette(0);
                    var ncanvas = try canvas_mod.TextCanvas.init(gpa, sz.cols, sz.rows);
                    errdefer ncanvas.deinit();
                    try t.applyResize(gpa, sz.cols, sz.rows);
                    frame.deinit();
                    canvas.deinit();
                    frame = nframe;
                    canvas = ncanvas;
                    cols = sz.cols;
                    rows = sz.rows;
                },
            };
        }
        scriptedKeys(&app, opts.keys);
        if (opts.headless) app.copier.waitIdle();
        afterKeys(&app);
        theme.tick(app.frame_no);

        app.cols = cols;
        app.rows = rows;
        const lay = view.layout(cols, rows, app.n, app.focus, app.zoom);
        app.page_rows = lay.panes[app.focus].h -| 3;

        if (app.status() != null or app.frame_no < app.anim_until or app.frame_no % 60 == 0) app.dirty = true;
        if (app.dirty or term == null) {
            app.dirty = false;
            const ctx = viewCtx(&app, &lay);
            if (pix_dirty) {
                frame.beginFrame();
                view.drawPixels(frame, &ctx);
                frame.composite();
                pix_dirty = false;
            }
            canvas.clear();
            view.drawText(&canvas, &ctx);
            if (term) |*t| try t.present(gpa, &canvas, frame, {});
        }

        if (term == null and app.frame_no + 1 >= opts.frames) {
            if (opts.dump) {
                const txt = try canvas.dumpAlloc(gpa);
                defer gpa.free(txt);
                std.fs.File.stdout().writeAll(txt) catch {};
            }
            if (opts.shot) |path| try frame.savePng(gpa, path, 4);
            break;
        }

        app.frame_no += 1;
        if (!opts.headless) {
            const now = std.time.nanoTimestamp();
            if (now < next_deadline) {
                std.Thread.sleep(@intCast(next_deadline - now));
            } else next_deadline = now;
        }
    }
    audio.stop();
    return 0;
}

fn viewCtx(app: *App, lay: *const view.Layout) view.Ctx {
    return .{
        .lay = lay,
        .panes = app.panes[0..app.n],
        .focus = app.focus,
        .zoom = app.zoom,
        .auto = app.cfg.auto,
        .loop = app.cfg.loop,
        .audio_ok = audio.enabled or app.headless,
        .volume = app.volume,
        .status = app.status(),
        .status_fade = app.statusFade(),
        .play = .{
            .active = app.playing,
            .path = app.playPath(),
            .pos = audio.cursor(),
            .frames = app.play_frames,
            .rate = app.play_rate,
        },
        .peaks = if (app.peaks_ok) app.peaks_view else null,
        .modal = app.modal,
        .fav_sel = app.fav_sel,
        .target = effectiveTarget(app),
        .target_sel = app.target_sel,
        .help_scroll = app.help_scroll,
        .input = app.input_buf[0..app.input_len],
        .lib = app.lib,
        .armed = app.armed_buf[0..app.armed_len],
        .scan = if (app.scanner) |sc| (if (sc.prog.running.load(.seq_cst)) view.ScanView{
            .done = sc.prog.done.load(.seq_cst),
            .total = sc.prog.total.load(.seq_cst),
        } else null) else null,
        .tags = .{
            .query = app.tag_query[0..app.tag_query_len],
            .rows = app.tag_rows,
            .shown = app.tag_shown.items,
            .have = app.tag_have.items,
            .targets = app.tag_targets.items.len,
            .sel = app.tag_sel,
            .title = app.tag_title[0..app.tag_title_len],
            .new_name = app.tag_new[0..app.tag_new_len],
        },
        .note_title = app.note_title[0..app.note_title_len],
        .find_count = app.find_count,
        .find_msg = app.find_msg,
        .export_n = app.export_n,
        .export_to = app.export_to,
        .cfg = app.cfg,
        .home = app.home_buf[0..app.home_len],
    };
}

/// A PLACE is what a pane shows, as one string: a folder, or `?query`
/// for a search pane (the config's panes and favorites hold places).
fn placeOf(p: *const Pane, buf: []u8) []const u8 {
    if (p.isQuery()) return std.fmt.bufPrint(buf, "?{s}", .{p.query()}) catch "";
    return p.dir();
}

fn openPlace(app: *App, p: *Pane, place: []const u8) !void {
    if (place.len > 0 and place[0] == '?') return runQuery(app, p, place[1..]);
    var buf: [PATH_MAX]u8 = undefined;
    const n = @min(place.len, buf.len);
    @memcpy(buf[0..n], place[0..n]); // `place` may live in the pane itself
    try p.open(buf[0..n], null);
}

fn runQuery(app: *App, p: *Pane, q: []const u8) !void {
    const lib = app.lib orelse return error.NoLibrary;
    var qb: [pane_mod.QUERY_MAX]u8 = undefined;
    const n = @min(q.len, qb.len);
    @memcpy(qb[0..n], q[0..n]); // `q` may be the pane's own query
    var found = try lib.find(app.gpa, qb[0..n]);
    defer found.deinit(app.gpa);
    try p.showResults(qb[0..n], @ptrCast(found.paths), found.truncated);
}

fn openStartPanes(app: *App, opts: Options) void {
    var opened: usize = 0;
    if (opts.dirs.len > 0) {
        for (opts.dirs) |d| {
            if (opened >= config.MAX_PANES) break;
            app.panes[opened].open(d, null) catch |e| {
                app.setStatus("can't open {s}: {s}", .{ d, @errorName(e) });
                continue;
            };
            opened += 1;
        }
    } else {
        for (app.cfg.panes) |maybe| {
            const d = maybe orelse continue;
            if (opened >= config.MAX_PANES) break;
            openPlace(app, &app.panes[opened], d) catch continue;
            opened += 1;
        }
        if (opened > 0) app.focus = @min(app.cfg.focus, opened - 1);
    }
    if (opened == 0) {
        app.panes[0].open(".", null) catch {
            app.panes[0].open("/", null) catch {};
        };
        opened = 1;
    }
    app.n = opened;
}

fn saveSession(app: *App) void {
    for (0..config.MAX_PANES) |i| {
        var pb: [PATH_MAX + 8]u8 = undefined;
        app.cfg.setPane(i, if (i < app.n) placeOf(&app.panes[i], &pb) else null);
    }
    app.cfg.focus = @intCast(app.focus);
    app.cfg.target = if (app.target) |t| @intCast(t + 1) else 0;
    app.cfg.save();
}

// ------------------------------------------------------------ per frame

fn afterKeys(app: *App) void {
    copyNews(app);
    libNews(app);
    audio.tick();
    // a non-looping preview ran out
    if (app.playing and !audio.isPlaying()) {
        app.playing = false;
        app.dirty = true;
    }
    // the playhead moves: 30 fps is smooth for it, and halves the terminal's work
    if (app.playing and app.frame_no % 2 == 0) app.dirty = true;

    // AUTO: the cursor moved to another file since the last frame
    const key = cursorKey(app);
    if (key != app.last_cursor) {
        app.last_cursor = key;
        if (app.cfg.auto and app.modal == .none) {
            const p = app.pane();
            if (p.current()) |e| {
                if (e.kind == .audio) {
                    if (!app.isPlayingEntry(p, e)) playEntry(app, p, e);
                } else stop(app);
            } else stop(app);
        }
    }

    // the waveform of the cursor file
    const had_peaks = app.peaks_ok;
    defer if (app.peaks_ok != had_peaks) {
        app.dirty = true;
    };
    app.peaks_ok = false;
    const p = app.pane();
    if (p.current()) |e| if (e.kind == .audio) {
        var buf: [PATH_MAX + 1]u8 = undefined;
        if (p.pathOf(e, &buf)) |path| {
            if (app.peaks.get(path, app.peaks_view)) {
                app.peaks_ok = true;
            } else {
                app.peaks.request(path);
                if (app.peaks.get(path, app.peaks_view)) app.peaks_ok = true; // sync mode
            }
        }
    };
}

/// Identity of the focused pane's cursor entry (pane, folder, name).
fn cursorKey(app: *App) u64 {
    const p = app.pane();
    var h = std.hash.Wyhash.init(app.focus);
    h.update(p.dir());
    if (p.current()) |e| {
        h.update("/");
        h.update(e.name);
    }
    return h.final();
}

fn playEntry(app: *App, p: *Pane, e: *pane_mod.Entry) void {
    var buf: [PATH_MAX + 1]u8 = undefined;
    const path = p.pathOf(e, &buf) orelse return;
    if (!audio.enabled) {
        if (!app.headless) app.setStatus("no audio device", .{});
        return;
    }
    const inf = p.info(e);
    var span: audio.Loop = .{};
    if (inf) |i| if (i.has_loop) {
        span = .{ .start = i.loop_start, .end = i.loop_end };
    };
    if (!audio.play(path, app.cfg.loop, span)) {
        app.playing = false;
        app.setStatus("can't play {s}", .{e.name});
        return;
    }
    @memcpy(app.play_buf[0..path.len], path);
    app.play_len = path.len;
    app.play_frames = if (inf) |i| i.frames else 0;
    app.play_rate = if (inf) |i| i.rate else 0;
    if (app.play_frames == 0) app.play_frames = audio.length();
    app.playing = true;
}

fn stop(app: *App) void {
    if (!app.playing) return;
    audio.stop();
    app.playing = false;
}

// ------------------------------------------------------------ keys

fn isChar(k: Key, ch: u8) bool {
    return k.type == .Char and k.sequence.len == 1 and k.sequence[0] == ch;
}

fn onKey(app: *App, k: Key) void {
    app.dirty = true;
    if (k.type == .CtrlC or (k.type == .CtrlChar and std.mem.eql(u8, k.sequence, "c"))) {
        app.quit = true;
        return;
    }
    if (k.event == .Release) return;
    switch (app.modal) {
        .help => return helpKey(app, k),
        .favs => return favsKey(app, k),
        .target => return targetKey(app, k),
        .mkdir => return mkdirKey(app, k),
        .tags => return tagsKey(app, k),
        .find => return findKey(app, k),
        .export_confirm => return exportKey(app, k),
        .note => return noteKey(app, k),
        .none => {},
    }
    if (app.pane().typing) return filterKey(app, k);
    mainKey(app, k);
}

fn filterKey(app: *App, k: Key) void {
    const p = app.pane();
    switch (k.type) {
        .Escape => p.filterClear(),
        .Enter => p.typing = false,
        .Backspace => if (p.filter_len == 0) {
            p.typing = false;
        } else p.filterBackspace(),
        .Up => p.move(-1),
        .Down => p.move(1),
        .PageUp => p.move(-pageRows(app)),
        .PageDown => p.move(pageRows(app)),
        .Tab, .ShiftTab => {
            p.typing = false;
            mainKey(app, k);
        },
        .Char => for (k.sequence) |b| {
            if (b >= 0x20) p.filterType(b);
        },
        else => {},
    }
}

fn pageRows(app: *App) isize {
    return @intCast(@max(app.page_rows, 1));
}

fn mainKey(app: *App, k: Key) void {
    const p = app.pane();
    switch (k.type) {
        .Up => p.move(-1),
        .Down => p.move(1),
        .PageUp => p.move(-pageRows(app)),
        .PageDown => p.move(pageRows(app)),
        .Home => p.home(),
        .End => p.end(),
        .Enter, .Right => activate(app),
        .Backspace, .Left => goUp(app),
        .Tab => cycleFocus(app, true),
        .ShiftTab => cycleFocus(app, false),
        .F7 => openMkdir(app),
        .Escape => {
            if (p.filter_len > 0) p.filterClear() else stop(app);
        },
        .CtrlChar => {
            if (std.mem.eql(u8, k.sequence, "d")) p.move(@divTrunc(pageRows(app), 2));
            if (std.mem.eql(u8, k.sequence, "u")) p.move(-@divTrunc(pageRows(app), 2));
        },
        .Char => {
            if (k.sequence.len != 1) return;
            switch (k.sequence[0]) {
                'j' => p.move(1),
                'k' => p.move(-1),
                'g' => p.home(),
                'G' => p.end(),
                'l' => activate(app),
                'h' => goUp(app),
                ' ' => togglePlay(app),
                'a' => {
                    app.cfg.auto = !app.cfg.auto;
                    app.cfg.save();
                    if (app.cfg.auto) {
                        app.setStatus("AUTO on - the cursor plays what it lands on", .{});
                    } else app.setStatus("AUTO off - space plays", .{});
                },
                'L' => {
                    app.cfg.loop = !app.cfg.loop;
                    app.cfg.save();
                    audio.setLoop(app.cfg.loop);
                    app.setStatus("LOOP {s}", .{if (app.cfg.loop) "on" else "off"});
                },
                '/' => p.typing = true,
                '1'...'8' => jumpFavorite(app, k.sequence[0] - '1'),
                'F' => {
                    app.modal = .favs;
                    app.fav_sel = 0;
                },
                'n' => newPane(app),
                'q' => closePane(app),
                'Q' => app.quit = true,
                'z' => if (app.n > 1) {
                    app.zoom = !app.zoom;
                },
                'r' => if (p.isQuery()) {
                    var qb: [pane_mod.QUERY_MAX]u8 = undefined;
                    const q = qb[0..p.query_len];
                    @memcpy(q, p.query());
                    if (runQuery(app, p, q)) {
                        app.setStatus("search again: {d} files", .{p.rows()});
                    } else |e| app.setStatus("search failed: {s}", .{@errorName(e)});
                } else if (p.reload()) {
                    app.setStatus("reloaded", .{});
                } else |e| app.setStatus("reload failed: {s}", .{@errorName(e)}),
                'T' => cycleTheme(app),
                '?' => {
                    app.modal = .help;
                    app.help_scroll = 0;
                },
                'c' => copyKey(app),
                'M' => openMkdir(app),
                't' => openTags(app),
                'f' => openFind(app),
                'E' => openExport(app),
                'o' => openFileFolder(app),
                'x' => armedKey(app),
                'e' => openNote(app),
                'C' => openTargetPick(app, false),
                'v' => if (!p.toggleMark()) app.setStatus("v marks files - not folders", .{}),
                'V' => {
                    const n = p.markAll();
                    if (n > 0) {
                        app.setStatus("{d} files marked - c copies them, V again clears", .{n});
                    } else app.setStatus("marks cleared", .{});
                },
                '-' => setVolume(app, app.volume - 0.1),
                '+', '=' => setVolume(app, app.volume + 0.1),
                else => {},
            }
        },
        else => {},
    }
}

fn setVolume(app: *App, v: f32) void {
    app.volume = std.math.clamp(@round(v * 10) / 10, 0.0, 1.0);
    audio.setVolume(app.volume);
    app.setStatus("preview volume {d}%", .{@as(u32, @intFromFloat(app.volume * 100 + 0.5))});
}

fn togglePlay(app: *App) void {
    const p = app.pane();
    const e = p.current() orelse return;
    if (e.kind != .audio) {
        stop(app);
        return;
    }
    if (app.isPlayingEntry(p, e)) stop(app) else playEntry(app, p, e);
}

/// ENTER: into a folder, up from `..`, replay a WAV from the start.
fn activate(app: *App) void {
    const p = app.pane();
    const e = p.current() orelse return;
    switch (e.kind) {
        .parent => goUp(app),
        .dir => {
            var buf: [PATH_MAX + 1]u8 = undefined;
            const path = p.pathOf(e, &buf) orelse return;
            var copy: [PATH_MAX + 1]u8 = undefined;
            @memcpy(copy[0..path.len], path);
            p.open(copy[0..path.len], null) catch |err| app.setStatus("can't open {s}: {s}", .{ e.name, @errorName(err) });
        },
        .audio => playEntry(app, p, e),
        .other => app.setStatus("{s}: not a WAV", .{e.name}),
    }
}

fn goUp(app: *App) void {
    const p = app.pane();
    if (p.isQuery()) {
        // the folder it came from; after a restart that is unknown: the
        // first library root, else home
        const back = if (p.back_len > 0)
            p.backDir()
        else if (app.lib != null and app.lib.?.roots.items.len > 0)
            app.lib.?.roots.items[0].path
        else
            app.home_buf[0..app.home_len];
        openPlace(app, p, back) catch |err| app.setStatus("can't open {s}: {s}", .{ back, @errorName(err) });
        return;
    }
    const d = p.dir();
    if (std.mem.eql(u8, d, "/")) return;
    var name_buf: [256]u8 = undefined;
    const base = std.fs.path.basename(d);
    const n = @min(base.len, name_buf.len);
    @memcpy(name_buf[0..n], base[0..n]);
    var parent_buf: [PATH_MAX]u8 = undefined;
    const parent = std.fs.path.dirname(d) orelse "/";
    @memcpy(parent_buf[0..parent.len], parent);
    p.open(parent_buf[0..parent.len], name_buf[0..n]) catch |err| app.setStatus("can't open {s}: {s}", .{ parent, @errorName(err) });
}

fn cycleFocus(app: *App, fwd: bool) void {
    if (app.n < 2) return;
    app.pane().typing = false;
    app.focus = if (fwd) (app.focus + 1) % app.n else (app.focus + app.n - 1) % app.n;
    // a focus change is not a cursor move: AUTO must not fire on it
    app.last_cursor = cursorKey(app);
}

fn newPane(app: *App) void {
    if (app.n >= config.MAX_PANES) {
        app.setStatus("4 panes is the most", .{});
        return;
    }
    const src = app.pane();
    if (src.isQuery()) {
        var qb: [PATH_MAX + 8]u8 = undefined;
        const place = placeOf(src, &qb);
        const np = &app.panes[app.n];
        np.* = .{ .gpa = app.gpa };
        openPlace(app, np, place) catch |err| return app.setStatus("new pane failed: {s}", .{@errorName(err)});
        app.focus = app.n;
        app.n += 1;
        app.zoom = false;
        app.last_cursor = cursorKey(app);
        return;
    }
    var dir_buf: [PATH_MAX]u8 = undefined;
    const d = src.dir();
    @memcpy(dir_buf[0..d.len], d);
    var name_buf: [256]u8 = undefined;
    var name: ?[]const u8 = null;
    if (src.current()) |e| {
        const k = @min(e.name.len, name_buf.len);
        @memcpy(name_buf[0..k], e.name[0..k]);
        name = name_buf[0..k];
    }
    const np = &app.panes[app.n];
    np.* = .{ .gpa = app.gpa };
    np.open(dir_buf[0..d.len], name) catch |err| {
        app.setStatus("new pane failed: {s}", .{@errorName(err)});
        return;
    };
    app.focus = app.n;
    app.n += 1;
    app.zoom = false;
    app.last_cursor = cursorKey(app);
}

fn closePane(app: *App) void {
    if (app.n <= 1) {
        app.quit = true;
        return;
    }
    app.panes[app.focus].deinit();
    var i = app.focus;
    while (i + 1 < app.n) : (i += 1) app.panes[i] = app.panes[i + 1];
    app.n -= 1;
    app.panes[app.n] = .{ .gpa = app.gpa };
    if (app.target) |t| {
        if (t == app.focus) app.target = null else if (t > app.focus) app.target = t - 1;
    }
    if (app.focus >= app.n) app.focus = app.n - 1;
    if (app.n == 1) app.zoom = false;
    app.last_cursor = cursorKey(app);
}

fn jumpFavorite(app: *App, slot: usize) void {
    const fav = app.cfg.favorite(slot) orelse {
        app.setStatus("favorite {d} is empty - F, then s, stores this folder there", .{slot + 1});
        return;
    };
    openPlace(app, app.pane(), fav) catch |err| {
        app.setStatus("favorite {d}: can't open ({s})", .{ slot + 1, @errorName(err) });
        return;
    };
    var pb: [PATH_MAX + 8]u8 = undefined;
    app.setStatus("{d}: {s}", .{ slot + 1, view.tildePath(fav, app.home_buf[0..app.home_len], &pb) });
}

fn favsKey(app: *App, k: Key) void {
    switch (k.type) {
        .Escape => app.modal = .none,
        .Up => app.fav_sel = (app.fav_sel + config.N_FAVS - 1) % config.N_FAVS,
        .Down => app.fav_sel = (app.fav_sel + 1) % config.N_FAVS,
        .Enter => {
            app.modal = .none;
            jumpFavorite(app, app.fav_sel);
        },
        .Char => {
            if (k.sequence.len != 1) return;
            switch (k.sequence[0]) {
                'j' => app.fav_sel = (app.fav_sel + 1) % config.N_FAVS,
                'k' => app.fav_sel = (app.fav_sel + config.N_FAVS - 1) % config.N_FAVS,
                '1'...'8' => {
                    app.modal = .none;
                    jumpFavorite(app, k.sequence[0] - '1');
                },
                's' => {
                    var pb: [PATH_MAX + 8]u8 = undefined;
                    app.cfg.setFavorite(app.fav_sel, placeOf(app.pane(), &pb));
                    app.setStatus("favorite {d} = {s}", .{ app.fav_sel + 1, if (app.pane().isQuery()) "this search" else "this folder" });
                },
                'x', 'd' => {
                    app.cfg.setFavorite(app.fav_sel, null);
                    app.setStatus("favorite {d} cleared", .{app.fav_sel + 1});
                },
                'F', 'q' => app.modal = .none,
                else => {},
            }
        },
        else => {},
    }
}

// ------------------------------------------------------------ copy

/// The pane `c` copies into: the other one of two, else the remembered
/// one (never the focused pane itself).
fn effectiveTarget(app: *const App) ?usize {
    if (app.n < 2) return null;
    if (app.n == 2) return 1 - app.focus;
    if (app.target) |t| if (t < app.n and t != app.focus) return t;
    return null;
}

fn copyKey(app: *App) void {
    if (app.n < 2) {
        app.setStatus("copy needs a second pane: n opens one - then go to the folder to copy into", .{});
        return;
    }
    const t = effectiveTarget(app) orelse return openTargetPick(app, true);
    copyTo(app, t);
}

fn copyTo(app: *App, t: usize) void {
    const src = app.pane();
    const dst = &app.panes[t];
    if (dst.isQuery()) {
        app.setStatus("pane {d} is a search - copies go into a folder pane", .{t + 1});
        return;
    }
    if (std.mem.eql(u8, src.dir(), dst.dir())) {
        app.setStatus("pane {d} shows this same folder - go to the folder to copy into", .{t + 1});
        return;
    }
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |x| app.gpa.free(x);
        paths.deinit(app.gpa);
    }
    const marked = src.markedCount() > 0;
    var buf: [PATH_MAX + 1]u8 = undefined;
    if (marked) {
        for (src.entries.items) |*e| if (e.marked) {
            const path = src.pathOf(e, &buf) orelse continue;
            const owned = app.gpa.dupe(u8, path) catch return;
            paths.append(app.gpa, owned) catch {
                app.gpa.free(owned);
                return;
            };
        };
    } else {
        const e = src.current() orelse return;
        if (!e.isFile()) {
            app.setStatus("c copies files - for a whole folder open it and V marks everything", .{});
            return;
        }
        const path = src.pathOf(e, &buf) orelse return;
        const owned = app.gpa.dupe(u8, path) catch return;
        paths.append(app.gpa, owned) catch {
            app.gpa.free(owned);
            return;
        };
    }
    if (paths.items.len == 0) return;
    const slices = app.gpa.alloc([]const u8, paths.items.len) catch return;
    defer app.gpa.free(slices);
    for (paths.items, 0..) |x, i| slices[i] = x;
    app.copier.submit(slices, dst.dir()) catch |e| {
        app.setStatus("copy failed: {s}", .{@errorName(e)});
        return;
    };
    var pb: [PATH_MAX + 8]u8 = undefined;
    const where = view.tildePath(dst.dir(), app.home_buf[0..app.home_len], &pb);
    if (marked) {
        app.setStatus("copying {d} files to {d}: {s}", .{ paths.items.len, t + 1, where });
        src.clearMarks();
    } else {
        app.setStatus("copying {s} to {d}: {s}", .{ std.fs.path.basename(paths.items[0]), t + 1, where });
        src.move(1); // copy, move on (AUTO plays the next one)
    }
}

/// Once a frame: progress while the worker copies, and the end of a batch.
fn copyNews(app: *App) void {
    const snap = app.copier.snapshot();
    var pb: [PATH_MAX + 8]u8 = undefined;
    const where = view.tildePath(snap.dstDir(), app.home_buf[0..app.home_len], &pb);
    if (snap.busy and snap.total > 1 and snap.done + snap.failed != app.seen_done) {
        app.seen_done = snap.done + snap.failed;
        app.setStatus("copying {d}/{d} into {s}", .{ app.seen_done, snap.total, where });
        app.dirty = true;
    }
    if (snap.batch == app.seen_batch) return;
    app.seen_batch = snap.batch;
    app.seen_done = 0;
    app.dirty = true;
    // every pane on the destination: reload, cursor on the new file
    for (app.panes[0..app.n], 0..) |*p, i| {
        if (!std.mem.eql(u8, p.dir(), snap.dstDir())) continue;
        p.reload() catch continue;
        if (i != app.focus and snap.done > 0) _ = p.select(snap.lastName());
    }
    if (snap.failed > 0) {
        const err = if (snap.err) |e| @errorName(e) else "error";
        app.setStatus("copied {d}, {d} FAILED - first: {s} ({s})", .{ snap.done, snap.failed, snap.errName(), err });
    } else if (snap.done == 1) {
        app.setStatus("copied {s} into {s}", .{ snap.lastName(), where });
    } else {
        app.setStatus("copied {d} files into {s}", .{ snap.done, where });
    }
}

fn openTargetPick(app: *App, copy_after: bool) void {
    if (app.n < 3) {
        if (app.n == 2) {
            app.setStatus("with 2 panes the target is always the other one", .{});
        } else app.setStatus("copy needs a second pane: n opens one", .{});
        return;
    }
    app.copy_after_pick = copy_after;
    app.modal = .target;
    app.target_sel = effectiveTarget(app) orelse nextOther(app, app.focus, true);
}

/// The next pane index after `from` that is not the focused one.
fn nextOther(app: *const App, from: usize, fwd: bool) usize {
    var i = from;
    var tries: usize = 0;
    while (tries < app.n) : (tries += 1) {
        i = if (fwd) (i + 1) % app.n else (i + app.n - 1) % app.n;
        if (i != app.focus) return i;
    }
    return from;
}

fn pickTarget(app: *App, t: usize) void {
    if (t >= app.n or t == app.focus) return;
    app.target = t;
    app.modal = .none;
    app.setStatus("copy target: pane {d}", .{t + 1});
    if (app.copy_after_pick) copyTo(app, t);
    app.copy_after_pick = false;
}

fn targetKey(app: *App, k: Key) void {
    switch (k.type) {
        .Escape => {
            app.modal = .none;
            app.copy_after_pick = false;
        },
        .Up => app.target_sel = nextOther(app, app.target_sel, false),
        .Down, .Tab => app.target_sel = nextOther(app, app.target_sel, true),
        .Enter => pickTarget(app, app.target_sel),
        .Char => {
            if (k.sequence.len != 1) return;
            switch (k.sequence[0]) {
                'j' => app.target_sel = nextOther(app, app.target_sel, true),
                'k' => app.target_sel = nextOther(app, app.target_sel, false),
                '1'...'4' => pickTarget(app, k.sequence[0] - '1'),
                'q' => {
                    app.modal = .none;
                    app.copy_after_pick = false;
                },
                else => {},
            }
        },
        else => {},
    }
}

// ------------------------------------------------------------ new folder

fn openMkdir(app: *App) void {
    if (app.pane().isQuery()) return app.setStatus("a search pane is no folder - backspace goes back to one", .{});
    app.input_len = 0;
    app.modal = .mkdir;
}

fn mkdirKey(app: *App, k: Key) void {
    switch (k.type) {
        .Escape => app.modal = .none,
        .Enter => makeFolder(app),
        else => editText(&app.input_buf, &app.input_len, k),
    }
}

/// Typing into a one-line field: characters append, backspace drops one
/// whole UTF-8 character.
fn editText(buf: []u8, len: *usize, k: Key) void {
    switch (k.type) {
        .Backspace => while (len.* > 0) {
            len.* -= 1;
            if (buf[len.*] & 0xC0 != 0x80) break;
        },
        .Char => for (k.sequence) |b| {
            if (b < 0x20 or len.* >= buf.len) continue;
            buf[len.*] = b;
            len.* += 1;
        },
        else => {},
    }
}

fn makeFolder(app: *App) void {
    const name = std.mem.trim(u8, app.input_buf[0..app.input_len], " ");
    if (name.len == 0) {
        app.modal = .none;
        return;
    }
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        app.setStatus("a folder name can't contain /", .{});
        return;
    }
    if (name[0] == '.') {
        app.setStatus("names starting with . are hidden in kr8 - pick another", .{});
        return;
    }
    const p = app.pane();
    var d = std.fs.openDirAbsolute(p.dir(), .{}) catch |e| {
        app.setStatus("can't open this folder: {s}", .{@errorName(e)});
        return;
    };
    defer d.close();
    var existed = false;
    d.makeDir(name) catch |e| switch (e) {
        error.PathAlreadyExists => existed = true,
        else => {
            app.setStatus("can't make {s}: {s}", .{ name, @errorName(e) });
            return;
        },
    };
    app.modal = .none;
    var keep: [128]u8 = undefined;
    @memcpy(keep[0..name.len], name);
    p.filterClear();
    p.reload() catch {};
    _ = p.select(keep[0..name.len]);
    if (existed) {
        app.setStatus("{s} exists already - the cursor is on it", .{keep[0..name.len]});
    } else app.setStatus("made {s}/", .{keep[0..name.len]});
}

// ------------------------------------------------------------ library

/// Once a frame: the scanner's progress shows up in the panes as it goes.
fn libNews(app: *App) void {
    const sc = app.scanner orelse return;
    const commits = sc.prog.commits.load(.seq_cst);
    if (commits != app.seen_commits) {
        app.seen_commits = commits;
        if (app.lib) |l| l.gen +%= 1;
        app.dirty = true;
    }
    const running = sc.prog.running.load(.seq_cst);
    if (running and app.frame_no % 10 == 0) app.dirty = true; // the counter
    if (!running and !app.scan_reported) {
        app.scan_reported = true;
        app.dirty = true;
        const hashed = sc.prog.hashed.load(.seq_cst);
        const failed = sc.prog.failed.load(.seq_cst);
        if (sc.err) |e| {
            app.setStatus("library scan failed: {s}", .{@errorName(e)});
        } else if (hashed > 0 or failed > 0) {
            app.setStatus("library: {d} new or changed file(s) indexed{s}", .{ hashed, if (failed > 0) ", some unreadable" else "" });
        }
    }
}

/// The audio files t / x / e act on - the pane's marks, else the cursor
/// file - as sound ids in `tag_targets` (unknown files get indexed now).
fn collectTargets(app: *App, lib: *library.Library) usize {
    app.tag_targets.clearRetainingCapacity();
    const p = app.pane();
    var buf: [PATH_MAX + 1]u8 = undefined;
    if (p.markedCount() > 0) {
        for (p.entries.items) |*e| {
            if (!e.marked or e.kind != .audio) continue;
            const path = p.pathOf(e, &buf) orelse continue;
            const sid = lib.ensureSound(path) catch continue;
            app.tag_targets.append(app.gpa, sid) catch {};
        }
    } else if (p.current()) |e| {
        if (e.kind == .audio) {
            if (p.pathOf(e, &buf)) |path| {
                if (lib.ensureSound(path)) |sid| {
                    app.tag_targets.append(app.gpa, sid) catch {};
                } else |err| app.setStatus("can't read {s}: {s}", .{ e.name, @errorName(err) });
            }
        }
    }
    return app.tag_targets.items.len;
}

fn openTags(app: *App) void {
    const lib = app.lib orelse return app.setStatus("no library - tags need ~/.config/kr8/kr8.db", .{});
    const p = app.pane();
    const n = collectTargets(app, lib);
    if (n == 0) return app.setStatus("t tags WAV files - put the cursor on one, or mark some with v", .{});
    const title = if (p.markedCount() > 0)
        std.fmt.bufPrint(&app.tag_title, "{d} marked files", .{n}) catch ""
    else
        std.fmt.bufPrint(&app.tag_title, "{s}", .{p.current().?.name}) catch "";
    app.tag_title_len = title.len;
    app.tag_query_len = 0;
    app.tag_sel = 0;
    reloadTagRows(app, lib);
    refilterTags(app);
    app.modal = .tags;
}

fn reloadTagRows(app: *App, lib: *library.Library) void {
    library.Library.freeTags(app.gpa, app.tag_rows);
    app.tag_rows = lib.listTags(app.gpa) catch &.{};
    app.tag_have.clearRetainingCapacity();
    for (app.tag_rows) |row| {
        var n: u32 = 0;
        for (app.tag_targets.items) |sid| n += @intFromBool(lib.hasTag(sid, row.id));
        app.tag_have.append(app.gpa, n) catch {};
    }
}

/// The rows the query lets through (substring, as everywhere in kr8),
/// plus a "new tag" row when the typed name is not a tag yet.
fn refilterTags(app: *App) void {
    app.tag_shown.clearRetainingCapacity();
    const q = app.tag_query[0..app.tag_query_len];
    const norm = library.Library.normTag(q, &app.tag_new);
    app.tag_new_len = norm.len;
    var exact: ?usize = null;
    for (app.tag_rows, 0..) |row, i| {
        if (norm.len > 0 and std.ascii.indexOfIgnoreCase(row.name, norm) == null) continue;
        if (norm.len > 0 and std.ascii.eqlIgnoreCase(row.name, norm)) exact = app.tag_shown.items.len;
        app.tag_shown.append(app.gpa, i) catch {};
    }
    if (norm.len > 0 and exact == null) app.tag_shown.append(app.gpa, app.tag_rows.len) catch {};
    app.tag_sel = exact orelse 0;
}

/// Toggle the selected tag on every target (all have it -> off, else on).
fn applyTag(app: *App, close: bool, toggle: bool) void {
    const lib = app.lib orelse return;
    if (app.tag_sel >= app.tag_shown.items.len) return;
    const ri = app.tag_shown.items[app.tag_sel];
    const tid: i64 = if (ri >= app.tag_rows.len) blk: {
        const name = app.tag_new[0..app.tag_new_len];
        break :blk (lib.tagId(name, true) catch null) orelse return app.setStatus("can't make tag {s}", .{name});
    } else app.tag_rows[ri].id;
    if (toggle) {
        const all = ri < app.tag_rows.len and app.tag_have.items[ri] == app.tag_targets.items.len;
        for (app.tag_targets.items) |sid| lib.setTag(sid, tid, !all) catch {};
        var nb: [library.TAG_MAX]u8 = undefined;
        app.setStatus("{s} {s} {s}", .{ if (all) "-" else "+", lib.tagName(tid, &nb), app.tag_title[0..app.tag_title_len] });
    }
    app.arm(tid);
    if (close) {
        app.modal = .none;
    } else {
        app.tag_query_len = 0;
        reloadTagRows(app, lib);
        refilterTags(app);
    }
}

fn tagsKey(app: *App, k: Key) void {
    switch (k.type) {
        .Escape => app.modal = .none,
        .Enter => applyTag(app, true, true),
        .Tab => applyTag(app, false, true), // toggle, stay for the next tag
        .ShiftTab => {
            applyTag(app, true, false); // arm only
            app.setStatus("x now toggles {s}", .{app.armed_buf[0..app.armed_len]});
        },
        .Up => app.tag_sel -|= 1,
        .Down => {
            if (app.tag_sel + 1 < app.tag_shown.items.len) app.tag_sel += 1;
        },
        .Char => {
            // a tag name is one word: a typed space becomes '-'
            const dash = Key{ .type = .Char, .sequence = "-" };
            editText(&app.tag_query, &app.tag_query_len, if (std.mem.eql(u8, k.sequence, " ")) dash else k);
            refilterTags(app);
        },
        .Backspace => {
            editText(&app.tag_query, &app.tag_query_len, k);
            refilterTags(app);
        },
        else => {},
    }
}

/// `x`: the armed tag on (or off) the file - or the marked files - and on.
fn armedKey(app: *App) void {
    const lib = app.lib orelse return app.setStatus("no library", .{});
    const tid = app.armed_id orelse {
        openTags(app);
        if (app.modal == .tags) app.setStatus("pick the tag x should toggle (enter)", .{});
        return;
    };
    const p = app.pane();
    const marked = p.markedCount() > 0;
    const n = collectTargets(app, lib);
    if (n == 0) return app.setStatus("x tags WAV files", .{});
    var all = true;
    for (app.tag_targets.items) |sid| all = all and lib.hasTag(sid, tid);
    for (app.tag_targets.items) |sid| lib.setTag(sid, tid, !all) catch {};
    const tag = app.armed_buf[0..app.armed_len];
    if (marked) {
        app.setStatus("{s} {s} on {d} marked files", .{ if (all) "-" else "+", tag, n });
    } else {
        app.setStatus("{s} {s}  {s}", .{ if (all) "-" else "+", tag, p.current().?.name });
        p.move(1); // and on to the next one (AUTO plays it)
    }
}

// ------------------------------------------------------------ find

fn openFind(app: *App) void {
    if (app.lib == null) return app.setStatus("no library - kr8 root add DIR first", .{});
    const p = app.pane();
    const q = if (p.isQuery()) p.query() else "";
    @memcpy(app.input_buf[0..q.len], q);
    app.input_len = q.len;
    updateFindCount(app);
    app.modal = .find;
}

fn updateFindCount(app: *App) void {
    const lib = app.lib orelse return;
    const q = app.input_buf[0..app.input_len];
    app.find_msg = "";
    app.find_count = lib.findCount(app.gpa, q) catch |e| blk: {
        app.find_msg = switch (e) {
            error.EmptyQuery => "",
            error.UnknownIs => "unknown is: - see the list below",
            error.BadLength => "a length is <1s, >2s or <500ms",
            else => "can't search that",
        };
        break :blk -1;
    };
}

fn findKey(app: *App, k: Key) void {
    switch (k.type) {
        .Escape => app.modal = .none,
        .Enter => {
            const q = std.mem.trim(u8, app.input_buf[0..app.input_len], " ");
            if (q.len == 0) {
                app.modal = .none;
                return;
            }
            const p = app.pane();
            runQuery(app, p, q) catch |e| return app.setStatus("search failed: {s}", .{@errorName(e)});
            app.modal = .none;
            if (p.truncated) {
                app.setStatus("{d}+ files - the first {d}; add words to narrow it", .{ p.rows(), library.FIND_LIMIT });
            } else app.setStatus("{d} files - backspace returns to the folder, o opens a file's folder", .{p.rows()});
        },
        else => {
            editText(&app.input_buf, &app.input_len, k);
            updateFindCount(app);
        },
    }
}

/// `o` in a search pane: show the cursor file in its folder.
fn openFileFolder(app: *App) void {
    const p = app.pane();
    if (!p.isQuery()) return app.setStatus("o opens a search hit's folder (f searches)", .{});
    const e = p.current() orelse return;
    var buf: [PATH_MAX + 1]u8 = undefined;
    const path = p.pathOf(e, &buf) orelse return;
    const dir = std.fs.path.dirname(path) orelse return;
    var nb: [256]u8 = undefined;
    const base = std.fs.path.basename(path);
    const n = @min(base.len, nb.len);
    @memcpy(nb[0..n], base[0..n]);
    var db: [PATH_MAX]u8 = undefined;
    @memcpy(db[0..dir.len], dir);
    p.open(db[0..dir.len], nb[0..n]) catch |err| app.setStatus("can't open {s}: {s}", .{ dir, @errorName(err) });
    app.last_cursor = cursorKey(app); // same file: AUTO keeps playing it
}

/// `E`: every file shown in this pane, copied into the target pane.
fn openExport(app: *App) void {
    if (app.n < 2) return app.setStatus("export needs a second pane: n opens one - go to the folder to fill", .{});
    const t = effectiveTarget(app) orelse return openTargetPick(app, false);
    if (app.panes[t].isQuery()) return app.setStatus("pane {d} is a search - export goes into a folder pane", .{t + 1});
    const p = app.pane();
    var n: usize = 0;
    for (p.view.items) |idx| n += @intFromBool(p.entries.items[idx].isFile());
    if (n == 0) return app.setStatus("nothing to export here", .{});
    app.export_n = n;
    app.export_to = t;
    app.modal = .export_confirm;
}

fn exportKey(app: *App, k: Key) void {
    switch (k.type) {
        .Escape => app.modal = .none,
        .Enter => {
            app.modal = .none;
            const p = app.pane();
            const dst = &app.panes[app.export_to];
            var paths: std.ArrayList([]const u8) = .empty;
            defer {
                for (paths.items) |x| app.gpa.free(x);
                paths.deinit(app.gpa);
            }
            var buf: [PATH_MAX + 1]u8 = undefined;
            for (p.view.items) |idx| {
                const e = &p.entries.items[idx];
                if (!e.isFile()) continue;
                const path = p.pathOf(e, &buf) orelse continue;
                const owned = app.gpa.dupe(u8, path) catch continue;
                paths.append(app.gpa, owned) catch app.gpa.free(owned);
            }
            app.copier.submit(paths.items, dst.dir()) catch |e| return app.setStatus("export failed: {s}", .{@errorName(e)});
            app.setStatus("exporting {d} files to pane {d}", .{ paths.items.len, app.export_to + 1 });
        },
        else => {},
    }
}

fn openNote(app: *App) void {
    const lib = app.lib orelse return app.setStatus("no library", .{});
    const p = app.pane();
    const e = p.current() orelse return;
    if (e.kind != .audio) return app.setStatus("e notes WAV files", .{});
    var buf: [PATH_MAX + 1]u8 = undefined;
    const path = p.pathOf(e, &buf) orelse return;
    const sid = lib.ensureSound(path) catch |err| return app.setStatus("can't read {s}: {s}", .{ e.name, @errorName(err) });
    app.note_sound = sid;
    const old = lib.note(sid, &app.input_buf);
    app.input_len = old.len;
    const t = std.fmt.bufPrint(&app.note_title, "{s}", .{e.name}) catch "";
    app.note_title_len = t.len;
    app.modal = .note;
}

fn noteKey(app: *App, k: Key) void {
    switch (k.type) {
        .Escape => app.modal = .none,
        .Enter => {
            app.modal = .none;
            const lib = app.lib orelse return;
            const txt = std.mem.trim(u8, app.input_buf[0..app.input_len], " ");
            lib.setNote(app.note_sound, txt) catch |e| return app.setStatus("note not saved: {s}", .{@errorName(e)});
            app.setStatus("{s}", .{if (txt.len == 0) "note deleted" else "note saved"});
        },
        else => editText(&app.input_buf, &app.input_len, k),
    }
}

fn helpKey(app: *App, k: Key) void {
    const g = view.helpGeom(app.cols, app.rows);
    const page = @max(g.body_h, 1);
    switch (k.type) {
        .Escape, .Enter => app.modal = .none,
        .Up => app.help_scroll -|= 1,
        .Down => app.help_scroll += 1,
        .PageUp => app.help_scroll -|= page,
        .PageDown => app.help_scroll += page,
        .Home => app.help_scroll = 0,
        .End => app.help_scroll = g.max_scroll,
        .CtrlChar => {
            if (std.mem.eql(u8, k.sequence, "d")) app.help_scroll += page / 2;
            if (std.mem.eql(u8, k.sequence, "u")) app.help_scroll -|= page / 2;
        },
        .Char => {
            if (k.sequence.len != 1) return;
            switch (k.sequence[0]) {
                'j' => app.help_scroll += 1,
                'k' => app.help_scroll -|= 1,
                'g' => app.help_scroll = 0,
                'G' => app.help_scroll = g.max_scroll,
                ' ' => app.help_scroll += page,
                '?', 'q' => app.modal = .none,
                else => {},
            }
        },
        else => {},
    }
    app.help_scroll = @min(app.help_scroll, g.max_scroll);
}

fn cycleTheme(app: *App) void {
    const n = theme.SCHEMES.len;
    const i = (theme.active + 1) % n;
    theme.fadeTo(i, app.frame_no);
    app.anim_until = app.frame_no + motion.frames(theme.scheme_fade_ms) + 2;
    app.cfg.setScheme(theme.SCHEMES[i].name);
    app.setStatus("{s} - {s}", .{ theme.SCHEMES[i].name, theme.SCHEMES[i].blurb });
}

// ------------------------------------------------------------ scripted

/// `--keys "10:j,12:space,20:text=kick"` - frame:key, comma-separated.
/// key: one character, a name (left right up down enter esc tab stab
/// bksp space pgup pgdn home end), or `text=abc`.
fn scriptedKeys(app: *App, script: []const u8) void {
    if (script.len == 0) return;
    var it = std.mem.splitScalar(u8, script, ',');
    while (it.next()) |item| {
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse continue;
        const at = std.fmt.parseInt(u64, item[0..colon], 10) catch continue;
        if (at != app.frame_no) continue;
        const name = item[colon + 1 ..];
        if (std.mem.startsWith(u8, name, "text=")) {
            const t = name[5..];
            for (0..t.len) |i| onKey(app, .{ .type = .Char, .sequence = t[i .. i + 1] });
            continue;
        }
        const named = [_]struct { []const u8, movy.input.KeyType, []const u8 }{
            .{ "left", .Left, "" },     .{ "right", .Right, "" },  .{ "up", .Up, "" },
            .{ "down", .Down, "" },     .{ "enter", .Enter, "" },  .{ "esc", .Escape, "" },
            .{ "tab", .Tab, "" },       .{ "stab", .ShiftTab, "" }, .{ "bksp", .Backspace, "" },
            .{ "space", .Char, " " },   .{ "pgup", .PageUp, "" },  .{ "pgdn", .PageDown, "" },
            .{ "home", .Home, "" },     .{ "end", .End, "" },      .{ "f7", .F7, "" },
        };
        var done = false;
        for (named) |nk| {
            if (std.mem.eql(u8, name, nk[0])) {
                onKey(app, .{ .type = nk[1], .sequence = nk[2] });
                done = true;
            }
        }
        if (!done and name.len == 1) onKey(app, .{ .type = .Char, .sequence = name });
    }
}
