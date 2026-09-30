---
name: godot-movie-driver
description: Use after ANY change to movement, animation, camera, physics feel, or gym/test-level geometry in a Godot project, and BEFORE claiming such a change works, looks right, is fixed, or is ready for review. Triggers on - needing to see MOTION rather than a pose (transitions, blends, crossfades, one-shots, timing, settle, overshoot, foot planting, gait, IK); verifying anything sub-second that a screenshot or a 1-2fps screenshot burst physically cannot sample; wanting a reproducible clip or reviewable evidence of a gameplay change; reproducing a movement or animation bug with nobody at the keyboard; capturing a repro for a bug report; or reaching for play_scene / get_game_screenshot / simulate_action to judge how something MOVES. A throwaway self-driving input script plus Movie Maker mode renders every engine frame offline and deterministically. Covers driver architecture, input simulation, reading game state, liveness guards, output resolution, and the render traps (occlusion freeze, stale assembly). THIS IS THE DEFAULT WAY TO LOOK AT A GODOT GAME, for development and debugging alike, not a final check after screenshots - keep using execute_game_script to probe STATE, but anything that moves or changes over time gets a render, because a clip is reviewed as frames anyway and is therefore a strictly better source of them than ad-hoc screenshots.
---

# Godot Movie Driver

## This is the DEFAULT way an agent looks at a game

**Rendering a clip is the first choice for development and debugging alike — not a final
verification step after screenshots.** A standing rule since 2026-08-06, made after watching
agents work both ways.

Draw the line in the right place. It is **not** "live session vs. render":

| Doing | Tool | Why |
|---|---|---|
| Reading **state** — a value, a node path, an enum, is-this-null | `execute_game_script` | Cheap, exact, no substitute. Keep doing this. |
| Trying a value interactively, hunting for a node | live session | Fine. This is poking, not looking. |
| Looking at anything that **moves or changes over time** | **movie driver** | The default. |
| Looking at one genuinely static thing — did the texture load, does the HUD read 42 | screenshot | The narrow exception. |

The distinction is between *probing state* (keep) and *capturing images* (default to the render).

### Why the render, specifically for an agent

**You review a clip as frames anyway** — contact sheet to locate, full-resolution frame to read.
So a clip is not a different medium from screenshots; it is a strictly better *source* of the
same frames: complete temporal coverage instead of whatever moments round-trip latency happened
to land on, deterministic instead of unrepeatable, and reviewable by the human afterwards instead
of a pile of stills only you saw. It is the closest an agent gets to watching the game the way
the person next to it is watching it — which is the whole reason the answers come out different.

Ad-hoc screenshots are dominated on every axis except latency, and the latency saving is false:
the third screenshot costs more than the render would have.

### The failure this prevents

Not disagreeing with the skill — **never thinking of it.** You finish a change, want to check it,
reach for `play_scene` + `get_game_screenshot` because they are one call away, collect a few
static poses, and call it verified. The screenshots are real; the conclusion is unfounded,
because **a pose cannot show a transition.**

Observed 2026-08-06 on a facing-aware idle swap. Live probes confirmed the right clips loaded and
each stance rendered correctly — and could not touch the 0.2s crossfade between two mirrored
stances, which was the entire risk. One render answered it in a pass and incidentally disproved
the premise: the motor crosses the idle speed threshold in ONE physics frame, so the blend being
worried about was unreachable from keyboard input at all. No number of screenshots surfaces that.
The driver's own mode log did, for free — which is the second reason to prefer it: a driver
**logs while it renders**, so you get the state timeline and the footage from one run.

**If the question contains a verb — settles, blends, snaps, slides, plants, overshoots, pops,
reads as — it is a motion question and screenshots are the wrong instrument.** Static frames
answer "what does it look like standing there." Almost nothing worth checking is that.

## Overview

A **driver** is a throwaway GDScript autoload that plays the game itself — teleports to the
scene under test, feeds input on a state machine, prints what it observed, and quits. Rendered
under Movie Maker mode (`--write-movie --fixed-fps 60`) it yields a deterministic, full
temporal-resolution clip that `video-review` turns into evidence. The loop needs nobody at the
keyboard, so "is this fixed?" is answerable in the same turn the change was made.

**Drivers are throwaway; this harness knowledge is not.** Delete the driver after review (it is
a test fixture, not content) — but after the USER's review passes, not your own: a feel-test
defect report reuses the driver, and deleting it at your own sign-off means rewriting it an hour
later. This skill is where the mechanics live so the next driver doesn't
start from archaeology — an entire session was once spent reconstructing this from git history
that turned out to contain no driver at all.

