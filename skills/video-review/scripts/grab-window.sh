#!/usr/bin/env bash
# Screenshot a single window by name, on macOS or Linux.
#
# This NEVER launches an application. It attaches to a window that is already open; if the target
# is not running, it fails and says so. --activate only brings an ALREADY-RUNNING app forward.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'USAGE'
usage: grab-window.sh <name-substring> [-o out.png] [--activate]
       grab-window.sh --id <window-id> [-o out.png] [--activate]
       grab-window.sh --list

  <name-substring>  matched case-insensitively against the application/window name
  --id              capture an exact window id (ids change every run -- never reuse an old one)
  --activate        bring the app forward first, switching Spaces if needed (STEALS FOCUS)
  -o                output path (default ./window-<name>.png)
  --list            list candidate windows and exit

macOS: capture is by screen region, so the window must be on the CURRENT Space and unobstructed.
The script refuses rather than silently capturing the wallpaper; --activate fixes it automatically.
USAGE
  exit 2
}

[ $# -ge 1 ] || usage

LIST=""; NAME=""; OUT=""; WID=""; ACTIVATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1; shift ;;
    --id) WID="${2:-}"; shift 2 ;;
    --activate) ACTIVATE=1; shift ;;
    -o) OUT="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) [ -z "$NAME" ] || die "unexpected argument: $1"; NAME="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------- macOS

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/video-review"
WINDOW_ID_BIN="$CACHE_DIR/window-id"

# Compile the Swift helper on first use (and whenever the source is newer). ~10s once, then cached.
# The compiled binary deliberately lives outside the skill directory: the skill is synced across
# machines via claude-memories, and a Mach-O binary has no business in that repo.
ensure_window_id() {
  local src="$SCRIPT_DIR/window-id.swift"
  [ -f "$src" ] || return 1
  [ -x "$WINDOW_ID_BIN" ] && [ ! "$src" -nt "$WINDOW_ID_BIN" ] && return 0
  have swiftc || return 1
  mkdir -p "$CACHE_DIR" || return 1
  echo "==> compiling window-id helper (first run only)..." >&2
  swiftc -O -o "$WINDOW_ID_BIN" "$src" >&2 || return 1
}

mac_query() {
  ensure_window_id || die "need swiftc (Xcode Command Line Tools) to resolve windows.
  Install with: xcode-select --install"
  "$WINDOW_ID_BIN" "$1"
}

# The single most expensive failure in this whole toolchain: without Screen Recording, macOS
# returns a picture of the WALLPAPER, exit code 0, no warning. Refuse before capturing.
mac_require_screen_recording() {
  ensure_window_id || return 0
  "$WINDOW_ID_BIN" --check-perms >/dev/null 2>&1 && return 0
  die "Screen Recording permission is NOT granted.
  Every capture would silently return the desktop wallpaper instead of the window.
  Grant it: System Settings > Privacy & Security > Screen Recording > enable the
  terminal app running Claude Code -- then FULLY QUIT AND REOPEN that app (a new tab
  is not enough; macOS only applies the grant on relaunch)."
}

# Capture a resolved window line: <id>\t<owner>\t<x,y,w,h>\t<onscreen|offscreen>\t<title>
mac_capture_line() {
  local line="$1" out="$2"
  local id owner geom state
  id="$(printf '%s' "$line" | cut -f1)"
  owner="$(printf '%s' "$line" | cut -f2)"
  geom="$(printf '%s' "$line" | cut -f3)"
  state="$(printf '%s' "$line" | cut -f4)"

  if [ "$state" = "offscreen" ]; then
    if [ -n "$ACTIVATE" ]; then
      # `open -a` brings a RUNNING app forward and switches Spaces to it. It does not relaunch a
      # running app, so this cannot start the game client.
      open -a "$owner" 2>/dev/null || die "could not bring '$owner' forward"
      sleep 1
      line="$(mac_query "$owner" | head -1)"
      geom="$(printf '%s' "$line" | cut -f3)"
      state="$(printf '%s' "$line" | cut -f4)"
    fi
    [ "$state" = "onscreen" ] || die "window $id ('$owner') is on another Space or minimised.
  macOS region capture would silently return the wallpaper instead, so this is a hard stop.
  Fix it by switching to that desktop yourself, or re-run with --activate."
  fi

  screencapture -x -R"$geom" "$out" \
    || die "screencapture failed. Grant Screen Recording:
  System Settings > Privacy & Security > Screen Recording > enable your terminal app,
  then START A NEW SESSION and retry."
}

