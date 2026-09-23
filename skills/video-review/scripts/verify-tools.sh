#!/usr/bin/env bash
# Report whether this machine can do video review. Exits non-zero if anything required is missing,
# so it doubles as a precondition check inside other scripts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

status=0

# check <label> <description> <binary>...
# Passes if ANY of the listed binaries is present (that is how the IM6/IM7 split is expressed).
check() {
  local label="$1" desc="$2"; shift 2
  local found=""
  for b in "$@"; do
    if have "$b"; then found="$b"; break; fi
  done
  if [ -n "$found" ]; then
    printf '  %-4s %-13s %s\n' "OK" "$label" "$desc"
  else
    printf '  %-4s %-13s %s\n' "--" "$label" "$desc  (missing: $*)"
    status=1
  fi
}

echo "==> Verifying tools"

check ffmpeg    "extract frames / record"      ffmpeg
check ffprobe   "inspect streams"              ffprobe
check mediainfo "readable file summary"        mediainfo
check convert   "image conversion"             magick convert
check montage   "contact sheets -- the main review tool" magick montage
check identify  "image dimensions / format"    magick identify
# optcheck <label> <description> <binary>...  -- reported, never fails the run.
optcheck() {
  local label="$1" desc="$2"; shift 2
  local found=""
  for b in "$@"; do
    if have "$b"; then found="$b"; break; fi
  done
  if [ -n "$found" ]; then
    printf '  %-4s %-13s %s\n' "OK" "$label" "$desc"
  else
    printf '  %-4s %-13s %s\n' "~~" "$label" "$desc  (optional; missing: $*)"
  fi
}
# Only the companion studying-tutorial-videos skill calls these; the review scripts never do.
optcheck yt-dlp  "optional: downloading screencasts" yt-dlp
optcheck python3 "optional: transcript parsing"      python3
optcheck node    "optional: yt-dlp JS runtime (>= 20)" node

case "$OS" in
  Darwin)
    check osascript     "window geometry"        osascript
    check screencapture "single-frame screenshot" screencapture
    # Optional: only improves precision, never required.
    if have GetWindowID; then
      printf '  %-4s %-13s %s\n' "OK" "GetWindowID" "exact window capture (optional)"
    else
      printf '  %-4s %-13s %s\n' "~~" "GetWindowID" "optional; without it capture is by screen region"
    fi
    ;;
  Linux)
    check xwininfo "window geometry"          xwininfo
    check xdotool  "find window by name"      xdotool
    check maim     "single-frame screenshot"  maim
    ;;
  *)
    echo "  warning: unrecognized OS '$OS' — window capture is unsupported here" >&2
    ;;
esac

if [ -n "$IM7" ]; then
  echo "==> ImageMagick 7 (via 'magick')"
else
  echo "==> ImageMagick 6 (legacy binaries)"
fi

if [ "$status" -ne 0 ]; then
  echo
  case "$OS" in
    Darwin) echo "Install what is missing with: brew install ffmpeg media-info imagemagick" ;;
    Linux)  echo "Install what is missing with your package manager (ffmpeg mediainfo imagemagick x11-utils xdotool maim)" ;;
  esac
fi

exit "$status"