## The loop

```bash
# 1. Write the driver (see architecture below) into <game>/TestDrivers/foo.gd
# 2. ALWAYS build first — the movie process loads the on-disk assembly, not the editor's:
dotnet build <your-game>.sln                 # whatever builds the assembly the game loads
# 3. Render (background it; it runs 0.3–2x realtime). The flag after `--` selects the driver:
<godot> --path game --write-movie /abs/scratch/out.avi --fixed-fps 60 -- --driver=foo
# 4. Review with the video-review skill: contact sheet to locate, full-res frames to judge.
# 5. Delete the driver once the USER's review passes; commit the real change only.
```

**Activate drivers by COMMAND-LINE FLAG, never by a temporary autoload in `project.godot`.**
Add one permanent, debug-gated hook in the main scene that reads the flag and attaches the
driver — everything else stays untouched:

```csharp
// In the main scene's _Ready (Godot C#; GDScript equivalent is the same three steps)
const string Flag = "--driver=";
string? name = OS.GetCmdlineUserArgs().Concat(OS.GetCmdlineArgs())
    .FirstOrDefault(a => a.StartsWith(Flag, StringComparison.Ordinal))?[Flag.Length..];
if (!OS.IsDebugBuild() || string.IsNullOrEmpty(name)) return;
string path = $"res://TestDrivers/{name}.gd";
if (!ResourceLoader.Exists(path)) { /* warn — Load() on a missing path emits a scary
                                      engine ERROR + stack trace for a benign absent fixture */ }
else if (ResourceLoader.Load(path) is GDScript s && s.New().As<Node>() is { } driver) AddChild(driver);
```

Why this matters more than it looks: the autoload approach edits a **tracked** file for every
render, and an open editor re-persists ProjectSettings from its own memory — so a line you
removed comes back, pointing at a driver you deleted after the render (a hard launch error),
and the file's comments are stripped in the same save. The flag has neither failure mode, needs
no cleanup step that can be forgotten, and the identical string works in the editor's
**Run Instances → Main Run Args** field for a hands-on run. Gitignore the drivers directory so
fixtures can never be committed — as a contents glob, not a directory rule, or nothing can be
allowlisted back out of it later:

```gitignore
# A contents glob: git cannot re-include a file whose parent directory is excluded, so
# `TestDrivers/` (the directory form) would make every negation below it silently inert.
game/TestDrivers/*
!game/TestDrivers/StandingDriver.gd   # one line per driver that documentation cites
```

## The log is not debug output — it is half the render

**Log richly, and timestamp everything so log times and frame times can be read against each
other.** This is the part most likely to be treated as an afterthought, and it is the half that
carries what frames structurally cannot.

A human watches the clip continuously. **You reconstruct motion from samples** — a contact sheet
is ~20 moments of a 13-second clip, and a narrowed re-sheet maybe 16 moments of one second.
Anything shorter than your sampling interval is invisible no matter how many frames you pull,
and you cannot know in advance what interval you needed. The log has no such limit: it runs at
the physics rate and records what the *state machine* did, not what the pixels showed.

Both channels, one run — that is what gets an agent close to what the person watching sees.

Worked example, 2026-08-06. The question was whether a crossfade between two mirrored idle
stances looked bad. Frames answered "the turn looks fine." The log answered the real question:

```
t=2.53  tapped move_left (2 frames)
t=2.55  idle_r -> walk   (speed=1.50)
t=2.57  walk   -> run    (speed=3.00)
t=2.60  run    -> idle_l (speed=0.00)
```

The motor crossed the idle threshold in ONE physics frame, so the blend being investigated was
unreachable from keyboard input at all. That is a fact about the state machine; **no sampling
rate would have revealed it from pixels**, and the frames alone would have supported a confident
wrong conclusion ("looks fine") for the wrong reason.

Practical rules:

- Print `DRIVER:`-prefixed lines for every event and grep for them. When stdout is piped the
  output buffers until process exit, so the log is read after the run, not during.
- **Every line carries the driver's own `t`.** Do not correlate against an on-screen clock —
  wall-clock HUD timers desync from movie time (see Render traps).
- Log *state transitions*, not just phase changes: the animation/mode a node switched to, a state
  enum changing, a threshold being crossed. Transitions are where the answers live.
- Include the values that explain the transition (speed, position, grounded) on the same line, so
  a surprising switch is self-diagnosing without a re-run.

## Driver architecture

A phase state machine in `_physics_process`, driving input and observing state:

