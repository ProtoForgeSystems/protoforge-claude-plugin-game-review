#!/usr/bin/env bash
# Shared helpers for the video-review scripts. Sourced, never executed directly.
#
# Everything here exists to hide two differences the caller should not have to think about:
#   1. macOS vs. Linux window tooling (screencapture/osascript vs. maim/xdotool/xwininfo).
#   2. ImageMagick 7 vs. 6 (`magick montage` vs. a real `montage` binary).

OS="$(uname -s)"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ImageMagick 6 ships convert/montage/identify as separate binaries.
# ImageMagick 7 (Homebrew ships >= 7.1.2) dropped them and routes everything through `magick`.
# Resolve once at source time so call sites never branch.
IM7=""
have magick && IM7=1

im_montage() {
  if [ -n "$IM7" ]; then magick montage "$@"
  elif have montage; then montage "$@"
  else die "ImageMagick missing: need 'magick' (v7) or 'montage' (v6). Run verify-tools.sh."
  fi
}

im_identify() {
  if [ -n "$IM7" ]; then magick identify "$@"
  elif have identify; then identify "$@"
  else die "ImageMagick missing: need 'magick' (v7) or 'identify' (v6). Run verify-tools.sh."
  fi
}

im_convert() {
  # `magick` alone IS the v7 convert; `magick convert` is deprecated, so don't use it.
  if [ -n "$IM7" ]; then magick "$@"
  elif have convert; then convert "$@"
  else die "ImageMagick missing: need 'magick' (v7) or 'convert' (v6). Run verify-tools.sh."
  fi
}

# Homebrew's ImageMagick is built without fontconfig, so `magick -list font` is EMPTY and any
# -label/-annotate fails with "unable to read font ''". It does accept a direct .ttf path, so
# resolve one ourselves. Populates FONT_ARGS, which callers splat into the montage command.
# Empty FONT_ARGS is a valid outcome: it means ImageMagick has real fonts and can pick its own.
FONT_ARGS=()
resolve_im_font() {
  local count candidates f p
  count="$( { im_identify -list font 2>/dev/null || true; } | grep -c '^  Font:' || true)"
  [ "${count:-0}" -gt 0 ] && return 0

  case "$OS" in
    Darwin) candidates="/System/Library/Fonts/Supplemental/Arial.ttf
/System/Library/Fonts/Supplemental/Verdana.ttf
/Library/Fonts/Arial.ttf" ;;
    Linux)  candidates="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf
/usr/share/fonts/TTF/DejaVuSans.ttf
/usr/share/fonts/dejavu/DejaVuSans.ttf" ;;
    *) candidates="" ;;
  esac

  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && { FONT_ARGS=(-font "$f"); return 0; }
  done <<EOF
$candidates
EOF

  # Prefer a real lookup over the hardcoded list when fontconfig is available.
  if have fc-match; then
    p="$(fc-match -f '%{file}' sans-serif 2>/dev/null || true)"
    [ -n "$p" ] && [ -f "$p" ] && { FONT_ARGS=(-font "$p"); return 0; }
  fi

  return 1
}

require_tools() {
  local missing=()
  for t in "$@"; do have "$t" || missing+=("$t"); done
  if [ ${#missing[@]} -gt 0 ]; then
    die "missing required tool(s): ${missing[*]} — run verify-tools.sh for the full picture"
  fi
}

# Seconds (float) -> M:SS.ss, for frame labels.
fmt_ts() {
  awk -v t="$1" 'BEGIN { m = int(t / 60); printf "%d:%05.2f", m, t - 60 * m }'
}

# Duration of a video in seconds, as a float. Empty/failed probe is a hard error at the call site.
probe_duration() {
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null
}
