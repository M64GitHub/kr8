//! Everything kr8 draws: the text layer (bar, panes, info strip, hints,
//! overlays) and the pixel layer (the waveform). Immediate mode - the
//! app hands a `Ctx` in, nothing here keeps state.
//!
//!   row 0            the bar: kr8 chip, status message, AUTO / LOOP chips
//!   rows 1..         the panes, auto-tiled (1 | 2 side by side | 3 = left
//!                    full + right split | 4 = 2x2), `z` zooms the focused one
//!   info row         the cursor file: format, length, loop, root, peak
//!   wave rows        TRANSPARENT text cells: the pixel waveform shows through
//!   last row         key hints

const std = @import("std");
const movy = @import("movy");
const theme = @import("ui/theme.zig");
const widgets = @import("ui/widgets.zig");
const TextCanvas = @import("ui/canvas.zig").TextCanvas;
const pane_mod = @import("pane.zig");
const config = @import("config.zig");
const wav = @import("../audio/wav.zig");
const peaks_mod = @import("../audio/peaks.zig");
const library = @import("../db/library.zig");

const Rgb = theme.Rgb;
const V3 = theme.V3;
const Pane = pane_mod.Pane;
const Entry = pane_mod.Entry;

pub const Rect = struct {
    x: usize = 0,
    y: usize = 0,
    w: usize = 0,
    h: usize = 0,
};

pub const Layout = struct {
    cols: usize,
    rows: usize,
    bar: Rect,
    panes: [config.MAX_PANES]Rect = @splat(.{}),
    info: Rect,
    /// the library row: tags, copies, note
    info2: Rect,
    wave: Rect,
    hints: Rect,
};

pub fn layout(cols: usize, rows: usize, n: usize, focus: usize, zoom: bool) Layout {
    // an EVEN number of rows: the zero line sits between two of them
    const wave_rows: usize = std.math.clamp((rows / 6) & ~@as(usize, 1), 4, 8);
    const bottom = 2 + wave_rows + 1;
    const top: usize = 1;
    const area_h = rows -| (top + bottom);
    const area: Rect = .{ .x = 0, .y = top, .w = cols, .h = area_h };
    var l: Layout = .{
        .cols = cols,
        .rows = rows,
        .bar = .{ .w = cols, .h = 1 },
        .info = .{ .y = top + area_h, .w = cols, .h = 1 },
        .info2 = .{ .y = top + area_h + 1, .w = cols, .h = 1 },
        .wave = .{ .x = 1, .y = top + area_h + 2, .w = cols -| 2, .h = wave_rows },
        .hints = .{ .y = rows -| 1, .w = cols, .h = 1 },
    };
    if (zoom and n > 1) {
        l.panes[focus] = area;
        return l;
    }
    const hw = area.w / 2;
    const hh = area.h / 2;
    const left: Rect = .{ .x = 0, .y = top, .w = hw, .h = area_h };
    const rx = hw;
    const rw = area.w - hw;
    switch (n) {
        0, 1 => l.panes[0] = area,
        2 => {
            l.panes[0] = left;
            l.panes[1] = .{ .x = rx, .y = top, .w = rw, .h = area_h };
        },
        3 => {
            l.panes[0] = left;
            l.panes[1] = .{ .x = rx, .y = top, .w = rw, .h = hh };
            l.panes[2] = .{ .x = rx, .y = top + hh, .w = rw, .h = area_h - hh };
        },
        else => {
            l.panes[0] = .{ .x = 0, .y = top, .w = hw, .h = hh };
            l.panes[1] = .{ .x = rx, .y = top, .w = rw, .h = hh };
            l.panes[2] = .{ .x = 0, .y = top + hh, .w = hw, .h = area_h - hh };
            l.panes[3] = .{ .x = rx, .y = top + hh, .w = rw, .h = area_h - hh };
        },
    }
    return l;
}

pub const Modal = enum { none, help, favs, target, mkdir, tags, note, find, export_confirm };

pub const PlayView = struct {
    active: bool = false,
    /// the playing file, absolute
    path: []const u8 = "",
    pos: u64 = 0, // frames
    frames: u64 = 0,
    rate: u32 = 0,
};

/// The tag picker, as the app holds it.
pub const TagView = struct {
    query: []const u8 = "",
    rows: []const library.TagRow = &.{},
    /// indices into `rows` that match the query; `rows.len` = the "new tag" row
    shown: []const usize = &.{},
    /// per row: how many of the targets carry it
    have: []const u32 = &.{},
    targets: usize = 0,
    sel: usize = 0,
    /// the file name, or "N marked files"
    title: []const u8 = "",
    /// the normalised new-tag name (when it is offered)
    new_name: []const u8 = "",
};

pub const ScanView = struct { done: u32, total: u32 };

pub const Ctx = struct {
    lay: *const Layout,
    panes: []Pane,
    focus: usize,
    zoom: bool,
    auto: bool,
    loop: bool,
    audio_ok: bool,
    volume: f32,
    status: ?[]const u8,
    status_fade: f32, // 0 fresh .. 1 gone
    play: PlayView,
    /// the overview of the cursor file, when it is ready
    peaks: ?*const peaks_mod.Peaks,
    modal: Modal,
    fav_sel: usize,
    /// the pane `c` copies into (null: none yet / ask)
    target: ?usize,
    /// the target picker's selection (a pane index)
    target_sel: usize,
    help_scroll: usize,
    /// the new-folder / note prompt's text
    input: []const u8,
    /// the library (null: it could not be opened)
    lib: ?*library.Library,
    /// the tag `x` toggles ("" = none armed)
    armed: []const u8,
    scan: ?ScanView,
    tags: TagView,
    /// the note prompt's file name
    note_title: []const u8,
    /// the find prompt: matches so far (-1 = none / invalid), or the problem
    find_count: i64,
    find_msg: []const u8,
    /// the find prompt's text is selected (typing replaces it)
    input_sel: bool,
    export_n: usize,
    export_to: usize,
    cfg: *const config.Config,
    home: []const u8,
};

// =================================================================== text

pub fn drawText(c: *TextCanvas, ctx: *const Ctx) void {
    drawBar(c, ctx);
    for (ctx.panes, 0..) |*p, i| {
        const r = ctx.lay.panes[i];
        if (r.w < 8 or r.h < 3) continue;
        drawPane(c, ctx, p, i, r);
    }
    drawInfo(c, ctx);
    drawInfo2(c, ctx);
    drawWave(c, ctx);
    drawHints(c, ctx);
    switch (ctx.modal) {
        .none => {},
        .help => drawHelp(c, ctx),
        .favs => drawFavs(c, ctx),
        .target => drawTargetPick(c, ctx),
        .mkdir => drawMkdir(c, ctx),
        .tags => drawTags(c, ctx),
        .note => drawNote(c, ctx),
        .find => drawFind(c, ctx),
        .export_confirm => drawExport(c, ctx),
    }
}

/// Is `e` (in pane `p`) the file that is playing?
fn isPlaying(ctx: *const Ctx, p: *const Pane, e: *const Entry) bool {
    if (!ctx.play.active or e.kind != .audio) return false;
    var buf: [pane_mod.PATH_MAX + 1]u8 = undefined;
    const path = p.pathOf(e, &buf) orelse return false;
    return std.mem.eql(u8, path, ctx.play.path);
}