- **Input:** `Input.action_press("move_right")` / `action_release` for actions the game polls.
  For `_UnhandledKeyInput` listeners (debug teleport keys), synthesize a real key:
  `InputEventKey` with `keycode` + `physical_keycode` set, `Input.parse_input_event(ev)` —
  press and release as two events.
- **Taps vs holds matter.** Keep a `{action: frames_left}` dict ticked each frame. A 4-frame
  jump tap triggers the variable-jump release cut and apexes at roughly HALF height — hold jump
  past the apex (~36 frames) when the test needs the full jump. A driver that taps everything
  silently fails every at-the-limit station.
- **Reading game state:** C# public properties on nodes ARE readable from GDScript —
  `int(player.get("State"))` returns the enum as an int (verified live). Prefer that for state
  the test hinges on; observational heuristics (airborne + zero velocity for N frames) work but
  break silently when a state can coexist with `is_on_floor()` — that exact false-negative hid
  an underground-hang defect once.
- **Verify the setup steps.** After a teleport keypress, check the player's position actually
  moved to the station before starting the run — an out-of-range key index otherwise sends the
  driver through the wrong geometry and every later observation is noise.
- **Self-terminate.** `get_tree().quit()` at script completion, or Movie Maker records forever.

## Liveness guards — quit the moment the run stops being a playable test

Dead footage is worthless and a reviewer can mistake it for data. Three layers, all printing a
diagnostic with `t`, position, and phase before quitting:

1. **Unplayable:** below the world's lowest floor (or any state the game can't recover from).
2. **Stuck:** no phase progress / no scripted event for ~15s — update a `_last_event`
   timestamp at every transition.
3. **Failsafe timeout:** a hard cap (~75s) as the backstop, never the only defense.

Review-side counterpart (also in `video-review`): the first unplayable frame ends the
reviewable portion of any capture — shorten/guard the harness or fix the game defect.

## The fallback trap — assert the system under test is ENGAGED

A codebase that degrades gracefully can hand your driver a convincing stand-in for the thing it
came to film. On the game this was built for, 2026-08-07: a clip-retime broke the animation loader, the designed
fallback (fully procedural gait) took over, and the character kept walking — stiffly, but
walking. Renders were made, numbers were measured, and the regression merged and survived a
day of verification, because every driver measured its own outputs and none asserted the clip
system was actually running. **A fallback looks like the feature having an off day, not like a
failure.**

Two rules, both cheap:

1. **Grep the run's log for `WARNING` before reading a single frame.** The engine printed the
   exact diagnosis ("clip locomotion is disabled") in every render of the broken day, unread.
   A warning naming the subsystem under test means the footage shows the fallback — the review
   is over before it starts.
2. **The driver asserts engagement, not just output.** Check for the node / clip name / state
   that exists ONLY when the real system is live (`expect_anim`-style per-phase assertions:
   this phase must observe a clip containing `walk`), and hard-fail the run when it is absent.
   A driver without an engagement assertion can pass with the feature entirely disabled — and
   its numbers will look plausibly near-perfect, because it is measuring the fallback against
   itself.

## Output resolution: only `override.cfg` moves it

**Movie Maker records at the PROJECT design resolution
(`display/window/size/viewport_width`/`_height`). Nothing at runtime reaches it.** Measured
2026-08-06 with a probe driver printing every size in play:

| Attempt | window | viewport | movie file |
|---|---|---|---|
| `--resolution 1280x720` | 1280x720 | 1280x720 | **1920x1080** |
| `DisplayServer.window_set_size()` in the driver | 1280x720 | 1280x720 | **1920x1080** |
| `override.cfg` | 1280x720 | 1280x720 | **1280x720** |

So the window flag that makes a *live* session cheaper does nothing for a render — worth knowing
before assuming a capture is half-size. Godot loads `override.cfg` from the project directory on
top of `project.godot`:

```bash
printf '[display]\n\nwindow/size/viewport_width=1280\nwindow/size/viewport_height=720\n' > game/override.cfg
# … render …
rm -f game/override.cfg
```

720p is ~44% the pixels of 1080p — a 13s clip goes ~41MB → ~18MB, which matters because contact
sheets and full-res frames are read as images. Drop to 720p unless the question needs fine detail.

**Gitignore `override.cfg`.** It silently re-configures the game for anyone who has it, and it is
a file you are meant to delete — the same "forgot to clean up" hazard as the autoload approach the
`--driver=` flag replaced. Ignoring it means forgetting cannot cost a commit.

## Deliver mp4, not the raw .avi

