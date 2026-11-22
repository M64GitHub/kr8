# kr8 — notes for Claude

Keyboard-driven terminal sample browser (browse, audition, tag, find, copy, cut loops) for m64's
tracker live set. Zig 0.15.2 + movy v0.3.1. **Read `DESIGN.md` first** — it holds the agreed design,
the library facts and the build order.

## Layout

- `src/audio/`: `shim.c` (miniaudio compiled once, as C: streaming player with 2 voice slots for
  click-free stops, + peak decoding), `audio.zig` (its externs), `wav.zig` (RIFF header reader:
  fmt/data/smpl/inst/clm), `peaks.zig` (waveform worker thread + LRU; `sync` when headless).
- `src/app/`: `app.zig` (60 fps loop, keys, playback rules, draws only when dirty), `pane.zig` (a
  folder: natural sort, word filter, cursor), `view.zig` (bar, auto-tiled panes, info strip,
  eighth-block waveform, help page, overlays), `config.zig` (`~/.config/kr8/config.zon`,
  `KR8_HOME`), `copier.zig` (the copy worker thread: never overwrites, `_2` names; headless runs
  `waitIdle()` each frame so dumps are deterministic).
- `src/db/`: `sqlite.zig` (+ `sqlite_shim.c`), `library.zig` (schema, roots + absorb, Indexer,
  lookups/Facts, tags, notes), `scanner.zig` (thread + `scanAll`). `src/cli.zig`: `root`/`scan`/`tags`.
- Lifted from qartz (from DUET): `term.zig`, `event.zig`, `ui/canvas.zig`, `ui/widgets.zig`,
  `ui/theme.zig`, `ui/motion.zig`.

## Rules

- **Never modify, move or delete anything under the sample roots** (`~/TRACKBASE/samples/...`).
  kr8 only creates new files. Tests copy samples into the scratchpad first.
- Tests and screenshots set `KR8_HOME=<scratch dir>` so they never touch `~/.config/kr8/`
  (the real tag database).
- Lifted DUET/qartz files (`term`, `event`, `config`, `canvas`, `widgets`, `theme`, `motion`,
  `filedialog`) stay recognisable so fixes carry over. Their known gotchas apply: no kitty keyboard
  protocol, ASCII-only `putStr`.
- Sources to lift from: DUET `~/m64/space_64/duetracker`, qartz `~/space/64/qartz`,
  remembra `~/m64/space_ai/remembra/src/sqlite.zig`.

## Verify

- `zig build test`: wav header (incl. placeholder loops), natural sort, word filter, marks, copier
  (real copies into a tmp dir, no-overwrite naming), formats.
- Copy tests read from the sample roots but always WRITE into a scratch folder (a pane on it).
- Library tests: `KR8_HOME=<scratch> kr8 root add ~/TRACKBASE/samples/trackers` builds a scratch
  library from the real samples (read only, ~6 s); headless runs then join the start-up scan, so
  `--keys "2:t,3:text=good,4:enter,5:x"` and `kr8 tags` are deterministic. Absorb/adopt/rename
  tests: copy a few WAVs into a scratch folder and root it there. NEVER root-add the real
  `~/.config/kr8` from a test.
- Text layer, scripted: `KR8_HOME=<scratch> kr8 --dump-screen --size 120x36 --frames N --keys
  "2:j,3:enter,4:/,4:text=kick" DIR...` (headless = no audio; peaks decode synchronously).
- Real look + CPU: `tools/look.sh OUT.png SECS "KEYS" DIR...` opens a kitty window at `--volume 0`
  (silent, but playback really runs: the playhead moves), screenshots it, prints kr8's and kitty's
  CPU. Never play audible sound in tests: always `--volume 0`.
- `pgrep -f kr8` also matches the kitty window running it; match the binary path (`^.../bin/kr8`).