fn drawBar(c: *TextCanvas, ctx: *const Ctx) void {
    const y = ctx.lay.bar.y;
    c.fillRow(y, theme.text, theme.header_bg);
    c.putStr(1, y, " kr8 ", theme.focus_fg, theme.focus_bg);
    var x: usize = 7;
    // right side first, so the status knows how much room it has
    var rx = ctx.lay.cols -| 1;
    rx = chipRight(c, rx, y, "LOOP", ctx.loop);
    rx = chipRight(c, rx -| 1, y, "AUTO", ctx.auto);
    if (ctx.armed.len > 0) {
        // the armed tag: what `x` toggles
        const n = @min(cellCount(ctx.armed), 20);
        rx -|= n + 5;
        c.putStr(rx, y, " x ", theme.bg, theme.fx_duet);
        _ = text(c, rx + 3, y, ctx.armed, n, theme.fx_duet, theme.header_bg);
    }
    if (ctx.scan) |sv| {
        var sb: [40]u8 = undefined;
        const ss = std.fmt.bufPrint(&sb, "scan {d}/{d}", .{ sv.done, sv.total }) catch "";
        rx -|= ss.len + 2;
        c.putStr(rx, y, ss, theme.accent, theme.header_bg);
    }
    if (!ctx.audio_ok) {
        rx -|= 10;
        c.putStr(rx, y, " NO AUDIO ", theme.bg, theme.accent_pink);
    } else if (ctx.volume < 0.999) {
        var vb: [16]u8 = undefined;
        const vs = std.fmt.bufPrint(&vb, "vol {d}%", .{@as(u32, @intFromFloat(ctx.volume * 100 + 0.5))}) catch "";
        rx -|= vs.len + 1;
        c.putStr(rx, y, vs, theme.text_dim, theme.header_bg);
    }
    if (ctx.status) |s| {
        const fg = theme.mix(theme.text_bright, theme.text_dim, ctx.status_fade);
        x += 1;
        _ = text(c, x, y, s, rx -| (x + 2), fg, theme.header_bg);
    }
}

/// A chip ending at column `right` (exclusive); returns its left edge.
fn chipRight(c: *TextCanvas, right: usize, y: usize, label: []const u8, on: bool) usize {
    const w = label.len + 2;
    const x = right -| w;
    if (on) {
        c.put(x, y, ' ', theme.bg, theme.accent);
        c.putStr(x + 1, y, label, theme.bg, theme.accent);
        c.put(x + 1 + label.len, y, ' ', theme.bg, theme.accent);
    } else {
        c.put(x, y, ' ', theme.value_off, theme.header_bg);
        c.putStr(x + 1, y, label, theme.value_off, theme.header_bg);
        c.put(x + 1 + label.len, y, ' ', theme.value_off, theme.header_bg);
    }
    return x;
}

fn drawPane(c: *TextCanvas, ctx: *const Ctx, p: *Pane, idx: usize, r: Rect) void {
    const focused = idx == ctx.focus;
    const bord = if (focused) theme.accent_hot else theme.sep;
    // border + cleared interior
    var dy: usize = 0;
    while (dy < r.h) : (dy += 1) c.putRepeat(r.x, r.y + dy, r.w, ' ', theme.text, theme.bg);
    c.putRepeat(r.x + 1, r.y, r.w - 2, 0x2500, bord, theme.bg);
    c.putRepeat(r.x + 1, r.y + r.h - 1, r.w - 2, 0x2500, bord, theme.bg);
    dy = 1;
    while (dy + 1 < r.h) : (dy += 1) {
        c.put(r.x, r.y + dy, 0x2502, bord, theme.bg);
        c.put(r.x + r.w - 1, r.y + dy, 0x2502, bord, theme.bg);
    }
    c.put(r.x, r.y, 0x256D, bord, theme.bg);
    c.put(r.x + r.w - 1, r.y, 0x256E, bord, theme.bg);
    c.put(r.x, r.y + r.h - 1, 0x2570, bord, theme.bg);
    c.put(r.x + r.w - 1, r.y + r.h - 1, 0x256F, bord, theme.bg);

    // title: number chip + path
    const nfg = if (focused) theme.focus_fg else theme.text;
    const nbg = if (focused) theme.focus_bg else theme.header_bg;
    c.put(r.x + 2, r.y, ' ', nfg, nbg);
    c.put(r.x + 3, r.y, '1' + @as(u21, @intCast(idx)), nfg, nbg);
    c.put(r.x + 4, r.y, ' ', nfg, nbg);
    var tx = r.x + 5;
    if (ctx.target != null and ctx.target.? == idx) {
        // the copy target: a pink dot after the number
        c.put(tx, r.y, ' ', theme.text, theme.bg);
        c.put(tx + 1, r.y, 0x25CF, theme.accent_pink, theme.bg);
        tx += 2;
    }
    var pb: [pane_mod.PATH_MAX + 8]u8 = undefined;
    const room = r.w -| (tx - r.x + 5);
    c.put(tx, r.y, ' ', theme.text, theme.bg);
    if (p.isQuery()) {
        // a search: the query, and how many files it found
        c.putStr(tx + 1, r.y, " ? ", theme.bg, theme.fx_duet);
        const qn = text(c, tx + 4, r.y, p.query(), room -| 16, theme.text_bright, theme.bg);
        var cb: [32]u8 = undefined;
        const cs = std.fmt.bufPrint(&cb, " {d}{s} files ", .{ p.entries.items.len, if (p.truncated) "+" else "" }) catch "";
        c.put(tx + 4 + qn, r.y, ' ', theme.text, theme.bg);
        c.putStr(tx + 5 + qn, r.y, cs, theme.text_dim, theme.bg);
    } else {
        const shown = tildePath(p.dir(), ctx.home, &pb);
        const n = textTail(c, tx + 1, r.y, shown, room, if (focused) theme.text_bright else theme.text, theme.bg);
        c.put(tx + 1 + n, r.y, ' ', theme.text, theme.bg);
    }

    // list
    const inner_w = r.w - 2;
    const inner_h = r.h - 2;
    p.follow(inner_h);
    var row: usize = 0;
    while (row < inner_h) : (row += 1) {
        const i = p.scroll + row;
        if (i >= p.rows()) break;
        drawRow(c, ctx, p, p.entryAt(i), r.x + 1, r.y + 1 + row, inner_w, i == p.cursor, focused);
    }
    // the scrollbar: a thumb riding the right border when the list is longer than the pane
    if (p.rows() > inner_h and inner_h > 0) {
        const total = p.rows();
        const th = @max((inner_h * inner_h) / total, 1);
        const range = inner_h - th;
        const denom = total - inner_h;
        const ty = r.y + 1 + @min((p.scroll * range + denom / 2) / denom, range);
        const thumb = if (focused) theme.accent_hot else theme.accent;
        var yy = ty;
        while (yy < ty + th) : (yy += 1) c.put(r.x + r.w - 1, yy, 0x2588, thumb, theme.bg);
    }
    if (p.rows() == 0) {
        const msg = if (p.filter_len > 0) "no match" else "empty folder";
        c.putStr(r.x + 3, r.y + 1, msg, theme.text_dim, theme.bg);
    }

    // bottom edge: filter (left), position (right)
    const by = r.y + r.h - 1;
    if (p.filter_len > 0 or p.typing) {
        var x = r.x + 2;
        c.putStr(x, by, " / ", theme.bg, theme.accent);
        x += 3;
        c.put(x, by, ' ', theme.text_bright, theme.bg);
        x += 1;
        const fw = text(c, x, by, p.filter(), r.w -| 24, theme.text_bright, theme.bg);
        x += fw;
        if (p.typing and focused) {
            c.put(x, by, 0x2588, theme.accent_hot, theme.bg);
            x += 1;
        }
        c.put(x, by, ' ', theme.text, theme.bg);
    }
    const shown_files = p.rows() - @intFromBool(p.rows() > 0 and p.entryAt(0).kind == .parent);
    if (shown_files > 0 and r.w > 30) {
        var nb: [32]u8 = undefined;
        const files = shown_files;
        const cur = if (p.entryAt(0).kind == .parent) p.cursor else p.cursor + 1;
        const s = std.fmt.bufPrint(&nb, " {d}/{d} ", .{ cur, files }) catch "";
        const sx = r.x + r.w -| (s.len + 2);
        c.putStr(sx, by, s, theme.text_dim, theme.bg);
        const marked = p.markedCount();
        if (marked > 0) {
            var mb: [32]u8 = undefined;
            const ms = std.fmt.bufPrint(&mb, " {d} marked ", .{marked}) catch "";
            c.putStr(sx -| (ms.len + 1), by, ms, theme.bg, theme.accent_pink);
        }
    }
}

