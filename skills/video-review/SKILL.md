---
name: video-review
description: Use when reviewing a video clip or screen recording — game client footage, bug repros, UI captures — or when asked what happens in a recording. Builds a labelled contact sheet to locate the moment, then extracts full-resolution frames to read it. Also screenshots a running application window on macOS or Linux.
---

# Video Review

## Overview

You cannot watch a video. You can look at images. This skill turns a clip into images that answer
questions about it, in two stages:

1. **Locate** — a contact sheet of N timestamped frames, sized to be read in one look.
2. **Read** — a full-resolution frame (optionally cropped) at the timestamp the sheet identified.

Doing only stage one and guessing at detail is the failure mode this exists to prevent. The sheet
tells you *when*; it is too small to tell you *what*. Go back for the frame.

## The instrument lies, and it lies plausibly

Read this before you trust any frame. It is the most expensive failure mode in visual review and
it does not announce itself — a capture that is *wrong* looks exactly like a capture that is
*right*, so the only defence is knowing the shapes it takes.

> **When a measurement and a frame disagree, suspect the instrument before the artifact.**

Three instances of the same failure are now on record here, all of which produced confident,
entirely wrong conclusions:

| The lie | What it looks like | Detail |
|---|---|---|
| **Camera angle** | motion along the view axis vanishes — a limb rotated toward the lens foreshortens to a stub and reads as "it never animated"; a dash straight at camera reads as standing still | below |
| **Brightness normalisation** | a habitual `eq=brightness=` in the extraction pipeline makes a too-dark build look fine for a whole session | Godot MCP section |
| **Wrong surface captured** | a locked screen, the desktop wallpaper, or the editor's frame instead of the game's | Window capture + platform sections |

The tell is always the same: an image that answers your question a little too cleanly, disagreeing
with something you measured. **Go check the instrument.** Re-frame from another angle, pull an
unprocessed frame, confirm the window id.

**Camera angle, concretely.** Judge limb and body poses from **3/4 or side**, never front-on. This
trap produced two separate fictional bug reports in one session (2026-08-07) — "the legs never
animate", then "the thigh mesh collapses" — while the measured joint positions matched the source
application to the millimetre both times. The numbers were right and the viewing angle was lying.
Cross-check by converting a measured quantity into the other application's coordinate convention
and comparing; agreement to a millimetre means the artifact is fine and your view is bad.

## Scripts

All under `${CLAUDE_SKILL_DIR}/scripts/` (Claude Code substitutes that placeholder when the skill
loads; the examples below abbreviate it to `scripts/`), all cross-platform (macOS and Linux), all
print their output path on stdout so you can chain them.

```bash
scripts/verify-tools.sh                       # is this machine set up? non-zero if not
scripts/clip-sheet.sh CLIP.mp4                # -> CLIP-sheet.png, 16 frames, ~1500px wide
scripts/frame-at.sh CLIP.mp4 11.25            # -> full-resolution frame at 11.25s
scripts/grab-window.sh --list                 # what windows are open
scripts/grab-window.sh "Godot"                # -> window-Godot.png
```

Useful flags:

```bash
clip-sheet.sh CLIP.mp4 --crop 700x500+1100+200  # crop each frame BEFORE tiling -- see below
clip-sheet.sh CLIP.mp4 -n 25                    # denser sample for a long or busy clip
clip-sheet.sh CLIP.mp4 --start 8 --end 14       # zoom the sampling into a narrow window
frame-at.sh CLIP.mp4 11.25 --crop 700x500+1100+200   # zoom a HUD corner
frame-at.sh CLIP.mp4 11.25 --scale 1200         # shrink an oversized frame
```

### Crop before tiling, almost always

Tiling untouched 1080p frames 4-across leaves the subject a few pixels tall and the sheet tells you
nothing. Crop to the thing you are judging first. On the game this was built for, that is what
turned a useless sheet into the one that found the unreachable-stride bug.

Get the crop region from one full frame: `frame-at.sh CLIP.mp4 5` then read it, estimate the box,
and pass it to `clip-sheet.sh --crop`.

## The loop

```bash
scripts/clip-sheet.sh clip.mp4        # then Read the PNG it prints
# identify the interesting tile by its timestamp label, say 0:11.25
scripts/frame-at.sh clip.mp4 11.25    # then Read that PNG
# still not enough detail? crop into it
scripts/frame-at.sh clip.mp4 11.25 --crop 800x600+900+300
```

When the thing you are looking for happens fast, re-sheet the narrow range rather than raising
`-n` over the whole clip: `--start 10 --end 13 -n 16` gives 16 frames across 3 seconds.

For a summary of the file itself — codec, resolution, frame rate, duration — use `mediainfo CLIP.mp4`.

