#!/usr/bin/env bash
# Build a labelled contact sheet from a video clip: N evenly-spaced frames tiled into one image,
# each stamped with its timestamp so a reviewer can name the moment worth looking at closely.
#
# The default width is deliberately ~1500px. That is about the largest image an LLM reviewer sees
# without downscaling, and a downscaled contact sheet turns small UI text into mush. Do not raise
# it "for quality" -- it makes the sheet strictly less readable to the thing reading it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

FRAMES=16
WIDTH=1500
OUT=""
START=""
END=""
CROP=""

usage() {
  cat >&2 <<'USAGE'
usage: clip-sheet.sh <video> [-n frames] [-w width] [-o out.png] [--start SEC] [--end SEC]

  -n  number of frames to sample        (default 16)
  -w  target sheet width in pixels      (default 1500 -- sized for LLM vision input)
  -o  output path                       (default <video-basename>-sheet.png next to the video)
      --start / --end   restrict sampling to a time range, in seconds
      --crop WxH+X+Y    crop each frame before tiling

CROP IS USUALLY THE DIFFERENCE BETWEEN A USEFUL SHEET AND A USELESS ONE. Tiling untouched 1080p
frames 4-across leaves the subject a few pixels tall. Crop to it first.

Prints the output path on success.
USAGE
  exit 2
}

[ $# -ge 1 ] || usage
VIDEO="$1"; shift

while [ $# -gt 0 ]; do
  case "$1" in
    -n) FRAMES="${2:-}"; shift 2 ;;
    -w) WIDTH="${2:-}"; shift 2 ;;
    -o) OUT="${2:-}"; shift 2 ;;
    --start) START="${2:-}"; shift 2 ;;
    --end) END="${2:-}"; shift 2 ;;
    --crop) CROP="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_tools ffmpeg ffprobe
[ -f "$VIDEO" ] || die "no such file: $VIDEO"
[ "$FRAMES" -ge 1 ] 2>/dev/null || die "-n must be a positive integer (got '$FRAMES')"
[ "$WIDTH" -ge 100 ] 2>/dev/null || die "-w must be at least 100 (got '$WIDTH')"

DURATION="$(probe_duration "$VIDEO")"
[ -n "$DURATION" ] || die "ffprobe could not read a duration from '$VIDEO' — is it actually a video?"

# Clamp the sampling window to the clip.
: "${START:=0}"
: "${END:=$DURATION}"
awk -v s="$START" -v e="$END" -v d="$DURATION" \
  'BEGIN { if (s < 0 || e > d + 0.001 || s >= e) exit 1 }' \
  || die "invalid range: --start $START --end $END against a ${DURATION}s clip"

SPAN="$(awk -v s="$START" -v e="$END" 'BEGIN { printf "%.6f", e - s }')"

# More frames than there are distinct moments produces duplicate tiles. Warn rather than fail --
# a 2-second clip sampled 16 times is still a legitimate thing to want.
if awk -v span="$SPAN" -v n="$FRAMES" 'BEGIN { exit !(span / n < 0.04) }'; then
  echo "warning: ${SPAN}s across $FRAMES frames is under one frame apart; tiles will repeat" >&2
fi

[ -n "$OUT" ] || OUT="${VIDEO%.*}-sheet.png"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Columns from the square root keeps the sheet roughly square; the tile width follows from the
# target sheet width so the montage lands near WIDTH regardless of frame count.
COLS="$(awk -v n="$FRAMES" 'BEGIN { c = int(sqrt(n)); if (c * c < n) c++; print c }')"
TILE="$(awk -v w="$WIDTH" -v c="$COLS" 'BEGIN { printf "%d", w / c }')"

echo "==> ${VIDEO##*/}: ${DURATION}s, sampling $FRAMES frames into ${COLS} columns" >&2

# Cropping during decode is cheaper than an ImageMagick round-trip per frame, and it means the
# tile width applies to the cropped region -- which is the whole point of cropping.
VF_ARGS=()
if [ -n "$CROP" ]; then
  case "$CROP" in
    *x*+*+*) ;;
    *) die "--crop expects WxH+X+Y (e.g. 700x500+1100+200), got '$CROP'" ;;
  esac
  VF_ARGS=(-vf "crop=$(printf '%s' "$CROP" | tr 'x+' '::')")
fi

# Timestamp labels are the point of the sheet, but a missing font must not cost you the sheet.
LABELS=1
if ! resolve_im_font; then
  LABELS=""
  echo "warning: no usable font found — sheet will have no timestamp labels" >&2
fi

args=()
i=0
while [ "$i" -lt "$FRAMES" ]; do
  # Sample interval midpoints, not edges: t=0 is often a black or logo frame, and the final
  # frame of a clip is frequently a fade.
  ts="$(awk -v s="$START" -v span="$SPAN" -v i="$i" -v n="$FRAMES" \
        'BEGIN { printf "%.3f", s + span * (i + 0.5) / n }')"
  frame="$TMP/$(printf 'f_%04d' "$i").png"

  # -ss before -i seeks by keyframe first, which is what makes this fast enough to be interactive.
  if ! ffmpeg -nostdin -loglevel error -y -ss "$ts" -i "$VIDEO" \
        ${VF_ARGS[@]+"${VF_ARGS[@]}"} -frames:v 1 "$frame" 2>/dev/null \
     || [ ! -s "$frame" ]; then
    echo "warning: no frame decoded at ${ts}s — skipping" >&2
    i=$((i + 1))
    continue
  fi

  if [ -n "$LABELS" ]; then
    args+=(-label "$(fmt_ts "$ts")" "$frame")
  else
    args+=("$frame")
  fi
  i=$((i + 1))
done

[ ${#args[@]} -gt 0 ] || die "no frames could be extracted from '$VIDEO'"

# bash 3.2 (what macOS ships) errors on "${arr[@]}" for an empty array under `set -u`,
# so every array expansion here uses the +-guarded form. FONT_ARGS is routinely empty.
im_montage \
  -background '#141414' -fill '#e8e8e8' -pointsize 13 \
  ${FONT_ARGS[@]+"${FONT_ARGS[@]}"} \
  ${args[@]+"${args[@]}"} \
  -tile "${COLS}x" -geometry "${TILE}x+5+5" \
  "$OUT"

echo "==> $OUT ($(im_identify -format '%wx%h' "$OUT"))" >&2
printf '%s\n' "$OUT"
