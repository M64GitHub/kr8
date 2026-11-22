# kr8 — design

**kr8** ("crate", as in crate digging; the 8 nods to the M8) is a keyboard-driven terminal sample
browser for a tracker live set (2× M8, Game Boy/LSDj, DUET). Browse, audition with one key, tag,
find across folders, copy into a set, cut loops out of long samples. Zig 0.15.2 on movy (v0.3.1,
pinned like qartz). macOS first; keep Linux building (bbox).

Repo: github.com/M64GitHub/kr8 (private, GPL-3.0). Status (2026-11-22): **steps 1-5 built** (browse + listen, copy, the library, find, the detail
view): `kr8 [DIR...]`, linked as `~/bin/kr8`. Next: step 6 (the extras pool).

## 1. The library (scanned 2026-11-22)

First root: `~/TRACKBASE/samples/trackers` — the working set for M8 and DUET.
Later root: `~/TRACKBASE/samples` (39 GB, bought collections: Ghosthack packs, SINGULARITY, …) —
the "dig through what I bought, keep the good ones" case.

| | trackers/ |
|---|---|
| size | 3.1 GB, 11,087 files, 491 dirs, max depth 7 |
| WAV | 10,819 — every one a valid RIFF/WAVE |
| other | 129 `.pti` (Polyend instruments), 65 `.mtp`, 12 `.m8i`, 5 `.m8s`, a few pdf/txt |
| formats | PCM 16-bit 7,791 · PCM 24-bit 3,021 · float32 6 — 44.1 kHz almost all, 101× 48k, 1× 96k, 4× 44117 Hz |
| channels | mono ~7,700 · stereo ~3,100 |
| length | < 0.5 s: 4,786 · 0.5–2 s: 2,763 · 2–10 s: 2,804 · ≥ 10 s: 466 · median 0.61 s · max 81.6 s |
| chunks | `smpl` 1,348 (loop points / root note) · `inst` 521 · `clm ` 201 (Serum wavetables) · `cue ` 51 · `id3`/`ID3` 2,015 · `bext` 1,094 |
| duplicates | 265 groups, 266 redundant copies (identical audio data) — mostly `Scanner/Step Kits` vs `Scanner/Scanner 16 bit mono`, and the single-cycle waveform packs |
| BPM in path | 259 files |

Consequences:
- v1 reads **WAV only**: PCM 16/24/32, float 32, `WAVE_FORMAT_EXTENSIBLE`, any rate, mono/stereo.
  No AIFF/FLAC/MP3 needed for this root. Unknown files are listed dimmed and are copyable, not playable.
- Files are small (median 0.6 s), so waveforms are computed **on demand** from the file (+ an
  in-memory LRU), not stored in the database.
- The `smpl` loop points and root note are worth reading at scan time: show ↻ and loop the preview.
- `clm ` marks a Serum wavetable → `is:wavetable`.
- A full scan (hash every data chunk) of 3.1 GB takes seconds; rescans skip files whose size+mtime
  are unchanged.

## 2. Settled decisions

