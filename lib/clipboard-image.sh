# shellcheck shell=bash disable=SC2034  # CLIP_BACKEND and CLIP_ERR are the callers' to read
#
# The clipboard's image as a PNG. Sourced by bin/claude-airlock (`airlock paste`) and
# agents/operator (`<command> paste`): one copy, so the two can't drift apart. Each caller
# picks where the files live and publishes the result itself; this only reads and converts.
#
#   clip_abs_path         drops the empty and relative entries from PATH (call it first): the
#                         caller's cwd may be a pastes dir a box can write, and with PATH=...:
#                         or PATH=.:... a magick planted there would be the one that runs.
#   clip_backend          sets CLIP_BACKEND to wayland or x11, by SESSION, not by which binary
#                         happens to exist (under XWayland both can be installed and the native
#                         one is the correct reader). Fails with the reason in CLIP_ERR.
#   clip_png <raw> <out>  reads the clipboard's image into <raw> and writes it as a PNG to <out>.
#                         Fails with the reason in CLIP_ERR; the caller removes both files (a
#                         half-written file must never look like a finished paste).
#
# <raw> and <out> must be files the caller made (mktemp) where no box can write: a converter
# writing to a name a box can plant a link at would write through it (pentest O22).
#
# Only raster types are taken, each read with its own decoder named explicitly: an SVG (copied
# from a web page, say) handed to a converter that sniffs the content could make it fetch or
# read files, and a converter left to sniff can be talked into another parser by the bytes.
# The Claude API accepts PNG, JPEG, GIF and WebP; the rest (Windows' BMP above all: WSLg passes
# Snipping Tool images through as image/bmp only) has to be converted or the box can't read it.

CLIP_TYPES="image/png image/bmp image/x-bmp image/jpeg image/gif image/webp image/tiff"

clip_abs_path() {
  local d out="" parts=()
  IFS=: read -ra parts <<< "$PATH"
  for d in "${parts[@]}"; do case $d in /*) out+="${out:+:}$d" ;; esac; done
  PATH=$out
}

clip_backend() {
  CLIP_BACKEND="" CLIP_ERR=""
  if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null 2>&1; then CLIP_BACKEND=wayland
  elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then CLIP_BACKEND=x11
  elif [ -n "${WAYLAND_DISPLAY:-}" ]; then CLIP_ERR="Wayland session but wl-paste is missing (install wl-clipboard)."
  elif [ -n "${DISPLAY:-}" ]; then CLIP_ERR="X11 session but xclip is missing (install xclip)."
  else CLIP_ERR="no graphical session (\$WAYLAND_DISPLAY and \$DISPLAY are both unset)."
  fi
  [ -n "$CLIP_BACKEND" ]
}

_clip_types() {
  case "$CLIP_BACKEND" in
    wayland) wl-paste --list-types 2>/dev/null ;;
    x11)     xclip -selection clipboard -t TARGETS -o 2>/dev/null ;;
  esac
}
_clip_read() {
  case "$CLIP_BACKEND" in
    wayland) wl-paste --type "$1" 2>/dev/null ;;
    x11)     xclip -selection clipboard -t "$1" -o 2>/dev/null ;;
  esac
}
_clip_is_png() { [ "$(head -c 8 "$1" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; }

clip_png() {
  local raw=$1 out=$2 types t type="" fmt rc=0
  CLIP_ERR=""
  # `|| true`: a failing wl-paste/xclip is "no image" (said below), never an exit. Under
  # `set -e` an assignment takes the substitution's status, and a caller that ever ran this
  # outside an `if`/`||` would otherwise end HERE, silently.
  types="$(_clip_types || true)"
  # PNG first (no conversion), then BMP (what Windows offers), then the first other raster type.
  for t in $CLIP_TYPES; do   # whole lines only: image/png-foo is not image/png
    case $'\n'"$types"$'\n' in *$'\n'"$t"$'\n'*) type=$t; break ;; esac
  done
  if [ -z "$type" ]; then
    CLIP_ERR="no image on the clipboard (offered: $(printf '%s' "$types" | tr '\n' ' ' | sed 's/ *$//'))"
    [ -n "$types" ] || CLIP_ERR="no image on the clipboard (offered: nothing)"
    return 1
  fi
  _clip_read "$type" > "$raw" || rc=$?
  [ "$rc" -eq 0 ] || { CLIP_ERR="reading the clipboard failed ($type, exit $rc)"; return 1; }
  [ -s "$raw" ] || { CLIP_ERR="the clipboard read produced no data ($type)"; return 1; }

  fmt=${type#image/}; fmt=${fmt#x-}   # png bmp jpeg gif webp tiff: each converter's name for it
  if [ "$fmt" = png ]; then
    _clip_is_png "$raw" || { CLIP_ERR="the clipboard's image/png is not a PNG"; return 1; }
    cp -- "$raw" "$out" || { CLIP_ERR="could not write the work file"; return 1; }
  # [0]: the first frame only. An animated GIF or WebP, or a multi-page TIFF, would otherwise
  # be written as <out>-0, <out>-1 ... next to <out>, which stays empty.
  elif command -v magick >/dev/null 2>&1; then
    magick "$fmt:${raw}[0]" "png:$out" || { CLIP_ERR="magick could not convert the clipboard's $type"; return 1; }
  elif command -v convert >/dev/null 2>&1; then
    convert "$fmt:${raw}[0]" "png:$out" || { CLIP_ERR="convert could not convert the clipboard's $type"; return 1; }
  elif command -v ffmpeg >/dev/null 2>&1; then
    # Demuxer named (bmp_pipe and so on; GIF's is gif), and the muxer: <out> has no extension
    # for ffmpeg to guess from, and -update 1 takes it as one file, not a numbered pattern.
    local dmx="${fmt}_pipe"; [ "$fmt" = gif ] && dmx=gif
    ffmpeg -nostdin -y -loglevel error -f "$dmx" -i "$raw" -frames:v 1 -c:v png -f image2 -update 1 "$out" \
      || { CLIP_ERR="ffmpeg could not convert the clipboard's $type"; return 1; }
  # -I on the probe too: `python3 -c` puts the current directory first on sys.path, and the
  # caller's may be a pastes dir a box can write (a planted PIL.py would run here, on the host).
  elif python3 -I -c 'import PIL' 2>/dev/null; then
    python3 -I -c 'import sys
from PIL import Image
im = Image.open(sys.argv[1], formats=[sys.argv[3]])
if im.mode not in ("1", "L", "LA", "P", "RGB", "RGBA", "I", "I;16"):
    im = im.convert("RGBA")   # CMYK and the like: PNG cannot hold them
im.save(sys.argv[2], "PNG")' "$raw" "$out" "${fmt^^}" 2>/dev/null \
      || { CLIP_ERR="Pillow could not convert the clipboard's $type"; return 1; }
  else
    CLIP_ERR="the clipboard offered $type and no PNG converter is installed (imagemagick, ffmpeg or python-pillow / python3-pil)"
    return 1
  fi

  # Check what was PRODUCED, not merely that something was: a converter that exits 0 having
  # written garbage is the failure that matters, and size alone can't see it.
  [ -s "$out" ] || { CLIP_ERR="the conversion produced an empty file"; return 1; }
  _clip_is_png "$out" || { CLIP_ERR="the conversion produced a file that is not a PNG"; return 1; }
}