fn drawRow(c: *TextCanvas, ctx: *const Ctx, p: *Pane, e: *Entry, x0: usize, y: usize, w: usize, is_cur: bool, focused: bool) void {
    const bg: Rgb = if (is_cur and focused) theme.cursor_bg else if (is_cur) theme.cursor_row_bg else theme.bg;
    const on_cur = is_cur and focused;
    c.putRepeat(x0, y, w, ' ', theme.text, bg);

    const playing = isPlaying(ctx, p, e);
    if (playing) c.put(x0, y, 0x25B6, if (on_cur) theme.cursor_fg else theme.accent_pink, bg);

    const name_x = x0 + 2;
    switch (e.kind) {
        .parent => {
            c.put(x0 + 1, y, 0x25B8, if (on_cur) theme.cursor_fg else theme.text_dim, bg);
            c.putStr(name_x + 1, y, "..", if (on_cur) theme.cursor_fg else theme.text_dim, bg);
        },
        .dir => {
            const fg = if (on_cur) theme.cursor_fg else theme.accent;
            c.put(x0 + 1, y, 0x25B8, fg, bg);
            const n = text(c, name_x + 1, y, e.name, w -| 5, fg, bg);
            c.put(name_x + 1 + n, y, '/', fg, bg);
        },
        .audio, .other => {
            // the right block, laid out from the right edge inward:
            // length, loop mark, copies (xN), note mark, tags
            var rb: [24]u8 = undefined;
            var right: []const u8 = "";
            var loop_mark = false;
            if (e.kind == .audio) {
                if (p.info(e)) |inf| {
                    right = fmtDur(inf.seconds(), &rb);
                    loop_mark = inf.has_loop;
                } else right = "?";
            }
            if (e.marked) c.put(x0 + 1, y, 0x25C6, if (on_cur) theme.cursor_fg else theme.accent_pink, bg);
            const base_fg = if (on_cur) theme.cursor_fg else if (e.marked) theme.accent_pink else if (e.kind == .audio) theme.text else theme.value_off;
            const dim_fg = if (on_cur) theme.cursor_fg else if (e.kind == .audio) theme.text_dim else theme.value_off;
            const name_left = name_x + 1;
            var rx = x0 + w - 1; // exclusive; one cell of margin before the border
            if (e.kind == .audio and w > 16) {
                rx -|= right.len;
                c.putStr(rx, y, right, dim_fg, bg);
                rx -|= 2;
                if (loop_mark) c.put(rx, y, 0x21BB, if (on_cur) theme.cursor_fg else theme.accent_pink, bg);
                if (ctx.lib) |lib| {
                    const f = p.facts(lib, e);
                    if (f.files > 1) {
                        var cb: [12]u8 = undefined;
                        const cs = std.fmt.bufPrint(&cb, "\u{00D7}{d}", .{f.files}) catch "";
                        rx -|= cellCount(cs) + 1;
                        _ = text(c, rx, y, cs, 8, if (on_cur) theme.cursor_fg else theme.text_dim, bg);
                    }
                    if (f.has_note) {
                        rx -|= 2;
                        c.put(rx, y, 0x00B6, if (on_cur) theme.cursor_fg else theme.text, bg);
                    }
                    const tl = cellCount(f.tags());
                    if (tl > 0) {
                        const room = @min(tl, w / 3);
                        if (room >= 3 and rx > name_left + room + 6) {
                            rx -= room + 1;
                            _ = text(c, rx, y, f.tags(), room, if (on_cur) theme.cursor_fg else theme.fx_duet, bg);
                        }
                    }
                }
            }
            const name_room = (rx -| 1) -| name_left;
            const shown = p.displayName(e);
            const ext = std.fs.path.extension(shown);
            const stem = shown[0 .. shown.len - ext.len];
            var ns = text(c, name_left, y, stem, name_room, if (playing and !on_cur) theme.text_bright else base_fg, bg);
            if (ns < name_room) ns += text(c, name_left + ns, y, ext, name_room - ns, dim_fg, bg);
            if (p.isQuery() and ns + 4 < name_room) {
                // where the hit lives: relative to its root, else ~-shortened
                const dir = std.fs.path.dirname(e.name) orelse "";
                var fb: [pane_mod.PATH_MAX + 8]u8 = undefined;
                const where = if (ctx.lib) |lib| blk: {
                    const pl = lib.place(dir);
                    break :blk if (pl.root_id != 0) pl.path else tildePath(dir, ctx.home, &fb);
                } else tildePath(dir, ctx.home, &fb);
                _ = textTail(c, name_left + ns + 2, y, where, name_room - ns - 2, if (on_cur) theme.cursor_fg else theme.value_off, bg);
            }
        },
    }
}