- **Tags belong to the sound, not the path.** A sound's identity is `(data length, wyhash64 of the
  data chunk bytes)` — the audio only, so tools rewriting ID3/bext don't change it. Tags and notes
  attach to the sound. Consequences: moves in Finder heal on rescan; copies share tags; duplicates
  are visible (`×2`). Editing audio makes a new sound — when kr8 writes the edit it copies the tags.
- **kr8 never modifies or deletes a source file.** It only creates new files (copy, export, write range).
- **Letters are commands.** Filtering is `/` (DUET's dialog types to filter; kr8 doesn't).
- **`Tab` switches panes** (Norton Commander). The favorites dropdown moves to `F`.
- **`1-8` are favorites**, same muscle memory as qartz/DUET. A favorite holds a folder or a saved query.
- **Choose once, repeat with one key** — for the copy target and the armed tag alike.
- Database: `~/.config/kr8/kr8.db` (sqlite, compiled in from the amalgamation). UI state
  (favorites, armed tag, copy target, pane dirs, theme) in `~/.config/kr8/config.zon`, like DUET/qartz.
  `KR8_HOME=<dir>` moves both, so tests never touch the real ones.
- Paths are stored relative to named roots, so a moved mount point or bbox needs one root edit.
- Written audio is always 16-bit WAV at the source rate and channel count.
- **Matching is exact, never fuzzy** (m64, 2026-11-22): every space-separated word must be a
  case-insensitive substring of the name. Applies to the pane filter `/` and to library search.
- **AUTO stops on leave** (m64): with AUTO on, the cursor landing on a WAV plays it; moving off the
  playing file stops it (onto a folder = silence). With AUTO off, a SPACE-started preview keeps
  playing while you browse. ENTER replays from the start.
- **Placeholder loops are no loops**: a `smpl` loop counts only if it lies inside the data and is not
  the whole file. trackers/ has zero real ones (746 run past the end, 45 span the whole file).
- **Playback streams from disk** (miniaudio `ma_sound` in STREAM mode): long samples (`~/TRACKBASE/
  samples` has many breaks and long files) cost no RAM; waveforms decode on a worker thread.

## 3. Screen

```
╭ 1  ~/samples/drums/loops ──────────────╮╭ 2 ● ~/m8/live-set/drums ────────────╮
│ ▸ ../                                  ││ ▸ ../                               │
│ ▸ breaks/                              ││   amen_cut_01.wav         1.2s      │
│ ▸ house/                               ││   kick_dark.wav           0.4s      │
│   loop_120_dusty.wav     3.9s  dusty   │├ 3  ? kick dark -used <1s ───────────┤
│ ▶ loop_124_shuffle.wav ↻ 4.1s  set-dec ││   808_long.wav   drums/808/   0.9s  │
│   loop_128_tight.wav     3.7s  ×2      ││   bd_hard.wav    one-shots/   0.2s  │
╰────────────────────────────────────────╯╰─────────────────────────────────────╯
 ▁▂▅█▇▅▃▂▁▂▅█▇▅▃▁▂▅█▇▅▃▁  loop_124_shuffle.wav  44.1k 16bit st 4.1s   ▶ 1.3s
 tags: groove set-dec  · note: from the 2019 tape session, nice swing
 SPC play  a auto  t tag  x set-dec  c copy→2  / filter  f find  ? help
```

- **Panes**: 1–4. Auto-layout: 1 = full; 2 = side by side; 3 = left full height, right split;
  4 = 2×2. `z` zooms the focused pane (tmux-style). Title: number, `●` on the copy target, the path
  (shortened from the left) or `? query`.
- A pane is a **DIR pane** (a folder: dirs first, then files) or a **QUERY pane** (search results
  across the library, folder shown dim). Both play, tag, copy and mark the same way.
- Row: name, ↻ (has loop points), duration, first tags, `×N` (duplicates).
- **Info strip** (bottom): format line, waveform with playhead, key hints. The strip's waveform is
  drawn in **eighth blocks** (8 steps per row, negative half inverted), not the pixel layer: half
  blocks gave 2 steps per row and a break looked like a flat line at 3 rows. 4-8 rows (an even number)
  by terminal height. The pixel layer (glow) is kept for the full-screen detail view (step 5).
- Drawing happens only when something changed (keys, playback at 30 fps, status fade, a waveform
  arriving): measured 0.4 % CPU idle, 1.4 % playing (kitty 4.4 %).

## 4. Keys (draft)

| key | action | key | action |
|---|---|---|---|
| `j k` `↑ ↓` `PgUp PgDn` | move | `SPC` | play / stop |
| `Enter` `l` | open folder / detail view | `a` | auto-audition on/off |
| `Bksp` `h` | parent folder | `L` | loop preview on/off |
| `Tab` `S-Tab` | next / previous pane | `t` | tag picker (fuzzy, multi-toggle, create) |
| `n` / `q` | new pane / close pane | `x` | toggle armed tag, move down |
| `z` | zoom pane | `e` | edit note (one line) |
| `1-8` / `F` | favorite / favorites dropdown | `c` / `C` | copy to target, move down / pick target |
| `/` | filter this pane (fuzzy) | `v` | mark, move down (`c`, `x`, `t` act on marks) |
| `f` | find in library → query pane | `E` | export pane (all results) to target |
| `?` | help | `T` | cycle theme |

Copy target: with 2 panes it is the other one; with 3–4 the first `c` asks "1 / 2 / 3 / 4?" and
remembers (saved in the config). Name collisions get `_2`, `_3`. Built as specified, plus:
- a single-file `c` moves the cursor down (AUTO plays the next one); a marked `c` clears the marks
- marks survive a filter: the pane's bottom edge shows `N marked` even when the filter hides them
- copies run on a worker thread (`copier.zig`), progress in the bar; the destination pane reloads and
  its cursor lands on the new file. A pane showing the source folder can't be the destination.
- `c` copies files only; a folder: open it, `V` marks everything.
- `?` is a full help page (one page, sections, scrolls; `j k` / `pgup pgdn` / `g G`), duet-style.
- Panes show a scrollbar thumb on their right border when the list is longer than the pane.
- `M` / `F7` (Norton Commander's key): new folder in the focused pane; refuses `/` and leading `.`
  (dot folders are hidden), an existing name just puts the cursor on it.

## 5. Workflows this must make fast

1. **Get to know trackers/**: `a` on, `j j j`, `x` on the good ones (armed tag `good`).
2. **Collect for a project**: `t proj-x ↵` arms the tag; browse with `x`; at the end `f #proj-x`,
   `E` to a folder (M8 SD card). The tag is the crate.