Movie Maker's native container is AVI/MJPEG (the only alternative is a PNG sequence) — there is
no mp4 writer in the engine, and .avi is poorly supported by modern players. So the .avi is the
*intermediate*: review-side scripts (`clip-sheet.sh`, `frame-at.sh`) read it fine,
but any clip handed to a person converts first:

```bash
ffmpeg -y -i out.avi -c:v libx264 -crf 20 -pix_fmt yuv420p -movflags +faststart out.mp4
```

~30x smaller at no visible cost for review purposes (MJPEG intra-only → h264), and it plays
everywhere. `-pix_fmt yuv420p` is what keeps QuickTime/browsers happy; leave it in.

## Render traps

- **`--headless` and `--write-movie` are INCOMPATIBLE — the render crashes, it does not degrade.**
  `--headless` selects the dummy rendering driver, which has no framebuffer to read back, so
  Movie Maker dereferences null on the very first frame it records and the process dies about a
  second after boot — exit 139 (SIGSEGV) or 134 (SIGABRT), nothing recorded:
  ```
  Movie Maker mode enabled, recording movie in 1920×1080 @ 60 FPS...
  …
  ERROR: Parameter "t" is null.
     at: texture_2d_get (./servers/rendering/dummy/storage/texture_storage.h:110)
  handle_crash: Program crashed with signal 11
  ```
  This is upstream by design, not a project bug: `--headless` disables GPU rendering entirely,
  and the PR that would have added a GPU-backed windowless mode (godotengine/godot#119379,
  `--offscreen`) was **closed unmerged**. Nothing upstream tracks the crash itself. Measured on
  4.7.1 mono, 2026-08-31, with and without zone content loaded.
  **A render needs a real display.** On a locked-screen Linux desktop that is `DISPLAY=:0`, not
  `--headless` — the lock is irrelevant, Movie Maker reads the framebuffer and never touches the
  screen. Verified: the identical command with `DISPLAY=:0` records all its frames and exits 0.
  **Gate on the summary block, never on the file.** The `.avi` is created *before* the crash, so
  `test -f` / "did the file appear" reports success on an empty one, and the run never reaches
  the leak tally — so the `WARNING` and `resources still in use` greps the render-verification
  rule depends on find nothing to report. A completed render prints:
  ```
  Done recording movie at path: /abs/path/out.avi
  120 frames at 60 FPS (movie length: 00:00:02:00), recorded in 00:00:02 …
  ```
  No block, no clip — whatever the file listing says.
  **Worth guarding in your main scene's ready method:** refuse the combination before frame
  zero, so it is one `ERROR:` line naming both flags and exit **1** rather than a segfault. The
  game this was built for does exactly that (2026-08-31); without the guard you get the raw
  crash described above.
- **macOS occlusion freeze:** when the game window is covered (the editor, anything), the
  compositor stops redrawing while the sim runs on — Movie Maker writes the last rendered image
  for the whole occluded stretch. The file looks like frozen gameplay; the driver log looks
  fine. Confirm with an RMSE diff of distant frames (`compare -metric RMSE a.png b.png null:`
  → 0 means duplicated). Fix: set `window/size/always_on_top=true` in `[display]` for the
  render, and REVERT it before committing — it is a render setting, not a game setting.
- **Stale assembly:** the movie process loads the built DLL from disk. An editor that built
  internally is not enough — run the real `dotnet build` first or the render exercises old code.
- **The editor may hold `project.godot` and re-persist it from its own memory** — this is why
  driver activation moved to a command-line flag (above). Any setting you DO still have to toggle
  on disk for a render (e.g. `always_on_top`) can come back after you remove it, and the same
  editor save strips the file's `;` comments permanently. **`git diff` the project file at
  SESSION END, not just before committing**: the editor's write can land after your last commit,
  which is exactly how a dead autoload shipped undetected once (2026-08-05).
- **Wall-clock HUD timers desync from movie time.** Movie frames advance sim time; anything
  displaying real elapsed time drifts by the render-speed ratio. Don't use an on-screen clock
  to correlate movie timestamps with driver `t` — use the driver's own printed timestamps.

## Live-probe complement

This section assumes a Godot editor MCP bridge exposing play, script-execution and input calls;
nothing above needs one. With the editor open and such a bridge connected, the same driver runs under
`play_scene` for interactive debugging: `execute_game_script` reads any node state between
frames, `simulate_action` injects input by hand, and `Engine.time_scale = 0.25` gives slow-mo
so MCP-latency sampling still resolves fast events. Use live probes to diagnose, the movie to
verify — the movie is the deterministic artifact; a live session is not.