fn drawInfo(c: *TextCanvas, ctx: *const Ctx) void {
    const r = ctx.lay.info;
    c.fillRow(r.y, theme.text, theme.header_bg);
    const p = &ctx.panes[ctx.focus];
    const e = p.current() orelse return;
    var x: usize = 1;
    const bg = theme.header_bg;
    switch (e.kind) {
        .parent => {
            _ = text(c, x, r.y, "..  parent folder", r.w -| 2, theme.text_dim, bg);
            return;
        },
        .dir => {
            c.put(x, r.y, 0x25B8, theme.accent, bg);
            x += 2;
            x += text(c, x, r.y, e.name, r.w -| 40, theme.text_bright, bg);
            c.put(x, r.y, '/', theme.text_bright, bg);
            x += 1;
            if (p.counts(e)) |n| {
                var cb: [80]u8 = undefined;
                const cs = std.fmt.bufPrint(&cb, "{d} WAV{s} \u{00B7} {d} folder{s}{s}", .{
                    n.wavs,                          if (n.wavs == 1) "" else "s",
                    n.dirs,                          if (n.dirs == 1) "" else "s",
                    if (n.other > 0) " \u{00B7} other files" else "",
                }) catch "";
                c.put(x + 1, r.y, 0x00B7, theme.sep, bg);
                _ = text(c, x + 3, r.y, cs, r.w -| (x + 4), theme.text_dim, bg);
            }
            return;
        },
        .other => {
            x += text(c, x, r.y, p.displayName(e), r.w -| 20, theme.text, bg);
            var pb: [pane_mod.PATH_MAX + 1]u8 = undefined;
            const size: ?u64 = if (p.pathOf(e, &pb)) |path|
                (if (std.fs.cwd().statFile(path)) |st| st.size else |_| null)
            else
                null;
            var sb: [16]u8 = undefined;
            if (size) |n| c.putStr(x + 2, r.y, humanSize(n, &sb), theme.text_dim, bg);
            c.putStr(x + 12, r.y, "not a WAV - kr8 lists it, can't play it", theme.value_off, bg);
            return;
        },
        .audio => {},
    }

    // the play readout on the right (when this file is the one playing)
    const playing_this = isPlaying(ctx, p, e);
    var right_w: usize = 0;
    if (playing_this and ctx.play.rate > 0) {
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        var b3: [40]u8 = undefined;
        const pos = @as(f64, @floatFromInt(ctx.play.pos)) / @as(f64, @floatFromInt(ctx.play.rate));
        const len = @as(f64, @floatFromInt(ctx.play.frames)) / @as(f64, @floatFromInt(ctx.play.rate));
        const s = std.fmt.bufPrint(&b3, "{s} / {s}", .{ fmtClock(pos, &b1), fmtClock(len, &b2) }) catch "";
        right_w = s.len + 4;
        const rx = r.w -| (s.len + 1);
        c.put(rx -| 2, r.y, 0x25B6, theme.accent_pink, bg);
        c.putStr(rx, r.y, s, theme.text_bright, bg);
    }

    const room = r.w -| (right_w + 2);
    const start = x;
    x += text(c, x, r.y, p.displayName(e), room, theme.text_bright, bg);
    const inf = p.info(e) orelse {
        _ = text(c, x + 2, r.y, "not a readable WAV", room -| (x - start + 2), theme.accent_pink, bg);
        return;
    };
    var parts: [8][]const u8 = undefined;
    var bufs: [8][40]u8 = undefined;
    var np: usize = 0;
    const add = struct {
        fn f(ps: *[8][]const u8, bs: *[8][40]u8, k: *usize, comptime fmt: []const u8, args: anytype) void {
            if (k.* >= ps.len) return;
            ps[k.*] = std.fmt.bufPrint(&bs[k.*], fmt, args) catch return;
            k.* += 1;
        }
    }.f;
    const khz = @as(f64, @floatFromInt(inf.rate)) / 1000.0;
    const kind: []const u8 = if (inf.format == .float) "float" else "bit";
    const chans: []const u8 = switch (inf.channels) {
        1 => "mono",
        2 => "stereo",
        else => "multi",
    };
    if (inf.rate % 1000 == 0) add(&parts, &bufs, &np, "{d}k {d}-{s} {s}", .{ inf.rate / 1000, inf.bits, kind, chans }) else add(&parts, &bufs, &np, "{d:.1}k {d}-{s} {s}", .{ khz, inf.bits, kind, chans });
    var db: [16]u8 = undefined;
    add(&parts, &bufs, &np, "{s}", .{fmtClock(inf.seconds(), &db)});
    if (inf.has_loop and inf.rate > 0) {
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        const rate: f64 = @floatFromInt(inf.rate);
        add(&parts, &bufs, &np, "loop {s}-{s}", .{
            fmtClock(@as(f64, @floatFromInt(inf.loop_start)) / rate, &b1),
            fmtClock(@as(f64, @floatFromInt(inf.loop_end)) / rate, &b2),
        });
    }
    if (inf.root_note) |rn| {
        var nb: [4]u8 = undefined;
        add(&parts, &bufs, &np, "root {s}", .{wav.noteName(rn, &nb)});
    }
    if (ctx.peaks) |pk| {
        if (!pk.failed and pk.peak > 0) {
            const dbv = 20.0 * std.math.log10(pk.peak);
            add(&parts, &bufs, &np, "peak {d:.1} dB", .{dbv});
        }
    }
    if (inf.wavetable) add(&parts, &bufs, &np, "wavetable", .{});

    for (parts[0..np]) |s| {
        const used = x - start;
        if (used + 3 + s.len > room) break;
        c.put(x + 1, r.y, 0x00B7, theme.sep, bg);
        x += 3;
        c.putStr(x, r.y, s, theme.text, bg);
        x += s.len;
    }
}

/// The library row: the cursor file's tags, copies and note.
fn drawInfo2(c: *TextCanvas, ctx: *const Ctx) void {
    const r = ctx.lay.info2;
    const bg = theme.header_bg;
    c.fillRow(r.y, theme.text, bg);
    const p = &ctx.panes[ctx.focus];
    const e = p.current() orelse return;
    if (e.kind != .audio) return;
    const lib = ctx.lib orelse {
        _ = text(c, 1, r.y, "no library (could not open ~/.config/kr8/kr8.db)", r.w -| 2, theme.value_off, bg);
        return;
    };
    const f = p.facts(lib, e);
    var x: usize = 1;
    if (f.sound == 0) {
        const msg = if (ctx.scan != null) "not scanned yet - t tags it anyway" else "not in the library yet - t or x adds it";
        _ = text(c, x, r.y, msg, r.w -| 2, theme.text_dim, bg);
        return;
    }
    if (f.tags_len > 0) {
        x += text(c, x, r.y, f.tags(), r.w / 2, theme.fx_duet, bg);
    } else {
        x += text(c, x, r.y, "no tags", 10, theme.value_off, bg);
    }
    if (f.files > 1) {
        var cb: [40]u8 = undefined;
        const cs = std.fmt.bufPrint(&cb, "{d} copies in the library", .{f.files}) catch "";
        c.put(x + 1, r.y, 0x00B7, theme.sep, bg);
        x += 3;
        x += text(c, x, r.y, cs, r.w -| (x + 2), theme.text_dim, bg);
    }
    if (f.has_note) {
        var nb: [256]u8 = undefined;
        const nt = lib.note(f.sound, &nb);
        c.put(x + 1, r.y, 0x00B7, theme.sep, bg);
        x += 3;
        c.put(x, r.y, 0x00B6, theme.text, bg);
        x += 2;
        _ = text(c, x, r.y, nt, r.w -| (x + 2), theme.text_bright, bg);
    }
}