**Gameplay captures: the first unplayable frame ends the reviewable portion.** If the subject
fell out of the world, wedged in geometry, or otherwise left a playable state, everything after
that frame is noise — never "more data". Stop reviewing there and branch: capture harness at
fault → guard/shorten the capture (a self-driving capture should detect the unplayable state at
runtime and quit with a diagnostic, not record dead time for a reviewer to find); game at fault
→ that IS the finding, fix the defect before re-rendering.

## Reviewing screencasts and tutorials (YouTube, editor recordings)

Screencasts differ from gameplay clips: most frames are static UI, the payload is text plus
occasional motion, and there is often a transcript and a companion repo that beat frames
entirely. The study loop that orders those sources — transcript first, then repo, then frames
for what only frames show — and the download and transcript mechanics behind it live in the
`studying-tutorial-videos` skill (`study.py admit <url>` runs them; its *Downloading and
transcripts* section is the troubleshooting). This skill keeps the two image techniques that
static-heavy recordings need.

**Finding the moments in a static-heavy recording — RMSE diffing.** Extract 1–2fps frames, then
diff consecutive pairs:

```bash
compare -metric RMSE prev.jpg cur.jpg null: 2>&1   # first number: ~<300 static, >3000 transition
```

Plateaus of low values = stable states (grab ONE full-res frame each); spikes = scrolls, tab
switches, dialogs. This separates "48 frames" into "5 distinct editor states" and is far faster
than reading tiles. The same trick locates motion in gameplay clips.