3. **Dig the bought collections**: left pane in `~/TRACKBASE/samples/Ghosthack…`, right pane
   `trackers/<dest>` as target; `c` copies and moves on. Tags made while digging travel along.
4. **Cut a loop**: `Enter` on a long sample, set in/out, snap to zero, `L`, `w` writes it next to the
   target pane.

## 6. Search syntax (built, step 4)

`f kick dark -used <1s`

- bare word: the PATH (folders + file name, relative to its root), a tag or the note contains it
  (case-insensitive substring - exact, never fuzzy); `-word` negates. Folder names count because
  packs sort by folder (`kick` finds `Techstep Kicks/BD_01.wav`) - so `in:` was dropped.
- `#tag`: exactly this tag; `-#tag`
- `<1s` `>2s` `<500ms`: duration
- `is:dupe` · `is:mono` · `is:stereo` · `is:tagged` · `is:untagged` · `is:noted` · `is:loop` ·
  `is:wavetable` (`is:lost` dropped: a lost sound has no file to list)

## 7. Data model

```sql
root      (id, name UNIQUE, path)
sound     (id, dlen, dhash, frames, rate, bits, channels, fmt,
           loop_start, loop_end, root_note, flags,       -- flags: wavetable, …
           UNIQUE(dlen, dhash))
file      (id, root_id NULL, relpath, size, mtime_ns, sound_id,
           UNIQUE(root_id, relpath))                     -- root_id NULL: indexed alone, relpath absolute
tag       (id, name UNIQUE COLLATE NOCASE)
sound_tag (sound_id, tag_id, added, PRIMARY KEY(sound_id, tag_id))
note      (sound_id PRIMARY KEY, text, updated)
```

- **Scan** (background thread, the UI stays live): walk the roots; unchanged size+mtime → skip; else
  parse chunks, hash the data chunk, upsert sound and file. File rows not seen are dropped; sounds
  are kept even without files (`is:lost`), so tags come back when a drive is plugged in again.
- Tagging a file outside every root indexes that file alone.

## 8. Detail view (`l` / right on a file; full screen; `Esc` back) - built, see step 5