/// The tag picker: type to filter (or name a new tag), pick with enter.
fn drawTags(c: *TextCanvas, ctx: *const Ctx) void {
    const tv = &ctx.tags;
    const w: usize = @min(ctx.lay.cols -| 4, 64);
    const list_h: usize = @min(@max(tv.shown.len, 1), ctx.lay.rows -| 10);
    const h: usize = list_h + 6;
    const x0 = (ctx.lay.cols -| w) / 2;
    const y0 = (ctx.lay.rows -| h) / 2;
    widgets.frame(c, x0, y0, w, h, " TAGS ");
    c.put(x0 + 10, y0, ' ', theme.text_bright, theme.bg);
    const tn = text(c, x0 + 11, y0, tv.title, w -| 16, theme.text_bright, theme.bg);
    c.put(x0 + 11 + tn, y0, ' ', theme.text_bright, theme.bg);
    c.put(x0 + 3, y0 + 2, 0x276F, theme.accent_hot, theme.bg);
    const qn = text(c, x0 + 5, y0 + 2, tv.query, w -| 9, theme.text_bright, theme.bg);
    c.put(x0 + 5 + qn, y0 + 2, 0x2588, theme.accent_hot, theme.bg);
    c.putRepeat(x0 + 2, y0 + 3, w - 4, 0x2500, theme.sep, theme.bg);
    if (tv.shown.len == 0) {
        _ = text(c, x0 + 4, y0 + 4, "no tags yet - type a name, enter makes it", w -| 8, theme.text_dim, theme.bg);
    }
    const first = if (tv.sel >= list_h) tv.sel + 1 - list_h else 0;
    var i: usize = 0;
    while (i < list_h and first + i < tv.shown.len) : (i += 1) {
        const k = first + i;
        const y = y0 + 4 + i;
        const sel = k == tv.sel;
        const bg = if (sel) theme.cursor_bg else theme.bg;
        const fg = if (sel) theme.cursor_fg else theme.text;
        c.putRepeat(x0 + 2, y, w - 4, ' ', fg, bg);
        const ri = tv.shown[k];
        if (ri >= tv.rows.len) {
            c.putStr(x0 + 3, y, "+ new tag", if (sel) fg else theme.accent_hot, bg);
            _ = text(c, x0 + 13, y, tv.new_name, w -| 18, if (sel) fg else theme.fx_duet, bg);
            continue;
        }
        const row = tv.rows[ri];
        const have = tv.have[ri];
        const box: []const u8 = if (tv.targets > 0 and have == tv.targets) "[x]" else if (have > 0) "[-]" else "[ ]";
        c.putStr(x0 + 3, y, box, if (sel) fg else theme.accent_hot, bg);
        _ = text(c, x0 + 7, y, row.name, w -| 20, if (sel) fg else theme.fx_duet, bg);
        var nb: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{row.count}) catch "";
        c.putStr(x0 + w -| (ns.len + 3), y, ns, if (sel) fg else theme.text_dim, bg);
    }
    c.putStr(x0 + 2, y0 + h - 1, " enter toggle+arm  tab toggle, stay  shift-tab arm  esc ", theme.text_dim, theme.bg);
}

const FIND_HELP = [_][]const u8{
    "words: the path (folders + name), a tag or the note contains it",
    "-word: none of them    #tag / -#tag: has / lacks the tag",
    "<1s  >2s  <500ms: length",
    "is:dupe is:mono is:stereo is:tagged is:untagged is:noted is:loop is:wavetable",
};

/// The search prompt: the query, the live count, the syntax.
fn drawFind(c: *TextCanvas, ctx: *const Ctx) void {
    const w: usize = @min(ctx.lay.cols -| 4, 86);
    const no_roots = if (ctx.lib) |lib| lib.roots.items.len == 0 else false;
    const h: usize = FIND_HELP.len + 7 + @as(usize, if (no_roots) 2 else 0);
    const x0 = (ctx.lay.cols -| w) / 2;
    const y0 = (ctx.lay.rows -| h) / 2;
    widgets.frame(c, x0, y0, w, h, " FIND IN THE LIBRARY ");
    c.put(x0 + 3, y0 + 2, 0x276F, theme.accent_hot, theme.bg);
    // a selected (pre-filled) query is drawn inverted: typing replaces it
    const qfg = if (ctx.input_sel) theme.cursor_fg else theme.text_bright;
    const qbg = if (ctx.input_sel) theme.cursor_bg else theme.bg;
    const n = textTail(c, x0 + 5, y0 + 2, ctx.input, w -| 24, qfg, qbg);
    c.put(x0 + 5 + n, y0 + 2, 0x2588, theme.accent_hot, theme.bg);
    var cb: [40]u8 = undefined;
    const cs = if (ctx.find_msg.len > 0)
        ctx.find_msg
    else if (ctx.find_count >= 0)
        std.fmt.bufPrint(&cb, "{d} files", .{ctx.find_count}) catch ""
    else
        "";
    const col = if (ctx.find_msg.len > 0) theme.accent_pink else theme.fx_duet;
    if (ctx.find_msg.len > 0) {
        _ = text(c, x0 + 3, y0 + 3, cs, w -| 6, col, theme.bg);
    } else c.putStr(x0 + w -| (cs.len + 3), y0 + 2, cs, col, theme.bg);
    c.putRepeat(x0 + 2, y0 + 4, w - 4, 0x2500, theme.sep, theme.bg);
    for (FIND_HELP, 0..) |line, i| _ = text(c, x0 + 3, y0 + 5 + i, line, w -| 6, theme.text_dim, theme.bg);
    if (ctx.lib) |lib| if (lib.roots.items.len == 0) {
        // an empty library is not a broken search: say what is in it
        _ = text(c, x0 + 3, y0 + 5 + FIND_HELP.len, "no folder is indexed yet - only files you tagged are searched.", w -| 6, theme.accent_pink, theme.bg);
        _ = text(c, x0 + 3, y0 + 6 + FIND_HELP.len, "in a shell: kr8 root add ~/TRACKBASE/samples/trackers", w -| 6, theme.accent_pink, theme.bg);
    };
    const hint = if (ctx.input_sel) " typing replaces the old search, right keeps it  esc " else " enter searches (this pane shows the hits)  esc ";
    c.putStr(x0 + 2, y0 + h - 1, hint, theme.text_dim, theme.bg);
}

fn drawExport(c: *TextCanvas, ctx: *const Ctx) void {
    const w: usize = @min(ctx.lay.cols -| 4, 76);
    const h: usize = 6;
    const x0 = (ctx.lay.cols -| w) / 2;
    const y0 = (ctx.lay.rows -| h) / 2;
    widgets.frame(c, x0, y0, w, h, " EXPORT ");
    var lb: [64]u8 = undefined;
    const ls = std.fmt.bufPrint(&lb, "copy all {d} files shown here into pane {d}:", .{ ctx.export_n, ctx.export_to + 1 }) catch "";
    _ = text(c, x0 + 3, y0 + 2, ls, w -| 6, theme.text, theme.bg);
    var pb: [pane_mod.PATH_MAX + 8]u8 = undefined;
    if (ctx.export_to < ctx.panes.len)
        _ = textTail(c, x0 + 3, y0 + 3, tildePath(ctx.panes[ctx.export_to].dir(), ctx.home, &pb), w -| 6, theme.text_bright, theme.bg);
    c.putStr(x0 + 2, y0 + h - 1, " enter copies (never overwrites)  esc ", theme.text_dim, theme.bg);
}

/// The one-line note prompt.
fn drawNote(c: *TextCanvas, ctx: *const Ctx) void {
    const w: usize = @min(ctx.lay.cols -| 4, 90);
    const h: usize = 5;
    const x0 = (ctx.lay.cols -| w) / 2;
    const y0 = (ctx.lay.rows -| h) / 2;
    widgets.frame(c, x0, y0, w, h, " NOTE ");
    c.put(x0 + 10, y0, ' ', theme.text_bright, theme.bg);
    const tn = text(c, x0 + 11, y0, ctx.note_title, w -| 16, theme.text_bright, theme.bg);
    c.put(x0 + 11 + tn, y0, ' ', theme.text_bright, theme.bg);
    c.put(x0 + 3, y0 + 2, 0x276F, theme.accent_hot, theme.bg);
    // the tail of a long note stays in view while typing
    const n = textTail(c, x0 + 5, y0 + 2, ctx.input, w -| 9, theme.text_bright, theme.bg);
    c.put(x0 + 5 + n, y0 + 2, 0x2588, theme.accent_hot, theme.bg);
    c.putStr(x0 + 2, y0 + h - 1, " enter saves (empty deletes)  esc cancels ", theme.text_dim, theme.bg);
}