**Font-free contact sheets.** ImageMagick `montage` needs a font for labels and Homebrew ships
none registered (the scripts here solve that via `resolve_im_font`, but direct invocation hits
``unable to read font `'``). ffmpeg's tile filter needs nothing and does the whole pipeline in
one pass — sample, crop, shrink, tile:

```bash
ffmpeg -ss 470 -t 15 -i clip.mp4 -vf "fps=2,crop=1270:680:273:125,scale=300:-1,tile=6x5" \
  -frames:v 1 -q:v 2 sheet.jpg
```

No timestamp labels — compute them from start + index/fps. Crop to the region that matters
before tiling, same rule as `clip-sheet.sh --crop`: for editor recordings that's the viewport
(drop the docks), or *just* the Inspector column (~380px wide strip at the window's right edge)
when the question is a property value — a full-res Inspector crop is readable where a whole-frame
tile is not.

## Sizing: why ~1500px, and don't raise it

The default sheet width is 1500px because that is roughly the largest image that reaches you
without being downscaled. A 4K contact sheet is *worse* than a 1500px one: it gets resized before
you see it, and small UI text turns to mush in the process. Raising `-w` to "get more detail" makes
the sheet less readable, not more.

Detail comes from stage two, at full resolution, not from a bigger grid.

## Window capture

`grab-window.sh` attaches to a window that is **already open**. It never launches anything; start
the application first (for Godot, `play_scene` or the movie driver — running the game is routine,
per that project's canonical-core).

On macOS it resolves window geometry with `window-id.swift` (compiled on first use into
`~/.cache/video-review/`, ~10s once) and captures that screen region with `screencapture -R`. The
helper reads CoreGraphics directly, so **no Accessibility permission is needed**. Because capture
is by region, **anything overlapping the window lands in the shot** — make sure the target is
frontmost and unobstructed, or pass `--activate` to bring it forward (this steals focus and may
switch Spaces).

On Linux it captures by window id via `maim -i`, which reads that window's own contents. That is
not a detail: **the desktop there is usually locked**, and coordinate-based capture
(`ffmpeg -f x11grab`, or a region screenshot) records the screen locker instead of the game.

**A Godot game under the editor exposes two windows with the same title** — the viewport and the
editor's embedded-game frame. `grab-window.sh` refuses to guess: it lists both with their geometry
and asks for `--id`. The viewport is the one whose size matches the run resolution. Window ids
change every run, so never reuse one from an earlier session.

### Godot via MCP: `get_game_screenshot`

This subsection assumes a Godot editor MCP bridge that exposes a screenshot call; nothing else in
this skill needs one, and the brightness lesson at the end applies to every capture path.

For a Godot project with the editor running, `mcp__godot__get_game_screenshot` needs no window
plumbing at all — no X11, no Screen Recording permission, works with the desktop locked. Learned
in practice (2026-08-04, verifying gait changes from live frames):

- **It requires `play_scene` first** and captures the running game, full render resolution.
- **`save_path` cannot create directories.** `res://some-new-dir/x.png` fails with a bare
  "Can't open file"; a flat `user://x.png` always works. `user://` resolves to
  `~/Library/Application Support/Godot/app_userdata/<Project Name>/` on macOS
  (`~/.local/share/godot/app_userdata/<Project Name>/` on Linux) — copy the files out from there.
- **Burst rate over MCP is ~1–2 frames/sec.** Pair with `Engine.time_scale = 0.5` (or lower) in
  the game so a burst still resolves a motion cycle — the MCP equivalent of the `maim` burst.
- **No input-simulation tool? Script the choreography.** A throwaway scene — the real zone + the
  player + a driver script calling `Input.action_press("move_right", strength)` on timers — makes
  any repro fully autonomous. The `strength` argument doubles as a speed limiter so slow captures
  still catch mid-motion frames. Delete the scene after; it is a test fixture, not content.
- **Judge exposure/look at NATIVE brightness.** A habitual `eq=brightness=...` in the frame
  extraction pipeline (added so dark frames are readable) silently masks how dark the game
  actually renders — an entire session of "looks fine" frames hid a lighting problem the player
  saw immediately. Boost for *reading* structure; always pull an unboosted frame before judging
  *presentation*.
- **For motion, skip screenshots entirely: Godot Movie Maker mode.** Verified far superior for
  transients (a landing, a spring settle) that a 1–2fps burst always misses:

  ```bash
  <godot> --path game res://path/TestScene.tscn --write-movie /abs/out.avi --fixed-fps 60
  ```

  Renders EVERY engine frame offline (~30% realtime) — full temporal resolution, deterministic,
  needs no Screen Recording permission and no window plumbing; works with the driver-script
  pattern above (end the driver with `get_tree().quit()` or it records forever). **macOS
  occlusion trap:** if the game window is covered during the render, the compositor stops
  redrawing and the movie silently fills with duplicates of the last frame while the sim runs on
  — set `window/size/always_on_top=true` for the render (revert after), and RMSE-diff two
  distant frames (0 = frozen) before trusting any long capture. The full driver harness
  (architecture, liveness guards, more traps) lives in the `godot-movie-driver` skill. The output is
  plain MJPEG — contact-sheet it as usual, and for quantitative motion (did the body overshoot?
  what's the oscillation period?) threshold a bright channel per frame and trace the subject's
  extremal row: measured period vs. designed period is a real verification, not an eyeball.

### macOS: Screen Recording, and the wallpaper trap

**Without Screen Recording permission, macOS does not fail. It returns a picture of the desktop
wallpaper, with exit code 0.** Every other app's window is invisible to the capture. This is the
single most expensive failure mode in this toolchain — it looks like a working screenshot of the
wrong thing, and it will happily fool you for an hour.

Three symptoms, all the same cause:

| Symptom | Looks like | Actually is |
|---|---|---|
| Capture shows only wallpaper | Window on another Space | No Screen Recording |
| `screencapture -l <id>` → `could not create image from window` | macOS 15 removed window capture | No Screen Recording |
| Every window title from `--list` is empty | Helper bug | No Screen Recording |

`grab-window.sh` now preflights this via `CGPreflightScreenCaptureAccess()` and refuses up front,
so you should never see the wallpaper result again. To check by hand:

```bash
~/.cache/video-review/window-id --check-perms   # prints granted / denied
```

Grant it at System Settings → Privacy & Security → **Screen Recording** → enable the terminal app
running Claude Code. **Then fully quit and reopen that app** — a new tab or window is not enough;
macOS only applies the grant on relaunch.

Accessibility is *not* required for capture. It is only needed if the Swift helper is unavailable
and the script falls back to System Events (error `-25211` or `-1743` means it is missing).

## Platform and toolchain gotchas

Learned the hard way on this setup; all are already handled by the scripts, but they explain
otherwise baffling errors if you invoke the tools directly.

- **Homebrew's `ffmpeg` has no `drawtext` filter.** The core formula is built without freetype, so
  burning text into frames fails with `No such filter: 'drawtext'`. Linux distro builds usually
  have it. Annotate with ImageMagick instead — which is what `clip-sheet.sh` does.
- **Homebrew's ImageMagick has zero fonts registered** (no fontconfig), so any `-label` or
  `-annotate` fails with ``unable to read font `'``. It does accept a direct `.ttf` path;
  `lib.sh:resolve_im_font` finds one per platform.
- **ImageMagick 7 vs 6.** Homebrew ships v7, which still installs `convert`/`montage`/`identify`,
  but `convert` prints a deprecation warning on every call. Use `magick` (v7) or the legacy
  binaries (v6) — `lib.sh` resolves this via `im_montage` / `im_identify` / `im_convert`.
- **macOS ships bash 3.2**, where `"${arr[@]}"` on an empty array is an error under `set -u`.
  Array expansions use the `${arr[@]+"${arr[@]}"}` guard.
- **macOS has no `timeout` command.** Don't wrap these in one.

## Setup

```bash
# macOS
brew install ffmpeg media-info imagemagick

# Debian/Ubuntu/Mint
sudo apt install ffmpeg mediainfo imagemagick x11-utils xdotool maim
```

Then `scripts/verify-tools.sh` to confirm.

If `brew` itself dies with a `sorbet-runtime` `LoadError`, its bootsnap cache is stale after an
auto-update: `rm -rf ~/Library/Caches/Homebrew/bootsnap` fixes it.
