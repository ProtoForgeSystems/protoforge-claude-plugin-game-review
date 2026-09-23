#!/usr/bin/env bash
# Pull one frame at full resolution. This is stage two of the review loop: the contact sheet
# locates the moment, this reads the pixels (UI text, a specific artifact, an exact pose).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'USAGE'
usage: frame-at.sh <video> <timestamp> [-o out.png] [--crop WxH+X+Y] [--scale W]

  <timestamp>     seconds (12.5) or ffmpeg time (00:01:23.400)
  -o              output path (default <video-basename>-<timestamp>.png)
  --crop          crop region before writing, e.g. 600x400+100+50 -- use to zoom a HUD corner
  --scale         scale the long edge to W px after cropping

Prints the output path on success.
USAGE
  exit 2
}

[ $# -ge 2 ] || usage
VIDEO="$1"; TS="$2"; shift 2

OUT=""; CROP=""; SCALE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="${2:-}"; shift 2 ;;
    --crop) CROP="${2:-}"; shift 2 ;;
    --scale) SCALE="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_tools ffmpeg
[ -f "$VIDEO" ] || die "no such file: $VIDEO"

if [ -z "$OUT" ]; then
  safe_ts="$(printf '%s' "$TS" | tr ':.' '--')"
  OUT="${VIDEO%.*}-${safe_ts}.png"
fi

# -ss after -i decodes from the start: slower, but frame-accurate. Stage two is about precision,
# and it is one frame, so pay for it here even though clip-sheet.sh does not.
ffmpeg -nostdin -loglevel error -y -i "$VIDEO" -ss "$TS" -frames:v 1 "$OUT" 2>/dev/null \
  || die "ffmpeg could not extract a frame at '$TS'"
[ -s "$OUT" ] || die "no frame at '$TS' — past the end of the clip?"

if [ -n "$CROP" ]; then
  im_convert "$OUT" -crop "$CROP" +repage "$OUT"
fi
if [ -n "$SCALE" ]; then
  im_convert "$OUT" -resize "${SCALE}x${SCALE}>" "$OUT"
fi

echo "==> $OUT ($(im_identify -format '%wx%h' "$OUT"))" >&2
printf '%s\n' "$OUT"