Big zoomable waveform with playhead. `[` `]` set in/out, `SPC` plays the range, `L` loops it,
`+ -` zoom, `0` snaps in/out to zero crossings, `w` writes the range (suggested `name_01.wav`, into
the target pane's folder; tags copied). Shows range length and a BPM guess for 1/2/4 bars.

## 9. Reuse

- DUET / qartz `src/app`: `term.zig`, `event.zig`, `config.zig`, `ui/canvas.zig`, `ui/widgets.zig`,
  `ui/theme.zig`, `ui/motion.zig`, `ui/filedialog.zig` (fuzzy matcher + favorites), the headless
  `--dump-screen` / `--keys` / `--shot` test loop. Keep lifted files recognisable so fixes carry over.
- DUET: `src/app/ma_shim.c` (miniaudio), `src/audio/wav.zig` reader, `src/app/wavfile.zig` writer.
- remembra `src/sqlite.zig`: the wrapper shape; kr8 compiles the amalgamation instead of linking the
  system lib (as qartz compiles libusb in).
- qartz lessons: no kitty keyboard protocol; ASCII-only in `putStr`; macOS 26 SDK + Zig 0.15 link
  workaround for release builds.

## 10. Build order (each step usable on its own)

1. ~~**Browse + listen**: panes and auto-layout, folders, favorites, `/` filter, `SPC`, auto-audition,
   loop preview, info strip with waveform.~~ Done 2026-11-22 (+ `-`/`+` preview volume, `T` themes).
2. ~~**Copy**: target pane, marks, collisions.~~ Done 2026-11-22 (+ scrollable `?` help page).
3. ~~**Database**: roots, background scan, fingerprints, tags (picker, armed tag), notes, `×N`.~~
   Done 2026-11-22. Decisions (m64): the db is `~/.config/kr8/kr8.db`; tagging works anywhere (files
   outside roots are LOOSE rows, adopted when a root covers them); roots are managed on the command
   line (`kr8 root add|rm|list`, `kr8 scan`, `kr8 tags`). Built:
   - SQLite 3.50.4 amalgamation compiled in (build.zig.zon `sqlite`); WAL; UI and scanner each own a
     connection. `sqlite_shim.c` binds text with SQLITE_TRANSIENT (Zig can't spell it).
   - Scanner (`src/db/scanner.zig`): walk, skip unchanged size+mtime, fingerprint the rest, commit
     every 400 files (the panes refresh as it goes), drop rows of files gone (only for roots walked
     completely). Runs at every kr8 start in the background. Measured on trackers/: first scan
     10,823 files in 5.9 s (10,553 sounds, 269 with copies), rescan 0.1 s, db 3 MB.
   - `root add` refuses a folder inside a root and ABSORBS roots inside the new one (rows re-pointed,
     no rehash) and adopts loose files. A file renamed behind kr8's back keeps its tags (verified).
   - UI: `t` picker (type filters / names a new tag; a typed space becomes `-`; enter toggle+arm+close,
     tab toggle+stay, shift-tab arm only), `x` toggles the armed tag (shown in the bar; no armed tag =
     the picker opens), `e` one-line note. Targets = the pane's marks, else the cursor WAV. Rows: tags
     (green), `×N` copies, `¶` note; a second info row: tags · copies · note. Folders show their
     WAV/folder counts in the info row.
4. ~~**Find**: query panes, search syntax, saved queries as favorites, export.~~ Done 2026-11-22:
   `f` turns the focused pane into a SEARCH PANE (live match count while typing; at most 5000 hits),
   hits show their folder dim; `bksp` returns to the folder (after a restart: the first root), `o`
   opens a hit's folder, `r` searches again, `E` exports everything shown (confirm). Searches are
   PLACES (`?query`): favorites and the session store them like folders. A search pane is never a
   copy destination. Also fixed: miniaudio's resource manager decoded at the DEVICE rate, so the
   playhead/readout ran 9 % fast on 44.1 kHz files at a 48 kHz Mac (and smpl loop points would have
   been off) - now it decodes at the file's own rate (regression test in audio.zig).
5. ~~**Detail view**: waveform zoom, range, snap, loop, write WAV.~~ Done 2026-11-22. `l` / right on
   a WAV opens it (ENTER stays "replay": m64 uses it); esc / q goes back. The file is decoded into a
   mono mix (draw + zero crossings; max ~11 min); the waveform is the movy pixel layer (glow, range
   wash, pink in/out markers, white cursor, glowing playhead trail; scanlines softened to 0.9). Keys:
   arrows move (shift 10x, ctrl half a view), up/down zoom around the cursor, `[` `]` range, `0`
   snaps to zero crossings, space plays the range (miniaudio data-source range, sample-exact; LOOP
   loops it; moving an end while it plays restarts it), enter plays from the cursor, `z`/`Z` fit,
   `w` writes the range as 16-bit WAV (target pane's folder, else next to the source; `_cutNN`,
   never overwrites) and the cut inherits the source's tags. Readout: range, length, bpm guess
   (1/2/4/8 bars or a beat landing in 70-190). Measured while looping: kr8 5 %, kitty 12 % (30 fps).
6. Later: BPM from names, `kr8 find|export` CLI, `.pti` preview, LSDj kit builder, M8 slice points.

## 11. Open questions

- Fingerprint by content is assumed OK (copies share tags). Revisit if a copy ever needs its own tags.