const Hint = struct { k: []const u8, v: []const u8 };

fn drawHints(c: *TextCanvas, ctx: *const Ctx) void {
    const y = ctx.lay.hints.y;
    c.fillRow(y, theme.text_dim, theme.bg);
    const typing = ctx.panes[ctx.focus].typing;
    const normal = [_]Hint{
        .{ .k = "spc", .v = "play" },   .{ .k = "a", .v = "auto" },
        .{ .k = "L", .v = "loop" },     .{ .k = "/", .v = "filter" },
        .{ .k = "f", .v = "find" },     .{ .k = "t", .v = "tag" },
        .{ .k = "x", .v = "armed" },
        .{ .k = "c", .v = "copy" },     .{ .k = "v", .v = "mark" },
        .{ .k = "tab", .v = "pane" },   .{ .k = "n", .v = "new pane" },
        .{ .k = "1-8", .v = "favs" },   .{ .k = "?", .v = "help" },
        .{ .k = "-+", .v = "vol" },     .{ .k = "z", .v = "zoom" },
    };
    const filtering = [_]Hint{
        .{ .k = "type", .v = "words to match" }, .{ .k = "up/dn", .v = "move" },
        .{ .k = "enter", .v = "keep filter" },   .{ .k = "esc", .v = "clear" },
    };
    const hs: []const Hint = if (typing) &filtering else &normal;
    var x: usize = 1;
    for (hs) |h| {
        const need = h.k.len + 1 + h.v.len + 2;
        if (x + need > ctx.lay.cols) break;
        c.putStr(x, y, h.k, theme.text, theme.bg);
        x += h.k.len + 1;
        c.putStr(x, y, h.v, theme.text_dim, theme.bg);
        x += h.v.len + 2;
    }
}

const HelpLine = union(enum) {
    section: []const u8,
    key: Hint,
    note: []const u8,
    blank,
};

fn sec(w: []const u8) HelpLine {
    return .{ .section = w };
}
fn key(k: []const u8, v: []const u8) HelpLine {
    return .{ .key = .{ .k = k, .v = v } };
}
fn note(t: []const u8) HelpLine {
    return .{ .note = t };
}

/// THE HELP PAGE: one page, sections, scrolls when the terminal is short.
const HELP = [_]HelpLine{
    note("Panes are folders. The bright border is the focused pane;"),
    note("the pink dot marks the pane `c` copies into."),
    note("kr8 never overwrites or deletes anything."),
    .blank,
    sec("BROWSE"),
    key("j k  up down", "move"),
    key("pgup pgdn", "a page  (ctrl-u ctrl-d: half a page)"),
    key("g G  home end", "first / last"),
    key("enter  l  right", "open the folder / play the file from the start"),
    key("bksp  h  left", "parent folder"),
    key("r", "reload the folder"),
    key("M  F7", "new folder here"),
    .blank,
    sec("LISTEN"),
    key("space", "play / stop"),
    key("a", "AUTO: the cursor plays what it lands on"),
    key("L", "LOOP: loop the preview"),
    key("-  +", "preview volume"),
    key("esc", "clear the filter, else stop"),
    note("AUTO: moving off the playing file stops it."),
    note("LOOP uses the file's own loop points when it has real ones."),
    .blank,
    sec("FILTER"),
    key("/", "filter this pane: words that must be in the name"),
    key("enter", "keep the filter and browse in it"),
    key("esc", "clear the filter"),
    key("bksp", "delete a letter (on an empty filter: leave it)"),
    .blank,
    sec("COPY"),
    key("c", "copy file (or marked files) to target, move on"),
    key("C", "choose the target pane (with 3-4 panes)"),
    key("v", "mark / unmark the file, move down"),
    key("V", "mark all files shown / clear all marks"),
    note("Copies never overwrite: a name that exists gets _2, _3, ..."),
    note("With 2 panes the target is always the other one."),
    note("Tip: / to filter, then V marks just those."),
    .blank,
    sec("TAGS & NOTES"),
    key("t", "tag picker: type to filter or to name a new tag"),
    key("  enter", "toggle the tag, arm it for x, close"),
    key("  tab", "toggle and stay (more tags)  shift-tab: arm only"),
    key("  space", "types - (a tag is one word: crisp snare = crisp-snare)"),
    key("x", "toggle the armed tag on the file (or marks), move on"),
    key("e", "edit the file's note (one line)"),
    note("Tags belong to the SOUND: a copy of the file has the same tags,"),
    note("and they follow it when it moves. Rows: tags in green, \u{00D7}2 = copies,"),
    note("a pilcrow = a note. kr8 root add/list, kr8 scan, kr8 tags on the shell."),
    .blank,
    sec("FIND"),
    key("f", "search the library: this pane shows the hits"),
    key("  bksp h left", "back to the folder the pane showed before"),
    key("o", "open the hit's folder (cursor on the file)"),
    key("E", "export: copy every file shown into the target pane"),
    key("r", "search again (tags changed since)"),
    note("Words match the path (folders + name), a tag or the note -"),
    note("exact, never fuzzy. -word excludes. #good: has the tag good."),
    note("<1s >2s <500ms: length.  is:dupe is:mono is:stereo is:tagged"),
    note("is:untagged is:noted is:loop is:wavetable."),
    note("F then s stores a search as a favorite, like a folder."),
    .blank,
    sec("PANES"),
    key("tab  shift-tab", "next / previous pane"),
    key("n", "new pane on this folder (4 at most)"),
    key("q", "close the pane (the last one quits)"),
    key("z", "zoom the pane to the whole screen"),
    .blank,
    sec("FAVORITES"),
    key("1-8", "jump to a favorite folder"),
    key("F", "favorites list: s store here, x clear, enter go"),
    .blank,
    sec("KR8"),
    key("T", "next colour theme"),
    key("?", "this page"),
    key("Q  ctrl-c", "quit"),
};

pub const HelpGeom = struct {
    x0: usize,
    y0: usize,
    w: usize,
    h: usize,
    body_top: usize,
    body_h: usize,
    max_scroll: usize,
};

pub fn helpGeom(cols: usize, rows: usize) HelpGeom {
    const w: usize = @min(cols -| 4, 86);
    const h: usize = @min(rows -| 2, HELP.len + 4);
    const body_h = h -| 4;
    return .{
        .x0 = (cols -| w) / 2,
        .y0 = (rows -| h) / 2,
        .w = w,
        .h = h,
        .body_top = (rows -| h) / 2 + 2,
        .body_h = body_h,
        .max_scroll = HELP.len -| body_h,
    };
}