mac_grab() {
  local name="$1" out="$2" hits count
  mac_require_screen_recording
  hits="$(mac_query "$name")"
  count="$(printf '%s\n' "$hits" | grep -c . || true)"

  [ "${count:-0}" -ge 1 ] || die "no window matching '$name' — try: $0 --list"

  # A Godot game under the editor exposes two windows with the same name: the viewport and the
  # editor's embedded-game frame. Picking blindly captures the wrong one about half the time, and
  # the result looks plausible. Make the caller choose. (The viewport matches the run resolution.)
  if [ "$count" -gt 1 ]; then
    echo "error: $count windows match '$name' — pass --id to pick one:" >&2
    printf '%s\n' "$hits" | while IFS="$(printf '\t')" read -r id owner geom state title; do
      [ -n "$id" ] || continue
      printf '  --id %-6s %-18s %-22s %-10s %s\n' "$id" "$owner" "$geom" "$state" "$title" >&2
    done
    exit 1
  fi

  mac_capture_line "$hits" "$out"
}

mac_grab_by_id() {
  local wid="$1" out="$2" line
  mac_require_screen_recording
  line="$(mac_query "" | awk -F'\t' -v i="$wid" '$1 == i')"
  [ -n "$line" ] || die "no window with id $wid — ids change every run; re-run --list"
  mac_capture_line "$line" "$out"
}

mac_list() {
  printf '%-8s %-20s %-22s %-10s %s\n' "ID" "APP" "X,Y,W,H" "STATE" "TITLE"
  mac_query "" | while IFS="$(printf '\t')" read -r id owner geom state title; do
    [ -n "$id" ] || continue
    printf '%-8s %-20s %-22s %-10s %s\n' "$id" "$owner" "$geom" "$state" "$title"
  done
}

# ---------------------------------------------------------------- Linux

linux_list() {
  xdotool search --onlyvisible --name '.+' 2>/dev/null | while read -r id; do
    wname="$(xdotool getwindowname "$id" 2>/dev/null || true)"
    [ -n "$wname" ] && printf '%s  |  %s\n' "$id" "$wname"
  done
}

linux_grab() {
  local name="$1" out="$2" ids count
  ids="$(xdotool search --onlyvisible --name "$name" 2>/dev/null || true)"
  count="$(printf '%s\n' "$ids" | grep -c . || true)"
  [ "${count:-0}" -ge 1 ] || die "no visible window matching '$name' — try: $0 --list"

  if [ "$count" -gt 1 ]; then
    echo "error: $count windows match '$name' — pass --id to pick one:" >&2
    printf '%s\n' "$ids" | while read -r i; do
      [ -n "$i" ] || continue
      printf '  --id %s   %s\n' "$i" \
        "$(xdotool getwindowgeometry --shell "$i" 2>/dev/null | tr '\n' ' ' || true)" >&2
    done
    exit 1
  fi

  # maim -i reads the window's OWN contents, so it works even when the desktop is locked --
  # coordinate capture there records the screen locker instead of the game.
  maim -i "$ids" "$out" || die "maim failed to capture window $ids"
}

# ---------------------------------------------------------------- dispatch

case "$OS" in
  Darwin)
    require_tools screencapture
    [ -n "$LIST" ] && { mac_list; exit 0; }
    ;;
  Linux)
    require_tools xdotool maim
    [ -n "$LIST" ] && { linux_list; exit 0; }
    ;;
  *) die "unsupported OS: $OS" ;;
esac

[ -n "$NAME" ] || [ -n "$WID" ] || usage

if [ -z "$OUT" ]; then
  OUT="./window-$(printf '%s' "${NAME:-$WID}" | tr -c 'A-Za-z0-9_.-' '-').png"
fi

case "$OS" in
  Darwin)
    if [ -n "$WID" ]; then mac_grab_by_id "$WID" "$OUT"; else mac_grab "$NAME" "$OUT"; fi ;;
  Linux)
    if [ -n "$WID" ]; then
      maim -i "$WID" "$OUT" || die "maim failed to capture window id $WID"
    else
      linux_grab "$NAME" "$OUT"
    fi ;;
esac

[ -s "$OUT" ] || die "capture produced an empty file — permission is the usual cause"

echo "==> $OUT ($(im_identify -format '%wx%h' "$OUT"))" >&2
printf '%s\n' "$OUT"
