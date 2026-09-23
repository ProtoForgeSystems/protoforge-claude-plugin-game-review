# game-review — how an AI coding agent looks at a game

Two Claude Code skills and one agent definition, extracted from a shipping Godot 4 project where
most of the code is written by agent sessions and none of it can be watched by the agent that
wrote it.

An agent cannot watch a game. It can look at images and read logs. So it plays the game with a
script, renders every frame offline, reads the log before the frames, tiles the frames into a
contact sheet to find the moment, pulls that moment at full resolution to judge it, and, when
the stakes warrant, hands the frames to a second agent that has seen none of the code and has to
commit to a verdict.

| Piece | What it is |
|---|---|
| `skills/godot-movie-driver` | The driver harness: a throwaway self-driving input script activated by a command-line flag, rendered under Godot's Movie Maker mode. Driver architecture, the log-is-half-the-render rule, liveness guards, the fallback trap, output resolution, and the render traps. Godot-specific. |
| `skills/video-review` | Turning a clip into images an agent can read: a labelled contact sheet to locate the moment, a full-resolution frame to read it, and a window screenshot on macOS or Linux. Shell scripts around `ffmpeg` and ImageMagick. Engine-agnostic. |
| `agents/frame-review` | A blind second reviewer with a fixed contract: clip, choreography, what correct looks like, what the fallback would look like. Returns frame-cited findings and one committed verdict. |

Every rule in these files traces to a day the loop reported something false. The skills keep
those incidents in, dated, because the rule without the failure is the kind of advice people
skip.

## Install

**As a plugin** (skills and the agent together):

```
/plugin marketplace add ProtoForgeSystems/protoforge-claude-plugin-game-review
/plugin install game-review@protoforge-game-review
```

**As plain skills** — clone and symlink each skill directory into `~/.claude/skills/` (all
projects) or a project's `.claude/skills/` (that project). Both locations accept a symlink. The
agent file goes in `~/.claude/agents/` or `.claude/agents/`.

```bash
git clone https://github.com/ProtoForgeSystems/protoforge-claude-plugin-game-review ~/repos/game-review
ln -s ~/repos/game-review/skills/video-review        ~/.claude/skills/video-review
ln -s ~/repos/game-review/skills/godot-movie-driver  ~/.claude/skills/godot-movie-driver
ln -s ~/repos/game-review/agents/frame-review.md     ~/.claude/agents/frame-review.md
```

## Dependencies

`ffmpeg`, ImageMagick (6 or 7) and `mediainfo` on both platforms. Linux window capture adds
`x11-utils`, `xdotool` and `maim`. macOS window capture compiles a small Swift helper once
(needs the Xcode command-line tools) and needs Screen Recording permission, whose failure mode
is silent and is documented in the skill. Run `skills/video-review/scripts/verify-tools.sh` to
see what is missing.

```bash
brew install ffmpeg media-info imagemagick                              # macOS
sudo apt install ffmpeg mediainfo imagemagick x11-utils xdotool maim    # Debian/Ubuntu
```

The movie-driver skill needs only a Godot 4 project, a real display (Movie Maker cannot render
headless), and whatever builds your game's assembly.

## Notes

- The `frame-review` agent is pinned to a stronger vision model on purpose. On the build that
  motivated it, a blind reviewer on that model called a real defect at high confidence while a
  blind reviewer on another model looked at the same frames and saw nothing wrong. One sample,
  but it is the sample the agent exists for. Edit `model:` if your account has a different
  roster; keep it on the strongest vision you have.
- Two subsections assume a Godot editor MCP bridge (a screenshot call in video-review, the
  live-probe complement in the movie driver). They say so at the top; nothing else needs one.
- `verify-tools.sh` lists `yt-dlp`, `python3` and `node` as optional. They belong to a
  companion skill for studying tutorial videos that is not published here; the review scripts
  never call them.

## License

MIT. Copyright (c) 2026 ProtoForge Systems.