fn drawHelp(c: *TextCanvas, ctx: *const Ctx) void {
    const g = helpGeom(ctx.lay.cols, ctx.lay.rows);
    if (g.w < 40 or g.body_h < 3) return;
    widgets.frame(c, g.x0, g.y0, g.w, g.h, " KR8 - KEYS ");
    const scroll = @min(ctx.help_scroll, g.max_scroll);
    const kx = g.x0 + 3;
    const vx = g.x0 + 21;
    const vw = g.w -| 26;
    var i: usize = 0;
    while (i < g.body_h) : (i += 1) {
        const li = scroll + i;
        if (li >= HELP.len) break;
        const y = g.body_top + i;
        switch (HELP[li]) {
            .section => |w| widgets.sectionRule(c, kx, y, g.w -| 8, w),
            .key => |h| {
                c.putStr(kx, y, h.k, theme.accent_hot, theme.bg);
                _ = text(c, vx, y, h.v, vw, theme.text, theme.bg);
            },
            .note => |t| _ = text(c, kx, y, t, g.w -| 8, theme.text_dim, theme.bg),
            .blank => {},
        }
    }
    const by = g.y0 + g.h - 1;
    if (g.max_scroll > 0) {
        widgets.scrollbar(c, g.x0 + g.w - 2, g.body_top, g.body_h, HELP.len, g.body_h, scroll);
        c.putStr(g.x0 + 3, by, " j k / pgup pgdn scroll ", theme.text_dim, theme.header_bg);
    }
    const close = " esc or ? closes ";
    c.putStr(g.x0 + g.w -| (close.len + 3), by, close, theme.text_dim, theme.header_bg);
}

/// The new-folder prompt: where, and the name being typed.
fn drawMkdir(c: *TextCanvas, ctx: *const Ctx) void {
    const w: usize = @min(ctx.lay.cols -| 4, 72);
    const h: usize = 6;
    const x0 = (ctx.lay.cols -| w) / 2;
    const y0 = (ctx.lay.rows -| h) / 2;
    widgets.frame(c, x0, y0, w, h, " NEW FOLDER ");
    var pb: [pane_mod.PATH_MAX + 8]u8 = undefined;
    c.putStr(x0 + 3, y0 + 2, "in", theme.text_dim, theme.bg);
    _ = textTail(c, x0 + 6, y0 + 2, tildePath(ctx.panes[ctx.focus].dir(), ctx.home, &pb), w -| 10, theme.text, theme.bg);
    c.put(x0 + 3, y0 + 3, 0x276F, theme.accent_hot, theme.bg);
    const n = text(c, x0 + 5, y0 + 3, ctx.input, w -| 9, theme.text_bright, theme.bg);
    c.put(x0 + 5 + n, y0 + 3, 0x2588, theme.accent_hot, theme.bg);
    c.putStr(x0 + 2, y0 + h - 1, " enter creates  esc cancels ", theme.text_dim, theme.bg);
}

/// "copy to which pane?" - the other panes, one row each.
fn drawTargetPick(c: *TextCanvas, ctx: *const Ctx) void {
    const w: usize = @min(ctx.lay.cols -| 4, 80);
    const h: usize = ctx.panes.len - 1 + 4;
    const x0 = (ctx.lay.cols -| w) / 2;
    const y0 = (ctx.lay.rows -| h) / 2;
    widgets.frame(c, x0, y0, w, h, " COPY TO WHICH PANE? ");
    var row: usize = 0;
    for (ctx.panes, 0..) |*p, i| {
        if (i == ctx.focus) continue;
        const y = y0 + 2 + row;
        row += 1;
        const sel = i == ctx.target_sel;
        const bg = if (sel) theme.cursor_bg else theme.bg;
        const fg = if (sel) theme.cursor_fg else theme.text;
        c.putRepeat(x0 + 2, y, w - 4, ' ', fg, bg);
        c.put(x0 + 3, y, '1' + @as(u21, @intCast(i)), if (sel) fg else theme.accent_hot, bg);
        var pb: [pane_mod.PATH_MAX + 8]u8 = undefined;
        if (p.isQuery()) {
            _ = text(c, x0 + 6, y, "(a search - not a folder)", w -| 10, if (sel) fg else theme.value_off, bg);
        } else _ = textTail(c, x0 + 6, y, tildePath(p.dir(), ctx.home, &pb), w -| 10, fg, bg);
    }
    c.putStr(x0 + 2, y0 + h - 1, " pane number or enter picks (and is remembered)  esc ", theme.text_dim, theme.bg);
}

fn drawFavs(c: *TextCanvas, ctx: *const Ctx) void {
    const w: usize = @min(ctx.lay.cols -| 4, 80);
    const h: usize = config.N_FAVS + 4;
    const x0 = (ctx.lay.cols -| w) / 2;
    const y0 = (ctx.lay.rows -| h) / 2;
    widgets.frame(c, x0, y0, w, h, " FAVORITES ");
    var i: usize = 0;
    while (i < config.N_FAVS) : (i += 1) {
        const y = y0 + 2 + i;
        const sel = i == ctx.fav_sel;
        const bg = if (sel) theme.cursor_bg else theme.bg;
        const fg = if (sel) theme.cursor_fg else theme.text;
        c.putRepeat(x0 + 2, y, w - 4, ' ', fg, bg);
        c.put(x0 + 3, y, '1' + @as(u21, @intCast(i)), if (sel) fg else theme.accent_hot, bg);
        if (ctx.cfg.favorite(i)) |f| {
            var pb: [pane_mod.PATH_MAX + 8]u8 = undefined;
            _ = textTail(c, x0 + 6, y, tildePath(f, ctx.home, &pb), w -| 10, fg, bg);
        } else {
            c.putStr(x0 + 6, y, "-", if (sel) fg else theme.value_off, bg);
        }
    }
    c.putStr(x0 + 2, y0 + h - 1, " enter/1-8 go  s store this folder  x clear  esc ", theme.text_dim, theme.bg);
}

// ================================================================= pixels

pub fn drawPixels(f: *movy.Frame, ctx: *const Ctx) void {
    _ = ctx;
    f.rect(0, 0, f.w, f.h, V3.fromRgb(theme.bg));
}

/// Display curve: >1 is linear-ish, <1 lifts quiet detail (a break's
/// ghost notes, a pad's tail) at strip height.
const WAVE_GAMMA: f32 = 0.7;

/// THE WAVE STRIP in eighth blocks: 8 steps per text row (the pixel
/// layer's half blocks give 2). Positive peaks grow UP from the zero
/// line with the lower blocks; negative peaks grow DOWN with the same
/// glyphs inverted (ink = the ground, ground = the wave), so both halves
/// get the full 1/8-row resolution.
fn drawWave(c: *TextCanvas, ctx: *const Ctx) void {
    const r = ctx.lay.wave;
    if (r.w < 4 or r.h < 2) return;
    const ground = theme.bg;
    var row: usize = 0;
    while (row < r.h) : (row += 1) c.putRepeat(r.x, r.y + row, r.w, ' ', theme.text, ground);

    const p = &ctx.panes[ctx.focus];
    const e = p.current() orelse return;
    if (e.kind != .audio) return;
    const half_rows = r.h / 2;
    const zero_y = r.y + half_rows; // first row of the lower half
    const pk = ctx.peaks orelse {
        c.putRepeat(r.x, zero_y - 1, r.w, 0x2581, theme.sep, ground);
        return;
    };
    if (pk.failed or pk.frames == 0) {
        _ = text(c, r.x + 1, zero_y - 1, "can't decode this file", r.w -| 2, theme.accent_pink, ground);
        return;
    }
    const inf = p.info(e);
    const playing_this = isPlaying(ctx, p, e);
    var head: ?usize = null;
    if (playing_this and ctx.play.frames > 0) {
        const t = std.math.clamp(@as(f64, @floatFromInt(ctx.play.pos)) / @as(f64, @floatFromInt(ctx.play.frames)), 0, 1);
        head = @intFromFloat(t * @as(f64, @floatFromInt(r.w - 1)));
    }
    var loop_x0: usize = r.w;
    var loop_x1: usize = r.w;
    if (inf) |i| if (i.has_loop) {
        const tot: f64 = @floatFromInt(pk.frames);
        const fw: f64 = @floatFromInt(r.w);
        loop_x0 = @intFromFloat(@as(f64, @floatFromInt(i.loop_start)) / tot * fw);
        loop_x1 = @intFromFloat(@as(f64, @floatFromInt(i.loop_end)) / tot * fw);
    };

    const gain: f32 = if (pk.peak > 0.0001) 1.0 / pk.peak else 1.0;
    const steps: f32 = @floatFromInt(half_rows * 8);
    const loop_ground = theme.mix(ground, theme.accent_pink, 0.18);
    var x: usize = 0;
    while (x < r.w) : (x += 1) {
        const b0 = x * peaks_mod.BUCKETS / r.w;
        const b1 = @max(b0 + 1, (x + 1) * peaks_mod.BUCKETS / r.w);
        var lo: f32 = 0;
        var hi: f32 = 0;
        for (b0..@min(b1, peaks_mod.BUCKETS)) |b| {
            lo = @min(lo, pk.mins[b]);
            hi = @max(hi, pk.maxs[b]);
        }
        const up: usize = @max(1, @as(usize, @intFromFloat(@round(std.math.pow(f32, @min(1, hi * gain), WAVE_GAMMA) * steps))));
        const dn: usize = @max(1, @as(usize, @intFromFloat(@round(std.math.pow(f32, @min(1, -lo * gain), WAVE_GAMMA) * steps))));
        const in_loop = x >= loop_x0 and x < loop_x1;
        const gnd = if (in_loop) loop_ground else ground;
        const ink = if (head) |h| (if (x == h) theme.accent_pink else if (x < h) theme.accent_hot else theme.text_dim) else theme.accent;
        // upper half: row k above the zero line holds eighths 8k+1 .. 8k+8
        var k: usize = 0;
        while (k < half_rows) : (k += 1) {
            const fill = @min(8, up -| k * 8);
            const y = zero_y - 1 - k;
            if (fill == 0) {
                c.put(r.x + x, y, ' ', ink, gnd);
            } else c.put(r.x + x, y, 0x2580 + @as(u21, @intCast(fill)), ink, gnd);
        }
        // lower half: the top `fill` eighths of the cell are wave
        k = 0;
        while (k < half_rows) : (k += 1) {
            const fill = @min(8, dn -| k * 8);
            const y = zero_y + k;
            if (fill == 0) {
                c.put(r.x + x, y, ' ', ink, gnd);
            } else if (fill == 8) {
                c.put(r.x + x, y, 0x2588, ink, gnd);
            } else c.put(r.x + x, y, 0x2580 + @as(u21, @intCast(8 - fill)), gnd, ink);
        }
    }
}

// ================================================================ helpers

/// Combining marks (macOS stores names decomposed: "o" + U+0308) are
/// dropped so one letter stays one cell.
fn isCombining(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x20D0 and cp <= 0x20FF) or (cp >= 0xFE20 and cp <= 0xFE2F);
}

/// Draw UTF-8 `s` at most `max` cells wide, an ellipsis when cut. Returns
/// the cells used. Bytes that are not UTF-8 show as '?'.
pub fn text(c: *TextCanvas, x: usize, y: usize, s: []const u8, max: usize, fg: Rgb, bg: Rgb) usize {
    if (max == 0) return 0;
    const total = cellCount(s);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        var cp: u21 = '?';
        if (i + len <= s.len) cp = std.unicode.utf8Decode(s[i .. i + len]) catch '?';
        i += if (i + len <= s.len) len else 1;
        if (isCombining(cp)) continue;
        if (total > max and n + 1 == max) {
            c.put(x + n, y, 0x2026, fg, bg);
            return n + 1;
        }
        if (n >= max) break;
        c.put(x + n, y, cp, fg, bg);
        n += 1;
    }
    return n;
}

/// Like `text`, but a cut keeps the END (paths: the folder you are in
/// matters more than where it lives).
fn textTail(c: *TextCanvas, x: usize, y: usize, s: []const u8, max: usize, fg: Rgb, bg: Rgb) usize {
    const total = cellCount(s);
    if (total <= max) return text(c, x, y, s, max, fg, bg);
    if (max < 2) return 0;
    // skip cells from the front until the rest fits after the ellipsis
    var skip = total - (max - 1);
    var i: usize = 0;
    while (i < s.len and skip > 0) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        var cp: u21 = '?';
        if (i + len <= s.len) cp = std.unicode.utf8Decode(s[i .. i + len]) catch '?';
        i += if (i + len <= s.len) len else 1;
        if (!isCombining(cp)) skip -= 1;
    }
    c.put(x, y, 0x2026, fg, bg);
    return 1 + text(c, x + 1, y, s[i..], max - 1, fg, bg);
}

fn cellCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        var cp: u21 = '?';
        if (i + len <= s.len) cp = std.unicode.utf8Decode(s[i .. i + len]) catch '?';
        i += if (i + len <= s.len) len else 1;
        if (!isCombining(cp)) n += 1;
    }
    return n;
}

pub fn tildePath(path: []const u8, home: []const u8, buf: []u8) []const u8 {
    if (home.len > 1 and std.mem.startsWith(u8, path, home) and
        (path.len == home.len or path[home.len] == '/'))
    {
        return std.fmt.bufPrint(buf, "~{s}", .{path[home.len..]}) catch path;
    }
    return path;
}

/// Row length: "0.61s", "4.13s", "12.3s", "1:21".
pub fn fmtDur(secs: f64, buf: []u8) []const u8 {
    if (secs < 10) return std.fmt.bufPrint(buf, "{d:.2}s", .{secs}) catch "";
    if (secs < 60) return std.fmt.bufPrint(buf, "{d:.1}s", .{secs}) catch "";
    const s: u64 = @intFromFloat(secs);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

/// Readout: "0.613 s", "12.30 s", "1:21.4".
fn fmtClock(secs: f64, buf: []u8) []const u8 {
    if (secs < 10) return std.fmt.bufPrint(buf, "{d:.3} s", .{secs}) catch "";
    if (secs < 60) return std.fmt.bufPrint(buf, "{d:.2} s", .{secs}) catch "";
    const s: u64 = @intFromFloat(secs);
    const tenths: u64 = @intFromFloat(@mod(secs, 1.0) * 10);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}.{d}", .{ s / 60, s % 60, tenths }) catch "";
}

fn humanSize(n: u64, buf: []u8) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "";
    if (n < 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / 1024}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / (1024 * 1024)}) catch "";
}

test "fmtDur" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0.61s", fmtDur(0.613, &b));
    try std.testing.expectEqualStrings("12.3s", fmtDur(12.34, &b));
    try std.testing.expectEqualStrings("1:21", fmtDur(81.6, &b));
}
